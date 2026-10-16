// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {GageV2Vault} from "../../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../../src/v2/GageV2Registry.sol";
import {GageLegacyAdapter} from "../../../src/v2/GageLegacyAdapter.sol";

/// @dev Local-fork setup for the live admission probes. Each probe was written while its deployed engine took new
///      loans. Mainnet has since paused new deals on superseded engines and moved its adapter's originations to a later
///      engine. Acting as the registry owner and the adapter's admin, this reopens the engine on the fork only. An
///      engine that still takes new loans is left as it is. Nothing is broadcast.
library LiveEngine {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Unpause new deals on `vault`'s registry and select `vault` as its adapter's originating engine.
    function reopen(GageV2Vault vault) internal {
        // The deployed engines name a GageV2Registry; this source's engine types the view as its token registry.
        GageV2Registry registry = GageV2Registry(address(vault.REGISTRY()));
        if (registry.newDealsPaused()) {
            VM.prank(registry.owner());
            registry.pauseNewDeals(false);
        }
        GageLegacyAdapter bridge = vault.BRIDGE();
        if (address(bridge) != address(0) && bridge.activeEngine() != address(vault)) {
            VM.prank(bridge.ADMIN());
            bridge.setEngine(address(vault));
        }
    }
}
