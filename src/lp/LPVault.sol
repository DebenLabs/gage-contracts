// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LPRegistry} from "./LPRegistry.sol";
import {ILPVault} from "./interfaces/ILPVault.sol";
import {ILPSwapExecutor} from "./interfaces/ILPSwapExecutor.sol";
import {Loan, PoolRef, SaleQuote} from "./LPTypes.sol";
import {ILPCoreView} from "./interfaces/ILPCoreView.sol";

/// @title LPVault
/// @notice USDG deposits that fund the LP lane's loans, as an ERC-4626 vault whose shares are an ERC-20. Each loan's
/// net return accrues into the share price over its term, an early repayment's included: the part not yet earned is
/// held back until the loan's original end, so a deposit made just before a repayment does not share in it. Redemptions
/// are paid from free cash, with no queue. A defaulted loan's recovery first restores what the price counted for it
/// (its book value: principal plus net return). Anything above that is the loan's bonus: it is set aside for the
/// lenders by their share of the vault times the seconds they held it while the loan ran, so a deposit made just before
/// a forgotten loan ends shares almost none of it. A lender who left keeps its part.
/// @dev Value the price does not count yet never reaches a depositor who was not there when it was lost:
/// - impaired (deposits, redemptions and funding stop): a loan sits past its end unsettled, or tokens a defaulted
///   position delivered wait to be sold while their sale can still move the price;
/// - deposits closed (redemptions and funding go on): a written-off token may still be sold, an abandoned loan's
///   position may still be recovered, or the vault's USDG is short of the fee credits and bonuses it holds, as after an
///   issuer's seizure.
/// Shares transfer, and each side keeps the exposure it earned: the sender's up to the transfer, the receiver's from it
/// on, so a share bought just before a forgotten loan ends shares almost none of its bonus either. A bonus belongs to the
/// address that held the shares, a contract included. The ERC-4626 limits say what the vault takes now: no deposit while
/// impaired or deposits are closed, no withdrawal while impaired, and never more than the free cash. `deposit` and
/// `redeem` also come with a minimum out. The curator sets the funding limits; the performance fee is fixed at creation.
/// A vault funds loans only in the pools of its mandate (each one under one adapter), so its lenders know what they
/// underwrite (an ETH/USDG LP vault never funds a stock LP). The pools named at creation fund at once; a pool the curator
/// adds funds only `MANDATE_DELAY` later; a pool the curator drops stops at once. Loans already open are never touched.
contract LPVault is ERC4626, ILPVault, EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant SALE_QUOTE_TYPEHASH = keccak256(
        "SaleQuote(address vault,uint256 loanId,address token,uint256 amountIn,uint256 minOut,address executor,uint64 deadline)"
    );

    /// @notice Most loans open at once; bounds every loop over them.
    uint256 public constant MAX_OPEN_LOANS = 64;
    /// @notice From this many open loans a new loan takes at least half an even share of the free cash over the slots
    /// left (`BelowSlotFloor`), so minimum-size loans cannot fill the book and keep the vault from lending.
    uint256 public constant SLOT_FLOOR_FROM = 32;
    /// @notice Wait before a pool the curator adds to the mandate funds loans.
    uint32 public constant MANDATE_DELAY = 3 hours;
    /// @notice Most pools a mandate names; bounds the loop over them.
    uint256 public constant MAX_MANDATE_POOLS = 32;
    /// @notice Most early repayments whose return is still being spread over the rest of their term.
    uint256 public constant MAX_DEFERRED = 64;
    /// @notice Bounds on the performance fee, a share of each loan's return.
    uint16 public constant MIN_PERFORMANCE_FEE_BPS = 500;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 1500;
    /// @notice The protocol's share of the performance fee.
    uint16 public constant PROTOCOL_SHARE_BPS = 1000;
    /// @notice Highest per-loan principal the curator may allow.
    uint128 public constant MAX_LOAN_PRINCIPAL_LIMIT = 10_000_000e6;
    /// @notice Wait after a defaulted loan delivered a token before the curator may write that token off.
    uint32 public constant WRITE_OFF_DELAY = 7 days;
    /// @notice Wait after a delivery before anyone may write the token off, so a lot no route sells never freezes
    /// redemptions for good, whatever becomes of the curator.
    uint32 public constant OPEN_WRITE_OFF_DELAY = 30 days;
    /// @notice Wait after a delivery before the curator may give a written-off token up for good.
    uint32 public constant RELEASE_DELAY = 60 days;
    /// @dev The shares' symbol; each vault's name is its own.
    string internal constant SHARE_SYMBOL = "gLP";
    /// @dev Virtual shares (10^12, ERC-4626's decimals offset) and one virtual asset: a first-depositor donation cannot
    /// move the share price. Shares have USDG's decimals plus the offset: 18, as Morpho's VaultV2 sets them.
    uint8 internal constant DECIMALS_OFFSET = 12;
    uint256 internal constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;
    /// @dev The exposure clock gains this much per second, shared over the shares and the virtual shares.
    uint256 internal constant EXPOSURE_PRECISION = 1e48;

    /// @notice The lent asset.
    IERC20 public immutable USDG;
    /// @notice The only core that opens, repays and settles this vault's loans.
    address public immutable CORE;
    /// @notice The lane's settings (quote signer, executors, protocol fee recipient).
    LPRegistry public immutable REGISTRY;
    /// @notice The vault's manager.
    address public immutable CURATOR;
    /// @notice Share of each loan's return kept as the performance fee, in basis points.
    uint16 public immutable PERFORMANCE_FEE_BPS;

    struct Book {
        uint128 principal;
        uint128 repayment;
        uint40 start;
        uint40 end;
    }

    /// @notice What a defaulted loan delivered of one token and the vault has not sold yet.
    struct Lot {
        uint128 amount;
        uint40 since;
        bool writtenOff;
    }

    /// @notice A defaulted loan's recovery: what it still owes the price, and its bonus with the exposure that shares it.
    struct Recovery {
        uint128 bookRemaining;
        uint256 closedIndex;
        uint256 exposure;
        uint256 bonus;
    }

    /// @dev A holder's exposure up to one clock reading, logged at every change of its shares.
    struct Checkpoint {
        uint256 index;
        uint256 carried;
    }

    /// @notice When the mandate's pool `pool` under `adapter` funds loans from (0: not in the mandate).
    mapping(address adapter => mapping(address pool => uint40)) public poolActiveAt;
    PoolRef[] internal _mandate;
    /// @notice The terms of each loan this vault funded.
    mapping(uint256 loanId => Book) public book;
    uint256[] internal _open;
    mapping(uint256 loanId => uint256) internal _openSlot;
    /// @dev Loans repaid before their end whose return is still being earned into the share price until that end.
    uint256[] internal _deferred;
    /// @dev Early repayments that found `_deferred` full, earned into the price together: what was still
    /// unearned at `_overflowAt`, released evenly until `_overflowEnd`, the latest of their original ends.
    uint256 internal _overflowUnearned;
    uint256 internal _overflowAt;
    uint256 internal _overflowEnd;
    /// @notice Principal of loans still open.
    uint256 public outstandingPrincipal;

    /// @notice Performance fees credited to the curator and the protocol, withdrawn by them.
    mapping(address account => uint256) public feeCredit;
    /// @notice The sum of `feeCredit`; never part of the depositors' assets.
    uint256 public totalFeeCredit;

    /// @notice The exposure clock: EXPOSURE_PRECISION per second, shared over the shares then outstanding and the
    /// virtual shares, rounded down at each write. A share held from one reading to another was exposed to every loan
    /// open in between for the difference.
    uint256 public exposureIndex;
    /// @notice Every holder's exposure summed up to `exposureIndex` (shares times the clock's movement).
    uint256 public totalExposure;
    /// @dev When the exposure clock was last written.
    uint256 internal _exposureAt;
    mapping(address account => Checkpoint[]) internal _exposure;
    /// @dev The clock and the summed exposure when each loan was funded.
    mapping(uint256 loanId => Checkpoint) internal _funded;

    mapping(uint256 loanId => mapping(address token => Lot)) internal _lots;
    /// @notice Each defaulted loan's recovery.
    mapping(uint256 loanId => Recovery) public recovery;
    /// @notice What each lender has claimed of each loan's bonus.
    mapping(uint256 loanId => mapping(address account => uint256)) public bonusClaimed;
    /// @notice USDG set aside for bonuses and not claimed yet; never part of the share price.
    uint256 public totalBonusHeld;

    address[] internal _recoveryTokens;
    /// @notice Amount of each token from defaulted positions still waiting to be sold, over all loans.
    mapping(address token => uint256) public recoveryBalance;
    /// @notice Tokens each defaulted loan delivered that still wait to be sold (written-off ones excluded).
    mapping(uint256 loanId => uint256) public pendingLots;
    /// @notice Defaulted loans whose waiting tokens the price still waits on (`recoveryBlocks`); only these impair.
    uint256 public blockingLoans;
    address[] internal _writtenOffTokens;
    /// @notice Amount of each written-off token that may still be sold, over all loans; it counts for nothing until then.
    mapping(address token => uint256) public writtenOffBalance;
    /// @notice Whether a loan this vault funded was abandoned and its position not yet recovered.
    mapping(uint256 loanId => bool) public abandoned;
    /// @notice How many abandoned loans may still deliver a recovery.
    uint256 public abandonedLoans;

    /// @notice Sale quotes already used, by EIP-712 digest.
    mapping(bytes32 digest => bool) public quoteUsed;

    /// @notice When true, the vault funds no new loan. Nothing else stops.
    bool public fundingPaused;
    /// @notice Largest principal one loan may take from this vault.
    uint128 public maxLoanPrincipal;

    event Funded(uint256 indexed loanId, uint128 principal, uint128 repayment, uint40 end);
    event LoanRepaid(uint256 indexed loanId, uint256 amount, uint256 performanceFee);
    event Refinanced(uint256 indexed loanId, uint256 indexed newLoanId, uint256 repaid, uint128 principal);
    event LoanDefaulted(uint256 indexed loanId, address[] tokens, uint256[] amounts);
    event LoanAbandoned(uint256 indexed loanId, uint128 principal);
    event LoanRecovered(uint256 indexed loanId, address[] tokens, uint256[] amounts);
    event RecoveryOpened(uint256 indexed loanId, uint256 bookValue, uint256 exposure);
    event BonusSetAside(uint256 indexed loanId, uint256 amount);
    event BonusClaimed(uint256 indexed loanId, address indexed account, uint256 amount);
    event RecoverySold(
        uint256 indexed loanId, address indexed token, uint256 amountIn, uint256 amountOut, address executor
    );
    event RecoveryWrittenOff(uint256 indexed loanId, address indexed token, uint256 amount);
    event WrittenOffReleased(uint256 indexed loanId, address indexed token, uint256 amount);
    event FeeCredited(address indexed account, uint256 amount);
    event FeeWithdrawn(address indexed account, uint256 amount);
    event FundingPausedSet(bool paused);
    event MaxLoanPrincipalSet(uint128 amount);
    event PoolAdded(address indexed adapter, address indexed pool, uint40 activeAt);
    event PoolRemoved(address indexed adapter, address indexed pool);

    error NotCore(address caller);
    error NotCurator(address caller);
    error ZeroAddress();
    error InvalidPerformanceFee(uint16 bps);
    error MaxLoanAboveLimit(uint128 amount);
    error ZeroAmount();
    error Slippage();
    error Impaired();
    error DepositsClosed();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error FundingPaused();
    error AboveMaxLoan(uint128 principal);
    error TooManyOpenLoans();
    error BelowSlotFloor(uint128 principal, uint256 least);
    error UnknownLoan(uint256 loanId);
    error RepaymentMismatch(uint256 amount, uint256 expected);
    error LengthMismatch();
    error QuoteMismatch();
    error QuoteExpired(uint64 deadline);
    error QuoteUsed(bytes32 digest);
    error InvalidSignature();
    error ExecutorNotAllowed(address executor);
    error InvalidToken(address token);
    error AboveRecovery(uint256 amountIn, uint256 available);
    error NothingSold();
    error WriteOffTooEarly(uint256 opensAt);
    error ReleaseTooEarly(uint256 opensAt);
    error NothingToWithdraw();
    error EmptyMandate();
    error TooManyPools();
    error PoolAlreadyInMandate(address adapter, address pool);
    error PoolNotInMandate(address adapter, address pool);

    modifier onlyCore() {
        if (msg.sender != CORE) revert NotCore(msg.sender);
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != CURATOR) revert NotCurator(msg.sender);
        _;
    }

    /// @notice Creates a vault named `name_` lending `usdg` through `core`, managed by `curator`, funding loans in
    /// `pools` only.
    constructor(
        IERC20 usdg,
        address core,
        LPRegistry registry,
        address curator,
        uint16 performanceFeeBps,
        uint128 maxLoanPrincipal_,
        PoolRef[] memory pools,
        string memory name_
    ) ERC20(name_, SHARE_SYMBOL) ERC4626(usdg) EIP712("gage LP vault", "1") {
        if (performanceFeeBps < MIN_PERFORMANCE_FEE_BPS || performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) {
            revert InvalidPerformanceFee(performanceFeeBps);
        }
        if (maxLoanPrincipal_ > MAX_LOAN_PRINCIPAL_LIMIT) revert MaxLoanAboveLimit(maxLoanPrincipal_);
        if (
            address(usdg) == address(0) || core == address(0) || address(registry) == address(0)
                || curator == address(0)
        ) {
            revert ZeroAddress();
        }
        USDG = usdg;
        CORE = core;
        REGISTRY = registry;
        CURATOR = curator;
        PERFORMANCE_FEE_BPS = performanceFeeBps;
        maxLoanPrincipal = maxLoanPrincipal_;
        _exposureAt = block.timestamp;
        if (pools.length == 0) revert EmptyMandate();
        for (uint256 i; i < pools.length; ++i) {
            _addPool(pools[i].adapter, pools[i].pool, uint40(block.timestamp));
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice USDG the vault holds that belongs to depositors (fee credits and set-aside bonuses excluded); zero, not a
    /// revert, should USDG's issuer ever leave the vault less than those.
    function freeCash() public view returns (uint256) {
        uint256 balance = USDG.balanceOf(address(this));
        uint256 held = totalFeeCredit + totalBonusHeld;
        return balance > held ? balance - held : 0;
    }

    /// @notice Depositors' assets: free cash plus each open loan's principal and its net return accrued so far, less
    /// the part of each early repayment's net return still held back: until its loan's original end when the deferred
    /// list (`MAX_DEFERRED` loans at most) had room at the repayment, and otherwise in the overflow, released evenly
    /// with the rest of the overflow until the latest original end there. Tokens waiting to be sold, written-off tokens
    /// and abandoned positions count for nothing until sold.
    function totalAssets() public view override returns (uint256 assets) {
        assets = freeCash();
        uint256 n = _open.length;
        for (uint256 i; i < n; ++i) {
            assets += _accruedValue(book[_open[i]]);
        }
        n = _deferred.length;
        for (uint256 i; i < n; ++i) {
            uint256 unearned = _unearned(book[_deferred[i]]);
            assets = assets > unearned ? assets - unearned : 0;
        }
        uint256 overflow = _overflowLeft();
        assets = assets > overflow ? assets - overflow : 0;
    }

    /// @notice Early repayments whose return is still being earned into the share price.
    function deferredLoans() external view returns (uint256[] memory) {
        return _deferred;
    }

    /// @notice True while a loan is past its end unsettled, or recovered tokens wait to be sold and their sale can
    /// still move the price: deposits, redemptions and funding stop.
    function impaired() public view returns (bool) {
        if (blockingLoans != 0) return true;
        uint256 n = _open.length;
        for (uint256 i; i < n; ++i) {
            if (block.timestamp >= book[_open[i]].end) return true;
        }
        return false;
    }

    /// @notice True while value the price does not count may still arrive (a written-off token that can still be
    /// sold, an abandoned position that can still be recovered), or while the vault's USDG is short of the fee credits
    /// and bonuses it holds, as after an issuer's seizure: only deposits stop.
    function depositsClosed() public view returns (bool) {
        return _writtenOffTokens.length != 0 || abandonedLoans != 0
            || USDG.balanceOf(address(this)) < totalFeeCredit + totalBonusHeld;
    }

    /// @notice Whether defaulted loan `loanId`'s tokens waiting to be sold impair the vault: while its recovery still
    /// owes the price its book value, or no lender was exposed to it (its bonus would then go to the price). Once the
    /// book value is back, what they sell for is bonus held outside the price, so nobody entering or leaving gains or
    /// loses by it.
    function recoveryBlocks(uint256 loanId) public view returns (bool) {
        if (pendingLots[loanId] == 0) return false;
        Recovery storage r = recovery[loanId];
        return r.bookRemaining != 0 || r.exposure == 0;
    }

    /// @notice Loans this vault funded that are still open.
    function openLoans() external view returns (uint256[] memory) {
        return _open;
    }

    /// @notice Tokens from defaulted positions still waiting to be sold.
    function recoveryTokens() external view returns (address[] memory) {
        return _recoveryTokens;
    }

    /// @notice Written-off tokens that may still be sold.
    function writtenOffTokens() external view returns (address[] memory) {
        return _writtenOffTokens;
    }

    /// @notice What defaulted loan `loanId` delivered of `token` and the vault has not sold yet.
    function lot(uint256 loanId, address token) external view returns (Lot memory) {
        return _lots[loanId][token];
    }

    /// @notice `account`'s exposure to loan `loanId`: its share of the vault times the seconds it held it while the loan
    /// ran, scaled by EXPOSURE_PRECISION. Zero until the loan defaults.
    function exposureIn(uint256 loanId, address account) public view returns (uint256) {
        uint256 closed = recovery[loanId].closedIndex;
        uint256 opened = _funded[loanId].index;
        if (closed <= opened) return 0;
        return _exposureOf(account, closed) - _exposureOf(account, opened);
    }

    /// @notice What `account` may claim of loan `loanId`'s bonus now.
    function bonusClaimable(uint256 loanId, address account) public view returns (uint256) {
        Recovery storage r = recovery[loanId];
        if (r.bonus == 0) return 0;
        uint256 share = r.bonus.mulDiv(exposureIn(loanId, account), r.exposure);
        uint256 claimed = bonusClaimed[loanId][account];
        return share > claimed ? share - claimed : 0;
    }

    /// @notice Assets a deposit may bring now: none while impaired or deposits are closed, else no limit.
    function maxDeposit(address) public view override returns (uint256) {
        return impaired() || depositsClosed() ? 0 : type(uint256).max;
    }

    /// @notice Shares a mint may create now: none while impaired or deposits are closed, else no limit.
    function maxMint(address) public view override returns (uint256) {
        return impaired() || depositsClosed() ? 0 : type(uint256).max;
    }

    /// @notice Assets `owner` may withdraw now: its shares' value, at most the free cash; none while impaired.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (impaired()) return 0;
        uint256 assets = previewRedeem(balanceOf(owner));
        uint256 cash = freeCash();
        return assets < cash ? assets : cash;
    }

    /// @notice Shares `owner` may redeem now: its shares, at most what the free cash pays for; none while impaired.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (impaired()) return 0;
        uint256 shares = balanceOf(owner);
        uint256 payable_ = _convertToShares(freeCash(), Math.Rounding.Floor);
        return shares < payable_ ? shares : payable_;
    }

    /// @notice The EIP-712 digest the rates signer signs for `quote`.
    function saleQuoteDigest(SaleQuote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(SALE_QUOTE_TYPEHASH, quote)));
    }

    // -------------------------------------------------------------- depositors

    /// @notice Deposits `assets` USDG for shares minted to `receiver`.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        shares = _depositAssets(assets, receiver, 0);
    }

    /// @notice Deposits `assets` USDG for at least `minShares` shares minted to `receiver`.
    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _depositAssets(assets, receiver, minShares);
    }

    /// @notice Mints exactly `shares` to `receiver` for the USDG they cost now.
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        _pruneDeferred();
        if (shares == 0) revert ZeroAmount();
        _beforeDeposit();
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Burns `owner`'s shares for exactly `assets` USDG paid to `receiver` from free cash.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _pruneDeferred();
        if (assets == 0) revert ZeroAmount();
        if (impaired()) revert Impaired();
        shares = previewWithdraw(assets);
        _payOut(receiver, owner, assets, shares);
    }

    /// @notice Redeems `owner`'s `shares` for USDG paid to `receiver` from free cash.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = _redeemShares(shares, receiver, owner, 0);
    }

    /// @notice Redeems `owner`'s `shares` for at least `minAssets` USDG paid to `receiver` from free cash.
    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = _redeemShares(shares, receiver, owner, minAssets);
    }

    /// @notice Pays the caller its part of loan `loanId`'s bonus.
    function claimBonus(uint256 loanId) external nonReentrant returns (uint256 amount) {
        amount = _claimBonus(loanId, msg.sender);
    }

    /// @notice Pays `account` its part of loan `loanId`'s bonus. Anyone may trigger it; the funds only go to the
    /// account.
    function claimBonusFor(uint256 loanId, address account) external nonReentrant returns (uint256 amount) {
        amount = _claimBonus(loanId, account);
    }

    // -------------------------------------------------------------- core hooks

    /// @inheritdoc ILPVault
    /// @dev Refused while impaired: the free cash then waits for the lenders who cannot leave yet.
    function fund(uint256 loanId, uint128 principal, uint128 repayment, uint40 end) external onlyCore nonReentrant {
        _fund(loanId, principal, repayment, end, principal);
        USDG.safeTransfer(CORE, principal);
    }

    /// @inheritdoc ILPVault
    function onRepaid(uint256 loanId, uint256 amount) external onlyCore nonReentrant {
        _repaid(loanId, amount);
    }

    /// @inheritdoc ILPVault
    /// @dev The same books as a repayment followed by a funding, so the old loan's return and the new loan's exposure
    /// are counted exactly as for two separate calls; only the cash nets, so a roll needs free cash for the difference
    /// alone. Refused, like a funding, while impaired or paused.
    function refinance(uint256 loanId, uint256 newLoanId, uint128 principal, uint128 repayment, uint40 end)
        external
        onlyCore
        nonReentrant
    {
        uint256 owed = book[loanId].repayment;
        _repaid(loanId, owed);
        uint256 out = principal > owed ? principal - owed : 0;
        _fund(newLoanId, principal, repayment, end, out);
        if (out != 0) USDG.safeTransfer(CORE, out);
        emit Refinanced(loanId, newLoanId, owed, principal);
    }

    /// @dev Books loan `loanId`; `cashOut` is what leaves the vault for it (the principal, or a roll's difference).
    function _fund(uint256 loanId, uint128 principal, uint128 repayment, uint40 end, uint256 cashOut) internal {
        if (fundingPaused) revert FundingPaused();
        if (impaired()) revert Impaired();
        if (principal > maxLoanPrincipal) revert AboveMaxLoan(principal);
        uint256 open = _open.length;
        if (open == MAX_OPEN_LOANS) revert TooManyOpenLoans();
        if (open >= SLOT_FLOOR_FROM) {
            uint256 least = freeCash() / ((MAX_OPEN_LOANS - open) * 2);
            if (principal < least) revert BelowSlotFloor(principal, least);
        }
        Loan memory l = ILPCoreView(CORE).loan(loanId);
        if (!funds(l.adapter, l.pool)) revert PoolNotInMandate(l.adapter, l.pool);
        // After a roll's repayment is booked, its fee credit must be backed too: the vault's USDG must cover every
        // credit it holds plus what leaves now, or the credits would be left short.
        uint256 balance = USDG.balanceOf(address(this));
        uint256 held = totalFeeCredit + totalBonusHeld;
        if (balance < held + cashOut) revert InsufficientLiquidity(cashOut, balance > held ? balance - held : 0);
        book[loanId] = Book({principal: principal, repayment: repayment, start: uint40(block.timestamp), end: end});
        _funded[loanId] = Checkpoint({index: _accrueExposure(), carried: totalExposure});
        _open.push(loanId);
        _openSlot[loanId] = _open.length;
        outstandingPrincipal += principal;
        emit Funded(loanId, principal, repayment, end);
    }

    /// @dev Closes repaid loan `loanId`, whose `amount` USDG the core moved into the vault (or netted, on a roll).
    function _repaid(uint256 loanId, uint256 amount) internal {
        Book memory b = book[loanId];
        _close(loanId);
        if (amount != b.repayment) revert RepaymentMismatch(amount, b.repayment);
        outstandingPrincipal -= b.principal;
        uint256 fee = ((amount - b.principal) * PERFORMANCE_FEE_BPS) / 10_000;
        uint256 protocolCut = (fee * PROTOCOL_SHARE_BPS) / 10_000;
        _creditFee(REGISTRY.feeRecipient(), protocolCut);
        _creditFee(CURATOR, fee - protocolCut);
        _pruneDeferred();
        // Repaid early: keep earning the rest of the return over the loan's original term. With the list full (64
        // early repayments still earning), it joins the overflow, earned over the latest of their ends: never at once,
        // which a deposit just before the repayment would share, and never refusing a repayment.
        if (block.timestamp < b.end) {
            if (_deferred.length < MAX_DEFERRED) _deferred.push(loanId);
            else _overflow(b);
        }
        emit LoanRepaid(loanId, amount, fee);
    }

    /// @inheritdoc ILPVault
    function onDefault(uint256 loanId, address[] calldata tokens, uint256[] calldata amounts)
        external
        onlyCore
        nonReentrant
    {
        Book memory b = book[loanId];
        _close(loanId);
        outstandingPrincipal -= b.principal;
        _openRecovery(loanId, b);
        _bookDelivered(loanId, tokens, amounts);
        _syncBlocking(loanId, false);
        emit LoanDefaulted(loanId, tokens, amounts);
    }

    /// @inheritdoc ILPVault
    function onAbandoned(uint256 loanId) external onlyCore nonReentrant {
        Book memory b = book[loanId];
        _close(loanId);
        outstandingPrincipal -= b.principal;
        _openRecovery(loanId, b);
        abandoned[loanId] = true;
        ++abandonedLoans;
        emit LoanAbandoned(loanId, b.principal);
    }

    /// @inheritdoc ILPVault
    function onRecovered(uint256 loanId, address[] calldata tokens, uint256[] calldata amounts)
        external
        onlyCore
        nonReentrant
    {
        if (!abandoned[loanId]) revert UnknownLoan(loanId);
        abandoned[loanId] = false;
        --abandonedLoans;
        _bookDelivered(loanId, tokens, amounts);
        _syncBlocking(loanId, false);
        emit LoanRecovered(loanId, tokens, amounts);
    }

    // ----------------------------------------------------------- recoveries

    /// @notice Sells part of what defaulted loan `quote.loanId` delivered of `quote.token` for USDG through an allowed
    /// executor, no worse than the rates signer's price. A quote for more than is left sells what is left, at the
    /// quote's price pro rata, so a smaller sale just before cannot void it. Only what the executor actually
    /// took is booked as sold; anything it sends back stays with the loan. The USDG first restores the loan's book
    /// value to the price; the rest is the loan's bonus. Anyone may submit a valid quote; the keeper does by default.
    function sell(SaleQuote calldata quote, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (quote.vault != address(this)) revert QuoteMismatch();
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline);
        if (quote.token == address(USDG)) revert InvalidToken(quote.token);
        if (quote.amountIn == 0) revert ZeroAmount();
        Lot storage l = _lots[quote.loanId][quote.token];
        uint256 amountIn = quote.amountIn < l.amount ? quote.amountIn : l.amount;
        if (amountIn == 0) revert AboveRecovery(quote.amountIn, 0);
        if (!REGISTRY.executorAllowed(quote.executor)) revert ExecutorNotAllowed(quote.executor);
        bytes32 digest = saleQuoteDigest(quote);
        if (quoteUsed[digest]) revert QuoteUsed(digest);
        quoteUsed[digest] = true;
        if (ECDSA.recover(digest, signature) != REGISTRY.quoteSigner()) revert InvalidSignature();

        bool blocked = recoveryBlocks(quote.loanId);
        IERC20 token = IERC20(quote.token);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 usdgBefore = USDG.balanceOf(address(this));
        token.safeTransfer(quote.executor, amountIn);
        ILPSwapExecutor(quote.executor).swap(quote.token, amountIn, address(this));
        uint256 tokenAfter = token.balanceOf(address(this));
        uint256 spent = tokenBefore > tokenAfter ? tokenBefore - tokenAfter : 0;
        if (spent > amountIn) spent = amountIn;
        if (spent == 0) revert NothingSold();
        amountOut = USDG.balanceOf(address(this)) - usdgBefore;
        if (amountOut < quote.minOut.mulDiv(spent, quote.amountIn, Math.Rounding.Ceil)) revert Slippage();
        l.amount -= SafeCast.toUint128(spent);
        if (l.amount == 0 && !l.writtenOff) --pendingLots[quote.loanId];
        _unbook(quote.token, spent, l.writtenOff);
        _creditRecovery(quote.loanId, amountOut);
        _syncBlocking(quote.loanId, blocked);
        emit RecoverySold(quote.loanId, quote.token, spent, amountOut, quote.executor);
    }

    /// @notice Gives up waiting on what loan `loanId` delivered of `token` once no route has sold it: the curator may
    /// from `WRITE_OFF_DELAY` after the delivery, anyone from `OPEN_WRITE_OFF_DELAY`, so a lost curator never freezes
    /// redemptions for good. It stops blocking redemptions and funding, and keeps counting for nothing. Deposits
    /// stay closed while it may still be sold, so its sale can only reach the lenders who were there when it was lost.
    /// A token that blocks nothing (`recoveryBlocks` false) is not written off: it would only close deposits.
    function writeOffRecovery(uint256 loanId, address token) external nonReentrant {
        Lot storage l = _lots[loanId][token];
        if (l.amount == 0 || l.writtenOff || !recoveryBlocks(loanId)) revert InvalidToken(token);
        uint256 opensAt = uint256(l.since) + (msg.sender == CURATOR ? WRITE_OFF_DELAY : OPEN_WRITE_OFF_DELAY);
        if (block.timestamp < opensAt) revert WriteOffTooEarly(opensAt);
        l.writtenOff = true;
        --pendingLots[loanId];
        _unbook(token, l.amount, false);
        if (writtenOffBalance[token] == 0) _writtenOffTokens.push(token);
        writtenOffBalance[token] += l.amount;
        _syncBlocking(loanId, true);
        emit RecoveryWrittenOff(loanId, token, l.amount);
    }

    /// @notice Gives up on a written-off lot for good so deposits can reopen, once `RELEASE_DELAY` has passed since its
    /// delivery. It can never be sold afterwards, so no later depositor can gain from it; it costs the lenders
    /// only a value the price already counts as nothing, and routes have had that long to sell it.
    function releaseWrittenOff(uint256 loanId, address token) external onlyCurator nonReentrant {
        Lot storage l = _lots[loanId][token];
        if (l.amount == 0 || !l.writtenOff) revert InvalidToken(token);
        uint256 opensAt = uint256(l.since) + RELEASE_DELAY;
        if (block.timestamp < opensAt) revert ReleaseTooEarly(opensAt);
        uint256 amount = l.amount;
        l.amount = 0;
        _unbook(token, amount, true);
        emit WrittenOffReleased(loanId, token, amount);
    }

    // ---------------------------------------------------------------- curator

    /// @notice Stops or restarts funding new loans.
    function setFundingPaused(bool paused) external onlyCurator {
        fundingPaused = paused;
        emit FundingPausedSet(paused);
    }

    /// @notice Sets the largest principal one loan may take, at most `MAX_LOAN_PRINCIPAL_LIMIT`.
    function setMaxLoanPrincipal(uint128 amount) external onlyCurator {
        if (amount > MAX_LOAN_PRINCIPAL_LIMIT) revert MaxLoanAboveLimit(amount);
        maxLoanPrincipal = amount;
        emit MaxLoanPrincipalSet(amount);
    }

    /// @notice Adds pool `pool` under `adapter` to the mandate; it funds loans `MANDATE_DELAY` from now.
    function addPool(address adapter, address pool) external onlyCurator {
        _addPool(adapter, pool, uint40(block.timestamp + MANDATE_DELAY));
    }

    /// @notice Drops pool `pool` under `adapter` from the mandate at once; its open loans run to their ends.
    function removePool(address adapter, address pool) external onlyCurator {
        if (poolActiveAt[adapter][pool] == 0) revert PoolNotInMandate(adapter, pool);
        delete poolActiveAt[adapter][pool];
        uint256 n = _mandate.length;
        for (uint256 i; i < n; ++i) {
            if (_mandate[i].adapter == adapter && _mandate[i].pool == pool) {
                _mandate[i] = _mandate[n - 1];
                _mandate.pop();
                break;
            }
        }
        emit PoolRemoved(adapter, pool);
    }

    /// @notice The mandate's pools and when each funds loans from.
    function mandate() external view returns (PoolRef[] memory pools, uint40[] memory activeAt) {
        pools = _mandate;
        activeAt = new uint40[](pools.length);
        for (uint256 i; i < pools.length; ++i) {
            activeAt[i] = poolActiveAt[pools[i].adapter][pools[i].pool];
        }
    }

    /// @notice Whether this vault funds a new loan in pool `pool` under `adapter` now.
    function funds(address adapter, address pool) public view returns (bool) {
        uint40 at = poolActiveAt[adapter][pool];
        return at != 0 && at <= block.timestamp;
    }

    function _addPool(address adapter, address pool, uint40 activeAt) internal {
        if (adapter == address(0) || pool == address(0)) revert ZeroAddress();
        if (poolActiveAt[adapter][pool] != 0) revert PoolAlreadyInMandate(adapter, pool);
        if (_mandate.length == MAX_MANDATE_POOLS) revert TooManyPools();
        poolActiveAt[adapter][pool] = activeAt;
        _mandate.push(PoolRef({adapter: adapter, pool: pool}));
        emit PoolAdded(adapter, pool, activeAt);
    }

    // ------------------------------------------------------------------- fees

    /// @notice Withdraws the caller's performance-fee credit.
    function withdrawFee() external nonReentrant returns (uint256 amount) {
        amount = _withdrawFee(msg.sender);
    }

    /// @notice Pays `account`'s performance-fee credit to `account`.
    function withdrawFeeFor(address account) external nonReentrant returns (uint256 amount) {
        amount = _withdrawFee(account);
    }

    // --------------------------------------------------------------- internal

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _beforeDeposit() internal view {
        if (impaired()) revert Impaired();
        if (depositsClosed()) revert DepositsClosed();
    }

    function _depositAssets(uint256 assets, address receiver, uint256 minShares) internal returns (uint256 shares) {
        _pruneDeferred();
        if (assets == 0) revert ZeroAmount();
        _beforeDeposit();
        shares = previewDeposit(assets);
        if (shares == 0 || shares < minShares) revert Slippage();
        _deposit(msg.sender, receiver, assets, shares);
    }

    function _redeemShares(uint256 shares, address receiver, address owner, uint256 minAssets)
        internal
        returns (uint256 assets)
    {
        _pruneDeferred();
        if (shares == 0) revert ZeroAmount();
        if (impaired()) revert Impaired();
        assets = previewRedeem(shares);
        if (assets < minAssets) revert Slippage();
        _payOut(receiver, owner, assets, shares);
    }

    /// @dev Pays `assets` from free cash for `owner`'s `shares`, the caller spending an allowance unless it is `owner`.
    function _payOut(address receiver, address owner, uint256 assets, uint256 shares) internal {
        uint256 cash = freeCash();
        if (assets > cash) revert InsufficientLiquidity(assets, cash);
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Every change of shares logs both sides' exposure first. A mint or a burn changes the supply, so it writes
    /// the clock at the old supply; a transfer leaves the supply alone, so it logs at the clock's reading now without
    /// writing it, and a loan past its end still finds the clock as its last write left it.
    function _update(address from, address to, uint256 value) internal override {
        if (value != 0) {
            uint256 index = from == address(0) || to == address(0) ? _accrueExposure() : _indexNow();
            if (from != address(0)) _logExposure(from, index);
            if (to != address(0)) _logExposure(to, index);
        }
        super._update(from, to, value);
    }

    /// @dev A loan's return net of the performance fee, rounded exactly as `onRepaid` books it.
    function _netReturn(Book memory b) internal view returns (uint256) {
        uint256 gross = uint256(b.repayment) - b.principal;
        return gross - (gross * PERFORMANCE_FEE_BPS) / 10_000;
    }

    function _accruedValue(Book memory b) internal view returns (uint256) {
        uint256 net = _netReturn(b);
        uint256 span = uint256(b.end) - b.start;
        uint256 elapsed = block.timestamp >= b.end ? span : block.timestamp - b.start;
        return uint256(b.principal) + (span == 0 ? net : net.mulDiv(elapsed, span));
    }

    function _unearned(Book memory b) internal view returns (uint256) {
        if (block.timestamp >= b.end) return 0;
        uint256 span = uint256(b.end) - b.start;
        return span == 0 ? 0 : _netReturn(b).mulDiv(uint256(b.end) - block.timestamp, span);
    }

    function _pruneDeferred() internal {
        uint256 i;
        while (i < _deferred.length) {
            if (block.timestamp >= book[_deferred[i]].end) {
                _deferred[i] = _deferred[_deferred.length - 1];
                _deferred.pop();
            } else {
                ++i;
            }
        }
    }

    /// @dev Adds early repayment `b`'s unearned return to the overflow: what is left of the overflow and this return are
    /// released evenly from now to the later of their ends, so the price takes it in over time and never steps up.
    function _overflow(Book memory b) internal {
        uint256 left = _overflowLeft() + _unearned(b);
        uint256 end = _overflowEnd > b.end ? _overflowEnd : b.end;
        _overflowUnearned = left;
        _overflowAt = block.timestamp;
        _overflowEnd = end;
    }

    /// @dev What the overflow has still to earn into the price.
    function _overflowLeft() internal view returns (uint256) {
        uint256 end = _overflowEnd;
        if (block.timestamp >= end) return 0;
        return _overflowUnearned.mulDiv(end - block.timestamp, end - _overflowAt);
    }

    /// @dev Counts loan `loanId` in or out of `blockingLoans` after a change to its lots or its recovery; `was` is
    /// whether it blocked before.
    function _syncBlocking(uint256 loanId, bool was) internal {
        bool blocks = recoveryBlocks(loanId);
        if (blocks && !was) ++blockingLoans;
        else if (was && !blocks) --blockingLoans;
    }

    function _close(uint256 loanId) internal {
        uint256 slot = _openSlot[loanId];
        if (slot == 0) revert UnknownLoan(loanId);
        uint256 last = _open[_open.length - 1];
        _open[slot - 1] = last;
        _openSlot[last] = slot;
        _open.pop();
        delete _openSlot[loanId];
    }

    /// @dev Takes a closed loan out of the price at its book value and fixes the exposure its bonus is shared by: the
    /// clock from the loan's funding to its end. Nothing wrote the clock since that end (the supply cannot change while a
    /// loan sits past its end, and transfers never write it), so the reading at the end follows from the last write at
    /// the supply since then.
    function _openRecovery(uint256 loanId, Book memory b) internal {
        Checkpoint memory opened = _funded[loanId];
        uint256 at = _exposureAt;
        uint256 closedIndex = exposureIndex;
        uint256 closedTotal = totalExposure;
        if (b.end > at) {
            uint256 supply = totalSupply();
            uint256 d = (uint256(b.end) - at) * EXPOSURE_PRECISION / (supply + VIRTUAL_SHARES);
            closedIndex += d;
            closedTotal += supply * d;
        }
        uint256 bookValue = uint256(b.principal) + _netReturn(b);
        uint256 exposure = closedTotal - opened.carried;
        Recovery storage r = recovery[loanId];
        r.bookRemaining = SafeCast.toUint128(bookValue);
        r.closedIndex = closedIndex;
        r.exposure = exposure;
        emit RecoveryOpened(loanId, bookValue, exposure);
    }

    /// @dev Books what a position delivered: USDG at once, every other token as a lot waiting to be sold.
    function _bookDelivered(uint256 loanId, address[] calldata tokens, uint256[] calldata amounts) internal {
        if (tokens.length != amounts.length) revert LengthMismatch();
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (token == address(USDG)) {
                _creditRecovery(loanId, amount);
                continue;
            }
            Lot storage l = _lots[loanId][token];
            if (l.amount == 0) ++pendingLots[loanId];
            l.amount += SafeCast.toUint128(amount);
            l.since = uint40(block.timestamp);
            if (recoveryBalance[token] == 0) _recoveryTokens.push(token);
            recoveryBalance[token] += amount;
        }
    }

    /// @dev USDG a defaulted loan recovered: up to its book value it stays in the price, the rest is its bonus.
    function _creditRecovery(uint256 loanId, uint256 amount) internal {
        Recovery storage r = recovery[loanId];
        uint256 owed = r.bookRemaining;
        uint256 toBook = amount < owed ? amount : owed;
        r.bookRemaining = uint128(owed - toBook);
        uint256 extra = amount - toBook;
        // Nobody held shares while the loan ran: the price keeps the extra.
        if (extra == 0 || r.exposure == 0) return;
        r.bonus += extra;
        totalBonusHeld += extra;
        emit BonusSetAside(loanId, extra);
    }

    function _claimBonus(uint256 loanId, address account) internal returns (uint256 amount) {
        amount = bonusClaimable(loanId, account);
        if (amount == 0) revert NothingToWithdraw();
        bonusClaimed[loanId][account] += amount;
        totalBonusHeld -= amount;
        USDG.safeTransfer(account, amount);
        emit BonusClaimed(loanId, account, amount);
    }

    /// @dev Removes `amount` of `token` from the books: from what waits to be sold, or from what was written off.
    function _unbook(address token, uint256 amount, bool writtenOff) internal {
        if (writtenOff) {
            uint256 off = writtenOffBalance[token] - amount;
            writtenOffBalance[token] = off;
            if (off == 0) _remove(_writtenOffTokens, token);
        } else {
            uint256 pending = recoveryBalance[token] - amount;
            recoveryBalance[token] = pending;
            if (pending == 0) _remove(_recoveryTokens, token);
        }
    }

    function _remove(address[] storage list, address token) internal {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == token) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
        }
    }

    /// @dev Advances the exposure clock to now. Between two writes the supply was constant, so every holder's exposure
    /// grew by its shares times the clock's movement.
    function _accrueExposure() internal returns (uint256 index) {
        index = exposureIndex;
        uint256 at = _exposureAt;
        if (block.timestamp == at) return index;
        uint256 supply = totalSupply();
        uint256 d = (block.timestamp - at) * EXPOSURE_PRECISION / (supply + VIRTUAL_SHARES);
        index += d;
        exposureIndex = index;
        totalExposure += supply * d;
        _exposureAt = block.timestamp;
    }

    /// @dev The clock's reading now, unwritten: the last write plus the movement since at the supply since then, exactly
    /// what writing it now would store.
    function _indexNow() internal view returns (uint256) {
        uint256 at = _exposureAt;
        if (block.timestamp == at) return exposureIndex;
        return exposureIndex + (block.timestamp - at) * EXPOSURE_PRECISION / (totalSupply() + VIRTUAL_SHARES);
    }

    /// @dev Logs `who`'s exposure up to the clock reading `index`, before its shares change.
    function _logExposure(address who, uint256 index) internal {
        Checkpoint[] storage h = _exposure[who];
        uint256 n = h.length;
        if (n == 0) {
            h.push(Checkpoint({index: index, carried: 0}));
            return;
        }
        Checkpoint storage last = h[n - 1];
        if (last.index == index) return;
        h.push(Checkpoint({index: index, carried: last.carried + balanceOf(who) * (index - last.index)}));
    }

    /// @dev The exposure `who` had carried when the clock read `index`. Between two checkpoints its shares were
    /// constant, so its exposure grew with the clock.
    function _exposureOf(address who, uint256 index) internal view returns (uint256) {
        Checkpoint[] storage h = _exposure[who];
        uint256 lo;
        uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h[mid].index <= index) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return 0;
        Checkpoint storage c = h[lo - 1];
        if (lo == h.length) return c.carried + balanceOf(who) * (index - c.index);
        Checkpoint storage next = h[lo];
        return c.carried + (next.carried - c.carried).mulDiv(index - c.index, next.index - c.index);
    }

    function _creditFee(address account, uint256 amount) internal {
        if (amount == 0) return;
        feeCredit[account] += amount;
        totalFeeCredit += amount;
        emit FeeCredited(account, amount);
    }

    function _withdrawFee(address account) internal returns (uint256 amount) {
        amount = feeCredit[account];
        if (amount == 0) revert NothingToWithdraw();
        feeCredit[account] = 0;
        totalFeeCredit -= amount;
        USDG.safeTransfer(account, amount);
        emit FeeWithdrawn(account, amount);
    }
}
