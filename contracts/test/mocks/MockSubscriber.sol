// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice A subscriber that accepts everything, so a position can be subscribed in tests.
contract MockSubscriber is ISubscriber {
    function notifySubscribe(uint256, bytes memory) external {}
    function notifyUnsubscribe(uint256) external {}
    function notifyBurn(uint256, address, PositionInfo, uint256, BalanceDelta) external {}
    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external {}
}
