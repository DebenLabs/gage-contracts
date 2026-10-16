// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice What a bound V2 engine asks before it records a lender: whether the account is one of the gate's vaults.
/// @dev `IntentFactory.isVault` answers it, so a bound engine lends only through that factory's partner vaults.
interface IFunderGate {
    function isVault(address account) external view returns (bool);
}
