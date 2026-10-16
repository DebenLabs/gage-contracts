// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State, V2LenderAsk, V2LenderSplit} from "../v2/V2Types.sol";
import {IntentFactory} from "./IntentFactory.sol";
import {IntentVault} from "./IntentVault.sol";

/// @notice One immutable vault's curator-posted sales. Listing never transfers or escrows lender rights.
/// @dev There is no standing core ask: only the vault's atomic execution can create and consume one. A buyer
/// cannot bypass its accounting by filling on the core. No owner, upgrade, arbitrary call or custody of positions.
/// A sale delivers each listed quarter to its own recipient (`buySplit`, S9; one recipient may take them all): the
/// one ask is consumed once and its trade fee charged once on the whole price.
contract IntentLenderMarket is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Ask {
        uint128 price;
        uint40 deadline;
        uint16 maxFeeBps;
        uint8 slots;
        uint64 nonce;
    }

    /// @notice The vault that deployed this market. The market calls only its `lenderSaleSlots` and
    /// `executeLenderSale`, and accepts `complete` only from it.
    IntentVault public immutable SELLER;
    GageV2Vault public immutable CORE;
    IERC20 public immutable USDG;
    address public immutable CURATOR;
    mapping(uint256 => Ask) public asks;
    mapping(uint256 => uint64) public nonces;

    event Listed(uint256 indexed id, uint64 nonce, uint8 slots, uint128 price, uint40 deadline, uint16 maxFeeBps);
    event Cancelled(uint256 indexed id, uint64 nonce);
    /// @dev `recipients[i]` took quarter i of `slots`; entries outside `slots` mean nothing.
    event Sold(
        uint256 indexed id,
        uint64 nonce,
        address indexed buyer,
        uint8 slots,
        uint256 price,
        uint256 proceeds,
        address[4] recipients
    );

    error NotCurator();
    error InvalidAsk();
    error StaleAsk();
    error TransferAmountMismatch();
    error UnbookedRecipient();

    constructor(address core, address curator) {
        SELLER = IntentVault(msg.sender);
        CORE = GageV2Vault(core);
        USDG = CORE.USDG();
        CURATOR = curator;
    }

    /// @notice List the entire holding recorded by the vault; repricing invalidates the previous nonce.
    /// @dev No sale at/after maturity, even while the core still calls the position ACTIVE.
    function list(uint256 id, uint128 price, uint40 deadline, uint16 maxFeeBps) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        V2Loan memory loan = CORE.getLoan(id);
        uint8 slots = SELLER.lenderSaleSlots(id);
        if (
            slots == 0 || price == 0 || loan.state != V2State.ACTIVE || deadline <= block.timestamp
                || deadline > uint256(loan.fundedAt) + loan.term || CORE.REGISTRY().tradeFeeBps() > maxFeeBps
        ) revert InvalidAsk();
        uint64 nonce = ++nonces[id];
        asks[id] = Ask(price, deadline, maxFeeBps, slots, nonce);
        emit Listed(id, nonce, slots, price, deadline, maxFeeBps);
    }

    /// @notice Cancellation stays available after repayment, expiry or default.
    function cancel(uint256 id) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (asks[id].price == 0) revert InvalidAsk();
        delete asks[id];
        emit Cancelled(id, ++nonces[id]);
    }

    /// @notice Pay the reviewed price once and deliver each listed quarter to its own recipient, or revert the entire
    /// sale (S9). Direct buyers must receive their own listed quarters; the fill router may name vault recipients
    /// after booking their purchases. `minRewards[i]` bounds quarter i's remaining future reward in the core ledger.
    function buySplit(
        uint256 id,
        uint64 nonce,
        uint128 price,
        address[4] calldata recipients,
        uint128[4] calldata minRewards
    ) external nonReentrant returns (uint256 proceeds) {
        Ask memory ask = asks[id];
        if (ask.price == 0 || ask.price != price || ask.nonce != nonce || block.timestamp >= ask.deadline) {
            revert StaleAsk();
        }
        // Only the current fill router can split a purchase among other recipients: it books each vault first.
        // A direct buyer may take listed quarters for itself, subject to the core's funder gate, but cannot assign
        // unrecorded rights to another vault (including one admitted by a different core gate).
        IntentFactory source = IntentFactory(SELLER.PROTOCOL_SOURCE());
        bool fromRouter = msg.sender == source.fillRouter();
        // The core also checks recipients as quarters move: its ledger (`transferLenders`) refuses a listed quarter
        // going to zero, the core or the seller vault (`InvalidTransfer`), and the bound funder gate refuses this
        // market, which `IntentFactory.isVault` never names (`NotFunder`, D42/D47).
        for (uint8 i; i < 4; ++i) {
            if (ask.slots & (1 << i) != 0 && !fromRouter && recipients[i] != msg.sender) {
                revert UnbookedRecipient();
            }
            _stash(i, recipients[i], minRewards[i]);
        }
        delete asks[id];
        ++nonces[id];
        uint256 before_ = USDG.balanceOf(address(this));
        USDG.safeTransferFrom(msg.sender, address(this), price);
        if (USDG.balanceOf(address(this)) - before_ != price) revert TransferAmountMismatch();
        USDG.forceApprove(address(CORE), price);
        proceeds = SELLER.executeLenderSale(id, ask.slots, price, ask.deadline, ask.maxFeeBps);
        // Inside `complete`, the core's `buyLenderSplit` pulls exactly the ask price the vault just posted from
        // `price` (`_pullExact`), so the approval is used up and the balance is back at `before_` (USDG transfers
        // exactly, section 2 of the scope).
        emit Sold(id, nonce, msg.sender, ask.slots, price, proceeds, recipients);
    }

    /// @dev Called back only by the seller while its accounting lock and this market's `buySplit` lock are held. The
    /// recipients are the ones the buy in progress stashed, in this transaction only. No state or maturity check is
    /// needed here. ACTIVE: the seller's `executeLenderSale` calls the core's `setLenderAsk`, which requires it, just
    /// before this call in the same locked frame (only views run in between); the core's `buyLenderSplit` makes no
    /// state check of its own, and its ledger's `transferLenders` refuses a loan whose allocation was never opened or
    /// is already closed (`InvalidTransfer`). Maturity: now < ask deadline <= maturity because `list` bounds the
    /// deadline to maturity and `buySplit` requires now < deadline. A change that reorders `executeLenderSale`, relaxes
    /// the ledger's open-allocation check or relaxes `list`'s deadline bound must restore the check here.
    function complete(uint256 id) external returns (uint256 proceeds, address token, uint40 maturity) {
        if (msg.sender != address(SELLER)) revert NotCurator();
        V2Loan memory loan = CORE.getLoan(id);
        maturity = uint40(uint256(loan.fundedAt) + loan.term);
        token = loan.token;
        V2LenderAsk memory ask = CORE.getLenderAsk(id, msg.sender);
        address[4] memory recipients;
        uint128[4] memory minRewards;
        for (uint8 i; i < 4; ++i) {
            (recipients[i], minRewards[i]) = _stashed(i);
        }
        CORE.buyLenderSplit(
            id, V2LenderSplit(msg.sender, ask.slots, ask.price, ask.feeBps, ask.nonce, recipients, minRewards)
        );
        proceeds = uint256(ask.price) - uint256(ask.price) * ask.feeBps / 10_000;
        // Collection must succeed in this transaction. Existing cash/donations cannot cover an unpaid sale.
        uint256 credit = CORE.cashCredit(msg.sender);
        uint256 before_ = USDG.balanceOf(msg.sender);
        CORE.withdrawUSDGFor(msg.sender);
        if (credit < proceeds || USDG.balanceOf(msg.sender) - before_ != credit) revert TransferAmountMismatch();
    }

    /// @dev Transient slots hold quarter i's recipient and its reward bound, for the buy in progress only.
    function _stash(uint8 i, address recipient, uint128 minReward) private {
        assembly ("memory-safe") {
            tstore(add(0x5ec0, i), recipient)
            tstore(add(0x5ec4, i), minReward)
        }
    }

    function _stashed(uint8 i) private view returns (address recipient, uint128 minReward) {
        assembly ("memory-safe") {
            recipient := tload(add(0x5ec0, i))
            minReward := tload(add(0x5ec4, i))
        }
    }
}
