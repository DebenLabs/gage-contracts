// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";

/// @notice Early-repayment capture under D29 (finding of 25 September 2026) and the rule that replaces it (D51).
/// @dev Under D29 a loan repaid before the end of its term left its unearned net interest in cash, out of the share
/// price, released on the original schedule to whoever held shares: a leaver forfeited its part and a 1 USDG newcomer
/// could collect it. Under D51 a loan's whole net return goes to the shares that were exposed to it while it was out,
/// in proportion to their share of the vault over the loan's actual life (its loan-days): the part the share price
/// already counted as it went, and the rest as a USDG claim opened when the repayment is booked, claimable at any time
/// and after a full exit. Fixture: the review loan (1,000 USDG, 21 days, 100 fixed cost, 10% fee, 90 net) of
/// IntentAccounting.t.sol, repaid three days in (12.857142 earned by then, the rest paid as the claim).
contract IntentEarlyRepayCaptureTest is IntentAccountingBaseTest {
    /// @dev Rounding allowance: a thousandth of a USDG, far under the 77 USDG at stake.
    uint256 internal constant DUST = 1e3;
    uint256 internal constant INCUMBENT = 10_000e6;
    uint256 internal constant ONE_USDG = 1e6;
    address internal newcomer = makeAddr("newcomer");

    function setUp() public override {
        super.setUp();
        usdg.mint(newcomer, 1_000_000e6);
        vm.prank(newcomer);
        usdg.approve(address(partner), MAX);
        // The borrower controls when it repays, so it is the natural entrant ahead of its own repayment.
        vm.prank(borrower);
        usdg.approve(address(partner), MAX);
    }

    // ------------------------------------------------------------ helpers

    /// @dev The review loan, fully funded by the vault, repaid and booked `elapsed` seconds into its term.
    function _repaidEarly(uint256 elapsed) internal returns (uint256 id) {
        id = _reviewLoan();
        vm.warp(_startOf(id) + elapsed);
        _repay(id);
        _book(id);
    }

    /// @dev No per-quarter reward minimum on a market purchase.
    function _none() internal pure returns (uint128[4] memory none) {}

    function _gain(uint256 out, uint256 in_) internal pure returns (uint256) {
        return out > in_ ? out - in_ : 0;
    }

    function _usdg(uint256 raw) internal pure returns (string memory) {
        string memory frac = vm.toString(raw % 1e6);
        while (bytes(frac).length < 6) {
            frac = string.concat("0", frac);
        }
        return string.concat(vm.toString(raw / 1e6), ".", frac);
    }

    function _log(string memory label, uint256 raw) internal pure {
        console2.log(string.concat(label, ": ", _usdg(raw), " USDG (", vm.toString(raw), " raw)"));
    }

    // ------------------------------------------------------------ a. the reported capture

    /// @dev a1. The report: a 1 USDG newcomer enters after the booking and before the incumbent leaves, the
    /// incumbent leaves in full, and at the original maturity the newcomer tries to take what the incumbent left.
    function testNewcomerBeforeIncumbentExitCollectsNoPaidInterest() public {
        _enter(alice, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        _enter(newcomer, ONE_USDG);
        uint256 incumbentOut = _leave(alice);
        vm.warp(_maturity(id));
        _book(id);
        uint256 newcomerOut = _leave(newcomer);

        console2.log("a1: 1 USDG newcomer enters after booking, before the incumbent's full exit");
        _log("  incumbent out, with its claim", incumbentOut);
        _log("  newcomer gain", _gain(newcomerOut, ONE_USDG));
        assertLe(_gain(newcomerOut, ONE_USDG), DUST, "a 1 USDG newcomer collected interest paid before it entered");
        assertApproxEqAbs(incumbentOut, INCUMBENT + REVIEW_NET, DUST, "the incumbent did not keep the loan's return");
    }

    /// @dev a2. Entry after the sole incumbent's exit finds nothing, and the incumbent keeps the whole return.
    function testNewcomerAfterSoleIncumbentExitFindsNothing() public {
        _enter(alice, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        uint256 incumbentOut = _leave(alice);
        _enter(newcomer, ONE_USDG);
        vm.warp(_maturity(id) + 1);
        _book(id);
        uint256 newcomerOut = _leave(newcomer);

        assertApproxEqAbs(incumbentOut, INCUMBENT + REVIEW_NET, 2, "the sole incumbent did not keep the return");
        assertLe(newcomerOut, ONE_USDG + DUST, "newcomer found a windfall");
    }

    /// @dev a3. Entry after the incumbent's exit while a small bystander still holds: nothing was forfeited, so
    /// neither a 1 USDG nor a 10,000 USDG entrant has anything to buy into, and the bystander keeps only its own part.
    function testNewcomerAfterIncumbentExitCannotBuyIntoForfeitedInterest() public {
        _enter(carol, 100e6);
        _enter(alice, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        uint256 incumbentOut = _leave(alice);
        uint256 snap = vm.snapshotState();

        _enter(newcomer, ONE_USDG);
        vm.warp(_maturity(id));
        _book(id);
        uint256 smallGain = _gain(_leave(newcomer), ONE_USDG);
        uint256 bystander = _gain(_leave(carol), 100e6);

        vm.revertToState(snap);
        _enter(newcomer, INCUMBENT);
        vm.warp(_maturity(id));
        _book(id);
        uint256 largeGain = _gain(_leave(newcomer), INCUMBENT);

        console2.log("a3: bystander holds 100 USDG; newcomer enters after the incumbent's exit");
        _log("  incumbent out, with its claim", incumbentOut);
        _log("  bystander gain", bystander);
        _log("  1 USDG newcomer gain", smallGain);
        _log("  10,000 USDG newcomer gain", largeGain);
        assertLe(smallGain, DUST, "a 1 USDG entrant bought into interest paid before it entered");
        assertLe(largeGain, DUST, "a 10,000 USDG entrant bought into interest paid before it entered");
        assertApproxEqAbs(incumbentOut, INCUMBENT + REVIEW_NET * 100 / 101, DUST, "incumbent lost its part");
        assertApproxEqAbs(bystander, REVIEW_NET / 101, DUST, "bystander took more than its own part");
    }

    // ------------------------------------------------------------ b. last-holder griefing

    /// @dev b. The incumbent leaves with the same whether or not a 1 USDG holder entered after the booking.
    function testDustHolderDoesNotChangeTheIncumbentsExit() public {
        _enter(alice, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        uint256 snap = vm.snapshotState();
        uint256 alone = _leave(alice);

        vm.revertToState(snap);
        _enter(newcomer, ONE_USDG);
        uint256 withDust = _leave(alice);
        vm.warp(_maturity(id));
        _book(id);
        uint256 dustOut = _leave(newcomer);

        assertApproxEqAbs(withDust, alone, 2, "a 1 USDG holder changed what the incumbent leaves with");
        assertLe(_gain(dustOut, ONE_USDG), DUST, "the dust holder gained");
    }

    // ------------------------------------------------------------ c. no dilution after the repayment

    /// @dev c. An entrant of the incumbent's size arrives right after the booking and holds to the original maturity.
    /// Its money was never in the loan, so it earns nothing from it.
    function testEqualEntrantAfterBookingEarnsNothingFromTheRepaidLoan() public {
        _enter(alice, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        _enter(bob, INCUMBENT);
        vm.warp(_maturity(id));
        _book(id);
        uint256 gain = _gain(_leave(bob), INCUMBENT);
        uint256 incumbentOut = _leave(alice);

        assertLe(gain, DUST, "an entrant after the repayment earned interest on a loan it bore no risk on");
        assertApproxEqAbs(incumbentOut, INCUMBENT + REVIEW_NET, DUST, "the incumbent was diluted");
    }

    // ------------------------------------------------------------ d. entry ahead of the repayment

    /// @dev d1. The S1 attack: the borrower enters, repays, settles and redeems in one block. Its money is in the loan
    /// for no time at all, so the round trip gains nothing.
    function testBorrowerEnteringBeforeItsRepaymentRoundTripGainsNothing() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _enter(borrower, INCUMBENT);
        _repay(id);
        _book(id);
        uint256 out = _leave(borrower);

        assertLe(out, INCUMBENT, "same-block round trip around the repayment profited");
    }

    /// @dev d2. The same entry, held to the original maturity: still no time in the loan, so still nothing.
    function testBorrowerEnteringBeforeItsRepaymentAndHoldingEarnsNothingFromIt() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _enter(borrower, INCUMBENT);
        _repay(id);
        _book(id);
        vm.warp(_maturity(id));
        _book(id);
        uint256 gain = _gain(_leave(borrower), INCUMBENT);
        uint256 incumbentOut = _leave(alice);

        assertLe(gain, DUST, "an entrant ahead of the repayment earned interest on a loan it bore no risk on");
        assertApproxEqAbs(incumbentOut, INCUMBENT + REVIEW_NET, DUST, "the incumbent lost part of the return");
    }

    /// @dev d3. Two equal holders at risk from before the loan was funded share its whole net return.
    function testHoldersAtRiskFromTheStartSharePaidInterestProRata() public {
        _enter(alice, INCUMBENT);
        _enter(bob, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        vm.warp(_maturity(id));
        _book(id);

        assertApproxEqAbs(_gain(_leave(bob), INCUMBENT), REVIEW_NET / 2, DUST, "equal holders did not share");
        assertApproxEqAbs(_gain(_leave(alice), INCUMBENT), REVIEW_NET / 2, DUST, "equal holders did not share");
    }

    // ------------------------------------------------------------ f. no forfeit between holders who bore the risk

    /// @dev f. Two equal holders from before funding; one leaves right after the booking and keeps its half.
    function testCoHolderLeavingAfterBookingKeepsItsShareOfPaidInterest() public {
        _enter(alice, INCUMBENT);
        _enter(bob, INCUMBENT);
        uint256 id = _repaidEarly(3 days);
        uint256 leaverOut = _leave(bob);
        vm.warp(_maturity(id));
        _book(id);
        uint256 stayerOut = _leave(alice);

        assertApproxEqAbs(leaverOut, INCUMBENT + REVIEW_NET / 2, DUST, "the leaver forfeited its share");
        assertApproxEqAbs(stayerOut, INCUMBENT + REVIEW_NET / 2, DUST, "the stayer took the leaver's share");
    }

    /// @dev f2. A holder who leaves before the repayment keeps the return of the days its money was in the loan.
    function testHolderLeavingBeforeTheRepaymentKeepsItsLoanDays() public {
        _enter(alice, INCUMBENT);
        _enter(bob, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1 days);
        uint256 bobOut = _exitAll(bob);
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        bobOut += _claimAll(bob);
        uint256 aliceOut = _leave(alice);

        // Each of the 3 loan-days is worth 30: bob held half of day 1, alice half of day 1 and all of days 2 and 3.
        assertApproxEqAbs(bobOut, INCUMBENT + REVIEW_NET / 6, 1e4, "the early leaver lost its loan-day");
        assertApproxEqAbs(aliceOut, INCUMBENT + REVIEW_NET * 5 / 6, 1e4, "the stayer's loan-days were mispaid");
    }

    // ------------------------------------------------------------ e. lender sales

    /// @dev e1. The reported sale case: a sale at 1,080 three days in (above the floor of book value plus half the
    /// interest still to come, Pashov L-01) books its gain above book as a claim for the shares that held the position
    /// by loan-days (D51); a 1 USDG newcomer after it finds nothing, even after the incumbent leaves.
    function testNewcomerCollectsNoSaleGainBookedBeforeItEntered() public {
        IntentLenderMarket market = partner.LENDER_MARKET();
        vm.prank(bob);
        usdg.approve(address(market), MAX);
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        // Read before the prank: `vm.prank` binds to the next external call, including this view.
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        market.list(id, 1080e6, deadline, 100);
        uint64 nonce = market.nonces(id);
        vm.prank(bob);
        uint256 proceeds = market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        _enter(newcomer, ONE_USDG);
        uint256 incumbentOut = _leave(alice);
        vm.warp(_maturity(id));
        uint256 newcomerOut = _leave(newcomer);

        uint256 net = proceeds - (proceeds - REVIEW_PRINCIPAL) / 10;
        assertLe(_gain(newcomerOut, ONE_USDG), DUST, "a newcomer collected a sale gain booked before it entered");
        assertApproxEqAbs(incumbentOut, INCUMBENT + net - REVIEW_PRINCIPAL, DUST, "the holder lost the sale's return");
    }

    /// @dev e2. A sale just above the floor, book value plus half the interest still to come (Pashov L-01): the same
    /// rule for the smallest gain a sale three days in can book, with a 1 USDG newcomer after it.
    function testSaleGainGoesToTheHoldersOfThePosition() public {
        IntentLenderMarket market = partner.LENDER_MARKET();
        vm.prank(bob);
        usdg.approve(address(market), MAX);
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        // Net of the core's 1% trade fee and the 10% manager fee on the profit, about 0.1 above that floor.
        uint128 price = 1067.94e6;
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        market.list(id, price, deadline, 100);
        uint64 nonce = market.nonces(id);
        vm.prank(bob);
        uint256 proceeds = market.buySplit(id, nonce, price, [bob, bob, bob, bob], _none());
        _enter(newcomer, ONE_USDG);
        uint256 incumbentOut = _leave(alice);
        vm.warp(_maturity(id));
        uint256 newcomerOut = _leave(newcomer);

        uint256 net = proceeds - (proceeds - REVIEW_PRINCIPAL) / 10;
        assertLe(_gain(newcomerOut, ONE_USDG), DUST, "a newcomer collected a sale gain booked before it entered");
        assertApproxEqAbs(incumbentOut, INCUMBENT + net - REVIEW_PRINCIPAL, DUST, "the holder lost the sale's return");
    }

    // ------------------------------------------------------------ g. the window of each loan

    /// @dev g1. A depositor who enters before the purchase shares the loan's return from its first second, including
    /// the borrower. A new position fixes those holders until the next second.
    function testBorrowerInTheLoanFromItsFirstSecondSharesByLoanDays() public {
        _enter(alice, INCUMBENT);
        _enter(borrower, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1);
        _repay(id);
        _book(id);
        uint256 borrowerOut = _leave(borrower);
        uint256 aliceOut = _leave(alice);

        assertApproxEqAbs(borrowerOut, INCUMBENT + REVIEW_NET / 2, DUST, "the borrower's loan-days were mispaid");
        assertApproxEqAbs(aliceOut, INCUMBENT + REVIEW_NET / 2, DUST, "the incumbent's loan-days were mispaid");
    }

    /// @dev g2 (Pashov M-01). The window and the accrual both end at the repayment the core records, not at the
    /// booking: an entrant after the repayment and before a booking five days late holds no loan-days and earns
    /// nothing, and the incumbent keeps the whole return.
    function testEntrantBetweenRepaymentAndLateBookingEarnsNothing() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _enter(newcomer, INCUMBENT);
        vm.warp(_startOf(id) + 8 days);
        _book(id);
        uint256 newcomerOut = _leave(newcomer);
        uint256 aliceOut = _leave(alice);

        assertEq(_claimable(newcomer), 0, "an entrant after the repayment holds a claim");
        assertLe(_gain(newcomerOut, INCUMBENT), DUST, "an entrant after the repayment earned the loan's rate");
        assertApproxEqAbs(aliceOut, INCUMBENT + REVIEW_NET, DUST, "the incumbent lost interest priced after repayment");
    }

    /// @dev g2b (Pashov M-19). A repayment recorded three days in and booked after the end of the term is still early:
    /// the price stops counting the loan at the repayment, the rest of its return is the incumbent's claim, and an
    /// entrant after the repayment earns nothing.
    function testEarlyRepaymentBookedAfterTheTermStillOpensItsClaim() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _enter(newcomer, INCUMBENT);
        vm.warp(_maturity(id) + 1 days);
        _book(id);

        uint256 counted = _scheduled(REVIEW_NET, 3 days, T21);
        assertTrue(_ln(id).repaid, "an early repayment booked late opened no claim");
        assertApproxEqAbs(_claimable(alice), REVIEW_NET - counted, DUST, "the claim is not the unpriced return");
        assertLe(_gain(_leave(newcomer), INCUMBENT), DUST, "an entrant after the repayment earned the loan's rate");
        assertApproxEqAbs(
            _leave(alice), INCUMBENT + REVIEW_NET, DUST, "the incumbent lost interest priced after repayment"
        );
    }

    /// @dev g2c (M-01). Entry during delayed booking pays the repayment-time price. Check each holder's value,
    /// including the entrant's principal, rather than only conservation across both holders.
    function testEntrantDuringLateBookingKeepsItsPrincipal() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        vm.warp(_startOf(id) + 5 days + 12 hours);
        _enter(newcomer, INCUMBENT);
        vm.warp(_startOf(id) + 8 days);
        _book(id);
        uint256 newcomerOut = _leave(newcomer);
        uint256 aliceOut = _leave(alice);

        assertApproxEqAbs(newcomerOut, INCUMBENT, 2, "the entrant paid for interest after repayment");
        assertApproxEqAbs(aliceOut, INCUMBENT + REVIEW_NET, DUST, "the incumbent's return changed");
    }

    /// @dev M-01. The public price and conversions stop at repayment, before anyone books the loan, and remain
    /// stable even past its original maturity. Booking only exposes the already-unpriced earnings claim.
    function testLivePriceStopsAtRepaymentBeforeBooking() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        uint256 interest = partner.accruedInterest();
        uint256 assets = partner.totalAssets();
        uint256 shares = partner.convertToShares(INCUMBENT);
        uint256 value = partner.convertToAssets(partner.balanceOf(alice));
        assertApproxEqAbs(interest, _scheduled(REVIEW_NET, 3 days, T21), 1);

        vm.warp(_startOf(id) + 8 days);
        assertEq(partner.accruedInterest(), interest);
        assertEq(partner.totalAssets(), assets);
        assertEq(partner.convertToShares(INCUMBENT), shares);
        assertEq(partner.convertToAssets(partner.balanceOf(alice)), value);
        assertFalse(_ln(id).settled);

        vm.warp(_maturity(id) + 1 days);
        assertEq(partner.totalAssets(), assets);
        _book(id);
        assertApproxEqAbs(partner.totalAssets(), assets, 1, "booking changed the price");
        assertEq(partner.accruedInterest(), 0);
        assertApproxEqAbs(_leave(alice), INCUMBENT + REVIEW_NET, DUST);
    }

    /// @dev M-01. Closing one loan must leave a neighboring active loan on its own schedule.
    function testActiveAccrualContinuesBesideAnUnbookedRepayment() public {
        _enter(alice, INCUMBENT);
        uint256 repaid = _reviewLoan();
        uint256 active = _reviewLoan();
        vm.warp(_startOf(repaid) + 3 days);
        _repay(repaid);
        vm.warp(_startOf(active) + 8 days);
        uint256 closedInterest = _scheduled(REVIEW_NET, 3 days, T21);
        uint256 activeInterest = _scheduled(REVIEW_NET, 8 days, T21);
        assertApproxEqAbs(partner.accruedInterest(), closedInterest + activeInterest, 2);
        uint256 assets = partner.totalAssets();
        _book(repaid);
        assertApproxEqAbs(partner.totalAssets(), assets, 1);
        assertApproxEqAbs(partner.accruedInterest(), activeInterest, 1);

        vm.warp(_startOf(active) + 9 days);
        assertApproxEqAbs(partner.accruedInterest(), _scheduled(REVIEW_NET, 9 days, T21), 1);
    }

    /// @dev M-01. A co-holder may leave before booking without receiving interest from the repayment delay.
    /// Both holders retain their own historical pocket entitlement after that exit.
    function testExitDuringLateBookingPreservesEachHoldersReturn() public {
        _enter(alice, INCUMBENT);
        _enter(bob, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        vm.warp(_startOf(id) + 5 days + 12 hours);
        uint256 bobOut = _exitAll(bob);
        assertFalse(_ln(id).settled);
        vm.warp(_startOf(id) + 8 days);
        _book(id);
        bobOut += _claimAll(bob);
        uint256 aliceOut = _leave(alice);
        assertApproxEqAbs(bobOut, INCUMBENT + REVIEW_NET / 2, DUST, "the leaver took the stayer's return");
        assertApproxEqAbs(aliceOut, INCUMBENT + REVIEW_NET / 2, DUST, "the stayer paid for the booking delay");
    }

    /// @dev Pashov M-79. A repayment harvested into `unassignedCash` before its booking is already priced: the loan
    /// stays in `performingPrincipal` with its interest to the repayment, so the harvest leaves `totalAssets` unchanged.
    /// A co-holder who leaves between the harvest and the booking ends level with the one who stays.
    function testExitAfterHarvestBeforeBookingPreservesEachHoldersReturn() public {
        _enter(alice, INCUMBENT);
        _enter(bob, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        uint256 assets = partner.totalAssets();
        partner.settle(new uint256[](0)); // harvest only
        assertEq(partner.unassignedCash(), REVIEW_CAP, "the repayment was not harvested");
        assertEq(partner.totalAssets(), assets, "the harvest moved the price");
        assertEq(partner.performingPrincipal(), REVIEW_PRINCIPAL, "the unbooked loan left the price");
        assertApproxEqAbs(partner.accruedInterest(), _scheduled(REVIEW_NET, 3 days, T21), 1);

        uint256 bobOut = _exitAll(bob);
        _book(id);
        bobOut += _claimAll(bob);
        uint256 aliceOut = _leave(alice);
        assertApproxEqAbs(bobOut, INCUMBENT + REVIEW_NET / 2, DUST, "the leaver was paid below its part");
        assertApproxEqAbs(aliceOut, INCUMBENT + REVIEW_NET / 2, DUST, "the stayer gained from the leaver's exit");
    }

    /// @dev Pashov M-79, the entry side. A depositor between the harvest and the booking pays the price that already
    /// counts the repaid loan: it keeps its principal and takes nothing of the repayment, and the incumbent keeps the
    /// whole return.
    function testEntrantAfterHarvestBeforeBookingTakesNothing() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        partner.settle(new uint256[](0)); // harvest only
        assertEq(partner.unassignedCash(), REVIEW_CAP);
        _enter(newcomer, INCUMBENT);
        vm.warp(_startOf(id) + 4 days);
        _book(id);

        assertApproxEqAbs(_leave(newcomer), INCUMBENT, 2, "the harvested repayment moved the entrant's value");
        assertApproxEqAbs(_leave(alice), INCUMBENT + REVIEW_NET, DUST, "the incumbent lost part of the return");
    }

    /// @dev g3b. An entrant after a same-second repayment must wait until the next second. Even if that entrant
    /// deposits before a later booking, the purchase-time holders keep the earnings pocket.
    function testEntrantInTheFillSecondAfterARepaymentTakesNothing() public {
        _enter(alice, INCUMBENT);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 id = _reviewLoan();
        _repay(id);
        vm.prank(newcomer);
        vm.expectRevert(IntentVault.SaleTooSoon.selector);
        partner.deposit(INCUMBENT, 0);
        vm.warp(_startOf(id) + 1);
        _enter(newcomer, INCUMBENT);
        vm.warp(_startOf(id) + 1 hours);
        _book(id);
        assertEq(_claimable(newcomer), 0, "an entrant after repayment held an earnings claim");
        uint256 latencyShare = REVIEW_NET * 1 hours / T21 / 2;
        assertLe(
            _gain(_leave(newcomer), INCUMBENT), latencyShare + DUST, "an entrant earned more than the latency rate"
        );
        assertGt(_claimable(alice), 0, "the purchase-time holder lost its earnings claim");
    }

    /// @dev H-03: the vault's first deposit may occur in the purchase second. A later deposit in that same second,
    /// after the repayment, must not dilute the lender's pocket even if settlement is delayed.
    function testFirstDepositSameSecondCannotBeDilutedAfterRepayment() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        vm.prank(newcomer);
        vm.expectRevert(IntentVault.SaleTooSoon.selector);
        partner.deposit(990_000e6, 0);
        _repay(id);

        vm.prank(newcomer);
        vm.expectRevert(IntentVault.SaleTooSoon.selector);
        partner.deposit(990_000e6, 0);
        uint256 shares = partner.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IntentVault.SaleTooSoon.selector);
        partner.redeem(shares / 2, 0);

        vm.warp(_startOf(id) + 1);
        _enter(newcomer, 990_000e6);
        vm.warp(_startOf(id) + 1 days);
        _book(id);
        assertEq(_claimable(newcomer), 0, "post-repayment shares entered the pocket");
        assertGt(_claimable(alice), 80e6, "the opening holder lost the pocket");
    }

    /// @dev Two deposits made before a purchase in the same timestamp second are both eligible. The fix needs no
    /// holder balance from the previous timestamp second.
    function testSameSecondOpeningDepositorsShareThePocket() public {
        _enter(alice, INCUMBENT);
        _enter(bob, INCUMBENT);
        uint256 id = _reviewLoan();
        _repay(id);
        vm.warp(_startOf(id) + 1);
        _book(id);
        assertApproxEqAbs(_leave(alice), INCUMBENT + REVIEW_NET / 2, DUST, "first holder lost its half");
        assertApproxEqAbs(_leave(bob), INCUMBENT + REVIEW_NET / 2, DUST, "second holder lost its half");
    }

    function testRepaymentInTheFillSecondIsBookedFromTheNextSecond() public {
        _enter(alice, INCUMBENT);
        uint256 id = _reviewLoan();
        _repay(id);
        _book(id);
        assertEq(partner.pocketCount(), 0, "booked with an empty window");
        vm.warp(_startOf(id) + 1);
        _book(id);
        assertApproxEqAbs(_leave(alice), INCUMBENT + REVIEW_NET, DUST, "the one-second loan was not paid out");
    }

    /// @dev g4. The shape of the reported fork case: a repayment about 12.2 days in (about 37.71 paid ahead).
    function testReportedShapeNewcomerFindsNothing() public {
        _enter(alice, INCUMBENT);
        uint256 id = _repaidEarly(12 days + 4.8 hours);
        _enter(newcomer, ONE_USDG);
        uint256 incumbentOut = _leave(alice);
        vm.warp(_maturity(id));
        uint256 newcomerOut = _leave(newcomer);

        assertLe(_gain(newcomerOut, ONE_USDG), DUST, "the reported capture is still open");
        assertApproxEqAbs(incumbentOut, INCUMBENT + REVIEW_NET, DUST, "the incumbent did not keep the return");
    }

    /// @dev g5. Three holders over a three-day loan: each loan-day is worth a third of the net return, split by the
    /// shares held that day. Alice 10,000 throughout; Carol 5,000 for days 1 and 2; Bob 5,000 from day 2.
    function testThreeLendersSplitByLoanDays() public {
        _enter(alice, INCUMBENT);
        _enter(carol, 5000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1 days);
        _enter(bob, 5000e6);
        vm.warp(_startOf(id) + 2 days);
        uint256 carolOut = _exitAll(carol);
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        carolOut += _claimAll(carol);
        uint256 bobOut = _leave(bob);
        uint256 aliceOut = _leave(alice);

        // Day 1: 2/3 alice, 1/3 carol. Day 2: 1/2, 1/4, 1/4. Day 3: 2/3 alice, 1/3 bob. Each day is worth 30.
        assertApproxEqAbs(aliceOut, INCUMBENT + 55e6, 5e4, "alice's loan-days were mispaid");
        assertApproxEqAbs(carolOut, 5000e6 + 17.5e6, 5e4, "carol's loan-days were mispaid");
        assertApproxEqAbs(bobOut, 5000e6 + 17.5e6, 5e4, "bob's loan-days were mispaid");
    }

    /// @dev g6. A claim is fixed at the booking: later deposits, exits and a pause change nothing, and it pays once.
    function testClaimIsFixedAtBookingAndPaysOnce() public {
        _enter(alice, INCUMBENT);
        _repaidEarly(3 days);
        uint256 before_ = _claimable(alice);
        _enter(bob, INCUMBENT);
        _exitAll(alice);
        vm.prank(curator);
        partner.setPaused(true);
        assertEq(_claimable(alice), before_, "a claim moved after the booking");
        assertGt(before_, 70e6, "no claim was opened");
        uint256 paid = _claimAll(alice);
        assertEq(paid, before_, "the claim did not pay what it showed");
        assertEq(_claimable(alice), 0, "a claim paid twice");
    }

    // ------------------------------------------------------------ h. extreme share counts

    /// @dev The earnings claim opened by the last booking.
    function _lastPocket() internal view returns (uint256 amount) {
        (,, amount,,,) = partner.pockets(partner.pocketCount());
    }

    function _claimsOfAll() internal view returns (uint256) {
        return _claimable(alice) + _claimable(bob) + _claimable(carol);
    }

    /// @dev A donor adds `amount` of backing, which lands only while the curator has paused the vault (Pashov I-01);
    /// the vault opens again afterwards.
    function _recapitalize(uint256 amount) internal {
        address donor = makeAddr("donor");
        usdg.mint(donor, amount);
        vm.prank(curator);
        partner.setPaused(true);
        vm.startPrank(donor);
        usdg.approve(address(partner), MAX);
        partner.recapitalize(amount);
        vm.stopPrank();
        vm.prank(curator);
        partner.setPaused(false);
    }

    /// @dev h1. Few shares, each worth a lot (the nightly invariant's shrunk sequence had value reach the vault while no
    /// share was outstanding): the holders still claim the whole of an earnings claim, none of it left to the virtual
    /// shares that only guard the price.
    function testFewSharesWorthALotClaimTheWholeEarnings() public {
        _enter(alice, ONE_USDG);
        _recapitalize(1_000_000e6);
        // Alice keeps shares worth a little more than the loan: about 1.1e15, a thousand times the virtual shares.
        _exit(alice, partner.balanceOf(alice) - partner.convertToShares(1100e6));
        uint256 id = _reviewLoan();
        assertLt(partner.totalSupply(), 2e15, "the fixture did not leave few shares");
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        uint256 amount = _lastPocket();
        assertGt(amount, 70e6, "no claim was opened");
        assertApproxEqAbs(_claimable(alice), amount, 1, "part of the claim went to no holder");
    }

    /// @dev h2. Many shares, each worth very little (new money after a near-total reserve loss), near the share ceiling
    /// and with the clock read every second: rounding the exposure clock leaves at most a millionth of the claim
    /// unowned. Past the ceiling it would leave more, so no deposit goes past it (h3).
    function testManySharesWorthLittleClaimTheWholeEarnings() public {
        _enter(alice, 1000e6);
        _invest(1000e6);
        reserve.simulateLoss(usdg.balanceOf(address(reserve)) - 20_000, address(0xdead));
        _enter(bob, 10_000e6);
        assertGt(partner.totalSupply(), 1e26, "the fixture did not leave many shares");
        uint256 id = _reviewLoan();
        for (uint256 i; i < 100; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            _enter(carol, ONE_USDG);
        }
        vm.warp(_startOf(id) + 200);
        _repay(id);
        _book(id);
        uint256 amount = _lastPocket();
        assertGt(amount, 80e6, "no claim was opened");
        assertApproxEqAbs(_claimsOfAll(), amount, amount / 1e6 + 3, "rounding the clock left part of the claim unowned");
    }

    /// @dev h3. A deposit that would take the share count past what the exposure clock resolves to a millionth reverts.
    function testDepositPastTheShareCeilingReverts() public {
        _enter(alice, 1000e6);
        _invest(1000e6);
        reserve.simulateLoss(usdg.balanceOf(address(reserve)) - 20, address(0xdead));
        vm.prank(bob);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        partner.deposit(100_000e6, 0);
    }

    /// @dev h4. Seconds in which few shares were out count for less, by the virtual shares' part of them: a holder
    /// alone with about 1.1e15 shares for half a window keeps its loan-days share of the claim to within 1e12/1.1e15.
    function testFewShareSecondsWeighLessOnlyByTheVirtualShares() public {
        _enter(alice, ONE_USDG);
        _recapitalize(1_000_000e6);
        _exit(alice, partner.balanceOf(alice) - partner.convertToShares(1100e6));
        uint256 id = _reviewLoan();
        uint256 few = partner.totalSupply();
        vm.warp(_startOf(id) + 1 days);
        _enter(bob, 900_000e6);
        vm.warp(_startOf(id) + 2 days);
        _repay(id);
        _book(id);
        uint256 amount = _lastPocket();
        // Loan-days: alice all of the first day and her part of the second; bob the rest of the second.
        uint256 aliceShare = partner.balanceOf(alice) * 1e18 / partner.totalSupply();
        uint256 ideal = amount / 2 + amount * aliceShare / 2e18;
        uint256 slack = ideal * 1e12 / few + DUST;
        assertApproxEqAbs(_claimable(alice), ideal, slack, "few-share seconds weighed beyond the virtual shares");
        assertApproxEqAbs(_claimable(alice) + _claimable(bob), amount, 2, "the claim was not whole");
    }
}
