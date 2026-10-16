// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FeeSink} from "../FeeSink.sol";
import {FeeFloor} from "./FeeFloor.sol";
import {PonsV4Swapper} from "./base/PonsV4Swapper.sol";

/// @notice Accumulates the entire 1% deal fee, buys GAGE in bounded clips and deposits it into the floor.
/// @dev No sGAGE swap, burn, caller bounty or operations deduction occurs in this route.
contract DealFeeRouter is PonsV4Swapper, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_THRESHOLD = 10e6;
    uint256 public constant MAX_THRESHOLD = 10_000e6;
    uint16 public constant MAX_IMPACT_BPS = 100;
    IERC20 public immutable USDG;
    IERC20 public immutable GAGE;
    FeeSink public immutable FEE_SINK;
    FeeFloor public immutable FLOOR;
    uint24 public immutable LAUNCH_POOL_FEE_PIPS;
    PoolKey internal _usdgEth;
    PoolKey internal _gageEth;
    uint256 public threshold;
    uint256 public batchRemaining;
    uint256 public totalUSDGProcessed;
    uint256 public totalGAGEAdded;

    struct Params {
        IPoolManager poolManager;
        IERC20 usdg;
        IERC20 gage;
        FeeSink feeSink;
        FeeFloor floor;
        PoolKey usdgEth;
        PoolKey gageEth;
        uint24 launchPoolFeePips;
        uint256 threshold;
        address initialOwner;
    }

    event ThresholdSet(uint256 threshold);
    event BatchOpened(uint256 amountUSDG);
    event FloorFunded(address indexed caller, uint256 usdgIn, uint256 ethOut, uint256 gageBought, uint256 gageAdded);

    error ZeroAddress();
    error PoolMismatch();
    error ThresholdOutOfBounds();
    error BelowThreshold(uint256 balance, uint256 threshold);
    error ClipTooLarge(uint256 requested, uint256 available);
    error RouteNotReady();

    constructor(Params memory p, address curve_)
        PonsV4Swapper(p.poolManager, curve_, p.gageEth, p.launchPoolFeePips)
        Ownable(p.initialOwner)
    {
        if (
            address(p.usdg) == address(0) || address(p.gage) == address(0) || address(p.feeSink) == address(0)
                || address(p.floor) == address(0)
        ) revert ZeroAddress();
        if (
            !p.usdgEth.currency0.isAddressZero() || Currency.unwrap(p.usdgEth.currency1) != address(p.usdg)
                || !p.gageEth.currency0.isAddressZero() || Currency.unwrap(p.gageEth.currency1) != address(p.gage)
                || address(p.usdgEth.hooks) != address(0) || address(p.feeSink.USDG()) != address(p.usdg)
                || p.floor.GAGE() != address(p.gage)
        ) revert PoolMismatch();
        if (p.threshold < MIN_THRESHOLD || p.threshold > MAX_THRESHOLD) revert ThresholdOutOfBounds();
        USDG = p.usdg;
        GAGE = p.gage;
        FEE_SINK = p.feeSink;
        FLOOR = p.floor;
        _usdgEth = p.usdgEth;
        _gageEth = p.gageEth;
        LAUNCH_POOL_FEE_PIPS = p.launchPoolFeePips;
        threshold = p.threshold;
        emit ThresholdSet(p.threshold);
    }

    /// @notice Fees available across vault credit, FeeSink and this processor, in raw USDG.
    function availableUSDG() public view returns (uint256) {
        return USDG.balanceOf(address(this)) + USDG.balanceOf(address(FEE_SINK))
            + FEE_SINK.vault().balanceUSDG(address(FEE_SINK));
    }

    /// @notice Pull upstream fees and execute one price-bounded clip. Unspent funds remain for later execution.
    function process(uint256 clipUSDG) external nonReentrant returns (uint256 added) {
        if (FEE_SINK.route() != FeeSink.Route.BUYBACK || FEE_SINK.buyback() != address(this)) revert RouteNotReady();
        uint256 available = availableUSDG();
        if (available >= threshold) {
            batchRemaining = available;
            emit BatchOpened(available);
        }
        if (batchRemaining == 0) revert BelowThreshold(available, threshold);
        uint256 limit = batchRemaining < available ? batchRemaining : available;
        if (clipUSDG == 0 || clipUSDG > limit) revert ClipTooLarge(clipUSDG, limit);
        batchRemaining -= clipUSDG;
        FEE_SINK.collect();
        if (USDG.balanceOf(address(FEE_SINK)) != 0) FEE_SINK.sweep();
        uint256 ethOut =
            _swapExactIn(_usdgEth, false, clipUSDG, _quoteAtSpot(_usdgEth, false, clipUSDG, MAX_IMPACT_BPS, 0));
        uint256 gageOut = _swapExactIn(
            _gageEth, true, ethOut, _quoteAtSpot(_gageEth, true, ethOut, MAX_IMPACT_BPS, LAUNCH_POOL_FEE_PIPS)
        );
        uint256 gage = GAGE.balanceOf(address(this));
        GAGE.forceApprove(address(FLOOR), gage);
        added = FLOOR.depositGAGE(gage);
        GAGE.forceApprove(address(FLOOR), 0);
        totalUSDGProcessed += clipUSDG;
        totalGAGEAdded += added;
        emit FloorFunded(msg.sender, clipUSDG, ethOut, gageOut, added);
    }

    /// @notice Set the batching trigger within the fixed 10–10,000 USDG bounds.
    function setThreshold(uint256 value) external onlyOwner {
        if (value < MIN_THRESHOLD || value > MAX_THRESHOLD) revert ThresholdOutOfBounds();
        threshold = value;
        emit ThresholdSet(value);
    }

    function pools() external view returns (PoolKey memory usdgEth, PoolKey memory gageEth) {
        return (_usdgEth, _gageEth);
    }
}
