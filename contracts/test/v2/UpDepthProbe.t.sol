// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Exit sizing probe for both enabled UP routes at the pinned fork: "weth" sells through the canonical v3 WETH / UP
// pool, unwraps and sells ETH / USDG; "usdg" sells through the canonical v3 UP / USDG pool. Each probe starts from
// the pinned state and logs (route, tokens, USDG out, bps of pre-trade spot). Rerun at the weekly cap revisit.
// Skips without a fork RPC like the admission suite.
import {UpAdmissionLiveForkTest} from "./UpAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract UpDepthProbeTest is UpAdmissionLiveForkTest {
    function _probeWeth(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellViaWeth(amount);
        console2.log("weth", amount / 1e18, out, (out * 10_000) / spot);
    }

    function _probeDirect(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        (uint256 out, uint256 unsold) = _trySellDirect(amount);
        console2.log("usdg", amount / 1e18, out, (out * 10_000) / spot);
        if (unsold != 0) console2.log("usdg unsold (pool out of liquidity)", unsold / 1e18);
    }

    function testProbe_weth_00200() public {
        _probeWeth(200e18);
    }

    function testProbe_weth_01000() public {
        _probeWeth(1000e18);
    }

    function testProbe_weth_02500() public {
        _probeWeth(2500e18);
    }

    function testProbe_weth_05000() public {
        _probeWeth(5000e18);
    }

    function testProbe_weth_10000() public {
        _probeWeth(10_000e18);
    }

    function testProbe_weth_24000() public {
        _probeWeth(24_000e18);
    }

    function testProbe_weth_48000() public {
        _probeWeth(48_000e18);
    }

    function testProbe_usdg_00200() public {
        _probeDirect(200e18);
    }

    function testProbe_usdg_01000() public {
        _probeDirect(1000e18);
    }

    function testProbe_usdg_05000() public {
        _probeDirect(5000e18);
    }

    function testProbe_usdg_24000() public {
        _probeDirect(24_000e18);
    }
}
