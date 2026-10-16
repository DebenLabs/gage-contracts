// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {Kind} from "./types/Types.sol";
import {V2Loan, V2State} from "./v2/V2Types.sol";
import {GageV2Vault} from "./v2/GageV2Vault.sol";
import {GageV2Rewards} from "./v2/GageV2Rewards.sol";
import {GageV2CollateralAccount} from "./v2/GageV2CollateralAccount.sol";
import {IGageV2LegacyCore} from "./interfaces/IGageV2LegacyCore.sol";

/// @notice Earn portfolio categories; separate from the collateral registry's token lanes.
enum EarnLane {
    STOCK,
    MEME,
    LP
}

/// @notice The fee companion: splits collected performance fees between the curator recipient and the protocol floor.
interface IHybridFees {
    /// @notice Read the immutable strategy served by the companion.
    function STRATEGY() external view returns (address);
    /// @notice Split fees the strategy has just transferred in between the curator and the protocol floor.
    function distribute(uint256 amount) external;
}

/// @notice A pooled USDG strategy: one share class over idle cash, an ERC-4626 reserve and Gage V2 loans at principal.
/// @dev No oracle: a loan is carried at exactly what was paid for it until it repays, refunds or falls overdue, when
/// its principal leaves the share price at once. Recoveries belong to the holders recorded at write-down, even
/// after they exit. Deposits pay for realized profit in full; withdrawals release that profit linearly. Future
/// repayment profit remains pooled among holders exposed before realization. Exits beyond free liquidity queue and are served
/// at the share price of the moment they are served; repayments serve that queue before they can fund a new loan.
/// The performance fee is charged only on the vault's new share-price high, pull-only through the fee companion.
/// Shares are not transferable. Curator approvals express underwriting decisions, not proofs of fair market value.
contract HybridVault is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    /// @notice Version of the mandate tuple and Earn category indices; legacy deployments use a different shape.
    uint256 public constant MANDATE_VERSION = 2;
    uint256 internal constant MAX_BATCH = 32;
    uint256 internal constant MAX_OPEN_LOANS = 32;
    uint256 internal constant MAX_TOKEN_CEILING = type(uint128).max;
    uint256 internal constant MAX_TOTAL_DEPOSITS = type(uint128).max;
    uint256 internal constant MAX_WEIGHT_BPS = 10_000;
    uint16 internal constant MAX_FEE_BPS = 5000;
    uint256 internal constant MAX_APPROVAL_TTL = 1 hours;
    uint8 internal constant UNITS = 4;
    /// @notice Virtual shares of the conversion denominator: one USDG unit starts worth 10^12 shares.
    uint256 public constant VIRTUAL_SHARES = 1e12;
    uint256 internal constant PRICE_PRECISION = 1e36;
    uint256 internal constant REWARD_PRECISION = 1e18;
    /// @notice Realized loan profit, net of fees, is credited to the share price linearly over this window.
    uint32 public constant PROFIT_UNLOCK = 7 days;

    struct Params {
        address core;
        address reserve;
        uint16[3] laneWeights;
        address curator;
        uint32 maxLoanTerm;
        uint16 minReturnBps;
        uint16 maxGageExposureBps;
        uint128 minDeposit;
        uint128 maxTotalDeposits;
    }

    struct Approval {
        uint40 validUntil;
        uint128 principal;
        uint64 epoch;
        uint8 units;
    }

    struct Request {
        address owner;
        uint256 shares;
    }

    struct Pocket {
        uint256 dealId;
        address token;
        uint256 amount;
        uint256 supply;
        uint256 claimed;
    }

    struct Snapshot {
        uint64 id;
        uint256 balance;
    }

    GageV2Vault public immutable VAULT;
    address internal immutable COLLATERAL_VALIDATOR;
    GageV2Rewards public immutable CORE_REWARDS;
    ICollateralRegistry public immutable REGISTRY;
    IERC4626 public immutable RESERVE;
    IERC20 public immutable USDG;
    IERC20 public immutable REWARD_TOKEN;
    address public immutable CURATOR;
    uint32 public immutable GRACE;
    /// @dev The account that deployed the strategy may wire its fee companion once, so a factory can finish setup.
    address internal immutable DEPLOYER;
    Params private _params;
    mapping(EarnLane => uint16) public laneWeightBps;
    mapping(EarnLane => uint256) public lanePrincipal;
    mapping(uint256 => EarnLane) public loanLane;
    mapping(address => uint256) public tokenCeiling;
    mapping(address => uint256) public tokenUnit;
    // Fees.
    uint16 public feeBps;
    address public fees;
    uint256 public feeAccrued;
    mapping(uint256 => uint16) public loanFeeBps;
    /// @notice The highest full-assets share price, in USDG units per share scaled by 1e36, starting at the initial
    /// price and raised by every profit that sets a new high, whether or not that loan carried a fee.
    uint256 public highWaterPrice;
    // Shares.
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lockedShares;
    mapping(address => Snapshot[]) private _snapshots;
    uint64 private _snapshotCount;
    mapping(uint256 => uint64) private _loanSnapshot;
    mapping(uint256 => uint256) private _loanSnapshotSupply;
    mapping(uint256 => uint64) private _pocketSnapshot;
    mapping(address => uint256) private _pocketLiability;
    // Assets. USDG also reserves recovery pockets: cash + fees + claims + pockets + harvested - assigned.
    uint256 public cash;
    uint256 public reserveShares;
    uint256 public performingPrincipal;
    uint256 public overduePrincipal;
    uint256 public lockedProfit;
    uint64 public unlockStart;
    uint64 public unlockEnd;
    uint256 public harvestedCash;
    uint256 public assignedCash;
    // Withdrawal requests.
    mapping(uint256 => Request) public requests;
    uint256 public requestCount;
    uint256 public requestHead = 1;
    uint256 public pendingShares;
    mapping(address => uint256) public claimable;
    uint256 public claimableTotal;
    // Side pockets reference the holder snapshot captured when principal was written down.
    mapping(uint256 => Pocket) public pockets;
    uint256 public pocketCount;
    mapping(uint256 => mapping(address => bool)) public pocketClaimed;
    // Rewards.
    uint256 public accRewardPerShare;
    uint256 public rewardRemainder; // Retained for ABI compatibility; exact dust stays in accounted rewards.
    uint256 private _orphanRewards;
    uint256 private _accountedRewards;
    uint256 private _rewardLiability;
    mapping(uint256 => uint256) private _loanRewardObserved;
    mapping(address => uint256) private _rewardIndex;
    mapping(address => uint256) private _rewardOwed;
    // Loans.
    bool public paused;
    uint64 public approvalEpoch;
    uint256 public approvedPrincipal;
    mapping(uint256 => Approval) public approvals;
    mapping(address => uint256) public borrowerPrincipal;
    mapping(uint256 => bool) public funded;
    mapping(uint256 => bool) public terminal;
    mapping(uint256 => bool) public withdrawn;
    mapping(uint256 => bool) public overdue;
    mapping(uint256 => uint8) public loanSlots;
    mapping(uint256 => uint256) public positionPrincipal;
    // Bounded positions awaiting a terminal outcome.
    uint256[] private _openLoans;

    event LaneWeightSet(EarnLane indexed lane, uint16 bps);
    event TokenCeilingSet(address indexed token, uint256 ceiling);
    event MaxTotalDepositsSet(uint256 cap);
    event FeeSet(uint16 bps);
    event FeesSet(address indexed fees);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event Paused(bool enabled);
    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, uint256 assets, uint256 shares);
    event RedeemRequested(uint256 indexed requestId, address indexed account, uint256 shares);
    event RequestCancelled(uint256 indexed requestId, address indexed account, uint256 shares);
    event RequestServed(
        uint256 indexed requestId, address indexed account, uint256 shares, uint256 assets, uint256 remainingShares
    );
    event Claimed(address indexed account, uint256 assets);
    event ReserveInvested(uint256 assets, uint256 shares);
    event ReserveDivested(uint256 shares, uint256 assets);
    event LoanApproved(uint256 indexed dealId, uint40 validUntil, uint256 principal, uint8 units);
    event LoanRevoked(uint256 indexed dealId);
    event LoanFunded(uint256 indexed dealId, uint256 principal, uint256 sharesBurned, uint8 slots, uint16 feeBps);
    event CommitmentWithdrawn(uint256 indexed dealId, uint256 principal);
    event LoanOverdue(uint256 indexed dealId, uint256 principal);
    event Settled(uint256 indexed dealId, V2State state, uint256 payout);
    event ProfitReported(uint256 indexed dealId, uint256 profit, uint256 fee, uint256 lockedProfit, uint64 unlockEnd);
    event LossReported(uint256 indexed dealId, uint256 loss, uint256 absorbed);
    event CashHarvested(uint256 amount);
    event CollateralRecovered(uint256 indexed dealId, address indexed token, uint256 amount);
    event PocketCreated(
        uint256 indexed pocketId, uint256 indexed dealId, address indexed token, uint256 amount, uint256 supply
    );
    event PocketClaimed(uint256 indexed pocketId, address indexed account, uint256 amount);
    event RewardsHarvested(uint256 indexed dealId, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 amount);

    error InvalidConfiguration();
    error InvalidAmount();
    error NotCurator();
    error PausedError();
    error NotOwner();
    error IneligibleDeal(uint256 id);
    error ApprovalExpired();
    error LimitExceeded();
    error InsufficientLiquidity();
    error RequestsPending();
    error TransferAmountMismatch();
    error Slippage();
    error UnknownDeal();
    error AlreadyClaimed();
    error SettlementPending();

    constructor(Params memory p) {
        if (
            p.core.code.length == 0 || p.reserve.code.length == 0 || p.curator == address(0)
                || p.curator == address(this) || p.maxLoanTerm == 0 || p.maxLoanTerm > 90 days
                || p.maxGageExposureBps == 0 || p.maxGageExposureBps > 10_000 || p.minDeposit == 0
                || p.minDeposit > p.maxTotalDeposits || p.minReturnBps > 10_000
        ) revert InvalidConfiguration();
        VAULT = GageV2Vault(p.core);
        COLLATERAL_VALIDATOR = address(IGageV2LegacyCore(address(VAULT)).VALIDATOR());
        CORE_REWARDS = VAULT.REWARDS();
        REGISTRY = ICollateralRegistry(address(VAULT.REGISTRY()));
        USDG = VAULT.USDG();
        REWARD_TOKEN = VAULT.SGAGE();
        RESERVE = IERC4626(p.reserve);
        CURATOR = p.curator;
        DEPLOYER = msg.sender;
        GRACE = VAULT.GRACE();
        if (
            RESERVE.asset() != address(USDG) || GRACE > 7 days || VAULT.UNITS() != UNITS
                || address(CORE_REWARDS.SGAGE()) != address(REWARD_TOKEN) || address(REWARD_TOKEN) == address(USDG)
                || address(REWARD_TOKEN) == address(RESERVE)
        ) {
            revert InvalidConfiguration();
        }
        if (IERC20Metadata(address(USDG)).decimals() > 18) revert InvalidConfiguration();
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += p.laneWeights[i];
            laneWeightBps[EarnLane(i)] = p.laneWeights[i];
            emit LaneWeightSet(EarnLane(i), p.laneWeights[i]);
        }
        if (sum > MAX_WEIGHT_BPS) revert InvalidConfiguration();
        _params = p;
        highWaterPrice = PRICE_PRECISION / VIRTUAL_SHARES;
    }

    // ---------------------------------------------------------------- curator settings

    /// @notice Set a lane's cap on strategy assets; existing loans keep their terms.
    function setLaneWeight(EarnLane lane, uint16 bps) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        uint256 sum = uint256(laneWeightBps[EarnLane.STOCK]) + laneWeightBps[EarnLane.MEME] + laneWeightBps[EarnLane.LP];
        if (sum - laneWeightBps[lane] + bps > MAX_WEIGHT_BPS) revert InvalidConfiguration();
        laneWeightBps[lane] = bps;
        emit LaneWeightSet(lane, bps);
    }

    /// @notice Admit a registry token at a bounded USDG price per whole unit, or close it with zero.
    function setTokenCeiling(address token, uint256 ceiling) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (ceiling > MAX_TOKEN_CEILING) revert InvalidConfiguration();
        if (ceiling != 0) {
            (bool allowed,) = _tokenPolicy(token);
            if (token.code.length == 0 || token == address(USDG) || token == address(RESERVE) || !allowed) {
                revert InvalidConfiguration();
            }
            uint8 decimals_ = IERC20Metadata(token).decimals();
            if (decimals_ > 36) revert InvalidConfiguration();
            tokenUnit[token] = 10 ** decimals_;
        }
        tokenCeiling[token] = ceiling;
        emit TokenCeilingSet(token, ceiling);
    }

    /// @notice Move the strategy's deposit cap, the one mandate limit the curator may change after deployment.
    /// @dev A zero cap closes deposits. A cap below current assets takes no deposit away and delays no exit; it
    /// only refuses new deposits until assets fall back under it. Every other mandate limit stays immutable.
    /// @param cap The new ceiling on `fullAssets()`, in USDG units.
    function setMaxTotalDeposits(uint256 cap) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (cap > MAX_TOTAL_DEPOSITS) revert InvalidConfiguration();
        _params.maxTotalDeposits = uint128(cap);
        emit MaxTotalDepositsSet(cap);
    }

    /// @notice Set the performance-fee rate, bounded and snapshotted for loans funded afterwards; needs the companion.
    function setFee(uint16 bps) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        if (bps > MAX_FEE_BPS || (bps != 0 && fees == address(0))) revert InvalidConfiguration();
        feeBps = bps;
        emit FeeSet(bps);
    }

    /// @notice Wire the immutable fee companion once, by the curator or the deployer; it must name this strategy.
    function setFees(address companion) external nonReentrant {
        if (fees != address(0)) revert InvalidConfiguration();
        if (msg.sender != CURATOR && msg.sender != DEPLOYER) revert NotCurator();
        if (companion.code.length == 0 || IHybridFees(companion).STRATEGY() != address(this)) {
            revert InvalidConfiguration();
        }
        fees = companion;
        emit FeesSet(companion);
    }

    /// @notice Pause deposits, reserve investment and funding, and invalidate outstanding approvals.
    function setPaused(bool enabled) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        paused = enabled;
        ++approvalEpoch;
        approvedPrincipal = 0;
        emit Paused(enabled);
    }

    /// @notice Move accrued fees to the companion, which splits them between curator and protocol; anyone may call.
    function claimFees() external nonReentrant {
        uint256 amount = feeAccrued;
        if (amount == 0) revert InvalidAmount();
        feeAccrued = 0;
        _transferExact(USDG, fees, amount);
        IHybridFees(fees).distribute(amount);
        emit FeesClaimed(fees, amount);
    }

    // ---------------------------------------------------------------- views

    /// @notice Read the mandate and its initial lane weights; every limit but `maxTotalDeposits` is immutable.
    function params() external view returns (Params memory) {
        return _params;
    }

    /// @notice The deposit token.
    function asset() external view returns (address) {
        return address(USDG);
    }

    /// @notice Shares carry eighteen decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Cash, the reserve at its own conversion and performing loans at principal, before profit unlocking.
    function fullAssets() public view returns (uint256) {
        return cash + _reserveRead(0x07a2d13a, reserveShares) + performingPrincipal - _pendingLoss();
    }

    /// @notice What shares are priced on: full assets less the profit still unlocking.
    function totalAssets() public view returns (uint256) {
        uint256 full = fullAssets();
        uint256 locked = lockedProfitNow();
        return full > locked ? full - locked : 0;
    }

    /// @notice Realized profit not yet credited to the share price.
    function lockedProfitNow() public view returns (uint256) {
        uint256 locked = _lockedProfitNow();
        uint256 loss = _pendingLoss();
        return locked > loss ? locked - loss : 0;
    }

    function _lockedProfitNow() internal view returns (uint256) {
        uint256 end = unlockEnd;
        if (block.timestamp >= end) return 0;
        uint256 start = unlockStart;
        return Math.mulDiv(lockedProfit, end - block.timestamp, end - start);
    }

    /// @notice Shares for a deposit, rounded down against the depositor.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply + VIRTUAL_SHARES, fullAssets() + 1);
    }

    /// @notice USDG for shares, rounded down against the redeemer.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply + VIRTUAL_SHARES);
    }

    /// @notice Shares burned for an exact USDG withdrawal, rounded up against the withdrawer.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + 1, Math.Rounding.Ceil);
    }

    /// @notice Shares the owner may redeem at once: unlocked shares, bounded by the free liquidity below.
    function maxRedeem(address owner) external view returns (uint256) {
        uint256 free = balanceOf[owner] - lockedShares[owner];
        uint256 liquid = freeLiquidity();
        uint256 value = convertToAssets(free);
        return value <= liquid ? free : Math.mulDiv(free, liquid, value);
    }

    /// @notice USDG the owner may withdraw at once, on the same bound.
    function maxWithdraw(address owner) external view returns (uint256) {
        return Math.min(convertToAssets(balanceOf[owner] - lockedShares[owner]), freeLiquidity());
    }

    /// @notice Cash plus the reserve position, capped by the reserve's own withdrawal limit when it reports one.
    /// @dev A reserve that reports zero (the live Morpho vault does) is treated as not reporting, not as empty; the
    /// redemption itself still depends on the reserve's actual liquidity.
    function freeLiquidity() public view returns (uint256) {
        uint256 value = _reserveRead(0x07a2d13a, reserveShares);
        uint256 limit = _reserveRead(0xce96cb77, uint256(uint160(address(this))));
        return cash + (limit == 0 ? value : Math.min(value, limit));
    }

    /// @notice USDG owed to every pending request at the current share price.
    function pendingRequestAssets() public view returns (uint256) {
        return convertToAssets(pendingShares);
    }

    /// @notice The holder's share balance when a side pocket was created; the current balance if unchanged since.
    function balanceOfAt(address who, uint256 pocketId) public view returns (uint256) {
        uint256 snapshotId = _pocketSnapshot[pocketId];
        if (snapshotId == 0) return balanceOf[who];
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
        return Math.mulDiv(pk.amount, balanceOfAt(who, pocketId), pk.supply);
    }

    /// @notice Accrued sGAGE entitlement; payment can wait for the underlying tokens to reach this vault.
    function rewardClaimable(address who) public view returns (uint256) {
        return _rewardOwed[who] + Math.mulDiv(balanceOf[who], accRewardPerShare - _rewardIndex[who], REWARD_PRECISION);
    }

    /// @notice The settled reward amount and index needed to reproduce `rewardClaimable` off chain exactly.
    function rewardState(address who) external view returns (uint256 owed, uint256 index) {
        return (_rewardOwed[who], _rewardIndex[who]);
    }

    // ---------------------------------------------------------------- depositors

    /// @notice Add USDG and receive shares at the current price.
    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (paused) revert PausedError();
        if (assets < _params.minDeposit) revert InvalidAmount();
        if (_checkpoint()) revert SettlementPending();
        if (fullAssets() + assets > _params.maxTotalDeposits) revert LimitExceeded();
        shares = convertToShares(assets);
        if (shares == 0 || shares < minShares) revert Slippage();
        uint256 before_ = _balanceOf(address(USDG), address(this));
        USDG.safeTransferFrom(msg.sender, address(this), assets);
        if (_balanceOf(address(USDG), address(this)) - before_ != assets) revert TransferAmountMismatch();
        cash += assets;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burn shares for USDG at once, from cash and then the reserve; fails beyond free liquidity.
    function redeem(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (shares == 0 || shares > balanceOf[msg.sender] - lockedShares[msg.sender]) revert InvalidAmount();
        _checkpoint();
        assets = convertToAssets(shares);
        if (assets < minAssets) revert Slippage();
        _payOut(assets);
        _burn(msg.sender, shares);
        _transferExact(USDG, msg.sender, assets);
        emit Withdrawn(msg.sender, assets, shares);
    }

    /// @notice Take exact USDG at once, burning at most `maxShares`.
    function withdraw(uint256 assets, uint256 maxShares) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert InvalidAmount();
        _checkpoint();
        shares = previewWithdraw(assets);
        if (shares > maxShares) revert Slippage();
        if (shares > balanceOf[msg.sender] - lockedShares[msg.sender]) revert InvalidAmount();
        _payOut(assets);
        _burn(msg.sender, shares);
        _transferExact(USDG, msg.sender, assets);
        emit Withdrawn(msg.sender, assets, shares);
    }

    /// @notice Queue shares for redemption beyond free liquidity; they stay owned, and priced, until served.
    function requestRedeem(uint256 shares) external nonReentrant returns (uint256 id) {
        if (shares == 0 || shares > balanceOf[msg.sender] - lockedShares[msg.sender]) revert InvalidAmount();
        lockedShares[msg.sender] += shares;
        pendingShares += shares;
        id = ++requestCount;
        requests[id] = Request(msg.sender, shares);
        emit RedeemRequested(id, msg.sender, shares);
    }

    /// @notice Withdraw an unserved request; the shares are unlocked without leaving the vault.
    function cancelRequest(uint256 id) external nonReentrant {
        Request storage r = requests[id];
        if (r.owner != msg.sender) revert NotOwner();
        uint256 shares = r.shares;
        if (shares == 0) revert InvalidAmount();
        r.shares = 0;
        lockedShares[msg.sender] -= shares;
        pendingShares -= shares;
        emit RequestCancelled(id, msg.sender, shares);
    }

    /// @notice Serve the queue oldest first at today's share price, up to `maxAssets` of cash and reserve liquidity.
    /// @dev Anyone may call. A partially served request stays at the head; served USDG is credited for withdrawal.
    function serveRequests(uint256 maxRequests, uint256 maxAssets) external nonReentrant {
        _checkpoint();
        uint256 id = requestHead;
        uint256 budget = Math.min(maxAssets, freeLiquidity());
        uint256 served;
        while (id <= requestCount && served < maxRequests) {
            ++served;
            Request storage r = requests[id];
            uint256 shares = r.shares;
            if (shares == 0) {
                ++id;
                continue;
            }
            uint256 assets = convertToAssets(shares);
            if (assets == 0) {
                // Worth less than one unit: hand the shares back so a dust request cannot stall the queue.
                r.shares = 0;
                lockedShares[r.owner] -= shares;
                pendingShares -= shares;
                emit RequestCancelled(id, r.owner, shares);
                ++id;
                continue;
            }
            if (assets > budget) {
                shares = Math.mulDiv(shares, budget, assets);
                assets = convertToAssets(shares);
                if (shares == 0 || assets == 0) break;
            }
            budget -= assets;
            _payOut(assets);
            _burn(r.owner, shares);
            lockedShares[r.owner] -= shares;
            pendingShares -= shares;
            r.shares -= shares;
            claimable[r.owner] += assets;
            claimableTotal += assets;
            emit RequestServed(id, r.owner, shares, assets, r.shares);
            if (r.shares != 0) break;
            ++id;
        }
        requestHead = id;
    }

    /// @notice Withdraw USDG credited by served requests.
    function claim() external nonReentrant returns (uint256 assets) {
        assets = claimable[msg.sender];
        if (assets == 0) revert InvalidAmount();
        claimable[msg.sender] = 0;
        claimableTotal -= assets;
        _transferExact(USDG, msg.sender, assets);
        emit Claimed(msg.sender, assets);
    }

    /// @notice Withdraw the caller's part of one side pocket, in the recovered token.
    function claimPocket(uint256 pocketId) external nonReentrant returns (uint256 amount) {
        Pocket storage pk = pockets[pocketId];
        if (pk.supply == 0) revert UnknownDeal();
        if (pocketClaimed[pocketId][msg.sender]) revert AlreadyClaimed();
        pocketClaimed[pocketId][msg.sender] = true;
        amount = Math.mulDiv(pk.amount, balanceOfAt(msg.sender, pocketId), pk.supply);
        if (amount == 0) revert InvalidAmount();
        pk.claimed += amount;
        _pocketLiability[pk.token] -= amount;
        if (pk.token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferAmountMismatch();
        } else {
            _transferExact(IERC20(pk.token), msg.sender, amount);
        }
        emit PocketClaimed(pocketId, msg.sender, amount);
    }

    /// @notice Withdraw the caller's accrued sGAGE.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _checkpoint();
        _settleRewards(msg.sender);
        uint256 owed = _rewardOwed[msg.sender];
        uint256 balance = _balanceOf(address(REWARD_TOKEN), address(this));
        uint256 reserved = _pocketLiability[address(REWARD_TOKEN)] + _orphanRewards;
        uint256 available = balance > reserved ? balance - reserved : 0;
        amount = Math.min(owed, available);
        if (amount == 0) revert InvalidAmount();
        _rewardOwed[msg.sender] = owed - amount;
        _accountedRewards -= amount;
        _rewardLiability -= amount;
        _transferExact(REWARD_TOKEN, msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    // ---------------------------------------------------------------- reserve

    /// @notice Move idle cash into the reserve; anyone may call while not paused.
    function investReserve(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        if (paused) revert PausedError();
        if (assets == 0 || assets > cash) revert InvalidAmount();
        shares = this.depositReserve(assets, minShares);
        cash -= assets;
        reserveShares += shares;
        emit ReserveInvested(assets, shares);
    }

    /// @notice Bring reserve shares back to idle cash; curator only, so nobody else can forgo reserve returns.
    function divestReserve(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        if (msg.sender != CURATOR) revert NotCurator();
        if (shares == 0 || shares > reserveShares) revert InvalidAmount();
        assets = _redeem(shares, minAssets);
        reserveShares -= shares;
        cash += assets;
        emit ReserveDivested(shares, assets);
    }

    // ---------------------------------------------------------------- loans

    /// @notice Approve buying `units` unfilled lender units of one currently eligible listing for at most one hour.
    /// @dev The approved principal is the largest amount those units can cost; the exact amount is fixed at funding.
    function approveLoan(uint256 id, uint40 validUntil, uint8 units) external nonReentrant {
        if (paused) revert PausedError();
        if (msg.sender != CURATOR) revert NotCurator();
        if (validUntil <= block.timestamp || validUntil > block.timestamp + MAX_APPROVAL_TTL) revert ApprovalExpired();
        V2Loan memory l = _loan(id);
        uint256 principal = uint256(units) * Math.ceilDiv(l.principal, UNITS);
        _checkDeal(id, l, units, principal);
        _revoke(id);
        if (approvedPrincipal + performingPrincipal + overduePrincipal + principal > _params.maxTotalDeposits) {
            revert LimitExceeded();
        }
        approvals[id] = Approval(validUntil, uint128(principal), approvalEpoch, units);
        approvedPrincipal += principal;
        emit LoanApproved(id, validUntil, principal, units);
    }

    /// @notice Revoke a curator approval, or clear an expired approval permissionlessly.
    function revokeLoan(uint256 id) external nonReentrant {
        if (msg.sender != CURATOR && approvals[id].validUntil >= block.timestamp) revert NotCurator();
        _revoke(id);
    }

    function _revoke(uint256 id) internal {
        Approval memory old = approvals[id];
        if (old.epoch == approvalEpoch) approvedPrincipal -= old.principal;
        delete approvals[id];
        emit LoanRevoked(id);
    }

    /// @notice Execute a fresh curator approval from pooled cash and reserve; pending requests keep their liquidity.
    function fund(uint256 id, uint256 maxReserveShares) external nonReentrant {
        if (paused) revert PausedError();
        _checkpoint();
        if (_openLoans.length >= MAX_OPEN_LOANS) revert LimitExceeded();
        Approval memory approval = approvals[id];
        if (approval.principal == 0 || approval.epoch != approvalEpoch || block.timestamp > approval.validUntil) {
            revert ApprovalExpired();
        }
        V2Loan memory l = _loan(id);
        (uint8 slots, uint256 principal) = _selectSlots(id, l.principal, approval.units);
        EarnLane lane = _checkDeal(id, l, approval.units, principal);
        if (principal > approval.principal) revert LimitExceeded();
        uint256 liquid = cash + _reserveRead(0x07a2d13a, reserveShares);
        if (principal > liquid) revert InsufficientLiquidity();
        if (liquid - principal < pendingRequestAssets()) revert RequestsPending();
        uint256 burned = _payOut(principal);
        if (burned > maxReserveShares) revert Slippage();
        _revoke(id);
        funded[id] = true;
        _openLoans.push(id);
        loanFeeBps[id] = feeBps;
        loanSlots[id] = slots;
        positionPrincipal[id] = principal;
        performingPrincipal += principal;
        borrowerPrincipal[l.originator] += principal;
        loanLane[id] = lane;
        lanePrincipal[lane] += principal;
        uint256 before_ = _balanceOf(address(USDG), address(this));
        USDG.forceApprove(address(VAULT), principal);
        VAULT.fund(id, approval.units);
        USDG.forceApprove(address(VAULT), 0);
        if (before_ - _balanceOf(address(USDG), address(this)) != principal) revert TransferAmountMismatch();
        emit LoanFunded(id, principal, burned, slots, feeBps);
    }

    /// @notice Release this strategy's units from a listing that has not activated; the refund settles as cash.
    function withdrawCommitment(uint256 id) external nonReentrant {
        if (!funded[id] || withdrawn[id] || terminal[id]) revert UnknownDeal();
        if (msg.sender != CURATOR) revert NotCurator();
        withdrawn[id] = true;
        VAULT.withdrawCommitment(id);
        emit CommitmentWithdrawn(id, positionPrincipal[id]);
    }

    /// @notice Write down loans past their term that have not repaid; anyone may call, the engine's clock decides.
    function markOverdue(uint256[] calldata ids) external nonReentrant {
        _checkBatch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (!funded[id]) revert UnknownDeal();
            if (terminal[id] || overdue[id]) continue;
            V2Loan memory l = _loan(id);
            if (l.state == V2State.REPAID || !_isImpaired(l)) continue;
            _writeDown(id);
        }
    }

    /// @notice Settle every ready position in funding order; ids retain the bounded compatibility/validation surface.
    function settle(uint256[] calldata ids) external nonReentrant {
        _checkBatch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (!funded[ids[i]]) revert UnknownDeal();
        }
        _checkpoint();
    }

    /// @notice Pull available core repayments and refunds without assigning any loan twice.
    function harvestCash() external nonReentrant {
        _harvestCash();
    }

    function _harvestCash() internal {
        _reconcileCash();
        uint256 available = VAULT.cashCredit(address(this));
        if (available == 0) return;
        uint256 before_ = _balanceOf(address(USDG), address(this));
        // A paused USDG must not prevent collateral settlement. Uncollected repayments stay unassigned.
        try VAULT.withdrawUSDG(address(this)) {
            if (_balanceOf(address(USDG), address(this)) - before_ != available) revert TransferAmountMismatch();
            harvestedCash += available;
            emit CashHarvested(available);
        } catch {}
    }

    /// @notice Pull released lender rewards of funded loans and spread them over every share.
    function harvestRewards(uint256[] calldata ids) external nonReentrant {
        _checkBatch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (!funded[id]) revert UnknownDeal();
            _accrueReward(id);
        }
        _reconcileRewards();
    }

    // ---------------------------------------------------------------- internals

    /// @dev Bring every bounded live position current before a share price is used or a balance changes.
    function _checkpoint() internal returns (bool settlementPending) {
        _harvestCash();
        uint256 length = _openLoans.length;
        uint256 write;
        for (uint256 i; i < length; ++i) {
            uint256 id = _openLoans[i];
            if (terminal[id]) continue;
            V2Loan memory l = _loan(id);
            if (!overdue[id] && _isImpaired(l)) _writeDown(id);
            if (l.state == V2State.ACTIVE && block.timestamp >= uint256(l.fundedAt) + l.term + GRACE) {
                try VAULT.finalizeDefault(id) {
                    l.state = V2State.DEFAULTED;
                } catch {}
            }
            _settleLoan(id, l);
            _accrueReward(id);
            if (!terminal[id] && !overdue[id] && l.state == V2State.REPAID) settlementPending = true;
            if (!terminal[id]) {
                if (write != i) _openLoans[write] = id;
                ++write;
            }
        }
        _reconcileRewards();
        assembly ("memory-safe") {
            sstore(_openLoans.slot, write)
        }
    }

    function _settleLoan(uint256 id, V2Loan memory l) internal {
        uint256 principal = positionPrincipal[id];
        uint256 payout;
        if (withdrawn[id] || l.state == V2State.CANCELLED) {
            payout = principal;
        } else if (l.state == V2State.REPAID) {
            payout = _sliceSum(l.cap, loanSlots[id]);
        } else if (l.state == V2State.DEFAULTED) {
            // Both LP assets and their pockets roll back together if either transfer cannot complete yet.
            try this.recoverLoanCollateral(id) {}
            catch {
                return;
            }
        } else {
            return;
        }
        if (payout != 0) {
            if (assignedCash + payout > harvestedCash) return;
            assignedCash += payout;
        }
        terminal[id] = true;
        borrowerPrincipal[l.originator] -= principal;
        lanePrincipal[loanLane[id]] -= principal;
        uint256 carried;
        if (overdue[id]) {
            overduePrincipal -= principal;
        } else {
            performingPrincipal -= principal;
            carried = principal;
        }
        if (payout != 0) {
            if (overdue[id]) {
                _openPocket(id, address(USDG), payout);
            } else {
                cash += payout;
                if (payout > carried) _reportProfit(id, payout - carried);
                else if (payout < carried) _reportLoss(id, carried - payout);
            }
        } else {
            if (carried != 0) _reportLoss(id, carried);
        }
        emit Settled(id, l.state, payout);
    }

    function _writeDown(uint256 id) internal {
        uint256 principal = positionPrincipal[id];
        overdue[id] = true;
        performingPrincipal -= principal;
        overduePrincipal += principal;
        _snapshotLoan(id);
        _reportLoss(id, principal);
        emit LoanOverdue(id, principal);
    }

    function _snapshotLoan(uint256 id) internal {
        uint64 snapshotId;
        unchecked {
            snapshotId = ++_snapshotCount;
        }
        _loanSnapshot[id] = snapshotId;
        _loanSnapshotSupply[id] = totalSupply;
    }

    function _isImpaired(V2Loan memory l) internal view returns (bool) {
        if (l.state == V2State.DEFAULTED) return true;
        uint256 maturity = uint256(l.fundedAt) + l.term;
        if (l.state == V2State.REPAID) return l.fundedAt != 0 && l.closedAt >= maturity;
        return l.state == V2State.ACTIVE && block.timestamp >= maturity;
    }

    function _pendingLoss() internal view returns (uint256 loss) {
        uint256 length = _openLoans.length;
        for (uint256 i; i < length; ++i) {
            uint256 id = _openLoans[i];
            if (terminal[id] || overdue[id]) continue;
            V2Loan memory l = _loan(id);
            if (_isImpaired(l)) loss += positionPrincipal[id];
        }
    }

    function _reconcileCash() internal {
        uint256 accounted =
            cash + feeAccrued + claimableTotal + _pocketLiability[address(USDG)] + harvestedCash - assignedCash;
        uint256 balance = _balanceOf(address(USDG), address(this));
        if (balance > accounted) {
            uint256 amount = balance - accounted;
            harvestedCash += amount;
            emit CashHarvested(amount);
        }
    }

    function _accrueReward(uint256 id) internal {
        uint256 due;
        try CORE_REWARDS.claimable(id, address(this)) returns (uint256 claimable_) {
            due = claimable_;
        } catch {
            return;
        }
        uint256 observed = _loanRewardObserved[id];
        if (due > observed) _distributeRewards(due - observed);
        _loanRewardObserved[id] = due;
        if (due == 0) return;
        uint256 before_ = _balanceOf(address(REWARD_TOKEN), address(this));
        try CORE_REWARDS.claim(id, address(this)) {
            uint256 amount = _balanceOf(address(REWARD_TOKEN), address(this)) - before_;
            try CORE_REWARDS.claimable(id, address(this)) returns (uint256 remaining) {
                _loanRewardObserved[id] = remaining;
            } catch {}
            if (amount != 0) emit RewardsHarvested(id, amount);
        } catch {}
    }

    function _reconcileRewards() internal {
        uint256 balance = _balanceOf(address(REWARD_TOKEN), address(this));
        uint256 pockets_ = _pocketLiability[address(REWARD_TOKEN)];
        uint256 available = balance > pockets_ ? balance - pockets_ : 0;
        uint256 reserved = _accountedRewards + _orphanRewards;
        if (available > reserved) _distributeRewards(available - reserved);
    }

    function _distributeRewards(uint256 amount) internal {
        uint256 supply = totalSupply;
        if (supply == 0) {
            _orphanRewards += amount;
            return;
        }
        // Per-epoch accumulator residue can be realized by a holder across later index increments, so it is not reusable.
        _accountedRewards += amount;
        accRewardPerShare += Math.mulDiv(amount, REWARD_PRECISION, supply);
    }

    /// @dev Profit above the vault's high-water mark pays the loan's snapshotted fee; the rest unlocks over the window.
    function _reportProfit(uint256 id, uint256 profit) internal {
        uint256 fee;
        uint256 supply = totalSupply;
        if (supply != 0) {
            uint256 full = fullAssets();
            uint256 price = Math.mulDiv(full, PRICE_PRECISION, supply);
            uint256 mark = highWaterPrice;
            if (price > mark) {
                uint16 rate = loanFeeBps[id];
                if (rate != 0) {
                    uint256 excess = Math.min(profit, Math.mulDiv(price - mark, supply, PRICE_PRECISION));
                    fee = Math.mulDiv(excess, rate, 10_000);
                    cash -= fee;
                    feeAccrued += fee;
                }
                highWaterPrice = Math.mulDiv(full - fee, PRICE_PRECISION, supply);
            }
        }
        uint256 locked = _lockedProfitNow() + profit - fee;
        lockedProfit = locked;
        unlockStart = uint64(block.timestamp);
        unlockEnd = uint64(block.timestamp + PROFIT_UNLOCK);
        emit ProfitReported(id, profit, fee, locked, unlockEnd);
    }

    /// @dev A loss consumes profit still unlocking before it reaches the share price.
    function _reportLoss(uint256 id, uint256 loss) internal {
        uint256 locked = _lockedProfitNow();
        uint256 absorbed = Math.min(locked, loss);
        lockedProfit = locked - absorbed;
        unlockStart = uint64(block.timestamp);
        if (unlockEnd < block.timestamp) unlockEnd = uint64(block.timestamp);
        emit LossReported(id, loss, absorbed);
    }

    /// @dev Record a recovery against the holder snapshot taken when this loan left priced assets.
    function _openPocket(uint256 id, address token, uint256 amount) internal {
        uint256 pocketId = ++pocketCount;
        uint256 supply = _loanSnapshotSupply[id];
        pockets[pocketId] = Pocket(id, token, amount, supply, 0);
        _pocketSnapshot[pocketId] = _loanSnapshot[id];
        _pocketLiability[token] += amount;
        emit PocketCreated(pocketId, id, token, amount, supply);
    }

    /// @dev Take USDG from cash, then redeem the reserve for the shortfall; the burned reserve shares are returned.
    function _payOut(uint256 assets) internal returns (uint256 burned) {
        uint256 c = cash;
        if (assets <= c) {
            cash = c - assets;
            return 0;
        }
        uint256 need = assets - c;
        if (need > _reserveRead(0x07a2d13a, reserveShares)) revert InsufficientLiquidity();
        uint256 beforeCash = _balanceOf(address(USDG), address(this));
        uint256 beforeShares = _balanceOf(address(RESERVE), address(this));
        uint256 reported = RESERVE.withdraw(need, address(this), address(this));
        burned = beforeShares - _balanceOf(address(RESERVE), address(this));
        if (burned == 0 || burned != reported || _balanceOf(address(USDG), address(this)) - beforeCash != need) {
            revert TransferAmountMismatch();
        }
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
        if (shares == totalSupply) {
            uint256 remainder = _accountedRewards - _rewardLiability;
            _accountedRewards -= remainder;
            _orphanRewards += remainder;
        }
        balanceOf[from] -= shares;
        totalSupply -= shares;
    }

    /// @dev Preserve the balance of record for open pockets and settle rewards before a balance moves.
    function _beforeBalanceChange(address who) internal {
        uint256 current = _snapshotCount;
        if (current != 0) {
            Snapshot[] storage s = _snapshots[who];
            if (s.length == 0 || s[s.length - 1].id < current) {
                s.push(Snapshot(uint64(current), balanceOf[who]));
            }
        }
        _settleRewards(who);
    }

    function _settleRewards(address who) internal {
        uint256 index = accRewardPerShare;
        uint256 amount = Math.mulDiv(balanceOf[who], index - _rewardIndex[who], REWARD_PRECISION);
        _rewardOwed[who] += amount;
        _rewardLiability += amount;
        _rewardIndex[who] = index;
    }

    /// @dev The first `units` empty lender slots, exactly as the core fills them, and their combined price.
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
        if (remaining != 0) revert IneligibleDeal(id);
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
        if (
            funded[id] || l.state != V2State.FUNDING || units == 0 || units > UNITS - l.filled || principal == 0
                || l.term > _params.maxLoanTerm || l.originator == address(this) || l.originator == CURATOR
                || block.timestamp >= l.fundingDeadline
                || l.cap
                    < uint256(l.principal) + Math.mulDiv(l.principal, _params.minReturnBps, 10_000, Math.Rounding.Ceil)
        ) {
            revert IneligibleDeal(id);
        }
        if (l.kind == Kind.ERC20) {
            bool allowed;
            (allowed, lane) = _tokenPolicy(l.token);
            if (
                !allowed || tokenCeiling[l.token] == 0
                    || l.principal > Math.mulDiv(l.collateral, tokenCeiling[l.token], tokenUnit[l.token])
            ) {
                revert IneligibleDeal(id);
            }
        } else {
            // NFT ids are never token quantities. The curator underwrites the principal; the core's immutable
            // validator rechecks the actual position, exact pool, current registry rules, range and liquidity.
            if (!_validLP(l)) revert IneligibleDeal(id);
            lane = EarnLane.LP;
        }
        uint256 assets = fullAssets();
        if (
            lanePrincipal[lane] + principal > Math.mulDiv(laneWeightBps[lane], assets, 10_000)
                || performingPrincipal + overduePrincipal + principal
                    > Math.mulDiv(_params.maxGageExposureBps, assets, 10_000)
        ) {
            revert IneligibleDeal(id);
        }
    }

    /// @dev The immutable registry returns five words; only token admission and its registry lane apply here.
    /// Registry STOCK=0 and ETH=1 share Earn STOCK=0; registry MEME=2 maps to Earn MEME=1.
    function _tokenPolicy(address token) internal view returns (bool allowed, EarnLane lane) {
        address registry = address(REGISTRY);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xab2ea17c)) // getERC20Config(address)
            mstore(add(ptr, 4), and(token, 0xffffffffffffffffffffffffffffffffffffffff))
            let ok := staticcall(gas(), registry, ptr, 36, ptr, 64)
            let registryLane := mload(add(ptr, 32))
            allowed := and(and(ok, eq(returndatasize(), 160)), and(eq(mload(ptr), 1), lt(registryLane, 3)))
            lane := eq(registryLane, 2)
        }
    }

    /// @dev Fixed-width validator result: key and raw amount must still match the immutable core loan record.
    function _validLP(V2Loan memory l) internal view returns (bool valid) {
        address validator = COLLATERAL_VALIDATOR;
        address core = address(VAULT);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // validate((uint8,address,uint256),address)
            mstore(ptr, shl(224, 0x942e54c9))
            mstore(add(ptr, 4), mload(add(l, 0x80)))
            mstore(add(ptr, 36), mload(add(l, 0x40)))
            mstore(add(ptr, 68), mload(add(l, 0x200)))
            mstore(add(ptr, 100), mload(add(l, 0x20)))
            let ok := staticcall(gas(), validator, ptr, 132, ptr, 96)
            valid := and(ok, eq(returndatasize(), 96))
            valid := and(valid, eq(mload(ptr), mload(add(l, 0x220))))
            valid := and(valid, eq(mload(add(ptr, 32)), mload(add(l, 0x240))))
            if valid {
                let maximum := mload(add(ptr, 64))
                let key := mload(ptr)
                // openExposure(bytes32)
                mstore(ptr, shl(224, 0x34b61fa5))
                mstore(add(ptr, 4), key)
                ok := staticcall(gas(), core, ptr, 36, ptr, 32)
                valid := and(and(ok, eq(returndatasize(), 32)), iszero(gt(mload(ptr), maximum)))
            }
        }
    }

    /// @notice Internal atomic recovery boundary; only this strategy may call it during guarded settlement.
    /// @dev A paused underlying leaves the entire recovery retryable while other loans in the batch can settle.
    /// LP recovery removes liquidity in kind without a swap; no relative price or NFT id is used as an output floor.
    function recoverLoanCollateral(uint256 id) external {
        if (msg.sender != address(this)) revert NotOwner();
        V2Loan memory l = _loan(id);
        GageV2CollateralAccount custody = GageV2CollateralAccount(payable(l.account));
        if (_scalarRead(address(custody), 0x0e78df61, 0) == 0) {
            address core = address(VAULT);
            uint256 minimum = l.kind == Kind.ERC20 ? l.collateral : 0;
            // The core records both outputs in custody. Read those records below instead of decoding unused arrays.
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, shl(224, 0xd388bfe6)) // recoverDefault(uint256,uint256,uint256,uint256)
                mstore(add(ptr, 4), id)
                mstore(add(ptr, 36), minimum)
                mstore(add(ptr, 68), 0)
                mstore(add(ptr, 100), timestamp())
                if iszero(call(gas(), core, 0, ptr, 132, 0, 0)) { revert(0, 0) }
            }
        }
        for (uint8 assetIndex; assetIndex < 2; ++assetIndex) {
            uint256 amount = VAULT.claimableRecovery(id, assetIndex, address(this));
            if (amount != 0) {
                address token = address(uint160(_scalarRead(address(custody), 0x5cda4d97, assetIndex)));
                uint256 before_ = token == address(0) ? address(this).balance : _balanceOf(token, address(this));
                VAULT.withdrawRecovery(id, assetIndex, address(this));
                uint256 after_ = token == address(0) ? address(this).balance : _balanceOf(token, address(this));
                if (after_ - before_ != amount) revert TransferAmountMismatch();
                _openPocket(id, token, amount);
                emit CollateralRecovered(id, token, amount);
            }
        }
    }

    /// @dev Copy the core's 19-word loan record straight into memory; the immutable core encodes it verbatim.
    function _loan(uint256 id) internal view returns (V2Loan memory l) {
        address target = address(VAULT);
        assembly ("memory-safe") {
            mstore(0, shl(224, 0x504006ca))
            mstore(4, id)
            let ok := staticcall(gas(), target, 0, 36, 0, 0)
            if iszero(ok) {
                let ptr := mload(64)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if iszero(eq(returndatasize(), 608)) {
                mstore(0, 0xb0a6ea29)
                revert(28, 4)
            }
            returndatacopy(l, 0, 608)
        }
    }

    /// @notice Internal-call boundary that shares reserve deposit bytecode; only this strategy may call.
    function depositReserve(uint256 assets, uint256 minShares) external returns (uint256 shares) {
        if (msg.sender != address(this)) revert NotOwner();
        uint256 beforeCash = _balanceOf(address(USDG), address(this));
        uint256 beforeShares = _balanceOf(address(RESERVE), address(this));
        USDG.forceApprove(address(RESERVE), assets);
        uint256 reported = RESERVE.deposit(assets, address(this));
        USDG.forceApprove(address(RESERVE), 0);
        shares = _balanceOf(address(RESERVE), address(this)) - beforeShares;
        if (beforeCash - _balanceOf(address(USDG), address(this)) != assets || reported != shares) {
            revert TransferAmountMismatch();
        }
        if (shares == 0 || shares < minShares) revert Slippage();
    }

    function _redeem(uint256 shares, uint256 minAssets) internal returns (uint256 assets) {
        uint256 beforeCash = _balanceOf(address(USDG), address(this));
        uint256 beforeShares = _balanceOf(address(RESERVE), address(this));
        uint256 reported = RESERVE.redeem(shares, address(this), address(this));
        assets = _balanceOf(address(USDG), address(this)) - beforeCash;
        if (beforeShares - _balanceOf(address(RESERVE), address(this)) != shares || reported != assets) {
            revert TransferAmountMismatch();
        }
        if (assets < minAssets) revert Slippage();
    }

    function _transferExact(IERC20 token, address who, uint256 amount) internal {
        uint256 before_ = _balanceOf(address(token), address(this));
        uint256 recipientBefore = _balanceOf(address(token), who);
        token.safeTransfer(who, amount);
        if (
            before_ - _balanceOf(address(token), address(this)) != amount
                || _balanceOf(address(token), who) - recipientBefore != amount
        ) {
            revert TransferAmountMismatch();
        }
    }

    /// @dev This immutable contract uses no other transient state or delegate calls.
    function _reentrancyGuardStorageSlot() internal pure override returns (bytes32) {
        return bytes32(uint256(1));
    }

    function _balanceOf(address token, address who) internal view returns (uint256 value) {
        return _scalarRead(token, 0x70a08231, uint160(who));
    }

    /// @dev Checked scalar ERC-4626 reads share one compact staticcall path.
    function _reserveRead(uint256 selector, uint256 argument) internal view returns (uint256 value) {
        return _scalarRead(address(RESERVE), selector, argument);
    }

    function _scalarRead(address target, uint256 selector, uint256 argument) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            mstore(0, shl(224, selector))
            mstore(4, argument)
            let ok := staticcall(gas(), target, 0, 36, 0, 32)
            if iszero(ok) {
                let ptr := mload(64)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 32) {
                mstore(0, 0xb0a6ea29)
                revert(28, 4)
            }
            value := mload(0)
        }
    }

    function _checkBatch(uint256 length) internal pure {
        if (length == 0 || length > MAX_BATCH) revert InvalidAmount();
    }

    /// @notice Receive native currency recovered from LP collateral; it belongs only to its side pocket.
    receive() external payable {}
}
