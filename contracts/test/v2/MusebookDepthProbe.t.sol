// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {MusebookAdmissionLiveForkTest} from "./MusebookAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract MusebookDepthProbeTest is MusebookAdmissionLiveForkTest {
    function testProbe_001m() public {
        uint256 amount = 1_000_000e18;
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, out * 10_000 / spot);
    }

    function testProbe_005m() public {
        uint256 amount = 5_000_000e18;
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, out * 10_000 / spot);
    }

    function testProbe_010m() public {
        uint256 amount = 10_000_000e18;
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, out * 10_000 / spot);
    }

    function testProbe_025m() public {
        uint256 amount = 25_000_000e18;
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, out * 10_000 / spot);
    }

    function testProbe_050m() public {
        uint256 amount = 50_000_000e18;
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, out * 10_000 / spot);
    }

    function testProbe_100m() public {
        uint256 amount = 100_000_000e18;
        uint256 spot = _spotUSDG(amount);
        uint256 out = _sellTwoHop(amount);
        console2.log(amount / 1e18, out, out * 10_000 / spot);
    }
}
