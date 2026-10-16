// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentCategory, IntentLimit} from "../../src/intent/IntentVaultState.sol";

/// @notice Test helper for the risk limits of Intent D53: the curator moves each one in the vault's asset policy, a
/// tightening at once and a loosening after its three-hour wait. `set*` reaches the target either way: a loosening is
/// queued, the clock moved past its wait and the change activated. A test whose point is the wait itself calls the
/// policy directly.
/// @dev Reads the curator and the policy before pranking, so an expectation set by the caller is never spent on a read.
/// The caller must not have a prank pending.
library IntentLimits {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function setLimit(IntentVault vault, IntentLimit limit, uint128 value) internal {
        IntentAssetPolicy policy = vault.ASSET_POLICY();
        address curator = vault.CURATOR();
        VM.prank(curator);
        policy.setLimit(limit, value);
        (, uint64 readyAt) = policy.pendingLimit(limit);
        if (readyAt == 0) return;
        VM.warp(readyAt);
        policy.activateLimit(limit);
    }

    /// @dev The three limits the vault's former `setLimits` moved together, each set in turn.
    function setLimits(IntentVault vault, uint128 maxLoanPrincipal, uint16 maxAssetBps, uint16 bufferBps) internal {
        setLimit(vault, IntentLimit.MAX_LOAN_PRINCIPAL, maxLoanPrincipal);
        setLimit(vault, IntentLimit.MAX_ASSET_BPS, maxAssetBps);
        setLimit(vault, IntentLimit.BUFFER_BPS, bufferBps);
    }

    function setCategoryWeight(IntentVault vault, IntentCategory lane, uint16 bps) internal {
        setLimit(vault, category(lane), bps);
    }

    function setMinRateGrade(IntentVault vault, uint8 rank) internal {
        setLimit(vault, IntentLimit.MIN_RATE_GRADE, rank);
    }

    /// @notice The limit that holds a category's weight.
    function category(IntentCategory lane) internal pure returns (IntentLimit) {
        return IntentLimit(uint8(IntentLimit.CATEGORY_STOCK) + uint8(lane));
    }
}
