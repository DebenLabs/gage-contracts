// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Collateral, Kind} from "../types/Types.sol";
import {V2State, V2Loan, V2Ask, V2LenderAsk, V2LenderSplit, unitSlice} from "./V2Types.sol";
import {GageV2Rewards} from "./GageV2Rewards.sol";
import {GageV2TokenRegistry} from "./GageV2TokenRegistry.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {GageV2TokenCollateralAccount} from "./GageV2TokenCollateralAccount.sol";
import {GageLegacyAdapter} from "./GageLegacyAdapter.sol";

/// @notice Four-unit loans with a single tradable reclaim right and independently withdrawable cash and rewards.
/// @dev Immutable custody: registry changes only gate new listings/funding, never repayment or recovery.
contract GageV2Vault is ERC721, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDG;
    IERC20 public immutable SGAGE;
    GageV2TokenRegistry public immutable REGISTRY;
    GageV2Rewards public immutable REWARDS;
    GageLegacyAdapter public immutable BRIDGE;
    address public immutable ACCOUNT_IMPLEMENTATION;
    address public immutable FEE_RECIPIENT;
    /// @notice Borrower-only window after the term. Repayment closes and default finalization opens at term + GRACE,
    ///         in the same second; zero on releases without a grace window.
    uint32 public immutable GRACE;
    uint32 public constant MAX_FUNDING_WINDOW = 7 days;
    uint32 public constant MAX_EXECUTION_WINDOW = 15 minutes;
    uint32 public constant MAX_GRACE = 7 days;
    uint8 public constant UNITS = 4;

    /// @notice Highest issued ID, including closed/cancelled loans, for independent chain discovery.
    uint256 public loanCount;
    mapping(uint256 => V2Loan) private _loans;
    mapping(uint256 => address[4]) private _lenders;
    mapping(uint256 => V2Ask) private _asks;
    mapping(uint256 => uint256) private _nonces;
    mapping(uint256 => mapping(address => V2LenderAsk)) private _lenderAsks;
    mapping(uint256 => mapping(address => uint256)) private _lenderNonces;
    /// @notice Cash available to withdraw; committed partial funding is excluded.
    mapping(address => uint256) public cashCredit;
    /// @notice Raw collateral exposure against the registry admission bucket.
    mapping(bytes32 => uint256) public openExposure;
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) private _recoveryClaimed;

    error InvalidConfiguration();
    /// @notice The collateral is not an admitted token within its per-loan bounds (the zero token and sGAGE never are).
    error InvalidCollateral();
    error InvalidTerms();
    error WrongState();
    error Paused();
    error NotAuthorized();
    error Deadline();
    error InvalidUnits();
    error ExactTransferRequired();
    error ExposureCap();
    error UseMarketplace();
    error StaleAsk();
    error InvalidRecipient();
    error NothingToClaim();

    event Listed(
        uint256 indexed id,
        address indexed borrower,
        address account,
        Collateral collateral,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint40 fundingDeadline
    );
    event UnitsFunded(uint256 indexed id, address indexed lender, uint8 units, uint256 amount, uint8 filled);
    event CommitmentWithdrawn(uint256 indexed id, address indexed lender, uint8 units, uint256 amount);
    event Activated(uint256 indexed id, uint40 fundedAt, uint128 fee, uint128 borrowerReward, uint128 lenderReward);
    event Closed(uint256 indexed id, V2State state, address beneficiary, uint40 closedAt);
    event AskPosted(
        uint256 indexed id, address indexed seller, uint128 price, uint40 deadline, uint16 feeBps, uint256 nonce
    );
    event AskCancelled(uint256 indexed id, uint256 nonce);
    event RightSold(
        uint256 indexed id,
        address indexed seller,
        address indexed buyer,
        address recipient,
        uint128 price,
        uint256 fee,
        uint256 nonce
    );
    event CollateralWithdrawn(uint256 indexed id, address indexed recipient);
    event DefaultRecovered(uint256 indexed id, address[2] tokens, uint256[2] amounts);
    event RecoveryWithdrawn(uint256 indexed id, address indexed lender, uint8 asset, address recipient, uint256 amount);
    event LenderAskPosted(
        uint256 indexed id,
        address indexed seller,
        uint8 slots,
        uint128 price,
        uint40 deadline,
        uint16 feeBps,
        uint256 nonce
    );
    event LenderSplitSold(
        uint256 indexed id,
        address indexed seller,
        address indexed buyer,
        uint8 slots,
        uint128 price,
        uint256 fee,
        uint256 nonce,
        address[4] recipients
    );

    /// @dev `usdg` is the lent asset: USDG on every core so far, and any token of 6 to 18 decimals (a stock token
    /// has 18), whose strategies scale their six-decimal amounts by it. A shared asset/sGAGE address is refused; a
    /// zero or codeless one fails its decimals call without revert data (its empty return cannot be decoded).
    constructor(
        GageV2TokenRegistry registry,
        IERC20 usdg,
        IERC20 sgage,
        address feeRecipient,
        uint32 grace,
        GageLegacyAdapter bridge
    ) ERC721("Gage V2 Reclaim Right", "GAGE-R") {
        uint8 cashDecimals = IERC20Metadata(address(usdg)).decimals();
        if (
            feeRecipient == address(0) || grace > MAX_GRACE || address(registry).code.length == 0 || cashDecimals < 6
                || cashDecimals > 18 || address(usdg) == address(sgage)
                || IERC20Metadata(address(sgage)).decimals() != 18
        ) revert InvalidConfiguration();
        REGISTRY = registry;
        USDG = usdg;
        SGAGE = sgage;
        FEE_RECIPIENT = feeRecipient;
        GRACE = grace;
        BRIDGE = bridge;
        if (address(bridge) != address(0)) {
            // The legacy deal behind a bridged loan holds only the adapter's receipt, so its own grace never has to
            // match this engine's: the adapter settles that deal once the legacy vault allows it.
            if (address(bridge.USDG()) != address(USDG) || address(bridge.SGAGE()) != address(SGAGE)) {
                revert InvalidConfiguration();
            }
        }
        REWARDS = new GageV2Rewards(SGAGE, bridge);
        ACCOUNT_IMPLEMENTATION = address(new GageV2TokenCollateralAccount());
    }

    /// @notice Deposit whole token collateral and post fixed terms, funded in exactly four units. Tokens only (D35):
    ///         the collateral account refuses any other kind.
    function list(
        Collateral calldata c,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint40 fundingDeadline,
        bool withRewards
    ) external nonReentrant returns (uint256 id) {
        return _list(c, principal, cap, term, fundingDeadline, withRewards, msg.sender);
    }

    /// @notice An admitted entry router deposits its own collateral and assigns the complete right to its user.
    function listFor(
        Collateral calldata c,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint40 fundingDeadline,
        bool withRewards,
        address borrower
    ) external nonReentrant returns (uint256) {
        if (!REGISTRY.isRouter(msg.sender)) revert NotAuthorized();
        _checkRecipient(borrower);
        return _list(c, principal, cap, term, fundingDeadline, withRewards, borrower);
    }

    function _list(
        Collateral calldata c,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint40 fundingDeadline,
        bool withRewards,
        address borrower
    ) private returns (uint256 id) {
        if (REGISTRY.newDealsPaused()) revert Paused();
        if (principal < UNITS || cap < principal || !REGISTRY.isTermAllowed(term)) revert InvalidTerms();
        if (fundingDeadline <= block.timestamp || fundingDeadline > block.timestamp + MAX_FUNDING_WINDOW) {
            revert Deadline();
        }
        (bytes32 key, uint256 exposure, uint256 maximum) = _validate(c);
        if (openExposure[key] + exposure > maximum) revert ExposureCap();
        openExposure[key] += exposure;
        id = ++loanCount;
        V2Loan storage l = _loans[id];
        l.originator = borrower;
        l.token = c.token;
        l.collateral = c.amountOrTokenId;
        l.kind = c.kind;
        l.state = V2State.FUNDING;
        l.principal = principal;
        l.cap = cap;
        l.term = term;
        l.fundingDeadline = fundingDeadline;
        l.exposureKey = key;
        l.exposureAmount = exposure;
        // A uint128 times a uint16 is below 2^144, so the product cannot overflow; the registry bounds the fee.
        l.originationFee = uint128(uint256(principal) * REGISTRY.feeBps() / 10_000);
        if (withRewards) {
            (l.borrowerReward, l.lenderReward) = address(BRIDGE) == address(0)
                ? REGISTRY.quoteRewards(term, l.originationFee)
                : BRIDGE.quote(term, l.originationFee);
        }
        l.account = Clones.clone(ACCOUNT_IMPLEMENTATION);
        GageV2TokenCollateralAccount(payable(l.account)).initialize(c);
        _pullExact(IERC20(c.token), msg.sender, l.account, c.amountOrTokenId);
        _safeMint(borrower, id);
        emit Listed(id, borrower, l.account, c, principal, cap, term, fundingDeadline);
    }

    /// @notice Buy 1, 2, 3 or 4 unfilled lender units; activate only on the final unit.
    function fund(uint256 id, uint8 units) external nonReentrant {
        _fund(id, units, msg.sender);
    }

    /// @notice An admitted entry router supplies USDG and records its user as the lender.
    function fundFor(uint256 id, uint8 units, address lender) external nonReentrant {
        if (!REGISTRY.isRouter(msg.sender)) revert NotAuthorized();
        _checkRecipient(lender);
        _fund(id, units, lender);
    }

    function _fund(uint256 id, uint8 units, address lender) private {
        // The registry's pause, then the funder gate, so a bound engine lends only through the gate's accounts (the
        // ledger checks buyers of listed quarters the same way). The ledger's revert data is passed through unchanged.
        REWARDS.requireFunding(lender);
        V2Loan storage l = _loans[id];
        if (l.state != V2State.FUNDING) revert WrongState();
        if (block.timestamp >= l.fundingDeadline) revert Deadline();
        if (units == 0 || units > UNITS - l.filled) revert InvalidUnits();
        uint256 amount;
        uint8 remaining = units;
        for (uint8 i; i < UNITS && remaining != 0; ++i) {
            if (_lenders[id][i] == address(0)) {
                _lenders[id][i] = lender;
                amount += unitSlice(l.principal, i);
                --remaining;
            }
        }
        l.filled += units;
        _pullExact(USDG, msg.sender, address(this), amount);
        emit UnitsFunded(id, lender, units, amount, l.filled);
        if (l.filled == UNITS) _activate(id, l);
    }

    /// @notice Withdraw all of your units before activation, crediting cash for independent withdrawal.
    function withdrawCommitment(uint256 id) external nonReentrant {
        V2Loan storage l = _loans[id];
        if (l.state != V2State.FUNDING) revert WrongState();
        uint256 amount;
        uint8 count;
        for (uint8 i; i < UNITS; ++i) {
            if (_lenders[id][i] == msg.sender) {
                amount += unitSlice(l.principal, i);
                delete _lenders[id][i];
                ++count;
            }
        }
        if (count == 0) revert NothingToClaim();
        l.filled -= count;
        cashCredit[msg.sender] += amount;
        emit CommitmentWithdrawn(id, msg.sender, count, amount);
    }

    /// @notice Borrower may cancel partial funding; after its deadline anyone may release all refunds.
    function cancelFunding(uint256 id) external nonReentrant {
        V2Loan storage l = _loans[id];
        if (l.state != V2State.FUNDING) revert WrongState();
        if (msg.sender != l.originator && block.timestamp < l.fundingDeadline) revert NotAuthorized();
        for (uint8 i; i < UNITS; ++i) {
            address lender = _lenders[id][i];
            if (lender != address(0)) {
                cashCredit[lender] += unitSlice(l.principal, i);
                delete _lenders[id][i];
            }
        }
        l.filled = 0;
        l.state = V2State.CANCELLED;
        l.closedAt = uint40(block.timestamp);
        l.collateralBeneficiary = l.originator;
        openExposure[l.exposureKey] -= l.exposureAmount;
        _burn(id);
        emit Closed(id, l.state, l.originator, l.closedAt);
    }

    /// @notice Pay the entire recorded cap before term + GRACE and assign whole collateral to recipient.
    /// @dev ERC721 approval permits exercise. Normal transfers are deliberately restricted to buy().
    ///      Reverts from the second finalizeDefault opens: a loan is repaid on time or it is defaulted, never raced.
    function reclaim(uint256 id, address recipient) external nonReentrant {
        V2Loan storage l = _loans[id];
        _requireSaleable(l);
        if (!_isAuthorized(ownerOf(id), msg.sender, id)) revert NotAuthorized();
        _checkRecipient(recipient);
        _pullExact(USDG, msg.sender, address(this), l.cap);
        if (address(BRIDGE) != address(0)) {
            USDG.forceApprove(address(BRIDGE), l.cap);
            BRIDGE.repay(id);
        }
        _close(id, l, V2State.REPAID);
        l.collateralBeneficiary = recipient;
        for (uint8 i; i < UNITS; ++i) {
            cashCredit[_lenders[id][i]] += unitSlice(l.cap, i);
        }
        emit Closed(id, l.state, recipient, l.closedAt);
    }

    /// @notice Finalize lender entitlement once term + GRACE has passed. Permissionless; repayment is closed from
    ///         that same second, so the outcome is fixed by the clock and not by who transacts first.
    function finalizeDefault(uint256 id) external nonReentrant {
        V2Loan storage l = _loans[id];
        if (l.state != V2State.ACTIVE) revert WrongState();
        if (block.timestamp < _windowEnd(l)) revert Deadline();
        if (address(BRIDGE) != address(0)) BRIDGE.finalizeDefault(id);
        _close(id, l, V2State.DEFAULTED);
        emit Closed(id, l.state, address(0), l.closedAt);
    }

    /// @notice Pull the intact original collateral after cancellation or full repayment.
    /// @dev `collateralBeneficiary` is written only on entering REPAID (`reclaim`) or CANCELLED (`cancelFunding`), both
    /// terminal, so the caller check alone gates the state.
    function withdrawCollateral(uint256 id, address recipient) external nonReentrant {
        V2Loan storage l = _loans[id];
        if (msg.sender != l.collateralBeneficiary) revert NotAuthorized();
        _checkRecipient(recipient);
        GageV2TokenCollateralAccount(payable(l.account)).release(recipient);
        emit CollateralWithdrawn(id, recipient);
    }

    /// @notice A lender records a defaulted loan's collateral for its unit holders, once, with a minimum.
    function recoverDefault(uint256 id, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        returns (address[2] memory tokens, uint256[2] memory amounts)
    {
        V2Loan storage l = _loans[id];
        if (l.state != V2State.DEFAULTED) revert WrongState();
        // A total of UNITS splits one raw unit to each quarter, so this counts the caller's quarters. It must stay a
        // multiple of UNITS: a total of 1 would count slot 0 only.
        if (_lenderShare(id, msg.sender, UNITS) == 0) revert NotAuthorized();
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_EXECUTION_WINDOW) revert Deadline();
        (tokens, amounts) = GageV2TokenCollateralAccount(payable(l.account)).recover(min0, min1, deadline);
        emit DefaultRecovered(id, tokens, amounts);
    }

    /// @notice Withdraw your full proportional share of one recovered underlying asset, independently of other lenders.
    /// @dev Pays `claimableRecovery`: reverts `NothingToClaim` when it is zero (loan not defaulted or not yet
    /// recovered, asset index above 1, already withdrawn, or no quarter held).
    function withdrawRecovery(uint256 id, uint8 asset, address recipient) external nonReentrant {
        uint256 amount = claimableRecovery(id, asset, msg.sender);
        if (amount == 0) revert NothingToClaim();
        _checkRecipient(recipient);
        _recoveryClaimed[id][asset][msg.sender] = true;
        GageV2TokenCollateralAccount(payable(_loans[id].account)).payRecovery(asset, recipient, amount);
        emit RecoveryWithdrawn(id, msg.sender, asset, recipient, amount);
    }

    /// @notice Post an on-chain USDG ask with a snapshotted protocol trading fee, only if that fee is no higher than
    ///         the seller approved; `type(uint16).max` accepts any fee within the registry bound.
    function setAskWithMaxFee(uint256 id, uint128 price, uint40 deadline, uint16 maxFeeBps) external nonReentrant {
        V2Loan storage l = _loans[id];
        _requireSaleable(l);
        if (ownerOf(id) != msg.sender) revert NotAuthorized();
        if (price == 0 || deadline <= block.timestamp || deadline > _windowEnd(l)) {
            revert Deadline();
        }
        uint256 nonce = ++_nonces[id];
        uint16 feeBps = REGISTRY.tradeFeeBps();
        if (feeBps > maxFeeBps) revert StaleAsk();
        _asks[id] = V2Ask(price, deadline, feeBps, nonce);
        emit AskPosted(id, msg.sender, price, deadline, feeBps, nonce);
    }

    /// @notice Invalidate an existing ask and its expected nonce.
    function cancelAsk(uint256 id) external nonReentrant {
        if (ownerOf(id) != msg.sender) revert NotAuthorized();
        delete _asks[id];
        emit AskCancelled(id, ++_nonces[id]);
    }

    /// @notice Buy a whole reclaim right. Earned rewards stay with its seller, even if not yet withdrawn.
    function buy(uint256 id, address seller, uint256 nonce, uint128 price, uint16 maxFeeBps, address recipient)
        external
        nonReentrant
    {
        V2Loan storage l = _loans[id];
        _requireSaleable(l);
        _checkRecipient(recipient);
        V2Ask memory ask = _asks[id];
        if (
            seller != ownerOf(id) || ask.nonce != nonce || ask.price != price || price == 0
                || block.timestamp >= ask.deadline || ask.feeBps > maxFeeBps
        ) revert StaleAsk();
        REWARDS.transferRight(id, recipient);
        delete _asks[id];
        ++_nonces[id];
        uint256 fee = uint256(price) * ask.feeBps / 10_000;
        _pullExact(USDG, msg.sender, address(this), price);
        cashCredit[seller] += price - fee;
        cashCredit[FEE_RECIPIENT] += fee;
        // The only owner-to-owner move: `_safeTransfer` bypasses the `transferFrom` override below. The event comes
        // first so that nothing is logged after the recipient's `onERC721Received` callback.
        emit RightSold(id, seller, msg.sender, recipient, price, fee, nonce);
        _safeTransfer(seller, recipient, id);
    }

    /// @notice Offer selected quarters as one bundle. Posting never escrows or changes their entitlements.
    function setLenderAsk(uint256 id, uint8 slots, uint128 price, uint40 deadline, uint16 maxFeeBps)
        external
        nonReentrant
    {
        if (_loans[id].state != V2State.ACTIVE) revert WrongState();
        if (slots == 0 || slots > 15) revert InvalidUnits();
        for (uint8 i; i < UNITS; ++i) {
            if (slots & (1 << i) != 0 && _lenders[id][i] != msg.sender) revert NotAuthorized();
        }
        // An ask posted while the loan can be repaid expires with that window (D162): its price was set for a repayment
        // claim. After the window the quarter is a recovery claim and may be offered afresh until finalization.
        uint256 windowEnd = _windowEnd(_loans[id]);
        if (price == 0 || deadline <= block.timestamp || (block.timestamp < windowEnd && deadline > windowEnd)) {
            revert Deadline();
        }
        uint16 feeBps = REGISTRY.tradeFeeBps();
        if (feeBps > maxFeeBps) revert StaleAsk();
        uint256 nonce = ++_lenderNonces[id][msg.sender];
        _lenderAsks[id][msg.sender] = V2LenderAsk(msg.sender, slots, price, deadline, feeBps, nonce);
        emit LenderAskPosted(id, msg.sender, slots, price, deadline, feeBps, nonce);
    }

    /// @notice Pay one ask's bundle price once and deliver each of its quarters to its own recipient, with that
    /// quarter's repayment, default recovery and future reward rights. One nonce, one trade fee on the whole price.
    /// This is the only lender sale: on a vault-only core (D47) the lenders are Intent vaults, whose one ask exists
    /// only inside their own market's sale, so no standing ask is ever left to cancel.
    /// @dev Consumes the seller's one ask and moves each selected quarter straight to its final recipient; the ask's
    /// fields equal the purchase's once checked. The rewards contract validates every recipient, bounds each quarter's
    /// remaining reward by `minRewards` and checkpoints the seller's earned rewards quarter by quarter. No state check
    /// here: the ledger's `transferLenders` refuses unless the loan's allocation is open, which holds exactly while
    /// the loan is ACTIVE (opened in `_activate`, closed in `_close`).
    function buyLenderSplit(uint256 id, V2LenderSplit calldata purchase) external nonReentrant {
        address seller = purchase.seller;
        V2LenderAsk memory ask = _lenderAsks[id][seller];
        if (
            ask.price == 0 || ask.price != purchase.price || ask.nonce != purchase.nonce || ask.slots != purchase.slots
                || ask.feeBps > purchase.maxFeeBps || block.timestamp >= ask.deadline
        ) {
            revert StaleAsk();
        }
        delete _lenderAsks[id][seller];
        ++_lenderNonces[id][seller];
        REWARDS.transferLenders(id, seller, ask.slots, purchase.recipients, purchase.minRewards);
        for (uint8 i; i < UNITS; ++i) {
            if (ask.slots & (1 << i) != 0) _lenders[id][i] = purchase.recipients[i];
        }
        uint256 fee = uint256(ask.price) * ask.feeBps / 10_000;
        _pullExact(USDG, msg.sender, address(this), ask.price);
        cashCredit[seller] += ask.price - fee;
        cashCredit[FEE_RECIPIENT] += fee;
        emit LenderSplitSold(id, seller, msg.sender, ask.slots, ask.price, fee, ask.nonce, purchase.recipients);
    }

    /// @notice A lender's current ask, or an empty one. An Intent vault's ask exists only inside its market's sale.
    function getLenderAsk(uint256 id, address seller) external view returns (V2LenderAsk memory) {
        return _lenderAsks[id][seller];
    }

    /// @notice Withdraw all your USDG credit to a chosen recipient.
    function withdrawUSDG(address recipient) external nonReentrant {
        _withdrawUSDG(msg.sender, recipient);
    }

    /// @notice Permissionlessly deliver an account's credit to that same account, including the existing fee router.
    function withdrawUSDGFor(address account) external nonReentrant {
        _withdrawUSDG(account, account);
    }

    /// @notice Complete loan record including immutable economics and collateral account.
    function getLoan(uint256 id) external view returns (V2Loan memory) {
        return _loans[id];
    }

    /// @notice Current time capped at repayment, for external accrual schedules with their own maturity cap.
    /// @dev Read only the repayment state and timestamp, avoiding a full loan copy on every share-price read.
    function accrualEnd(uint256 id) external view returns (uint256) {
        V2Loan storage l = _loans[id];
        return l.state == V2State.REPAID ? l.closedAt : block.timestamp;
    }
    /// @notice Four fixed lender slots; empty slots are zero before activation.

    function lenders(uint256 id) external view returns (address[4] memory) {
        return _lenders[id];
    }
    /// @notice Current on-chain sale quote.

    function getAsk(uint256 id) external view returns (V2Ask memory) {
        return _asks[id];
    }

    /// @notice One lender's remaining entitlement to a recovered asset, including deterministic quarter rounding.
    function claimableRecovery(uint256 id, uint8 asset, address holder) public view returns (uint256) {
        V2Loan storage l = _loans[id];
        if (l.state != V2State.DEFAULTED || asset > 1 || _recoveryClaimed[id][asset][holder]) return 0;
        // Before recovery the recorded amounts are zero, so the share is zero.
        return _lenderShare(id, holder, GageV2TokenCollateralAccount(payable(l.account)).recoveryAmounts(asset));
    }

    function _activate(uint256 id, V2Loan storage l) private {
        if (!REGISTRY.isTermAllowed(l.term)) revert InvalidTerms();
        (bytes32 key, uint256 exposure, uint256 maximum) = _validate(Collateral(l.kind, l.token, l.collateral));
        if (key != l.exposureKey || exposure != l.exposureAmount || openExposure[key] > maximum) revert ExposureCap();
        if (address(BRIDGE) != address(0)) {
            USDG.forceApprove(address(BRIDGE), l.principal);
            (uint128 borrowerReward, uint128 lenderReward) =
                BRIDGE.open(id, l.account, l.principal, l.cap, l.term, l.originationFee);
            if (borrowerReward < l.borrowerReward || lenderReward < l.lenderReward) revert InvalidTerms();
            l.borrowerReward = borrowerReward;
            l.lenderReward = lenderReward;
            // V1 already credited this fee to its existing floor fee route and never pays it to the core, so the core
            // does not charge it twice.
        } else {
            cashCredit[FEE_RECIPIENT] += l.originationFee;
        }
        REWARDS.activate(id, l.originator, _lenders[id], l.term, l.borrowerReward, l.lenderReward);
        l.state = V2State.ACTIVE;
        l.fundedAt = uint40(block.timestamp);
        cashCredit[l.originator] += l.principal - l.originationFee;
        emit Activated(id, l.fundedAt, l.originationFee, l.borrowerReward, l.lenderReward);
    }

    function _close(uint256 id, V2Loan storage l, V2State state) private {
        l.closedAt = uint40(block.timestamp);
        REWARDS.close(id);
        l.state = state;
        delete _asks[id];
        ++_nonces[id];
        openExposure[l.exposureKey] -= l.exposureAmount;
        _burn(id);
    }

    /// @dev Admission of an allowed token within the registry's per-loan bounds; any other kind is refused. Returns the
    /// exposure bucket, the raw amount and the bucket's aggregate ceiling.
    function _validate(Collateral memory c) private view returns (bytes32 key, uint256 raw, uint256 maximum) {
        if (c.kind != Kind.ERC20 || c.token == address(0) || c.token == address(SGAGE)) revert InvalidCollateral();
        ICollateralRegistry.ERC20Config memory cfg = REGISTRY.getERC20Config(c.token);
        raw = c.amountOrTokenId;
        if (!cfg.allowed || raw < cfg.minAmount || raw > cfg.maxDealRaw) revert InvalidCollateral();
        return (keccak256(abi.encode(c.kind, c.token)), raw, cfg.maxOpenRaw);
    }

    function _lenderShare(uint256 id, address account, uint256 total) private view returns (uint256 amount) {
        for (uint8 i; i < UNITS; ++i) {
            if (_lenders[id][i] == account) amount += unitSlice(total, i);
        }
    }

    /// @dev The second repayment closes and default finalization opens.
    function _windowEnd(V2Loan storage l) private view returns (uint256) {
        return uint256(l.fundedAt) + l.term + GRACE;
    }

    /// @dev ACTIVE and before the window end: when the reclaim right can be sold or exercised.
    function _requireSaleable(V2Loan storage l) private view {
        if (l.state != V2State.ACTIVE) revert WrongState();
        if (block.timestamp >= _windowEnd(l)) revert Deadline();
    }

    function _withdrawUSDG(address account, address recipient) private {
        _checkRecipient(recipient);
        uint256 amount = cashCredit[account];
        if (amount == 0) revert NothingToClaim();
        delete cashCredit[account];
        USDG.safeTransfer(recipient, amount);
    }

    function _pullExact(IERC20 token, address from, address to, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        if (token.balanceOf(to) - beforeBalance != amount) revert ExactTransferRequired();
    }

    function _checkRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    }

    /// @notice Reclaim rights carry no metadata: the empty base URI makes every existing right's URI empty.
    /// @dev Identical to the inherited result with no base URI; drops the unreachable decimal formatting.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return "";
    }

    /// @notice Raw transfers always revert: a right moves only by mint, burn and `buy`.
    /// @dev Both `safeTransferFrom` overloads route through `transferFrom` in OpenZeppelin 5.7, so this one override
    /// blocks all three entry points; `buy` moves the right with the internal `_safeTransfer`.
    function transferFrom(address, address, uint256) public pure override {
        revert UseMarketplace();
    }
}
