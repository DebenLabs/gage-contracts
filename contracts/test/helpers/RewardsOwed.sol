// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";

Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev Test-only stand-in for the ledger's former `reserved` counter (removed by REW-05): its outstanding reward
/// liability, that is the claimable reward of `holders` (each account counted once) on loans 1 to `loanCount`, plus the
/// unearned remainder of every allocation still open, on the ledger's own quadratic clock. When `holders` names every
/// account that ever earned, an unbridged ledger that receives no donations holds exactly `freeBudget()` plus this.
/// The clock is read with `getBlockTimestamp`: under via-IR a test's `block.timestamp` may be cached across `vm.warp`.
function rewardsOwed(GageV2Rewards ledger, uint256 loanCount, address[] memory holders) view returns (uint256 owed) {
    uint256 now_ = VM.getBlockTimestamp();
    for (uint256 id = 1; id <= loanCount; ++id) {
        GageV2Rewards.Allocation memory a = ledger.allocation(id);
        if (a.start == 0) continue;
        for (uint256 i; i < holders.length; ++i) {
            bool counted;
            for (uint256 j; j < i; ++j) {
                if (holders[j] == holders[i]) counted = true;
            }
            if (!counted) owed += ledger.claimable(id, holders[i]);
        }
        if (a.end != 0) continue;
        uint256 elapsed = Math.min(now_ - a.start, a.term);
        uint256 square = elapsed * elapsed;
        uint256 denominator = uint256(a.term) * a.term;
        owed += a.borrowerTotal - Math.mulDiv(a.borrowerTotal, square, denominator);
        owed += a.lenderTotal - Math.mulDiv(a.lenderTotal, square, denominator);
    }
}
