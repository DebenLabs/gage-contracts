// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IEmissions} from "../interfaces/token/IEmissions.sol";
import {IsGAGE} from "../interfaces/token/IsGAGE.sol";
import {ILPRewards} from "../interfaces/token/ILPRewards.sol";

/// @title Emissions
/// @notice Holds the 4.0B sGAGE reserve. 52 weekly epochs from launch, each 10% smaller than the last, summing to
///         the whole reserve; the prefix sums are the on-chain ceiling on cumulative emission (T2). Each week splits
///         deals : liquidity (60:40) and the deal budget splits 21-day : 7-day (70:30), adjustable per epoch by the
///         Safe within bounds. Unreserved deal budget rolls over to liquidity after the epoch; week 52 burns the rest.
contract Emissions is IEmissions, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant WEEKS = 52;
    uint256 public constant EPOCH = 7 days;
    uint256 public constant RESERVE = 4_000_000_000e18;
    /// @dev E1 = RESERVE * 0.10 / (1 - 0.9^52). Week n is E1 * 0.9^n; week 51 absorbs the rounding so the table
    ///      sums to RESERVE exactly, and the constructor asserts it.
    uint256 public constant WEEK_ONE = 401_676_823_162_582_040_807_155_502;
    /// @notice Late registrations get this long after an epoch ends before its unreserved budget rolls over.
    uint256 public constant REGISTRATION_GRACE = 6 hours;
    uint16 public constant DEFAULT_DEAL_SHARE_BPS = 6000;
    uint16 public constant DEFAULT_TERM21_SHARE_BPS = 7000;
    uint16 public constant MIN_DEAL_SHARE_BPS = 2000;
    uint16 public constant MAX_DEAL_SHARE_BPS = 8000;
    uint16 public constant MIN_TERM21_SHARE_BPS = 5000;
    uint16 public constant MAX_TERM21_SHARE_BPS = 9000;
    uint32 public constant TERM7 = 7 days;
    uint32 public constant TERM21 = 21 days;

    struct Shares {
        uint16 dealShareBps;
        uint16 term21ShareBps;
        bool set;
    }

    address public immutable DEPLOYER;
    IsGAGE public sgage;
    ILPRewards public lpRewards;
    address public dealRewards;

    uint40 public launchAt;
    uint256 public totalOut;
    uint256[52] internal _weekly;
    uint256[52] internal _prefix;
    mapping(uint256 epoch => Shares) internal _shares;
    mapping(uint256 epoch => bool) public released;
    mapping(uint256 epoch => bool) public rolledOver;
    mapping(uint256 epoch => mapping(uint32 term => uint256)) internal _reserved;

    error NotDeployer();
    error AlreadyWired();
    error NotWired();
    error TableMismatch(uint256 sum);

    /// @param admin The account allowed to call `wire` once (explicit: CREATE2 factories are `msg.sender`).
    constructor(address initialOwner, address admin) Ownable(initialOwner) {
        if (admin == address(0)) revert ZeroAddress();
        DEPLOYER = admin;
        uint256 sum;
        for (uint256 i = 0; i < WEEKS - 1; ++i) {
            uint256 w = (WEEK_ONE * (9 ** i)) / (10 ** i);
            _weekly[i] = w;
            sum += w;
            _prefix[i] = sum;
        }
        uint256 last = RESERVE - sum;
        // The rounding remainder must land within 1% of the decay, or the table is wrong.
        uint256 expectedLast = (_weekly[WEEKS - 2] * 9) / 10;
        if (last > (expectedLast * 101) / 100 || last < (expectedLast * 99) / 100) revert TableMismatch(sum + last);
        _weekly[WEEKS - 1] = last;
        _prefix[WEEKS - 1] = RESERVE;
    }

    /// @notice Deployer, once: the token and the two recipients. The reserve must already sit here.
    function wire(IsGAGE sgage_, ILPRewards lpRewards_, address dealRewards_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (address(sgage) != address(0)) revert AlreadyWired();
        if (address(sgage_) == address(0) || address(lpRewards_) == address(0) || dealRewards_ == address(0)) {
            revert ZeroAddress();
        }
        sgage = sgage_;
        lpRewards = lpRewards_;
        dealRewards = dealRewards_;
    }

    // ----------------------------------------------------------------- owner

    /// @inheritdoc IEmissions
    /// @dev `at` may sit up to one epoch in the past, so a launch transaction that lands after the block it was
    ///      prepared for still succeeds and epoch 0 simply starts a little earlier.
    function launch(uint40 at) external onlyOwner {
        if (address(sgage) == address(0)) revert NotWired();
        if (launchAt != 0) revert AlreadyLaunched();
        if (at + EPOCH < block.timestamp) revert LaunchInPast();
        launchAt = at;
        emit Launched(at);
    }

    /// @inheritdoc IEmissions
    function setShares(uint256 epoch, uint16 dealShareBps_, uint16 term21ShareBps_) external onlyOwner {
        if (epoch >= WEEKS) revert EpochOutOfRange(epoch);
        if (
            dealShareBps_ < MIN_DEAL_SHARE_BPS || dealShareBps_ > MAX_DEAL_SHARE_BPS
                || term21ShareBps_ < MIN_TERM21_SHARE_BPS || term21ShareBps_ > MAX_TERM21_SHARE_BPS
        ) revert SharesOutOfBounds();
        if (launchAt != 0 && block.timestamp >= epochStart(epoch)) revert EpochAlreadyStarted(epoch);
        _shares[epoch] = Shares({dealShareBps: dealShareBps_, term21ShareBps: term21ShareBps_, set: true});
        emit SharesSet(epoch, dealShareBps_, term21ShareBps_);
    }

    // ----------------------------------------------------------------- permissionless

    /// @inheritdoc IEmissions
    function release(uint256 epoch) public {
        _requireLaunched();
        if (epoch >= WEEKS) revert EpochOutOfRange(epoch);
        if (block.timestamp < epochStart(epoch)) revert EpochNotStarted(epoch);
        if (released[epoch]) revert EpochAlreadyReleased(epoch);
        released[epoch] = true;

        uint256 liquidity = liquidityBudget(epoch);
        totalOut += liquidity;
        _checkCeiling();
        IERC20(address(sgage)).safeTransfer(address(lpRewards), liquidity);
        lpRewards.notifyEmissions(epoch, liquidity);
        emit Released(epoch, liquidity, dealBudget(epoch, TERM7), dealBudget(epoch, TERM21));
    }

    /// @inheritdoc IEmissions
    function reserve(uint256 epoch, uint32 term, uint256 amount, address to) external {
        if (msg.sender != dealRewards) revert NotDealRewards();
        if (!released[epoch]) revert EpochNotReleased(epoch);
        if (rolledOver[epoch]) revert EpochAlreadyRolledOver(epoch);
        uint32 bucket = _bucket(term);
        uint256 left = remaining(epoch, bucket);
        if (amount > left) revert BudgetExceeded(epoch, bucket, left, amount);
        _reserved[epoch][bucket] += amount;
        totalOut += amount;
        _checkCeiling();
        IERC20(address(sgage)).safeTransfer(to, amount);
        emit Reserved(epoch, bucket, amount, to);
    }

    /// @inheritdoc IEmissions
    function rollover(uint256 epoch) external {
        if (!released[epoch]) revert EpochNotReleased(epoch);
        if (rolledOver[epoch]) revert EpochAlreadyRolledOver(epoch);
        if (block.timestamp < epochStart(epoch + 1) + REGISTRATION_GRACE) revert EpochNotEnded(epoch);
        rolledOver[epoch] = true;

        uint256 amount = remaining(epoch, TERM7) + remaining(epoch, TERM21);
        _reserved[epoch][TERM7] = dealBudget(epoch, TERM7);
        _reserved[epoch][TERM21] = dealBudget(epoch, TERM21);
        if (amount > 0) {
            totalOut += amount;
            _checkCeiling();
            IERC20(address(sgage)).forceApprove(address(lpRewards), amount);
            lpRewards.notifyLump(amount);
        }
        emit RolledOver(epoch, amount);
    }

    /// @inheritdoc IEmissions
    function finalize() external {
        if (!scheduleOver() || block.timestamp < epochStart(WEEKS) + REGISTRATION_GRACE) revert ScheduleNotOver();
        for (uint256 e = 0; e < WEEKS; ++e) {
            if (!released[e]) revert EpochNotReleased(e);
            if (!rolledOver[e]) revert EpochNotEnded(e);
        }
        uint256 left = sgage.balanceOf(address(this));
        if (left > 0) sgage.burn(left);
        emit Finalized(left);
    }

    // ----------------------------------------------------------------- views

    function weekly(uint256 epoch) public view returns (uint256) {
        if (epoch >= WEEKS) revert EpochOutOfRange(epoch);
        return _weekly[epoch];
    }

    function prefixSum(uint256 epoch) public view returns (uint256) {
        if (epoch >= WEEKS) return RESERVE;
        return _prefix[epoch];
    }

    function currentEpoch() public view returns (uint256) {
        _requireLaunched();
        if (block.timestamp < launchAt) return 0;
        return epochOf(uint40(block.timestamp));
    }

    function epochOf(uint40 timestamp) public view returns (uint256) {
        _requireLaunched();
        if (timestamp < launchAt) return 0;
        uint256 e = (timestamp - launchAt) / EPOCH;
        return e > WEEKS ? WEEKS : e;
    }

    function epochStart(uint256 epoch) public view returns (uint40) {
        _requireLaunched();
        return uint40(launchAt + epoch * EPOCH);
    }

    function scheduleOver() public view returns (bool) {
        return launchAt != 0 && block.timestamp >= launchAt + WEEKS * EPOCH;
    }

    function dealShareBps(uint256 epoch) public view returns (uint16) {
        Shares storage s = _shares[epoch];
        return s.set ? s.dealShareBps : DEFAULT_DEAL_SHARE_BPS;
    }

    function term21ShareBps(uint256 epoch) public view returns (uint16) {
        Shares storage s = _shares[epoch];
        return s.set ? s.term21ShareBps : DEFAULT_TERM21_SHARE_BPS;
    }

    function liquidityBudget(uint256 epoch) public view returns (uint256) {
        return weekly(epoch) - _dealsTotal(epoch);
    }

    function dealBudget(uint256 epoch, uint32 term) public view returns (uint256) {
        uint256 deals = _dealsTotal(epoch);
        uint256 deals21 = (deals * term21ShareBps(epoch)) / 10_000;
        return _bucket(term) == TERM21 ? deals21 : deals - deals21;
    }

    function reserved(uint256 epoch, uint32 term) external view returns (uint256) {
        return _reserved[epoch][_bucket(term)];
    }

    function remaining(uint256 epoch, uint32 term) public view returns (uint256) {
        uint32 bucket = _bucket(term);
        return dealBudget(epoch, bucket) - _reserved[epoch][bucket];
    }

    // ----------------------------------------------------------------- internal

    function _dealsTotal(uint256 epoch) internal view returns (uint256) {
        return (weekly(epoch) * dealShareBps(epoch)) / 10_000;
    }

    /// @dev Two budgets: 21 days and longer draw on the 21-day budget, everything shorter on the 7-day budget.
    function _bucket(uint32 term) internal pure returns (uint32) {
        return term >= TERM21 ? TERM21 : TERM7;
    }

    function _requireLaunched() internal view {
        if (launchAt == 0) revert NotLaunched();
    }

    /// @dev T2: cumulative transfers out never exceed the table's prefix sum for the current epoch.
    function _checkCeiling() internal view {
        uint256 e = currentEpoch();
        uint256 ceiling = prefixSum(e >= WEEKS ? WEEKS - 1 : e);
        assert(totalOut <= ceiling);
    }
}
