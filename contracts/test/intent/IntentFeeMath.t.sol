// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentFeeBreakdown} from "./IntentFeeBreakdown.sol";

/// @notice The shared fee calculation against the reference vectors of docs/intent-v1/evidence/fee-math-check.json
/// and the properties FEE-MATH.md asks an implementation to prove. Rates here are test inputs, not settings.
contract IntentFeeMathTest is Test {
    function _check(
        uint256 gross,
        uint256 minimum,
        uint256 executionFee,
        uint256 performanceFee,
        uint256 protocolFee,
        uint256 managerFee,
        uint256 depositorInterest
    ) internal pure {
        (bool ok, IntentFeeBreakdown.Breakdown memory b) = IntentFeeBreakdown.breakdown(gross, minimum, 2000, 1000);
        assertTrue(ok);
        assertEq(b.executionFee, executionFee);
        assertEq(b.performanceFee, performanceFee);
        assertEq(b.protocolPerformanceFee, protocolFee);
        assertEq(b.managerNetFee, managerFee);
        assertEq(b.depositorInterest, depositorInterest);
    }

    /// @dev The first `units` empty lender units of a listing, as the core and the vaults take them.
    function _purchase(uint256 principal, uint256 cap, uint256 taken, uint256 units)
        internal
        pure
        returns (uint256 lent, uint256 interest)
    {
        uint256 owed;
        for (uint256 i; i < 4 && units != 0; ++i) {
            if (taken >> i & 1 != 0) continue;
            lent += principal / 4 + (i < principal % 4 ? 1 : 0);
            owed += cap / 4 + (i < cap % 4 ? 1 : 0);
            --units;
        }
        interest = owed - lent;
    }

    /// @dev S3-A4: every boundary vector of docs/intent-v1/evidence/check-quote-math.py, the same file the quote
    /// service replays. The file names the policy version and the outer ceiling it was generated for.
    function testTheS3QuoteVectorsReplayExactly() public view {
        string memory json = vm.readFile("../docs/intent-v1/evidence/s3-fee-vectors.json");
        // Version 1 of the calculation, as the verifier's `FEE_POLICY_VERSION` names it (pinned in the verifier suite).
        assertEq(vm.parseJsonUint(json, ".feePolicyVersion"), 1);
        assertEq(vm.parseJsonUint(json, ".maxExecutionCapBps"), IntentFeeMath.MAX_EXECUTION_CAP_BPS);
        uint256[] memory pct = vm.parseJsonUintArray(json, ".floorPct");
        for (uint256 rank; rank < pct.length; ++rank) {
            assertEq(IntentFeeMath.floorPct(rank), pct[rank]);
        }
        uint256[] memory principal = vm.parseJsonUintArray(json, ".vectors.principal");
        uint256[] memory cap = vm.parseJsonUintArray(json, ".vectors.cap");
        uint256[] memory taken = vm.parseJsonUintArray(json, ".vectors.taken");
        uint256[] memory units = vm.parseJsonUintArray(json, ".vectors.units");
        uint256[] memory cost = vm.parseJsonUintArray(json, ".vectors.costBps");
        uint256[] memory rank_ = vm.parseJsonUintArray(json, ".vectors.minRateGrade");
        uint256[] memory capBps = vm.parseJsonUintArray(json, ".vectors.capBps");
        uint256[] memory managerBps = vm.parseJsonUintArray(json, ".vectors.managerBps");
        bool[] memory refused = vm.parseJsonBoolArray(json, ".vectors.refused");
        assertEq(principal.length, vm.parseJsonUint(json, ".count"));
        assertGt(principal.length, 100);
        for (uint256 i; i < principal.length; ++i) {
            (uint256 lent, uint256 interest) = _purchase(principal[i], cap[i], taken[i], units[i]);
            assertEq(lent, _at(json, "purchasePrincipal", i));
            assertEq(interest, _at(json, "interest", i));
            uint256 minimum = IntentFeeMath.minimumInterest(lent, cost[i], rank_[i]);
            assertEq(minimum, _at(json, "minimum", i));
            assertEq(IntentFeeMath.executionCap(interest, capBps[i]), _at(json, "ceiling", i));
            (bool ok, IntentFeeBreakdown.Breakdown memory b) =
                IntentFeeBreakdown.breakdown(interest, minimum, capBps[i], managerBps[i]);
            assertEq(ok, !refused[i]);
            if (!ok) continue;
            assertEq(b.executionFee, _at(json, "executionFee", i));
            assertEq(b.performanceFee, _at(json, "managerFee", i));
            assertEq(b.protocolPerformanceFee, _at(json, "protocolPerformanceFee", i));
            assertEq(b.managerNetFee, _at(json, "managerNetFee", i));
            assertEq(b.depositorInterest, _at(json, "depositorInterest", i));
        }
    }

    function _at(string memory json, string memory column, uint256 i) internal pure returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".vectors.", column, "[", vm.toString(i), "]"));
    }

    function testFuzz_TheMinimumIsTheLeastInterestThatKeepsTheGradesShareOfTheModeledCost(
        uint128 principal,
        uint32 costBps,
        uint8 rank
    ) public pure {
        rank = uint8(bound(rank, 0, 4));
        uint256 minimum = IntentFeeMath.minimumInterest(principal, costBps, rank);
        uint256 asked = uint256(principal) * costBps * IntentFeeMath.floorPct(rank);
        assertGe(minimum * 1_000_000, asked);
        if (minimum != 0) assertLt((minimum - 1) * 1_000_000, asked);
    }

    function testReferenceVectors() public pure {
        // Cap binds: 20% of 100.
        _check(100e6, 70e6, 20e6, 8e6, 0.8e6, 7.2e6, 72e6);
        // Minimum binds: the FEE-MATH worked example.
        _check(100e6, 85e6, 15e6, 8.5e6, 0.85e6, 7.65e6, 76.5e6);
        _check(75e6, 70e6, 5e6, 7e6, 0.7e6, 6.3e6, 63e6);
        // Even a zero fee leaves less than the minimum: refused.
        (bool ok,) = IntentFeeBreakdown.breakdown(60e6, 70e6, 2000, 1000);
        assertFalse(ok);
    }

    function testZeroMinimumTakesTheCapAndZeroCapTakesNothing() public pure {
        (bool ok, uint256 fee) = IntentFeeMath.executionFee(100e6, 0, 2000);
        assertTrue(ok);
        assertEq(fee, 20e6);
        (ok, fee) = IntentFeeMath.executionFee(100e6, 0, 10_000);
        assertEq(fee, 100e6);
        (ok, fee) = IntentFeeMath.executionFee(100e6, 100e6, 2000);
        assertTrue(ok);
        assertEq(fee, 0);
        (ok, fee) = IntentFeeMath.executionFee(100e6, 0, 0);
        assertEq(fee, 0);
    }

    /// @dev Within the cap, the minimum survives, and the parts sum to the interest exactly.
    function testFuzz_AcceptedFillsConserveAndRespectBothBounds(
        uint128 gross,
        uint128 minimum,
        uint16 capBps,
        uint16 managerBps
    ) public pure {
        capBps = uint16(bound(capBps, 0, 10_000));
        managerBps = uint16(bound(managerBps, 0, 10_000));
        (bool ok, IntentFeeBreakdown.Breakdown memory b) =
            IntentFeeBreakdown.breakdown(gross, minimum, capBps, managerBps);
        assertEq(ok, gross >= minimum, "refused exactly when the interest is below the minimum");
        if (!ok) return;
        assertLe(b.executionFee, IntentFeeMath.executionCap(gross, capBps));
        assertGe(gross - b.executionFee, minimum);
        assertEq(b.executionFee + b.protocolPerformanceFee + b.managerNetFee + b.depositorInterest, gross);
        // Below the cap, one more unit would break the minimum.
        if (b.executionFee < IntentFeeMath.executionCap(gross, capBps)) {
            assertLt(uint256(gross) - (b.executionFee + 1), uint256(minimum));
        }
    }

    /// @dev The manager rate moves what depositors keep, never the execution fee; a higher minimum never raises it.
    function testFuzz_ManagerRateAndMinimumNeverRaiseTheExecutionFee(
        uint128 gross,
        uint128 minimum,
        uint128 higher,
        uint16 capBps,
        uint16 rateA,
        uint16 rateB
    ) public pure {
        capBps = uint16(bound(capBps, 0, 10_000));
        rateA = uint16(bound(rateA, 0, 10_000));
        rateB = uint16(bound(rateB, 0, 10_000));
        minimum = uint128(bound(minimum, 0, gross));
        higher = uint128(bound(higher, minimum, gross));
        (, IntentFeeBreakdown.Breakdown memory a) = IntentFeeBreakdown.breakdown(gross, minimum, capBps, rateA);
        (, IntentFeeBreakdown.Breakdown memory b) = IntentFeeBreakdown.breakdown(gross, minimum, capBps, rateB);
        assertEq(a.executionFee, b.executionFee);
        (, uint256 feeAtHigher) = IntentFeeMath.executionFee(gross, higher, capBps);
        assertLe(feeAtHigher, a.executionFee);
    }

    /// @dev One aggregated contribution never pays less in fees than the same interest split in two, so splitting
    /// cannot widen the allowance: the cap and the performance fee both round down per call.
    function testFuzz_SplittingAContributionNeverWidensTheAllowance(uint128 first, uint128 second, uint16 capBps)
        public
        pure
    {
        capBps = uint16(bound(capBps, 0, 10_000));
        uint256 whole = IntentFeeMath.executionCap(uint256(first) + second, capBps);
        uint256 parts = IntentFeeMath.executionCap(first, capBps) + IntentFeeMath.executionCap(second, capBps);
        assertLe(parts, whole);
        assertLe(whole - parts, 1);
    }
}
