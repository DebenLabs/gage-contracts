// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @notice Forks Robinhood Chain mainnet and reads gage's addresses from this repository's deployment manifest.
abstract contract MainnetFork is Test {
    string internal manifest;

    function setUp() public virtual {
        vm.createSelectFork("mainnet");
        manifest = vm.readFile("../../deployments/manifest/4663.json");
    }

    /// @notice The address at a manifest key, such as `intentV1.core` or `intentV1Assets.NVDA.factory`. An array index
    /// takes brackets here (`lpLane.adapters[0].address`), where the guides write `lpLane.adapters.0.address`.
    function addressOf(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(manifest, string.concat(".", key));
    }

    /// @notice Whether the manifest has a key, for parts a release may not carry.
    function has(string memory key) internal view returns (bool) {
        return vm.keyExistsJson(manifest, string.concat(".", key));
    }
}
