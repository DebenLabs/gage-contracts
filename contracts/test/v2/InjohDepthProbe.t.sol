// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Two-hop exit sizing probe (INJOH -> WETH on v3, unwrap, ETH -> USDG); logs (tokens, USDG out, bps of spot).
// Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {InjohAdmissionLiveForkTest} from "./InjohAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract InjohDepthProbeTest is InjohAdmissionLiveForkTest {
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

    function testProbe_1500k() public {
        _probe(1_500_000e18);
    }

    function testProbe_2000k() public {
        _probe(2_000_000e18);
    }

    function testProbe_4000k() public {
        _probe(4_000_000e18);
    }

    function testProbe_8000k() public {
        _probe(8_000_000e18);
    }

    function testProbe_16000k() public {
        _probe(16_000_000e18);
    }
}
