// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TokenBaseTest} from "../token/TokenBase.t.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {IDealVault, DealState} from "../../src/interfaces/IDealVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @notice 1-day loans through the legacy bridge: they activate, mirror as 1-day legacy deals, and earn from the
/// weekly pot's short (under 21 days) budget at the 7-day rate, exactly as `DealRewards` buckets them.
contract GageLegacyAdapterOneDayTest is TokenBaseTest {
    uint32 internal constant T1 = 1 days;

    GageV2Vault internal v2;
    GageLegacyAdapter internal bridge;
    address internal b0 = address(0xB0B);
    address internal l0 = address(0x1E0);

    function setUp() public override {
        super.setUp();
        bridge = new GageLegacyAdapter(address(this), vault, dealRewards, usdg);
        uint32[] memory legacyTerms = new uint32[](3);
        legacyTerms[0] = T1;
        legacyTerms[1] = T7;
        legacyTerms[2] = T21;
        vm.startPrank(safe);
        registry.setFee(100);
        registry.setTerms(legacyTerms);
        registry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        vm.stopPrank();
        GageV2TokenRegistry cfg = new GageV2TokenRegistry(address(this), legacyTerms, address(this));
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

    function _open(uint128 principal, uint32 term) internal returns (uint256 id) {
        nvda.mint(b0, 1e18);
        vm.prank(b0);
        id = v2.list(
            Collateral(Kind.ERC20, address(nvda), 1e18),
            principal,
            principal + principal / 10,
            term,
            uint40(block.timestamp + 1 days),
            true
        );
        usdg.mint(l0, principal);
        vm.prank(l0);
        v2.fund(id, 4);
    }

    function test_oneDayLoanActivatesAsAOneDayLegacyDeal() public {
        uint256 id = _open(1000e6, T1);
        V2Loan memory l = v2.getLoan(id);
        assertEq(uint256(l.state), uint256(V2State.ACTIVE), "active");
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        assertEq(a.term, T1, "adapter term");
        assertEq(vault.getDeal(a.legacyId).term, T1, "legacy term");
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.FUNDED), "legacy funded");
    }

    function test_oneDayQuotesTheSevenDayRateFromTheShortBucket() public view {
        (uint128 b1, uint128 l1) = bridge.quote(T1, 10e6);
        (uint128 b7, uint128 l7) = bridge.quote(T7, 10e6);
        (uint128 b21, uint128 l21) = bridge.quote(T21, 10e6);
        assertGt(uint256(b1) + l1, 0, "1-day earns");
        assertEq(b1, b7, "borrower: 7-day rate");
        assertEq(l1, l7, "lender: 7-day rate");
        // The fixture's 21-day rate is higher than its 7-day one, so a 1-day loan is never priced at it.
        assertGt(uint256(b21) + l21, uint256(b7) + l7, "21-day rate");
    }

    function test_oneDayRewardsComeOutOfTheShortBudget() public {
        uint256 epoch = emissions.currentEpoch();
        uint256 shortBefore = emissions.reserved(epoch, T7);
        uint256 longBefore = emissions.reserved(epoch, T21);
        uint256 id = _open(1000e6, T1);
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        (uint128 total,,) = dealRewards.rewardOf(a.legacyId);
        assertGt(total, 0, "registered");
        assertEq(emissions.reserved(epoch, T7) - shortBefore, total, "short budget");
        assertEq(emissions.reserved(epoch, T1), emissions.reserved(epoch, T7), "1-day is the short bucket");
        assertEq(emissions.reserved(epoch, T21), longBefore, "21-day budget untouched");
        assertEq(uint256(a.borrowerReward) + a.lenderReward, total, "allocation");
    }

    function test_oneDayRewardsAreFullyClaimableAfterTheDay() public {
        uint256 id = _open(1000e6, T1);
        GageV2Rewards ledger = v2.REWARDS();
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        vm.warp(block.timestamp + T1);
        assertEq(ledger.claimable(id, b0), a.borrowerReward, "borrower drip done");
        vm.prank(b0);
        ledger.claim(id, b0);
        assertEq(sgage.balanceOf(b0), a.borrowerReward, "paid");
    }

    function test_oneDayLoanRepaysThroughTheBridge() public {
        uint256 id = _open(1000e6, T1);
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        V2Loan memory l = v2.getLoan(id);
        vm.warp(uint256(l.fundedAt) + T1 - 1);
        usdg.mint(b0, l.cap);
        vm.prank(b0);
        v2.reclaim(id, b0);
        assertEq(uint256(v2.getLoan(id).state), uint256(V2State.REPAID), "repaid");
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.RECLAIMED), "legacy reclaimed");
        assertEq(usdg.balanceOf(address(bridge)), 0, "bridge holds nothing");
    }

    function test_oneDayLoanDefaultsAndSettlesThroughTheBridge() public {
        uint256 id = _open(1000e6, T1);
        uint256 source = bridge.adapterId(address(v2), id);
        GageLegacyAdapter.Loan memory a = bridge.loan(source);
        V2Loan memory l = v2.getLoan(id);
        vm.warp(uint256(l.fundedAt) + T1);
        v2.finalizeDefault(id);
        assertEq(uint256(v2.getLoan(id).state), uint256(V2State.DEFAULTED), "defaulted");
        // The legacy deal waits for the legacy vault's own grace, as every bridged loan's does.
        uint40 claimable = vault.claimableAt(a.legacyId);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, claimable));
        bridge.settleLegacy(source);
        vm.warp(claimable);
        bridge.settleLegacy(source);
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.CLAIMED), "legacy claimed");
    }

    function test_otherShortTermsStayRefused() public {
        uint32[] memory terms = new uint32[](4);
        terms[0] = T1;
        terms[1] = 2 days;
        terms[2] = T7;
        terms[3] = T21;
        vm.prank(safe);
        registry.setTerms(terms);
        GageV2TokenRegistry(address(v2.REGISTRY())).setTerms(terms);
        (uint128 b, uint128 l) = bridge.quote(2 days, 10e6);
        assertEq(uint256(b) + l, 0, "no quote");
        nvda.mint(b0, 1e18);
        vm.prank(b0);
        uint256 id = v2.list(
            Collateral(Kind.ERC20, address(nvda), 1e18), 1000e6, 1100e6, 2 days, uint40(block.timestamp + 1 days), true
        );
        usdg.mint(l0, 1000e6);
        vm.prank(l0);
        vm.expectRevert(GageLegacyAdapter.InvalidLoan.selector);
        v2.fund(id, 4);
    }
}
