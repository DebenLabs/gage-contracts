// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {V2State, unitSlice} from "../../src/v2/V2Types.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

/// @notice S9-03: a bought position through repayment, early repayment, default and recovery, resale, depositor
/// entries and exits and rewards, on the buyer's own basis; and the secondary policy's authority and timing.
contract IntentSecondaryLifecycleTest is IntentSecondaryBaseTest {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), an asking price of about 1,067 after the 1% trade fee and the seller's manager fee; the odd
    /// units exercise the per-quarter remainder rule.
    uint128 internal constant PRICE = 1070e6 + 3;
    /// @dev buyerA's resale of quarters 0 and 2, six days into the loan and three after it bought them at about 535.
    /// The seller keeps at least half of the interest still to come (Pashov L-01), and on a 21-day loan the core's 1%
    /// fee on a second sale would leave the next buyer less than its 13% a year: the resales trade without that fee.
    uint128 internal constant RESALE = 545e6;
    /// @dev Who runs the vaults the fixture's buyers resell to: not their own curator, whose other vaults the verifier
    /// refuses as buyers (L-01).
    address internal resaleCurator = makeAddr("resale curator");

    /// @dev The registry's trade fee drops to zero for a resale (see `RESALE`).
    function _noTradeFee() internal {
        vm.prank(safe);
        registry.setTradeFee(0);
    }

    function _bought() internal returns (uint256 id, IntentQuoteVerifier.SecondaryPlan memory p) {
        id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        p = _marketPlan(id, vaults, masks);
        _buy(p);
    }

    function _allocationOf(IntentQuoteVerifier.SecondaryPlan memory p, IntentVault vault)
        internal
        pure
        returns (IntentQuoteVerifier.SecondaryAllocation memory a)
    {
        for (uint256 i; i < p.allocations.length; ++i) {
            if (p.allocations[i].vault == address(vault)) return p.allocations[i];
        }
        revert("not in plan");
    }

    function _settle(IntentVault vault, uint256 id) internal {
        vault.settle(_ids(id));
    }

    // ---------------------------------------------------------------- repayment

    function test_earlyRepaymentBooksProfitOnTheBuyersOwnBasisAndOpensItsClaim() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint256 before_ = buyerA.totalAssets();
        _buy(p);
        IntentQuoteVerifier.SecondaryAllocation memory a = _allocationOf(p, buyerA);
        uint256 gross = a.repayment - a.price;
        uint256 fee = IntentFeeMath.performanceFee(gross, a.executionFee, 1000);
        vm.warp(_startOf(id) + 10 days);
        _repay(id);
        uint256 atRepayment = buyerA.totalAssets();
        _settle(buyerA, id);
        assertLe(atRepayment - buyerA.totalAssets(), 1, "settling the early repayment moves no price");
        assertEq(buyerA.performingPrincipal(), 0);
        assertTrue(_loanOf(buyerA, id).repaid);
        assertTrue(_loanOf(buyerA, id).settled);
        assertEq(buyerA.curatorFees() + buyerA.protocolFees(), fee, "fee on its own profit after its own fee");
        vm.warp(p.maturity);
        _settle(buyerA, id);
        // Whole life: the execution fee at purchase, then what the quarters repaid beyond their price, less the fee,
        // part of it in the price and the rest as the earnings claim of the position's holders (D51).
        assertApproxEqAbs(
            buyerA.totalAssets() + buyerA.pocketLiability(address(usdg)), before_ - a.executionFee + gross - fee, 1
        );
        // The seller received nothing after its sale; the borrower's terms never changed.
        assertEq(core.cashCredit(address(seller)), 0);
        assertEq(core.getLoan(id).cap, REVIEW_CAP);
    }

    /// @dev D48: a vault sells only at or above book, so the discount a buyer could once get from a vault seller is
    /// refused whole; a premium purchase still charges fees only on the profit the buyer realises.
    function test_aDiscountSaleIsRefusedAndPremiumPurchasesChargeFeesOnlyOnRealisedProfit() public {
        uint256 discounted = _onSale(960e6);
        (IntentVault[] memory refusedVaults, uint8[] memory refusedMasks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory refused = _marketPlan(discounted, refusedVaults, refusedMasks);
        bytes memory signature = _signSecondary(refused);
        IntentFillRouter router_ = _secondaryRouter();
        address[4] memory holders = core.lenders(discounted);
        vm.prank(refused.filler);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        router_.fillSecondary(refused, signature);
        address[4] memory after_ = core.lenders(discounted);
        for (uint256 q; q < 4; ++q) {
            assertEq(after_[q], holders[q], "nothing moved");
        }
        _repay(discounted);
        vm.warp(_maturity(discounted));
        _settle(seller, discounted);

        // Two premiums to the principal the quarters represent.
        uint128[2] memory prices = [uint128(1070e6), uint128(1080e6)];
        for (uint256 k; k < 2; ++k) {
            uint256 id = _onSale(prices[k]);
            (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
            IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
            IntentVault buyer = IntentVault(p.allocations[0].vault);
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[0];
            uint256 feesBefore = buyer.curatorFees() + buyer.protocolFees();
            _buy(p);
            // A repayment in the second of the purchase is booked from the next second (D51).
            vm.warp(vm.getBlockTimestamp() + 1);
            _repay(id);
            _settle(buyer, id);
            uint256 gross = a.repayment - a.price;
            assertEq(
                buyer.curatorFees() + buyer.protocolFees() - feesBefore,
                IntentFeeMath.performanceFee(gross, a.executionFee, 1000)
            );
            vm.warp(p.maturity);
            _settle(seller, id);
            _settle(buyer, id);
            _settle(IntentVault(p.allocations[1].vault), id);
            _settle(IntentVault(p.allocations[2].vault), id);
        }
    }

    // ---------------------------------------------------------------- default

    function test_defaultWritesOffTheBuyersCostAndRecoversOnlyItsQuarters() public {
        (uint256 id, IntentQuoteVerifier.SecondaryPlan memory p) = _bought();
        IntentQuoteVerifier.SecondaryAllocation memory a = _allocationOf(p, buyerA);
        vm.warp(p.maturity);
        uint256 assets = buyerA.totalAssets();
        _settle(buyerA, id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED));
        assertEq(buyerA.performingPrincipal(), 0);
        // The cost and everything it had accrued leave priced assets at once.
        assertGe(assets - buyerA.totalAssets(), a.price, "cost written off");
        buyerA.recover(id);
        (, address token, uint256 amount,,,) = buyerA.pockets(buyerA.pocketCount());
        assertEq(token, address(nvda));
        // Quarters 0 and 2 of 100 NVDA.
        assertEq(amount, 50e18);
        uint256 held = nvda.balanceOf(carol);
        uint256 pocket = buyerA.pocketCount();
        vm.prank(carol);
        buyerA.claimPocket(pocket);
        assertEq(nvda.balanceOf(carol) - held, 50e18, "the only holder of record takes the whole pocket");
        // The seller has no claim on the collateral it sold.
        assertEq(core.claimableRecovery(id, 0, address(seller)), 0);
    }

    /// SEC-10: whichever comes first, a holder's exit or the booking of a default, nobody leaves at a price that
    /// ignores the loss. Before maturity an exit is priced at the position's book value; from maturity, unpaid, exits
    /// and entries wait for the outcome; once anyone books it, the next exit is priced after the write-off and a
    /// minimum taken from the stale quote refuses.
    function test_aDefaultIsBookedBeforeAnyExitAndAStaleMinimumRefuses() public {
        (uint256 id, IntentQuoteVerifier.SecondaryPlan memory p) = _bought();
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 part = buyerA.balanceOf(carol) / 20;
        uint256 quoted = buyerA.convertToAssets(part);
        vm.prank(carol);
        assertEq(buyerA.redeem(part, quoted), quoted, "an exit in term is paid at book");

        vm.warp(p.maturity);
        uint256 stale = buyerA.convertToAssets(part);
        vm.prank(carol);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        buyerA.redeem(part, 0);
        vm.prank(carol);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        buyerA.deposit(1e6, 0);

        _settle(buyerA, id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED));
        uint256 booked = buyerA.convertToAssets(part);
        assertLt(booked, stale, "the write-off lowers the price before anyone leaves");
        vm.prank(carol);
        vm.expectRevert(IntentVault.Slippage.selector);
        buyerA.redeem(part, stale);
        vm.prank(carol);
        assertEq(buyerA.redeem(part, booked), booked, "the next exit is priced after the loss");
    }

    // ---------------------------------------------------------------- resale

    /// SEC-11: rewards follow each holder of record through a resale, after holders already claimed part of them:
    /// the reselling vault keeps what its quarters earned while it held them, the next buyer's clock starts at its
    /// purchase, and every reward of the loan still comes from its one budget.
    function test_rewardsFollowEachHolderThroughAResaleFromOneBudget() public {
        (uint256 id, IntentQuoteVerifier.SecondaryPlan memory p) = _bought();
        IntentVault d = _buyerRunBy(resaleCurator, 1000e6);
        uint256 carolBefore = sgage.balanceOf(carol);
        // A prior claim: buyerA harvests what its quarters earned so far and its holder takes it.
        vm.warp(_startOf(id) + 5 days);
        buyerA.harvestRewards(_ids(id));
        vm.prank(carol);
        uint256 early = buyerA.claimRewards();
        assertGt(early, 0);

        vm.warp(_startOf(id) + 6 days);
        _noTradeFee();
        IntentLenderMarket market = buyerA.LENDER_MARKET();
        uint40 deadline = uint40(p.maturity);
        vm.prank(buyerCurator);
        market.list(id, RESALE, deadline, 100);
        IntentVault[] memory vaults = new IntentVault[](1);
        uint8[] memory masks = new uint8[](1);
        (vaults[0], masks[0]) = (d, 5);
        _buy(_planFor(id, buyerA, vaults, masks));
        uint256 kept = coreRewards.claimable(id, address(buyerA)) + sgage.balanceOf(address(buyerA));
        assertEq(coreRewards.claimable(id, address(d)), 0, "the next buyer's clock starts at its purchase");

        vm.warp(p.maturity - 1);
        assertEq(
            coreRewards.claimable(id, address(buyerA)) + sgage.balanceOf(address(buyerA)),
            kept,
            "a seller's rewards stop growing at its sale and are not lost by it"
        );
        assertGt(coreRewards.claimable(id, address(d)), 0, "the new holder earns from then on");

        vm.warp(p.maturity);
        IntentVault[5] memory all = [seller, buyerA, buyerB, buyerC, d];
        uint256 total = sgage.balanceOf(carol) - carolBefore;
        for (uint256 i; i < all.length; ++i) {
            total += coreRewards.claimable(id, address(all[i])) + sgage.balanceOf(address(all[i]));
        }
        assertApproxEqAbs(total, core.getLoan(id).lenderReward, 6, "one reward budget, never duplicated");
    }

    function test_buyerResellsItsQuartersToAnotherVaultOnItsOwnBasis() public {
        (uint256 id, IntentQuoteVerifier.SecondaryPlan memory p) = _bought();
        IntentQuoteVerifier.SecondaryAllocation memory a = _allocationOf(p, buyerA);
        IntentVault d = _buyerRunBy(resaleCurator, 1000e6);
        vm.warp(_startOf(id) + 6 days);
        _noTradeFee();
        IntentLenderMarket market = buyerA.LENDER_MARKET();
        uint40 deadline = uint40(p.maturity);
        vm.prank(buyerCurator);
        market.list(id, RESALE, deadline, 100);
        uint256 assets = buyerA.totalAssets();
        IntentVault[] memory vaults = new IntentVault[](1);
        uint8[] memory masks = new uint8[](1);
        (vaults[0], masks[0]) = (d, 5);
        IntentQuoteVerifier.SecondaryPlan memory resale = _planFor(id, buyerA, vaults, masks);
        _buy(resale);
        assertEq(core.lenders(id)[0], address(d));
        assertEq(core.lenders(id)[2], address(d));
        assertEq(buyerA.performingPrincipal(), 0);
        assertEq(buyerA.lenderSaleSlots(id), 0);
        assertEq(buyerA.totalAssets(), assets, "the resale gain is released, not jumped");
        uint256 proceeds = RESALE;
        uint256 fee = IntentFeeMath.performanceFee(proceeds - a.price, a.executionFee, 1000);
        assertEq(buyerA.curatorFees() + buyerA.protocolFees(), fee, "fee on the resale profit over its own basis");
        assertEq(_loanOf(d, id).principal, RESALE, "the next buyer's basis is its own price");
        // The first buyer can never buy this loan again.
        vm.warp(block.timestamp + 1 days);
        IntentLenderMarket next = d.LENDER_MARKET();
        vm.prank(resaleCurator);
        next.list(id, RESALE + 1e6, deadline, 100);
        (vaults[0], masks[0]) = (buyerA, 5);
        _assertSecondaryRefused(_planFor(id, d, vaults, masks), IntentQuoteVerifier.Refusal.EXISTING_RECORD);
        IntentAssetPolicy policy = buyerA.ASSET_POLICY();
        vm.expectRevert(IntentAssetPolicy.ExistingRecord.selector);
        policy.quote(id, 5, RESALE + 1e6, 0);
    }

    function test_aVaultHoldingPrimaryQuartersCannotAddBoughtOnes() public {
        // Modeled costs are published with a lifetime; the seller's origination needs a fresh one.
        _modeled(address(nvda), COST_BPS);
        uint256 id = _listing();
        // buyerA lends two quarters at origination; the seller vault the other two, in the same fill.
        IntentVault[] memory vs = new IntentVault[](2);
        uint8[] memory counts = new uint8[](2);
        (vs[0], counts[0]) = (buyerA, 2);
        (vs[1], counts[1]) = (seller, 2);
        (vs, counts) = _sorted(vs, counts);
        _fill(_plan(id, vs, counts));
        assertGt(_loanOf(buyerA, id).principal, 0, "buyerA holds its primary record");
        // The seller vault lists its two quarters through its own market.
        vm.warp(_startOf(id) + 3 days);
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        sellerMarket.list(id, 520e6, deadline, 100);
        (,,, uint8 listed,) = sellerMarket.asks(id);
        assertEq(listed, seller.lenderSaleSlots(id));
        IntentVault[] memory vaults = new IntentVault[](1);
        uint8[] memory masks = new uint8[](1);
        (vaults[0], masks[0]) = (buyerA, listed);
        _assertSecondaryRefused(_marketPlan(id, vaults, masks), IntentQuoteVerifier.Refusal.EXISTING_RECORD);
    }

    /// @dev A plan for any vault seller's listing.
    // ---------------------------------------------------------------- a resale gain is a claim outside cash (D51)

    /// @dev buyerA resells its quarters above its cost, which opens an earnings claim for the gain above book, and
    /// then lends 1,000 USDG afresh from a new deposit. Returns the claim.
    function _scheduled() internal returns (uint256 scheduled) {
        (uint256 id, IntentQuoteVerifier.SecondaryPlan memory p) = _bought();
        IntentVault d = _buyerRunBy(resaleCurator, 1000e6);
        vm.warp(_startOf(id) + 6 days);
        _noTradeFee();
        IntentLenderMarket market = buyerA.LENDER_MARKET();
        uint40 deadline = uint40(p.maturity);
        vm.prank(buyerCurator);
        market.list(id, RESALE, deadline, 100);
        IntentVault[] memory vaults = new IntentVault[](1);
        uint8[] memory masks = new uint8[](1);
        (vaults[0], masks[0]) = (d, 5);
        _buy(_planFor(id, buyerA, vaults, masks));
        scheduled = buyerA.pocketLiability(address(usdg));
        assertGt(scheduled, 0, "the resale opened a claim for its gain above book");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        buyerA.deposit(2000e6, 0);
        _modeled(address(nvda), COST_BPS);
        uint256 loan = _listing();
        (IntentVault[] memory lenders, uint8[] memory units) = _one(buyerA, 4);
        _fill(_plan(loan, lenders, units));
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function test_theResaleClaimIsOutsideCashAndCannotBeInvested() public {
        uint256 scheduled = _scheduled();
        uint256 cash = buyerA.cash();
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        fills.investReserve(address(buyerA), cash + 1, 0);
        vm.prank(fillers[0]);
        fills.investReserve(address(buyerA), cash, 0);
        assertEq(buyerA.cash(), 0);
        assertEq(buyerA.pocketLiability(address(usdg)), scheduled, "the claim stays whole");
        assertGe(usdg.balanceOf(address(buyerA)), scheduled, "the claim's USDG stays in the vault");
    }

    function test_anExitSpendsCashThenTheReserveAndLeavesTheResaleClaimWhole() public {
        uint256 scheduled = _scheduled();
        uint256 spare = buyerA.cash();
        vm.prank(fillers[0]);
        fills.investReserve(address(buyerA), spare / 2, 0);
        // Worth more than the spare cash left: the rest must come from the reserve, not from the held profit.
        uint256 shares = buyerA.convertToShares(spare);
        vm.prank(carol);
        buyerA.redeem(shares, 0);
        assertEq(buyerA.pocketLiability(address(usdg)), scheduled, "the claim is still whole");
        assertGe(usdg.balanceOf(address(buyerA)), scheduled);
    }

    /// S9-F1: a reserve loss can neither take a resale claim, which would leave its holders a gain that no longer
    /// exists, nor hold a fresh deposit behind it. Under D51 the claim is never in `cash`, so nothing can invest it.
    function test_aReserveLossNeitherTakesTheResaleClaimNorHoldsAFreshDeposit() public {
        uint256 scheduled = _scheduled();
        uint256 all = buyerA.cash();
        vm.prank(fillers[0]);
        fills.investReserve(address(buyerA), all, 0);
        uint256 before_ = buyerA.totalAssets();
        uint256 held = reserve.convertToAssets(buyerA.reserveShares());
        reserve.simulateLoss(usdg.balanceOf(address(reserve)) * 999 / 1000, address(0xDEAD));
        uint256 lost = held - reserve.convertToAssets(buyerA.reserveShares());
        assertEq(buyerA.pocketLiability(address(usdg)), scheduled, "the claim survived the loss");
        assertGe(usdg.balanceOf(address(buyerA)), scheduled);
        assertEq(before_ - buyerA.totalAssets(), lost, "the price bears exactly the reserve's loss");

        address alice = makeAddr("s9-f1-alice");
        usdg.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdg.approve(address(buyerA), 1000e6);
        uint256 shares = buyerA.deposit(1000e6, 0);
        uint256 out = buyerA.redeem(shares, 0);
        vm.stopPrank();
        assertApproxEqAbs(out, 1000e6, 2, "a fresh deposit comes straight back out");
    }

    function _planFor(uint256 id, IntentVault from, IntentVault[] memory vaults, uint8[] memory masks)
        internal
        view
        returns (IntentQuoteVerifier.SecondaryPlan memory p)
    {
        IntentLenderMarket market = from.LENDER_MARKET();
        (uint128 price,,, uint8 slots, uint64 nonce) = market.asks(id);
        p.seller = address(from);
        p.market = address(market);
        p.slots = slots;
        p.price = price;
        p.nonce = nonce;
        p.maxFeeBps = 100;
        _complete(p, id, vaults, masks);
    }

    // ---------------------------------------------------------------- depositors

    function test_depositJustBeforeAPurchaseCannotExtractAWindfall() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        vm.prank(bob);
        usdg.approve(address(buyerA), MAX);
        vm.prank(bob);
        uint256 shares = buyerA.deposit(1000e6, 0);
        _buy(p);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(bob);
        uint256 out = buyerA.redeem(shares, 0);
        assertLe(out, 1000e6, "no instant gain from a discounted purchase");
        // An early repayment settled at once does not hand an entrant the loan's interest either.
        vm.prank(bob);
        shares = buyerA.deposit(500e6, 0);
        _repay(id);
        _settle(buyerA, id);
        vm.prank(bob);
        out = buyerA.redeem(shares, 0);
        assertLe(out, 500e6);
    }

    function test_buyerHoldersEarnFutureRewardsAndSellerHoldersKeepEarnedOnes() public {
        uint256 id = _onSale(PRICE);
        uint256 sellerEarned = coreRewards.claimable(id, address(seller));
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        _buy(_marketPlan(id, vaults, masks));
        // The seller's holders were checkpointed before the quarters moved.
        assertApproxEqAbs(
            seller.rewardClaimable(alice) + seller.rewardClaimable(bob) + seller.rewardClaimable(carol),
            sellerEarned,
            10_000
        );
        assertEq(coreRewards.claimable(id, address(buyerA)), 0, "no reward clock restarts");
        vm.warp(_startOf(id) + 8 days);
        uint256 accrued = coreRewards.claimable(id, address(buyerA));
        assertGt(accrued, 0);
        buyerA.harvestRewards(_ids(id));
        assertApproxEqAbs(buyerA.rewardClaimable(carol), accrued, 10_000);
        vm.warp(_maturity(id));
        uint256 total = coreRewards.claimable(id, address(seller)) + coreRewards.claimable(id, address(buyerA))
            + coreRewards.claimable(id, address(buyerB)) + coreRewards.claimable(id, address(buyerC));
        uint256 claimed = sgage.balanceOf(address(seller)) + sgage.balanceOf(address(buyerA));
        assertApproxEqAbs(total + claimed, core.getLoan(id).lenderReward, 4, "one reward budget, never duplicated");
    }

    // ---------------------------------------------------------------- policy

    function test_policyTighteningAppliesAtOnceAndLooseningWaits() public {
        IntentAssetPolicy policy = buyerA.ASSET_POLICY();
        assertTrue(policy.secondaryEnabled());
        assertEq(policy.minExtraAnnualReturnBps(), EXTRA_BPS);
        uint64 revision = policy.secondaryRevision();
        vm.expectRevert(IntentAssetPolicy.NotCurator.selector);
        policy.setSecondaryPolicy(false, 0);
        vm.prank(buyerCurator);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.setSecondaryPolicy(true, 10_001);
        // Asking more applies at once.
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(true, EXTRA_BPS + 100);
        assertEq(policy.minExtraAnnualReturnBps(), EXTRA_BPS + 100);
        assertEq(policy.secondaryRevision(), revision + 1);
        // Asking less waits three hours; anyone may then apply it, the curator may cancel it before.
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(true, EXTRA_BPS);
        assertEq(policy.minExtraAnnualReturnBps(), EXTRA_BPS + 100);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateSecondaryPolicy();
        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert(IntentAssetPolicy.NotCurator.selector);
        policy.cancelSecondaryPolicy();
        policy.activateSecondaryPolicy();
        assertEq(policy.minExtraAnnualReturnBps(), EXTRA_BPS);
        assertEq(policy.secondaryRevision(), revision + 2);
        // Disabling applies at once and drops any queued loosening; enabling waits.
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(true, 0);
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(false, 0);
        assertFalse(policy.secondaryEnabled());
        assertEq(policy.pendingReadyAt(), 0);
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(true, EXTRA_BPS);
        assertFalse(policy.secondaryEnabled());
        vm.prank(buyerCurator);
        policy.cancelSecondaryPolicy();
        assertEq(policy.pendingReadyAt(), 0);
    }

    function test_disabledOrChangedPolicyRefusesBeforeAndAtExecution() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        IntentAssetPolicy policy = buyerB.ASSET_POLICY();
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(true, EXTRA_BPS + 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.POLICY_CHANGED);
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(false, 0);
        _assertSecondaryRefused(_marketPlan(id, vaults, masks), IntentQuoteVerifier.Refusal.POLICY_CHANGED);
        vm.expectRevert(IntentAssetPolicy.SecondaryClosed.selector);
        policy.quote(id, 2, 260e6, 0);
        // A vault created without a policy never buys.
        vm.prank(curator);
        IntentVault plain = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
        assertFalse(plain.ASSET_POLICY().secondaryEnabled());
    }

    function test_curatorFloorHoldsWhoeverSigns() public {
        uint256 id = _onSale(PRICE);
        // Asking 90% a year on 540 USDG over 18 days is more than the 10 USDG these quarters repay beyond it.
        IntentAssetPolicy policy = buyerA.ASSET_POLICY();
        vm.prank(buyerCurator);
        policy.setSecondaryPolicy(true, 9000);
        vm.expectRevert(IntentAssetPolicy.BelowReturnFloor.selector);
        policy.quote(id, 5, 540e6, 0);
        policy.quote(id, 5, 500e6, 0);
        // And a fee above the vault's own ceiling is refused by the vault itself.
        vm.prank(buyerCurator);
        buyerB.setExecutionCap(0);
        IntentAssetPolicy other = buyerB.ASSET_POLICY();
        vm.expectRevert(IntentAssetPolicy.LimitExceeded.selector);
        other.quote(id, 2, 260e6, 1);
    }

    /// @dev Pashov M-68: the signed floor holds for a fill made late in the plan's life. The verifier recomputes each
    /// allocation's minimum over maturity less `issuedAt`, the longer and stricter interval, and refuses a fee that
    /// leaves less than it, in the fill transaction before any purchase. Every term of what a purchase keeps is signed,
    /// so a late fill keeps exactly the signed repayment less price less fee, which is at least the signed minimum; the
    /// vault's own check over the remaining term is a second, lower floor. The reward bounds are signed at expiry, as
    /// the rate service does, so they hold at any second of the plan.
    function test_aDelayedFillKeepsItsSignedMinimum() public {
        uint256 id = _onSale(PRICE);
        IntentVault[3] memory buyers = [buyerA, buyerB, buyerC];
        for (uint256 i; i < 3; ++i) {
            vm.prank(buyerCurator);
            buyers[i].setExecutionCap(5000);
        }
        // A model rate high enough that each allocation's minimum, not the ceiling, sets its execution fee, and low
        // enough that each minimum stays under what its quarters repay beyond their price (the listing's price leaves
        // the seller half the interest still to come, Pashov L-01).
        modelBps = 4000;
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory honest = _marketPlan(id, vaults, masks);
        (vaults, masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory under = _marketPlan(id, vaults, masks);
        IntentQuoteVerifier.SecondaryAllocation memory a = under.allocations[0];
        uint256 gross = a.repayment - a.price;
        assertEq(gross - a.executionFee, a.minimum, "the minimum binds");
        // One unit more fee keeps one unit under the signed minimum.
        a.executionFee += 1;
        _rewardsAtExpiry(honest);
        _rewardsAtExpiry(under);
        vm.warp(uint256(honest.issuedAt) + 20);
        uint256 late = IntentFeeMath.secondaryMinimum(
            a.price, uint256(under.modelAnnualBps) + a.extraBps, under.maturity - vm.getBlockTimestamp()
        );
        assertGe(gross - a.executionFee, late, "clears a minimum measured from the fill");
        _assertSecondaryRefused(under, IntentQuoteVerifier.Refusal.FEE_ABOVE_CEILING);
        _buy(honest);
        for (uint256 i; i < honest.allocations.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory h = honest.allocations[i];
            uint256 g = h.repayment - h.price;
            assertGe(g - h.executionFee, h.minimum);
            assertEq(
                _loanOf(IntentVault(h.vault), id).interest,
                g - IntentFeeMath.performanceFee(g, h.executionFee, 1000),
                "a late fill books the signed return"
            );
        }
    }

    /// @dev Each sold quarter's reward bound at the plan's expiry, the latest second it can be filled.
    function _rewardsAtExpiry(IntentQuoteVerifier.SecondaryPlan memory p) internal {
        vm.warp(p.expiry);
        for (uint8 q; q < 4; ++q) {
            if (p.slots & (1 << q) != 0) {
                p.minRewards[q] = uint128(remainingLenderReward(coreRewards, p.loanId, uint8(1 << q)));
            }
        }
        vm.warp(p.issuedAt);
    }

    function test_remainingTermAndCapsUseTheProposedConservativeBasis() public {
        uint256 id = _onSale(900e6);
        IntentAssetPolicy policy = buyerA.ASSET_POLICY();
        // At a discount the quarters still count at the 500 USDG of principal they represent.
        uint256 state = vm.snapshotState();
        IntentLimits.setLimits(buyerA, 450e6, 10_000, 0);
        vm.expectRevert(IntentAssetPolicy.IneligibleDeal.selector);
        policy.quote(id, 5, 450e6, 0);
        // From 450 to 500 would be a raise, three hours away (D53): from the vault's own cap it is a cut, at once.
        vm.revertToState(state);
        IntentLimits.setLimits(buyerA, 500e6, 10_000, 0);
        (uint256 principal,,,,) = policy.quote(id, 5, 450e6, 0);
        assertEq(principal, 450e6, "booked and priced at its price");
        // A vault whose longest term is seven days buys only what has seven days or less to run.
        mandate.maxLoanTerm = T7;
        IntentVault shortTerm = _buyer(600e6);
        mandate.maxLoanTerm = T21;
        IntentAssetPolicy weekly = shortTerm.ASSET_POLICY();
        vm.expectRevert(IntentAssetPolicy.IneligibleDeal.selector);
        weekly.quote(id, 5, 450e6, 0);
        vm.warp(_maturity(id) - 7 days);
        weekly.quote(id, 5, 450e6, 0);
    }

    /// @dev Pashov M-24: a bought position's exposure is measured on the assets its purchase leaves, after its own
    /// execution fee. With every cap at 100% of 510 USDG, the 500 USDG two quarters represent, quoted as a view at 450
    /// (a price the seller's SaleBelowBook would refuse, M-21), fit with a 10 USDG fee and not with one raw unit more.
    function test_capsMeasureABoughtPositionOnTheAssetsLeftAfterItsFee() public {
        uint256 id = _onSale(900e6);
        IntentVault tight = _buyer(510e6);
        assertEq(tight.totalAssets(), 510e6);
        IntentAssetPolicy policy = tight.ASSET_POLICY();
        vm.expectRevert(IntentAssetPolicy.IneligibleDeal.selector);
        policy.quote(id, 5, 450e6, 10e6 + 1);
        (uint256 principal,,,,) = policy.quote(id, 5, 450e6, 10e6);
        assertEq(principal, 450e6, "booked and priced at its price");
    }

    function test_repaymentAfterSigningRefusesThePlan() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        _repay(id);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.LOAN_NOT_ACTIVE);
    }

    // ---------------------------------------------------------------- never below the principal its quarters represent

    /// @dev Each buyer's performing, category and asset principal before the plan executes.
    function _counters(IntentQuoteVerifier.SecondaryPlan memory p) internal view returns (uint256[3][] memory before_) {
        before_ = new uint256[3][](p.allocations.length);
        for (uint256 i; i < p.allocations.length; ++i) {
            IntentVault v = IntentVault(p.allocations[i].vault);
            before_[i] =
                [v.performingPrincipal(), v.categoryPrincipal(IntentCategory.STOCK), v.assetPrincipal(address(nvda))];
        }
    }

    /// @dev Every allocation paid at least the principal its quarters represent, so the larger of the two, the exposure
    /// `quote` admitted against the caps, is its price; and its record and all three counters grew by exactly that.
    function _assertBookedAtExposure(IntentQuoteVerifier.SecondaryPlan memory p, uint256[3][] memory before_)
        internal
        view
    {
        uint128 principal = core.getLoan(p.loanId).principal;
        for (uint256 i; i < p.allocations.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            IntentVault v = IntentVault(a.vault);
            assertGe(a.price, v.ASSET_POLICY().repayment(principal, a.slots), "never below the represented principal");
            assertEq(_loanOf(v, p.loanId).principal, a.price, "booked at its price");
            assertEq(v.performingPrincipal() - before_[i][0], a.price, "performing");
            assertEq(v.categoryPrincipal(IntentCategory.STOCK) - before_[i][1], a.price, "category");
            assertEq(v.assetPrincipal(address(nvda)) - before_[i][2], a.price, "asset");
        }
    }

    /// @dev The fill the router would make, expected to revert `SaleBelowBook` in the seller vault.
    function _assertBelowBook(IntentQuoteVerifier.SecondaryPlan memory p) internal {
        bytes memory signature = _signSecondary(p);
        vm.prank(p.filler);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        fills.fillSecondary(p, signature);
    }

    /// @dev Pashov M-21 (M-63, M-64). The verifier splits an ask over its quarters with the core's own remainder rule
    /// (`quarterPrice`, `unitSlice`): at the principal the listed quarters represent, each quarter's share is exactly
    /// the principal it represents, and at any higher ask never less. So an allocation priced from an ask at or above
    /// that principal never pays less than the principal its own quarters represent, to the raw unit.
    function testFuzz_aQuarterShareOfAnAskIsNeverBelowThePrincipalItRepresents(
        uint128 principal,
        uint8 listed,
        uint256 extra
    ) public view {
        listed = uint8(bound(listed, 1, 15));
        uint256 represented = buyerA.ASSET_POLICY().repayment(principal, listed);
        uint256 ask = represented + bound(extra, 0, type(uint128).max);
        for (uint8 q; q < 4; ++q) {
            if (listed & (1 << q) == 0) continue;
            assertEq(verifier.quarterPrice(represented, listed, q), unitSlice(principal, q), "the same remainder");
            assertGe(verifier.quarterPrice(ask, listed, q), unitSlice(principal, q), "never a discount");
        }
    }

    /// @dev Pashov M-21 (M-63, M-64). Only vaults hold quarters (D47), and a vault never sells below book (D48).
    /// Here an ask of exactly the principal the four quarters represent is below the seller's book, which has earned
    /// interest since funding, so the sale reverts `SaleBelowBook`. A bought position is booked at its price, so its
    /// resale at the principal its quarters represent is refused the same way: no vault can hold a record worth less
    /// than that.
    function test_anAskAtTheRepresentedPrincipalIsBelowBookAndRefused() public {
        uint256 id = _onSale(uint128(REVIEW_PRINCIPAL));
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        _assertBelowBook(_marketPlan(id, vaults, masks));

        (uint256 bought, IntentQuoteVerifier.SecondaryPlan memory p) = _bought();
        vm.warp(block.timestamp + 1 days);
        uint256 represented = buyerA.ASSET_POLICY().repayment(core.getLoan(bought).principal, 5);
        IntentLenderMarket market = buyerA.LENDER_MARKET();
        vm.prank(buyerCurator);
        market.list(bought, uint128(represented), uint40(p.maturity), 100);
        IntentVault[] memory next = new IntentVault[](1);
        uint8[] memory mask = new uint8[](1);
        (next[0], mask[0]) = (_buyerRunBy(resaleCurator, 1000e6), 5);
        _assertBelowBook(_planFor(bought, buyerA, next, mask));
    }

    /// @dev Pashov M-21 (M-63, M-64). An ask above book executes, and every buyer books exactly the exposure its caps
    /// were checked on: the counters never hold less than the principal a bought position represents.
    function test_anExecutedPurchaseBooksTheExposureItsCapsAdmitted() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint256[3][] memory before_ = _counters(p);
        _buy(p);
        _assertBookedAtExposure(p, before_);
    }

    /// @dev Pashov M-21 (M-63, M-64). Asks from 10% below the represented principal to 8% above it: every ask that
    /// executes is at or above that principal and books exactly the exposure its caps admitted, and every other ask is
    /// refused below book. A purchase below the represented principal, or one that understates the counters, would
    /// fail one of the two branches.
    function testFuzz_anExecutedPurchaseIsNeverADiscount(uint128 ask) public {
        ask = uint128(bound(ask, 900e6, 1080e6));
        uint256 id = _onSale(ask);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint256[3][] memory before_ = _counters(p);
        bytes memory signature = _signSecondary(p);
        vm.prank(p.filler);
        try fills.fillSecondary(p, signature) {
            assertGe(ask, REVIEW_PRINCIPAL, "only an ask at or above the represented principal executes");
            _assertBookedAtExposure(p, before_);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IntentVault.SaleBelowBook.selector, "refused only below book");
        }
    }
}
