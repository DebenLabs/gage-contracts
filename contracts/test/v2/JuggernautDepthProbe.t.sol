// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Two-hop exit sizing probe (JUGGERNAUT -> WETH on v3, unwrap, ETH -> USDG); logs (tokens, USDG out, bps of spot).
// Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {JuggernautAdmissionLiveForkTest} from "./JuggernautAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract JuggernautDepthProbeTest is JuggernautAdmissionLiveForkTest {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_250k() public {
        _probe(250_000e18);
    }

    function testProbe_500k() public {
        _probe(500_000e18);
    }

    function testProbe_1000k() public {
        _probe(1_000_000e18);
    }

    function testProbe_2500k() public {
        _probe(2_500_000e18);
    }

    function testProbe_5000k() public {
        _probe(5_000_000e18);
    }

    function testProbe_10000k() public {
        _probe(10_000_000e18);
    }

    function testProbe_20000k() public {
        _probe(20_000_000e18);
    }
}
