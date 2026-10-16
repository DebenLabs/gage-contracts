// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentFeeBreakdown} from "./IntentFeeBreakdown.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";

/// @notice S9-04, SEC-03/SEC-04: the contracts' secondary arithmetic replays every vector of
/// docs/intent-v1/evidence/check-secondary-math.py, the same file the quote service replays.
contract IntentSecondaryMathTest is IntentSecondaryBaseTest {
    function testTheS9SecondaryVectorsReplayExactly() public view {
        string memory json = vm.readFile("../docs/intent-v1/evidence/s9-secondary-vectors.json");
        assertEq(vm.parseJsonUint(json, ".secondaryPolicyVersion"), verifier.SECONDARY_POLICY_VERSION());
        assertEq(vm.parseJsonUint(json, ".maxExecutionCapBps"), IntentFeeMath.MAX_EXECUTION_CAP_BPS);
        assertEq(vm.parseJsonUint(json, ".year"), 365 days);
        uint256 count = vm.parseJsonUint(json, ".count");
        assertGt(count, 100);
        IntentAssetPolicy policy = buyerA.ASSET_POLICY();
        for (uint256 i; i < count; ++i) {
            uint256 price = _at(json, "price", i);
            uint8 listed = uint8(_at(json, "listed", i));
            uint8 mask = uint8(_at(json, "mask", i));
            uint256 allocationPrice;
            for (uint8 q; q < 4; ++q) {
                if (mask & (1 << q) != 0) allocationPrice += verifier.quarterPrice(price, listed, q);
            }
            assertEq(allocationPrice, _at(json, "allocationPrice", i), "allocation price");
            uint256 repayment = policy.repayment(uint128(_at(json, "cap", i)), mask);
            assertEq(repayment, _at(json, "repayment", i), "repayment");
            assertEq(policy.repayment(uint128(_at(json, "principal", i)), mask), _at(json, "represented", i));
            uint256 minimum = IntentFeeMath.secondaryMinimum(
                allocationPrice, _at(json, "modelBps", i) + _at(json, "extraBps", i), _at(json, "remaining", i)
            );
            assertEq(minimum, _at(json, "minimum", i), "minimum");
            bool refused = vm.parseJsonBool(json, string.concat(".vectors.refused[", vm.toString(i), "]"));
            if (repayment <= allocationPrice) {
                assertTrue(refused, "no return, refused");
                continue;
            }
            uint256 gross = repayment - allocationPrice;
            assertEq(IntentFeeMath.executionCap(gross, _at(json, "capBps", i)), _at(json, "ceiling", i));
            (bool ok, IntentFeeBreakdown.Breakdown memory b) =
                IntentFeeBreakdown.breakdown(gross, minimum, _at(json, "capBps", i), _at(json, "managerBps", i));
            assertEq(ok, !refused, "refusal");
            if (!ok) continue;
            assertEq(b.executionFee, _at(json, "executionFee", i));
            assertEq(b.performanceFee, _at(json, "performanceFee", i));
            assertEq(b.protocolPerformanceFee, _at(json, "protocolPerformanceFee", i));
            assertEq(b.managerNetFee, _at(json, "managerNetFee", i));
            assertEq(b.depositorInterest, _at(json, "depositorInterest", i));
        }
    }

    function _at(string memory json, string memory column, uint256 i) internal pure returns (uint256) {
        return vm.parseJsonUint(json, string.concat(".vectors.", column, "[", vm.toString(i), "]"));
    }
}
