// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IntentQuoteVerifier} from "./IntentQuoteVerifier.sol";
import {IntentFactory} from "./IntentFactory.sol";
import {IntentVault} from "./IntentVault.sol";
import {IntentLenderMarket} from "./IntentLenderMarket.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";

/// @notice Funds a whole listing from Intent vaults in one transaction, or nothing at all (D12).
/// @dev A fill uses one signed plan through the verifier, has every vault in it buy its units, requires the listing
/// to have activated in this very transaction, brings every vault to that common activation, and takes each vault's
/// execution fee, which must be exactly what the plan signed. The fees are credited here, at once and whole, to the
/// protocol's recipient as it stands at that moment (V1 has no filler share, D49): amounts owed to an address, which
/// no later setting can move. Anything that fails reverts all of it, the plan's use included, so no vault is ever left
/// holding part of a listing that did not activate and no fee is ever owed for one. Nothing here holds a user's funds:
/// the router only ever holds execution fees already earned, until their recipients are paid.
/// Amounts and units come from the plan, so nothing assumes an engine's unit count; the verifier knows the engine.
contract IntentFillRouter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IntentQuoteVerifier public immutable VERIFIER;
    IntentFactory public immutable FACTORY;
    GageV2Vault public immutable CORE;
    IERC20 public immutable USDG;

    /// @notice Earned execution fees not yet paid out, by recipient.
    mapping(address => uint256) public owed;
    /// @notice The sum of `owed`; the router's USDG never falls below it.
    uint256 public totalOwed;

    event Contribution(
        bytes32 indexed digest, address indexed vault, uint8 units, uint256 principal, uint256 interest, uint256 fee
    );
    /// @dev The whole execution fee is owed to `protocolRecipient` (V1 has no filler share, D49).
    event Filled(
        bytes32 indexed digest,
        uint256 indexed listingId,
        address indexed filler,
        uint40 activatedAt,
        uint256 principal,
        uint256 executionFee,
        address protocolRecipient
    );
    event SecondaryContribution(
        bytes32 indexed digest, address indexed vault, uint8 slots, uint256 price, uint256 repayment, uint256 fee
    );
    /// @dev One complete purchase of one listed lender bundle: its seller, its price and the execution fee it paid,
    /// credited here whole to the protocol recipient that stood at that moment (D49).
    event SecondaryFilled(
        bytes32 indexed digest,
        uint256 indexed loanId,
        address indexed filler,
        address seller,
        address market,
        uint8 slots,
        uint256 price,
        uint256 executionFee,
        address protocolRecipient
    );
    event StaleFeesSwept(address indexed vault, address indexed protocolRecipient, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);

    error InvalidConfiguration();
    error NotFiller();
    error NotAVault();
    error LengthMismatch();
    error NotActivated();
    error FeeMismatch();
    error NothingOwed();
    /// @notice The buyers did not hand over exactly the listing price, or the sale did not spend exactly it.
    error PaymentMismatch();
    /// @notice A quarter a vault paid for did not arrive at that vault.
    error RightsMismatch();

    constructor(IntentQuoteVerifier verifier, IERC20 usdg) {
        if (address(verifier).code.length == 0 || address(usdg).code.length == 0) revert InvalidConfiguration();
        VERIFIER = verifier;
        FACTORY = verifier.FACTORY();
        CORE = verifier.CORE();
        USDG = usdg;
    }

    /// @notice Fund every purchase of a signed plan and activate its listing, or revert everything.
    /// @param maxReserveShares Per purchase, an optional tighter caller ceiling. The signed allocation is always
    /// the upper bound, including when this caller supplies an unlimited value.
    function fill(IntentQuoteVerifier.Plan calldata plan, bytes calldata signature, uint256[] calldata maxReserveShares)
        external
        nonReentrant
        returns (bytes32 digest)
    {
        uint256 count = plan.allocations.length;
        if (maxReserveShares.length != count) revert LengthMismatch();
        // Signature, single use, filler admission, listing terms, the empty units and every fee bound.
        digest = VERIFIER.consume(plan, signature, msg.sender);
        uint256 id = plan.listingId;
        for (uint256 i; i < count; ++i) {
            IntentQuoteVerifier.Allocation calldata a = plan.allocations[i];
            uint256 ceiling = maxReserveShares[i] < a.maxReserveShares ? maxReserveShares[i] : a.maxReserveShares;
            IntentVault(a.vault).purchase(id, a.units, 0, ceiling, a.executionFee);
        }
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE || l.fundedAt != block.timestamp) revert NotActivated();
        // Every vault is brought to the common activation before this returns: the ones that bought before the last
        // purchase had not seen the loan active. Then each hands over exactly the fee the plan signed.
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256 principal;
        uint256 fee;
        for (uint256 i; i < count; ++i) {
            IntentQuoteVerifier.Allocation calldata a = plan.allocations[i];
            if (i + 1 != count) IntentVault(a.vault).settle(ids);
            if (_collect(a.vault) != a.executionFee) revert FeeMismatch();
            principal += a.principal;
            fee += a.executionFee;
            emit Contribution(digest, a.vault, a.units, a.principal, a.interest, a.executionFee);
        }
        address protocol = _split(fee);
        emit Filled(digest, id, msg.sender, l.fundedAt, principal, fee, protocol);
    }

    /// @notice Buy one listed lender bundle with every vault of a signed secondary plan, each taking its exact
    /// quarters at its exact price, in one transaction; or revert everything, the plan's use included (D36).
    /// @dev Each vault books its purchase whole inside its own call and sends its price here; the one sale, through the
    /// seller vault's market (the only seller the verifier accepts), then delivers each quarter straight to its vault:
    /// the core's split sale (`GageV2Vault.buyLenderSplit`) writes exactly the sold quarters, the ask's, which the
    /// verifier holds equal to the plan's and to the allocations' union, to the recipients named here, and its ledger
    /// refuses an invalid recipient. Nothing is credited unless the price was spent exactly, the core records every
    /// quarter each vault paid for as that vault's, and every vault handed over exactly the fee the plan signed.
    function fillSecondary(IntentQuoteVerifier.SecondaryPlan calldata plan, bytes calldata signature)
        external
        nonReentrant
        returns (bytes32 digest)
    {
        // Signature, single use, filler admission, the live listing and loan, and every allocation's own terms.
        digest = VERIFIER.consumeSecondary(plan, signature, msg.sender);
        uint256 id = plan.loanId;
        uint256 held = USDG.balanceOf(address(this));
        address[4] memory recipients;
        uint256 count = plan.allocations.length;
        for (uint256 i; i < count; ++i) {
            IntentQuoteVerifier.SecondaryAllocation calldata a = plan.allocations[i];
            IntentVault(a.vault).purchase(id, a.slots, a.price, a.maxReserveShares, a.executionFee);
            for (uint8 q; q < 4; ++q) {
                if (a.slots & (1 << q) != 0) recipients[q] = a.vault;
            }
        }
        if (USDG.balanceOf(address(this)) - held != plan.price) revert PaymentMismatch();
        USDG.forceApprove(plan.market, plan.price);
        IntentLenderMarket(plan.market).buySplit(id, uint64(plan.nonce), plan.price, recipients, plan.minRewards);
        // The one spender, the market, was approved exactly the price and pulls exactly the price from this router
        // (its exact-receipt transfer); the router's own outflows are all non-reentrant and it holds no other
        // allowance. So exactly the price leaving, as checked here, means no approval survives the sale.
        if (USDG.balanceOf(address(this)) != held) revert PaymentMismatch();
        // Every vault booked its quarters before they moved, so each must now hold every quarter it paid for: a
        // delivery bug in the market or the core would otherwise leave a vault booking a position it does not hold.
        address[4] memory owners = CORE.lenders(id);
        uint256 fee;
        for (uint256 i; i < count; ++i) {
            IntentQuoteVerifier.SecondaryAllocation calldata a = plan.allocations[i];
            for (uint8 q; q < 4; ++q) {
                if (a.slots & (1 << q) != 0 && owners[q] != a.vault) revert RightsMismatch();
            }
            if (_collect(a.vault) != a.executionFee) revert FeeMismatch();
            fee += a.executionFee;
            emit SecondaryContribution(digest, a.vault, a.slots, a.price, a.repayment, a.executionFee);
        }
        address protocol = _split(fee);
        emit SecondaryFilled(digest, id, msg.sender, plan.seller, plan.market, plan.slots, plan.price, fee, protocol);
    }

    /// @notice Pay a recipient everything it is owed. Anyone may call; the money only ever goes to the recipient.
    function claim(address recipient) external nonReentrant returns (uint256 amount) {
        amount = owed[recipient];
        if (amount == 0) revert NothingOwed();
        owed[recipient] = 0;
        totalOwed -= amount;
        USDG.safeTransfer(recipient, amount);
        emit Claimed(recipient, amount);
    }

    /// @notice Collect earned fees left outside this router's fills and credit the current protocol recipient.
    /// Sweep inherited fees before a new fill's exact-fee check. Funding gates do not prevent collection, but this
    /// router must still be the factory's current fill router.
    function sweepStale(address vault) external nonReentrant returns (uint256 amount) {
        if (!FACTORY.isVault(vault)) revert NotAVault();
        amount = _collect(vault);
        if (amount == 0) revert NothingOwed();
        address recipient = FACTORY.protocolRecipient();
        owed[recipient] += amount;
        totalOwed += amount;
        emit StaleFeesSwept(vault, recipient, amount);
    }

    /// @notice Move a vault's idle cash into its reserve, for an admitted filler.
    function investReserve(address vault, uint256 assets, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (!FACTORY.isFiller(msg.sender)) revert NotFiller();
        if (!FACTORY.isVault(vault)) revert NotAVault();
        return IntentVault(vault).investReserve(assets, minShares);
    }

    /// @dev What the vault says it handed over must be what arrived.
    function _collect(address vault) internal returns (uint256 amount) {
        uint256 held = USDG.balanceOf(address(this));
        amount = IntentVault(vault).collectExecutionFees();
        if (USDG.balanceOf(address(this)) - held != amount) revert FeeMismatch();
    }

    /// @dev Credit the whole `fee` to the protocol's recipient as it stands now, once: V1 has no filler share and no
    /// filler payout (D49), and a later filler model comes with a new router and its own payout registry.
    function _split(uint256 fee) internal returns (address protocol) {
        protocol = FACTORY.protocolRecipient();
        if (protocol == address(0)) revert InvalidConfiguration();
        owed[protocol] += fee;
        totalOwed += fee;
    }
}
