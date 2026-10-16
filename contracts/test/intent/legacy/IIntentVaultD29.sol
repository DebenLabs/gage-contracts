// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice The views of an Intent vault built before D51, when an early repayment's net interest ran on its original
/// schedule (D29). Fork suites that read vaults already published on a chain call them through this.
interface IIntentVaultD29 {
    /// @notice Net interest of loans repaid before the end of their term whose schedule still runs.
    function paidInterest() external view returns (uint256);

    /// @notice Paid interest its schedule has not earned yet.
    function unearnedInterest() external view returns (uint256);
}
