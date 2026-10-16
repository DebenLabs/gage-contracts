// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./Base.t.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {IDealVault} from "../src/interfaces/IDealVault.sol";

contract FeeSinkTest is BaseTest {
    address internal buybackStub = makeAddr("buyback");

    function test_constructor_state() public view {
        assertEq(address(feeSink.USDG()), address(usdg));
        assertEq(address(feeSink.vault()), address(vault));
        assertEq(feeSink.treasury(), treasury);
        assertEq(feeSink.buyback(), address(0));
        assertEq(uint8(feeSink.route()), uint8(FeeSink.Route.TREASURY));
        assertEq(feeSink.owner(), safe);
    }

    function test_constructor_revertsZero() public {
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(IERC20(address(0)), safe, treasury);
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(usdg, safe, address(0));
    }

    function test_setVault_onceOnly() public {
        FeeSink f = new FeeSink(usdg, safe, treasury);
        vm.startPrank(safe);
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        f.setVault(IDealVault(address(0)));
        vm.expectEmit(address(f));
        emit FeeSink.VaultSet(address(vault));
        f.setVault(vault);
        vm.expectRevert(FeeSink.VaultAlreadySet.selector);
        f.setVault(vault);
        vm.stopPrank();
    }

    function test_collect_revertsVaultNotSet() public {
        FeeSink f = new FeeSink(usdg, safe, treasury);
        vm.expectRevert(FeeSink.VaultNotSet.selector);
        f.collect();
    }

    function test_collect_returnsZeroWhenNothing() public {
        assertEq(feeSink.collect(), 0);
    }

    function test_collect_pullsFees() public {
        _fundDeal();
        uint128 fee = _fee(7960e6);
        vm.expectEmit(address(feeSink));
        emit FeeSink.Collected(fee);
        vm.prank(other);
        assertEq(feeSink.collect(), fee);
        assertEq(usdg.balanceOf(address(feeSink)), fee);
        assertEq(vault.balanceUSDG(address(feeSink)), 0);
    }

    function test_collect_accumulatesAcrossDeals() public {
        _fundDeal();
        _fundDeal();
        assertEq(feeSink.collect(), 2 * _fee(7960e6));
    }

    function test_sweep_toTreasury() public {
        _fundDeal();
        feeSink.collect();
        uint128 fee = _fee(7960e6);
        vm.expectEmit(address(feeSink));
        emit FeeSink.Swept(FeeSink.Route.TREASURY, treasury, fee);
        assertEq(feeSink.sweep(), fee);
        assertEq(usdg.balanceOf(treasury), fee);
        assertEq(usdg.balanceOf(address(feeSink)), 0);
    }

    function test_sweep_revertsNothing() public {
        vm.expectRevert(FeeSink.NothingToSweep.selector);
        feeSink.sweep();
    }

    function test_setRoute_buybackRequiresAddress() public {
        vm.startPrank(safe);
        vm.expectRevert(FeeSink.BuybackNotSet.selector);
        feeSink.setRoute(FeeSink.Route.BUYBACK);
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        feeSink.setBuyback(address(0));
        vm.expectEmit(address(feeSink));
        emit FeeSink.BuybackSet(buybackStub);
        feeSink.setBuyback(buybackStub);
        vm.expectEmit(address(feeSink));
        emit FeeSink.RouteSet(FeeSink.Route.BUYBACK);
        feeSink.setRoute(FeeSink.Route.BUYBACK);
        assertEq(uint8(feeSink.route()), uint8(FeeSink.Route.BUYBACK));
        vm.stopPrank();
    }

    function test_sweep_toBuyback() public {
        vm.startPrank(safe);
        feeSink.setBuyback(buybackStub);
        feeSink.setRoute(FeeSink.Route.BUYBACK);
        vm.stopPrank();
        _fundDeal();
        feeSink.collect();
        feeSink.sweep();
        assertEq(usdg.balanceOf(buybackStub), _fee(7960e6));
        assertEq(usdg.balanceOf(treasury), 0);
    }

    function test_setTreasury() public {
        vm.startPrank(safe);
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        feeSink.setTreasury(address(0));
        vm.expectEmit(address(feeSink));
        emit FeeSink.TreasurySet(other);
        feeSink.setTreasury(other);
        assertEq(feeSink.treasury(), other);
        vm.stopPrank();
    }

    function test_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other);
        vm.startPrank(other);
        vm.expectRevert(err);
        feeSink.setRoute(FeeSink.Route.TREASURY);
        vm.expectRevert(err);
        feeSink.setTreasury(other);
        vm.expectRevert(err);
        feeSink.setBuyback(other);
        vm.expectRevert(err);
        feeSink.setVault(vault);
        vm.stopPrank();
    }

    function test_collectAndSweep_arePermissionless() public {
        _fundDeal();
        vm.prank(other);
        feeSink.collect();
        vm.prank(other);
        feeSink.sweep();
        assertEq(usdg.balanceOf(treasury), _fee(7960e6));
    }
}
