// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title PositionMath
/// @notice Token amounts a position holds at the current price, from v4-core's audited SqrtPriceMath.
library PositionMath {
    /// @dev Same maths as Uniswap's LiquidityAmounts.getAmountsForLiquidity, rounding down.
    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtLowerX96 > sqrtUpperX96) (sqrtLowerX96, sqrtUpperX96) = (sqrtUpperX96, sqrtLowerX96);
        if (sqrtPriceX96 <= sqrtLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
        }
    }
}
