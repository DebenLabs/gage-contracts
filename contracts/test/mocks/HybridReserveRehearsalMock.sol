// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HybridReserveMock} from "./HybridReserveMock.sol";

/// @notice Local fixture exposing Morpho's accrual views for the production indexer.
contract HybridReserveRehearsalMock is HybridReserveMock {
    constructor(IERC20 asset_) HybridReserveMock(asset_) {}
}
