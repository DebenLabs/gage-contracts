// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {EarnBaseTest} from "./EarnBase.t.sol";
import {HybridVault, EarnLane} from "../src/HybridVault.sol";
import {HybridFees} from "../src/HybridFees.sol";
import {V2State} from "../src/v2/V2Types.sol";

/// @notice The pooled share vault: one price, loans at principal, side pockets, requests, unlocking and the vault mark.
contract HybridVaultTest is EarnBaseTest {
    uint256 internal constant ONE = 1e12; // shares per USDG unit at the initial price

    function setUp() public override {
        super.setUp();
        vm.prank(curator);
        hybrid.setFee(1000);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = hybrid.deposit(assets, 0);
    }

    function _fundLoan(uint128 principal) internal returns (uint256 id) {
        id = _listed(principal);
        _approve(id);
        hybrid.fund(id, type(uint256).max);
    }

    function _unlock() internal {
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK());
    }

    // ---------------------------------------------------------------- shares and the reserve

    function testDepositMintsSharesAtTheInitialPriceAndLaterAtTheCurrentPrice() public {
        assertEq(_deposit(lender, 1000e6), 1000e6 * ONE);
        assertEq(hybrid.totalAssets(), 1000e6);
        assertEq(hybrid.cash(), 1000e6);
        hybrid.investReserve(1000e6, 1);
        assertEq(hybrid.cash(), 0);
        assertEq(hybrid.reserveShares(), reserve.balanceOf(address(hybrid)));
        assertEq(hybrid.fullAssets(), 1000e6);
        usdg.mint(address(this), 100e6);
        usdg.approve(address(reserve), 100e6);
        reserve.donate(100e6);
        assertApproxEqAbs(hybrid.totalAssets(), 1100e6, 2);
        uint256 second = _deposit(lender2, 1100e6);
        assertApproxEqRel(second, 1000e6 * ONE, 1e12, "a later depositor buys at the higher price");
        assertApproxEqAbs(hybrid.convertToAssets(hybrid.balanceOf(lender)), 1100e6, 2);
        assertApproxEqAbs(hybrid.convertToAssets(second), 1100e6, 2);
    }

    function testRedeemPaysFromCashThenTheReserveAndDonationsNeverChangeThePrice() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(600e6, 1);
        usdg.mint(address(hybrid), 5000e6);
        assertEq(hybrid.totalAssets(), 1000e6, "a direct transfer is not strategy assets");
        uint256 before_ = usdg.balanceOf(lender);
        vm.prank(lender);
        uint256 assets = hybrid.redeem(700e6 * ONE, 700e6);
        assertEq(assets, 700e6);
        assertEq(usdg.balanceOf(lender) - before_, 700e6);
        assertEq(hybrid.cash(), 0);
        assertApproxEqAbs(reserve.convertToAssets(hybrid.reserveShares()), 300e6, 1);
        vm.prank(lender);
        hybrid.withdraw(100e6, 100e6 * ONE);
        assertApproxEqAbs(hybrid.totalAssets(), 200e6, 1);
        assertEq(hybrid.balanceOf(lender), 200e6 * ONE);
    }

    function testCuratorDivestsTheReserveBackToCashAndOthersCannot() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(1000e6, 1);
        uint256 shares = hybrid.reserveShares();
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.divestReserve(shares, 1);
        vm.prank(curator);
        hybrid.divestReserve(shares, 1000e6);
        assertEq(hybrid.cash(), 1000e6);
        assertEq(hybrid.reserveShares(), 0);
        assertEq(hybrid.totalAssets(), 1000e6);
    }

    function testDepositBoundsMinimumCapPauseAndSlippage() public {
        vm.prank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.deposit(1e6 - 1, 0);
        vm.prank(lender);
        vm.expectRevert(HybridVault.Slippage.selector);
        hybrid.deposit(10e6, 10e6 * ONE + 1);
        vm.prank(lender);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.deposit(100_000e6 + 1, 0);
        vm.prank(curator);
        hybrid.setPaused(true);
        vm.prank(lender);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.deposit(10e6, 0);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.investReserve(1, 1);
    }

    function testCuratorRaisesTheDepositCapAndNobodyElseCan() public {
        _deposit(lender, 90_000e6);
        vm.prank(lender);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.deposit(10_000e6 + 1, 0);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.setMaxTotalDeposits(200_000e6);
        vm.expectEmit(false, false, false, true);
        emit HybridVault.MaxTotalDepositsSet(200_000e6);
        vm.prank(curator);
        hybrid.setMaxTotalDeposits(200_000e6);
        assertEq(hybrid.params().maxTotalDeposits, 200_000e6);
        assertEq(_deposit(lender, 10_000e6 + 1), (10_000e6 + 1) * ONE, "the raised cap admits the refused deposit");
    }

    function testALoweredDepositCapRefusesNewMoneyAndTouchesNoPosition() public {
        _deposit(lender, 50_000e6);
        vm.prank(curator);
        hybrid.setMaxTotalDeposits(20_000e6);
        assertEq(hybrid.params().maxTotalDeposits, 20_000e6);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.deposit(1e6, 0);
        assertEq(hybrid.convertToAssets(hybrid.balanceOf(lender)), 50_000e6, "a lower cap takes no deposit away");
        assertEq(hybrid.maxWithdraw(lender), 50_000e6, "and holds back no exit");
        vm.prank(lender);
        assertEq(hybrid.redeem(50_000e6 * ONE, 50_000e6), 50_000e6);
    }

    function testZeroDepositCapClosesDepositsAndPreservesExits() public {
        uint256 shares = _deposit(lender, 1000e6);
        vm.startPrank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setMaxTotalDeposits(uint256(type(uint128).max) + 1);
        hybrid.setMaxTotalDeposits(0);
        vm.stopPrank();
        assertEq(hybrid.params().maxTotalDeposits, 0);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.deposit(p.minDeposit, 0);
        assertEq(hybrid.maxWithdraw(lender), 1000e6);
        vm.prank(lender);
        assertEq(hybrid.redeem(shares, 1000e6), 1000e6);
        vm.prank(curator);
        hybrid.setMaxTotalDeposits(p.minDeposit);
        assertEq(_deposit(lender2, p.minDeposit), p.minDeposit * ONE);
    }

    function testLoansAndBorrowerExposureHaveNoSeparatePrincipalLimits() public {
        _deposit(lender, 30_000e6);
        uint256 first = _fundLoan(9000e6);
        uint256 second = _fundLoan(9000e6);
        assertTrue(hybrid.funded(first));
        assertTrue(hybrid.funded(second));
        assertEq(hybrid.borrowerPrincipal(borrower), 18_000e6);
        assertEq(hybrid.performingPrincipal(), 18_000e6);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 18_000e6);
    }

    // ---------------------------------------------------------------- loans at principal

    function testFundingKeepsTheShareValueAndPaysFromCashBeforeTheReserve() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(400e6, 1);
        uint256 id = _fundLoan(800e6);
        assertEq(uint256(_state(id)), uint256(V2State.ACTIVE));
        assertEq(hybrid.performingPrincipal(), 800e6);
        assertEq(hybrid.cash(), 0);
        assertApproxEqAbs(reserve.convertToAssets(hybrid.reserveShares()), 200e6, 1);
        assertApproxEqAbs(hybrid.totalAssets(), 1000e6, 1);
        assertApproxEqAbs(hybrid.convertToAssets(hybrid.balanceOf(lender)), 1000e6, 1);
    }

    function testFundingFailsWholeWhenTheReserveCannotPayAndNothingIsRecorded() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(800e6, 1);
        uint256 id = _listed(600e6);
        _approve(id);
        reserve.setLimits(type(uint256).max, 0, 0);
        vm.expectRevert();
        hybrid.fund(id, type(uint256).max);
        assertFalse(hybrid.funded(id));
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.cash(), 200e6);
        reserve.setLimits(type(uint256).max, type(uint256).max, type(uint256).max);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.cash(), 0);
        assertApproxEqAbs(reserve.convertToAssets(hybrid.reserveShares()), 400e6, 1);
    }

    function testLeavingBeyondFreeLiquidityFailsClearly() public {
        _deposit(lender, 1000e6);
        _fundLoan(600e6);
        vm.prank(lender);
        vm.expectRevert(HybridVault.InsufficientLiquidity.selector);
        hybrid.redeem(500e6 * ONE, 0);
        vm.prank(lender);
        vm.expectRevert(HybridVault.InsufficientLiquidity.selector);
        hybrid.withdraw(400e6 + 1, type(uint256).max);
        vm.prank(lender);
        hybrid.withdraw(400e6, type(uint256).max);
    }

    function testRepaymentUnlocksThePremiumOverTheWindowAndChargesTheFeeOnce() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        _repay(id);
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.cash(), 1045e6, "principal plus the premium net of the 10% fee");
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(hybrid.fullAssets(), 1045e6);
        assertEq(hybrid.totalAssets(), 1000e6, "profit is locked at settlement");
        assertEq(hybrid.lockedProfitNow(), 45e6);
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK() / 2);
        assertApproxEqAbs(hybrid.totalAssets(), 1_022_500_000, 1);
        _unlock();
        assertEq(hybrid.totalAssets(), 1045e6);
        assertEq(hybrid.lockedProfitNow(), 0);
        hybrid.claimFees();
        assertEq(hybridFees.curatorAccrued(), 3_750_000);
        assertEq(hybridFees.protocolAccrued(), 1_250_000);
        hybridFees.claimProtocol();
        assertEq(usdg.balanceOf(floor), 1_250_000);
    }

    function testDepositAfterRepaymentPaysForLockedProfitAndCannotSnipeIt() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        _repay(id);
        uint256 lateShares = _deposit(lender2, 1000e6);
        hybrid.settle(_ids(id));
        // The deposit checkpoint realizes repayment first and mints against full value. Leaving before unlock
        // therefore gives up its temporary lock discount instead of taking profit earned by the incumbent.
        vm.prank(lender2);
        assertLt(hybrid.redeem(lateShares, 0), 1000e6);
        uint256 again = _deposit(lender2, 1000e6);
        _unlock();
        assertApproxEqAbs(hybrid.convertToAssets(again), 1000e6, 2);
        assertGt(hybrid.convertToAssets(hybrid.balanceOf(lender)), 1044e6);
    }

    function testFeeIsChargedOnlyAboveTheVaultsHighWaterMark() public {
        _deposit(lender, 2000e6);
        uint256 first = _fundLoan(1000e6);
        _repay(first);
        hybrid.settle(_ids(first));
        assertEq(hybrid.feeAccrued(), 5e6);
        _unlock();
        // A default writes 1000 off; the next two repayments only recover part of it: no fee.
        uint256 lost = _fundLoan(1000e6);
        vm.warp(_defaultAt(lost));
        hybrid.settle(_ids(lost));
        assertEq(hybrid.fullAssets(), 1045e6);
        uint256 third = _fundLoan(1000e6);
        _repay(third);
        hybrid.settle(_ids(third));
        assertEq(hybrid.feeAccrued(), 5e6, "below the mark nothing is charged");
        assertEq(hybrid.fullAssets(), 1095e6);
        _unlock();
        // Ten more repayments would be needed to pass 2045; a big premium crosses the mark and pays only on the excess.
        uint256 big = _list(borrower, address(nvda), 1000e18, 1000e6, 2100e6, T7);
        _approve(big);
        hybrid.fund(big, type(uint256).max);
        _repay(big);
        hybrid.settle(_ids(big));
        // Full assets before the fee: 1095 + 1100 = 2195; excess above the 2045 mark is 150, fee 15.
        assertEq(hybrid.feeAccrued(), 20e6);
        assertEq(hybrid.fullAssets(), 2180e6);
    }

    function testZeroFeeLoansPayNothingEvenAboveTheMark() public {
        vm.prank(curator);
        hybrid.setFee(0);
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.prank(curator);
        hybrid.setFee(2000);
        _repay(id);
        hybrid.settle(_ids(id));
        assertEq(hybrid.feeAccrued(), 0, "the rate is snapshotted at funding");
        assertEq(hybrid.loanFeeBps(id), 0);
        assertEq(hybrid.fullAssets(), 1050e6);
    }

    function testRefundedCommitmentReturnsPrincipalWithoutProfitOrFee() public {
        _deposit(lender, 1000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 800e6, 840e6, T7);
        _approve(id, 2);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.performingPrincipal(), 400e6);
        vm.prank(curator);
        hybrid.withdrawCommitment(id);
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.cash(), 1000e6);
        assertEq(hybrid.lockedProfit(), 0);
        assertEq(hybrid.feeAccrued(), 0);
        assertEq(hybrid.totalAssets(), 1000e6);
    }

    // ---------------------------------------------------------------- overdue and defaults

    function testOverdueLoanRecoveryBelongsToTheWriteDownHolders() public {
        _deposit(lender, 1000e6);
        _deposit(lender2, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_ids(id));
        assertTrue(hybrid.overdue(id));
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.overduePrincipal(), 1000e6);
        assertEq(hybrid.totalAssets(), 1000e6, "the written-down loan is worth nothing to the price");
        uint256 held = hybrid.balanceOf(lender2);
        vm.prank(lender2);
        assertEq(hybrid.redeem(held, 0), 500e6, "leaving now sells at the impaired price");
        uint256 entrant = _deposit(other, 500e6);
        _repay(id);
        hybrid.settle(_ids(id));
        assertEq(hybrid.overduePrincipal(), 0);
        assertEq(hybrid.feeAccrued(), 0);
        assertEq(hybrid.lockedProfitNow(), 0);
        assertApproxEqAbs(hybrid.convertToAssets(entrant), 500e6, 2);
        assertEq(hybrid.pocketClaimable(1, other), 0);
        assertEq(hybrid.pocketClaimable(1, lender), 525e6);
        assertEq(hybrid.pocketClaimable(1, lender2), 525e6);
    }

    function testMarkOverdueIgnoresLoansStillInTermAndSettleWritesDownAMissedOne() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        hybrid.markOverdue(_ids(id));
        assertFalse(hybrid.overdue(id));
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.markOverdue(_ids(999));
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.totalAssets(), 0);
        assertEq(hybrid.pocketCount(), 1);
    }

    function testDefaultOpensASidePocketForTheHoldersOfRecord() public {
        uint256 first = _deposit(lender, 1000e6);
        uint256 second = _deposit(lender2, 3000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_ids(id));
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
        (uint256 dealId, address token, uint256 amount, uint256 supply, uint256 claimed) = hybrid.pockets(1);
        assertEq(dealId, id);
        assertEq(token, address(nvda));
        assertEq(amount, 100e18);
        assertEq(supply, first + second);
        assertEq(claimed, 0);
        assertEq(nvda.balanceOf(address(hybrid)), 100e18);
        assertEq(hybrid.totalAssets(), 3000e6, "collateral is never priced");
        // A later depositor and a holder who leaves afterwards do not change the entitlements.
        _deposit(other, 1000e6);
        vm.prank(lender2);
        hybrid.redeem(second, 0);
        assertEq(hybrid.balanceOfAt(lender2, 1), second);
        assertEq(hybrid.balanceOfAt(other, 1), 0);
        assertEq(hybrid.pocketClaimable(1, lender2), 75e18);
        vm.prank(lender2);
        assertEq(hybrid.claimPocket(1), 75e18);
        assertEq(nvda.balanceOf(lender2), 75e18);
        vm.prank(lender);
        assertEq(hybrid.claimPocket(1), 25e18);
        vm.prank(lender);
        vm.expectRevert(HybridVault.AlreadyClaimed.selector);
        hybrid.claimPocket(1);
        vm.prank(other);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimPocket(1);
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.claimPocket(2);
        (,,,, claimed) = hybrid.pockets(1);
        assertEq(claimed, 100e18);
    }

    function testTwoPocketsKeepSeparateRecordsAcrossBalanceChanges() public {
        uint256 first = _deposit(lender, 1000e6);
        uint256 a = _fundLoan(500e6);
        uint256 b = _fundLoan(400e6);
        vm.warp(_defaultAt(a));
        hybrid.settle(_ids(a));
        // Both ready defaults settle in their canonical funding order before any balance can change.
        vm.prank(lender);
        hybrid.redeem(first / 10, 0);
        uint256 joined = _deposit(lender2, 50e6);
        hybrid.settle(_ids(b));
        assertEq(hybrid.pocketCount(), 2);
        assertEq(hybrid.balanceOfAt(lender, 1), first);
        assertEq(hybrid.balanceOfAt(lender, 2), first);
        assertEq(hybrid.balanceOfAt(lender2, 1), 0);
        assertEq(hybrid.balanceOfAt(lender2, 2), 0);
        assertEq(hybrid.pocketClaimable(1, lender), 100e18);
        assertEq(hybrid.pocketClaimable(1, lender2), 0);
        assertEq(hybrid.pocketClaimable(2, lender), 100e18);
        assertEq(hybrid.pocketClaimable(2, lender2), 0);
        assertGt(joined, 0);
    }

    // ---------------------------------------------------------------- withdrawal requests

    function testRequestsAreServedOldestFirstFromRepaymentsBeforeAnyNewLoan() public {
        _deposit(lender, 1000e6);
        uint256 second = _deposit(lender2, 1000e6);
        uint256 id = _fundLoan(1500e6);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.InsufficientLiquidity.selector);
        hybrid.redeem(second, 0);
        vm.prank(lender2);
        uint256 requestId = hybrid.requestRedeem(second);
        assertEq(hybrid.pendingShares(), second);
        assertEq(hybrid.lockedShares(lender2), second);
        assertEq(hybrid.pendingRequestAssets(), 1000e6);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.redeem(1, 0);
        // Half is served from the idle 500; the rest waits.
        hybrid.serveRequests(10, type(uint256).max);
        (, uint256 remaining) = hybrid.requests(requestId);
        assertEq(remaining, second / 2);
        assertEq(hybrid.claimable(lender2), 500e6);
        assertEq(hybrid.requestHead(), requestId);
        _repay(id);
        hybrid.settle(_ids(id));
        // The repayment lands as cash; a loan that would leave the queue short cannot be funded.
        uint256 next = _listed(1200e6);
        _approve(next);
        vm.expectRevert(HybridVault.RequestsPending.selector);
        hybrid.fund(next, type(uint256).max);
        hybrid.serveRequests(10, type(uint256).max);
        (, remaining) = hybrid.requests(requestId);
        assertEq(remaining, 0);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.requestHead(), requestId + 1);
        assertEq(hybrid.balanceOf(lender2), 0);
        assertEq(hybrid.claimable(lender2), 1000e6, "served in the settlement block, before the premium unlocks");
        vm.prank(lender2);
        assertEq(hybrid.claim(), 1000e6);
        assertEq(hybrid.claimableTotal(), 0);
        // Served requests left the strategy; a loan sized to what remains funds at once.
        uint256 fits = _listed(1000e6);
        _approve(fits);
        hybrid.fund(fits, type(uint256).max);
        assertTrue(hybrid.funded(fits));
    }

    function testRequestCanBeCancelledAndOnlyByItsOwner() public {
        uint256 shares = _deposit(lender, 1000e6);
        vm.prank(lender);
        uint256 id = hybrid.requestRedeem(shares);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.NotOwner.selector);
        hybrid.cancelRequest(id);
        vm.prank(lender);
        hybrid.cancelRequest(id);
        assertEq(hybrid.lockedShares(lender), 0);
        assertEq(hybrid.pendingShares(), 0);
        vm.prank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.cancelRequest(id);
        hybrid.serveRequests(10, type(uint256).max);
        assertEq(hybrid.requestHead(), id + 1, "a cancelled request is skipped");
        vm.prank(lender);
        hybrid.redeem(shares, 1000e6);
    }

    function testRequesterStillOwnsAPocketOpenedWhileWaiting() public {
        uint256 shares = _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.prank(lender);
        hybrid.requestRedeem(shares);
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
        assertEq(hybrid.pocketClaimable(1, lender), 100e18);
        hybrid.serveRequests(10, type(uint256).max);
        assertEq(hybrid.pendingShares(), 0, "a request worth nothing in USDG is handed back, not left to stall");
        assertEq(hybrid.lockedShares(lender), 0);
        assertEq(hybrid.balanceOf(lender), shares, "the shares stay owned");
        vm.prank(lender);
        hybrid.claimPocket(1);
        assertEq(nvda.balanceOf(lender), 100e18);
    }

    // ---------------------------------------------------------------- rewards

    function testRewardsAccruedBeforeASecondDepositStayWithTheFirstHolder() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7 / 2);
        _repay(id);
        hybrid.settle(_ids(id));
        uint256 due = hybrid.rewardClaimable(lender);
        assertGt(due, 0);
        assertGt(_deposit(lender2, 1000e6), 0);
        hybrid.harvestRewards(_ids(id));
        assertEq(sgage.balanceOf(address(hybrid)), due);
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1);
        assertEq(hybrid.rewardClaimable(lender2), 0);
        vm.prank(lender);
        uint256 paid = hybrid.claimRewards();
        assertEq(sgage.balanceOf(lender), paid);
        assertEq(hybrid.rewardClaimable(lender), 0);
        uint256 third = _deposit(other, 1000e6);
        assertEq(hybrid.rewardClaimable(other), 0, "rewards already harvested belong to earlier holders");
        assertGt(third, 0);
        vm.prank(other);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimRewards();
        hybrid.harvestRewards(_ids(id));
        assertEq(hybrid.rewardClaimable(lender), 0, "a second harvest of the same loan releases nothing new");
    }

    // ---------------------------------------------------------------- mandate

    function testPausingRevokesEveryOutstandingApprovalAndBlocksFunding() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(500e6);
        _approve(id);
        vm.prank(curator);
        hybrid.setPaused(true);
        assertEq(hybrid.approvedPrincipal(), 0);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.fund(id, type(uint256).max);
        vm.prank(curator);
        hybrid.setPaused(false);
        vm.expectRevert(HybridVault.ApprovalExpired.selector);
        hybrid.fund(id, type(uint256).max);
    }

    function testLaneWeightAndGageExposureCapTheStrategyNotTheAccount() public {
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 5000);
        _deposit(lender, 1000e6);
        uint256 id = _listed(600e6);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(HybridVault.IneligibleDeal.selector, id));
        hybrid.approveLoan(id, uint40(block.timestamp + 1 hours), UNITS);
        uint256 ok = _fundLoan(500e6);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 500e6);
        assertTrue(hybrid.funded(ok));
        p.maxGageExposureBps = 2000;
        _deploy();
        vm.prank(curator);
        hybrid.setFee(0);
        _deposit(lender, 1000e6);
        uint256 over = _listed(300e6);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(HybridVault.IneligibleDeal.selector, over));
        hybrid.approveLoan(over, uint40(block.timestamp + 1 hours), UNITS);
        _fundLoan(200e6);
    }

    function testMaxViewsReportFreeSharesBoundedByLiquidity() public {
        uint256 shares = _deposit(lender, 1000e6);
        assertEq(hybrid.maxRedeem(lender), shares);
        assertEq(hybrid.maxWithdraw(lender), 1000e6);
        hybrid.investReserve(1000e6, 1);
        assertEq(hybrid.maxWithdraw(lender), 1000e6);
        _fundLoan(600e6);
        assertApproxEqAbs(hybrid.maxWithdraw(lender), 400e6, 1);
        assertApproxEqAbs(hybrid.maxRedeem(lender), shares * 2 / 5, 1e12);
        vm.prank(lender);
        hybrid.requestRedeem(shares / 2);
        assertEq(hybrid.maxRedeem(lender), shares * 2 / 5 < shares / 2 ? shares * 2 / 5 : shares / 2);
    }

    function testDeploymentRuntimeFitsEIP170() public view {
        assertLe(address(hybrid).code.length, 24_576);
    }
}
