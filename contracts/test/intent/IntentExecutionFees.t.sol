// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentFeeBreakdown} from "./IntentFeeBreakdown.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice S2-A4: the execution fee leaves priced assets once, is owed only when the fill completed, and the manager
/// fee is charged on the interest left after it. The fee amounts here are test inputs: the cap and the return floor
/// that size a real one are S3's, and the claim and its split are S4's.
contract IntentExecutionFeesTest is IntentAccountingBaseTest {
    function _held() internal view returns (uint256) {
        return partner.cash() + partner.curatorFees() + partner.protocolFees() + partner.executionPending()
            + partner.executionFees() + partner.unassignedCash() + partner.pocketLiability(address(usdg));
    }

    /// @dev R3's identity: 1,020 in, 1,000 lent at a 20 fee, 1,100 back at a 10% manager fee on the 80 left, 1,092 out.
    /// Accruing only 72 after expensing the 20 would end at 1,072. Repaid a second before the end of its term, the
    /// loan's last second of interest is the holder's earnings claim rather than priced (M-01).
    function testExecutionFeeIsExpensedOnceNotTwice() public {
        _enter(alice, 1020e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, UNITS, 20e6);
        assertEq(partner.totalAssets(), 1000e6, "the fee left priced assets at the purchase");
        assertEq(partner.cash(), 0);
        assertEq(partner.executionFees(), 20e6);
        assertEq(partner.executionPending(), 0);
        LoanView memory v = _ln(id);
        assertEq(v.interest, 92e6, "the loan earns its whole cost less the manager fee");
        assertEq(v.executionFee, 20e6);
        assertTrue(v.executionEarned);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.totalAssets() + partner.pocketLiability(address(usdg)), 1092e6);
        assertEq(partner.curatorFees(), 7.2e6);
        assertEq(partner.protocolFees(), 0.8e6);
        assertEq(partner.executionFees(), 20e6, "not charged again at the repayment");
        assertEq(usdg.balanceOf(address(partner)), 1092e6 + 8e6 + 20e6);
        assertApproxEqAbs(_leave(alice), 1092e6, 2);
    }

    /// @dev The FEE-MATH example end to end: 100 of interest, 15 of execution, 8.50 of performance fee split
    /// 7.65 and 0.85, 76.50 to depositors. Every amount the vault books is the library's.
    function testWorkedExampleMatchesTheSharedCalculation() public {
        (bool ok, IntentFeeBreakdown.Breakdown memory b) = IntentFeeBreakdown.breakdown(100e6, 85e6, 2000, 1000);
        assertTrue(ok);
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, UNITS, b.executionFee);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.executionFees(), 15e6);
        assertEq(partner.curatorFees(), b.managerNetFee);
        assertEq(partner.protocolFees(), b.protocolPerformanceFee);
        assertEq(partner.totalAssets() + partner.pocketLiability(address(usdg)), 10_000e6 + b.depositorInterest);
        assertEq(b.depositorInterest, 76.5e6);
    }

    /// @dev The fixture vault fixed the widest ceiling the code allows: half of what a purchase earns.
    function testExecutionFeeCannotExceedTheCeilingOnThePurchasesInterest() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        router.fund(partner, id, UNITS, 50e6 + 1);
        // Two quarters earn half the interest, so their ceiling is half as much.
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        router.fund(partner, id, 2, 25e6 + 1);
        _route(id, 2, 25e6);
        // The fee is an expense of the purchase; the loan earns its 50 less the manager's 10% of the 25 left.
        assertEq(_ln(id).interest, 50e6 - 2.5e6);
    }

    /// @dev R3-A2: the principal and the fee must both fit what is free to spend, buffer included. 100 of the assets
    /// sit in a reserve that pays nothing out now, so liquidity binds before the caps: with every asset in cash and
    /// 100% caps, the caps measured after the fee (Pashov M-24) are the same bound, and they are checked first.
    function testPrincipalAndFeeMustFitFreeLiquidity() public {
        _enter(alice, 1110e6);
        _invest(100e6);
        reserve.setLimits(type(uint256).max, 0, 0);
        assertEq(partner.freeLiquidity(), 1010e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        router.fund(partner, id, UNITS, 10e6 + 1);
        assertEq(partner.cash(), 1010e6);
        assertEq(partner.executionPending() + partner.executionFees(), 0);
        _route(id, UNITS, 10e6);
        assertEq(partner.cash(), 0);
    }

    /// @dev Both at or under the fixture's 100%: tightenings, in force at once (D53).
    function _capsAt(uint16 categoryBps, uint16 assetBps) internal {
        IntentLimits.setCategoryWeight(partner, IntentCategory.STOCK, categoryBps);
        IntentLimits.setLimits(partner, 1_000_000e6, assetBps, 0);
    }

    /// @dev Pashov M-24: the fee leaves priced assets while the whole principal is booked, so the caps are measured on
    /// what the purchase leaves. At 50% of 2,000, a 1,000 purchase with a 50 fee would hold 1,000 of a 975 cap.
    function testAPurchaseAtItsCapsIsRefusedWhenItsFeeWouldLeaveItAbove() public {
        _capsAt(5000, 5000);
        _enter(alice, 2000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, UNITS, 50e6);
        _route(id, UNITS, 0);
        assertEq(partner.categoryPrincipal(IntentCategory.STOCK), 5000 * partner.totalAssets() / 10_000);
        assertEq(partner.assetPrincipal(address(nvda)), 5000 * partner.totalAssets() / 10_000);
    }

    /// @dev Pashov M-26: the category weight alone. At 50% of 2,010, a 1,000 purchase fits with a 10 fee, which
    /// leaves exactly 2,000, and not with one raw unit more.
    function testTheCategoryWeightHoldsAfterThePurchasesOwnFee() public {
        _capsAt(5000, 10_000);
        _atTheCapAfterTheFee();
    }

    /// @dev Pashov M-27: the per-token share alone, on the same boundary.
    function testThePerTokenShareHoldsAfterThePurchasesOwnFee() public {
        _capsAt(10_000, 5000);
        _atTheCapAfterTheFee();
    }

    function _atTheCapAfterTheFee() internal {
        _enter(alice, 2010e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, UNITS, 10e6 + 1);
        _route(id, UNITS, 10e6);
        assertEq(partner.totalAssets(), 2000e6, "the fee left priced assets");
        assertEq(partner.categoryPrincipal(IntentCategory.STOCK), 1000e6);
        assertEq(partner.assetPrincipal(address(nvda)), 1000e6);
    }

    /// @dev Pashov M-24: whatever the weight, the size and the fee, a purchase the vault accepts leaves its own
    /// category and token within their caps on the assets that remain after it, and it refuses only one that would not.
    function testFuzz_APurchaseLeavesItsOwnCategoryAndTokenWithinTheirCaps(uint16 bps, uint256 slack, uint256 fee)
        public
    {
        bps = uint16(bound(bps, 500, 10_000));
        _capsAt(bps, bps);
        _enter(alice, 2000e6);
        // Sizes up to a tenth under the cap measured before any fee, where a fee can make the difference.
        uint256 room = 2000e6 * uint256(bps) / 10_000;
        uint256 principal = room - bound(slack, 0, room / 10);
        uint256 cap = principal * 11 / 10;
        uint256 id = _list(borrower, address(nvda), 100e18, uint128(principal), uint128(cap), T21);
        fee = bound(fee, 0, (cap - principal) / 2);
        bool fits = principal <= uint256(bps) * (2000e6 - fee) / 10_000;
        vm.prank(fillers[0]);
        if (!fits) vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, UNITS, fee);
        if (!fits) return;
        uint256 limit = uint256(bps) * partner.totalAssets() / 10_000;
        assertLe(partner.categoryPrincipal(IntentCategory.STOCK), limit);
        assertLe(partner.assetPrincipal(address(nvda)), limit);
    }

    /// @dev A purchase that does not complete the listing owes nothing yet; the fee is earned when the loan is
    /// first seen active.
    function testFeeIsPendingUntilTheLoanIsSeenActive() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 2, 10e6);
        assertEq(partner.executionPending(), 10e6);
        assertEq(partner.executionFees(), 0);
        assertEq(partner.totalAssets(), 10_000e6 - 10e6);
        assertFalse(_ln(id).executionEarned);
        _fill(id);
        _book(id);
        assertEq(partner.executionPending(), 0);
        assertEq(partner.executionFees(), 10e6);
        assertTrue(_ln(id).executionEarned);
        assertEq(partner.totalAssets(), 10_000e6 - 10e6, "earning the fee moves no priced assets");
    }

    function testFeeIsReturnedWhenTheBorrowerCancels() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 2, 10e6);
        vm.prank(borrower);
        core.cancelFunding(id);
        _book(id);
        _assertRefunded(id);
    }

    function testFeeIsReturnedWhenTheCommitmentIsWithdrawn() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 2, 10e6);
        vm.prank(curator);
        partner.withdrawCommitment(id);
        _book(id);
        _assertRefunded(id);
    }

    function testFeeIsReturnedWhenTheFundingDeadlinePasses() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 2, 10e6);
        vm.warp(core.getLoan(id).fundingDeadline);
        _book(id);
        assertEq(uint8(_state(id)), uint8(V2State.CANCELLED));
        _assertRefunded(id);
    }

    function _assertRefunded(uint256 id) internal view {
        assertEq(partner.executionPending(), 0);
        assertEq(partner.executionFees(), 0, "no fee is earned on a loan that never ran");
        assertEq(partner.totalAssets(), 10_000e6);
        assertEq(partner.cash(), 10_000e6);
        assertEq(_ln(id).executionFee, 0);
        assertTrue(_ln(id).settled);
        assertEq(usdg.balanceOf(address(partner)), _held());
    }

    /// @dev R3: on a default the execution fee stays an incurred cost and no manager fee is made from a return
    /// that never arrived.
    function testDefaultKeepsTheExecutionFeeAndChargesNoManagerFee() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, UNITS, 20e6);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(uint8(_state(id)), uint8(V2State.DEFAULTED));
        assertEq(partner.totalAssets(), 10_000e6 - 1000e6 - 20e6);
        assertEq(partner.executionFees(), 20e6);
        assertEq(partner.curatorFees() + partner.protocolFees(), 0);
    }

    /// @dev A default finalized on the core by someone else, before any settle saw the loan active.
    function testFeeIsEarnedWhenADefaultIsTheFirstSightOfTheLoan() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 2, 10e6);
        _fill(id);
        vm.warp(_maturity(id));
        core.finalizeDefault(id);
        _book(id);
        assertEq(partner.executionPending(), 0);
        assertEq(partner.executionFees(), 10e6);
        assertEq(partner.totalAssets(), 10_000e6 - 500e6 - 10e6);
    }

    /// @dev D29 with an execution fee: the booking of an early repayment still moves no priced assets, and the
    /// holder ends with the interest less both fees, the execution fee counted once.
    function testEarlyRepaymentWithAnExecutionFeeIsStillPriceNeutral() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, UNITS, 20e6);
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        uint256 before_ = partner.totalAssets();
        _book(id);
        assertLe(before_ - partner.totalAssets(), 1, "the booking moved priced assets");
        assertEq(before_, 10_000e6 - 20e6 + _scheduled(92e6, 3 days, T21));
        // D51: the 92 left after the fee is the loan's whole net return; what the clock had not counted is the claim.
        assertEq(partner.pocketLiability(address(usdg)), 92e6 - _scheduled(92e6, 3 days, T21));
        vm.warp(_maturity(id));
        _book(id);
        assertApproxEqAbs(partner.totalAssets() + _claimAll(alice), 10_000e6 - 20e6 + 92e6, 2);
        assertEq(usdg.balanceOf(address(partner)), _held());
    }

    /// @dev The ledgers are part of what the vault accounts for, so a harvest never mistakes a fee for stray cash.
    function testHarvestDoesNotCountExecutionFeesAsUnassignedCash() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 2, 10e6);
        partner.settle(new uint256[](0));
        assertEq(partner.unassignedCash(), 0);
        _fill(id);
        _book(id);
        partner.settle(new uint256[](0));
        assertEq(partner.unassignedCash(), 0);
        assertEq(usdg.balanceOf(address(partner)), _held());
    }

    /// @dev One purchase: the interest is exactly the execution fee, the performance fee and what depositors keep.
    function testFuzz_InterestIsSplitExactly(uint128 principal, uint16 premiumBps, uint256 feeSeed) public {
        principal = uint128(bound(principal, 100e6, 5000e6));
        premiumBps = uint16(bound(premiumBps, 1, 2000));
        _enter(alice, 10_000e6);
        uint128 cap = principal + uint128(uint256(principal) * premiumBps / 10_000) + 3;
        uint256 gross = cap - principal;
        uint256 executionFee = bound(feeSeed, 0, IntentFeeMath.executionCap(gross, partner.executionCapBps()));
        uint256 id = _list(borrower, address(nvda), 100e18, principal, cap, T21);
        _route(id, UNITS, executionFee);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        _book(id);
        uint256 performance = partner.curatorFees() + partner.protocolFees();
        assertEq(performance, IntentFeeMath.performanceFee(gross, executionFee, 1000));
        assertEq(partner.protocolFees(), performance * IntentFeeMath.PROTOCOL_SHARE_BPS / IntentFeeMath.BPS);
        assertEq(partner.executionFees(), executionFee);
        assertEq(
            partner.totalAssets() + partner.pocketLiability(address(usdg)) + executionFee + performance,
            10_000e6 + gross
        );
        assertEq(usdg.balanceOf(address(partner)), _held());
    }

    /// @dev Bought in three purchases with a fee each: the manager fee is charged once on the whole interest less
    /// every execution fee, and the booked interest differs from the cash by at most a unit per purchase.
    function testFuzz_TopUpsAggregateTheirExecutionFees(uint128 principal, uint16 premiumBps, uint256 feeSeed) public {
        principal = uint128(bound(principal, 100e6, 5000e6));
        premiumBps = uint16(bound(premiumBps, 1, 2000));
        _enter(alice, 10_000e6);
        uint128 cap = principal + uint128(uint256(principal) * premiumBps / 10_000) + 7;
        uint256 id = _list(borrower, address(nvda), 100e18, principal, cap, T21);
        uint256 total;
        uint8[3] memory units = [1, 1, 2];
        for (uint256 i; i < 3; ++i) {
            // A sixteenth of the interest is within half of what any one quarter earns, whatever the rounding.
            uint256 fee = bound(uint256(keccak256(abi.encode(feeSeed, i))), 0, (cap - principal) / 16);
            _route(id, units[i], fee);
            total += fee;
        }
        assertEq(partner.executionFees(), total, "earned when the last purchase activated the loan");
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        _book(id);
        uint256 performance = partner.curatorFees() + partner.protocolFees();
        assertEq(performance, IntentFeeMath.performanceFee(cap - principal, total, 1000));
        assertEq(
            partner.totalAssets() + partner.pocketLiability(address(usdg)) + total + performance,
            10_000e6 + (cap - principal)
        );
        assertLe(_ln(id).interest - (cap - principal - performance), 3);
    }
}
