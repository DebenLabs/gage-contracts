// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {LPAdapterBase} from "./LPAdapterBase.sol";
import {IPositionManagerParams, IUniV3Factory, IUniV3PositionManager} from "../interfaces/IConcentratedLiquidity.sol";
import {PositionFacts} from "../LPTypes.sol";

/// @title UniV3PositionAdapter
/// @notice Uniswap v3 positions, and forks that keep its position manager (12-field `positions`, pools by fee): one
/// adapter per position manager. Stateless; only its core may call it, and it acts as the operator the loan's escrow
/// approved for that one position.
contract UniV3PositionAdapter is LPAdapterBase {
    IUniV3PositionManager public immutable NFPM;
    IUniV3Factory public immutable FACTORY;

    constructor(IUniV3PositionManager nfpm, IUniV3Factory factory, address core_) LPAdapterBase(core_) {
        if (address(nfpm) == address(0) || address(factory) == address(0)) revert ZeroAddress();
        NFPM = nfpm;
        FACTORY = factory;
    }

    /// @inheritdoc ILPAdapter
    function positionManager() external view returns (address) {
        return address(NFPM);
    }

    /// @inheritdoc ILPAdapter
    function facts(uint256 tokenId) external view returns (PositionFacts memory f) {
        (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            NFPM.positions(tokenId);
        f = PositionFacts({
            pool: FACTORY.getPool(token0, token1, fee),
            token0: token0,
            token1: token1,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
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
    function unwind(uint256 tokenId, address recipient, uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        (,,,,,,, uint128 liquidity,,,,) = NFPM.positions(tokenId);
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
