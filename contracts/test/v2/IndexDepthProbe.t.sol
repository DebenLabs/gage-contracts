// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Exit sizing probes for INDEX: two-hop (INDEX -> WETH on v3, unwrap, ETH -> USDG), the published route, and single-hop
// through the v4 INDEX / USDG pool, recorded to show why that pool is an LP market but not a route; logs (tokens, USDG
// out, bps of that route's spot). Rerun at the weekly cap revisit. Skips
// without a fork RPC like the admission suite.
import {IndexAdmissionLiveForkTest} from "./IndexAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract IndexDepthProbeTest is IndexAdmissionLiveForkTest {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log("v3 two-hop", amount / 1e18, out, (out * 10_000) / spot);
    }

    function _probeUsdg(uint256 amount) internal {
        uint256 spot = _spotUSDGViaUsdgPool(amount);
        uint256 out = _sellUsdgPool(amount);
        console2.log("v4 usdg one-hop", amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_100k() public {
        _probe(100_000e18);
    }

    function testProbe_250k() public {
        _probe(250_000e18);
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

    function testProbe_1500k() public {
        _probe(1_500_000e18);
    }

    function testProbe_2000k() public {
        _probe(2_000_000e18);
    }

    function testProbe_4000k() public {
        _probe(4_000_000e18);
    }

    function testProbeUsdg_50k() public {
        _probeUsdg(50_000e18);
    }

    function testProbeUsdg_100k() public {
        _probeUsdg(100_000e18);
    }

    function testProbeUsdg_250k() public {
        _probeUsdg(250_000e18);
    }

    function testProbeUsdg_500k() public {
        _probeUsdg(500_000e18);
    }

    function testProbeUsdg_1000k() public {
        _probeUsdg(1_000_000e18);
    }
}
