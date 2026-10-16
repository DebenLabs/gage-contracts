// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest} from "./EarnV3Base.t.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice The paths the main suite does not walk: missed funding deadlines, paused USDG, reserve limits,
/// reward edge cases, approval bookkeeping and settlement batches.
contract EarnVaultEdgeTest is EarnV3BaseTest {
    function testAListingThatMissesItsFundingDeadlineIsRefundedBySettleAlone() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, 2); // half the quarters; nobody fills the rest
        assertEq(earn.performingPrincipal(), 500e6);
        uint40 bound = _loan(id).maturity;
        _settle(id); // before the deadline nothing happens
        assertFalse(_loan(id).settled);
        vm.warp(uint256(core.getLoan(id).fundingDeadline));
        _settle(id);
        assertTrue(_loan(id).settled, "refunded in the same call");
        assertEq(_state(id) == V2State.CANCELLED, true, "cancelled on the core by the settle");
        assertEq(earn.cash(), 10_000e6);
        assertEq(earn.performingPrincipal(), 0);
        assertEq(earn.unassignedCash(), 0);
        assertEq(earn.earliestMaturity(), type(uint40).max);
        assertLe(block.timestamp, bound, "the bound never comes before the deadline");
    }

    function testARepaymentWhileUSDGIsPausedWaitsAndSettlesOnceItCanBePulled() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        _repay(id);
        usdg.setPaused(true);
        _settle(id); // the pull fails quietly; the loan stays open
        assertFalse(_loan(id).settled);
        assertEq(earn.performingPrincipal(), 1000e6);
        usdg.setPaused(false);
        _settle(id);
        assertTrue(_loan(id).settled);
        assertEq(earn.cash(), 10_042.5e6);
    }

    function testCoreCreditPushedByAThirdPartyIsStillBookedOnce() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        _repay(id);
        core.withdrawUSDGFor(address(earn)); // anyone may push the vault's credit
        assertEq(earn.unassignedCash(), 0, "nothing counted until a harvest");
        _settle(id);
        assertTrue(_loan(id).settled);
        assertEq(earn.cash(), 10_042.5e6);
        assertEq(earn.unassignedCash(), 0);
        _settle(id); // idempotent
        assertEq(earn.cash(), 10_042.5e6);
    }

    function testSettleRejectsUnknownIdsAndToleratesDuplicates() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        _repay(id);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        earn.settle(ids);
        assertTrue(_loan(id).settled);
        ids[1] = 999;
        vm.expectRevert(EarnVault.UnknownDeal.selector);
        earn.settle(ids);
        uint256[] memory tooMany = new uint256[](33);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.settle(tooMany);
    }

    function testRedeemBeyondFreeLiquidityFailsBeforeTouchingTheReserve() public {
        _deposit(alice, 10_000e6);
        vm.prank(curator);
        earn.investReserve(6000e6, 0);
        assertEq(earn.freeLiquidity(), 10_000e6, "a reserve that reports no limit counts in full");
        reserve.setReportZeroMax(false);
        reserve.setLimits(type(uint256).max, 1000e6, type(uint256).max); // the reserve can only pay 1,000 now
        assertEq(earn.freeLiquidity(), 5000e6);
        vm.prank(alice);
        vm.expectRevert();
        earn.redeem(6000e18, 0);
        vm.prank(alice);
        earn.redeem(5000e18, 5000e6);
        assertEq(earn.freeLiquidity(), 1000e6, "the reserve will only pay 1,000 more now");
        vm.prank(alice);
        vm.expectRevert(EarnVault.InsufficientLiquidity.selector);
        earn.redeem(5000e18, 0);
        reserve.setLimits(type(uint256).max, type(uint256).max, type(uint256).max);
        vm.prank(alice);
        earn.redeem(5000e18, 5000e6);
        assertEq(earn.totalSupply(), 0);
    }

    function testReserveGainsRaiseThePriceWithoutFee() public {
        _deposit(alice, 10_000e6);
        vm.prank(curator);
        earn.investReserve(10_000e6, 0);
        usdg.mint(address(this), 1000e6);
        usdg.approve(address(reserve), 1000e6);
        reserve.donate(1000e6);
        assertApproxEqAbs(earn.convertToAssets(10_000e18), 11_000e6, 2, "reserve gains are priced in at once");
        assertEq(earn.curatorFees() + earn.protocolFees(), 0);
        uint256 id = _funded(1000e6);
        _repay(id);
        _settle(id);
        // The 50 of loan interest pays the fee; the 1,000 reserve gain never does.
        assertEq(earn.curatorFees() + earn.protocolFees(), 7.5e6);
    }

    function testRewardsHarvestedWithNoHoldersWaitForTheNextHarvest() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(vm.getBlockTimestamp() + T7 - 1);
        _repay(id);
        _settle(id);
        vm.prank(alice);
        earn.redeem(10_000e18, 0); // nobody left
        assertEq(earn.totalSupply(), 0);
        earn.harvestRewards(_ids(id));
        assertEq(earn.accountedRewards(), 0, "no holder to credit");
        assertGt(sgage.balanceOf(address(earn)), 0);
        _deposit(bob, 100e6);
        earn.harvestRewards(_ids(id));
        // Dust of a few wei from the reward-per-share rounding stays in the vault.
        assertApproxEqAbs(
            earn.rewardClaimable(bob), sgage.balanceOf(address(earn)), 1000, "the next holder receives them"
        );
    }

    function testAHolderWithNothingAtTheSnapshotHasNoPocketClaimEvenAfterDepositing() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.warp(_maturity(id));
        _settle(id);
        _deposit(bob, 5000e6);
        vm.prank(bob);
        earn.redeem(1000e18, 0); // balance changes after the snapshot do not create a claim
        earn.recover(id);
        assertEq(earn.pocketClaimable(1, bob), 0);
        assertEq(earn.pocketClaimable(1, alice), 100e18);
        vm.prank(bob);
        vm.expectRevert(EarnVault.InvalidAmount.selector);
        earn.claimPocket(1);
        vm.expectRevert(EarnVault.UnknownDeal.selector);
        earn.claimPocket(2);
    }

    function testTwoWriteOffsInTheSameBlockShareTheSupplyButNotTheSnapshot() public {
        _deposit(alice, 10_000e6);
        uint256 first = _funded(1000e6);
        uint256 second = _funded(1000e6);
        vm.warp(_maturity(second));
        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        earn.settle(ids);
        assertEq(_loan(first).snapshotId, 1);
        assertEq(_loan(second).snapshotId, 2);
        assertEq(_loan(first).snapshotSupply, _loan(second).snapshotSupply);
        assertEq(earn.totalAssets(), 8000e6);
        earn.recover(first);
        earn.recover(second);
        assertEq(earn.pocketClaimable(1, alice) + earn.pocketClaimable(2, alice), 200e18);
    }

    function testPickedStrategiesStillFundLPLoansThroughTheLPWeightAlone() public {
        // Picks only filter ERC-20 collateral; the LP category is opened or closed by its weight.
        p.mandate.laneWeights = [uint16(10_000), 0, 0];
        p.mandate.assets = new address[](1);
        p.mandate.assets[0] = address(nvda);
        _deploy();
        assertEq(earn.laneWeightBps(EarnLane.LP), 0);
        assertTrue(earn.assetPicked(address(nvda)));
        assertFalse(earn.assetPicked(address(meme)));
    }

    function testDepositCapCountsReserveValueAndOpenLoans() public {
        vm.prank(curator);
        earn.setMaxTotalDeposits(10_500e6);
        _deposit(alice, 10_000e6);
        vm.prank(curator);
        earn.investReserve(5000e6, 0);
        _funded(1000e6);
        assertEq(earn.totalAssets(), 10_000e6);
        vm.prank(bob);
        vm.expectRevert(EarnVault.LimitExceeded.selector);
        earn.deposit(501e6, 0);
        _deposit(bob, 500e6);
    }

    function testFeeSplitRoundsTowardTheCuratorAndIsPaidSeparately() public {
        _deposit(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1000e6 + 7, T7); // 7 units of premium
        _fund(id, UNITS);
        _repay(id);
        _settle(id);
        // fee = 15% of 7 = 1 (rounded down); protocol share = 10% of 1 = 0; curator gets the 1.
        assertEq(earn.curatorFees(), 1);
        assertEq(earn.protocolFees(), 0);
        earn.claimFees();
        assertEq(usdg.balanceOf(feeRecipient), 1);
        assertEq(usdg.balanceOf(floor), 0);
    }

    function testSettlingThirtyTwoRepaidLoansFitsInOneCall() public {
        _deposit(alice, 100_000e6);
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            ids[i] = _funded(1000e6);
        }
        for (uint256 i; i < 32; ++i) {
            _repay(ids[i]);
        }
        vm.cool(address(earn));
        vm.cool(address(core));
        vm.cool(address(usdg));
        uint256 start = gasleft();
        earn.settle(ids);
        uint256 used = start - gasleft();
        emit log_named_uint("settle gas, 32 repaid loans", used);
        assertLt(used, 6_000_000);
        assertEq(earn.performingPrincipal(), 0);
        assertEq(earn.earliestMaturity(), type(uint40).max);
        assertEq(earn.curatorFees() + earn.protocolFees(), 32 * 7.5e6);
    }

    function testPausePreservesExitsAndSettlement() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        vm.prank(curator);
        earn.setPaused(true);
        vm.prank(curator);
        vm.expectRevert(EarnVault.PausedError.selector);
        earn.investReserve(1e6, 0);
        vm.prank(alice);
        earn.redeem(100e18, 0);
        _repay(id);
        _settle(id);
        assertTrue(_loan(id).settled);
        vm.prank(alice);
        earn.redeem(100e18, 0);
    }
}
