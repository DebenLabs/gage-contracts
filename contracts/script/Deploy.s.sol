// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Retired foundation-only entrypoint. Use `python3 scripts/launch.py` from the repository root.
/// @dev The launch coordinator journals transactions, retains the deployment EOA as owner and treasury,
///      verifies each wiring step, and publishes the matching app/services before continuing.
contract Deploy {
    error UseLaunchCoordinator();

    function run() external pure {
        revert UseLaunchCoordinator();
    }
}
