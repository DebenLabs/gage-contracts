// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";

/// @notice Test reference: every amount of one accepted fill, composed from `IntentFeeMath` as
/// docs/intent-v1/FEE-MATH.md composes them. The vault books the same parts itself; nothing deployed uses this.
library IntentFeeBreakdown {
    struct Breakdown {
        uint256 executionFee;
        uint256 performanceFee;
        uint256 protocolPerformanceFee;
        uint256 managerNetFee;
        uint256 depositorInterest;
    }

    /// @notice Every amount of one accepted fill; they sum to `gross` exactly.
    function breakdown(uint256 gross, uint256 minimum, uint256 capBps, uint256 managerBps)
        internal
        pure
        returns (bool ok, Breakdown memory b)
    {
        (ok, b.executionFee) = IntentFeeMath.executionFee(gross, minimum, capBps);
        if (!ok) return (false, b);
        b.performanceFee = IntentFeeMath.performanceFee(gross, b.executionFee, managerBps);
        b.protocolPerformanceFee = b.performanceFee * IntentFeeMath.PROTOCOL_SHARE_BPS / IntentFeeMath.BPS;
        b.managerNetFee = b.performanceFee - b.protocolPerformanceFee;
        b.depositorInterest = gross - b.executionFee - b.performanceFee;
    }
}
