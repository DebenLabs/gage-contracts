// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Two-hop exit sizing probe behind the ASTEROID caps; logs (tokens, USDG out, bps of spot).
// Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {AsteroidAdmissionLiveForkTest} from "./AsteroidAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract AsteroidDepthProbeTest is AsteroidAdmissionLiveForkTest {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_1000k() public {
        _probe(1_000_000e18);
    }

    function testProbe_1100k() public {
        _probe(1_100_000e18);
    }

    function testProbe_1200k() public {
        _probe(1_200_000e18);
    }

    function testProbe_1300k() public {
        _probe(1_300_000e18);
    }

    function testProbe_1400k() public {
        _probe(1_400_000e18);
    }
}
