// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";

Vm constant REMAINING_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev Test-only replica of the ledger's former `remainingLenderReward` view (removed by X-scope-09, its only on-chain
/// reader being the market's single-recipient `buy`): the future reward the quarters `slots` of loan `id` still carry,
/// before any early-close cutoff; zero unless the allocation is open. It reads the public `allocation` on the ledger's
/// own quadratic clock and quarter rounding, so it is what `transferLenders` compares each `minRewards[i]` with. The
/// clock is read with `getBlockTimestamp`: under via-IR a test's `block.timestamp` may be cached across `vm.warp`.
/// Bind it with `using {remainingLenderReward} for GageV2Rewards;`.
function remainingLenderReward(GageV2Rewards ledger, uint256 id, uint8 slots) view returns (uint256 remaining) {
    GageV2Rewards.Allocation memory a = ledger.allocation(id);
    if (a.start == 0 || a.end != 0) return 0;
    uint256 elapsed = Math.min(REMAINING_VM.getBlockTimestamp() - a.start, a.term);
    uint256 earned = Math.mulDiv(a.lenderTotal, elapsed * elapsed, uint256(a.term) * a.term);
    for (uint8 i; i < 4; ++i) {
        if (slots & (1 << i) != 0) remaining += _quarter(a.lenderTotal, i) - _quarter(earned, i);
    }
}

/// @dev The core's quarter rounding, restated here so the replica does not lean on the source it checks.
function _quarter(uint256 total, uint8 i) pure returns (uint256) {
    return total / 4 + (i < total % 4 ? 1 : 0);
}
