// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest} from "./EarnV3Base.t.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EarnFactory} from "../../src/earn/EarnFactory.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {answerLegacyValidator} from "../helpers/LegacyCoreValidator.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";

contract EarnVaultTest is EarnV3BaseTest {
    // ---------------------------------------------------------------- shares

    function testDepositMintsAtTheInitialPriceAndLaterAtTheCurrentPrice() public {
        uint256 shares = _deposit(alice, 1000e6);
        assertEq(shares, 1000e18, "one USDG unit starts at 1e12 shares");
        assertEq(earn.convertToAssets(shares), 1000e6);
        vm.prank(curator);
        earn.investReserve(1000e6, 0);
        usdg.mint(address(this), 100e6);
        usdg.approve(address(reserve), 100e6);
        reserve.donate(100e6); // the reserve earns 10%
        assertApproxEqAbs(earn.totalAssets(), 1100e6, 1);
        uint256 second = _deposit(bob, 1100e6);
        assertApproxEqAbs(second, 1000e18, 1e12, "priced at 1.1 USDG per 1e12 shares");
        assertApproxEqAbs(earn.convertToAssets(second), 1100e6, 2);
        assertApproxEqAbs(earn.convertToAssets(shares), 1100e6, 2);
    }

    function testDepositBoundsMinimumCapPauseAndSlippage() public {
        vm.prank(alice);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.deposit(0.5e6, 0);
        vm.prank(curator);
        earn.setMaxTotalDeposits(500e6);
        vm.prank(alice);
        vm.expectRevert(EarnVault.LimitExceeded.selector);
        earn.deposit(501e6, 0);
        vm.prank(alice);
        vm.expectRevert(EarnVault.Slippage.selector);
        earn.deposit(500e6, 500e18 + 1);
        vm.prank(curator);
        earn.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(EarnVault.PausedError.selector);
        earn.deposit(500e6, 0);
        vm.prank(curator);
        earn.setPaused(false);
        _deposit(alice, 500e6);
        vm.prank(curator);
        earn.setMaxTotalDeposits(0);
        vm.prank(bob);
        vm.expectRevert(EarnVault.LimitExceeded.selector);
        earn.deposit(1e6, 0);
        // A cap below current assets takes nothing away and exits still work.
        vm.prank(alice);
        earn.redeem(100e18, 0);
        assertEq(usdg.balanceOf(alice), 1_000_000e6 - 400e6);
    }

    function testRedeemPaysFromCashThenTheReserve() public {
        _deposit(alice, 1000e6);
        vm.prank(curator);
        earn.investReserve(600e6, 0);
        assertEq(earn.cash(), 400e6);
        vm.prank(alice);
        uint256 assets = earn.redeem(500e18, 0);
        assertEq(assets, 500e6);
        assertEq(earn.cash(), 0, "cash first");
        assertEq(reserve.convertToAssets(earn.reserveShares()), 500e6, "then the reserve");
        vm.prank(alice);
        earn.redeem(250e18, 250e6);
        vm.prank(alice);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.redeem(250e18 + 1, 0);
        vm.prank(alice);
        vm.expectRevert(EarnVault.Slippage.selector);
        earn.redeem(250e18, 250e6 + 1);
        assertEq(earn.freeLiquidity(), 250e6);
    }

    function testDirectDonationsNeverMoveThePriceAndAreHarvestedAsUnassignedCash() public {
        _deposit(alice, 1000e6);
        usdg.mint(address(earn), 77e6);
        assertEq(earn.convertToAssets(1000e18), 1000e6);
        earn.settle(new uint256[](0));
        assertEq(earn.unassignedCash(), 77e6);
        assertEq(earn.convertToAssets(1000e18), 1000e6);
    }

    // ---------------------------------------------------------------- loans

    function testFundingKeepsTheShareValueAndPaysCashBeforeTheReserve() public {
        _deposit(alice, 10_000e6);
        vm.prank(curator);
        earn.investReserve(9500e6, 0);
        uint256 id = _listed(1000e6);
        _fund(id, UNITS);
        assertEq(earn.cash(), 0);
        assertEq(reserve.convertToAssets(earn.reserveShares()), 9000e6);
        assertEq(earn.performingPrincipal(), 1000e6);
        assertEq(earn.lanePrincipal(EarnLane.STOCK), 1000e6);
        assertEq(earn.convertToAssets(10_000e18), 10_000e6, "loans are carried at principal");
        assertEq(_state(id) == V2State.ACTIVE, true);
        EarnVault.Loan memory ln = _loan(id);
        assertEq(ln.maturity, block.timestamp + T7, "exact maturity once active");
        assertEq(earn.earliestMaturity(), ln.maturity);
        assertEq(ln.feeBps, 1500);
        assertEq(ln.slots, 0x0f);
    }

    function testInterestAccruesOverTheTermAndTheFeeIsChargedAtSettlement() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        assertEq(earn.totalAssets(), 10_000e6, "nothing earned at funding");
        vm.warp(vm.getBlockTimestamp() + 3 days);
        // 50 USDG of fixed cost, 15% fee = 7.5, so 42.5 net earned evenly over seven days.
        assertApproxEqAbs(earn.accruedInterest(), 18_214_285, 1, "three sevenths of the 42.5 net interest");
        assertApproxEqAbs(earn.totalAssets(), 10_000e6 + 18_214_285, 1);
        _repay(id);
        assertApproxEqAbs(earn.totalAssets(), 10_000e6 + 18_214_285, 1, "a repayment moves nothing before settlement");
        _settle(id);
        // Repaid early: the rest of the net interest lands at settlement, and the fee is charged on the 50 received.
        assertEq(earn.curatorFees(), 6.75e6);
        assertEq(earn.protocolFees(), 0.75e6);
        assertEq(earn.totalAssets(), 10_042.5e6);
        assertEq(earn.accruedInterest(), 0);
        assertEq(earn.accrualRate(), 0);
        assertEq(earn.performingPrincipal(), 0);
        assertEq(earn.earliestMaturity(), type(uint40).max);
        earn.claimFees();
        assertEq(usdg.balanceOf(feeRecipient), 6.75e6);
        assertEq(usdg.balanceOf(floor), 0.75e6);
        earn.claimFees(); // nothing left: a no-op
        assertEq(usdg.balanceOf(feeRecipient), 6.75e6);
    }

    function testRepaymentAtMaturityMovesNothingAtSettlement() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        assertApproxEqAbs(earn.totalAssets(), 10_042.5e6, 1, "fully earned by the end of the term");
        _settle(id);
        assertEq(earn.totalAssets(), 10_042.5e6);
        assertEq(earn.curatorFees() + earn.protocolFees(), 7.5e6);
    }

    function testADepositAndARedemptionBackToBackReturnWhatWentInWhileALoanAccrues() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 earnedBefore = earn.accruedInterest();
        uint256 bobShares = _deposit(bob, 10_000e6);
        vm.prank(bob);
        uint256 out = earn.redeem(bobShares, 0);
        assertApproxEqAbs(out, 10_000e6, 2, "a deposit and a redemption back to back return what went in");
        // Staying earns the interest from here on, in proportion to the shares held while the loan runs.
        bobShares = _deposit(bob, 10_000e6);
        uint256 expected = 10_000e6 + (42.5e6 - earnedBefore) * bobShares / earn.totalSupply();
        vm.warp(_maturity(id) - 1);
        _repay(id);
        _settle(id);
        assertApproxEqAbs(earn.convertToAssets(bobShares), expected, 3, "the rest of the interest, pro rata");
    }

    function testARepaymentInTheLastSecondOfTheTermIsARepayment() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id) - 1); // the core closes repayment the second the term ends
        assertLt(block.timestamp, earn.earliestMaturity(), "pricing is open until the term ends");
        _repay(id);
        _settle(id);
        assertEq(earn.pocketCount(), 0, "no pocket");
        assertEq(earn.totalAssets(), 10_042.5e6, "the premium is profit");
        assertEq(earn.curatorFees() + earn.protocolFees(), 7.5e6, "the fee is charged");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertApproxEqAbs(earn.convertToAssets(10_000e18), 10_042.5e6, 1);
    }

    function testTheStrategyRefusesACoreWithAGraceWindow() public {
        GageV2Vault graced = new GageV2Vault(
            GageV2TokenRegistry(address(registry)),
            IERC20(address(usdg)),
            IERC20(address(sgage)),
            treasury,
            48 hours,
            GageLegacyAdapter(address(0))
        );
        answerLegacyValidator(address(graced), address(validator));
        EarnVault.Params memory q = p;
        q.core = address(graced);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        assertEq(core.GRACE(), 0, "the fixture's core has no grace window");
    }

    function testRepaymentIsClosedFromTheSecondTheTermEndsAndTheDefaultOpens() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id));
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vm.prank(borrower);
        core.reclaim(id, borrower);
        vm.expectRevert(EarnVault.SettlementDue.selector);
        earn.deposit(1e6, 0);
        _settle(id);
        assertEq(_state(id) == V2State.DEFAULTED, true, "no grace: the default is final at maturity");
        assertEq(earn.totalAssets(), 9000e6);
    }

    function testTheFeeIsChargedOnInterestWhateverThePriceHistory() public {
        _deposit(alice, 10_000e6);
        uint256 loss = _funded(1000e6);
        uint256 win = _funded(1000e6);
        vm.warp(_maturity(win) - 1); // repayment closes the second the term ends
        vm.prank(borrower);
        core.reclaim(win, borrower);
        vm.warp(_maturity(loss));
        _settle(loss); // written off: 9,000 of principal left, plus the win's 42.5 fully earned
        assertApproxEqAbs(earn.totalAssets(), 9042.5e6, 1);
        _settle(win);
        assertEq(earn.curatorFees() + earn.protocolFees(), 7.5e6, "the fee is on the interest received, loss or not");
        assertEq(earn.totalAssets(), 9042.5e6, "settling a loan earned to the end moves nothing");
    }

    function testAListingPastItsDeadlineAndACancelledListingReturnPrincipalOnly() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, 2);
        assertEq(earn.performingPrincipal(), 500e6);
        EarnVault.Loan memory ln = _loan(id);
        assertEq(ln.maturity, block.timestamp + T7, "a lower bound until active");
        vm.warp(uint256(core.getLoan(id).fundingDeadline));
        _settle(id); // past the deadline: settle cancels the listing on the core and books the refund
        assertEq(_state(id) == V2State.CANCELLED, true);
        assertEq(earn.cash(), 10_000e6);
        assertEq(earn.performingPrincipal(), 0);
        assertEq(earn.accruedInterest(), 0);
        uint256 second = _listed(1000e6);
        _fund(second, 1);
        vm.prank(borrower);
        core.cancelFunding(second);
        _settle(second);
        assertEq(earn.cash(), 10_000e6);
        assertEq(earn.earliestMaturity(), type(uint40).max);
    }

    function testMaturityIsRecordedExactlyWhenOthersActivateTheListing() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, 1);
        uint40 bound = _loan(id).maturity;
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        _fill(id);
        _settle(id); // still in term: only records the exact maturity
        assertEq(_loan(id).maturity, _maturity(id));
        assertGt(_loan(id).maturity, bound, "the bound was early, never late");
        assertEq(earn.earliestMaturity(), _maturity(id));
        assertFalse(_loan(id).settled);
    }

    // ---------------------------------------------------------------- defaults

    function testDefaultWritesOffAtMaturityAndThePocketBelongsToTheHoldersOfRecord() public {
        _deposit(alice, 8000e6);
        _deposit(bob, 2000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id) - 1);
        uint256 carolShares = _deposit(carol, 1e6); // pricing still open one second before the term ends
        vm.prank(carol);
        earn.redeem(carolShares, 0);
        vm.warp(_maturity(id));
        _settle(id);
        assertEq(_state(id) == V2State.DEFAULTED, true);
        assertApproxEqAbs(earn.totalAssets(), 9000e6, 2, "principal written off");
        assertEq(earn.earliestMaturity(), type(uint40).max);
        // Bob leaves after the write-down and keeps his right; Carol enters after it and gets none.
        vm.prank(bob);
        earn.redeem(2000e18, 0);
        _deposit(carol, 9000e6);
        earn.recover(id);
        assertEq(earn.pocketCount(), 1);
        assertEq(earn.pocketClaimable(1, alice), 80e18);
        assertEq(earn.pocketClaimable(1, bob), 20e18);
        assertEq(earn.pocketClaimable(1, carol), 0);
        vm.prank(bob);
        earn.claimPocket(1);
        assertEq(nvda.balanceOf(bob), 20e18);
        vm.prank(bob);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.claimPocket(1);
        vm.prank(carol);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.claimPocket(1);
        vm.expectRevert(EarnVault.NothingToRecover.selector);
        earn.recover(id);
    }

    function testSettlementDueBlocksPricingUntilSomeoneSettles() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id));
        vm.prank(alice);
        vm.expectRevert(EarnVault.SettlementDue.selector);
        earn.deposit(1e6, 0);
        vm.prank(alice);
        vm.expectRevert(EarnVault.SettlementDue.selector);
        earn.redeem(1e18, 0);
        uint256 other = _listed(1000e6);
        vm.prank(curator);
        vm.expectRevert(EarnVault.SettlementDue.selector);
        earn.fund(other, 1, MAX);
        // Settlement by anyone stays open.
        vm.prank(bob);
        _settle(id);
        _deposit(bob, 1e6);
    }

    function testRecoveryIsRetryableWhenTheCollateralTokenIsPaused() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id));
        _settle(id);
        nvda.setPaused(true);
        vm.expectRevert();
        earn.recover(id);
        assertFalse(_loan(id).recovered);
        assertEq(earn.pocketCount(), 0);
        _deposit(bob, 1e6); // the vault keeps working meanwhile
        nvda.setPaused(false);
        earn.recover(id);
        assertEq(earn.pocketCount(), 1);
        assertEq(earn.pocketClaimable(1, alice), 100e18);
        assertEq(earn.pocketClaimable(1, bob), 0);
    }

    function testTwoWriteOffsKeepSeparateRecordsAcrossBalanceChanges() public {
        _deposit(alice, 10_000e6);
        uint256 first = _funded(1000e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 second = _funded(1000e6);
        vm.warp(_maturity(first));
        _settle(first);
        _deposit(bob, 8000e6); // Bob enters between the two write-offs
        vm.warp(_maturity(second));
        _settle(second);
        earn.recover(first);
        earn.recover(second);
        assertEq(earn.pocketClaimable(1, alice), 100e18);
        assertEq(earn.pocketClaimable(1, bob), 0);
        // Bob bought in at 0.9, so he holds 8,000 / 0.9 shares against Alice's 10,000.
        uint256 supply = earn.totalSupply();
        assertEq(earn.pocketClaimable(2, alice), 100e18 * earn.balanceOf(alice) / supply);
        assertEq(earn.pocketClaimable(2, bob), 100e18 * earn.balanceOf(bob) / supply);
        assertApproxEqAbs(earn.pocketClaimable(2, alice) + earn.pocketClaimable(2, bob), 100e18, 1);
    }

    // ---------------------------------------------------------------- queue

    // ---------------------------------------------------------------- rewards

    function testRewardsAreHarvestedAndSpreadOverSharesHeldAtHarvest() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(vm.getBlockTimestamp() + T7 - 1);
        _repay(id);
        _settle(id);
        earn.harvestRewards(_ids(id));
        uint256 harvested = earn.accountedRewards();
        assertGt(harvested, 0);
        uint256 dust = harvested - earn.rewardClaimable(alice);
        assertLt(dust, 1e5, "only the per-share index rounding stays behind");
        _deposit(bob, 10_000e6);
        assertEq(earn.rewardClaimable(bob), 0, "nothing accrued before Bob");
        vm.prank(alice);
        assertEq(earn.claimRewards(), harvested - dust);
        assertEq(sgage.balanceOf(alice), harvested - dust);
        assertEq(earn.accountedRewards(), dust);
        vm.prank(bob);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.claimRewards();
    }

    // ---------------------------------------------------------------- eligibility and approvals

    function testAListingStillFundingCanBeBoughtIntoAgainAndTheRecordGrows() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, 1);
        (uint8 slots,,,,,,,, uint128 principal,, uint128 interest,,) = earn.loans(id);
        assertEq(slots, 1);
        assertEq(principal, 250e6);
        // Two more quarters join the same record: slots, principal and the net return add up; one open loan.
        _fund(id, 2);
        (slots,,,,,,,, principal,, interest,,) = earn.loans(id);
        assertEq(slots, 7);
        assertEq(principal, 750e6);
        // 5% cost on 750 less the fixture's 15% fee = 31.875.
        assertEq(interest, 31_875_000);
        assertEq(earn.performingPrincipal(), 750e6);
        // The last quarter activates the loan and starts the accrual on the whole record.
        _fund(id, 1);
        (slots,,,,,,,, principal,,,,) = earn.loans(id);
        assertEq(slots, 15);
        assertEq(principal, 1000e6);
        assertGt(earn.accrualRate(), 0);
        // Nothing left to buy: the fifth quarter does not exist.
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(id, 1, MAX);
    }

    function testTheRateFloorRefusesAListingBelowTheModeledCostOrWithoutAFreshModel() public {
        _deposit(alice, 10_000e6);
        vm.prank(curator);
        earn.setMinRateGrade(3); // B: at least 90% of the modeled cost.
        assertEq(earn.minRateGrade(), 3);
        // No model published: no loan.
        uint256 cheap = _list(borrower, address(nvda), 100e18, 1000e6, 1040e6, T7); // 4%
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(cheap, UNITS, MAX);
        // The model says 5% for NVDA over 7 days: 4% is 80% of it, below B.
        address[] memory tokens = new address[](1);
        tokens[0] = address(nvda);
        uint32[] memory terms = new uint32[](1);
        terms[0] = T7;
        uint32[] memory bps = new uint32[](1);
        bps[0] = 500;
        grades.setModeledCosts(tokens, terms, bps);
        assertEq(grades.modeledCostOf(address(nvda), T7), 500);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(cheap, UNITS, MAX);
        // 4.6% is 92% of the model: bought. A floor set to A wants the whole modeled cost.
        uint256 fair = _list(borrower, address(nvda), 100e18, 1000e6, 1046e6, T7);
        _fund(fair, UNITS);
        vm.prank(curator);
        earn.setMinRateGrade(4);
        uint256 nearly = _list(borrower, address(nvda), 100e18, 1000e6, 1049e6, T7); // 4.9%
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(nearly, UNITS, MAX);
        uint256 full = _list(borrower, address(nvda), 100e18, 1000e6, 1050e6, T7); // 5%
        _fund(full, UNITS);
        // A model older than the registry's window counts as absent.
        vm.warp(block.timestamp + 8 days);
        assertEq(grades.modeledCostOf(address(nvda), T7), 0);
    }

    function testTheCuratorMovesTheGradeFloorsWithinTheirBounds() public {
        vm.prank(curator);
        earn.setMinGrade(5);
        assertEq(earn.minGrade(), 5);
        assertEq(earn.MIN_GRADE(), 5);
        vm.prank(curator);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setMinGrade(11);
        vm.prank(curator);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setMinRateGrade(5);
        vm.prank(alice);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setMinRateGrade(1);
        // A floor now refuses the ungraded NVDA listing; lowering it back admits it.
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(id, UNITS, MAX);
        vm.prank(curator);
        earn.setMinGrade(0);
        _fund(id, UNITS);
    }

    function testAnEtherTokenBacksNoLoanEvenWithTheStockCategoryOpen() public {
        _deposit(alice, 10_000e6);
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vm.prank(safe);
        registry.setERC20Allowed(address(weth), true, Lane.ETH, 1e18, 1000e18, 100_000e18);
        weth.mint(borrower, 1000e18);
        vm.prank(borrower);
        weth.approve(address(core), type(uint256).max);
        uint256 id = _list(borrower, address(weth), 10e18, 1000e6, 1100e6, T7);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(id, UNITS, MAX);
    }

    function testLaneCapsAndRegistryAdmissionRejectListings() public {
        _deposit(alice, 10_000e6);
        // 6,000 of stocks at most.
        uint256 big = _listed(7000e6);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(big, UNITS, MAX);
        _fund(big, 3); // 5,250 of it is fine
        uint256 memeLoan = _list(borrower, address(meme), 1000e18, 3500e6, 4000e6, T7);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(memeLoan, UNITS, MAX);
        _fund(memeLoan, 3);
        assertEq(earn.lanePrincipal(EarnLane.MEME), 2625e6);
        vm.prank(curator);
        earn.setLaneWeight(EarnLane.MEME, 0);
        uint256 memeTwo = _list(borrower, address(meme), 1000e18, 100e6, 110e6, T7);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(memeTwo, 1, MAX);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 0, 0, 0);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(big, 1, MAX);
    }

    function testCuratorSettersAreBoundedAndCuratorOnly() public {
        vm.startPrank(bob);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setLaneWeight(EarnLane.STOCK, 1);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setMaxTotalDeposits(1);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setFee(1);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setFeeRecipient(bob);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setPaused(true);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.divestReserve(1, 0);
        vm.stopPrank();
        vm.startPrank(curator);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setLaneWeight(EarnLane.LP, 10_001);
        earn.setLaneWeight(EarnLane.LP, 10_000); // caps are independent: 6000 + 3000 + 10000 is fine
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setFee(5001);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setFeeRecipient(address(0));
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setFeeRecipient(address(earn));
        earn.setFeeRecipient(bob);
        earn.setFee(0);
        vm.stopPrank();
        assertEq(earn.feeRecipient(), bob);
    }

    function testConstructorRejectsEveryBadMandate() public {
        EarnVault.Params memory q = p;
        q.mandate.curator = address(0);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.mandate.maxLoanTerm = 8 days; // not a term the registry allows
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.mandate.feeBps = 5001;
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.mandate.laneWeights = [uint16(10_001), 0, 0];
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.mandate.assets = new address[](1);
        q.mandate.assets[0] = address(usdg); // not a registry collateral
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.mandate.assets = new address[](2);
        q.mandate.assets[0] = address(nvda);
        q.mandate.assets[1] = address(nvda); // listed twice
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.protocolShareBps = 10_001;
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.protocolSource = bob; // a wallet cannot answer where the protocol share goes
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(q);
        q = p;
        q.reserve = address(usdg);
        vm.expectRevert();
        new EarnVault(q);
    }

    // ---------------------------------------------------------------- the three strategy shapes

    function testAnEverythingStrategyLetsOneCategoryTakeTheWholePot() public {
        p.mandate.laneWeights = [uint16(10_000), 10_000, 10_000];
        _deploy();
        _deposit(alice, 10_000e6);
        uint256 id = _list(borrower, address(meme), 1000e18, 10_000e6, 10_500e6, T7);
        _fund(id, UNITS);
        assertEq(earn.lanePrincipal(EarnLane.MEME), 10_000e6, "the whole pot in memes");
    }

    function testAPickedStrategyAdmitsOnlyItsAssetsAndOnlyWhileTheRegistryAllowsThem() public {
        p.mandate.laneWeights = [uint16(10_000), 10_000, 0];
        p.mandate.assets = new address[](1);
        p.mandate.assets[0] = address(nvda);
        _deploy();
        assertEq(earn.pickedAssets(), 1);
        assertTrue(earn.assetPicked(address(nvda)));
        _deposit(alice, 10_000e6);
        uint256 memeLoan = _list(borrower, address(meme), 1000e18, 1000e6, 1050e6, T7);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(memeLoan, UNITS, MAX);
        uint256 nvdaLoan = _listed(1000e6);
        _fund(nvdaLoan, UNITS);
        // The curator widens the pick to MEME; a token the registry does not allow cannot be picked.
        vm.prank(curator);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setAsset(address(usdg), true);
        vm.prank(bob);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setAsset(address(meme), true);
        vm.prank(curator);
        earn.setAsset(address(meme), true);
        _fund(memeLoan, UNITS);
        // A picked token the registry later drops is refused even though it is still picked.
        uint256 later = _listed(500e6);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 0, 0, 0);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(later, UNITS, MAX);
        // Removing the last pick reopens the strategy to every registry token.
        vm.startPrank(curator);
        earn.setAsset(address(nvda), false);
        earn.setAsset(address(meme), false);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setAsset(address(meme), false);
        vm.stopPrank();
        assertEq(earn.pickedAssets(), 0);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        _fund(later, UNITS);
    }

    // ---------------------------------------------------------------- factory and gas

    function testFactoryCreatesAWiredStrategyInOneTransaction() public {
        EarnFactory factory = new EarnFactory(
            EarnFactory.Params({
                core: address(core),
                reserve: address(reserve),
                grades: address(grades),
                protocolRecipient: floor,
                protocolShareBps: 1000,
                initialOwner: address(this)
            })
        );
        vm.prank(bob);
        vm.expectRevert(EarnFactory.CreationClosed.selector);
        factory.create(p.mandate);
        address created = factory.create(p.mandate);
        EarnVault v = EarnVault(payable(created));
        assertEq(v.CURATOR(), curator);
        assertEq(v.feeRecipient(), curator, "the curator is paid until it names someone else");
        assertEq(v.feeBps(), 1500);
        assertEq(v.MAX_TERM(), T21);
        assertEq(v.PROTOCOL_SOURCE(), address(factory));
        assertEq(factory.protocolRecipient(), floor);
        assertEq(v.PROTOCOL_SHARE_BPS(), 1000);
        assertEq(v.laneWeightBps(EarnLane.STOCK), 6000);
        assertEq(v.maxTotalDeposits(), 1_000_000e6);
        assertEq(v.MANDATE_VERSION(), 3);
        assertEq(factory.count(), 1);
        assertEq(factory.vaults(0), created);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        factory.setProtocolRecipient(bob);
        vm.expectRevert(EarnFactory.InvalidConfiguration.selector);
        factory.setProtocolRecipient(address(0));
        factory.setProtocolRecipient(bob); // the protocol's share follows the factory's recipient, a wallet included
        vm.prank(alice);
        usdg.approve(created, type(uint256).max);
        vm.prank(alice);
        v.deposit(10_000e6, 0);
        uint256 id = _listed(1000e6);
        vm.prank(curator);
        v.fund(id, UNITS, MAX);
        vm.warp(uint256(core.getLoan(id).fundedAt) + T7 - 1);
        _repay(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        v.settle(ids);
        uint256 bobBefore = usdg.balanceOf(bob);
        v.claimFees();
        assertEq(
            usdg.balanceOf(bob) - bobBefore, 0.75e6, "the protocol's tenth of the 7.5 fee, paid to the new recipient"
        );
        assertTrue(factory.isVault(created));
        assertEq(factory.creatorOf(created), address(this));
        factory.setPublicCreation(true);
        vm.prank(bob);
        factory.create(p.mandate);
        assertEq(factory.count(), 2);
        assertLe(created.code.length, 24_576);
        assertLe(address(factory).code.length, 24_576);
    }

    function testDepositAndRedeemGasDoNotGrowWithOpenLoans() public {
        _deposit(alice, 500_000e6);
        uint256 snapshot = vm.snapshotState();
        (uint256 depositFew, uint256 redeemFew) = _userGas();
        vm.revertToState(snapshot);
        for (uint256 i; i < 32; ++i) {
            _funded(1000e6);
        }
        (uint256 depositMany, uint256 redeemMany) = _userGas();
        emit log_named_uint("deposit gas, 0 open loans", depositFew);
        emit log_named_uint("deposit gas, 32 open loans", depositMany);
        emit log_named_uint("redeem gas, 0 open loans", redeemFew);
        emit log_named_uint("redeem gas, 32 open loans", redeemMany);
        assertApproxEqAbs(depositMany, depositFew, 200, "deposit does not read loans");
        assertApproxEqAbs(redeemMany, redeemFew, 200, "redeem does not read loans");
        assertLt(depositMany, 150_000);
    }

    function _userGas() internal returns (uint256 depositGas, uint256 redeemGas) {
        vm.startPrank(bob);
        vm.cool(address(earn));
        vm.cool(address(reserve));
        vm.cool(address(usdg));
        uint256 start = gasleft();
        earn.deposit(1000e6, 0);
        depositGas = start - gasleft();
        vm.cool(address(earn));
        vm.cool(address(reserve));
        vm.cool(address(usdg));
        start = gasleft();
        earn.redeem(500e18, 0);
        redeemGas = start - gasleft();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- audit corners

    function testAWriteOffLosesThePrincipalAndTheInterestAlreadyEarned() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id));
        assertApproxEqAbs(earn.totalAssets(), 10_042.5e6, 1, "earned to the end of the term");
        _settle(id);
        assertEq(earn.totalAssets(), 9000e6, "principal and the interest earned are both gone");
        assertEq(earn.accruedInterest(), 0);
        assertEq(earn.accrualRate(), 0);
    }

    function testFeeUsesTheRateSnapshottedAtFunding() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.prank(curator);
        earn.setFee(3000);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        _settle(id);
        assertEq(_loan(id).feeBps, 1500);
        assertEq(earn.curatorFees() + earn.protocolFees(), 7.5e6, "15% at funding, not 30% now");
    }

    function testSettleReadsADefaultFinalizedByAThirdParty() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id));
        vm.prank(fillers[0]);
        core.finalizeDefault(id);
        assertEq(_state(id) == V2State.DEFAULTED, true);
        _settle(id);
        assertTrue(_loan(id).settled);
        assertGt(_loan(id).snapshotId, 0);
        assertEq(earn.totalAssets(), 9000e6, "written off from the core's own state");
    }

    function testAWithdrawnCommitmentIsRefundedEvenIfOthersFillTheListingAndDefault() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, 1);
        vm.prank(curator);
        earn.withdrawCommitment(id);
        assertTrue(_loan(id).withdrawn);
        _fill(id); // others take all four quarters: the listing activates without the strategy
        vm.warp(uint256(core.getLoan(id).fundedAt) + T7);
        vm.prank(fillers[0]);
        core.finalizeDefault(id);
        _settle(id);
        assertTrue(_loan(id).settled);
        assertEq(_loan(id).snapshotId, 0, "a refund, never a write-off");
        assertEq(earn.cash(), 10_000e6, "the principal came back");
        assertEq(earn.earliestMaturity(), type(uint40).max);
        vm.expectRevert(EarnVault.NothingToRecover.selector);
        earn.recover(id);
    }

    function testAMinimumGradeAdmitsOnlyTokensRatedAtLeastThatWellAndAStaleGradeIsUnrated() public {
        p.mandate.minGrade = 6; // B and better
        _deploy();
        assertEq(earn.MIN_GRADE(), 6);
        _deposit(alice, 10_000e6);
        uint256 unrated = _listed(1000e6);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(unrated, UNITS, MAX);
        address[] memory tokens = new address[](1);
        tokens[0] = address(nvda);
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 6;
        grades.setGrades(tokens, ranks);
        _fund(unrated, UNITS); // rated B now
        ranks[0] = 5;
        grades.setGrades(tokens, ranks); // the grade fell: no new loan, the open one runs to settlement
        uint256 next = _listed(1000e6);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(next, UNITS, MAX);
        vm.warp(_maturity(unrated) - 1);
        _repay(unrated);
        _settle(unrated);
        assertEq(earn.totalAssets(), 10_042.5e6);
        ranks[0] = 8;
        grades.setGrades(tokens, ranks);
        vm.warp(vm.getBlockTimestamp() + 8 days); // older than MAX_AGE: unrated again
        assertEq(grades.gradeOf(address(nvda)), 0);
        uint256 stale = _listed(1000e6);
        vm.prank(curator);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        earn.fund(stale, UNITS, MAX);
        // Only the publisher writes, and a rank above the scale is refused.
        vm.prank(bob);
        vm.expectRevert(GradeRegistry.NotPublisher.selector);
        grades.setGrades(tokens, ranks);
        ranks[0] = 11;
        vm.expectRevert(GradeRegistry.InvalidGrade.selector);
        grades.setGrades(tokens, ranks);
    }

    function testAMinimumGradeNeedsARegistry() public {
        p.mandate.minGrade = 6;
        p.grades = address(0);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(p);
        p.grades = address(grades);
        p.mandate.minGrade = 11;
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        new EarnVault(p);
    }
}
