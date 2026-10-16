// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";

contract SGAGETest is TokenBaseTest {
    function test_mintedOnce() public view {
        assertEq(sgage.totalSupply(), 5_000_000_000e18);
        assertEq(sgage.balanceOf(address(emissions)), 4_000_000_000e18);
        assertEq(sgage.balanceOf(treasury), 1_000_000_000e18);
        assertEq(sgage.TOTAL_SUPPLY_AT_MINT(), 5_000_000_000e18);
        assertEq(sgage.decimals(), 18);
    }

    function test_constructor_revertsZero() public {
        vm.expectRevert(SGAGE.ZeroAddress.selector);
        new SGAGE(address(0), treasury);
        vm.expectRevert(SGAGE.ZeroAddress.selector);
        new SGAGE(address(emissions), address(0));
    }

    function test_burnReducesSupply() public {
        vm.prank(treasury);
        sgage.burn(1e18);
        assertEq(sgage.totalSupply(), 5_000_000_000e18 - 1e18);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(sgage).call(abi.encodeWithSignature("mint(address,uint256)", other, 1));
        assertFalse(ok);
        (ok,) = address(sgage).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    /// @dev T1 under fuzz: any sequence of burns only lowers supply.
    function testFuzz_T1_supplyOnlyDecreases(uint256 a, uint256 b) public {
        a = bound(a, 0, 1_000_000_000e18);
        b = bound(b, 0, 1_000_000_000e18 - a);
        uint256 s0 = sgage.totalSupply();
        vm.startPrank(treasury);
        if (a > 0) sgage.burn(a);
        uint256 s1 = sgage.totalSupply();
        if (b > 0) sgage.burn(b);
        vm.stopPrank();
        assertLe(s1, s0);
        assertLe(sgage.totalSupply(), s1);
        assertEq(sgage.totalSupply(), s0 - a - b);
    }
}
