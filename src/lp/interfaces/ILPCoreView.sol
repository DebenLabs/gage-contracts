// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Loan} from "../LPTypes.sol";

/// @notice The core's loan book, as a vault reads it.
interface ILPCoreView {
    function loan(uint256 loanId) external view returns (Loan memory);
}
