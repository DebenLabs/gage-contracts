// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TokenBaseTest} from "./TokenBase.t.sol";
import {IDealRewards} from "../../src/interfaces/token/IDealRewards.sol";
import {IDrip} from "../../src/interfaces/token/IDrip.sol";
import {IEmissions} from "../../src/interfaces/token/IEmissions.sol";
import {Deal} from "../../src/interfaces/IDealVault.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {Drip} from "../../src/token/Drip.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";
import {MockLPRewards} from "../mocks/MockLPRewards.sol";

contract DealRewardsTest is TokenBaseTest {
    uint128 internal constant PRICE_A = 7960e6;

    function _feeFor(uint128 price) internal view returns (uint128) {
        return uint128((uint256(price) * registry.feeBps()) / 10_000);
    }

    function _expectedReward(uint128 fee, uint128 rate) internal pure returns (uint256 r) {
        r = (uint256(fee) * rate) / 1e6;
        uint256 cap = _cap(fee);
        if (r > cap) r = cap;
    }

    // ----------------------------------------------------------------- register

    function test_register_grantsTwoDripsOverTheTerm() public {
        (uint256 id,) = _fundDeal();
        Deal memory d = vault.getDeal(id);
        uint128 fee = _feeFor(PRICE_A);
        assertEq(d.fee, fee, "vault records the fee");
        uint256 reward = _expectedReward(fee, RATE7);
        assertLt(reward, _cap(fee), "rate, not the cap, binds here");

        vm.expectEmit(address(dealRewards));
        emit IDealRewards.Registered(
            id, 0, T7, fee, uint128(reward), uint128(reward / 2), uint128(reward - reward / 2), false
        );
        vm.prank(other);
        dealRewards.register(id);

        assertTrue(dealRewards.registered(id));
        (uint128 total, uint128 l, uint128 b) = dealRewards.rewardOf(id);
        assertEq(total, reward);
        assertEq(l + b, total);
        IDrip.DripAccount memory ld = drip.getDrip(lender, dealRewards.dripIdOf(id, lender));
        IDrip.DripAccount memory bd = drip.getDrip(borrower, dealRewards.dripIdOf(id, borrower));
        assertEq(ld.total, l);
        assertEq(bd.total, b);
        assertEq(ld.start, d.fundedAt);
        assertEq(ld.length, T7);
        assertEq(bd.start, d.fundedAt);
        assertEq(bd.length, T7);
        assertEq(sgage.balanceOf(address(drip)), reward, "the reward sits locked in Drip");
        assertEq(sgage.balanceOf(address(dealRewards)), 0, "DealRewards keeps nothing");
        assertEq(emissions.reserved(0, T7), reward);
        assertTrue(emissions.released(0), "registration released the epoch");
    }

    function test_register_capAt80PercentOfFee() public {
        vm.prank(safe);
        dealRewards.setEpochRates(0, 10_000e18, RATE21, PRICE, LENDER_SHARE);
        (uint256 id,) = _fundDeal();
        uint128 fee = _feeFor(PRICE_A);
        assertGt((uint256(fee) * 10_000e18) / 1e6, _cap(fee), "rate would exceed the cap");
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        assertEq(total, _cap(fee), "capped at 80% of the fee at the posted price");
    }

    function test_register_21DayTermUsesRate21() public {
        uint256 id = _list(borrower, address(nvda), 100e18, 8000e6, T21, 0);
        uint256 bidId = _bid(lender, id, PRICE_A);
        vm.prank(borrower);
        vault.accept(id, bidId);
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        assertEq(total, _expectedReward(_feeFor(PRICE_A), RATE21));
        assertEq(emissions.reserved(0, T21), total);
        assertEq(drip.getDrip(lender, dealRewards.dripIdOf(id, lender)).length, T21);
    }

    function test_register_shortTermUsesTheSevenDayBudgetAndRate() public {
        uint32[] memory terms = new uint32[](3);
        terms[0] = 1 days;
        terms[1] = T7;
        terms[2] = T21;
        vm.prank(safe);
        registry.setTerms(terms);
        uint256 id = _list(borrower, address(nvda), 100e18, 8000e6, 1 days, 0);
        uint256 bidId = _bid(lender, id, PRICE_A);
        vm.prank(borrower);
        vault.accept(id, bidId);
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        assertEq(total, _expectedReward(_feeFor(PRICE_A), RATE7));
        assertEq(emissions.reserved(0, T7), total);
        assertEq(drip.getDrip(lender, dealRewards.dripIdOf(id, lender)).length, 1 days);
    }

    function test_register_lenderShareSplit() public {
        vm.prank(safe);
        dealRewards.setEpochRates(0, RATE7, RATE21, PRICE, 7000);
        (uint256 id,) = _fundDeal();
        dealRewards.register(id);
        (uint128 total, uint128 l, uint128 b) = dealRewards.rewardOf(id);
        assertEq(l, (uint256(total) * 7000) / 10_000);
        assertEq(b, total - l);
    }

    function test_register_budgetExhaustionPartialThenZero() public {
        // Tiny posted price makes the 80% cap enormous, so the 7-day budget is what binds.
        vm.prank(safe);
        dealRewards.setEpochRates(0, 1e30, RATE21, 1, LENDER_SHARE);
        uint256 budget7 = emissions.dealBudget(0, T7);
        uint128 fee = _feeFor(PRICE_A);
        uint256 perDeal = (uint256(fee) * 1e18 * 8000) / 10_000; // cap at price 1
        assertLt(perDeal, budget7, "one deal fits");
        uint256 n = budget7 / perDeal; // full-reward deals before the budget runs out

        for (uint256 i = 0; i < n; ++i) {
            usdg.mint(lender, PRICE_A);
            (uint256 id,) = _fundDeal();
            dealRewards.register(id);
            (uint128 total,,) = dealRewards.rewardOf(id);
            assertEq(total, perDeal);
        }
        uint256 left = emissions.remaining(0, T7);
        assertLt(left, perDeal);

        (uint256 partialId,) = _fundDeal();
        vm.expectEmit(true, true, false, false, address(dealRewards));
        emit IDealRewards.Registered(partialId, 0, T7, fee, uint128(left), 0, 0, true);
        dealRewards.register(partialId);
        (uint128 partialTotal,,) = dealRewards.rewardOf(partialId);
        assertEq(partialTotal, left, "partial fill flagged as exhausted");
        assertEq(emissions.remaining(0, T7), 0);

        (uint256 zeroId,) = _fundDeal();
        dealRewards.register(zeroId);
        (uint128 zero,,) = dealRewards.rewardOf(zeroId);
        assertEq(zero, 0, "registered with zero once the budget is gone");
        assertTrue(dealRewards.registered(zeroId));

        (uint128 q, uint256 epoch, bool available, uint256 remaining) = dealRewards.quote(T7, fee);
        assertEq(q, 0);
        assertEq(epoch, 0);
        assertFalse(available, "This week's rewards are fully allocated");
        assertEq(remaining, 0);
    }

    function test_register_zeroFeeEarnsZero() public {
        vm.prank(safe);
        registry.setFee(0);
        (uint256 id,) = _fundDeal();
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        assertEq(total, 0);
        assertEq(sgage.balanceOf(address(drip)), 0);
    }

    function test_register_reclaimedAndClaimedDealsCount() public {
        (uint256 a,) = _fundDeal();
        vm.prank(borrower);
        vault.reclaim(a);
        dealRewards.register(a);
        (uint128 ta,,) = dealRewards.rewardOf(a);
        assertGt(ta, 0);

        (uint256 b,) = _fundDeal();
        vm.warp(vault.claimableAt(b));
        vm.prank(lender);
        vault.claim(b);
        dealRewards.register(b);
        (uint128 tb,,) = dealRewards.rewardOf(b);
        assertGt(tb, 0);
    }

    function test_register_rejectsUnfundedTwiceAndCancelled() public {
        uint256 listed = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(IDealRewards.DealNotFunded.selector, listed));
        dealRewards.register(listed);
        vm.prank(borrower);
        vault.cancel(listed);
        vm.expectRevert(abi.encodeWithSelector(IDealRewards.DealNotFunded.selector, listed));
        dealRewards.register(listed);
        vm.expectRevert(abi.encodeWithSelector(IDealRewards.DealNotFunded.selector, 999));
        dealRewards.register(999);

        (uint256 id,) = _fundDeal();
        dealRewards.register(id);
        vm.expectRevert(abi.encodeWithSelector(IDealRewards.AlreadyRegistered.selector, id));
        dealRewards.register(id);
    }

    function test_register_preLaunchDealDripsFromLaunch() public {
        (uint256 id,) = _fundDeal();
        uint40 fundedAt = vault.getDeal(id).fundedAt;
        vm.warp(fundedAt + 2 days);
        (Emissions e2, DealRewards dr2, Drip d2) = _secondSupplySide(uint40(block.timestamp + 1 days));
        vm.prank(safe);
        dr2.setEpochRates(0, RATE7, RATE21, PRICE, LENDER_SHARE);
        vm.warp(block.timestamp + 1 days);
        assertLt(fundedAt, e2.launchAt());
        dr2.register(id);
        IDrip.DripAccount memory ld = d2.getDrip(lender, dr2.dripIdOf(id, lender));
        assertGt(ld.total, 0);
        assertEq(ld.start, e2.launchAt(), "drips from launch, not from funding");
        assertEq(ld.length, T7);
    }

    function test_register_revertsBeforeLaunch() public {
        (uint256 id,) = _fundDeal();
        (, DealRewards dr2,) = _secondSupplySide(0);
        vm.expectRevert(IEmissions.NotLaunched.selector);
        dr2.register(id);
    }

    // ----------------------------------------------------------------- rates

    function test_rates_carryForwardToUnsetEpochs() public {
        vm.warp(emissions.epochStart(3));
        assertEq(dealRewards.effectiveRates(3).rate7, RATE7, "epoch 0 rates carry to epoch 3");
        vm.prank(safe);
        dealRewards.setEpochRates(5, 1e18, 2e18, PRICE, LENDER_SHARE);
        assertEq(dealRewards.effectiveRates(4).rate7, RATE7);
        assertEq(dealRewards.effectiveRates(5).rate7, 1e18);
        assertEq(dealRewards.effectiveRates(9).rate7, 1e18);
        (uint256 id,) = _fundDeal(); // funded in epoch 3
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        assertEq(total, _expectedReward(_feeFor(PRICE_A), RATE7));
        assertEq(emissions.reserved(3, T7), total);
    }

    function test_rates_noRatesMeansNoReward() public {
        (uint256 id,) = _fundDeal();
        (, DealRewards dr2, Drip d2) = _secondSupplySide(uint40(block.timestamp));
        // launched, but no rates posted at all
        vm.expectEmit(true, true, false, false, address(dr2));
        emit IDealRewards.Registered(id, 0, T7, vault.getDeal(id).fee, 0, 0, 0, true);
        dr2.register(id);
        (uint128 total,,) = dr2.rewardOf(id);
        assertEq(total, 0);
        assertEq(sgage2.balanceOf(address(d2)), 0);
    }

    function test_setEpochRates_validation() public {
        vm.startPrank(safe);
        vm.expectRevert(IDealRewards.InvalidRates.selector);
        dealRewards.setEpochRates(1, RATE7, RATE21, 0, LENDER_SHARE);
        vm.expectRevert(IDealRewards.InvalidRates.selector);
        dealRewards.setEpochRates(1, RATE7, RATE21, PRICE, 10_001);
        vm.warp(emissions.epochStart(2));
        vm.expectRevert(abi.encodeWithSelector(IDealRewards.RatesForPastEpoch.selector, 1));
        dealRewards.setEpochRates(1, RATE7, RATE21, PRICE, LENDER_SHARE);
        vm.expectEmit(address(dealRewards));
        emit IDealRewards.RatesSet(2, RATE7, RATE21, PRICE, LENDER_SHARE);
        dealRewards.setEpochRates(2, RATE7, RATE21, PRICE, LENDER_SHARE);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        dealRewards.setEpochRates(3, RATE7, RATE21, PRICE, LENDER_SHARE);
    }

    function test_quote_matchesRegistration() public {
        uint128 fee = _feeFor(PRICE_A);
        (uint128 q, uint256 epoch, bool available, uint256 remaining) = dealRewards.quote(T7, fee);
        assertEq(q, _expectedReward(fee, RATE7));
        assertEq(epoch, 0);
        assertTrue(available);
        assertEq(remaining, emissions.dealBudget(0, T7));
        (uint256 id,) = _fundDeal();
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        assertEq(total, q);
    }

    /// @dev T4: reward <= rate × fee, and zero fee earns zero, under fuzzed rates and fees.
    function testFuzz_T4_rewardNeverExceedsRateTimesFee(uint128 price, uint128 rate, uint16 bps) public {
        price = uint128(bound(price, 1e6, 100_000e6));
        rate = uint128(bound(rate, 0, 1000e18));
        bps = uint16(bound(bps, 0, 200));
        vm.startPrank(safe);
        registry.setFee(bps);
        dealRewards.setEpochRates(0, rate, rate, PRICE, LENDER_SHARE);
        vm.stopPrank();
        usdg.mint(lender, price);
        uint256 id = _list(borrower, address(nvda), 100e18, price, T7, 0);
        uint256 bidId = _bid(lender, id, price);
        vm.prank(borrower);
        vault.accept(id, bidId);
        dealRewards.register(id);
        (uint128 total,,) = dealRewards.rewardOf(id);
        uint128 fee = vault.getDeal(id).fee;
        assertLe(total, (uint256(fee) * rate) / 1e6, "T4: at most rate x fee");
        assertLe(total, _cap(fee), "at most 80% of the fee's value");
        if (fee == 0) assertEq(total, 0, "zero fee earns zero");
    }

    // ----------------------------------------------------------------- helpers

    SGAGE internal sgage2;

    /// @dev A second, independent supply side bound to the same vault. `launchAt == 0` leaves it unlaunched;
    ///      otherwise it launches at that time with the standard rates for epoch 0.
    function _secondSupplySide(uint40 launchAt) internal returns (Emissions e2, DealRewards dr2, Drip d2) {
        e2 = new Emissions(safe, address(this));
        sgage2 = new SGAGE(address(e2), treasury);
        d2 = new Drip(sgage2, address(this));
        MockLPRewards lp2 = new MockLPRewards(sgage2);
        dr2 = new DealRewards(vault, e2, d2, sgage2, 6, safe);
        e2.wire(sgage2, ILPRewards(address(lp2)), address(dr2));
        d2.setGrantors(address(dr2), address(lp2));
        if (launchAt != 0) {
            vm.prank(safe);
            e2.launch(launchAt);
        }
    }
}
