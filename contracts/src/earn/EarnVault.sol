// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICollateralRegistry, Lane} from "../interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../types/Types.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {GageV2Rewards} from "../v2/GageV2Rewards.sol";
import {GageV2CollateralValidator} from "../v2/GageV2CollateralValidator.sol";
import {IGageV2LegacyCore} from "../interfaces/IGageV2LegacyCore.sol";
import {GageV2CollateralAccount} from "../v2/GageV2CollateralAccount.sol";
import {GradeRegistry} from "./GradeRegistry.sol";

/// @notice Earn portfolio categories; registry STOCK tokens count as STOCK, registry MEME as MEME. Registry ETH tokens back no
/// Earn loan (D124): ether is not a stock.
enum EarnLane {
    STOCK,
    MEME,
    LP
}

/// @notice A pooled USDG strategy over idle cash, an ERC-4626 reserve and Gage V2 loans carried at principal.
/// @dev Third design of the Earn vault. Nothing about a loan is read inside a deposit or a redemption: every
/// outcome is booked by an explicit, permissionless `settle`, so user actions cost the same whatever the book
/// holds. The one thing a user action checks is that no loan has passed the end of its term unsettled; until
/// someone settles it, pricing stops, so nobody can leave before a write-down or enter before it. The core has no
/// grace window: a loan is repaid before its term ends or it defaults that same second, so a loan repaid at any
/// time the core allows is a repayment, and a loan is written off only once the core lets it be finalized as a
/// default. Recovered collateral then belongs, in kind, to the holders of
/// record at that moment and is claimed from a side pocket. Profit unlocks linearly over seven days so a deposit
/// cannot capture a repayment that just landed. The performance fee is charged only on profit that lifts the share
/// price above its high-water mark and is split with the protocol floor at once. Shares are not transferable.
/// @dev The factory answers where the protocol's fee share goes and which fill router may fund on a filler's behalf;
/// its owner may move both for every strategy at once.
interface IProtocolSource {
    function protocolRecipient() external view returns (address);
    function fillRouter() external view returns (address);
}

contract EarnVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Version of the mandate tuple and category indices; earlier deployments use another shape.
    uint256 public constant MANDATE_VERSION = 3;
    /// @notice Virtual shares of the conversion denominator: one USDG unit starts worth 10^12 shares.
    uint256 public constant VIRTUAL_SHARES = 1e12;
    /// @notice Interest accrues in USDG units scaled by this, so per-second rates carry no rounding drift.
    uint256 internal constant RATE_PRECISION = 1e18;
    uint256 public constant MAX_OPEN_LOANS = 128;
    uint256 public constant MAX_BATCH = 32;
    uint16 public constant MAX_FEE_BPS = 5000;
    uint8 internal constant UNITS = 4;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_PRECISION = 1e36;
    uint256 internal constant REWARD_PRECISION = 1e18;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    /// @notice What a creator decides. `laneWeights`, `assets`, `feeBps` and `maxTotalDeposits` may move later;
    /// `curator` and `maxLoanTerm` never do. The curator's fee share is paid to the curator until it names another
    /// recipient. Each weight caps one category independently (100 / 100 / 100 opens the whole pot to any of
    /// them). An empty `assets` list admits every registry token in an open category; a non-empty list admits
    /// only those tokens, each of which the registry must already allow.
    struct Mandate {
        address curator;
        uint16[3] laneWeights;
        address[] assets;
        uint32 maxLoanTerm;
        uint16 feeBps;
        uint128 maxTotalDeposits;
        /// @dev The lowest grade rank a collateral token may carry to back a new loan; 0 admits any registry token.
        uint8 minGrade;
        /// @dev The lowest rate grade a listing may carry (D127): its offered cost against the registry's modeled cost,
        ///      1 = D (50%), 2 = C (75%), 3 = B (90%), 4 = A (100%); 0 admits any cost.
        uint8 minRateGrade;
    }

    struct Params {
        address core;
        address reserve;
        address grades;
        /// @dev The factory: `protocolRecipient()` on it names where the protocol's fee share goes, updatable there.
        address protocolSource;
        uint16 protocolShareBps;
        Mandate mandate;
    }

    struct Loan {
        uint8 slots;
        EarnLane lane;
        uint16 feeBps;
        /// @dev The end of the term, when repayment closes and the default opens. Exact once the loan is active; a
        ///      lower bound while other lenders may still fill it.
        uint40 maturity;
        /// @dev The curator released the strategy's units before the listing activated; only a refund can follow.
        bool withdrawn;
        bool settled;
        bool recovered;
        uint64 snapshotId;
        uint128 principal;
        uint256 snapshotSupply;
        /// @dev The strategy's share of the fixed cost less the fee, earned evenly from activation to maturity.
        uint128 interest;
        /// @dev `interest` scaled by RATE_PRECISION per second of running clock; zero until the loan is seen active.
        uint128 rate;
        uint64 clockStart;
    }

    struct Pocket {
        uint256 loanId;
        address token;
        uint256 amount;
        uint256 supply;
        uint256 claimed;
        uint64 snapshotId;
    }

    struct Snapshot {
        uint64 id;
        uint256 balance;
    }

    GageV2Vault public immutable VAULT;
    GageV2Rewards public immutable CORE_REWARDS;
    GageV2CollateralValidator public immutable VALIDATOR;
    ICollateralRegistry public immutable REGISTRY;
    IERC4626 public immutable RESERVE;
    /// @notice Grades published from the valuation service; read only when the strategy has a minimum grade.
    GradeRegistry public immutable GRADES;
    /// @notice The lowest collateral grade rank a new loan may carry; curator-adjustable (D127), open loans unaffected.
    uint8 public minGrade;
    /// @notice The lowest rate grade a new loan may carry (D127); curator-adjustable, open loans unaffected.
    uint8 public minRateGrade;
    uint8 public constant MAX_RATE_GRADE = 4;
    IERC20 public immutable USDG;
    IERC20 public immutable REWARD_TOKEN;
    address public immutable CURATOR;
    address public immutable PROTOCOL_SOURCE;
    uint16 public immutable PROTOCOL_SHARE_BPS;
    /// @notice The longest loan term this strategy funds, one of the terms the registry allowed at creation.
    uint32 public immutable MAX_TERM;
    /// @notice One whole USDG: the smallest deposit and the smallest redemption request.
    uint256 public immutable MIN_DEPOSIT;

    // Curator settings.
    mapping(EarnLane => uint16) public laneWeightBps;
    /// @notice Picked collateral tokens; while `pickedAssets` is non-zero, only these are admitted.
    mapping(address => bool) public assetPicked;
    uint256 public pickedAssets;
    uint128 public maxTotalDeposits;
    uint16 public feeBps;
    address public feeRecipient;
    bool public paused;
    /// @notice Whether the factory's fill router may fund on a filler's behalf; the curator may opt out.
    bool public fillersOpen;
    /// @notice The most principal one listing may take from this strategy over every fill; zero is no cap.
    uint128 public maxLoanPrincipal;
    /// @notice The most principal one collateral token may back, as a share of strategy assets; zero is no cap.
    uint16 public maxAssetBps;
    /// @notice The share of strategy assets a fill must leave in free liquidity; zero is no buffer.
    uint16 public bufferBps;
    // Shares.
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => Snapshot[]) private _snapshots;
    uint64 public snapshotCount;
    // Assets. USDG held = cash + fees + claimable + USDG pockets + unassignedCash.
    uint256 public cash;
    uint256 public reserveShares;
    uint256 public performingPrincipal;
    mapping(EarnLane => uint256) public lanePrincipal;
    /// @notice Outstanding principal backed by each collateral token, for the per-asset cap.
    mapping(address => uint256) public assetPrincipal;
    // Interest: the running clock advances while no loan is past its term unsettled, and every active loan
    // accrues its net interest on it; a loan's own accrual is capped at its interest and settled at its outcome.
    uint256 public accrualRate;
    uint256 private _accrued;
    uint64 private _clockBase;
    uint64 private _clockAt;
    uint256 public curatorFees;
    uint256 public protocolFees;
    /// @notice USDG pulled from the core and not yet booked to a loan outcome.
    uint256 public unassignedCash;
    // Side pockets.
    mapping(uint256 => Pocket) public pockets;
    uint256 public pocketCount;
    mapping(uint256 => mapping(address => bool)) public pocketClaimed;
    mapping(address => uint256) public pocketLiability;
    // Rewards.
    uint256 public accRewardPerShare;
    uint256 public accountedRewards;
    mapping(address => uint256) private _rewardIndex;
    mapping(address => uint256) private _rewardOwed;
    // Loans.
    mapping(uint256 => Loan) public loans;
    uint256[] private _openLoans;
    /// @notice The earliest end of term among open loans, when repayment closes and the default can be finalized;
    ///         pricing pauses from then until the loan is settled.
    uint40 public earliestMaturity = NO_DEADLINE;

    event LaneWeightSet(EarnLane indexed lane, uint16 bps);
    event AssetSet(address indexed token, bool picked);
    event MaxTotalDepositsSet(uint256 cap);
    event MinGradeSet(uint8 rank);
    event MinRateGradeSet(uint8 rank);
    event FeeSet(uint16 bps);
    event FeeRecipientSet(address indexed recipient);
    event FeesClaimed(address indexed curatorRecipient, uint256 curatorAmount, uint256 protocolAmount);
    event Paused(bool enabled);
    event FillersOpenSet(bool enabled);
    event LimitsSet(uint128 maxLoanPrincipal, uint16 maxAssetBps, uint16 bufferBps);
    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, uint256 assets, uint256 shares);
    event ReserveInvested(uint256 assets, uint256 shares);
    event ReserveDivested(uint256 shares, uint256 assets);
    event LoanFunded(uint256 indexed loanId, uint256 principal, uint8 slots, uint16 feeBps);
    event LoanAccruing(uint256 indexed loanId, uint256 interest, uint40 maturity);
    event CommitmentWithdrawn(uint256 indexed loanId, uint256 principal);
    event CashHarvested(uint256 amount);
    event LoanSettled(uint256 indexed loanId, V2State state, uint256 payout);
    event LoanWrittenOff(uint256 indexed loanId, uint256 principal, uint64 snapshotId);
    event ProfitReported(uint256 indexed loanId, uint256 profit, uint256 fee);
    event LossReported(uint256 indexed loanId, uint256 principal, uint256 earned);
    event CollateralRecovered(uint256 indexed loanId, address indexed token, uint256 amount);
    event PocketCreated(
        uint256 indexed pocketId, uint256 indexed loanId, address indexed token, uint256 amount, uint256 supply
    );
    event PocketClaimed(uint256 indexed pocketId, address indexed account, uint256 amount);
    event RewardsHarvested(uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);

    error InvalidConfiguration();
    error InvalidAmount();
    error NotCurator();
    error PausedError();
    error IneligibleDeal();
    error LimitExceeded();
    error InsufficientLiquidity();
    error TransferAmountMismatch();
    error Slippage();
    error UnknownDeal();
    error SettlementDue();
    error NothingToRecover();

    constructor(Params memory p) {
        Mandate memory m = p.mandate;
        if (
            p.core.code.length == 0 || p.reserve.code.length == 0 || p.protocolShareBps > BPS
                || (p.protocolShareBps != 0 && p.protocolSource.code.length == 0) || m.curator == address(0)
                || m.curator == address(this) || m.feeBps > MAX_FEE_BPS
        ) revert InvalidConfiguration();
        VAULT = GageV2Vault(p.core);
        VALIDATOR = IGageV2LegacyCore(address(VAULT)).VALIDATOR();
        CORE_REWARDS = VAULT.REWARDS();
        REGISTRY = ICollateralRegistry(address(VAULT.REGISTRY()));
        USDG = VAULT.USDG();
        REWARD_TOKEN = VAULT.SGAGE();
        RESERVE = IERC4626(p.reserve);
        GRADES = GradeRegistry(p.grades);
        minGrade = m.minGrade;
        minRateGrade = m.minRateGrade;
        if ((m.minGrade != 0 || m.minRateGrade != 0) && p.grades.code.length == 0) revert InvalidConfiguration();
        if (m.minGrade > GRADES.MAX_GRADE() || m.minRateGrade > MAX_RATE_GRADE) revert InvalidConfiguration();
        // The strategy pins a core without a grace window: repayment closes the second the term ends.
        if (
            RESERVE.asset() != address(USDG) || VAULT.GRACE() != 0 || address(REWARD_TOKEN) == address(USDG)
                || address(REWARD_TOKEN) == address(RESERVE) || !REGISTRY.isTermAllowed(m.maxLoanTerm)
        ) revert InvalidConfiguration();
        uint8 decimals_ = IERC20Metadata(address(USDG)).decimals();
        if (decimals_ > 18) revert InvalidConfiguration();
        MIN_DEPOSIT = 10 ** decimals_;
        CURATOR = m.curator;
        PROTOCOL_SOURCE = p.protocolSource;
        PROTOCOL_SHARE_BPS = p.protocolShareBps;
        MAX_TERM = m.maxLoanTerm;
        for (uint256 i; i < 3; ++i) {
            if (m.laneWeights[i] > BPS) revert InvalidConfiguration();
            laneWeightBps[EarnLane(i)] = m.laneWeights[i];
        }
        for (uint256 i; i < m.assets.length; ++i) {
            _setAsset(m.assets[i], true);
        }
        feeRecipient = m.curator;
        feeBps = m.feeBps;
        maxTotalDeposits = m.maxTotalDeposits;
        fillersOpen = true;
        _clockAt = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------- curator settings

    /// @notice Cap one category's outstanding principal as a share of strategy assets; zero closes it.
    function setLaneWeight(EarnLane lane, uint16 bps) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (bps > BPS) revert InvalidConfiguration();
        laneWeightBps[lane] = bps;
        emit LaneWeightSet(lane, bps);
    }

    /// @notice Pick or unpick one collateral token; picking needs the registry to allow it. Removing the last
    /// pick reopens the strategy to every registry token in an open category.
    function setAsset(address token, bool picked) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        _setAsset(token, picked);
    }

    /// @notice Move the deposit cap; zero closes deposits, existing positions are untouched. Pausing closes lending.
    /// @notice The first release's name for the collateral grade floor; readers of that release keep working.
    function MIN_GRADE() external view returns (uint8) {
        return minGrade;
    }

    /// @notice Move the collateral grade floor for new loans (D127); open loans run to settlement.
    function setMinGrade(uint8 rank) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (rank > GRADES.MAX_GRADE()) revert InvalidConfiguration();
        minGrade = rank;
        emit MinGradeSet(rank);
    }

    /// @notice Move the rate grade floor for new loans (D127); open loans run to settlement.
    function setMinRateGrade(uint8 rank) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (rank > MAX_RATE_GRADE) revert InvalidConfiguration();
        minRateGrade = rank;
        emit MinRateGradeSet(rank);
    }

    function setMaxTotalDeposits(uint128 cap) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        maxTotalDeposits = cap;
        emit MaxTotalDepositsSet(cap);
    }

    /// @notice Set the fee rate on interest for loans funded afterwards; funded loans keep their snapshot.
    function setFee(uint16 bps) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (bps > MAX_FEE_BPS) revert InvalidConfiguration();
        feeBps = bps;
        emit FeeSet(bps);
    }

    /// @notice Change where the curator's fee share is paid.
    function setFeeRecipient(address recipient) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        _setFeeRecipient(recipient);
    }

    /// @notice Pause deposits, reserve investment and funding. Exits stay open.
    function setPaused(bool enabled) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        paused = enabled;
        emit Paused(enabled);
    }

    /// @notice Bound what one fill may do: the cap per listing (its whole principal here, over every fill), the cap
    /// per collateral token and the free-liquidity buffer a fill must leave, the last two as shares of assets. Zero
    /// lifts a bound. Open loans are untouched; a bound that is now exceeded only refuses new fills.
    function setLimits(uint128 maxLoanPrincipal_, uint16 maxAssetBps_, uint16 bufferBps_) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (maxAssetBps_ > BPS || bufferBps_ > BPS) revert InvalidConfiguration();
        maxLoanPrincipal = maxLoanPrincipal_;
        maxAssetBps = maxAssetBps_;
        bufferBps = bufferBps_;
        emit LimitsSet(maxLoanPrincipal_, maxAssetBps_, bufferBps_);
    }

    /// @notice Let the factory's fill router fund within the mandate on a filler's behalf, or keep funding to the
    /// curator alone. Open loans are untouched either way.
    function setFillersOpen(bool enabled) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        fillersOpen = enabled;
        emit FillersOpenSet(enabled);
    }

    /// @notice Pay charged fees to the curator recipient and to the protocol recipient the factory names now;
    /// anyone may call.
    function claimFees() external nonReentrant {
        uint256 curatorAmount = curatorFees;
        uint256 protocolAmount = protocolFees;
        curatorFees = 0;
        protocolFees = 0;
        if (curatorAmount != 0) USDG.safeTransfer(feeRecipient, curatorAmount);
        if (protocolAmount != 0) {
            USDG.safeTransfer(IProtocolSource(PROTOCOL_SOURCE).protocolRecipient(), protocolAmount);
        }
        emit FeesClaimed(feeRecipient, curatorAmount, protocolAmount);
    }

    // ---------------------------------------------------------------- views

    /// @notice The deposit token.
    function asset() external view returns (address) {
        return address(USDG);
    }

    /// @notice Shares carry eighteen decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice What shares are priced on: cash, the reserve at its own conversion, open loans at principal and the
    /// interest they have earned so far. Deposits and redemptions convert at this one value.
    function totalAssets() public view returns (uint256) {
        return cash + RESERVE.convertToAssets(reserveShares) + performingPrincipal + accruedInterest();
    }

    /// @notice Net interest the open loans have earned so far, in USDG units.
    function accruedInterest() public view returns (uint256) {
        return (_accrued + accrualRate * (_clockNow() - _clockBase)) / RATE_PRECISION;
    }

    /// @notice Seconds the interest clock has run: it stops at the earliest end of term until that loan settles.
    function _clockNow() internal view returns (uint256) {
        uint256 stop = Math.min(block.timestamp, earliestMaturity);
        uint256 at = _clockAt;
        return _clockBase + (stop > at ? stop - at : 0);
    }

    /// @notice Shares for a deposit, rounded down against the depositor.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + 1);
    }

    /// @notice USDG for shares, rounded down against the redeemer.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply + VIRTUAL_SHARES);
    }

    /// @notice Cash plus the reserve position, capped by the reserve's own withdrawal limit when it reports one.
    function freeLiquidity() public view returns (uint256) {
        uint256 value = RESERVE.convertToAssets(reserveShares);
        uint256 limit = RESERVE.maxWithdraw(address(this));
        return cash + (limit == 0 ? value : Math.min(value, limit));
    }

    /// @notice The holder's balance when a snapshot was taken; the current balance if unchanged since.
    function balanceOfAt(address who, uint64 snapshotId) public view returns (uint256) {
        Snapshot[] storage s = _snapshots[who];
        uint256 lo;
        uint256 hi = s.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (s[mid].id < snapshotId) lo = mid + 1;
            else hi = mid;
        }
        return lo == s.length ? balanceOf[who] : s[lo].balance;
    }

    /// @notice Collateral one holder may still claim from a side pocket.
    function pocketClaimable(uint256 pocketId, address who) public view returns (uint256) {
        Pocket storage pk = pockets[pocketId];
        if (pk.supply == 0 || pocketClaimed[pocketId][who]) return 0;
        return Math.mulDiv(pk.amount, balanceOfAt(who, pk.snapshotId), pk.supply);
    }

    /// @notice Accrued sGAGE the holder may claim.
    function rewardClaimable(address who) public view returns (uint256) {
        return _rewardOwed[who] + Math.mulDiv(balanceOf[who], accRewardPerShare - _rewardIndex[who], REWARD_PRECISION);
    }

    // ---------------------------------------------------------------- depositors

    /// @notice Add USDG and receive shares at the current price.
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (paused) revert PausedError();
        _requireSettled();
        if (assets < MIN_DEPOSIT) revert InvalidAmount();
        if (totalAssets() + assets > maxTotalDeposits) revert LimitExceeded();
        shares = convertToShares(assets);
        if (shares == 0 || shares < minShares) revert Slippage();
        uint256 before_ = USDG.balanceOf(address(this));
        USDG.safeTransferFrom(msg.sender, address(this), assets);
        if (USDG.balanceOf(address(this)) - before_ != assets) revert TransferAmountMismatch();
        cash += assets;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burn shares for USDG at once, from cash and then the reserve, up to what is liquid now; the rest
    /// stays as shares for a later redemption.
    function redeem(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        _requireSettled();
        if (shares == 0 || shares > balanceOf[msg.sender]) revert InvalidAmount();
        assets = convertToAssets(shares);
        if (assets < minAssets) revert Slippage();
        if (assets > freeLiquidity()) revert InsufficientLiquidity();
        _payOut(assets);
        _burn(msg.sender, shares);
        USDG.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, assets, shares);
    }

    /// @notice Withdraw the caller's part of one side pocket, in the recovered asset.
    function claimPocket(uint256 pocketId) external nonReentrant returns (uint256 amount) {
        Pocket storage pk = pockets[pocketId];
        if (pk.supply == 0) revert UnknownDeal();
        if (pocketClaimed[pocketId][msg.sender]) revert InvalidAmount();
        pocketClaimed[pocketId][msg.sender] = true;
        amount = Math.mulDiv(pk.amount, balanceOfAt(msg.sender, pk.snapshotId), pk.supply);
        if (amount == 0) revert InvalidAmount();
        pk.claimed += amount;
        pocketLiability[pk.token] -= amount;
        if (pk.token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferAmountMismatch();
        } else {
            IERC20(pk.token).safeTransfer(msg.sender, amount);
        }
        emit PocketClaimed(pocketId, msg.sender, amount);
    }

    /// @notice Withdraw the caller's accrued sGAGE.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _settleRewards(msg.sender);
        amount = _rewardOwed[msg.sender];
        if (amount == 0) revert InvalidAmount();
        _rewardOwed[msg.sender] = 0;
        accountedRewards -= amount;
        REWARD_TOKEN.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- reserve

    /// @notice Move idle cash into the reserve; the curator or the fill router, while not paused, so nobody else
    /// can push the cash a fill or an exit would use behind the reserve's withdrawal limit.
    function investReserve(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (paused) revert PausedError();
        _requireFunder();
        if (assets == 0 || assets > cash) revert InvalidAmount();
        uint256 beforeCash = USDG.balanceOf(address(this));
        uint256 beforeShares = RESERVE.balanceOf(address(this));
        USDG.forceApprove(address(RESERVE), assets);
        RESERVE.deposit(assets, address(this));
        USDG.forceApprove(address(RESERVE), 0);
        shares = RESERVE.balanceOf(address(this)) - beforeShares;
        if (beforeCash - USDG.balanceOf(address(this)) != assets) revert TransferAmountMismatch();
        if (shares == 0 || shares < minShares) revert Slippage();
        cash -= assets;
        reserveShares += shares;
        emit ReserveInvested(assets, shares);
    }

    /// @notice Bring reserve shares back to idle cash; curator only, so nobody else can forgo reserve returns.
    function divestReserve(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (msg.sender != CURATOR) revert NotCurator();
        if (shares == 0 || shares > reserveShares) revert InvalidAmount();
        uint256 beforeCash = USDG.balanceOf(address(this));
        uint256 beforeShares = RESERVE.balanceOf(address(this));
        RESERVE.redeem(shares, address(this), address(this));
        assets = USDG.balanceOf(address(this)) - beforeCash;
        if (beforeShares - RESERVE.balanceOf(address(this)) != shares) revert TransferAmountMismatch();
        if (assets < minAssets) revert Slippage();
        reserveShares -= shares;
        cash += assets;
        emit ReserveDivested(shares, assets);
    }

    // ---------------------------------------------------------------- loans

    /// @notice Buy `units` unfilled lender units of one currently eligible listing, from cash and then the reserve.
    /// The curator, or the factory's fill router on a filler's behalf while fillers are open; one transaction, and
    /// the reserve's withdrawal limit counts. The mandate is checked here whoever calls.
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external nonReentrant {
        if (paused) revert PausedError();
        _requireFunder();
        _requireSettled();
        Loan storage ln = loans[id];
        // A listing the strategy already holds can be bought into again while it is still funding (D127).
        bool topUp = ln.principal != 0;
        if (!topUp && _openLoans.length >= MAX_OPEN_LOANS) revert LimitExceeded();
        V2Loan memory l = VAULT.getLoan(id);
        (uint8 slots, uint256 principal) = _selectSlots(id, l.principal, units);
        EarnLane lane = _checkDeal(id, l, units, principal);
        // The fill must leave the buffer's share of assets liquid; assets do not move when cash becomes principal.
        if (principal + Math.mulDiv(bufferBps, totalAssets(), BPS) > freeLiquidity()) revert InsufficientLiquidity();
        _accrue();
        uint256 burned = _payOut(principal);
        if (burned > maxReserveShares) revert Slippage();
        uint256 before_ = USDG.balanceOf(address(this));
        USDG.forceApprove(address(VAULT), principal);
        VAULT.fund(id, units);
        USDG.forceApprove(address(VAULT), 0);
        if (before_ - USDG.balanceOf(address(this)) != principal) revert TransferAmountMismatch();
        // A top-up keeps the fee rate booked at the first purchase; the record grows by the new quarters.
        uint16 fee = topUp ? ln.feeBps : feeBps;
        ln.slots |= slots;
        ln.lane = lane;
        ln.feeBps = fee;
        ln.principal += uint128(principal);
        // The strategy's share of the fixed cost, less its fee, is what the loan earns if it repays.
        uint256 gross = _sliceSum(l.cap, slots) - principal;
        ln.interest += uint128(gross - Math.mulDiv(gross, fee, BPS));
        if (!topUp) _openLoans.push(id);
        performingPrincipal += principal;
        lanePrincipal[lane] += principal;
        assetPrincipal[l.token] += principal;
        emit LoanFunded(id, principal, slots, fee);
        // Active now if this purchase filled the listing. Otherwise the term cannot end before now plus the term, so
        // pricing may pause early until a settle records the exact maturity, never late.
        l = VAULT.getLoan(id);
        uint40 maturity = uint40((l.state == V2State.ACTIVE ? uint256(l.fundedAt) : block.timestamp) + l.term);
        _setMaturity(ln, maturity);
        if (l.state == V2State.ACTIVE) _startAccrual(id, ln, maturity);
    }

    /// @notice Release this strategy's units from a listing that has not activated, at any time before it does;
    /// the refund is booked by `settle` once the cash is here, whatever the listing does afterwards.
    function withdrawCommitment(uint256 id) external nonReentrant {
        Loan storage ln = loans[id];
        if (ln.principal == 0 || ln.withdrawn || ln.settled) revert UnknownDeal();
        if (msg.sender != CURATOR) revert NotCurator();
        ln.withdrawn = true;
        VAULT.withdrawCommitment(id);
        emit CommitmentWithdrawn(id, ln.principal);
    }

    /// @notice Pull core repayments and refunds and book every listed loan whose outcome is known; anyone may call,
    /// and an empty batch only harvests.
    /// @dev A repaid, withdrawn or cancelled loan settles once its cash has arrived, and a listing past its funding
    /// deadline is cancelled on the core and refunded. A withdrawn commitment is only ever refunded, even if others
    /// filled the listing and let it default. An active loan past the end of its term is finalized as a default and written off; its
    /// collateral is pulled by `recover`. An active loan still in term only has its exact maturity recorded.
    function settle(uint256[] calldata ids) external nonReentrant {
        if (ids.length > MAX_BATCH) revert InvalidAmount();
        _harvest();
        _accrue();
        for (uint256 i; i < ids.length; ++i) {
            _settle(ids[i]);
        }
    }

    /// @notice Unwind a written-off loan's collateral into side pockets for the holders of record; anyone may
    /// call, and a failed attempt (a paused token, an illiquid pool) can be retried.
    function recover(uint256 id) external nonReentrant {
        Loan storage ln = loans[id];
        if (ln.snapshotId == 0 || ln.recovered) revert NothingToRecover();
        V2Loan memory l = VAULT.getLoan(id);
        GageV2CollateralAccount custody = GageV2CollateralAccount(payable(l.account));
        if (!custody.recovered()) {
            // In kind, no swap: an LP position is removed into its two assets whatever the pool's price.
            VAULT.recoverDefault(id, l.kind == Kind.ERC20 ? l.collateral : 0, 0, block.timestamp);
        }
        ln.recovered = true;
        for (uint8 assetIndex; assetIndex < 2; ++assetIndex) {
            uint256 amount = VAULT.claimableRecovery(id, assetIndex, address(this));
            if (amount == 0) continue;
            address token = custody.recoveryTokens(assetIndex);
            uint256 before_ = _held(token);
            VAULT.withdrawRecovery(id, assetIndex, address(this));
            if (_held(token) - before_ != amount) revert TransferAmountMismatch();
            _openPocket(id, ln, token, amount);
            emit CollateralRecovered(id, token, amount);
        }
    }

    /// @notice Claim released sGAGE for funded loans and spread it over every share; anyone may call.
    function harvestRewards(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            try CORE_REWARDS.claim(ids[i], address(this)) {} catch {}
        }
        uint256 balance = REWARD_TOKEN.balanceOf(address(this));
        uint256 reserved = accountedRewards + pocketLiability[address(REWARD_TOKEN)];
        uint256 supply = totalSupply;
        if (balance > reserved && supply != 0) {
            uint256 amount = balance - reserved;
            accountedRewards += amount;
            accRewardPerShare += Math.mulDiv(amount, REWARD_PRECISION, supply);
            emit RewardsHarvested(amount);
        }
    }

    // ---------------------------------------------------------------- internals

    function _requireSettled() internal view {
        if (block.timestamp >= earliestMaturity) revert SettlementDue();
    }

    /// @dev The curator always; the factory's current fill router only while the curator keeps fillers open.
    function _requireFunder() internal view {
        if (msg.sender == CURATOR) return;
        if (!fillersOpen || msg.sender != IProtocolSource(PROTOCOL_SOURCE).fillRouter()) revert NotCurator();
    }

    /// @dev Pull the core's credit, and count any USDG that reached this contract outside `cash` as harvested.
    function _harvest() internal {
        // A paused USDG must not stop collateral settlement; uncollected credit stays with the core.
        if (VAULT.cashCredit(address(this)) != 0) try VAULT.withdrawUSDG(address(this)) {} catch {}
        uint256 accounted = cash + curatorFees + protocolFees + pocketLiability[address(USDG)] + unassignedCash;
        uint256 balance = USDG.balanceOf(address(this));
        if (balance > accounted) {
            uint256 amount = balance - accounted;
            unassignedCash += amount;
            emit CashHarvested(amount);
        }
    }

    function _settle(uint256 id) internal {
        Loan storage ln = loans[id];
        if (ln.principal == 0) revert UnknownDeal();
        if (ln.settled) return;
        V2Loan memory l = VAULT.getLoan(id);
        uint256 principal = ln.principal;
        uint256 payout;
        if (ln.withdrawn || l.state == V2State.CANCELLED) {
            payout = principal;
        } else if (l.state == V2State.FUNDING) {
            // A listing that missed its deadline can never activate: anyone may cancel it on the core, which credits
            // every lender's units, and the refund is booked once that cash is here.
            if (block.timestamp < l.fundingDeadline) return;
            VAULT.cancelFunding(id);
            l.state = V2State.CANCELLED;
            _harvest();
            payout = principal;
        } else if (l.state == V2State.REPAID) {
            payout = _sliceSum(l.cap, ln.slots);
        } else if (l.state == V2State.ACTIVE) {
            uint40 exact = uint40(uint256(l.fundedAt) + l.term);
            if (ln.maturity != exact) _setMaturity(ln, exact);
            // Seen active for the first time: the fixed cost is earned from here to the end of the term.
            if (ln.rate == 0 && ln.interest != 0 && block.timestamp < exact) _startAccrual(id, ln, exact);
            if (block.timestamp < exact) return;
            try VAULT.finalizeDefault(id) {
                l.state = V2State.DEFAULTED;
            } catch {
                return;
            }
        } else if (l.state != V2State.DEFAULTED) {
            return;
        }
        if (!ln.withdrawn && l.state == V2State.DEFAULTED) {
            _close(id, ln, l.token, principal);
            uint256 earned = _stopAccrual(ln);
            uint64 snapshotId = ++snapshotCount;
            ln.snapshotId = snapshotId;
            ln.snapshotSupply = totalSupply;
            emit LossReported(id, principal, earned);
            emit LoanWrittenOff(id, principal, snapshotId);
            return;
        }
        if (payout > unassignedCash) return;
        unassignedCash -= payout;
        _close(id, ln, l.token, principal);
        _stopAccrual(ln);
        cash += payout;
        if (payout > principal) {
            // The fee is charged on the interest actually received, at the rate snapshotted when the loan was funded.
            uint256 profit = payout - principal;
            uint256 fee = Math.mulDiv(profit, ln.feeBps, BPS);
            uint256 protocolShare = Math.mulDiv(fee, PROTOCOL_SHARE_BPS, BPS);
            cash -= fee;
            protocolFees += protocolShare;
            curatorFees += fee - protocolShare;
            emit ProfitReported(id, profit, fee);
        } else if (payout < principal) {
            emit LossReported(id, principal - payout, 0);
        }
        emit LoanSettled(id, l.state, payout);
    }

    /// @dev Take the loan out of priced assets and the open set, refreshing the earliest maturity.
    function _close(uint256 id, Loan storage ln, address token, uint256 principal) internal {
        ln.settled = true;
        performingPrincipal -= principal;
        lanePrincipal[ln.lane] -= principal;
        assetPrincipal[token] -= principal;
        uint256 last = _openLoans.length - 1;
        for (uint256 i; i <= last; ++i) {
            if (_openLoans[i] == id) {
                if (i != last) _openLoans[i] = _openLoans[last];
                break;
            }
        }
        _openLoans.pop();
        if (ln.maturity == earliestMaturity) _refreshEarliest();
    }

    function _setMaturity(Loan storage ln, uint40 maturity) internal {
        uint40 previous = ln.maturity;
        ln.maturity = maturity;
        if (maturity < earliestMaturity) earliestMaturity = maturity;
        else if (previous == earliestMaturity) _refreshEarliest();
    }

    function _refreshEarliest() internal {
        uint40 earliest = NO_DEADLINE;
        uint256 length = _openLoans.length;
        for (uint256 i; i < length; ++i) {
            uint40 end = loans[_openLoans[i]].maturity;
            if (end < earliest) earliest = end;
        }
        earliestMaturity = earliest;
    }

    /// @dev Book the interest earned up to now and anchor the clock at now, so a stop at the earliest maturity
    /// never counts the time until its settlement. Called before any change to the rate or the earliest maturity.
    function _accrue() internal {
        uint256 c = _clockNow();
        _accrued += accrualRate * (c - _clockBase);
        _clockBase = uint64(c);
        _clockAt = uint64(block.timestamp);
    }

    /// @dev Start earning the loan's net interest evenly until its maturity; `_accrue` has run in this call.
    function _startAccrual(uint256 id, Loan storage ln, uint40 maturity) internal {
        uint256 remaining = maturity - block.timestamp;
        uint256 rate = uint256(ln.interest) * RATE_PRECISION / remaining;
        ln.rate = uint128(rate);
        ln.clockStart = _clockBase;
        accrualRate += rate;
        emit LoanAccruing(id, ln.interest, maturity);
    }

    /// @dev Take the loan out of the running interest and return what it had earned, in USDG units.
    function _stopAccrual(Loan storage ln) internal returns (uint256 earned) {
        uint256 rate = ln.rate;
        if (rate == 0) return 0;
        uint256 scaled = Math.min(uint256(ln.interest) * RATE_PRECISION, rate * (_clockBase - ln.clockStart));
        _accrued -= scaled;
        accrualRate -= rate;
        ln.rate = 0;
        return scaled / RATE_PRECISION;
    }

    function _openPocket(uint256 id, Loan storage ln, address token, uint256 amount) internal {
        uint256 pocketId = ++pocketCount;
        pockets[pocketId] = Pocket(id, token, amount, ln.snapshotSupply, 0, ln.snapshotId);
        pocketLiability[token] += amount;
        emit PocketCreated(pocketId, id, token, amount, ln.snapshotSupply);
    }

    /// @dev Take USDG from cash, then redeem the reserve for the shortfall; the burned reserve shares are returned.
    function _payOut(uint256 assets) internal returns (uint256 burned) {
        uint256 c = cash;
        if (assets <= c) {
            cash = c - assets;
            return 0;
        }
        uint256 need = assets - c;
        if (need > RESERVE.convertToAssets(reserveShares)) revert InsufficientLiquidity();
        uint256 beforeCash = USDG.balanceOf(address(this));
        uint256 beforeShares = RESERVE.balanceOf(address(this));
        RESERVE.withdraw(need, address(this), address(this));
        burned = beforeShares - RESERVE.balanceOf(address(this));
        if (burned == 0 || USDG.balanceOf(address(this)) - beforeCash != need) revert TransferAmountMismatch();
        if (burned > reserveShares) revert InsufficientLiquidity();
        reserveShares -= burned;
        cash = 0;
    }

    function _mint(address to, uint256 shares) internal {
        _beforeBalanceChange(to);
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function _burn(address from, uint256 shares) internal {
        _beforeBalanceChange(from);
        balanceOf[from] -= shares;
        totalSupply -= shares;
    }

    /// @dev Preserve the balance of record for open pockets and settle rewards before a balance moves.
    function _beforeBalanceChange(address who) internal {
        uint64 current = snapshotCount;
        if (current != 0) {
            Snapshot[] storage s = _snapshots[who];
            if (s.length == 0 || s[s.length - 1].id < current) s.push(Snapshot(current, balanceOf[who]));
        }
        _settleRewards(who);
    }

    function _settleRewards(address who) internal {
        uint256 index = accRewardPerShare;
        _rewardOwed[who] += Math.mulDiv(balanceOf[who], index - _rewardIndex[who], REWARD_PRECISION);
        _rewardIndex[who] = index;
    }

    /// @dev The first `units` empty lender slots, exactly as the core fills them, and their combined price.
    /// @dev The share of the modeled cost a listing must offer per rate grade: D 50%, C 75%, B 90%, A 100%.
    function _rateFloorPct(uint8 rank) internal pure returns (uint256) {
        if (rank == 1) return 50;
        if (rank == 2) return 75;
        if (rank == 3) return 90;
        return 100;
    }

    function _selectSlots(uint256 id, uint256 principal, uint8 units)
        internal
        view
        returns (uint8 slots, uint256 cost)
    {
        address[4] memory lenders = VAULT.lenders(id);
        uint8 remaining = units;
        for (uint8 i; i < UNITS && remaining != 0; ++i) {
            if (lenders[i] == address(0)) {
                slots |= uint8(1 << i);
                cost += _slice(principal, i);
                --remaining;
            }
        }
        if (remaining != 0) revert IneligibleDeal();
    }

    function _slice(uint256 total, uint8 i) internal pure returns (uint256) {
        return total / UNITS + (i < total % UNITS ? 1 : 0);
    }

    function _sliceSum(uint256 total, uint8 slots) internal pure returns (uint256 sum) {
        for (uint8 i; i < UNITS; ++i) {
            if (slots & (1 << i) != 0) sum += _slice(total, i);
        }
    }

    function _checkDeal(uint256 id, V2Loan memory l, uint8 units, uint256 principal)
        internal
        view
        returns (EarnLane lane)
    {
        Loan storage held = loans[id];
        if (held.principal != 0 && (held.settled || held.withdrawn)) revert IneligibleDeal();
        if (
            l.state != V2State.FUNDING || units == 0 || units > UNITS - l.filled || principal == 0 || l.term > MAX_TERM
                || l.originator == address(this) || l.originator == CURATOR || block.timestamp >= l.fundingDeadline
        ) revert IneligibleDeal();
        if (l.kind == Kind.ERC20) {
            ICollateralRegistry.ERC20Config memory cfg = REGISTRY.getERC20Config(l.token);
            if (!cfg.allowed || (pickedAssets != 0 && !assetPicked[l.token])) revert IneligibleDeal();
            // A token whose grade fell, or went stale, backs no new loan; open loans run to settlement.
            if (minGrade != 0 && GRADES.gradeOf(l.token) < minGrade) revert IneligibleDeal();
            // The rate floor (D127): the listing's cost for the whole loan against the registry's modeled cost for the
            // token and term; no fresh model, no loan.
            if (minRateGrade != 0) {
                uint256 modeled = GRADES.modeledCostOf(l.token, l.term);
                uint256 offered = l.cap > l.principal ? Math.mulDiv(l.cap - l.principal, BPS, l.principal) : 0;
                if (modeled == 0 || offered * 100 < modeled * _rateFloorPct(minRateGrade)) revert IneligibleDeal();
            }
            // Ether is neither a stock nor a meme: no category, no loan (D124).
            if (cfg.lane == Lane.ETH) revert IneligibleDeal();
            lane = cfg.lane == Lane.MEME ? EarnLane.MEME : EarnLane.STOCK;
        } else {
            // The core's immutable validator rechecks the position, its pool, range and the registry's limits.
            (bytes32 key, uint256 raw, uint256 maximum) =
                VALIDATOR.validate(Collateral(l.kind, l.token, l.collateral), l.account);
            if (key != l.exposureKey || raw != l.exposureAmount || VAULT.openExposure(key) > maximum) {
                revert IneligibleDeal();
            }
            lane = EarnLane.LP;
        }
        if (held.principal != 0 && lane != held.lane) revert IneligibleDeal();
        // The cap per listing counts what the strategy already holds in it, so top-ups cannot pass it in quarters.
        uint128 loanCap = maxLoanPrincipal;
        if (loanCap != 0 && held.principal + principal > loanCap) revert IneligibleDeal();
        uint256 assets = totalAssets();
        if (lanePrincipal[lane] + principal > Math.mulDiv(laneWeightBps[lane], assets, BPS)) revert IneligibleDeal();
        uint256 assetCap = maxAssetBps;
        if (assetCap != 0 && assetPrincipal[l.token] + principal > Math.mulDiv(assetCap, assets, BPS)) {
            revert IneligibleDeal();
        }
    }

    function _setAsset(address token, bool picked) internal {
        if (assetPicked[token] == picked || (picked && !REGISTRY.getERC20Config(token).allowed)) {
            revert InvalidConfiguration();
        }
        assetPicked[token] = picked;
        if (picked) ++pickedAssets;
        else --pickedAssets;
        emit AssetSet(token, picked);
    }

    function _setFeeRecipient(address recipient) internal {
        if (recipient == address(0) || recipient == address(this)) revert InvalidConfiguration();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function _held(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice Receive native currency recovered from LP collateral; it belongs only to its side pocket.
    receive() external payable {}
}
