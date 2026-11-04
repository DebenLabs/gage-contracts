// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IIntentExitDesk} from "../interfaces/IIntentExitDesk.sol";
import {IntentFactory} from "./IntentFactory.sol";
import {IntentLenderMarket} from "./IntentLenderMarket.sol";
import {IntentVault} from "./IntentVault.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";

/// @notice Exit now: the only lister whose listings fall to book, for a holder leaving a vault whose
/// factory names this desk. Self-dealing gains nothing from it, whoever opens both sides of a sale:
/// - **Only an exit lists.** A holder commits shares and approves this desk for them; a listing stands only while those
///   shares are worth more than the vault can pay now (`shortfall`), and its sale redeems them in the sale's own
///   transaction (`onSale`), or the sale reverts. What they pay is the holder's to collect (`withdraw`).
/// - **Only the shortfall falls to book.** The listing's floor (`floorBps`) is none for the part of the holding the
///   shortfall covers and, for the rest, what a listing starts at (`IntentLenderMarket.START_KEEP_BPS`), read again
///   when it sells: a leaver short by a little cannot sell a large holding cheap.
/// - **The leaver pays its own discount**. The floor never falls below what the leaver's committed
///   shares carried of the holding by loan-days (`IntentVaultViews.exitShare`), and the sale's discount below
///   what a listing starts at is recorded against the leaver (`exitDebit`): the earnings claim the sale opens splits as
///   if the holding had sold at the start, less that debit on the leaver's own part. Every other holder keeps its
///   loan-days share of 99% of the interest still to come, and the leaver's share of other loans' interest is never
///   spent on this one.
/// - **Nothing falls for cash on its way.** A record whose outcome only the vault's `settle` books, a loan repaid early
///   above all, counts as lent until then though its cash is the vault's to pay with: while one waits
///   (`pendingSettlements`) the desk lists nothing (`SettlementPending`) and a live listing stops where a listing starts,
///   until anyone settles it. The average below is read again at the sale, so a listing whose holding no
///   longer sits within it stops there too (r13d).
/// - **No more yield per dollar than the vault holds.** A holding is listed only if the interest it has still to earn,
///   per unit of its book value, is at most the vault's own over every open loan (`withinAverage`). Leaving at book,
/// the holder gives up their share of that interest, and a sale can forfeit no more of it than theirs.
/// - **One listing at a time, ending a minute after its fall** (`IntentLenderMarket.EXIT_GRACE`); the holder or an
///   admitted filler lists the next holding once it has sold, ended or passed to another exit.
/// - **A lower floor takes over**. A holding under another exit's live
///   listing is listed for an exit only by taking that listing over as it stands, its nonce, start and end kept, so its
///   price goes on falling; and only while this exit's floor there (`floorOf`) is lower than that of the exit the desk
///   names for it now, or that exit has no shortfall. A leaver that withdrew the approval or the shares, whose exit
///   lapsed, or that cancelled keeps nothing, so a listing nobody can be paid for keeps no exit out. The exit it served
///   names no listing (`ExitDropped`) and may list another holding at once. A sale still pays one leaver: the one the
///   desk names when it sells, whose floor it is.
/// - **What a takeover does to the price**. A takeover compares both floors as its transaction finds the
///   vault, so it never raises the price a listing stood at just before it, nor reverts a plan that cleared then. Cash a
///   deposit brings in and a redemption takes out within that same transaction can lower the shortfall the comparison
///   reads (or zero the displaced exit's) and be gone once it ends, so across the transaction an exit whose floor there
///   is higher can take the listing over and raise its price, and plans signed for it revert. The exit it displaced may
///   then take it back as it stands, its floor the lower again, and gage's keeper does so and buys it in one transaction
///   (`IntentExitRetaker`), so no takeover lands between the two. What the reserve can pay at that instant moves no
///   shortfall.
/// @dev Holds no shares: a committed holder keeps their shares, their sGAGE and their pockets until the sale, and can
/// withdraw the commitment (`cancel`) or the approval at any time before it. It holds only what sales redeemed, credited
/// to each leaver until they collect it: pull, never push, so no leaver's address can stop a sale. No owner, upgrade or
/// arbitrary call. A vault's market trusts this desk only while its factory names it (`IntentFactory.exitDesk`), and the
/// desk lists only on a market that names the vault it was called for as its seller, under that vault's factory.
contract IntentExitDesk is IIntentExitDesk, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice A holder's exit from one vault.
    struct Exit {
        /// @dev The most shares the desk may still redeem for the holder.
        uint256 shares;
        /// @dev The holding listed for it last, and that listing's nonce.
        uint256 id;
        uint64 nonce;
    }

    /// @notice The exit an exit listing serves.
    struct Listing {
        address owner;
        uint64 nonce;
    }

    /// @notice What an exit sale charged its leaver: the sale's discount below what a listing starts at,
    /// paid out of the leaver's own part of the earnings claim the sale opened.
    struct Debit {
        /// @dev The leaver the desk named for the listing when it sold.
        address owner;
        /// @dev In the vault asset's raw units.
        uint96 amount;
    }

    /// @dev IntentVault's interest clock precision.
    uint256 internal constant RATE_PRECISION = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @notice The floor of a curator's listing, `IntentLenderMarket.CURATOR_FLOOR_BPS`: an exit's for the part of its
    /// holding beyond the shortfall.
    uint256 public constant CURATOR_FLOOR_BPS = 5000;
    /// @notice What a listing starts at, `IntentLenderMarket.START_KEEP_BPS`: an exit's floor for the part of its
    /// holding beyond the shortfall, which never falls.
    uint256 public constant START_KEEP_BPS = 9900;
    /// @notice How long a commitment stands: a holder who left another way and came back is never sold out on a
    /// request they forgot. Commit again to go on.
    uint256 public constant EXIT_LIFE = 1 days;

    mapping(IntentVault => mapping(address => Exit)) public exits;
    mapping(IntentVault => mapping(uint256 => Listing)) public listings;
    /// @notice When each holder last committed to leave each vault; their exit lapses `EXIT_LIFE` later.
    mapping(IntentVault => mapping(address => uint256)) public committedAt;
    /// @notice What exit sales redeemed for each leaver, by the vault's asset, until the leaver collects it.
    mapping(address => mapping(address => uint256)) public owed;
    /// @dev By vault and holding: what each exit sale charged its leaver. A sold record is settled for
    /// good, so a holding sells for an exit at most once.
    mapping(IntentVault => mapping(uint256 => Debit)) internal _debits;

    event ExitCommitted(IntentVault indexed vault, address indexed owner, uint256 shares);
    event ExitListed(IntentVault indexed vault, address indexed owner, uint256 indexed id, uint64 nonce);
    event ExitPaid(
        IntentVault indexed vault, address indexed owner, uint256 indexed id, uint256 shares, uint256 assets
    );
    event ExitCancelled(IntentVault indexed vault, address indexed owner);
    /// @notice Exit listing (`id`, `nonce`) no longer serves `owner`'s exit: another exit took it over as it stands (as
    /// designed: a lower floor there, or `owner` had no shortfall). The exit keeps its commitment and may list
    /// another holding, or take this one back where its floor is the lower.
    event ExitDropped(IntentVault indexed vault, address indexed owner, uint256 indexed id, uint64 nonce);
    event Withdrawn(address indexed asset, address indexed owner, uint256 amount);
    /// @notice Exit sale of holding `id` charged its leaver `owner` the sale's discount below what a listing starts at,
    /// `debit`, out of `owner`'s own part of earnings claim `pocketId`.
    event ExitDebited(
        IntentVault indexed vault, address indexed owner, uint256 indexed id, uint256 pocketId, uint256 debit
    );

    error NotDeskVault();
    error NotOwner();
    error NotMarket();
    error InvalidAmount();
    error NoExit();
    error ListingLive();
    error NoShortfall();
    error AboveAverageYield();
    error UnknownListing();
    error NothingToPay();
    error TransferAmountMismatch();
    error SettlementPending();

    /// @notice Commit `shares` to leave `vault` and list holding `id` for them. The caller must have approved this
    /// desk for the shares on the vault; a new commitment replaces the last. `id` zero lists nothing: a holder that
    /// pools others' exits (a rehypo source) raises its commitment while its listing is live, and the listing goes on,
    /// or the holder or a filler lists the next holding. A holding under another exit's live listing is taken over as
    /// it stands, and only by an exit whose floor there is lower than that exit's, or once that exit has no shortfall
    /// (`list`).
    function exitNow(IntentVault vault, uint256 shares, uint256 id) external nonReentrant {
        _requireDeskVault(vault);
        if (shares == 0 || shares > vault.balanceOf(msg.sender) || shares > vault.allowance(msg.sender, address(this)))
        {
            revert InvalidAmount();
        }
        exits[vault][msg.sender].shares = shares;
        committedAt[vault][msg.sender] = block.timestamp;
        emit ExitCommitted(vault, msg.sender, shares);
        if (id != 0) _list(vault, msg.sender, id);
    }

    /// @notice List holding `id` for `owner`'s exit once its last listing sold, ended or passed to another exit: the
    /// owner, or a filler the vault's factory admitted, asked only once the vault is one of the desk's. Under another
    /// exit's live listing of the holding nothing is listed anew: that listing passes to this exit as it stands (its
    /// nonce, start and end), only while this exit's floor there (`floorOf`) is strictly lower than that exit's now, or
    /// that exit has no shortfall (`ListingLive` otherwise), both read as this transaction finds the vault: a takeover
    /// never raises the price the listing stood at just before it, though cash moved within the same transaction can
    /// leave it higher after the transaction than before. The exit it served is dropped (`ExitDropped`). A
    /// cancelled exit's listing has no leaver, and passes to any exit with a shortfall.
    function list(IntentVault vault, address owner, uint256 id) external nonReentrant {
        _requireDeskVault(vault);
        if (msg.sender != owner && !IntentFactory(vault.PROTOCOL_SOURCE()).isFiller(msg.sender)) revert NotOwner();
        _list(vault, owner, id);
    }

    /// @notice Withdraw the caller's exit from `vault`. Its live listing stays in the market until it ends, but with no
    /// leaver behind it its floor is the curator's half and its sale reverts (`onSale`), until another exit with a
    /// shortfall takes it over as it stands (`list`).
    function cancel(IntentVault vault) external nonReentrant {
        Exit memory e = exits[vault][msg.sender];
        if (e.shares == 0) revert NoExit();
        if (listings[vault][e.id].owner == msg.sender) delete listings[vault][e.id];
        delete exits[vault][msg.sender];
        delete committedAt[vault][msg.sender];
        emit ExitCancelled(vault, msg.sender);
    }

    /// @inheritdoc IIntentExitDesk
    function onSale(uint256 id, uint64 nonce) external nonReentrant {
        IntentVault vault = IntentLenderMarket(msg.sender).SELLER();
        if (address(vault.LENDER_MARKET()) != msg.sender) revert NotMarket();
        _requireDeskVault(vault);
        Listing memory l = listings[vault][id];
        if (l.owner == address(0) || l.nonce != nonce) revert UnknownListing();
        delete listings[vault][id];
        Exit storage e = exits[vault][l.owner];
        (e.id, e.nonce) = (0, 0);
        if (_lapsed(vault, l.owner)) revert NothingToPay();
        // Before the redemption, from the earnings claim the sale just opened: no claim on it can come first.
        _debit(vault, id, l.owner);
        uint256 shares = Math.min(Math.min(e.shares, vault.maxRedeem(l.owner)), vault.allowance(l.owner, address(this)));
        // A sole holder's shares maximum is every share. Fewer shares worth more than its assets maximum would
        // take what that maximum keeps behind the shares that stay, which the vault refuses: they stop at the most
        // shares whose redemption pays it (r13d).
        if (shares < vault.totalSupply()) {
            uint256 most = vault.maxWithdraw(l.owner);
            if (vault.previewRedeem(shares) > most) shares = most == 0 ? 0 : vault.previewWithdraw(most + 1) - 1;
        }
        if (shares == 0) revert NothingToPay();
        e.shares -= shares;
        IERC20 asset = IERC20(vault.asset());
        uint256 before_ = asset.balanceOf(address(this));
        uint256 assets = vault.redeem(shares, address(this), l.owner);
        if (asset.balanceOf(address(this)) - before_ != assets) revert TransferAmountMismatch();
        owed[address(asset)][l.owner] += assets;
        emit ExitPaid(vault, l.owner, id, shares, assets);
    }

    /// @notice Collect what the caller's exit sales redeemed in `asset`.
    /// @return amount What was owed, now sent to the caller.
    function withdraw(IERC20 asset) external nonReentrant returns (uint256 amount) {
        amount = owed[address(asset)][msg.sender];
        if (amount == 0) revert NothingToPay();
        delete owed[address(asset)][msg.sender];
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(address(asset), msg.sender, amount);
    }

    /// @notice The share of the interest still to come, in basis points, that a sale of exit listing `id` of `vault`
    /// must leave its holders above book value however far the price has fallen: none for the part of the holding the
    /// leaver's shortfall covers. What a listing starts at (`START_KEEP_BPS`) for the rest, for no shortfall, while a
    /// record of the vault awaits its settlement (`pendingSettlements`), and for a holding no longer within the vault's
    /// average (`withinAverage`). Never below the share of the holding's loan-days the leaver's committed shares
    /// did not carry, of what a listing starts at: the leaver can take off a buyer's price only its own
    /// part. The curator floor for a holding with no exit listing.
    /// @param vault The selling vault.
    /// @param id The listed loan.
    /// @return floor Between zero and `IntentLenderMarket.START_KEEP_BPS`.
    function floorBps(address vault, uint256 id) external view returns (uint256 floor) {
        address owner = listings[IntentVault(vault)][id].owner;
        if (owner == address(0)) return CURATOR_FLOOR_BPS;
        return _floorOf(IntentVault(vault), id, owner);
    }

    /// @notice The floor exit listing `id` of `vault` would have now with `owner` as its leaver, by `floorBps`'s rule:
    /// what the desk compares when an exit asks to take a live listing over (`list`), and what an exit listing of the
    /// holding for `owner`'s current commitment would stop at. `START_KEEP_BPS` for an owner with no shortfall.
    /// @param vault The selling vault.
    /// @param id The holding's loan.
    /// @param owner The leaver.
    /// @return Between zero and `IntentLenderMarket.START_KEEP_BPS`.
    function floorOf(address vault, uint256 id, address owner) external view returns (uint256) {
        return _floorOf(IntentVault(vault), id, owner);
    }

    /// @inheritdoc IIntentExitDesk
    function exitDebit(address vault, uint256 id) external view returns (address owner, uint256 debit) {
        Debit memory d = _debits[IntentVault(vault)][id];
        return (d.owner, d.amount);
    }

    /// @notice What `owner`'s committed shares are worth beyond what `vault` holds outside its loans, at most their share
    /// of its loan book (principal out plus the interest it has earned). What it holds outside its loans is its cash and
    /// its reserve at the reserve's own value (`totalAssets` less the loan book), never what the reserve can pay out this
    /// instant: a reserve that cannot pay now lists no loan and moves no floor, so nobody can list one or
    /// lower a price by moving the reserve's liquidity for a transaction, and the leaver waits for the reserve, as a
    /// withdrawal does. Zero for no commitment, or one its holder has moved or no longer approves.
    function shortfall(IntentVault vault, address owner) public view returns (uint256) {
        if (_lapsed(vault, owner)) return 0;
        uint256 shares = Math.min(
            Math.min(exits[vault][owner].shares, vault.balanceOf(owner)), vault.allowance(owner, address(this))
        );
        if (shares == 0) return 0;
        uint256 claim = vault.previewRedeem(shares);
        uint256 loans = vault.performingPrincipal() + vault.accruedInterest();
        uint256 held = vault.totalAssets() - loans;
        if (claim <= held) return 0;
        return Math.min(claim - held, Math.mulDiv(shares, loans, vault.totalSupply()));
    }

    /// @notice Whether holding `id` has at most as much interest still to earn, per unit of book value, as `vault`'s
    /// running loans together; false for no running holding.
    function withinAverage(IntentVault vault, uint256 id) public view returns (bool within) {
        (, within,) = _check(vault, id);
    }

    /// @notice The records of `vault` whose outcome only its `settle` books. A refund or a repayment brings cash the
    /// vault counts as lent until then; a default or a loan past the end of its term brings a write-off. While any
    /// waits, the desk lists nothing and nothing falls. Anyone may settle them (`IntentVault.settle`), at most 32 a
    /// call; a repayment in its purchase's second is booked from the next.
    function pendingSettlements(IntentVault vault) public view returns (uint256[] memory ids) {
        uint256[] memory records = IntentFactory(vault.PROTOCOL_SOURCE()).SHARE_VIEWS().rewardRecords(address(vault));
        GageV2Vault core = vault.VAULT();
        ids = new uint256[](records.length);
        uint256 count;
        for (uint256 i; i < records.length; ++i) {
            (bool waits,,) = _record(vault, core, records[i]);
            if (waits) ids[count++] = records[i];
        }
        assembly ("memory-safe") {
            mstore(ids, count)
        }
    }

    function _list(IntentVault vault, address owner, uint256 id) private {
        Exit storage e = exits[vault][owner];
        if (e.shares == 0) revert NoExit();
        IntentLenderMarket market = _marketOf(vault);
        if (_live(market, e.id, e.nonce)) revert ListingLive();
        uint256 need = shortfall(vault, owner);
        if (need == 0) revert NoShortfall();
        (bool pending, bool within, uint256 book) = _check(vault, id);
        // Another exit's live listing of the holding passes, as it stands, only to an exit whose floor there is lower
        // (`_takesOver`): a leaver that withdrew the approval or the shares, or whose exit
        // lapsed, keeps nothing, and a cancelled exit's listing has no leaver.
        (uint64 nonce, address holder) = _openExit(market, vault, id);
        if (holder != address(0) && !_takesOver(vault, id, owner, need, holder, book)) revert ListingLive();
        if (!within) revert AboveAverageYield();
        // A shortfall counts what a settle would book as lent: settle first (`pendingSettlements`).
        if (pending) revert SettlementPending();
        if (nonce == 0) {
            // The market sets an exit's own deadline.
            nonce = market.list(id, 0, vault.VAULT().REGISTRY().tradeFeeBps());
        } else if (holder != address(0)) {
            // Taken over as it stands: the market keeps its nonce, start and end, and its price goes on falling. The exit
            // it served names it no more, so it may list another holding at once.
            Exit storage displaced = exits[vault][holder];
            if (displaced.id == id && displaced.nonce == nonce) {
                (displaced.id, displaced.nonce) = (0, 0);
                emit ExitDropped(vault, holder, id, nonce);
            }
        }
        // The exit's last listing sold or ended; the holding's last exit listing, if another's, ended or passes to it.
        if (listings[vault][e.id].owner == owner) delete listings[vault][e.id];
        listings[vault][id] = Listing(owner, nonce);
        (e.id, e.nonce) = (id, nonce);
        emit ExitListed(vault, owner, id, nonce);
    }

    /// @dev The market's live exit listing of `id`, as `_live` reads one: its nonce, zero for none, and the exit the
    /// desk's record names for it, zero once that exit was cancelled (its record is gone).
    function _openExit(IntentLenderMarket market, IntentVault vault, uint256 id)
        private
        view
        returns (uint64 nonce, address holder)
    {
        (uint40 listedAt, uint40 deadline,,, uint64 current, bool exit) = market.asks(id);
        if (listedAt == 0 || !exit || block.timestamp >= deadline) return (0, address(0));
        Listing memory l = listings[vault][id];
        return (current, l.nonce == current ? l.owner : address(0));
    }

    /// @dev Whether the market's listing of `id` is still the exit listing `nonce` and open.
    function _live(IntentLenderMarket market, uint256 id, uint64 nonce) private view returns (bool) {
        if (nonce == 0) return false;
        (uint40 listedAt, uint40 deadline,,, uint64 current, bool exit) = market.asks(id);
        return listedAt != 0 && exit && current == nonce && block.timestamp < deadline;
    }

    /// @dev One pass over `vault`'s open records (`IntentVaultViews.rewardRecords`): whether any awaits its settlement,
    /// whether holding `id` has at most as much interest still to earn per unit of book value as the running loans
    /// together, and its book value (scaled by RATE_PRECISION).
    function _check(IntentVault vault, uint256 id) private view returns (bool pending, bool within, uint256 book) {
        uint256[] memory ids = IntentFactory(vault.PROTOCOL_SOURCE()).SHARE_VIEWS().rewardRecords(address(vault));
        GageV2Vault core = vault.VAULT();
        uint256 remaining;
        uint256 allRemaining;
        uint256 allBook;
        for (uint256 i; i < ids.length; ++i) {
            (bool waits, uint256 r, uint256 b) = _record(vault, core, ids[i]);
            if (waits) pending = true;
            if (ids[i] == id) (remaining, book) = (r, b);
            allRemaining += r;
            allBook += b;
        }
        within = book != 0 && Math.mulDiv(remaining, allBook, book) <= allRemaining;
    }

    /// @dev Record `id` of `vault`: whether only its `settle` books its outcome (a refund: a withdrawn commitment, a
    /// cancelled listing or one past its funding deadline; a repayment; a default; or a loan past the end of its term),
    /// and, for a loan still running, its interest still to earn and book value, both scaled by RATE_PRECISION, exactly
    /// as the vault's interest clock and `executeLenderSale` count them. A loan repaid early has no interest still to
    /// come: it was paid, and settling it gives every holder their share whoever leaves. A settled record, a listing
    /// still funding and a loan not yet seen active count nothing.
    function _record(IntentVault vault, GageV2Vault core, uint256 id)
        private
        view
        returns (bool waits, uint256 remaining, uint256 book)
    {
        (
            ,,,
            uint40 maturity,
            bool withdrawn,
            bool settled,,,,
            uint128 principal,,
            uint128 interest,
            uint128 rate,
            uint64 clockStart,,
        ) = vault.loans(id);
        if (settled) return (false, 0, 0);
        if (withdrawn) return (true, 0, 0);
        V2Loan memory l = core.getLoan(id);
        if (l.state == V2State.FUNDING) return (block.timestamp >= l.fundingDeadline, 0, 0);
        if (l.state != V2State.ACTIVE) return (l.state != V2State.NONE, 0, 0);
        if (block.timestamp >= uint256(l.fundedAt) + l.term) return (true, 0, 0);
        if (rate == 0) return (false, 0, 0);
        uint256 earned = uint256(rate) * (Math.min(core.accrualEnd(id), maturity) - clockStart);
        uint256 owed = uint256(interest) * RATE_PRECISION;
        remaining = owed > earned ? owed - earned : 0;
        book = uint256(principal) * RATE_PRECISION + earned;
    }

    /// @dev `floorBps`'s rule for `owner` as the leaver of holding `id`.
    function _floorOf(IntentVault vault, uint256 id, address owner) private view returns (uint256) {
        uint256 need = shortfall(vault, owner);
        // Nothing the vault cannot pay the leaver now (or the exit lapsed): nothing falls, whoever brought it there.
        if (need == 0) return START_KEEP_BPS;
        // Nor while a settle would book cash first, or once the holding has more interest still to come per unit of
        // book than the vault's open loans together: a sale would then forfeit more than the leaver's share of it.
        (bool pending, bool within, uint256 book) = _check(vault, id);
        if (pending || !within) return START_KEEP_BPS;
        return _floorFor(vault, id, owner, need, book);
    }

    /// @dev The floor of holding `id` (book value `book`, scaled by RATE_PRECISION) for leaver `owner` short by `need`:
    /// none for the part of the holding the shortfall covers and `START_KEEP_BPS` for the rest, rounded up; and never
    /// below what the leaver's committed shares did not carry of the holding, since the sale's discount
    /// comes out of the leaver's own part of its earnings claim (`onSale`), which must be able to pay it.
    function _floorFor(IntentVault vault, uint256 id, address owner, uint256 need, uint256 book)
        private
        view
        returns (uint256 floor)
    {
        need *= RATE_PRECISION;
        floor = need >= book ? 0 : Math.mulDiv(START_KEEP_BPS, book - need, book, Math.Rounding.Ceil);
        uint256 stake = _stakeFloor(vault, id, owner);
        if (stake > floor) floor = stake;
    }

    /// @dev Whether exit `owner`, short by `need`, takes over the live exit listing of holding `id` that serves
    /// `holder`: when `holder` has no shortfall (it withdrew the approval or the
    /// shares, its exit lapsed, or the vault can pay it), whose floor is then where a listing starts, or when `owner`'s
    /// floor there is lower than `holder`'s. Both are read as this transaction finds the vault: a takeover never raises
    /// the price the listing stood at just before it, nor reverts a plan that cleared then; cash moved within the same
    /// transaction can leave it higher, and `holder` may then take the listing back. The holding's average
    /// and settlement checks, common to both, are `list`'s own.
    function _takesOver(IntentVault vault, uint256 id, address owner, uint256 need, address holder, uint256 book)
        private
        view
        returns (bool)
    {
        uint256 holderNeed = shortfall(vault, holder);
        if (holderNeed == 0) return true;
        return _floorFor(vault, id, owner, need, book) < _floorFor(vault, id, holder, holderNeed, book);
    }

    /// @dev `START_KEEP_BPS` of the part of holding `id`'s exposure window that `owner`'s committed shares did not
    /// carry, rounded up: the share of the interest still to come a sale must keep for every other holder. The
    /// committed shares carried the holder's exposure in proportion to its balance, as `shortfall` counts them.
    function _stakeFloor(IntentVault vault, uint256 id, address owner) private view returns (uint256) {
        (uint256 exposure, uint256 supply) = _exitShare(vault, id, owner);
        if (supply == 0) return START_KEEP_BPS;
        uint256 held = vault.balanceOf(owner);
        uint256 committed = Math.min(Math.min(exits[vault][owner].shares, held), vault.allowance(owner, address(this)));
        uint256 carried = held == 0 ? 0 : Math.mulDiv(exposure, committed, held);
        return carried >= supply ? 0 : Math.mulDiv(START_KEEP_BPS, supply - carried, supply, Math.Rounding.Ceil);
    }

    /// @dev What `owner` carried of holding `id`'s exposure window and the window's supply, as a sale closes it now.
    function _exitShare(IntentVault vault, uint256 id, address owner)
        private
        view
        returns (uint256 exposure, uint256 supply)
    {
        return IntentFactory(vault.PROTOCOL_SOURCE()).SHARE_VIEWS().exitShare(address(vault), id, owner);
    }

    /// @dev Charge `owner`, the leaver exit sale `id` pays, the sale's discount below what a listing starts at, out of
    /// its own part of the earnings claim the sale just opened (the vault's last pocket). Never more than that part can
    /// absorb, `pocket * exposure / (supply - exposure)`: the vault's split then takes every part on the pocket plus the
    /// debit, the leaver's less the debit, and the parts never sum above the pocket. Nothing for a sale at or above the
    /// start, or one that set nothing aside.
    function _debit(IntentVault vault, uint256 id, address owner) private {
        uint256 pocketId = vault.pocketCount();
        if (pocketId == 0) return;
        (uint256 loanId,, uint256 pocket, uint256 supply,,) = vault.pockets(pocketId);
        if (loanId != id) return;
        uint256 start = _start(vault, id);
        if (start <= pocket) return;
        uint256 debit = start - pocket;
        (uint256 exposure,) = _exitShare(vault, id, owner);
        if (exposure < supply) debit = Math.min(debit, Math.mulDiv(pocket, exposure, supply - exposure));
        if (debit == 0) return;
        _debits[vault][id] = Debit(owner, SafeCast.toUint96(debit));
        emit ExitDebited(vault, owner, id, pocketId, debit);
    }

    /// @dev What a listing of holding `id` started at, in the vault asset: `START_KEEP_BPS` of the interest it still had
    /// to earn when it sold, exactly as `IntentVault.executeLenderSale` counted it. The sale's `_close` cleared the
    /// record's rate, so the rate is read again as `_startAccrual` set it from the record's interest, maturity and clock
    /// start, which the sale leaves as booked; a record never seen active had earned nothing.
    function _start(IntentVault vault, uint256 id) private view returns (uint256) {
        (,,, uint40 maturity,,,,,,,, uint128 interest,, uint64 clockStart,,) = vault.loans(id);
        uint256 earned;
        if (clockStart != 0 && maturity > clockStart) {
            uint256 rate = uint256(interest) * RATE_PRECISION / (maturity - clockStart);
            earned = rate * (Math.min(vault.VAULT().accrualEnd(id), maturity) - clockStart) / RATE_PRECISION;
        }
        return (interest > earned ? interest - earned : 0) * START_KEEP_BPS / BPS;
    }

    /// @dev Whether `owner`'s commitment to leave `vault` is older than `EXIT_LIFE`.
    function _lapsed(IntentVault vault, address owner) private view returns (bool) {
        return block.timestamp >= committedAt[vault][owner] + EXIT_LIFE;
    }

    function _requireDeskVault(IntentVault vault) private view {
        IntentFactory factory = IntentFactory(vault.PROTOCOL_SOURCE());
        if (!factory.isVault(address(vault)) || factory.exitDesk() != address(this)) revert NotDeskVault();
    }

    /// @dev `vault`'s own market, the only one the desk lists on: a market that names `vault` as its seller
    /// and `vault`'s factory as its own, as the market a vault deploys does. The desk takes a vault on its factory's
    /// word, and a vault can name any market, so a vault under a factory of anyone's reaches only a market it deployed.
    /// Read once: the market checked is the one the desk lists on.
    function _marketOf(IntentVault vault) private view returns (IntentLenderMarket market) {
        market = vault.LENDER_MARKET();
        if (address(market.SELLER()) != address(vault) || address(market.FACTORY()) != vault.PROTOCOL_SOURCE()) {
            revert NotDeskVault();
        }
    }
}
