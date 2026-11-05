// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {LPAdapterBase} from "./LPAdapterBase.sol";
import {
    IPositionManagerParams,
    IRamsesV3Factory,
    IRamsesV3PositionManager
} from "../interfaces/IConcentratedLiquidity.sol";
import {PositionFacts} from "../LPTypes.sol";

/// @title RamsesV3PositionAdapter
/// @notice Ramses V3 positions: a 10-field `positions`, pools keyed by tick spacing, and gauge rewards the position
/// manager pays to the position's owner (on a claim, and on any liquidity change). Stateless; only its core may call
/// it, and it acts as the operator the loan's escrow approved for that one position.
/// @dev The reward list must name every token the gauges or the manager's own auto-claim can pay (on chain 4663 the
/// WETH/USDG gauge pays WETH, USDG and RAM): the core sweeps exactly these from a loan's escrow.
contract RamsesV3PositionAdapter is LPAdapterBase {
    /// @notice Most reward tokens one adapter claims.
    uint256 public constant MAX_REWARD_TOKENS = 4;
    /// @notice How long after a position's last liquidity change a claim waits. Ramses' reward validator forfeits a
    /// claim made within about 100 seconds of one, and with it every earlier unpaid period (seen on chain 4663, 21
    /// October 2026: forfeited at 11 to 79 seconds, paid from 108 seconds); a claim inside the window is skipped, and
    /// the rewards keep accruing for a later one.
    uint256 public constant CLAIM_DELAY = 3 minutes;

    IRamsesV3PositionManager public immutable NFPM;
    IRamsesV3Factory public immutable FACTORY;
    uint256 internal immutable REWARD_COUNT;
    address internal immutable REWARD_0;
    address internal immutable REWARD_1;
    address internal immutable REWARD_2;
    address internal immutable REWARD_3;

    error TooManyRewardTokens();
    error DuplicateRewardToken(address token);

    constructor(IRamsesV3PositionManager nfpm, IRamsesV3Factory factory, address core_, address[] memory rewards)
        LPAdapterBase(core_)
    {
        if (address(nfpm) == address(0) || address(factory) == address(0)) revert ZeroAddress();
        if (rewards.length > MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        for (uint256 i; i < rewards.length; ++i) {
            if (rewards[i] == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (rewards[j] == rewards[i]) revert DuplicateRewardToken(rewards[i]);
            }
        }
        NFPM = nfpm;
        FACTORY = factory;
        REWARD_COUNT = rewards.length;
        REWARD_0 = rewards.length > 0 ? rewards[0] : address(0);
        REWARD_1 = rewards.length > 1 ? rewards[1] : address(0);
        REWARD_2 = rewards.length > 2 ? rewards[2] : address(0);
        REWARD_3 = rewards.length > 3 ? rewards[3] : address(0);
    }

    /// @inheritdoc ILPAdapter
    function positionManager() external view returns (address) {
        return address(NFPM);
    }

    /// @inheritdoc ILPAdapter
    function facts(uint256 tokenId) external view returns (PositionFacts memory f) {
        (address token0, address token1, int24 tickSpacing, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            NFPM.positions(tokenId);
        f = PositionFacts({
            pool: FACTORY.getPool(token0, token1, tickSpacing),
            token0: token0,
            token1: token1,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
    }

    /// @inheritdoc ILPAdapter
    function rewardTokens() public view override returns (address[] memory tokens) {
        tokens = new address[](REWARD_COUNT);
        if (REWARD_COUNT > 0) tokens[0] = REWARD_0;
        if (REWARD_COUNT > 1) tokens[1] = REWARD_1;
        if (REWARD_COUNT > 2) tokens[2] = REWARD_2;
        if (REWARD_COUNT > 3) tokens[3] = REWARD_3;
    }

    /// @inheritdoc ILPAdapter
    function collectFees(uint256 tokenId, address recipient)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = NFPM.collect(
            IPositionManagerParams.CollectParams({
                tokenId: tokenId, recipient: recipient, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }

    /// @inheritdoc ILPAdapter
    function claimRewards(uint256 tokenId) external override onlyCore {
        if (REWARD_COUNT == 0) return;
        if (block.timestamp < NFPM.positionLastModified(tokenId) + CLAIM_DELAY) return;
        NFPM.getReward(tokenId, rewardTokens());
    }

    /// @inheritdoc ILPAdapter
    function unwind(uint256 tokenId, address recipient, uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        (,,,,, uint128 liquidity,,,,) = NFPM.positions(tokenId);
        if (liquidity != 0) {
            NFPM.decreaseLiquidity(
                IPositionManagerParams.DecreaseLiquidityParams({
                    tokenId: tokenId, liquidity: liquidity, amount0Min: min0, amount1Min: min1, deadline: deadline
                })
            );
        }
        (amount0, amount1) = NFPM.collect(
            IPositionManagerParams.CollectParams({
                tokenId: tokenId, recipient: recipient, amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }
}
