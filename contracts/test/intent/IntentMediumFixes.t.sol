// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Keep native reward ledgers/transfers, but model a bridge able to pay only part of a claim: the ledger pays
/// from its own funded balance whatever this reports.
contract PartiallyPayingBridge {
    uint256 private immutable PAYMENT_LIMIT;

    constructor(uint256 limit) {
        PAYMENT_LIMIT = limit;
    }

    function adapterId(address, uint256 id) external pure returns (uint256) {
        return id;
    }

    function pay(uint256, uint256 amount) external view returns (uint256) {
        return amount < PAYMENT_LIMIT ? amount : PAYMENT_LIMIT;
    }
}

/// @notice Local accounting regressions: entitlement conservation and safe state transitions.
contract IntentMediumFixesTest is IntentAccountingBaseTest {
    function testDepositCheckpointsPreexistingRewards() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        uint256 earned = coreRewards.claimable(id, address(partner));
        assertGt(earned, 0);
        _enter(bob, 1000e6);
        assertApproxEqAbs(partner.rewardClaimable(alice), earned, 10_000);
        assertEq(partner.rewardClaimable(bob), 0, "new shares do not inherit already earned rewards");
        assertEq(coreRewards.claimable(id, address(partner)), 0);
    }

    function testForcedDeliveryIsIndexedBeforeMint() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        vm.prank(address(partner));
        coreRewards.claim(id, address(partner));
        uint256 delivered = sgage.balanceOf(address(partner));
        _enter(bob, 1000e6);
        assertApproxEqAbs(partner.rewardClaimable(alice), delivered, 10_000);
        assertEq(partner.rewardClaimable(bob), 0);
        partner.harvestRewards(_ids(id));
        assertEq(partner.accountedRewards(), delivered, "same delivery is never indexed twice");
    }

    function testBurnCheckpointsRewardsAndPreservesClaimAfterExit() public {
        _enter(alice, 5000e6);
        _enter(bob, 5000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        uint256 earned = coreRewards.claimable(id, address(partner));
        _exitAll(alice);
        assertApproxEqAbs(partner.rewardClaimable(alice), earned / 2, 5000);
        assertApproxEqAbs(partner.rewardClaimable(bob), earned / 2, 5000);
        vm.prank(alice);
        partner.claimRewards();
        assertApproxEqAbs(sgage.balanceOf(alice), earned / 2, 5000);
    }

    function testRewardFailureDoesNotBlockDefaultSettlementAndCanBeRetried() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_maturity(id));
        vm.mockCallRevert(address(coreRewards), abi.encodeWithSelector(GageV2Rewards.claim.selector), "paused");
        _book(id);
        assertTrue(_ln(id).settled, "principal settlement remains available");
        assertEq(partner.earliestMaturity(), type(uint40).max);
        assertEq(partner.accruedInterest(), 0, "retained reward record cannot keep accruing");
        vm.prank(bob);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        partner.deposit(1000e6, 0);
        uint256 earned = coreRewards.claimable(id, address(partner));
        vm.clearMockedCalls();
        _book(id); // Existing keeper maintenance can retire a settled reward record.
        assertApproxEqAbs(partner.rewardClaimable(alice), earned, 10_000);
        _enter(bob, 1000e6);
        assertEq(partner.rewardClaimable(bob), 0);
    }

    function testPartialRewardClaimBlocksShareChangesUntilFullyCollected() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        // A bridge can successfully pay less than claimable. Success alone must not satisfy the checkpoint.
        vm.mockCall(address(coreRewards), abi.encodeWithSelector(GageV2Rewards.claim.selector), bytes(""));
        vm.prank(bob);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        partner.deposit(1000e6, 0);
        uint256 shares = partner.balanceOf(alice) / 2;
        vm.prank(alice);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        partner.redeem(shares, 0);
        vm.clearMockedCalls();
        _enter(bob, 1000e6);
        assertEq(partner.rewardClaimable(bob), 0);
    }

    function testLastExitCollectsClosedRewardsBeforeFreshSupply() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        uint256 earned = coreRewards.claimable(id, address(partner));
        // D51: the booking closes the record, collecting its rewards for the holders of the moment.
        _book(id);
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        _exitAll(alice);
        assertEq(partner.totalSupply(), 0);
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        _enter(bob, 1000e6);
        partner.harvestRewards(_ids(id));
        assertEq(partner.rewardClaimable(bob), 0);
        assertApproxEqAbs(partner.rewardClaimable(alice), earned, 10_000);
    }

    function testFinalSharesWaitForOutstandingPrincipal() public {
        _enter(alice, 2000e6);
        uint256 id = _reviewLoan();
        uint256 shares = partner.totalSupply();
        vm.prank(alice);
        vm.expectRevert(IntentVault.OutstandingLoans.selector);
        partner.redeem(shares, 0);
        assertEq(partner.totalSupply(), shares);
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        _exitAll(alice);
        assertEq(partner.totalSupply(), 0);
    }

    /// @dev Pashov M-30. At an ordinary share price, with principal lent, the whole supply is worth more than
    /// `freeLiquidity()`, so one share fewer is refused for liquidity and the holder still takes every liquid unit at
    /// once. This pins that ordinary case only. At a share price far above its initial value a whole-supply redemption
    /// can be liquid; the guard then withholds at most one share's value, since one share fewer is liquid too, and the
    /// holder keeps that share.
    function testLastHolderTakesEveryLiquidUnitWhilePrincipalIsLent() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1);
        uint256 supply = partner.totalSupply();
        uint256 free = partner.freeLiquidity();
        assertGt(partner.convertToAssets(supply), free, "the whole supply is payable from free liquidity");
        assertLe(partner.totalAssets() - partner.convertToAssets(supply), 2, "more than the virtual shares' part");

        vm.prank(alice);
        vm.expectRevert(IntentVault.OutstandingLoans.selector);
        partner.redeem(supply, 0);
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(supply - 1, 0);

        assertApproxEqAbs(_exit(alice, partner.convertToShares(free)), free, 2, "a liquid unit was withheld");
        assertLe(partner.freeLiquidity(), 2);
    }

    /// @dev Pashov M-53. A redemption is paid whole or refused whole. A request worth more than `freeLiquidity()`
    /// reverts `InsufficientLiquidity` and burns nothing; sized to what is liquid, it burns exactly the shares named
    /// and pays their full value.
    function testRedemptionIsPaidWholeOrRefusedWhole() public {
        _enter(alice, 2000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1);
        uint256 shares = partner.balanceOf(alice);
        uint256 supply = partner.totalSupply();
        uint256 cash = partner.cash();
        uint256 held = usdg.balanceOf(alice);
        uint256 free = partner.freeLiquidity();
        uint256 request = shares * 3 / 4;
        assertGt(partner.convertToAssets(request), free);

        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(request, 0);
        assertEq(partner.balanceOf(alice), shares, "a refused request burned shares");
        assertEq(partner.totalSupply(), supply);
        assertEq(partner.cash(), cash);
        assertEq(usdg.balanceOf(alice), held, "a refused request paid out");

        uint256 sized = partner.convertToShares(free);
        uint256 value = partner.convertToAssets(sized);
        vm.prank(alice);
        uint256 paid = partner.redeem(sized, value);
        assertEq(paid, value, "the sized request was not paid in full");
        assertEq(partner.balanceOf(alice), shares - sized, "the burn differs from the shares named");
        assertEq(usdg.balanceOf(alice), held + paid);
    }

    function testPartialPaymentRetainsAndEventuallyIndexesTheWholeEntitlement() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_maturity(id));
        vm.mockCallRevert(address(coreRewards), abi.encodeWithSelector(GageV2Rewards.claim.selector), "paused");
        _book(id);
        vm.clearMockedCalls();
        uint256 earned = coreRewards.claimable(id, address(partner));
        uint256 part = earned / 4;
        bytes memory originalCode = address(coreRewards).code;
        // Deploy the mock bridge first: the prank must bind to the ledger's creation, which sets its VAULT.
        GageLegacyAdapter limitedBridge = GageLegacyAdapter(address(new PartiallyPayingBridge(part)));
        vm.prank(address(core));
        GageV2Rewards limitedRewards = new GageV2Rewards(IERC20(address(sgage)), limitedBridge);
        vm.etch(address(coreRewards), address(limitedRewards).code);

        partner.harvestRewards(_ids(id));
        assertEq(sgage.balanceOf(address(partner)), part, "actual partial token delivery");
        assertEq(coreRewards.claimable(id, address(partner)), earned - part);
        assertApproxEqAbs(partner.rewardClaimable(alice), part, 10_000);
        vm.prank(bob);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        partner.deposit(1000e6, 0);
        assertEq(coreRewards.claimable(id, address(partner)), earned - part, "failed checkpoint rolls back");

        vm.etch(address(coreRewards), originalCode);
        partner.harvestRewards(_ids(id));
        assertEq(partner.accountedRewards(), earned);
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        _enter(bob, 1000e6);
        assertEq(partner.rewardClaimable(bob), 0);
        assertApproxEqAbs(partner.rewardClaimable(alice), earned, 20_000);
    }

    function testNewFillRetiresAFullBookOfClosedRewardRecords() public {
        _enter(alice, 100_000e6);
        uint256[] memory ids = new uint256[](64);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
            _route(ids[i], UNITS);
        }
        vm.warp(_maturity(ids[0]));
        vm.mockCallRevert(address(coreRewards), abi.encodeWithSelector(GageV2Rewards.claim.selector), "paused");
        for (uint256 from; from < ids.length; from += 32) {
            uint256[] memory batch = new uint256[](32);
            for (uint256 i; i < batch.length; ++i) {
                batch[i] = ids[from + i];
            }
            partner.settle(batch);
        }
        assertEq(partner.performingPrincipal(), 0);
        assertEq(partner.earliestMaturity(), type(uint40).max);
        uint256 next = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        router.fund(partner, next, UNITS, 0);
        vm.clearMockedCalls();
        // No deposit, redemption, or explicit maintenance ids are needed to restore fill capacity.
        _route(next, UNITS);
        uint256 gas = vm.lastCallGas().gasTotalUsed;
        assertLt(gas, 32_000_000);
        emit log_named_uint("new fill, retiring 64 closed reward records", gas);
        assertEq(partner.performingPrincipal(), 100e6);
        assertEq(coreRewards.claimable(ids[0], address(partner)), 0);
        assertGt(partner.rewardClaimable(alice), 0);
    }

    /// @dev The vault's `Impaired` guard: shares outstanding and priced equity at zero.
    function _isImpaired() internal view returns (bool) {
        return partner.totalSupply() != 0 && partner.totalAssets() == 0;
    }

    function _impaired() internal returns (uint256 id) {
        _enter(alice, 2000e6);
        id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        // D51: the early repayment's earnings claim is held outside `cash`; all the cash goes to the reserve, which
        // then loses all of it. Priced equity is exactly zero while the claim is still whole.
        uint256 claim = partner.pocketLiability(address(usdg));
        assertGt(claim, 0);
        _invest(partner.cash());
        reserve.simulateLoss(usdg.balanceOf(address(reserve)), address(0xDEAD));
        assertEq(partner.cash(), 0);
        assertEq(partner.pocketLiability(address(usdg)), claim, "the earnings claim survived the loss");
        assertEq(usdg.balanceOf(address(partner)), claim + partner.curatorFees() + partner.protocolFees());
        assertEq(partner.totalAssets(), 0);
        assertTrue(_isImpaired());
    }

    function testImpairmentRejectsNewRiskAndPreservesShares() public {
        _impaired();
        uint256 supply = partner.totalSupply();
        vm.prank(bob);
        vm.expectRevert(IntentVault.Impaired.selector);
        partner.deposit(1000e6, 0);
        vm.prank(alice);
        vm.expectRevert(IntentVault.Impaired.selector);
        partner.redeem(supply / 2, 0);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.Impaired.selector);
        router.investReserve(partner, 1);
        uint256 next = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.Impaired.selector);
        router.fund(partner, next, UNITS, 0);
        assertEq(partner.totalSupply(), supply);
        // Divestment and explicit backing restoration remain available.
        uint256 reserveShares = partner.reserveShares();
        vm.prank(curator);
        partner.divestReserve(reserveShares, 0);
        vm.prank(curator);
        partner.setPaused(true);
        vm.prank(bob);
        partner.recapitalize(1000e6);
        assertEq(partner.totalSupply(), supply);
        assertFalse(_isImpaired());
        vm.prank(curator);
        partner.setPaused(false);
        _enter(bob, 1000e6);
    }

    function testExactZeroEquityStillRejectsDeposits() public {
        _impaired();
        uint256 gross = partner.cash() + reserve.convertToAssets(partner.reserveShares())
            + partner.performingPrincipal() + partner.accruedInterest();
        // With the earnings claim outside `cash` (D51), the loss leaves gross assets at exactly zero.
        assertEq(gross, 0, "exactly zero equity");
        assertEq(partner.totalAssets(), 0);
        vm.prank(bob);
        vm.expectRevert(IntentVault.Impaired.selector);
        partner.deposit(1000e6, 0);
    }

    /// @dev D51: an impaired vault still pays its earnings claims in full, and nothing else can reach them.
    function testEarningsClaimIsPaidWhileImpaired() public {
        uint256 id = _impaired();
        uint256 supply = partner.totalSupply();
        uint256 claim = partner.pocketLiability(address(usdg));
        vm.warp(_maturity(id));
        _book(id);
        assertTrue(_isImpaired());
        assertApproxEqAbs(_claimAll(alice), claim, 1, "the claim was not paid in full");
        assertEq(partner.totalSupply(), supply);
        // Backing lands only while the curator has paused the vault (Pashov I-01).
        vm.prank(curator);
        partner.setPaused(true);
        vm.prank(bob);
        partner.recapitalize(1000e6);
        assertFalse(_isImpaired());
        _exitAll(alice);
        assertEq(partner.totalSupply(), 0);
        vm.prank(curator);
        partner.setPaused(false);
        _enter(bob, 1000e6);
    }

    function testPerLoanAccrualIsIndependentOfBatchOrderingAndLatency() public {
        _enter(alice, 10_000e6);
        uint256 longLoan = _reviewLoan();
        uint256 shortLoan = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
        _route(shortLoan, UNITS);
        vm.warp(_startOf(longLoan) + 3 days);
        _repay(longLoan);
        _book(longLoan);
        vm.warp(_maturity(shortLoan) + 5 days);
        // D51: the long loan left the book at its early booking; only the short loan's clock is still priced.
        assertApproxEqAbs(partner.accruedInterest(), 9e6, 2);
        _book(shortLoan);
        assertEq(partner.accruedInterest(), 0);
        _enter(bob, 1000e6);
        vm.warp(_maturity(longLoan));
        uint256 before_ = partner.totalAssets();
        _book(longLoan);
        assertEq(partner.totalAssets(), before_, "the original maturity moved priced assets");
    }

    function testOverdueBatchOrderDoesNotChangeAccounting() public {
        _enter(alice, 10_000e6);
        uint256 longLoan = _reviewLoan();
        uint256 shortLoan = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
        _route(shortLoan, UNITS);
        vm.warp(_startOf(longLoan) + 3 days);
        _repay(longLoan);
        _book(longLoan);
        vm.warp(_maturity(longLoan) + 2 days);
        uint256 snapshot = vm.snapshotState();
        uint256[] memory ids = new uint256[](2);
        ids[0] = longLoan;
        ids[1] = shortLoan;
        partner.settle(ids);
        uint256 assets = partner.totalAssets();
        uint256 rewards = partner.rewardClaimable(alice);
        vm.revertToState(snapshot);
        ids[0] = shortLoan;
        ids[1] = longLoan;
        partner.settle(ids);
        assertEq(partner.totalAssets(), assets);
        assertEq(partner.rewardClaimable(alice), rewards);
        assertEq(_ln(shortLoan).rate + _ln(longLoan).rate, 0);
        assertEq(partner.pocketCount(), 1);
    }
}
