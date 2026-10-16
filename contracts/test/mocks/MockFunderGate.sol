// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IFunderGate} from "../../src/interfaces/IFunderGate.sol";

/// @dev Stand-in for the Intent factory's `isVault`: the test names which accounts count as vaults.
contract MockFunderGate is IFunderGate {
    mapping(address => bool) public isVault;

    function set(address account, bool vault) external {
        isVault[account] = vault;
    }
}

/// @dev An engine lends to no one until a gate is bound (D47). Suites about lending itself bind this one, which names
/// every account, so their wallets lend as they always have.
contract MockOpenFunderGate is IFunderGate {
    function isVault(address) external pure returns (bool) {
        return true;
    }
}
