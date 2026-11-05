// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Sells a token a vault recovered for USDG along one reviewed route.
interface ILPSwapExecutor {
    /// @notice Swaps `amountIn` of `tokenIn`, already sent to the executor, for USDG paid to `recipient`.
    function swap(address tokenIn, uint256 amountIn, address recipient) external returns (uint256 amountOut);
}
