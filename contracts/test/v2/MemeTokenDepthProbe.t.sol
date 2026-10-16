// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Exit sizing probe for the meme token batch (scripts/lib/meme-token-admission.mjs) at the pinned fork: every enabled route
// sells the minimum, the per-loan limit, the aggregate and twice the aggregate from the same pinned state, and logs
// (route, tokens, USDG out, bps of the published route's pre-trade spot, bps of the route's own spot). Fees, hook charges
// and price impact are included; gas is not. Rerun at the weekly cap revisit. Skips without a fork RPC.
import {MemeTokenAdmissionLiveForkBase, PriorsAdmissionLiveForkTest} from "./MemeTokenAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

abstract contract MemeTokenDepthProbe is MemeTokenAdmissionLiveForkBase {
    function _probe(uint256 amount) internal {
        uint256 published = _spotUSDG(0, amount);
        for (uint256 r; r < _routeCount(); ++r) {
            uint256 own = _spotUSDG(r, amount);
            uint256 snapshot = vm.snapshotState();
            uint256 out = _sell(r, amount);
            vm.revertToState(snapshot);
            console2.log("route", r, amount / 1e18);
            console2.log(
                "  usdg out, bps of published spot, bps of own spot",
                out,
                (out * 10_000) / published,
                (out * 10_000) / own
            );
        }
    }

    function testProbe_1_minimum() public {
        _probe(_min());
    }

    function testProbe_2_perLoan() public {
        _probe(_perDeal());
    }

    function testProbe_3_aggregate() public {
        _probe(_aggregate());
    }

    function testProbe_4_aggregate2x() public {
        _probe(2 * _aggregate());
    }
}

contract PriorsDepthProbeTest is MemeTokenDepthProbe, PriorsAdmissionLiveForkTest {
    function setUp() public override(MemeTokenAdmissionLiveForkBase, PriorsAdmissionLiveForkTest) {
        super.setUp();
    }
}
