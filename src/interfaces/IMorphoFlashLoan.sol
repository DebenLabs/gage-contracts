// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Morpho Blue's flash loan: free, any amount of a token the singleton holds. It transfers `assets` to the
///         caller, calls `onMorphoFlashLoan` on it, then pulls `assets` back with `transferFrom`.
interface IMorphoFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/// @notice The callback a Morpho Blue flash borrower implements; it must approve the repayment before it returns.
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
