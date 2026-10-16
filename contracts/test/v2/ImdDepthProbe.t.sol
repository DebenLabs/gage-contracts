// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Exit sizing probe for IMD at the pinned fork, independent of the registry limits: "eth" sells through the v4 IMD/ETH
// pool and then native ETH/USDG; "usdg" sells through the direct v4 IMD/USDG pool; "v3" sells through the canonical v3
// IMD/WETH pool, unwraps and sells ETH/USDG. Each probe starts from the pinned state and logs (route, IMD, USDG out,
// bps of pre-trade IMD/ETH spot); a pool that runs out of liquidity logs the IMD left unsold. Rerun at a cap revisit.
// Skips without a fork RPC like the admission suite.
import {ImdForkBase} from "./ImdAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract ImdDepthProbeTest is ImdForkBase {
    function setUp() public {
        _fork();
    }

    function _probeEth(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellViaEth(amount);
        console2.log("eth", amount / 1e18, out, (out * 10_000) / spot);
    }

    function _probeDirect(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        (uint256 out, uint256 unsold) = _trySellDirect(amount);
        console2.log("usdg", amount / 1e18, out, (out * 10_000) / spot);
        if (unsold != 0) console2.log("usdg unsold (pool out of liquidity)", unsold / 1e18);
    }

    function _probeV3(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        (uint256 out, uint256 unsold) = _trySellViaV3Weth(amount);
        console2.log("v3", amount / 1e18, out, (out * 10_000) / spot);
        if (unsold != 0) console2.log("v3 unsold (pool out of liquidity)", unsold / 1e18);
    }

    function testProbe_eth_00010() public {
        _probeEth(10e18);
    }

    function testProbe_eth_00025() public {
        _probeEth(25e18);
    }

    function testProbe_eth_00050() public {
        _probeEth(50e18);
    }

    function testProbe_eth_00100() public {
        _probeEth(100e18);
    }

    function testProbe_eth_00250() public {
        _probeEth(250e18);
    }

    function testProbe_eth_00500() public {
        _probeEth(500e18);
    }

    function testProbe_eth_01000() public {
        _probeEth(1000e18);
    }

    function testProbe_eth_01500() public {
        _probeEth(1500e18);
    }

    function testProbe_eth_02000() public {
        _probeEth(2000e18);
    }

    function testProbe_eth_03000() public {
        _probeEth(3000e18);
    }

    function testProbe_eth_05000() public {
        _probeEth(5000e18);
    }

    function testProbe_usdg_00010() public {
        _probeDirect(10e18);
    }

    function testProbe_usdg_00025() public {
        _probeDirect(25e18);
    }

    function testProbe_usdg_00050() public {
        _probeDirect(50e18);
    }

    function testProbe_usdg_00100() public {
        _probeDirect(100e18);
    }

    function testProbe_usdg_00250() public {
        _probeDirect(250e18);
    }

    function testProbe_usdg_00500() public {
        _probeDirect(500e18);
    }

    function testProbe_usdg_01000() public {
        _probeDirect(1000e18);
    }

    function testProbe_usdg_02000() public {
        _probeDirect(2000e18);
    }

    function testProbe_usdg_03000() public {
        _probeDirect(3000e18);
    }

    function testProbe_v3_00001() public {
        _probeV3(1e18);
    }

    function testProbe_v3_00005() public {
        _probeV3(5e18);
    }

    function testProbe_v3_00010() public {
        _probeV3(10e18);
    }

    function testProbe_v3_00025() public {
        _probeV3(25e18);
    }

    function testProbe_v3_00050() public {
        _probeV3(50e18);
    }
}
