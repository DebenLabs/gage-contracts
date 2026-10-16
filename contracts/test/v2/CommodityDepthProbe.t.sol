// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// One-step exit sizing probe (token -> USDG on the depth pool); logs (tokens, USDG out, bps of spot) at multiples of the
// limits. Rerun at the weekly cap revisit. Skips without a fork RPC like the admission suite.
import {
    CommodityAdmissionLiveForkBase,
    GldAdmissionLiveForkTest,
    SlvAdmissionLiveForkTest,
    UsoAdmissionLiveForkTest
} from "./CommodityAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

abstract contract CommodityDepthProbe is CommodityAdmissionLiveForkBase {
    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sell(_pools()[0], amount);
        console2.log(amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_perDeal() public {
        _probe(_perDeal());
    }

    function testProbe_aggregate() public {
        _probe(_aggregate());
    }

    function testProbe_aggregate2x() public {
        _probe(2 * _aggregate());
    }

    function testProbe_aggregate4x() public {
        _probe(4 * _aggregate());
    }

    function testProbe_aggregate8x() public {
        _probe(8 * _aggregate());
    }
}

contract GldDepthProbeTest is CommodityDepthProbe, GldAdmissionLiveForkTest {}

contract SlvDepthProbeTest is CommodityDepthProbe, SlvAdmissionLiveForkTest {}

contract UsoDepthProbeTest is CommodityDepthProbe, UsoAdmissionLiveForkTest {}
