// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IIntentExitDesk} from "../interfaces/IIntentExitDesk.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State, V2LenderAsk, V2LenderSplit} from "../v2/V2Types.sol";
import {IntentFactory} from "./IntentFactory.sol";
import {IntentVault} from "./IntentVault.sol";

/// @notice One immutable vault's curator-posted sales. Listing never transfers or escrows lender rights.
/// @dev There is no standing core ask: only the vault's atomic execution can create and consume one. A buyer
/// cannot bypass its accounting by filling on the core. No owner, upgrade, arbitrary call or custody of positions.
/// A sale delivers each listed quarter to its own recipient (`buySplit`, one recipient may take them all): the
/// one ask is consumed once and its trade fee charged once on the whole price.
/// A listing names no price: it falls every second from its listing. The seller's holders keep `keepBps`
/// of the interest still to come on top of the position's book value, 99% at listing and 16.5 basis points less each
/// second, none from `AUCTION_SPAN` on; the vault refuses any price that books less (`SaleBelowBook`). A buyer pays any
/// price at or above that floor; the earliest buyer wins.
/// Only an exit falls to book. The curator's own listing stops at `CURATOR_FLOOR_BPS`, Pashov L-01's half.
/// The factory's exit desk lists for a holder leaving the vault: its floor is the desk's (`floorBps`), none for the
/// part of the holding the leaver's shortfall covers, the listing ends `EXIT_GRACE` after the fall, and the desk redeems
/// the leaver's shares in the sale's own transaction, or the sale reverts. While it is live the curator can neither
/// replace nor cancel it.
contract IntentLenderMarket is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Ask {
        /// @dev When the price started falling; zero when nothing is listed.
        uint40 listedAt;
        uint40 deadline;
        uint16 maxFeeBps;
        uint8 slots;
        uint64 nonce;
        /// @dev Listed by the factory's exit desk for a holder leaving the vault.
        bool exit;
    }

    /// @notice The vault that deployed this market. The market calls only its `lenderSaleSlots` and
    /// `executeLenderSale`, and accepts `complete` only from it.
    IntentVault public immutable SELLER;
    GageV2Vault public immutable CORE;
    IERC20 public immutable USDG;
    address public immutable CURATOR;
    /// @notice The factory that created the seller, its `PROTOCOL_SOURCE`: it names the fill router and the exit desk.
    IntentFactory public immutable FACTORY;
    /// @notice The share of the interest still to come the seller's holders keep at listing, in basis points.
    uint256 public constant START_KEEP_BPS = 9900;
    /// @notice How long the price takes to fall from `START_KEEP_BPS` to book value.
    uint256 public constant AUCTION_SPAN = 10 minutes;
    /// @notice The share of the interest still to come a curator's listing keeps above book however long it stands.
    uint256 public constant CURATOR_FLOOR_BPS = 5000;
    /// @notice How long an exit listing stays open after its price stops falling; it is listed again if unsold.
    uint256 public constant EXIT_GRACE = 1 minutes;
    mapping(uint256 => Ask) public asks;
    mapping(uint256 => uint64) public nonces;

    /// @notice A listing whose price falls from `listedAt`; named apart from the fixed-price `Listed` of
    /// earlier markets, so one indexer follows both.
    event AuctionListed(
        uint256 indexed id, uint64 nonce, uint8 slots, uint40 listedAt, uint40 deadline, uint16 maxFeeBps, bool exit
    );
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
    error ExitListed();
    error InvalidAsk();
    error StaleAsk();
    error TransferAmountMismatch();
    error UnbookedRecipient();

    constructor(address core, address curator, address factory) {
        SELLER = IntentVault(msg.sender);
        CORE = GageV2Vault(core);
        USDG = CORE.USDG();
        CURATOR = curator;
        FACTORY = IntentFactory(factory);
    }

    /// @notice List the entire holding recorded by the vault; its price starts falling now. Listing again restarts
    /// the fall and invalidates the previous nonce. The curator's listing stops at `CURATOR_FLOOR_BPS`, and cannot
    /// replace a live exit listing (`ExitListed`). The factory's exit desk lists for a holder leaving the vault: its
    /// price falls to the desk's floor, it ends `EXIT_GRACE` after the fall whatever `deadline` says, and it replaces
    /// any listing of the holding.
    /// @dev No sale at/after maturity, even while the core still calls the position ACTIVE.
    /// @return nonce The new listing's nonce.
    function list(uint256 id, uint40 deadline, uint16 maxFeeBps) external nonReentrant returns (uint64 nonce) {
        bool exit = msg.sender == _exitDesk();
        if (exit) deadline = uint40(block.timestamp + AUCTION_SPAN + EXIT_GRACE);
        else _requireCurator(id);
        V2Loan memory loan = CORE.getLoan(id);
        uint8 slots = SELLER.lenderSaleSlots(id);
        if (
            slots == 0 || loan.state != V2State.ACTIVE || deadline <= block.timestamp
                || deadline > uint256(loan.fundedAt) + loan.term || CORE.REGISTRY().tradeFeeBps() > maxFeeBps
        ) revert InvalidAsk();
        nonce = ++nonces[id];
        asks[id] = Ask(uint40(block.timestamp), deadline, maxFeeBps, slots, nonce, exit);
        emit AuctionListed(id, nonce, slots, uint40(block.timestamp), deadline, maxFeeBps, exit);
    }

    /// @notice The share of the interest still to come, in basis points, that a sale of listing `id` must leave the
    /// seller's holders above book value now: `START_KEEP_BPS` at listing, falling every second to zero at
    /// `AUCTION_SPAN`, never below the listing's floor: `CURATOR_FLOOR_BPS` for the curator's listing, the exit desk's
    /// live `floorBps` for an exit. Zero for no listing.
    function keepBps(uint256 id) public view returns (uint256) {
        Ask storage ask = asks[id];
        uint256 listedAt = ask.listedAt;
        if (listedAt == 0) return 0;
        uint256 elapsed = block.timestamp - listedAt;
        uint256 keep = elapsed >= AUCTION_SPAN ? 0 : START_KEEP_BPS - START_KEEP_BPS * elapsed / AUCTION_SPAN;
        uint256 floor = ask.exit ? IIntentExitDesk(_exitDesk()).floorBps(address(SELLER), id) : CURATOR_FLOOR_BPS;
        return keep > floor ? keep : floor;
    }

    /// @notice Cancellation stays available after repayment, expiry or default; a live exit listing is not the curator's
    /// to cancel (`ExitListed`). The desk never cancels one: an exit it drops has no leaver to pay, so it cannot sell.
    function cancel(uint256 id) external nonReentrant {
        _requireCurator(id);
        if (asks[id].listedAt == 0) revert InvalidAsk();
        delete asks[id];
        emit Cancelled(id, ++nonces[id]);
    }

    /// @notice Pay `price` once and deliver each listed quarter to its own recipient, or revert the entire sale.
    /// The price is the buyer's: the seller's vault refuses one that books less than the falling floor now. Direct
    /// buyers must receive their own listed quarters; the fill router may name vault recipients after
    /// booking their purchases. `minRewards[i]` bounds quarter i's remaining future reward in the core ledger.
    function buySplit(
        uint256 id,
        uint64 nonce,
        uint128 price,
        address[4] calldata recipients,
        uint128[4] calldata minRewards
    ) external nonReentrant returns (uint256 proceeds) {
        Ask memory ask = asks[id];
        if (ask.listedAt == 0 || price == 0 || ask.nonce != nonce || block.timestamp >= ask.deadline) {
            revert StaleAsk();
        }
        uint256 keep = keepBps(id);
        // Only the current fill router can split a purchase among other recipients: it books each vault first.
        // A direct buyer may take listed quarters for itself, subject to the core's funder gate, but cannot assign
        // unrecorded rights to another vault (including one admitted by a different core gate).
        bool fromRouter = msg.sender == FACTORY.fillRouter();
        // The core also checks recipients as quarters move: its ledger (`transferLenders`) refuses a listed quarter
        // going to zero, the core or the seller vault (`InvalidTransfer`), and the bound funder gate refuses this
        // market, which `IntentFactory.isVault` never names (`NotFunder`).
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
        proceeds = SELLER.executeLenderSale(id, ask.slots, price, ask.deadline, ask.maxFeeBps, keep);
        // Inside `complete`, the core's `buyLenderSplit` pulls exactly the ask price the vault just posted from
        // `price` (`_pullExact`), so the approval is used up and the balance is back at `before_` (USDG transfers
        // exactly, section 2 of the scope).
        // An exit redeems its leaver now, or the sale reverts: no exit listing sells without the exit behind it.
        if (ask.exit) IIntentExitDesk(_exitDesk()).onSale(id, nonce);
        emit Sold(id, nonce, msg.sender, ask.slots, price, proceeds, recipients);
    }

    /// @dev The curator, and no live exit listing of `id`: that one belongs to the leaver until it ends.
    function _requireCurator(uint256 id) private view {
        if (msg.sender != CURATOR) revert NotCurator();
        Ask storage live = asks[id];
        if (live.exit && block.timestamp < live.deadline) revert ExitListed();
    }

    /// @dev The factory's exit desk as it stands; zero while none is named, which no caller can be.
    function _exitDesk() private view returns (address) {
        return FACTORY.exitDesk();
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
