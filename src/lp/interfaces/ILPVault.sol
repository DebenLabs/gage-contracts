// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The lender side of the LP lane, as its core sees it.
interface ILPVault {
    /// @notice Books loan `loanId` and sends exactly `principal` USDG to the core.
    function fund(uint256 loanId, uint128 principal, uint128 repayment, uint40 end) external;

    /// @notice Closes `loanId` after the core moved `amount` USDG (its repayment) into the vault.
    function onRepaid(uint256 loanId, uint256 amount) external;

    /// @notice Rolls `loanId` into `newLoanId` within this vault: books the old loan repaid in full and the new one
    /// funded in full, but only the difference moves. The core first sends what the old repayment exceeds the new
    /// principal by; the vault sends the core what the new principal exceeds the old repayment by.
    function refinance(uint256 loanId, uint256 newLoanId, uint128 principal, uint128 repayment, uint40 end) external;

    /// @notice Closes defaulted `loanId` after the core moved every token the position delivered into the vault (the
    /// unwound liquidity, its fees and its rewards), each with the amount the vault received.
    function onDefault(uint256 loanId, address[] calldata tokens, uint256[] calldata amounts) external;

    /// @notice Closes `loanId` at a full loss: its position could not be unwound for weeks and stays in escrow.
    function onAbandoned(uint256 loanId) external;

    /// @notice Books what abandoned `loanId`'s position delivered when it was recovered later.
    function onRecovered(uint256 loanId, address[] calldata tokens, uint256[] calldata amounts) external;
}
