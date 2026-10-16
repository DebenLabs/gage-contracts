// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Two-hop exit sizing probe (ORBIO -> NVDA on the Pons V2 launch pool with its after-swap charge, NVDA -> USDG);
// logs (tokens, USDG out, bps of spot). Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {OrbioAdmissionLiveForkTest} from "./OrbioAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract OrbioDepthProbeTest is OrbioAdmissionLiveForkTest {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_50k() public {
        _probe(50_000e18);
    }

    function testProbe_100k() public {
        _probe(100_000e18);
    }

    function testProbe_150k() public {
        _probe(150_000e18);
    }

    function testProbe_250k() public {
        _probe(250_000e18);
    }

    function testProbe_400k() public {
        _probe(400_000e18);
    }

    function testProbe_450k() public {
        _probe(450_000e18);
    }

    function testProbe_500k() public {
        _probe(500_000e18);
    }

    function testProbe_750k() public {
        _probe(750_000e18);
    }

    function testProbe_1000k() public {
        _probe(1_000_000e18);
    }

    function testProbe_2000k() public {
        _probe(2_000_000e18);
    }
}
