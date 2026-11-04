// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {V2State} from "../v2/V2Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {GageV2Rewards} from "../v2/GageV2Rewards.sol";
import {GageV2TokenCollateralAccount} from "../v2/GageV2TokenCollateralAccount.sol";
import {GradeRegistry} from "../earn/GradeRegistry.sol";
import {IntentAssetPolicy} from "./IntentAssetPolicy.sol";
import {IntentFeeMath} from "./IntentFeeMath.sol";
import {IntentLenderMarket} from "./IntentLenderMarket.sol";
import {IntentCategory, IntentLimit, INTENT_MAX_LOAN_PRINCIPAL, INTENT_MAX_RATE_GRADE} from "./IntentVaultState.sol";
import {IntentFactory} from "./IntentFactory.sol";
import {IntentVaultViews} from "./IntentVaultViews.sol";

/// @notice Measures what a reserve can pay out now, for a reserve whose own ERC-4626 max views do not.
interface IReserveLens {
    /// @return The most USDG `owner` could withdraw from `reserve` in this block.
    function withdrawable(address reserve, address owner) external view returns (uint256);
}

/// @notice Token-only partner strategy, based on EarnVault at colleague commit 55b6e6f.
/// @dev Shares, settlement and reward machinery retain the established engine, with one accounting change: a
/// position that leaves the book before the end of its term, repaid early or sold, books what the share price already
/// counted for it, and the rest of its return becomes a USDG claim for the shares exposed to it while it was held, by
/// their share of the vault over its actual life (its loan-days), up to the second the core recorded the repayment
/// however late the booking. Nobody who arrives after the repayment shares the claim. Pricing reads the core's
/// repayment timestamp even before booking, so the delay cannot add interest to deposits or redemptions. Settlement
/// makes the repayment liquid and opens the earnings claim.
/// A fill's execution fee is an input here: it leaves priced assets once, when the purchase is made, is owed only
/// once the loan is active, and the manager fee is charged on the interest left after it (IntentFeeMath).
/// The fill path must supply execution-cost checks and atomic funding before deployment enables a router/signer.
/// Legacy EarnVault and existing LP servicing are separate, unchanged contracts.
contract IntentVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice Mandate policy version: v6 requires explicit assets and a three-hour delay for additions; v7 adds the
    /// secondary purchase policy and the bought-position route; v8 adds the `COMMODITY` category and refuses a
    /// mandate that spans both universes; v10 books an early exit's unpriced return as an earnings claim by
    /// loan-days; v11 is the same mandate on the audit candidate's interface (one `purchase` entry point, curator
    /// settings and pocket claims on the vault itself, no pass-through views of the asset policy); v12 moves the risk
    /// limits through the asset policy, tightening at once and loosening after three hours, with no creation ceilings
    /// or floors, and the factory names each vault; v13 sells through a falling price that
    /// reaches book ten minutes after listing, pays the factory's fixed secondary fee, and may be created to buy
    /// existing positions only.
    uint256 public constant MANDATE_VERSION = 13;
    /// @notice Virtual shares of the conversion denominator, over `ASSET_SCALE` virtual assets: one whole unit of the
    /// asset starts worth 10^18 shares, whatever its decimals (one USDG unit, 10^12 shares). Never scaled by the
    /// decimals: the exposure clock below divides by it.
    uint256 internal constant VIRTUAL_SHARES = 1e12;
    /// @notice Interest accrues in USDG units scaled by this, so per-second rates carry no rounding drift.
    uint256 internal constant RATE_PRECISION = 1e18;
    /// @notice The most loan records the vault holds open, settled ones still owed rewards included. Every deposit and
    /// redemption checkpoints each one's reward claim, so the cap bounds that checkpoint: at 128 records Pashov
    /// measured 27.79M gas steady and 34.43M with no claim ever made on the bridged core, the second past the chain's
    /// 32M per transaction; 64 roughly halves both (Pashov I-03).
    uint256 internal constant MAX_OPEN_LOANS = 64;
    uint256 internal constant MAX_BATCH = 32;
    uint16 internal constant MAX_FEE_BPS = 1500;
    uint16 internal constant MIN_FEE_BPS = 500;
    uint8 internal constant MAX_RATE_GRADE = INTENT_MAX_RATE_GRADE;
    /// @dev Category bits of the two universes: STOCK and COMMODITY, MEME and RH_ECOSYSTEM.
    uint8 internal constant RWA_MASK =
        uint8(1 << uint8(IntentCategory.STOCK)) | uint8(1 << uint8(IntentCategory.COMMODITY));
    uint8 internal constant RH_ECO_MASK =
        uint8(1 << uint8(IntentCategory.MEME)) | uint8(1 << uint8(IntentCategory.RH_ECOSYSTEM));
    uint256 internal constant REWARD_PRECISION = 1e18;
    /// @notice The exposure clock gains this much per second, shared over the shares outstanding and the virtual
    /// shares:
    /// at most 10^21 a second, so its 104 bits last over 600 years, and under MAX_SUPPLY about 10^6 or more, so
    /// its rounding stays near a millionth of a claim at most.
    uint256 internal constant EXPOSURE_PRECISION = 1e33;
    /// @notice The most shares outstanding, for the exposure clock's precision: 10^9 whole units of the asset at the
    /// first price, and otherwise reached only after the price falls.
    uint256 internal constant MAX_SUPPLY = 1e27;

    /// @notice A vault's terms at creation. Its universe (the categories given a weight), its performance fee and
    /// its longest loan are fixed for good, and `minGrade` keeps its creation value as a floor (`MIN_GRADE_FLOOR`). The
    /// risk limits only start at their creation values, which bound no later change (v12): the asset policy
    /// applies a tightening at once and a loosening after three hours, within the bounds in code. The execution-fee
    /// ceiling is a plain setting, bounded in code.
    /// Zero contribution/exposure/category limits close that allocation; zero buffer imposes no cash minimum.
    /// Assets are explicit: an empty list closes new funding. Additions after creation wait three hours.
    struct Mandate {
        address curator;
        uint16[4] categoryWeights;
        address[] assets;
        uint32 maxLoanTerm;
        uint16 feeBps;
        uint8 minGrade;
        uint8 minRateGrade;
        uint128 maxLoanPrincipal;
        uint16 maxAssetBps;
        uint16 bufferBps;
        /// @dev The most execution may take of a purchase's interest, in basis points. The manager's own choice, at
        /// creation and afterwards (`setExecutionCap`); zero allows no execution fee.
        uint16 executionCapBps;
    }

    struct Loan {
        uint8 slots;
        IntentCategory lane;
        uint16 feeBps;
        /// @dev The end of the term, when repayment closes and the default opens. Exact once the loan is active; a
        ///      lower bound while other lenders may still fill it.
        uint40 maturity;
        /// @dev The curator released the strategy's units before the listing activated; only a refund can follow.
        bool withdrawn;
        bool settled;
        bool recovered;
        /// @dev The record left the book before the end of its term, repaid early or sold, and the return the share
        ///      price had not counted yet became an earnings claim. Such a record is settled.
        bool repaid;
        /// @dev The write-off's number (`snapshotCount`), zero until the loan is written off.
        uint64 snapshotId;
        /// @dev What the vault paid for its quarters: the principal it lent, or a bought position's price.
        uint128 principal;
        /// @dev Once written off, the shares outstanding at the write-off, which bore it: its pockets' supply.
        uint256 snapshotSupply;
        /// @dev Net loan interest, earned by the clock from the loan's activation to its maturity.
        uint128 interest;
        /// @dev `interest` scaled by RATE_PRECISION per second of wall time; zero until the loan is seen active.
        uint128 rate;
        /// @dev Wall-clock activation observation, not a vault-wide stopped clock.
        uint64 clockStart;
        /// @dev Execution fees of this loan's purchases, already out of priced assets; owed once the loan is seen
        ///      active, and returned to cash if the purchase is refunded instead.
        uint128 executionFee;
        bool executionEarned;
    }

    struct Pocket {
        uint256 loanId;
        address token;
        uint256 amount;
        uint256 supply;
        uint256 claimed;
        /// @dev Always zero: a pocket's split is told by its loan (a written-off loan's pockets by balance at the
        /// write-off and the seconds carried; otherwise earnings by exposure over the window).
        uint64 snapshotId;
    }

    /// @notice One whole USDG, the smallest deposit, in six-decimal units: scaled by `ASSET_SCALE`, one whole unit of any
    /// asset. This vault's USDG is its core's lent asset, which the core's constructor holds to 6 to 18 decimals.
    uint256 internal constant MIN_DEPOSIT = 1e6;
    uint40 internal constant NO_DEADLINE = type(uint40).max;

    // Curator settings, the first slots of the vault's storage (a layout pinned by its storage test).
    /// @notice The lowest collateral grade rank a new loan may carry; curator-adjustable, open loans unaffected.
    uint8 public minGrade;
    /// @notice The lowest rate grade a new loan may carry; curator-adjustable, open loans unaffected.
    uint8 public minRateGrade;
    /// @notice The most an execution fee may be, in basis points of the interest a purchase earns. The manager moves
    /// it either way, never past `IntentFeeMath.MAX_EXECUTION_CAP_BPS`; a purchase already made keeps its fee.
    uint16 public executionCapBps;
    mapping(IntentCategory => uint16) public categoryWeightBps;
    /// @dev Retired in v12 with the three bounds marked below: the creation ceilings and floors of the risk limits,
    /// which now tighten at once and loosen after three hours in the asset policy. Their slots stay so the layout,
    /// and every client that reads a slot by number, is the same for every version.
    mapping(IntentCategory => uint16) private _retiredCategoryCeilings;
    // Constructor-only bounds: packed storage keeps runtime within EIP-170; there are no mutation paths.
    uint8 public CATEGORY_MASK;
    uint8 public MIN_GRADE_FLOOR;
    uint8 private _retiredRateGradeFloor;
    uint128 private _retiredLoanCeiling;
    uint16 private _retiredAssetCeiling;
    uint16 private _retiredBufferFloor;
    address public feeRecipient;
    bool public paused;
    /// @notice Whether the factory's fill router may fund on a filler's behalf; the curator may opt out.
    bool public fillersOpen;
    /// @notice The most principal one listing may take from this strategy over every fill; zero closes allocation.
    uint128 public maxLoanPrincipal;
    /// @notice The most principal one collateral token may back, as a share of strategy assets; zero closes allocation.
    uint16 public maxAssetBps;
    /// @notice The share of strategy assets a fill must leave in free liquidity; zero is no buffer.
    uint16 public bufferBps;

    // Shares.
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    /// @dev Per holder, the balance times the seconds it has been held, at each second its balance moved
    /// (time << 216 | balance-seconds): the time a share carried a written-off loan, in wall-clock seconds that other
    /// holders' flows cannot speed up or slow down. It reuses the slot the per-holder balance snapshots of
    /// earlier versions held, so the layout is the same for every version.
    mapping(address => uint256[]) internal _heldSeconds;
    /// @notice How many loans this strategy has written off; a written-off loan's `snapshotId` is its number here.
    uint64 public snapshotCount;
    // Assets. USDG held = cash + curatorFees + protocolFees + executionPending + executionFees + USDG pockets +
    // unassignedCash, plus any USDG `_harvest` has not counted yet.
    uint256 public cash;
    uint256 public reserveShares;
    uint256 public performingPrincipal;
    mapping(IntentCategory => uint256) public categoryPrincipal;
    /// @notice Outstanding principal backed by each collateral token, for the per-asset cap.
    mapping(address => uint256) public assetPrincipal;
    uint256 public curatorFees;
    uint256 public protocolFees;
    /// @notice Execution fees of purchases whose loan is not yet seen active: set aside, owed to nobody yet.
    uint256 public executionPending;
    /// @notice Execution fees earned by fills that completed; a liability, never part of priced assets.
    uint256 public executionFees;
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
    // Settled records remain here until their reward entitlement has been collected. Bounded by `MAX_OPEN_LOANS`.
    EnumerableSet.UintSet private _openLoans;
    /// @notice The earliest end of term among open loans, when repayment closes and the default can be finalized. From
    ///         then until `settle` books that loan, share moves, fills, lender sales and the ERC-4626 maxima are closed
    ///         (`SettlementDue`). The price does not pause: `totalAssets()` still counts the loan at full value until
    ///         then.
    uint40 public earliestMaturity = NO_DEADLINE;
    /// @notice The exposure clock: EXPOSURE_PRECISION per second shared over the shares then outstanding and the
    ///         virtual shares, rounded down at each write. A share held from one reading to another was exposed to
    ///         every open position for the difference.
    uint104 public exposureIndex;
    /// @dev When the exposure clock was last written.
    uint40 internal _exposureAt;
    /// @dev Keep each new position's opening holders fixed through its purchase second.
    uint40 internal _shareChangeBlockedAt = NO_DEADLINE;
    /// @dev Per holder, one entry per clock reading at which its balance changed: the reading, and the exposure the
    ///      holder had carried up to it (reading << 152 | exposure).
    mapping(address => uint256[]) internal _exposure;
    /// @notice Per position, the clock reading and time its window opened and the reading it closed at
    ///         (opened << 152 | time << 104 | closed); the window closes when an earnings claim is opened or the
    ///         loan is written off at the end of its term.
    mapping(uint256 => uint256) public exposureWindow;
    /// @dev Every earlier point of the exposure clock (time << 104 | reading), so it can be read at a past second.
    uint256[] internal _exposureLog;
    // Appended: existing gas estimation and release storage slots remain unchanged.
    mapping(address => mapping(address => uint256)) public allowance;
    // Fixed at construction, with no setters. Appending configuration storage avoids repeating immutable
    // addresses throughout runtime bytecode and keeps this native vault within EIP-170 without moving old slots.
    GageV2Vault public VAULT;
    GageV2Rewards internal CORE_REWARDS;
    IERC4626 public RESERVE;
    /// @notice How the reserve's liquidity is measured: zero reads its own `maxWithdraw`, where zero means nothing
    ///         can leave; a lens serves a reserve whose max views report zero by design (Morpho Vault V2).
    IReserveLens public RESERVE_LENS;
    /// @notice Collateral grades and modeled costs published from the valuation service; a purchase reads them only
    /// while the strategy has a minimum grade, or a minimum rate grade for a new loan.
    GradeRegistry public GRADES;
    IERC20 public USDG;
    IERC20 internal REWARD_TOKEN;
    address public CURATOR;
    /// @notice The factory that created this vault: it names the protocol fee recipient and the quote signer, each
    /// updatable there, and the fill router, bound for good to the first one it named (`boundFillRouter`, Pashov L-02,
    /// L-03, L-05): its owner may only close fills (zero) and reopen them with that router.
    address public PROTOCOL_SOURCE;
    /// @notice Only explicitly picked collateral tokens are admitted, including when the list is empty. The policy
    /// holds the list: `picked` and `readyAt` (the three-hour addition delay) are read there.
    IntentAssetPolicy public ASSET_POLICY;
    /// @notice Curator listings live here; fills must synchronously book their proceeds in this vault.
    IntentLenderMarket public LENDER_MARKET;
    IntentVaultViews internal SHARE_VIEWS;
    /// @notice The asset's raw units in one six-decimal unit, 10^(decimals - 6): 1 for USDG. The conversion's virtual
    /// assets, so share amounts and `MAX_SUPPLY` mean the same in whole units for every asset; the amounts fixed in
    /// six-decimal units, `MIN_DEPOSIT` and `INTENT_MAX_LOAN_PRINCIPAL`, are scaled by it where they are checked.
    uint256 internal ASSET_SCALE;
    /// @notice The longest loan term this strategy funds, one of the terms the registry allowed at creation.
    uint32 public MAX_TERM;
    uint16 public feeBps;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    error InsufficientAllowance();

    event CategoryWeightSet(IntentCategory indexed lane, uint16 bps);
    event AssetSet(address indexed token, bool picked);
    event AssetAdditionQueued(address indexed token, uint256 readyAt);
    event AssetAdditionCancelled(address indexed token);
    event MinGradeSet(uint8 rank);
    event MinRateGradeSet(uint8 rank);
    event FeeRecipientSet(address indexed recipient);
    event Paused(bool enabled);
    event FillersOpenSet(bool enabled);
    event LimitsSet(uint128 maxLoanPrincipal, uint16 maxAssetBps, uint16 bufferBps);
    event ExecutionCapSet(uint16 bps);

    error InvalidConfiguration();
    error NotCurator();
    event FeesClaimed(address indexed curatorRecipient, uint256 curatorAmount, uint256 protocolAmount);
    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, uint256 assets, uint256 shares);
    event ReserveInvested(uint256 assets, uint256 shares);
    event ReserveDivested(uint256 shares, uint256 assets);
    event LoanFunded(uint256 indexed loanId, uint256 principal, uint8 slots, uint16 feeBps, uint256 executionFee);
    event ExecutionFeeEarned(uint256 indexed loanId, uint256 amount);
    event ExecutionFeeReversed(uint256 indexed loanId, uint256 amount);
    event ExecutionFeesCollected(address indexed router, uint256 amount);
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

    error InvalidAmount();
    error PausedError();
    error IneligibleDeal();
    error LimitExceeded();
    error InsufficientLiquidity();
    error TransferAmountMismatch();
    error Slippage();
    error UnknownDeal();
    error SettlementDue();
    error NothingToRecover();
    error NoHolders();
    error Impaired();
    error RewardsPending();
    error OutstandingLoans();
    /// @dev Pashov L-01: a sale would book less than the position's value (principal plus interest earned so
    /// far) plus half of the interest still to come.
    error SaleBelowBook();
    /// @dev A sale gain cannot be shared, or balances changed, in the second a position was bought.
    error SaleTooSoon();

    event LoanSold(uint256 indexed id, uint256 principal, uint256 proceeds, uint256 stoppedInterest);
    event LoanAcquired(uint256 indexed loanId, uint256 price, uint8 slots, uint16 feeBps, uint256 executionFee);

    /// @notice Created by an `IntentFactory` only: the deployer is the factory, whose core, reserve, reserve lens
    /// (zero when the reserve's `maxWithdraw` measures what it can pay) and grades the vault adopts, and which names
    /// the protocol's fee recipient.
    /// `secondaryEnabled` and `secondaryExtraBps` are the secondary purchase policy at creation; zero values buy
    /// nothing.
    constructor(Mandate memory m, bool secondaryEnabled, uint16 secondaryExtraBps, bool secondaryOnly) {
        // Only the factory creates a vault that counts (`isVault`, the core's funder gate): it has already checked that
        // the core, the reserve, the grades and any lens have code, it is the protocol source, and the curator is the
        // caller that created the vault. A vault deployed any other way is unsupported and inert.
        IntentFactory factory = IntentFactory(msg.sender);
        SHARE_VIEWS = factory.SHARE_VIEWS();
        executionCapBps = m.executionCapBps;
        VAULT = GageV2Vault(factory.CORE());
        CORE_REWARDS = VAULT.REWARDS();
        USDG = VAULT.USDG();
        uint256 scale = 10 ** IERC20Metadata(address(USDG)).decimals() / 1e6;
        ASSET_SCALE = scale;
        REWARD_TOKEN = VAULT.SGAGE();
        RESERVE = IERC4626(factory.RESERVE());
        RESERVE_LENS = IReserveLens(factory.RESERVE_LENS());
        address grades = factory.GRADES();
        GRADES = GradeRegistry(grades);
        MIN_GRADE_FLOOR = m.minGrade;
        minGrade = m.minGrade;
        minRateGrade = m.minRateGrade;
        if (m.minGrade > GRADES.MAX_GRADE() || m.minRateGrade > MAX_RATE_GRADE) revert InvalidConfiguration();
        // The strategy pins a core without a grace window: repayment closes the second the term ends. A zero scale
        // (fewer than six decimals) cannot come from a core.
        if (
            RESERVE.asset() != address(USDG) || VAULT.GRACE() != 0 || address(REWARD_TOKEN) == address(USDG)
                || address(REWARD_TOKEN) == address(RESERVE) || !VAULT.REGISTRY().isTermAllowed(m.maxLoanTerm)
                || scale == 0
        ) revert InvalidConfiguration();
        CURATOR = m.curator;
        PROTOCOL_SOURCE = msg.sender;
        MAX_TERM = m.maxLoanTerm;
        uint8 mask;
        for (uint256 i; i < 4; ++i) {
            if (m.categoryWeights[i] > IntentFeeMath.BPS) revert InvalidConfiguration();
            categoryWeightBps[IntentCategory(i)] = m.categoryWeights[i];
            if (m.categoryWeights[i] != 0) mask |= uint8(1 << i);
        }
        // One universe: real-world assets (STOCK, COMMODITY) or the Robinhood ecosystem (MEME, RH_ECOSYSTEM).
        if (
            mask == 0 || ((mask & RWA_MASK) != 0 && (mask & RH_ECO_MASK) != 0) || m.maxAssetBps > IntentFeeMath.BPS
                || m.bufferBps > IntentFeeMath.BPS || m.feeBps < MIN_FEE_BPS || m.feeBps > MAX_FEE_BPS
                || m.executionCapBps > IntentFeeMath.MAX_EXECUTION_CAP_BPS
                || m.maxLoanPrincipal > INTENT_MAX_LOAN_PRINCIPAL * scale
        ) revert InvalidConfiguration();
        CATEGORY_MASK = mask;
        maxLoanPrincipal = m.maxLoanPrincipal;
        maxAssetBps = m.maxAssetBps;
        bufferBps = m.bufferBps;
        ASSET_POLICY = new IntentAssetPolicy(
            address(VAULT),
            m.curator,
            msg.sender,
            grades,
            mask,
            scale,
            m.assets,
            secondaryEnabled,
            secondaryExtraBps,
            secondaryOnly
        );
        LENDER_MARKET = new IntentLenderMarket(address(VAULT), m.curator, msg.sender);
        for (uint256 i; i < m.assets.length; ++i) {
            emit AssetSet(m.assets[i], true);
        }
        feeRecipient = m.curator;
        feeBps = m.feeBps;
        fillersOpen = true;
    }

    // ---------------------------------------------------------------- curator settings

    /// @notice Apply a risk limit the asset policy has accepted: a tightening at once, a loosening after its three
    /// hours. The policy checks the curator, the bounds, the universe and the wait; only it may call. Open loans
    /// are untouched; a limit now exceeded only refuses new purchases. The setting's own event is emitted.
    function applyLimit(IntentLimit limit, uint128 value) external nonReentrant {
        if (msg.sender != address(ASSET_POLICY)) revert NotCurator();
        if (limit == IntentLimit.MIN_RATE_GRADE) {
            minRateGrade = uint8(value);
            emit MinRateGradeSet(uint8(value));
        } else if (limit >= IntentLimit.CATEGORY_STOCK) {
            IntentCategory lane = IntentCategory(uint8(limit) - uint8(IntentLimit.CATEGORY_STOCK));
            categoryWeightBps[lane] = uint16(value);
            emit CategoryWeightSet(lane, uint16(value));
        } else {
            if (limit == IntentLimit.MAX_LOAN_PRINCIPAL) maxLoanPrincipal = value;
            else if (limit == IntentLimit.MAX_ASSET_BPS) maxAssetBps = uint16(value);
            else bufferBps = uint16(value);
            emit LimitsSet(maxLoanPrincipal, maxAssetBps, bufferBps);
        }
    }

    /// @notice Queue an addition, or remove an active token immediately. An empty list closes funding.
    function setAsset(address token, bool picked) external nonReentrant {
        uint256 eta = ASSET_POLICY.update(token, picked ? 1 : 0, msg.sender);
        if (picked) emit AssetAdditionQueued(token, eta);
        else emit AssetSet(token, false);
    }

    /// @notice Anyone may activate after three hours; only the manager may cancel. Admission is rechecked.
    function resolveAssetAddition(address token, bool activate) external nonReentrant {
        ASSET_POLICY.update(token, activate ? 2 : 3, msg.sender);
        if (activate) emit AssetSet(token, true);
        else emit AssetAdditionCancelled(token);
    }

    /// @notice Move the collateral grade floor for new loans; open loans run to settlement.
    function setMinGrade(uint8 rank) external nonReentrant {
        _requireCurator();
        if (rank < MIN_GRADE_FLOOR || rank > GRADES.MAX_GRADE()) revert InvalidConfiguration();
        minGrade = rank;
        emit MinGradeSet(rank);
    }

    /// @notice Change where the curator's fee share is paid.
    function setFeeRecipient(address recipient) external nonReentrant {
        _requireCurator();
        if (recipient == address(0) || recipient == address(this)) revert InvalidConfiguration();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Pause deposits, reserve investment, funding and lender sales. Exits still enforce solvency and rewards.
    function setPaused(bool enabled) external nonReentrant {
        _requireCurator();
        paused = enabled;
        emit Paused(enabled);
    }

    /// @notice Move the execution-fee ceiling for purchases from now on, up or down, within the compile-time bound;
    /// zero allows no execution fee. A purchase already made keeps the fee it paid, and a signed plan that names the
    /// earlier ceiling is refused by the quote verifier. The rate floor still holds whatever the ceiling is.
    function setExecutionCap(uint16 bps) external nonReentrant {
        _requireCurator();
        if (bps > IntentFeeMath.MAX_EXECUTION_CAP_BPS) revert InvalidConfiguration();
        executionCapBps = bps;
        emit ExecutionCapSet(bps);
    }

    /// @notice Let the factory's fill router fund within the mandate on a filler's behalf, or keep funding to the
    /// closed. Open loans are untouched either way.
    function setFillersOpen(bool enabled) external nonReentrant {
        _requireCurator();
        fillersOpen = enabled;
        emit FillersOpenSet(enabled);
    }

    /// @notice Pay charged fees to the curator recipient and to the protocol recipient the factory names now;
    /// anyone may call. Each is paid on its own: a payment USDG refuses keeps its balance for a later claim and does
    /// not hold up the other (M-03). A call that owed fees and could pay none of them reverts.
    function claimFees() external nonReentrant {
        address recipient = feeRecipient;
        uint256 curatorAmount = curatorFees;
        uint256 protocolAmount = protocolFees;
        uint256 owed = curatorAmount + protocolAmount;
        curatorFees = 0;
        protocolFees = 0;
        if (curatorAmount != 0 && !USDG.trySafeTransfer(recipient, curatorAmount)) {
            curatorFees = curatorAmount;
            curatorAmount = 0;
        }
        if (
            protocolAmount != 0
                && !USDG.trySafeTransfer(IntentFactory(PROTOCOL_SOURCE).protocolRecipient(), protocolAmount)
        ) {
            protocolFees = protocolAmount;
            protocolAmount = 0;
        }
        if (owed != 0 && curatorAmount + protocolAmount == 0) revert InvalidAmount();
        emit FeesClaimed(recipient, curatorAmount, protocolAmount);
    }

    /// @notice Hand every earned execution fee to the factory's current fill router for protocol crediting.
    /// Already-earned fees remain collectible while new funding is disabled; they are outside priced assets.
    function collectExecutionFees() external nonReentrant returns (uint256 amount) {
        _requireFillRouter();
        amount = executionFees;
        executionFees = 0;
        USDG.safeTransfer(msg.sender, amount);
        emit ExecutionFeesCollected(msg.sender, amount);
    }

    // ---------------------------------------------------------------- views

    /// @notice What shares are priced on: cash, the reserve at its own conversion, open loans at principal and the
    /// interest they have earned so far. Deposits and redemptions convert at this one value; a redemption pays at most
    /// all of it. A loan past its end keeps its full value here, its principal and the interest its clock earned
    /// to maturity, until this vault's `settle` books the outcome, a write-off for a default. From
    /// `earliestMaturity` until then share moves, fills, lender sales and the maxima are closed (`SettlementDue`), so
    /// no one enters or leaves at that price. Anyone may settle.
    function totalAssets() public view returns (uint256) {
        return cash + _reserveAssets() + performingPrincipal + accruedInterest();
    }

    /// @notice Net interest earned by open loans, capped at repayment or maturity even before settlement.
    /// @dev A settled record left the book through `_drop`, after its rate was cleared (the design leaves no settled
    /// record
    /// accruing), so it earns zero here.
    function accruedInterest() public view returns (uint256) {
        uint256 scaled;
        for (uint256 i; i < _openLoans.length(); ++i) {
            uint256 id = _openLoans.pos(i);
            scaled += _earnedScaled(id, loans[id]);
        }
        return scaled / RATE_PRECISION;
    }

    /// @dev Impaired: shares are outstanding and priced equity is zero. New risk is refused; existing holders retain
    /// all recovery rights.
    function _requireHealthy() internal view {
        if (totalSupply != 0 && totalAssets() == 0) revert Impaired();
    }

    /// @notice Back a written-off loan for the shares that bore it: `assets` becomes a side pocket split as its
    /// recovered collateral is (`claimPocket`), never priced in the shares, so nobody who enters after the
    /// write-off shares it (Pashov I-01). Anyone may add backing, at least one whole unit at a time.
    function recapitalize(uint256 id, uint256 assets) external nonReentrant {
        Loan storage ln = loans[id];
        // A write-off that found no shares outstanding has nobody to back: its pocket could never be claimed.
        if (ln.snapshotId == 0 || ln.snapshotSupply == 0 || assets < MIN_DEPOSIT * ASSET_SCALE) revert InvalidAmount();
        _receiveUSDG(assets);
        cash -= assets;
        _openPocket(id, address(USDG), assets, ln.snapshotSupply);
    }

    /// @notice Shares for a deposit, rounded down against the depositor.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + ASSET_SCALE);
    }

    /// @notice USDG for shares, rounded down against the redeemer.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + ASSET_SCALE, totalSupply + VIRTUAL_SHARES);
    }

    /// @notice Cash plus what the reserve can pay out now. Earnings claims are held outside `cash`, so everything
    /// counted here is priced and redeemable. The reserve is measured by its kind (`RESERVE_LENS`): a zero is never
    /// read as "no limit".
    function freeLiquidity() public view returns (uint256) {
        uint256 value = _reserveAssets();
        // No reserve shares, nothing to read: cash alone, so a reserve whose limit view reverts never stops an exit or
        // a fill cash covers.
        if (value == 0) return cash;
        uint256 limit = address(RESERVE_LENS) == address(0)
            ? RESERVE.maxWithdraw(address(this))
            : RESERVE_LENS.withdrawable(address(RESERVE), address(this));
        return cash + Math.min(value, limit);
    }

    /// @notice Read a slot for this generation's immutable, layout-pinned accounting views.
    /// @dev Read-only chain data; no delegatecall or state mutation occurs in the helper.
    function readAccountingSlot(uint256 slot) external view returns (uint256 value) {
        assembly ("memory-safe") { value := sload(slot) }
    }

    /// @notice What `who` may still claim from a pocket: a written-off loan's by its balance at the write-off and the
    /// seconds it carried the loan, earnings by exposure over the loan's window.
    function pocketClaimable(uint256 pocketId, address who) public view returns (uint256) {
        return SHARE_VIEWS.pocketClaimable(pocketId, who);
    }

    /// @notice Accrued sGAGE the holder may claim.
    function rewardClaimable(address who) public view returns (uint256) {
        return _rewardOwed[who] + Math.mulDiv(balanceOf[who], accRewardPerShare - _rewardIndex[who], REWARD_PRECISION);
    }

    // ---------------------------------------------------------------- depositors

    /// @notice The share token's name: the vault's name at its factory, which its manager may change.
    function name() external view returns (string memory) {
        address source = PROTOCOL_SOURCE;
        // Forward the trusted factory's already-encoded string without a redundant decode and re-encode.
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, shl(224, 0xf5c57382)) // nameOf(address)
            mstore(add(p, 4), address())
            let ok := staticcall(gas(), source, p, 36, 0, 0)
            returndatacopy(p, 0, returndatasize())
            if iszero(ok) { revert(p, returndatasize()) }
            return(p, returndatasize())
        }
    }

    /// @notice The share token's symbol, the same for every vault.
    function symbol() external pure returns (string memory) {
        return "gSHARE";
    }

    /// @notice Shares have 18 decimals for every lend asset: one whole unit of the asset starts worth 10^18 shares.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice The lend asset the vault takes and pays out (ERC-4626).
    function asset() external view returns (address) {
        return address(USDG);
    }

    /// @notice Let `spender` move or burn up to `shares` of the caller's shares; never its reward or pocket claims.
    function approve(address spender, uint256 shares) external returns (bool) {
        if (spender == address(0)) revert InvalidConfiguration();
        allowance[msg.sender][spender] = shares;
        emit Approval(msg.sender, spender, shares);
        return true;
    }

    /// @notice Move shares. Both holders are checkpointed first: earned sGAGE and pocket exposure stay put.
    function transfer(address to, uint256 shares) external nonReentrant returns (bool) {
        _transfer(msg.sender, to, shares);
        return true;
    }

    /// @notice Move `from`'s shares within the caller's allowance (none when the caller is `from`), as `transfer`.
    function transferFrom(address from, address to, uint256 shares) external nonReentrant returns (bool) {
        _spendAllowance(from, shares);
        _transfer(from, to, shares);
        return true;
    }

    function _spendAllowance(address owner, uint256 shares) internal {
        if (msg.sender == owner) return;
        uint256 approved = allowance[owner][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < shares) revert InsufficientAllowance();
            allowance[owner][msg.sender] = approved - shares;
        }
    }

    /// @dev The vault refuses itself as a recipient: shares it held could never move, redeem or claim.
    function _transfer(address from, address to, uint256 shares) internal {
        if (from == address(0) || to == address(0) || to == address(this)) revert InvalidConfiguration();
        if (shares > balanceOf[from]) revert InvalidAmount();
        if (shares != 0 && from != to) {
            _requireSettled();
            _checkpointRewards();
            _beforeBalanceChange(from);
            _beforeBalanceChange(to);
            balanceOf[from] -= shares;
            balanceOf[to] += shares;
        }
        emit Transfer(from, to, shares);
    }

    /// @notice Shares a deposit of `assets` mints, rounded down; no entry limit is applied.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Assets a redemption of `shares` pays, rounded down; no liquidity limit is applied.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _redeemable(shares);
    }

    /// @notice Assets a mint of `shares` takes, rounded up; no entry limit is applied.
    function previewMint(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + ASSET_SCALE, totalSupply + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    /// @notice Shares a withdrawal of `assets` burns, rounded up; no liquidity limit is applied.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + ASSET_SCALE, Math.Rounding.Ceil);
    }

    /// @notice The most assets a deposit takes now (`_maximum`); a positive maximum can still revert `RewardsPending`.
    function maxDeposit(address receiver) external view returns (uint256) {
        return _maximum(receiver);
    }

    /// @notice The most shares a mint makes now (`_maximum`); a positive maximum can still revert `RewardsPending`.
    function maxMint(address receiver) external view returns (uint256) {
        return _maximum(receiver);
    }

    /// @notice The most assets `owner` can withdraw now (`_maximum`); a positive one can still revert `RewardsPending`.
    function maxWithdraw(address owner) external view returns (uint256) {
        return _maximum(owner);
    }

    /// @notice The most shares `owner` can redeem now (`_maximum`); a positive one can still revert `RewardsPending`.
    function maxRedeem(address owner) external view returns (uint256) {
        return _maximum(owner);
    }

    /// @dev Zero at a settlement due or in a purchase second, and whenever the helper's reads fail. Positive maxima do
    /// not model the reward checkpoint: a reward source that cannot deliver an owed claim reverts the operation with
    /// `RewardsPending` and changes nothing.
    function _maximum(address account) internal view returns (uint256) {
        if (
            account == address(0) || account == address(this) || block.timestamp >= earliestMaturity
                || block.timestamp == _shareChangeBlockedAt
        ) {
            return 0;
        }
        try SHARE_VIEWS.maximum(account, msg.sig, ASSET_SCALE) returns (uint256 amount) {
            return amount;
        } catch {
            return 0;
        }
    }

    /// @notice Existing slippage-protected entry; the caller also receives the shares.
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        shares = convertToShares(assets);
        if (shares < minShares) revert Slippage();
        _deposit(assets, shares, msg.sender);
    }

    /// @notice ERC-4626 deposit: the caller pays `assets`, `receiver` gets the shares; zero changes nothing.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        shares = convertToShares(assets);
        _deposit(assets, shares, receiver);
    }

    /// @notice ERC-4626 mint: the caller pays what `shares` cost, rounded up, and `receiver` gets them.
    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        assets = previewMint(shares);
        _deposit(assets, shares, receiver);
    }

    /// @dev Prices do not change when rewards are checkpointed: sGAGE is outside the share's USDG backing.
    function _deposit(uint256 assets, uint256 shares, address receiver) internal {
        if (receiver == address(0) || receiver == address(this)) revert InvalidConfiguration();
        if (assets != 0) {
            if (paused) revert PausedError();
            _requireSettled();
            _requireHealthy();
            _checkpointRewards();
            if (assets < MIN_DEPOSIT * ASSET_SCALE) revert InvalidAmount();
            if (shares == 0) revert Slippage();
            if (totalSupply + shares > MAX_SUPPLY) revert LimitExceeded();
            _receiveUSDG(assets);
            _mint(receiver, shares);
        } else {
            emit Transfer(address(0), receiver, 0);
        }
        emit Deposited(receiver, assets, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Existing slippage-protected exit; the caller owns the shares and receives the USDG.
    function redeem(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert InvalidAmount();
        assets = _redeemable(shares);
        if (assets < minAssets) revert Slippage();
        _withdraw(assets, shares, msg.sender, msg.sender);
    }

    /// @notice ERC-4626 redeem: burn `owner`'s shares (within the caller's allowance) and pay `receiver`, rounded down.
    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        assets = _redeemable(shares);
        _withdraw(assets, shares, receiver, owner);
    }

    /// @notice ERC-4626 withdraw: pay `receiver` `assets`, burning `owner`'s shares (rounded up) within the allowance.
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner);
    }

    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (receiver == address(0) || receiver == address(this) || owner == address(0)) revert InvalidConfiguration();
        if (shares != 0) {
            _requireSettled();
            _requireHealthy();
            _checkpointRewards();
            if (shares > balanceOf[owner]) revert InvalidAmount();
            if (shares == totalSupply && performingPrincipal != 0) revert OutstandingLoans();
            _spendAllowance(owner, shares);
            if (assets > freeLiquidity()) revert InsufficientLiquidity();
            _payOut(assets);
            _burn(owner, shares);
            // An exit that takes every asset must take every share: dust shares over nothing close the vault for good.
            _requireHealthy();
            if (assets != 0) USDG.safeTransfer(receiver, assets);
        } else {
            emit Transfer(owner, address(0), 0);
        }
        emit Withdrawn(owner, assets, shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Withdraw the caller's part of one side pocket, in its asset: a written-off loan's recovered collateral
    /// or backing, or USDG earnings. Open whatever the vault's state, and after a full exit. An unknown
    /// pocket, one already claimed and a zero share all revert `InvalidAmount`.
    function claimPocket(uint256 pocketId) external nonReentrant returns (uint256 amount) {
        return _claimPocket(pocketId);
    }

    /// @notice Withdraw the caller's part of several side pockets; every one of them must pay something.
    function claimPockets(uint256[] calldata pocketIds) external nonReentrant {
        for (uint256 i; i < pocketIds.length; ++i) {
            _claimPocket(pocketIds[i]);
        }
    }

    /// @dev Pay the caller's `pocketClaimable`, which already applies the pocket's own bound.
    function _claimPocket(uint256 pocketId) internal returns (uint256 amount) {
        amount = pocketClaimable(pocketId, msg.sender);
        if (amount == 0) revert InvalidAmount();
        pocketClaimed[pocketId][msg.sender] = true;
        Pocket storage pk = pockets[pocketId];
        address token = pk.token;
        pk.claimed += amount;
        pocketLiability[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
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

    /// @notice Move idle cash into the reserve; the fill router only, while the vault is not paused, its fillers are
    /// open and the factory names a quote signer (`_requireFunder`), so nobody else can push the cash a fill or an exit
    /// would use behind the reserve's withdrawal limit. Earnings claims are not `cash`, so a reserve loss can never
    /// reach them (which keeps the rule by construction).
    function investReserve(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (paused) revert PausedError();
        _requireFunder();
        _requireHealthy();
        if (assets == 0 || assets > cash) revert InvalidAmount();
        uint256 beforeCash = _held(USDG);
        uint256 beforeShares = _held(RESERVE);
        USDG.forceApprove(address(RESERVE), assets);
        RESERVE.deposit(assets, address(this));
        USDG.forceApprove(address(RESERVE), 0);
        shares = _held(RESERVE) - beforeShares;
        if (beforeCash - _held(USDG) != assets) revert TransferAmountMismatch();
        if (shares == 0 || shares < minShares) revert Slippage();
        cash -= assets;
        reserveShares += shares;
        emit ReserveInvested(assets, shares);
    }

    /// @notice Bring reserve shares back to idle cash; curator only, so nobody else can forgo reserve returns.
    function divestReserve(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        _requireCurator();
        if (shares == 0 || shares > reserveShares) revert InvalidAmount();
        uint256 beforeCash = _held(USDG);
        uint256 beforeShares = _held(RESERVE);
        RESERVE.redeem(shares, address(this), address(this));
        assets = _held(USDG) - beforeCash;
        if (beforeShares - _held(RESERVE) != shares) revert TransferAmountMismatch();
        if (assets < minAssets) revert Slippage();
        reserveShares -= shares;
        cash += assets;
        emit ReserveDivested(shares, assets);
    }

    // ---------------------------------------------------------------- loans

    /// @notice Only a complete recorded holding can be sold; settled reward records carry no lender position.
    function lenderSaleSlots(uint256 id) public view returns (uint8) {
        Loan storage ln = loans[id];
        return ln.settled || ln.withdrawn ? 0 : ln.slots;
    }

    /// @notice Complete one curator-approved sale while holding the vault's share-accounting lock.
    /// @dev The immutable market authenticates the ask, pays its buyer's USDG and names the recipient of every
    /// quarter. The core ask exists only inside this call and is consumed before returning. It can never be filled
    /// without the accompanying bookkeeping. A sale must book at least the position's value, principal plus the
    /// interest it has earned, plus the share `keepBps` of the interest still to come: the market's falling price,
    /// 99% of it at listing and never below the listing's floor, Pashov L-01's half for the curator's own listing and
    /// none for the part of an exit the leaver's shortfall covers; below that it reverts
    /// `SaleBelowBook`. What it books above the position's value is an earnings claim for the shares
    /// exposed to the position since its purchase; a gain in the second of the purchase reverts `SaleTooSoon`.
    function executeLenderSale(
        uint256 id,
        uint8 slots,
        uint128 price,
        uint40 deadline,
        uint16 maxFeeBps,
        uint256 keepBps
    ) external nonReentrant returns (uint256 proceeds) {
        if (msg.sender != address(LENDER_MARKET)) revert NotCurator();
        if (paused) revert PausedError();
        _requireSettled();
        Loan storage ln = loans[id];
        // The sole caller authenticated a nonempty listing; reject any change to the recorded holding.
        if (lenderSaleSlots(id) != slots) revert UnknownDeal();
        // Earned rewards belong to the current holders even if they exit immediately after this sale.
        _checkpointRewards();
        _earnExecution(id, ln);
        VAULT.setLenderAsk(id, slots, price, deadline, maxFeeBps);
        address token;
        (proceeds, token,) = LENDER_MARKET.complete(id);
        _harvest();
        unassignedCash -= proceeds;
        uint256 principal = ln.principal;
        uint256 earned = _close(id, ln, token, principal);
        uint256 book = principal + earned;
        uint256 net = _bookPayout(id, ln, proceeds, principal);
        // Never below book value, so a sale never lowers the share price. Nor below the market's share of the
        // interest still to come on top of it (`_close` and `_bookPayout` leave `interest` as booked), so the whole of
        // the position's remaining return can only go after ten minutes of a price falling in public.
        uint256 interest = ln.interest;
        if (net < book + (interest > earned ? interest - earned : 0) * keepBps / IntentFeeMath.BPS) {
            revert SaleBelowBook();
        }
        if (net > book) _setAside(id, ln, net - book, block.timestamp);
        emit LoanSold(id, principal, proceeds, book - principal);
    }

    /// @notice Buy lender units from cash and then the reserve, the only purchase entry point, for both routes.
    /// With `price` zero, buy the next `units` unfilled lender units (a count) of one currently eligible FUNDING
    /// listing. With `price` above zero, pay `price` for the exact quarter mask `units` of an active loan someone is
    /// selling: the fill router receives the price for the seller in the same transaction, and its one sale
    /// delivers these quarters here before it returns. The policy's `quote` accepts disjoint core states for the two:
    /// a zero-price buy of an active loan is refused (`IneligibleDeal`). The factory's fill router on a filler's behalf
    /// while fillers are open; one transaction, and the reserve's withdrawal limit counts. The mandate, the vault's
    /// secondary policy and its liquidity are checked here whoever calls.
    /// @param executionFee What this purchase pays for its execution, in USDG: at most `executionCapBps` of the
    /// interest the purchase earns, and never so much that what is left falls under the rate floor. It leaves
    /// priced assets now and is owed once the loan is active.
    /// @dev Nothing is lent while no share is outstanding (`NoHolders`): what is still priced then is rounding, or a
    /// reserve gain on it, that no holder owns, and a loan made from it would book interest nobody is there to earn
    /// and recover collateral for holders of record that do not exist. A bought position is booked at once at its
    /// cost, which becomes the position's principal: the purchase leaves priced assets only its execution fee, and
    /// earns what the quarters repay beyond their price, less the manager fee, from now to the loan's own maturity. A
    /// vault with any record of this loan refuses it. A purchase that opens a record takes at least one whole
    /// unit of a six-decimal asset and a tenth of one of an asset with more decimals (`InvalidAmount`, Pashov I-04); a
    /// top-up of a funding listing already held takes any amount.
    function purchase(uint256 id, uint8 units, uint256 price, uint256 maxReserveShares, uint256 executionFee)
        external
        nonReentrant
    {
        if (paused) revert PausedError();
        if (totalSupply == 0) revert NoHolders();
        _requireFunder();
        _requireSettled();
        _requireHealthy();
        Loan storage ln = loans[id];
        // A listing the strategy already holds can be bought into again while it is still funding.
        bool topUp = ln.principal != 0;
        if (!topUp && _openLoans.length() >= MAX_OPEN_LOANS) {
            _checkpointRewards();
            if (_openLoans.length() >= MAX_OPEN_LOANS) revert LimitExceeded();
        }
        (uint256 principal, uint256 interest, IntentCategory lane, address token, uint8 slots) =
            ASSET_POLICY.quote(id, units, price, executionFee);
        // A new record carries at least one whole unit of a six-decimal asset (1 USDG), a tenth of one of an asset with
        // more decimals (0.1 GLD), a bought position's price included, so dust cannot fill the book of open records
        // (Pashov I-04); a top-up of a record already held takes any amount.
        if (!topUp && principal < (ASSET_SCALE == 1 ? MIN_DEPOSIT : MIN_DEPOSIT * ASSET_SCALE / 10)) {
            revert InvalidAmount();
        }
        // The fill must leave the buffer's share of assets liquid after the principal and the execution fee.
        if (principal + executionFee + Math.mulDiv(bufferBps, totalAssets(), IntentFeeMath.BPS) > freeLiquidity()) {
            revert InsufficientLiquidity();
        }
        uint256 burned = _payOut(principal + executionFee);
        if (burned > maxReserveShares) revert Slippage();
        uint16 fee = feeBps;
        if (price == 0) {
            uint256 before_ = _held(USDG);
            USDG.forceApprove(address(VAULT), principal);
            VAULT.fund(id, units);
            USDG.forceApprove(address(VAULT), 0);
            if (before_ - _held(USDG) != principal) revert TransferAmountMismatch();
            emit LoanFunded(id, principal, slots, fee, executionFee);
        } else {
            USDG.safeTransfer(msg.sender, principal);
            emit LoanAcquired(id, principal, slots, fee, executionFee);
        }
        // The fee rate is immutable; a top-up keeps that same rate and adds the new quarters.
        ln.slots |= slots;
        ln.lane = lane;
        ln.feeBps = fee;
        ln.principal += uint128(principal);
        // The execution fee is an expense of this moment, so the loan earns its whole cost less the manager fee,
        // which is charged on what the execution fee left: deducting the execution fee here too would count it twice.
        executionPending += executionFee;
        ln.executionFee += uint128(executionFee);
        ln.interest += uint128(interest);
        performingPrincipal += principal;
        categoryPrincipal[lane] += principal;
        assetPrincipal[token] += principal;
        // Active now if this purchase filled the listing, and always for a bought position. Otherwise the term cannot
        // end before now plus the term, so share moves may pause early (`earliestMaturity`) until a settle records the
        // exact maturity, never late.
        IntentVaultViews.CoreLoan memory l = _coreLoan(id);
        uint40 maturity = uint40((l.state == V2State.ACTIVE ? uint256(l.fundedAt) : block.timestamp) + l.term);
        _setMaturity(ln, maturity);
        if (l.state == V2State.ACTIVE) {
            _startAccrual(id, ln, maturity);
            _earnExecution(id, ln);
        }
        // A new record joins the open set once it is booked (here rather than with the other writes, which keeps the
        // function within the stack). Nothing above reads the set on its account: its maturity was unset, so
        // `_setMaturity` cannot refresh the earliest one for it. Nothing above moves the exposure clock either.
        if (!topUp) {
            _openLoans.add(id);
            // The position's window opens with its purchase: only shares exposed from here on share its return.
            exposureWindow[id] = _accrueExposure() << 152 | block.timestamp << 104;
            // A same-second repayment uses [now, now+1]. Keep the opening holders fixed through that interval.
            _shareChangeBlockedAt = uint40(block.timestamp);
        }
    }

    /// @notice Release this strategy's units from a listing that has not activated, at any time before it does;
    /// the refund is booked by `settle` once the cash is here, whatever the listing does afterwards.
    function withdrawCommitment(uint256 id) external nonReentrant {
        Loan storage ln = loans[id];
        if (ln.principal == 0 || ln.withdrawn || ln.settled) revert UnknownDeal();
        _requireCurator();
        ln.withdrawn = true;
        VAULT.withdrawCommitment(id);
        emit CommitmentWithdrawn(id, ln.principal);
    }

    /// @notice Pull core repayments and refunds and book every listed loan whose outcome is known; anyone may call,
    /// and an empty batch only harvests.
    /// @dev A repaid, withdrawn or cancelled loan settles once its cash has arrived, and a listing past its funding
    /// deadline is cancelled on the core and refunded. A loan repaid before the end of its term books what the price
    /// counted and opens an earnings claim for the rest; one repaid in its purchase second waits for the next. A
    /// withdrawn commitment is only ever refunded, even if others filled the listing and let it default. An active
    /// loan past the end of its term is finalized as a default and written off; its collateral is pulled by
    /// `recover`. An active loan still in term only has its exact maturity recorded.
    function settle(uint256[] calldata ids) external nonReentrant {
        if (ids.length > MAX_BATCH) revert InvalidAmount();
        _harvest();
        for (uint256 i; i < ids.length; ++i) {
            _settle(ids[i]);
        }
        _indexRewards();
    }

    /// @notice Unwind a written-off loan's collateral into side pockets for the shares that bore its write-off, each
    /// up to its part of that loss and the seconds it carried the loan; anyone may call, and a failed attempt (a
    /// paused token, an illiquid pool) can be retried.
    function recover(uint256 id) external nonReentrant {
        Loan storage ln = loans[id];
        if (ln.snapshotId == 0 || ln.recovered) revert NothingToRecover();
        // Every loan this vault holds is token-collateralized: both quotes refuse any other kind.
        IntentVaultViews.CoreLoan memory l = _coreLoan(id);
        GageV2TokenCollateralAccount custody = GageV2TokenCollateralAccount(payable(l.account));
        if (!custody.recovered()) VAULT.recoverDefault(id, l.collateral, 0, block.timestamp);
        ln.recovered = true;
        uint256 amount = VAULT.claimableRecovery(id, 0, address(this));
        if (amount != 0) {
            address token = custody.recoveryTokens(0);
            uint256 before_ = _held(IERC20(token));
            VAULT.withdrawRecovery(id, 0, address(this));
            if (_held(IERC20(token)) - before_ != amount) revert TransferAmountMismatch();
            _openPocket(id, token, amount, ln.snapshotSupply);
            emit CollateralRecovered(id, token, amount);
        }
    }

    /// @notice Collect released sGAGE; existing holders retain entitlement before every share change.
    function harvestRewards(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            if (loans[ids[i]].settled) _retireRewardRecord(ids[i]);
            else _claimReward(ids[i]);
        }
        _indexRewards();
    }

    /// @dev A successful bridge claim may be partial. Never discard the remaining entitlement.
    function _claimReward(uint256 id) internal returns (bool) {
        if (CORE_REWARDS.claimable(id, address(this)) == 0) return true;
        try CORE_REWARDS.claim(id, address(this)) {}
        catch {
            return false;
        }
        return CORE_REWARDS.claimable(id, address(this)) == 0;
    }

    function _checkpointRewards() internal {
        uint256 i = _openLoans.length();
        while (i != 0) {
            uint256 id = _openLoans.pos(--i);
            if (!_claimReward(id)) revert RewardsPending();
            if (loans[id].settled) _openLoans.remove(id);
        }
        // Includes sGAGE sent here directly (a transfer, or a claim another account pays to this vault), independently
        // of this call's claim results.
        _indexRewards();
    }

    /// @dev sGAGE held beyond what is already owed as rewards is new rewards. No side pocket can hold sGAGE: a pocket
    /// holds a loan's collateral token, and the core's own admission check (`GageV2Vault._validate`) refuses sGAGE as
    /// collateral, so no pocket liability is reserved here.
    function _indexRewards() internal {
        uint256 balance = _held(REWARD_TOKEN);
        uint256 supply = totalSupply;
        if (balance > accountedRewards && supply != 0) {
            uint256 amount = balance - accountedRewards;
            accountedRewards += amount;
            accRewardPerShare += Math.mulDiv(amount, REWARD_PRECISION, supply);
            emit RewardsHarvested(amount);
        }
    }

    // ---------------------------------------------------------------- internals

    function _receiveUSDG(uint256 assets) internal {
        uint256 before_ = _held(USDG);
        USDG.safeTransferFrom(msg.sender, address(this), assets);
        if (_held(USDG) - before_ != assets) revert TransferAmountMismatch();
        cash += assets;
    }

    /// @dev This contract's balance of one token.
    function _held(IERC20 token) internal view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function _requireCurator() internal view {
        if (msg.sender != CURATOR) revert NotCurator();
    }

    function _requireSettled() internal view {
        if (block.timestamp >= earliestMaturity) revert SettlementDue();
    }

    /// @dev Funding has no curator bypass. Deployment leaves router and signer zero until the fill path is ready.
    function _requireFunder() internal view {
        if (!fillersOpen || IntentFactory(PROTOCOL_SOURCE).quoteSigner() == address(0)) {
            revert NotCurator();
        }
        _requireFillRouter();
    }

    function _requireFillRouter() internal view {
        if (msg.sender != IntentFactory(PROTOCOL_SOURCE).fillRouter()) revert NotCurator();
    }

    /// @dev Pull the core's credit, and count any USDG that reached this contract outside `cash` as harvested.
    function _harvest() internal {
        // A paused USDG must not stop collateral settlement; uncollected credit stays with the core.
        if (VAULT.cashCredit(address(this)) != 0) try VAULT.withdrawUSDG(address(this)) {} catch {}
        uint256 accounted = cash + curatorFees + protocolFees + executionPending + executionFees
            + pocketLiability[address(USDG)] + unassignedCash;
        uint256 balance = _held(USDG);
        if (balance > accounted) {
            uint256 amount = balance - accounted;
            unassignedCash += amount;
            emit CashHarvested(amount);
        }
    }

    function _settle(uint256 id) internal {
        Loan storage ln = loans[id];
        if (ln.principal == 0) revert UnknownDeal();
        if (ln.settled) {
            _retireRewardRecord(id);
            return;
        }
        IntentVaultViews.CoreLoan memory l = _coreLoan(id);
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
        } else if (l.state == V2State.ACTIVE || l.state == V2State.REPAID) {
            _earnExecution(id, ln);
            uint40 exact = uint40(uint256(l.fundedAt) + l.term);
            if (ln.maturity != exact) _setMaturity(ln, exact);
            if (l.state == V2State.REPAID) {
                // A repayment in the second the window opened is booked from the next second, over one second.
                if (uint40(exposureWindow[id] >> 104) == block.timestamp) return;
                payout = ASSET_POLICY.repayment(l.cap, ln.slots);
            } else {
                // Seen active for the first time: the fixed cost is earned from here to the end of the term.
                if (ln.rate == 0 && ln.interest != 0 && block.timestamp < exact) _startAccrual(id, ln, exact);
                if (block.timestamp < exact) return;
                try VAULT.finalizeDefault(id) {
                    l.state = V2State.DEFAULTED;
                } catch {
                    return;
                }
            }
        } else if (l.state != V2State.DEFAULTED) {
            return;
        }
        if (!ln.withdrawn && l.state == V2State.DEFAULTED) {
            // The fill completed, so its execution fee stays an incurred cost; no manager fee on a loss.
            _earnExecution(id, ln);
            uint256 earned = _close(id, ln, l.token, principal);
            uint64 snapshotId = ++snapshotCount;
            ln.snapshotId = snapshotId;
            // The shares outstanding now bear the write-off through the price (share moves are refused from the
            // end of the term until now), and what its collateral recovers, or any backing added later, goes to them:
            // to each no more than its part of that loss, and no more than the seconds it carried the loan earn it,
            // so a share added in the loan's last second takes about a second's part and a share that left
            // before the end takes none (INT-1). The window still closes at the end of the term.
            _closeWindow(id, uint256(l.fundedAt) + l.term);
            ln.snapshotSupply = totalSupply;
            emit LossReported(id, principal, earned);
            emit LoanWrittenOff(id, principal, snapshotId);
            return;
        }
        if (payout > unassignedCash) return;
        unassignedCash -= payout;
        // A repayment's accrual stops at the second the core recorded it, however late this booking (M-01). A refund
        // never accrued, so its `closedAt` is not read.
        uint256 book = principal + _close(id, ln, l.token, principal);
        uint256 net = _bookPayout(id, ln, payout, principal);
        // The return the price had not counted by then belongs to the shares exposed to the loan until the repayment,
        // not to whoever holds at this booking, even after the end of the term (M-19): the core's `reclaim`
        // closes the second the term ends, so every repayment is early. A refund books no return.
        if (net > book) _setAside(id, ln, net - book, l.closedAt);
        emit LoanSettled(id, l.state, payout);
    }

    /// @dev Repayment and sale share realized-profit accounting. A sale may realize less than already-expensed
    /// execution costs; that is a loss, not a negative performance fee or an arithmetic underflow. No persisting
    /// booking has a payout below principal: a refund returns it exactly, a repayment's quarters repay at least what
    /// they cost (core `cap >= principal`, policy `owed > price`), and a sale below book value reverts `SaleBelowBook`
    /// after this returns. `executeLenderSale` marks the execution fee earned first, so the refund branch cannot run
    /// for a sale.
    function _bookPayout(uint256 id, Loan storage ln, uint256 payout, uint256 principal)
        internal
        returns (uint256 net)
    {
        net = payout;
        if (payout > principal) {
            // The fee is charged on the interest actually received less the execution fees already expensed, at the
            // rate snapshotted when the loan was funded.
            uint256 profit = payout - principal;
            uint256 fee =
                profit > ln.executionFee ? IntentFeeMath.performanceFee(profit, ln.executionFee, ln.feeBps) : 0;
            uint256 protocolShare = fee * IntentFeeMath.PROTOCOL_SHARE_BPS / IntentFeeMath.BPS;
            net -= fee;
            protocolFees += protocolShare;
            curatorFees += fee - protocolShare;
            emit ProfitReported(id, profit, fee);
        } else if (!ln.executionEarned && ln.executionFee != 0) {
            // A refund: the loan never ran for this purchase, so no execution fee was earned.
            uint256 reversed = ln.executionFee;
            ln.executionFee = 0;
            executionPending -= reversed;
            cash += reversed;
            emit ExecutionFeeReversed(id, reversed);
        }
        cash += net;
    }

    /// @dev Book the same interest used by live pricing, clear its rate, then remove the principal and open record.
    function _close(uint256 id, Loan storage ln, address token, uint256 principal) internal returns (uint256 earned) {
        earned = _earnedScaled(id, ln) / RATE_PRECISION;
        ln.rate = 0;
        _unbook(ln, token, principal);
        _drop(id, ln);
    }

    /// @dev The loan is seen active for the first time: the fill completed and its execution fee is owed.
    function _earnExecution(uint256 id, Loan storage ln) internal {
        uint256 fee = ln.executionFee;
        if (fee == 0 || ln.executionEarned) return;
        ln.executionEarned = true;
        executionPending -= fee;
        executionFees += fee;
        emit ExecutionFeeEarned(id, fee);
    }

    /// @dev Principal that is no longer lent stops counting toward priced assets and the category and asset caps.
    function _unbook(Loan storage ln, address token, uint256 principal) internal {
        performingPrincipal -= principal;
        categoryPrincipal[ln.lane] -= principal;
        assetPrincipal[token] -= principal;
    }

    function _drop(uint256 id, Loan storage ln) internal {
        ln.settled = true;
        // A failed reward transfer must not block principal/default settlement.
        _retireRewardRecord(id);
        if (ln.maturity == earliestMaturity) _refreshEarliest();
    }

    function _retireRewardRecord(uint256 id) internal {
        if (_claimReward(id)) _openLoans.remove(id);
    }

    function _setMaturity(Loan storage ln, uint40 maturity) internal {
        uint40 previous = ln.maturity;
        ln.maturity = maturity;
        if (maturity < earliestMaturity) earliestMaturity = maturity;
        else if (previous == earliestMaturity) _refreshEarliest();
    }

    function _refreshEarliest() internal {
        uint40 earliest = NO_DEADLINE;
        uint256 length = _openLoans.length();
        for (uint256 i; i < length; ++i) {
            Loan storage ln = loans[_openLoans.pos(i)];
            if (ln.settled) continue;
            if (ln.maturity < earliest) earliest = ln.maturity;
        }
        earliestMaturity = earliest;
    }

    /// @dev Earn the loan's net interest evenly from its activation observation until its own maturity.
    function _startAccrual(uint256 id, Loan storage ln, uint40 maturity) internal {
        ln.rate = SafeCast.toUint128(uint256(ln.interest) * RATE_PRECISION / (maturity - block.timestamp));
        ln.clockStart = uint64(block.timestamp);
        emit LoanAccruing(id, ln.interest, maturity);
    }

    /// @dev Shared reserve valuation for pricing, available liquidity and reserve withdrawals. Without reserve shares
    /// there is nothing to value, so the reserve is not read; while shares are held, its failure reverts pricing.
    function _reserveAssets() internal view returns (uint256) {
        uint256 shares = reserveShares;
        return shares == 0 ? 0 : RESERVE.convertToAssets(shares);
    }

    function _coreLoan(uint256 id) internal view returns (IntentVaultViews.CoreLoan memory) {
        return SHARE_VIEWS.coreLoan(VAULT, id);
    }

    /// @dev Pricing and booking cap repaid loans at the core's close time; other schedules retain their maturity
    /// cap. A running schedule was observed ACTIVE, so its repayment cannot precede `clockStart`.
    function _earnedScaled(uint256 id, Loan storage ln) internal view returns (uint256) {
        if (ln.rate == 0) return 0;
        uint256 end = Math.min(VAULT.accrualEnd(id), ln.maturity);
        return uint256(ln.rate) * (end - ln.clockStart);
    }

    /// @dev Move a position's return that the share price has not counted out of `cash` into a USDG earnings pocket
    /// for the shares exposed to the position over its window: from its purchase to `end`, at least one second.
    /// `end` is the second the core recorded the repayment, or now for a sale. What the price counted up to `end` stays
    /// in `cash`. Live pricing already uses the repayment's `end`, so booking changes the price by at most a raw unit
    /// per purchase of the position. Each reading moved the clock by the seconds
    /// since the last one times EXPOSURE_PRECISION over the shares and the virtual shares, rounded down: the window's
    /// seconds times EXPOSURE_PRECISION, less the virtual shares' part of the clock's movement, is what the holders
    /// carried plus that rounding. The virtual shares hold no claim.
    function _setAside(uint256 id, Loan storage ln, uint256 amount, uint256 end) internal {
        if (end == uint40(exposureWindow[id] >> 104)) {
            // Only a sale can book a gain in the second the position was bought; a repayment waits for the next one.
            if (block.timestamp == end) revert SaleTooSoon();
            // Shares could not change after the purchase until the next second, so this interval belongs to
            // the holders who funded the position, including when the vault had no shares beforehand.
            ++end;
        }
        ln.repaid = true;
        cash -= amount;
        _openPocket(id, address(USDG), amount, _closeWindow(id, end));
    }

    /// @dev Close a position's exposure window at `end`, a second after its purchase and no later than now, and return
    /// the exposure its holders carried over it: an earnings pocket opened on it splits by that exposure. A
    /// write-off closes it too, and its pockets split by instead.
    function _closeWindow(uint256 id, uint256 end) internal returns (uint256) {
        uint256 w = exposureWindow[id];
        uint256 opened = w >> 152;
        _accrueExposure();
        // At `end` now, this reads the clock just advanced; an earlier `end` reads the clock's log.
        uint256 closed = _indexAt(end);
        exposureWindow[id] = w >> 104 << 104 | closed;
        return (end - uint40(w >> 104)) * EXPOSURE_PRECISION - VIRTUAL_SHARES * (closed - opened);
    }

    function _openPocket(uint256 id, address token, uint256 amount, uint256 supply) internal {
        uint256 pocketId = ++pocketCount;
        pockets[pocketId] = Pocket(id, token, amount, supply, 0, 0);
        pocketLiability[token] += amount;
        emit PocketCreated(pocketId, id, token, amount, supply);
    }

    /// @dev What redeeming `shares` pays: never more than the vault holds. Below the first share price the virtual
    /// assets' rounding (ASSET_SCALE, 1e12 at eighteen decimals) values the whole supply above `totalAssets()`, which
    /// no exit could pay, so the last holder redeems all there is. `convertToAssets` keeps the plain rate.
    function _redeemable(uint256 shares) internal view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 value = Math.mulDiv(shares, assets + ASSET_SCALE, totalSupply + VIRTUAL_SHARES);
        return totalSupply != 0 && value > assets ? assets : value;
    }

    /// @dev Take USDG from cash, then redeem the reserve for the shortfall. The burned reserve shares are returned.
    function _payOut(uint256 assets) internal returns (uint256 burned) {
        uint256 c = cash;
        if (assets <= c) {
            cash = c - assets;
            return 0;
        }
        uint256 need = assets - c;
        if (need > _reserveAssets()) revert InsufficientLiquidity();
        uint256 beforeCash = _held(USDG);
        uint256 beforeShares = _held(RESERVE);
        RESERVE.withdraw(need, address(this), address(this));
        burned = beforeShares - _held(RESERVE);
        if (burned == 0 || _held(USDG) - beforeCash != need) revert TransferAmountMismatch();
        if (burned > reserveShares) revert InsufficientLiquidity();
        reserveShares -= burned;
        cash = 0;
    }

    function _mint(address to, uint256 shares) internal {
        _beforeBalanceChange(to);
        balanceOf[to] += shares;
        totalSupply += shares;
        emit Transfer(address(0), to, shares);
    }

    function _burn(address from, uint256 shares) internal {
        _beforeBalanceChange(from);
        balanceOf[from] -= shares;
        totalSupply -= shares;
        emit Transfer(from, address(0), shares);
    }

    /// @dev Preserve the holder's exposure up to now, which every pocket splits by, and settle rewards before a
    /// balance moves, including both holders of a transfer, before either balance is written.
    function _beforeBalanceChange(address who) internal {
        if (block.timestamp == _shareChangeBlockedAt) revert SaleTooSoon();
        uint256 index = _accrueExposure();
        uint256[] storage h = _exposure[who];
        uint256 n = h.length;
        uint256 last = n == 0 ? 0 : h[n - 1];
        uint256 from = last >> 152;
        // Changes at one reading share one entry: no exposure was carried between them. A holder's exposure grows by
        // less than EXPOSURE_PRECISION a second, so it stays under 2^152, clear of the reading, for 180,000 years.
        if (n == 0 || from != index) h.push(index << 152 | (uint152(last) + balanceOf[who] * (index - from)));
        // The same in wall-clock seconds: changes in one second share one entry, and a balance (under 2^90)
        // times a timestamp stays under 2^216.
        uint256[] storage held = _heldSeconds[who];
        uint256 m = held.length;
        uint256 lastHeld = m == 0 ? 0 : held[m - 1];
        uint256 since = lastHeld >> 216;
        if (m == 0 || since != block.timestamp) {
            held.push(block.timestamp << 216 | (uint216(lastHeld) + balanceOf[who] * (block.timestamp - since)));
        }
        _settleRewards(who);
    }

    /// @dev Advance the exposure clock to now and log the point it leaves. Between two writes the supply was constant,
    /// so the clock is exact at every written point and linear in between.
    function _accrueExposure() internal returns (uint256 index) {
        index = exposureIndex;
        uint256 at = _exposureAt;
        if (block.timestamp == at) return index;
        _exposureLog.push(at << 104 | index);
        uint256 supply = totalSupply;
        if (supply != 0) index += (block.timestamp - at) * EXPOSURE_PRECISION / (supply + VIRTUAL_SHARES);
        exposureIndex = uint104(index);
        _exposureAt = uint40(block.timestamp);
    }

    /// @dev The exposure clock at a past second `t`, no earlier than the clock's first point: interpolated between the
    /// two written points around it, rounded down.
    function _indexAt(uint256 t) internal view returns (uint256) {
        return SHARE_VIEWS.indexAt(t);
    }

    function _settleRewards(address who) internal {
        _rewardOwed[who] = rewardClaimable(who);
        _rewardIndex[who] = accRewardPerShare;
    }
}
