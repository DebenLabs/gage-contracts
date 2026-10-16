// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2VaultBase} from "./GageV2Vault.t.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {IFunderGate} from "../../src/interfaces/IFunderGate.sol";
import {V2State, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {MockFunderGate} from "../mocks/MockFunderGate.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @notice Vaults-only lending: an engine lends to no one until the registry's owner binds a funder gate on its ledger
/// (D47); from then on only the accounts the gate names take lender quarters, by funding a listing or by buying a
/// listed position. Nothing else changes.
contract GageV2FunderGateTest is GageV2VaultBase {
    MockFunderGate internal gate;
    address internal vaultA = makeAddr("partner vault A");
    address internal vaultB = makeAddr("partner vault B");
    address internal vaultC = makeAddr("partner vault C");
    address internal router = makeAddr("entry router");

    /// @dev The partner vaults and the entry router hold credits too.
    function _extraCashHolders() internal view override returns (address[] memory holders) {
        holders = new address[](4);
        (holders[0], holders[1], holders[2], holders[3]) = (vaultA, vaultB, vaultC, router);
    }

    /// @dev This suite binds its own gate, so the engine starts unbound.
    function _opensToEveryone() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        gate = new MockFunderGate();
        gate.set(vaultA, true);
        gate.set(vaultB, true);
        gate.set(vaultC, true);
        address[3] memory payers = [vaultA, vaultB, router];
        for (uint256 i; i < payers.length; ++i) {
            usdg.mint(payers[i], 1_000_000e6);
            vm.prank(payers[i]);
            usdg.approve(address(vault), type(uint256).max);
        }
    }

    function _bind() internal {
        rewards.bindFunderGate(gate);
    }

    /// @dev vaultA holds every quarter of an active loan and offers them all.
    function _heldByVault() internal returns (uint256 id, V2LenderAsk memory ask) {
        id = _list(1000e6, 1100e6, 100e18);
        vm.prank(vaultA);
        vault.fund(id, 4);
        vm.warp(block.timestamp + 1 days);
        vm.prank(vaultA);
        vault.setLenderAsk(id, 15, 1050e6, uint40(block.timestamp + 1 hours), 100);
        ask = vault.getLenderAsk(id, vaultA);
    }

    function _split(V2LenderAsk memory ask, address[4] memory recipients)
        internal
        pure
        returns (V2LenderSplit memory p)
    {
        uint128[4] memory none;
        p = V2LenderSplit(ask.seller, ask.slots, ask.price, ask.feeBps, ask.nonce, recipients, none);
    }

    function test_unboundEngineLetsNoAccountLend() public {
        assertEq(address(rewards.funderGate()), address(0));
        registry.setRouter(router, true);
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fund(id, 1);
        vm.prank(vaultA);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fund(id, 4);
        vm.prank(router);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fundFor(id, 1, vaultA);
        assertEq(vault.getLoan(id).filled, 0, "nothing committed");
        _assertCash();
    }

    function test_onlyTheRegistryOwnerBindsAndOnlyOnce() public {
        vm.prank(buyer);
        vm.expectRevert(GageV2Rewards.NotAuthorized.selector);
        rewards.bindFunderGate(gate);

        vm.expectEmit(address(rewards));
        emit GageV2Rewards.FunderGateBound(address(gate));
        _bind();
        assertEq(address(rewards.funderGate()), address(gate));

        MockFunderGate other = new MockFunderGate();
        vm.expectRevert(GageV2Rewards.NotAuthorized.selector);
        rewards.bindFunderGate(other);
        vm.expectRevert(GageV2Rewards.NotAuthorized.selector);
        rewards.bindFunderGate(gate);
        assertEq(address(rewards.funderGate()), address(gate), "bound for good");
    }

    function test_bindRefusesAnAccountWithoutCode() public {
        vm.expectRevert(GageV2Rewards.NotAuthorized.selector);
        rewards.bindFunderGate(IFunderGate(makeAddr("not a contract")));
        assertEq(address(rewards.funderGate()), address(0));
    }

    function test_boundEngineRefusesWalletFunding() public {
        _bind();
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fund(id, 1);

        vm.prank(vaultA);
        vault.fund(id, 3);
        vm.prank(vaultB);
        vault.fund(id, 1);
        assertEq(uint8(vault.getLoan(id).state), uint8(V2State.ACTIVE));
        assertEq(vault.unitsOf(id, vaultA), 3);
        assertEq(vault.unitsOf(id, vaultB), 1);
        _assertCash();
    }

    function test_boundEngineRefusesRouterFundingForAWallet() public {
        registry.setRouter(router, true);
        _bind();
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(router);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fundFor(id, 1, lender[0]);

        vm.prank(router);
        vault.fundFor(id, 1, vaultA);
        assertEq(vault.unitsOf(id, vaultA), 1);
    }

    function test_nothingIsCommittedBeforeBindingAndVaultsLendAfter() public {
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fund(id, 1);
        _bind();
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.fund(id, 1);
        vm.prank(vaultA);
        vault.fund(id, 4);
        assertEq(uint8(vault.getLoan(id).state), uint8(V2State.ACTIVE));
        assertEq(vault.unitsOf(id, lender[0]), 0, "no wallet ever held a quarter");
        assertEq(vault.unitsOf(id, vaultA), 4);
    }

    function test_boundEngineRefusesALenderSaleToAWallet() public {
        _bind();
        (uint256 id, V2LenderAsk memory ask) = _heldByVault();
        vm.prank(buyer);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.buyLenderSplit(id, _split(ask, [buyer, buyer, buyer, buyer]));

        vm.prank(buyer);
        vault.buyLenderSplit(id, _split(ask, [vaultB, vaultB, vaultB, vaultB]));
        assertEq(vault.unitsOf(id, vaultB), 4, "a payer may deliver the bundle to a vault");
        _assertCash();
    }

    function test_boundEngineRefusesASplitWithAnyWalletQuarter() public {
        _bind();
        (uint256 id, V2LenderAsk memory ask) = _heldByVault();
        vm.prank(buyer);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        vault.buyLenderSplit(id, _split(ask, [vaultB, vaultB, lender[0], vaultB]));

        vm.prank(buyer);
        vault.buyLenderSplit(id, _split(ask, [vaultB, vaultB, vaultC, vaultB]));
        assertEq(vault.unitsOf(id, vaultB), 3);
        assertEq(vault.unitsOf(id, vaultC), 1);
    }

    function test_quartersOutsideTheAskAreNotChecked() public {
        _bind();
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(vaultA);
        vault.fund(id, 4);
        vm.prank(vaultA);
        vault.setLenderAsk(id, 3, 520e6, uint40(block.timestamp + 1 hours), 100);
        V2LenderAsk memory ask = vault.getLenderAsk(id, vaultA);
        vm.prank(buyer);
        vault.buyLenderSplit(id, _split(ask, [vaultB, vaultB, lender[0], lender[1]]));
        assertEq(vault.unitsOf(id, vaultB), 2);
        assertEq(vault.unitsOf(id, vaultA), 2);
    }

    function test_pauseStillComesFirst() public {
        _bind();
        uint256 id = _list(1000e6, 1100e6, 100e18);
        registry.pauseNewDeals(true);
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Rewards.Paused.selector);
        vault.fund(id, 1);
        vm.prank(vaultA);
        vm.expectRevert(GageV2Rewards.Paused.selector);
        vault.fund(id, 1);
    }

    function test_anyoneCanAskWhoMayLend() public {
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        rewards.requireFunder(lender[0]);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        rewards.requireFunder(vaultA);
        _bind();
        rewards.requireFunder(vaultA);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        rewards.requireFunder(lender[0]);
    }
}
