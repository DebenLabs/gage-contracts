// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice Early repayment must not move value between holders, whatever the order of entry, repayment and settlement.
/// @dev Under D51 a loan booked before the end of its term books what the share price already counted for it and
/// opens a USDG earnings claim for the rest, shared by the loan-days of the shares exposed to it (S2-A1 to A4 as they
/// stand after D51; the D29 schedule these cases once checked is gone).
contract IntentAccountingTest is IntentAccountingBaseTest {
    uint40 internal constant NO_DEADLINE = type(uint40).max;
    /// @dev What the review loan earns by the clock over three days, and the rest of its 90 net, paid as the claim.
    uint256 internal constant EARNED = 12_857_142;
    uint256 internal constant UNEARNED = 90e6 - EARNED;

    // ------------------------------------------------------------ S2-A1: no capture, either ordering

    /// @dev The documented case: entry after the core repayment and before its settlement.
    function testEntryAfterRepaymentBeforeSettlementCapturesNothing() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        uint256 before_ = usdg.balanceOf(bob);
        _enter(bob, 10_000e6);
        vm.prank(bob);
        partner.settle(_ids(id));
        _leave(bob);
        uint256 after_ = usdg.balanceOf(bob);
        emit log_named_uint("entrant balance before, USDG raw", before_);
        emit log_named_uint("entrant balance after, USDG raw", after_);
        assertLe(after_, before_, "entrant captured paid interest");
    }

    /// @dev The reordering: entry first, then the repayment, settlement and exit in the same block. A borrower
    /// controls this order; its money is in the loan for no time, so it holds no loan-days.
    function testEntryBeforeRepaymentCapturesNothing() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        uint256 before_ = usdg.balanceOf(bob);
        _enter(bob, 10_000e6);
        _repay(id);
        _book(id);
        _leave(bob);
        uint256 after_ = usdg.balanceOf(bob);
        emit log_named_uint("entrant balance before, USDG raw", before_);
        emit log_named_uint("entrant balance after, USDG raw", after_);
        assertLe(after_, before_, "entrant captured paid interest");
    }

    /// @dev An unbooked repayment is priced on the loan's clock, so leaving it out of a settle list gains nothing.
    function testExitWithoutSettlingTheRepaymentCapturesNothing() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _enter(bob, 10_000e6);
        _repay(id);
        assertLe(_exitAll(bob), 10_000e6);
        assertFalse(_ln(id).repaid);
    }

    /// @dev The booking keeps what the price counted in cash and moves the rest into a claim: the price moves by at
    /// most one raw unit, down, and the loan leaves the book at once.
    function testEarlyRepaymentSettlementDoesNotMoveSharePrice() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        uint256 assetsBefore = partner.totalAssets();
        uint256 claimBefore = _claimOf(alice);
        _book(id);
        assertLe(partner.totalAssets(), assetsBefore, "settlement raised priced assets");
        assertLe(assetsBefore - partner.totalAssets(), 1, "settlement moved priced assets");
        assertLe(claimBefore - _claimOf(alice), 1, "settlement moved the holder's claim");
        assertEq(assetsBefore, 10_000e6 + EARNED);
        LoanView memory v = _ln(id);
        assertTrue(v.repaid);
        assertTrue(v.settled);
        assertEq(partner.performingPrincipal(), 0);
        assertEq(partner.cash(), 9000e6 + REVIEW_CAP - 10e6 - UNEARNED);
        assertEq(partner.pocketCount(), 1);
        (uint256 loanId, address token, uint256 amount, uint256 supply,, uint64 snapshotId) = partner.pockets(1);
        assertEq(loanId, id);
        assertEq(token, address(usdg));
        assertEq(amount, UNEARNED);
        // One reading of the clock over the three days: their seconds, less the clock's virtual shares' part.
        uint256 moved = 3 days * 1e33 / (partner.totalSupply() + 1e12);
        assertEq(supply, 3 days * 1e33 - 1e12 * moved, "the window is the loan's three days");
        assertEq(snapshotId, 0);
        assertEq(partner.pocketLiability(address(usdg)), UNEARNED);
        assertApproxEqAbs(partner.pocketClaimable(1, alice), UNEARNED, 1, "the sole holder owns the whole claim");
    }

    // ------------------------------------------------------------ S2-A2: ownership by loan-days

    function testEarlyRepaymentIsBookedAtOnceWithTheRestAsAClaim() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        vm.warp(_startOf(id) + 12 days);
        assertEq(partner.totalAssets(), 10_000e6 + EARNED, "nothing more accrues on a repaid loan");
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.totalAssets(), 10_000e6 + EARNED);
        assertTrue(_ln(id).settled);
        assertApproxEqAbs(_leave(alice), 10_000e6 + REVIEW_NET, 2);
    }

    function testNoPauseAtTheOriginalMaturityAfterAnEarlyBooking() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        assertEq(partner.earliestMaturity(), NO_DEADLINE, "the booked loan still holds a maturity");
        vm.warp(_maturity(id));
        _enter(bob, 1000e6);
        vm.prank(alice);
        partner.redeem(1e18, 0);
    }

    function testSettleAfterAnEarlyBookingChangesNothing() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        uint256 cash = partner.cash();
        uint256 fees = partner.curatorFees() + partner.protocolFees();
        uint256 claim = partner.pocketClaimable(1, alice);
        vm.warp(block.timestamp + 5 days);
        uint256 assets = partner.totalAssets();
        _book(id);
        _book(id);
        assertEq(partner.cash(), cash);
        assertEq(partner.curatorFees() + partner.protocolFees(), fees);
        assertEq(partner.totalAssets(), assets);
        assertEq(partner.pocketCount(), 1);
        assertEq(partner.pocketClaimable(1, alice), claim);
    }

    /// @dev Zero supply: the last holder leaves with its price part and keeps its claim; the next depositor finds none.
    function testLastHolderExitAfterAnEarlyBookingLeavesNoWindfall() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        assertApproxEqAbs(_leave(alice), 10_000e6 + REVIEW_NET, 2);
        assertEq(partner.totalSupply(), 0);
        assertEq(partner.earliestMaturity(), NO_DEADLINE);
        uint256 shares = _enter(bob, 10_000e6);
        vm.warp(_maturity(id) + 1 days);
        assertLe(_exit(bob, shares), 10_000e6 + 2, "next depositor found a windfall");
        assertEq(_claimable(bob), 0);
    }

    /// @dev D51 replaces D29's forfeit: a holder who leaves after the booking keeps its loan-days' share, and the
    /// holder who stays gets only its own.
    function testExitingHolderKeepsItsShareOfTheEarlyRepayment() public {
        _enter(alice, 5000e6);
        _enter(bob, 5000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        uint256 aliceOut = _leave(alice);
        vm.warp(_maturity(id));
        _book(id);
        uint256 bobOut = _leave(bob);
        emit log_named_uint("left at the repayment, USDG raw", aliceOut);
        emit log_named_uint("stayed to the end of the term, USDG raw", bobOut);
        assertApproxEqAbs(aliceOut, 5000e6 + REVIEW_NET / 2, 2);
        assertApproxEqAbs(bobOut, 5000e6 + REVIEW_NET / 2, 2);
    }

    function testEntrantAfterEarlyBookingEarnsNothingFromTheRepaidLoan() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        uint256 shares = _enter(bob, 10_000e6);
        vm.warp(_startOf(id) + 12 days);
        assertLe(_exit(bob, shares), 10_000e6 + 1, "an entrant after the booking earned from the repaid loan");
        assertEq(_claimable(bob), 0);
    }

    /// @dev Pashov M-19. Repaid three days in and booked after the end of the term: pricing pauses until the booking,
    /// which prices the loan up to its repayment and opens the claim for the rest, as a prompt booking would have.
    function testRepaymentSettledAfterTermEndStillOpensItsClaim() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        vm.warp(_maturity(id) + 1 hours);
        vm.prank(alice);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        partner.redeem(1e18, 0);
        _book(id);
        LoanView memory v = _ln(id);
        uint256 counted = _scheduled(REVIEW_NET, 3 days, T21);
        assertTrue(v.settled);
        assertTrue(v.repaid);
        assertEq(partner.pocketCount(), 1);
        assertApproxEqAbs(partner.totalAssets(), 10_000e6 + counted, 1);
        assertApproxEqAbs(_claimable(alice), REVIEW_NET - counted, 1e3);
    }

    /// @dev Other lenders activated the loan and the borrower repaid before any settle saw it active: the clock never
    /// ran, so its whole return is the claim, over the window from the purchase to the repayment.
    function testRepaymentOfLoanNeverSeenActiveIsAClaimAtItsBooking() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21);
        _route(id, 2);
        _fill(id);
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        assertEq(partner.totalAssets(), 10_000e6);
        _book(id);
        assertEq(partner.totalAssets(), 10_000e6, "first sight of the repayment moved priced assets");
        (,, uint256 amount,,,) = partner.pockets(1);
        assertEq(amount, 45e6);
        assertApproxEqAbs(partner.pocketClaimable(1, alice), 45e6, 1);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.totalAssets(), 10_000e6);
    }

    // ------------------------------------------------------------ S2-A4: fees

    function testFeesAreBookedOnceAtRepaymentAndClaimableAtOnce() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        assertEq(partner.curatorFees(), 9e6);
        assertEq(partner.protocolFees(), 1e6);
        uint256 assets = partner.totalAssets();
        partner.claimFees();
        assertEq(usdg.balanceOf(curator), 9e6);
        assertEq(usdg.balanceOf(feeProcessor), 1e6);
        assertEq(partner.totalAssets(), assets);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.curatorFees() + partner.protocolFees(), 0, "fee charged again");
        assertEq(usdg.balanceOf(address(partner)), partner.cash() + partner.pocketLiability(address(usdg)));
        assertEq(partner.cash() + partner.pocketLiability(address(usdg)), 10_000e6 + REVIEW_NET);
    }

    /// @dev Pashov M-03. A curator recipient USDG refuses keeps its fee and does not hold up the protocol's. A claim
    /// that can pay nothing it owes reverts; once the recipient can receive, the next claim pays it.
    function testBlockedCuratorRecipientDoesNotHoldUpTheProtocolFee() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        usdg.setBlocked(curator, true);
        partner.claimFees();
        assertEq(usdg.balanceOf(feeProcessor), 1e6, "the protocol fee waited on the curator's");
        assertEq(partner.protocolFees(), 0);
        assertEq(partner.curatorFees(), 9e6, "a refused payment lost its balance");
        assertEq(usdg.balanceOf(address(partner)), partner.cash() + partner.pocketLiability(address(usdg)) + 9e6);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        partner.claimFees();
        usdg.setBlocked(curator, false);
        partner.claimFees();
        assertEq(usdg.balanceOf(curator), 9e6);
        assertEq(partner.curatorFees(), 0);
    }

    /// @dev The other way round: a protocol recipient USDG refuses does not hold up the curator's fee.
    function testBlockedProtocolRecipientDoesNotHoldUpTheCuratorFee() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + 3 days);
        _repay(id);
        _book(id);
        usdg.setBlocked(feeProcessor, true);
        partner.claimFees();
        assertEq(usdg.balanceOf(curator), 9e6, "the curator fee waited on the protocol's");
        assertEq(partner.curatorFees(), 0);
        assertEq(partner.protocolFees(), 1e6, "a refused payment lost its balance");
        usdg.setBlocked(feeProcessor, false);
        partner.claimFees();
        assertEq(usdg.balanceOf(feeProcessor), 1e6);
        assertEq(partner.protocolFees(), 0);
        // Nothing owed: a claim still succeeds and pays nothing.
        partner.claimFees();
    }

    // ------------------------------------------------------------ S2-A3: liquidity and defaults

    /// @dev An earnings claim is held outside `cash`: no fill can lend it, no exit can take it, and a later write-off
    /// cannot reach it. Everything the share price counts stays redeemable.
    function testEarningsClaimIsOutsideCashThroughALaterDefault() public {
        _enter(alice, 1500e6);
        _enter(bob, 500e6);
        uint256 first = _reviewLoan();
        vm.warp(_startOf(first) + 3 days);
        _repay(first);
        _book(first);
        assertEq(partner.cash(), 2000e6 + EARNED);
        assertEq(partner.pocketLiability(address(usdg)), UNEARNED);
        assertEq(partner.freeLiquidity(), 2000e6 + EARNED);
        assertEq(partner.freeLiquidity(), partner.totalAssets());
        uint256 second = _list(borrower, address(nvda), 100e18, 2000e6, 2200e6, T7);
        _route(second, UNITS);
        assertEq(partner.cash(), EARNED);
        assertEq(partner.freeLiquidity(), EARNED);
        // A new position fixes its opening holders through the purchase second.
        vm.warp(_startOf(second) + 1);
        uint256 tooMany = partner.convertToShares(EARNED + 1e6);
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(tooMany, 0);
        _exit(alice, partner.convertToShares(EARNED - 1e6));
        vm.warp(_maturity(second));
        _book(second);
        assertEq(uint8(_state(second)), uint8(V2State.DEFAULTED));
        assertEq(partner.totalAssets(), partner.cash());
        assertEq(partner.totalAssets(), partner.freeLiquidity());
        uint256 shares = _enter(carol, 1000e6);
        assertLe(_exit(carol, shares), 1000e6, "entrant mispriced after the write-off");
        assertEq(partner.pocketLiability(address(usdg)), UNEARNED, "the write-off reached the claim");
        assertApproxEqAbs(_claimAll(alice), UNEARNED * 3 / 4, 2, "alice's loan-days were mispaid");
        assertApproxEqAbs(_claimAll(bob), UNEARNED / 4, 2, "bob's loan-days were mispaid");
        _exitAll(alice);
        _exitAll(bob);
        assertLe(partner.cash(), 4, "value left behind beyond rounding");
    }

    /// @dev Right after an early booking a holder of almost the whole supply leaves in full: its price part now and
    /// its loan-days' share of the claim whenever it likes.
    function testHolderLeavesInFullAfterAnEarlyBooking() public {
        _enter(alice, 2000e6);
        _enter(bob, 3e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1 days);
        _repay(id);
        _book(id);
        uint256 out = _leave(alice);
        assertApproxEqAbs(out, 2000e6 + REVIEW_NET * 2000 / 2003, 2);
    }

    function testDefaultStillWritesOffAtTermEndAndBlocksStaleExits() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_maturity(id));
        vm.prank(alice);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        partner.redeem(100e18, 0);
        _book(id);
        assertEq(partner.totalAssets(), 9000e6);
        assertEq(partner.pocketCount(), 0);
        partner.recover(id);
        assertEq(partner.pocketClaimable(1, alice), 100e18);
    }

    // ------------------------------------------------------------ residual dust, measured

    /// @dev A late booking of another loan does not touch an early booking already made.
    function testDelayedSettlementOfAnotherLoanLeavesAnEarlyBookingAlone() public {
        _enter(alice, 10_000e6);
        uint256 long_ = _reviewLoan();
        uint256 short_ = _list(borrower, address(nvda), 100e18, 1000e6, 1050e6, T7);
        _route(short_, UNITS);
        vm.warp(block.timestamp + 3 days);
        _repay(long_);
        _book(long_);
        uint256 claim = partner.pocketClaimable(1, alice);
        vm.warp(_maturity(short_) + 1 hours);
        _book(short_);
        assertEq(partner.pocketClaimable(1, alice), claim, "a later booking moved the claim");
        vm.warp(_maturity(long_));
        uint256 before_ = partner.totalAssets();
        _book(long_);
        assertEq(partner.totalAssets(), before_, "the original maturity moved priced assets");
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Once the purchase second has passed, any same-block entry and exit around an early repayment returns at
    /// most the deposit. Entry during the purchase second is tested as a revert in IntentEarlyRepayCapture.
    function testFuzz_SameBlockRoundTripNeverProfits(uint256 amount, uint256 elapsed, uint8 order) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        elapsed = bound(elapsed, 1, T21 - 1);
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(block.timestamp + elapsed);
        uint256 shares;
        order = order % 4;
        if (order == 0) {
            shares = _enter(bob, amount);
            _repay(id);
            _book(id);
        } else if (order == 1) {
            _repay(id);
            shares = _enter(bob, amount);
            _book(id);
        } else if (order == 2) {
            _repay(id);
            _book(id);
            shares = _enter(bob, amount);
        } else {
            shares = _enter(bob, amount);
            _repay(id);
        }
        assertLe(_exit(bob, shares) + _claimAll(bob), amount);
    }

    /// @dev Two holders, an early repayment and exits at arbitrary times: together they receive their deposits and
    /// the net interest, to the unit of rounding.
    function testFuzz_EarlyRepaymentConservesValue(
        uint256 aliceIn,
        uint256 bobIn,
        uint256 repayAt,
        uint256 aliceOutAt,
        bool bobEntersLate
    ) public {
        aliceIn = bound(aliceIn, 2000e6, 1_000_000e6);
        // A holder of dust would leave the virtual shares a visible part of the interest; that offset is the share
        // conversion's own and is not what this case measures.
        bobIn = bound(bobIn, 100e6, 1_000_000e6);
        // A repayment in the fill second is booked from the next second (testRepaymentInTheFillSecondIsBooked...).
        repayAt = bound(repayAt, 1, T21 - 1);
        aliceOutAt = bound(aliceOutAt, repayAt, T21 - 1);
        _enter(alice, aliceIn);
        if (!bobEntersLate) _enter(bob, bobIn);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + repayAt);
        _repay(id);
        _book(id);
        if (bobEntersLate) _enter(bob, bobIn);
        vm.warp(_startOf(id) + aliceOutAt);
        uint256 out = _exitAll(alice);
        vm.warp(_maturity(id));
        _book(id);
        out += _exitAll(bob) + _claimAll(alice) + _claimAll(bob);
        assertLe(out, aliceIn + bobIn + REVIEW_NET);
        assertGe(out + 8, aliceIn + bobIn + REVIEW_NET);
        assertLe(partner.pocketLiability(address(usdg)), 4, "a claim was left unpaid beyond rounding");
    }

    /// @dev Bought in three purchases, the booked interest can exceed the fee-net cash by a unit per purchase; the
    /// settlement step absorbs that dust and nothing more.
    function testFuzz_TopUpRoundingIsBoundedAtSettlement(uint128 principal, uint16 premiumBps, uint32 elapsed) public {
        principal = uint128(bound(principal, 100e6, 5000e6));
        premiumBps = uint16(bound(premiumBps, 1, 2000));
        elapsed = uint32(bound(elapsed, 1, T21 - 1));
        _enter(alice, 10_000e6);
        uint128 cap = principal + uint128(uint256(principal) * premiumBps / 10_000) + 7;
        uint256 id = _list(borrower, address(nvda), 100e18, principal, cap, T21);
        _route(id, 1);
        _route(id, 1);
        _route(id, 2);
        vm.warp(block.timestamp + elapsed);
        _repay(id);
        uint256 before_ = partner.totalAssets();
        _book(id);
        uint256 after_ = partner.totalAssets();
        assertLe(after_, before_);
        assertLe(before_ - after_, 3);
    }
}
