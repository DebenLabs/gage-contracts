// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentPartnersTest} from "./IntentPartners.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

contract IntentAssetTimelockTest is IntentPartnersTest {
    function _removeAndQueue() internal returns (uint256 readyAt) {
        vm.startPrank(curator);
        partner.setAsset(address(nvda), false);
        partner.setAsset(address(nvda), true);
        vm.stopPrank();
        readyAt = partner.ASSET_POLICY().readyAt(address(nvda));
    }

    function testAdditionWaitsExactlyThreeHoursAndAnyoneCanActivate() public {
        assertTrue(partner.ASSET_POLICY().picked(address(nvda)), "constructor selection is active");
        uint256 readyAt = _removeAndQueue();
        assertEq(readyAt, block.timestamp + 10_800);
        assertFalse(partner.ASSET_POLICY().picked(address(nvda)));
        vm.warp(readyAt - 1);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.resolveAssetAddition(address(nvda), true);
        vm.warp(readyAt);
        vm.prank(bob);
        partner.resolveAssetAddition(address(nvda), true);
        assertTrue(partner.ASSET_POLICY().picked(address(nvda)));
        assertEq(partner.ASSET_POLICY().readyAt(address(nvda)), 0);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.resolveAssetAddition(address(nvda), true);
    }

    function testPendingAndEmptySelectionRejectFundingAndReadditionRestartsClock() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(1000e6);
        vm.prank(curator);
        partner.setAsset(address(gold), false);
        uint256 readyAt = _removeAndQueue();
        assertFalse(partner.ASSET_POLICY().picked(address(gold)));
        assertFalse(partner.ASSET_POLICY().picked(address(nvda)));
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, 4);
        vm.warp(readyAt);
        // Passing the deadline alone cannot make a token fundable.
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, 4);
        partner.resolveAssetAddition(address(nvda), true);
        _route(id, 4);
        uint256 next = _removeAndQueue();
        assertEq(next, readyAt + 10_800);
    }

    function testCancellationRequeueAndManagerAuthorization() public {
        uint256 readyAt = _removeAndQueue();
        vm.prank(bob);
        vm.expectRevert(IntentVault.NotCurator.selector);
        partner.resolveAssetAddition(address(nvda), false);
        vm.prank(bob);
        vm.expectRevert(IntentVault.NotCurator.selector);
        partner.setAsset(address(nvda), true);
        vm.prank(curator);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.setAsset(address(nvda), true);
        vm.warp(readyAt);
        vm.prank(curator);
        partner.resolveAssetAddition(address(nvda), false);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.resolveAssetAddition(address(nvda), true);
        vm.prank(curator);
        partner.setAsset(address(nvda), true);
        assertEq(partner.ASSET_POLICY().readyAt(address(nvda)), readyAt + 10_800);
    }

    function testRevocationDuringDelayBlocksActivationWithoutConsumingQueue() public {
        uint256 readyAt = _removeAndQueue();
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        vm.warp(readyAt);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.resolveAssetAddition(address(nvda), true);
        assertEq(partner.ASSET_POLICY().readyAt(address(nvda)), readyAt);
        assertFalse(partner.ASSET_POLICY().picked(address(nvda)));
    }

    function testEmptyConstructorNeverIncludesRegistryTokens() public {
        mandate.assets = new address[](0);
        IntentVault empty = _create();
        assertFalse(empty.ASSET_POLICY().picked(address(gold)));
        assertFalse(empty.ASSET_POLICY().picked(address(nvda)));
        vm.prank(curator);
        empty.setAsset(address(nvda), true);
        assertFalse(empty.ASSET_POLICY().picked(address(nvda)));
        assertEq(empty.ASSET_POLICY().readyAt(address(nvda)), block.timestamp + 10_800);
    }
}
