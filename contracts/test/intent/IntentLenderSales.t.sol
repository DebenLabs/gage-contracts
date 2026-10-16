// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {V2LenderSplit} from "../../src/v2/V2Types.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

using {remainingLenderReward} for GageV2Rewards;

/// @dev Keep the live fixture's ERC20 storage while checking callbacks at the core's payment step.
contract SaleCallbackUSDG is MockERC20 {
    IntentVault private immutable SELLER;

    constructor(IntentVault seller) MockERC20("USDG", "USDG", 6) {
        SELLER = seller;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (from == address(SELLER.LENDER_MARKET()) && to == address(SELLER.VAULT())) {
            (bool entered, bytes memory reason) = address(SELLER).call(abi.encodeCall(SELLER.deposit, (1e6, 0)));
            require(!entered && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")), "mint unlocked");
            (entered, reason) = address(SELLER).call(abi.encodeCall(SELLER.redeem, (1, 0)));
            require(!entered && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")), "burn unlocked");
            (entered, reason) = address(SELLER.LENDER_MARKET()).call(abi.encodeCall(SELLER.LENDER_MARKET().cancel, (1)));
            require(!entered && bytes4(reason) == bytes4(keccak256("ReentrancyGuardReentrantCall()")), "ask unlocked");
        }
        return super.transferFrom(from, to, amount);
    }
}

contract IntentLenderSalesTest is IntentAccountingBaseTest {
    /// @dev A sale one second into the review loan, with a 50 USDG execution fee, whose profit stays below that fee.
    uint128 internal constant PROFIT_BELOW_COST = 1060e6;
    IntentLenderMarket internal market;

    function setUp() public override {
        super.setUp();
        market = partner.LENDER_MARKET();
        vm.prank(bob);
        usdg.approve(address(market), MAX);
        vm.prank(carol);
        usdg.approve(address(market), MAX);
    }

    function _listedSale(uint128 price) internal returns (uint256 id, uint64 nonce) {
        _enter(alice, 10_000e6);
        id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        nonce = _offer(id, price);
    }

    function _offer(uint256 id, uint128 price) internal returns (uint64 nonce) {
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        market.list(id, price, deadline, 100);
        nonce = market.nonces(id);
    }

    function _buy(uint256 id, uint64 nonce, uint128 price) internal returns (uint256) {
        vm.prank(bob);
        return market.buySplit(id, nonce, price, [bob, bob, bob, bob], _none());
    }

    function _none() internal pure returns (uint128[4] memory none) {}

    /// @dev The listing price whose sale pays the vault exactly `proceeds` after the 1% trade fee.
    function _priceFor(uint256 proceeds) internal pure returns (uint128) {
        uint256 guess = proceeds * 100 / 99;
        for (uint256 price = guess - 3; price <= guess + 3; ++price) {
            if (price - price / 100 == proceeds) return uint128(price);
        }
        revert("no exact price");
    }

    function _assertOwned(uint256 id, address owner) internal view {
        address[4] memory lenders = core.lenders(id);
        for (uint8 i; i < 4; ++i) {
            assertEq(lenders[i], owner);
        }
    }

    function _assertRollback(uint256 id, uint64 nonce, uint256 balance, uint256 assets) internal view {
        _assertOwned(id, address(partner));
        assertEq(market.nonces(id), nonce);
        assertEq(usdg.balanceOf(bob), balance);
        assertEq(usdg.balanceOf(address(market)), 0);
        assertEq(usdg.allowance(address(market), address(core)), 0);
        assertEq(core.getLenderAsk(id, address(partner)).price, 0);
        assertEq(partner.totalAssets(), assets);
    }

    function testListingLeavesOwnershipYieldAndRewardsWithSeller() public {
        (uint256 id,) = _listedSale(1080e6);
        _assertOwned(id, address(partner));
        assertEq(core.getLenderAsk(id, address(partner)).price, 0, "no bypassable core ask");
        uint256 assets = partner.totalAssets();
        uint256 reward = coreRewards.claimable(id, address(partner));
        vm.warp(_startOf(id) + 4 days);
        assertGt(partner.totalAssets(), assets);
        assertGt(coreRewards.claimable(id, address(partner)), reward);
        assertEq(partner.performingPrincipal(), REVIEW_PRINCIPAL);
    }

    function testCoreCannotFillAroundTheVaultAccountingLock() public {
        (uint256 id,) = _listedSale(1080e6);
        vm.prank(bob);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        core.buyLenderSplit(id, V2LenderSplit(address(partner), 15, 1080e6, 100, 0, [bob, bob, bob, bob], _none()));
        _assertOwned(id, address(partner));
    }

    function testSaleAtomicallyUnbooksLoanAndReceivesOnlyNetCash() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint256 beforeAssets = partner.totalAssets();
        uint256 buyerBalance = usdg.balanceOf(bob);
        uint256 proceeds = _buy(id, nonce, 1080e6);
        uint256 net = proceeds - (proceeds - REVIEW_PRINCIPAL) / 10;
        assertEq(proceeds, 1_069_200_000);
        _assertOwned(id, bob);
        assertEq(usdg.balanceOf(bob), buyerBalance - 1080e6);
        // D51: what the sale books above book value leaves cash for the position's earnings claim.
        uint256 book = REVIEW_PRINCIPAL + _scheduled(REVIEW_NET, 3 days, T21);
        assertEq(partner.pocketLiability(address(usdg)), net - book);
        assertEq(partner.cash(), 9000e6 + book);
        assertEq(partner.performingPrincipal(), 0);
        assertEq(partner.categoryPrincipal(IntentCategory.STOCK), 0);
        assertEq(partner.assetPrincipal(address(nvda)), 0);
        assertEq(partner.lenderSaleSlots(id), 0);
        assertEq(core.cashCredit(address(partner)), 0);
        assertEq(partner.unassignedCash(), 0);
        assertEq(usdg.balanceOf(address(market)), 0);
        assertEq(usdg.allowance(address(market), address(core)), 0);
        assertEq(core.getLenderAsk(id, address(partner)).price, 0);
        assertLe(beforeAssets - partner.totalAssets(), 1, "gain does not create an entry/exit arbitrage");
        assertTrue(_ln(id).settled);
        assertTrue(_ln(id).repaid);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.totalAssets(), 9000e6 + book);
        assertEq(partner.earliestMaturity(), type(uint40).max);
        assertEq(_ln(id).rate, 0);
        assertApproxEqAbs(_claimAll(alice), net - book, 1, "the sole holder did not get the sale's gain");
    }

    function testEarnedRewardsSurviveSaleAndExitWhileBuyerGetsOnlyFutureRewards() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint256 earned = coreRewards.claimable(id, address(partner));
        _buy(id, nonce, 1080e6);
        assertApproxEqAbs(partner.rewardClaimable(alice), earned, 10_000);
        assertEq(coreRewards.claimable(id, bob), 0);
        _exitAll(alice);
        vm.prank(alice);
        partner.claimRewards();
        assertApproxEqAbs(sgage.balanceOf(alice), earned, 10_000);
        _enter(carol, 1000e6);
        assertEq(partner.rewardClaimable(carol), 0);
        vm.warp(_startOf(id) + 5 days);
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        assertGt(coreRewards.claimable(id, bob), 0);
        partner.harvestRewards(_ids(id));
        assertEq(partner.rewardClaimable(carol), 0);
    }

    function testDepositBeforeSaleCannotExtractTheUnreleasedGain() public {
        (uint256 id, uint64 nonce) = _listedSale(1090e6);
        uint256 reward = coreRewards.claimable(id, address(partner));
        uint256 shares = _enter(carol, 500_000e6);
        _buy(id, nonce, 1090e6);
        assertLe(_exit(carol, shares), 500_000e6);
        assertEq(partner.rewardClaimable(carol), 0);
        assertApproxEqAbs(partner.rewardClaimable(alice), reward, 10_000);
    }

    /// @dev D48: a vault sells a position only at or above its book value, so a sale never lowers the share price.
    function testASaleBelowBookValueRevertsAndChangesNothing() public {
        (uint256 id, uint64 nonce) = _listedSale(900e6);
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        uint256 shares = partner.balanceOf(alice) / 2;
        uint256 quote = partner.convertToAssets(shares);
        vm.prank(bob);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        market.buySplit(id, nonce, 900e6, [bob, bob, bob, bob], _none());
        _assertRollback(id, nonce, balance, assets);
        assertFalse(_ln(id).settled);
        assertEq(partner.convertToAssets(shares), quote, "the share price is untouched");
    }

    function testASaleAtPrincipalAfterInterestHasAccruedIsBelowBook() public {
        (uint256 id, uint64 nonce) = _listedSale(uint128(REVIEW_PRINCIPAL));
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        vm.prank(bob);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        market.buySplit(id, nonce, uint128(REVIEW_PRINCIPAL), [bob, bob, bob, bob], _none());
        _assertRollback(id, nonce, balance, assets);
    }

    /// @dev A loan with no fixed cost, bought whole: 1,000 lent for 21 days, 1,000 back. It earns nothing and has
    /// nothing to come, so its book value is its principal.
    function _zeroCostLoan() internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 100e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_PRINCIPAL), T21);
        _route(id, UNITS);
    }

    /// @dev Pashov M-08: a sale at exactly book value books the whole position into the price and leaves no return for
    /// an earnings claim. The record leaves the book settled, not `repaid`, and its exposure window is never closed:
    /// both mark an opened claim, and a default or a refund leaves the same state. Only an earnings pocket reads a
    /// window's closing field, and none is opened; the record can never be listed or bought again, and later entries
    /// and exits are unaffected. Since Pashov L-01 a sale also keeps half of the interest still to come, so it can be
    /// at exactly book only once nothing is left to come: here a loan with no fixed cost.
    function testASaleAtExactlyBookOpensNoClaimAndLeavesTheRecordInert() public {
        _enter(alice, 10_000e6);
        uint256 id = _zeroCostLoan();
        vm.warp(_startOf(id) + 3 days);
        assertEq(partner.accruedInterest(), 0);
        uint256 book = REVIEW_PRINCIPAL;
        uint128 price = _priceFor(book);
        uint64 nonce = _offer(id, price);
        uint256 assets = partner.totalAssets();
        assertEq(_buy(id, nonce, price), book);
        assertEq(partner.cash(), 9000e6 + book, "the price had counted the whole position");
        assertEq(partner.totalAssets(), assets);
        assertEq(partner.pocketCount(), 0, "no earnings claim");
        assertTrue(_ln(id).settled);
        assertFalse(_ln(id).repaid);
        assertEq(uint40(partner.exposureWindow(id) >> 104), _startOf(id), "the window opened with the purchase");
        assertEq(uint104(partner.exposureWindow(id)), 0, "a window closes only when a claim opens");
        assertEq(partner.lenderSaleSlots(id), 0);
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        vm.expectRevert(IntentLenderMarket.InvalidAsk.selector);
        market.list(id, price, deadline, 100);
        _book(id);
        assertEq(partner.totalAssets(), assets, "booking the sold record changes nothing");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 shares = _enter(carol, 1000e6);
        assertApproxEqAbs(_exit(carol, shares), 1000e6, 1);
        assertApproxEqAbs(_leave(alice), 10_000e6, 2);
    }

    /// @dev Pashov M-08, in the second of the purchase: book is then the principal, so a sale at it sets nothing aside
    /// and never reaches `SaleTooSoon`, which guards only a gain in that second. Entries and exits stay blocked for the
    /// rest of the second, and the record is left as above. With interest still to come, Pashov L-01 holds a sale above
    /// book, a gain `SaleTooSoon` refuses in that second; the loan with no fixed cost has none to come.
    function testASaleAtBookInThePurchaseSecondSetsNothingAside() public {
        _enter(alice, 10_000e6);
        uint256 id = _zeroCostLoan();
        uint256 assets = partner.totalAssets();
        uint128 price = _priceFor(REVIEW_PRINCIPAL);
        uint64 nonce = _offer(id, price);
        assertEq(_buy(id, nonce, price), REVIEW_PRINCIPAL);
        assertEq(partner.totalAssets(), assets);
        assertEq(partner.pocketCount(), 0);
        assertTrue(_ln(id).settled);
        assertFalse(_ln(id).repaid);
        assertEq(uint104(partner.exposureWindow(id)), 0);
        vm.prank(carol);
        vm.expectRevert(IntentVault.SaleTooSoon.selector);
        partner.deposit(1000e6, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        _book(id);
        uint256 shares = _enter(carol, 1000e6);
        assertApproxEqAbs(_exit(carol, shares), 1000e6, 1);
        assertApproxEqAbs(_leave(alice), 10_000e6, 2);
    }

    function testOnlyCuratorListsOrCancelsAndOnlyMarketExecutes() public {
        (uint256 id,) = _listedSale(1080e6);
        uint40 deadline = uint40(_maturity(id));
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.NotCurator.selector);
        market.list(id, 1080e6, deadline, 100);
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.NotCurator.selector);
        market.cancel(id);
        vm.prank(bob);
        vm.expectRevert(IntentVault.NotCurator.selector);
        partner.executeLenderSale(id, 15, 1080e6, deadline, 100);
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.NotCurator.selector);
        market.complete(id);
    }

    function testCancelAndRelistAtSamePriceInvalidateOldQuotes() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        vm.prank(curator);
        market.cancel(id);
        uint64 next = _offer(id, 1080e6);
        assertGt(next, nonce);
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.StaleAsk.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        _buy(id, next, 1080e6);
        _assertOwned(id, bob);
    }

    function testRepricingRequiresBothCurrentNonceAndExactPrice() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint64 next = _offer(id, 1070e6);
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.StaleAsk.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.StaleAsk.selector);
        market.buySplit(id, next, 1080e6, [bob, bob, bob, bob], _none());
        _buy(id, next, 1070e6);
    }

    function testCompetingBuyerCannotFillTwice() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        _buy(id, nonce, 1080e6);
        uint256 balance = usdg.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(IntentLenderMarket.StaleAsk.selector);
        market.buySplit(id, nonce, 1080e6, [carol, carol, carol, carol], _none());
        assertEq(usdg.balanceOf(carol), balance);
        _assertOwned(id, bob);
    }

    function testRepaymentBeforeFillRollsBackPaymentAndListingCanBeCancelled() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        _repay(id);
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        vm.prank(bob);
        vm.expectRevert(GageV2Vault.WrongState.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        _assertRollback(id, nonce, balance, assets);
        vm.prank(curator);
        market.cancel(id);
        _book(id);
        assertEq(partner.performingPrincipal(), 0);
    }

    function testRepaymentAfterSaleBelongsOnlyToBuyer() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        _buy(id, nonce, 1080e6);
        uint256 cash = partner.cash();
        _repay(id);
        assertEq(core.cashCredit(bob), REVIEW_CAP);
        assertEq(core.cashCredit(address(partner)), 0);
        _book(id);
        assertEq(partner.cash(), cash);
    }

    function testDefaultAfterSaleCreatesNoSellerRecoveryClaim() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        _buy(id, nonce, 1080e6);
        uint256 cash = partner.cash();
        vm.warp(_maturity(id));
        core.finalizeDefault(id);
        _book(id);
        assertEq(partner.cash(), cash);
        vm.expectRevert(IntentVault.NothingToRecover.selector);
        partner.recover(id);
        vm.prank(bob);
        core.recoverDefault(id, 100e18, 0, block.timestamp);
        assertEq(core.claimableRecovery(id, 0, address(partner)), 0);
        assertEq(core.claimableRecovery(id, 0, bob), 100e18);
    }

    function testExpiredOrDefaultedLoanCannotBeSold() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        vm.warp(_maturity(id));
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.StaleAsk.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        core.finalizeDefault(id);
        vm.prank(bob);
        vm.expectRevert(IntentLenderMarket.StaleAsk.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        vm.prank(curator);
        market.cancel(id);
    }

    function testInvalidDeadlineOrUnfundedLoanCannotBeListed() public {
        _enter(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _route(id, 2);
        vm.prank(curator);
        vm.expectRevert(IntentLenderMarket.InvalidAsk.selector);
        market.list(id, 500e6, uint40(block.timestamp + 1 days), 100);
        _fill(id);
        _book(id);
        uint40 maturity = uint40(_maturity(id));
        vm.prank(curator);
        vm.expectRevert(IntentLenderMarket.InvalidAsk.selector);
        market.list(id, 500e6, maturity + 1, 100);
        vm.prank(curator);
        vm.expectRevert(IntentLenderMarket.InvalidAsk.selector);
        market.list(id, 0, maturity, 100);
    }

    function testSellsOnlyRecordedNonAdjacentSlots() public {
        _enter(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _route(id, 1);
        vm.prank(fillers[0]);
        core.fund(id, 1);
        _route(id, 1);
        _fill(id);
        _book(id);
        // A gain needs a window of at least a second to be shared over (D51).
        vm.warp(vm.getBlockTimestamp() + 1);
        // Above book value (D48): the 1% trade fee on a sale at exactly the principal would book less than the position.
        uint64 nonce = _offer(id, 520e6);
        uint256 assets = partner.totalAssets();
        _buy(id, nonce, 520e6);
        address[4] memory lenders = core.lenders(id);
        assertEq(lenders[0], bob);
        assertEq(lenders[1], fillers[0]);
        assertEq(lenders[2], bob);
        assertEq(lenders[3], fillers[0]);
        assertEq(partner.performingPrincipal(), 0);
        assertApproxEqAbs(partner.totalAssets(), assets, 2, "a sale never lowers the share price");
    }

    function testTradeFeeAboveManagerCeilingRollsEverythingBack() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        vm.prank(safe);
        registry.setTradeFee(200);
        vm.prank(bob);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        _assertRollback(id, nonce, balance, assets);
    }

    function testRewardMinimumProtectsDelayedBuyerAndRollsBackCheckpoint() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        // Each quarter's bound is its remaining reward at listing; the core's ledger enforces it as the quarter moves.
        uint128[4] memory mins;
        for (uint8 q; q < 4; ++q) {
            mins[q] = uint128(coreRewards.remainingLenderReward(id, uint8(1 << q)));
        }
        vm.warp(_startOf(id) + 4 days);
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        uint256 reward = coreRewards.claimable(id, address(partner));
        vm.prank(bob);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], mins);
        _assertRollback(id, nonce, balance, assets);
        assertEq(coreRewards.claimable(id, address(partner)), reward);
        assertEq(partner.accountedRewards(), 0);
    }

    function testCashCollectionFailureCannotSpendAnUnrelatedDonation() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        usdg.mint(address(partner), 2000e6);
        partner.settle(new uint256[](0));
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        vm.mockCallRevert(address(core), abi.encodeCall(core.withdrawUSDGFor, (address(partner))), "paused");
        vm.prank(bob);
        vm.expectRevert();
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        vm.clearMockedCalls();
        _assertRollback(id, nonce, balance, assets);
        assertEq(partner.unassignedCash(), 2000e6);
        _buy(id, nonce, 1080e6);
        assertEq(partner.unassignedCash(), 2000e6);
    }

    function testIncompleteRewardCheckpointRollsBackAndCanRetry() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        vm.mockCall(address(coreRewards), abi.encodeWithSelector(GageV2Rewards.claim.selector), bytes(""));
        vm.prank(bob);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        vm.clearMockedCalls();
        _assertRollback(id, nonce, balance, assets);
        _buy(id, nonce, 1080e6);
    }

    function testPausedSellerCannotFillButCanCancel() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        vm.prank(curator);
        partner.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(IntentVault.PausedError.selector);
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        vm.prank(curator);
        market.cancel(id);
    }

    function testProfitBelowOriginalExecutionCostHasNoPerformanceFee() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        // The widest fee the code allows, half the interest: the sale must also keep half of the interest still to
        // come (Pashov L-01), so only so large a cost leaves a sale whose profit stays below it.
        _route(id, 4, 50e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint64 nonce = _offer(id, PROFIT_BELOW_COST);
        uint256 proceeds = _buy(id, nonce, PROFIT_BELOW_COST);
        assertLt(proceeds - 1000e6, 50e6, "the profit is below the execution cost");
        assertEq(partner.curatorFees() + partner.protocolFees(), 0);
        assertEq(partner.executionFees(), 50e6);
        _leave(alice);
        assertApproxEqAbs(usdg.balanceOf(alice), 1_000_000e6 - 1000e6 - 50e6 + proceeds, 2);
    }

    /// @dev Pashov M-70: the manager fee is charged once. A position accrues its interest net of the fee (100 USDG
    /// gross, less 10% of what is left after the 20 USDG execution fee), so the price never counted the manager's
    /// share. The sale charges 10% of its realised profit after execution costs, as a repayment does, and depositors
    /// keep the rest: the interest the price counted plus the earnings claim. A fee only on the gain above book would
    /// under-charge the interest accrued before the sale.
    function testASaleChargesTheManagerFeeOnceOnItsRealisedProfit() public {
        _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _route(id, 4, 20e6);
        assertEq(_ln(id).interest, 92e6, "booked net of the manager fee");
        vm.warp(_startOf(id) + 7 days);
        uint256 accrued = partner.accruedInterest();
        assertApproxEqAbs(accrued, _scheduled(92e6, 7 days, T21), 1);
        uint256 assets = partner.totalAssets();
        uint64 nonce = _offer(id, 1080e6);
        uint256 proceeds = _buy(id, nonce, 1080e6);
        uint256 profit = proceeds - 1000e6;
        uint256 fee = partner.curatorFees() + partner.protocolFees();
        assertEq(fee, (profit - 20e6) / 10, "one fee on the realised profit after execution costs");
        assertEq(accrued + partner.pocketLiability(address(usdg)), profit - fee);
        assertApproxEqAbs(partner.totalAssets(), assets, 1);
        // What a fee on the gain above book alone would charge.
        assertLt((proceeds - (1000e6 + accrued) - 20e6) / 10, fee);
        assertApproxEqAbs(_leave(alice), 10_000e6 - 20e6 + profit - fee, 2, "depositors keep 90% of the net profit");
    }

    function testCorePaymentFailureRestoresOwnershipRewardsAndBuyerCash() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint256 balance = usdg.balanceOf(bob);
        uint256 assets = partner.totalAssets();
        uint256 reward = coreRewards.claimable(id, address(partner));
        usdg.setBlocked(address(core), true);
        vm.prank(bob);
        vm.expectRevert();
        market.buySplit(id, nonce, 1080e6, [bob, bob, bob, bob], _none());
        _assertRollback(id, nonce, balance, assets);
        assertEq(coreRewards.claimable(id, address(partner)), reward);
        usdg.setBlocked(address(core), false);
        _buy(id, nonce, 1080e6);
    }

    function testPaymentCallbacksCannotMintBurnOrChangeTheAskMidSale() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        SaleCallbackUSDG callbackToken = new SaleCallbackUSDG(partner);
        vm.etch(address(usdg), address(callbackToken).code);
        _buy(id, nonce, 1080e6);
        _assertOwned(id, bob);
    }

    /// @dev Pashov M-71: core credit that predates a sale is a repayment or refund of a loan the vault records, and
    /// that loan's open record prices it until `settle` books it from `unassignedCash`. The sale collects the whole
    /// credit, as any `_harvest` does; only its own proceeds leave `unassignedCash`, and `totalAssets` holds within one
    /// raw unit through the sale and the booking.
    function testOtherRepaymentCreditIsNotMistakenForSaleProceeds() public {
        (uint256 id, uint64 nonce) = _listedSale(1080e6);
        uint256 other = _reviewLoan();
        _repay(other);
        assertEq(core.cashCredit(address(partner)), REVIEW_CAP);
        uint256 assets = partner.totalAssets();
        _buy(id, nonce, 1080e6);
        assertApproxEqAbs(partner.totalAssets(), assets, 1, "the prior credit never left the price");
        assertEq(partner.performingPrincipal(), REVIEW_PRINCIPAL, "the repaid loan is still priced by its record");
        assertEq(partner.unassignedCash(), REVIEW_CAP);
        assertEq(core.cashCredit(address(partner)), 0);
        // Repaid in the second it was funded, `other` is booked from the next second (D51).
        vm.warp(vm.getBlockTimestamp() + 1);
        _book(other);
        assertEq(partner.unassignedCash(), 0);
        assertEq(partner.performingPrincipal(), 0);
        assertApproxEqAbs(partner.totalAssets(), assets, 1, "booking it from unassigned cash moves no price");
    }

    function testFuzzSaleCashAndFeesConservedWithoutInstantGain(uint128 price, uint32 delay) public {
        price = uint128(bound(price, 1, 1500e6));
        delay = uint32(bound(delay, 1, T21 - 1));
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + delay);
        uint64 nonce = _offer(id, price);
        uint256 beforeAssets = partner.totalAssets();
        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 proceeds;
        vm.prank(bob);
        try market.buySplit(id, nonce, price, [bob, bob, bob, bob], _none()) returns (uint256 received) {
            proceeds = received;
        } catch (bytes memory reason) {
            // D48 and Pashov L-01: below book value plus half the interest still to come the sale reverts whole.
            assertEq(bytes4(reason), IntentVault.SaleBelowBook.selector);
            _assertRollback(id, nonce, bobBefore, beforeAssets);
            return;
        }
        // At or above book value the share price does not move: any gain is an earnings claim (D51).
        assertApproxEqAbs(partner.totalAssets(), beforeAssets, 2, "a sale never lowers the share price");
        uint256 fee = proceeds > REVIEW_PRINCIPAL ? (proceeds - REVIEW_PRINCIPAL) / 10 : 0;
        assertEq(
            partner.cash() + partner.curatorFees() + partner.protocolFees() + partner.pocketLiability(address(usdg)),
            9000e6 + proceeds
        );
        assertEq(usdg.balanceOf(address(partner)), 9000e6 + proceeds);
        assertEq(partner.curatorFees() + partner.protocolFees(), fee);
        assertLe(partner.totalAssets(), beforeAssets);
        assertEq(partner.performingPrincipal(), 0);
        vm.warp(_maturity(id));
        _book(id);
        assertEq(partner.totalAssets() + partner.pocketLiability(address(usdg)), 9000e6 + proceeds - fee);
        assertEq(_ln(id).rate, 0);
        _assertOwned(id, bob);
    }
}
