// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title TestnetOnly
/// @notice Refuses to exist on Robinhood Chain mainnet. Every fixture a labeled gage testnet deploys inherits
///         this, so a misconfigured coordinator cannot put a valueless stand-in on the chain that carries value.
/// @dev This denies one chain rather than pinning one, unlike the older rehearsal fixtures, because the testnet a
///      config names is a setting: pinning 46630 into the bytecode would make these undeployable on any other test
///      chain. The one chain that must never see them is the one that holds value, and that is the one denied.
abstract contract TestnetOnly {
    /// @notice Robinhood Chain mainnet, where none of these fixtures may ever be deployed.
    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    error MainnetForbidden();

    constructor() {
        if (block.chainid == MAINNET_CHAIN_ID) revert MainnetForbidden();
    }
}
