// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";

/// @title LPAdapterBase
/// @notice What every LP lane adapter shares: the one core allowed to operate positions through it, and no DEX rewards
/// unless the adapter names some.
abstract contract LPAdapterBase is ILPAdapter {
    /// @notice The only core allowed to operate positions through this adapter.
    address public immutable CORE;

    error NotCore(address caller);
    error ZeroAddress();

    constructor(address core_) {
        if (core_ == address(0)) revert ZeroAddress();
        CORE = core_;
    }

    modifier onlyCore() {
        if (msg.sender != CORE) revert NotCore(msg.sender);
        _;
    }

    /// @inheritdoc ILPAdapter
    function core() external view returns (address) {
        return CORE;
    }

    /// @inheritdoc ILPAdapter
    function rewardTokens() public view virtual returns (address[] memory tokens) {
        tokens = new address[](0);
    }

    /// @inheritdoc ILPAdapter
    function claimRewards(uint256) external virtual onlyCore {}
}
