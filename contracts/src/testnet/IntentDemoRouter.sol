// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TestnetOnly} from "./TestnetOnly.sol";
import {IntentVault} from "../intent/IntentVault.sol";
import {IntentFactory} from "../intent/IntentFactory.sol";

/// @title IntentDemoRouter
/// @notice Testnet fixture for the S2 accounting demonstration: it lets an admitted filler buy into a listing for a
///         partner vault with an execution fee the caller names, and move the vault's idle cash into its reserve.
/// @dev This is NOT the Intent fill router. It verifies no quote, enforces no fee cap and no return floor (S3), and
///      does not complete a loan atomically across vaults (S4). It exists only so the vault's accounting can be shown
///      on a test chain before those sprints, and it refuses to exist on Robinhood Chain mainnet.
contract IntentDemoRouter is TestnetOnly {
    IntentFactory public immutable FACTORY;

    error NotFiller();
    error NotAVault();

    constructor(IntentFactory factory) {
        FACTORY = factory;
    }

    /// @notice Buy `units` quarters of listing `id` for `vault`, paying `executionFee` USDG for the execution.
    function fund(IntentVault vault, uint256 id, uint8 units, uint256 executionFee) external {
        _check(vault);
        vault.purchase(id, units, 0, type(uint256).max, executionFee);
    }

    /// @notice Move `assets` of the vault's idle cash into its reserve.
    function investReserve(IntentVault vault, uint256 assets) external returns (uint256 shares) {
        _check(vault);
        return vault.investReserve(assets, 0);
    }

    function _check(IntentVault vault) internal view {
        if (!FACTORY.isFiller(msg.sender)) revert NotFiller();
        if (!FACTORY.isVault(address(vault))) revert NotAVault();
    }
}
