// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Two-hop exit sizing probe (COOK -> HOOD on the LunchTaxHookPair pool, HOOD -> USDG on the hook-free pool); logs
// (tokens, USDG out, bps of spot). Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {CookAdmissionLiveForkTest} from "./CookAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract CookDepthProbeTest is CookAdmissionLiveForkTest {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_0100k() public {
        _probe(100_000e18);
    }

    function testProbe_0200k() public {
        _probe(200_000e18);
    }

    function testProbe_0400k() public {
        _probe(400_000e18);
    }

    function testProbe_0600k() public {
        _probe(600_000e18);
    }

    function testProbe_0800k() public {
        _probe(800_000e18);
    }

    function testProbe_1000k() public {
        _probe(1_000_000e18);
    }

    function testProbe_1250k() public {
        _probe(1_250_000e18);
    }

    function testProbe_1500k() public {
        _probe(1_500_000e18);
    }

    function testProbe_2000k() public {
        _probe(2_000_000e18);
    }
}
