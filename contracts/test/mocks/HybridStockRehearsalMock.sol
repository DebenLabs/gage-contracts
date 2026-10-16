// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @notice Local stock token with the ERC-8056 display metadata used by the indexer.
contract HybridStockRehearsalMock is MockERC20 {
    constructor() MockERC20("Local NVIDIA Test Token", "NVDA", 18) {}

    /// @notice A fixed-point value of 1e18 means one displayed unit per raw whole token.
    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }
}
