// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnBaseTest} from "./EarnBase.t.sol";
import {HybridVault} from "../src/HybridVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract HybridVaultAuditFixTest is EarnBaseTest {
    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        return hybrid.deposit(assets, 0);
    }

    function _fund(uint128 principal) internal returns (uint256 id) {
        id = _listed(principal);
        _approve(id);
        hybrid.fund(id, type(uint256).max);
    }

    function testForcedCoreCashIsReconciledAndSettledOnce() public {
        _deposit(lender, 1000e6);
        uint256 id = _fund(1000e6);
        _repay(id);
        vault.withdrawUSDGFor(address(hybrid));

        hybrid.settle(_ids(id));

        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.cash(), 1050e6);
        assertEq(hybrid.harvestedCash(), hybrid.assignedCash());
    }

    function testForcedCoreRewardIsAllocatedToExistingHolder() public {
        _deposit(lender, 1000e6);
        uint256 id = _fund(1000e6);
        vm.warp(block.timestamp + T7 / 2);
        uint256 due = coreRewards.claimable(id, address(hybrid));
        vm.prank(address(hybrid));
        coreRewards.claim(id, address(hybrid));

        hybrid.harvestRewards(_ids(id));

        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
    }

    function testOrphanRewardsCannotFundOrDuplicateALaterEntitlement() public {
        uint256 orphan = 100e18;
        sgage.mint(address(hybrid), orphan);
        _deposit(lender, 1000e6);
        uint256 id = _fund(1000e6);
        vm.warp(block.timestamp + T7 / 2);
        uint256 due = coreRewards.claimable(id, address(hybrid));
        assertGt(due, 0);

        vm.mockCall(address(coreRewards), abi.encodeWithSelector(coreRewards.claim.selector), bytes(""));
        hybrid.harvestRewards(_ids(id));
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        vm.prank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimRewards();

        vm.clearMockedCalls();
        hybrid.harvestRewards(_ids(id));
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        vm.prank(lender);
        assertApproxEqAbs(hybrid.claimRewards(), due, 1000);
        assertEq(sgage.balanceOf(address(hybrid)), orphan);
    }

    function testPostWriteDownDepositCannotAcquireExistingRecovery() public {
        _deposit(lender, 1000e6);
        uint256 id = _fund(1000e6);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_ids(id));
        uint256 entrantShares = _deposit(lender2, 1000e6);
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));

        assertEq(hybrid.pocketClaimable(1, lender2), 0);
        assertEq(hybrid.pocketClaimable(1, lender), 100e18);
        vm.prank(lender2);
        assertApproxEqAbs(hybrid.redeem(entrantShares, 0), 1000e6, 2);
    }

    function testRecoverySnapshotPreservesBalancesAboveUint192() public {
        p.maxTotalDeposits = type(uint128).max;
        _deploy();

        uint256 firstAssets = uint256(type(uint128).max) / 2;
        usdg.mint(lender, firstAssets);
        uint256 firstShares = _deposit(lender, firstAssets);
        hybrid.investReserve(firstAssets, 1);
        uint256 survivingAssets = uint256(1) << 96;
        reserve.simulateLoss(firstAssets - survivingAssets, other);

        uint256 secondAssets = uint256(type(uint128).max) / 4;
        usdg.mint(lender2, secondAssets);
        uint256 secondShares = _deposit(lender2, secondAssets);
        assertGt(secondShares, type(uint192).max);
        assertGt(secondShares, firstShares);

        uint256 id = _fund(1000e6);
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
        uint256 snapshotSupply = hybrid.totalSupply();

        vm.prank(lender2);
        hybrid.redeem(secondShares, 0);

        assertEq(hybrid.balanceOfAt(lender2, 1), secondShares);
        assertEq(hybrid.pocketClaimable(1, lender2), Math.mulDiv(100e18, secondShares, snapshotSupply));
    }

    function testDepositCannotCapturePreviouslyAccruedRewards() public {
        _deposit(lender, 1000e6);
        uint256 id = _fund(1000e6);
        vm.warp(block.timestamp + T7 / 2);
        uint256 due = coreRewards.claimable(id, address(hybrid));

        uint256 entrantShares = _deposit(lender2, 99_000e6);

        assertEq(hybrid.rewardClaimable(lender2), 0);
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        vm.prank(lender2);
        assertApproxEqAbs(hybrid.redeem(entrantShares, 0), 99_000e6, 2);
    }

    function testMaturityLossIsReflectedBeforeAnExit() public {
        _deposit(lender, 1000e6);
        uint256 departingShares = _deposit(lender2, 1000e6);
        _fund(1000e6);
        vm.warp(block.timestamp + T7);

        assertEq(hybrid.totalAssets(), 1000e6);
        vm.prank(lender2);
        assertApproxEqAbs(hybrid.redeem(departingShares, 0), 500e6, 2);
        assertApproxEqAbs(hybrid.convertToAssets(hybrid.balanceOf(lender)), 500e6, 2);
    }

    function testReadyLoansAlwaysSettleInFundingOrder() public {
        _deposit(lender, 4000e6);
        uint256 loss = _fund(1000e6);
        vm.warp(_defaultAt(loss));
        hybrid.settle(_ids(loss));

        vm.prank(curator);
        hybrid.setFee(0);
        uint256 first = _list(borrower, address(nvda), 100e18, 1000e6, 1600e6, T7);
        _approve(first);
        hybrid.fund(first, type(uint256).max);
        vm.prank(curator);
        hybrid.setFee(5000);
        uint256 second = _list(borrower, address(nvda), 100e18, 1000e6, 1600e6, T7);
        _approve(second);
        hybrid.fund(second, type(uint256).max);
        _repay(first);
        _repay(second);

        uint256 snapshot = vm.snapshotState();
        hybrid.settle(_two(first, second));
        uint256 forward = hybrid.feeAccrued();
        assertTrue(vm.revertToState(snapshot));
        hybrid.settle(_two(second, first));
        assertEq(hybrid.feeAccrued(), forward);
    }

    function testQueueScanIsBoundedByEveryVisitedRow() public {
        _deposit(lender, 1000e6);
        for (uint256 i; i < 100; ++i) {
            vm.prank(lender);
            uint256 id = hybrid.requestRedeem(1);
            vm.prank(lender);
            hybrid.cancelRequest(id);
        }
        uint256 shares = _deposit(lender2, 1000e6);
        vm.prank(lender2);
        uint256 live = hybrid.requestRedeem(shares);

        hybrid.serveRequests(1, type(uint256).max);
        assertEq(hybrid.requestHead(), 2);
        for (uint256 i = 1; i < live; ++i) {
            hybrid.serveRequests(1, type(uint256).max);
        }
        assertEq(hybrid.requestHead(), live + 1);
    }
}
