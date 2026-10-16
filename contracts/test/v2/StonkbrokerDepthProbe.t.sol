// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Two-hop exit sizing probe (STONKBROKER -> native ETH -> USDG); logs (tokens, USDG out, bps of spot).
// Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {StonkbrokerAdmissionLiveForkTest} from "./StonkbrokerAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract StonkbrokerDepthProbeTest is StonkbrokerAdmissionLiveForkTest {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_250k() public {
        _probe(250_000e18);
    }

    function testProbe_1250k() public {
        _probe(1_250_000e18);
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
}
