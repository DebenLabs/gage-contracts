// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {TokenBaseTest} from "../token/TokenBase.t.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {IDealVault, DealState} from "../../src/interfaces/IDealVault.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @notice Local coverage of the adapter's close and settle paths against the real legacy vault: `LoanClosed` on
/// both close paths, and `settleLegacy` surfacing the legacy vault's own grace and state errors.
contract GageLegacyAdapterTest is TokenBaseTest {
    GageV2Vault internal v2;
    GageLegacyAdapter internal bridge;
    address internal b0 = address(0xB0B);
    address internal l0 = address(0x1E0);

    function setUp() public override {
        super.setUp();
        bridge = new GageLegacyAdapter(address(this), vault, dealRewards, usdg);
        vm.startPrank(safe);
        registry.setFee(100);
        registry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        vm.stopPrank();
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        GageV2TokenRegistry cfg = new GageV2TokenRegistry(address(this), terms, address(this));
        cfg.setERC20Allowed(address(nvda), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        v2 = new GageV2Vault(cfg, IERC20(address(usdg)), IERC20(address(sgage)), treasury, 0, bridge);
        bridge.setEngine(address(v2));
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        v2.REWARDS().bindFunderGate(openGate);
        vm.startPrank(b0);
        nvda.approve(address(v2), type(uint256).max);
        usdg.approve(address(v2), type(uint256).max);
        vm.stopPrank();
        vm.prank(l0);
        usdg.approve(address(v2), type(uint256).max);
    }

    function _open(uint128 principal) internal returns (uint256 id) {
        nvda.mint(b0, 1e18);
        vm.prank(b0);
        id = v2.list(
            Collateral(Kind.ERC20, address(nvda), 1e18),
            principal,
            principal + principal / 10,
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        usdg.mint(l0, principal);
        vm.prank(l0);
        v2.fund(id, 4);
        assertEq(uint256(v2.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    function test_defaultThenSettleLegacyUsesLegacyVaultErrors() public {
        uint256 id = _open(1000e6);
        uint256 source = bridge.adapterId(address(v2), id);
        GageLegacyAdapter.Loan memory a = bridge.loan(source);
        assertEq(bridge.balanceOf(address(vault)), 1);
        // Before the close the adapter's own InvalidLoan guards it.
        vm.expectRevert(GageLegacyAdapter.InvalidLoan.selector);
        bridge.settleLegacy(source);
        V2Loan memory l = v2.getLoan(id);
        vm.warp(uint256(l.fundedAt) + l.term);
        vm.recordLogs();
        v2.finalizeDefault(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawClosed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == GageLegacyAdapter.LoanClosed.selector) {
                sawClosed = true;
                (bool repaid, uint40 at) = abi.decode(logs[i].data, (bool, uint40));
                assertFalse(repaid);
                assertEq(at, block.timestamp);
            }
        }
        assertTrue(sawClosed);
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.FUNDED));
        uint40 claimable = vault.claimableAt(a.legacyId);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, claimable));
        bridge.settleLegacy(source);
        vm.warp(claimable);
        bridge.settleLegacy(source);
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.CLAIMED));
        assertEq(bridge.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, a.legacyId));
        bridge.settleLegacy(source);
        // A nonexistent id.
        vm.expectRevert(GageLegacyAdapter.InvalidLoan.selector);
        bridge.settleLegacy(999);
    }

    function test_repayExactCashAndSettleOnRepaidReverts() public {
        uint256 id = _open(1000e6);
        uint256 source = bridge.adapterId(address(v2), id);
        GageLegacyAdapter.Loan memory a = bridge.loan(source);
        V2Loan memory l = v2.getLoan(id);
        usdg.mint(b0, l.cap);
        vm.recordLogs();
        vm.prank(b0);
        v2.reclaim(id, b0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawClosed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(bridge) && logs[i].topics[0] == GageLegacyAdapter.LoanClosed.selector) {
                sawClosed = true;
                (bool repaid,) = abi.decode(logs[i].data, (bool, uint40));
                assertTrue(repaid);
            }
        }
        assertTrue(sawClosed);
        assertEq(bridge.loan(source).closedAt, block.timestamp);
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.RECLAIMED));
        assertEq(usdg.balanceOf(address(bridge)), 0);
        assertEq(usdg.balanceOf(a.borrower), 0);
        assertEq(usdg.balanceOf(a.lender), 0);
        assertEq(bridge.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, a.legacyId));
        bridge.settleLegacy(source);
        // A second close through the engine path is refused.
        vm.prank(address(v2));
        vm.expectRevert(GageLegacyAdapter.InvalidLoan.selector);
        bridge.repay(id);
        vm.prank(address(v2));
        vm.expectRevert(GageLegacyAdapter.InvalidLoan.selector);
        bridge.finalizeDefault(id);
        vm.prank(address(0xBAD));
        vm.expectRevert(GageLegacyAdapter.NotAuthorized.selector);
        bridge.repay(id);
    }

    function test_bridgedLedgerNamesItsBridgeAndTakesNoDonations() public {
        GageV2Rewards ledger = v2.REWARDS();
        assertEq(address(ledger.BRIDGE()), address(bridge));
        assertEq(ledger.VAULT(), address(v2));
        vm.prank(treasury);
        sgage.approve(address(ledger), 1e18);
        vm.prank(treasury);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        ledger.fund(1e18);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        ledger.fund(0);
        // A loan that never activated has nothing to claim and never reaches the adapter.
        vm.expectRevert(GageV2Rewards.NothingToClaim.selector);
        ledger.claim(1, address(this));
        // An activated loan's claim is paid through the adapter's record of that loan.
        uint256 id = _open(1000e6);
        vm.warp(block.timestamp + 7 days);
        uint256 owed = ledger.claimable(id, b0);
        assertGt(owed, 0);
        vm.prank(b0);
        ledger.claim(id, b0);
        uint256 paid = sgage.balanceOf(b0);
        assertGt(paid, 0);
        assertEq(bridge.loan(bridge.adapterId(address(v2), id)).paid, paid);
        assertEq(ledger.claimable(id, b0), owed - paid);
    }

    function test_constructorWithNoCodeRewardsReverts() public {
        vm.expectRevert();
        new GageLegacyAdapter(address(this), vault, DealRewards(address(0xDEAD)), usdg);
        vm.expectRevert();
        new GageLegacyAdapter(address(this), IDealVault(address(0xBEEF)), dealRewards, usdg);
        vm.expectRevert(GageLegacyAdapter.InvalidConfiguration.selector);
        new GageLegacyAdapter(address(this), vault, dealRewards, IERC20(address(0xCAFE)));
    }
}
