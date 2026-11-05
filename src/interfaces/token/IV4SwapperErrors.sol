// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Errors raised by the token layer's swap legs. Shared so every contract that swaps, and every interface
///         an integrator decodes against, declares them exactly once.
interface IV4SwapperErrors {
    error TooLittleOut(uint256 got, uint256 minOut);
    error TooMuchIn(uint256 paid, uint256 maxIn);
}
