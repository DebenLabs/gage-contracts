// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest, EarnVault} from "./EarnV3Base.t.sol";

/// @notice Local source-characterization tests for the Intent PRD; not a live exploit assessment.
contract IntentWithdrawalReviewTest is EarnV3BaseTest {
    function setUp() public override {
        super.setUp();
        p.mandate.feeBps = 1000;
        _deploy();
    }

    function _reviewLoan() internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        _fund(id, UNITS);
        vm.warp(block.timestamp + 3 days);
    }

    function testNormalAccrualRoundTripDoesNotCaptureExistingInterest() public {
        _deposit(alice, 10_000e6);
        _reviewLoan();
        uint256 shares = _deposit(bob, 10_000e6);
        vm.prank(bob);
        uint256 redeemed = earn.redeem(shares, 0);
        assertLe(redeemed, 10_000e6);
        assertApproxEqAbs(redeemed, 10_000e6, 2);
    }

    function testDepositAfterCoreRepaymentBeforeSettlementCapturesProfit() public {
        _deposit(alice, 10_000e6);
        uint256 id = _reviewLoan();
        _repay(id);
        uint256 staleAssets = earn.totalAssets();
        uint256 beforeBalance = usdg.balanceOf(bob);
        uint256 shares = _deposit(bob, 10_000e6);
        vm.prank(bob);
        earn.settle(_ids(id));
        vm.prank(bob);
        uint256 redeemed = earn.redeem(shares, 0);
        uint256 captured = usdg.balanceOf(bob) - beforeBalance;
        uint256 aliceClaim = earn.convertToAssets(earn.balanceOf(alice));
        emit log_named_uint("stale vault assets, USDG raw", staleAssets);
        emit log_named_uint("new depositor redeemed, USDG raw", redeemed);
        emit log_named_uint("new depositor captured, USDG raw", captured);
        emit log_named_uint("original depositor claim, USDG raw", aliceClaim);
        assertGt(captured, 38e6);
        assertLt(captured, 39e6);
        assertApproxEqAbs(aliceClaim + captured, 10_090e6, 3);
        assertEq(earn.balanceOf(bob), 0);
    }

    function testSettlementBeforeNewDepositRemovesAlreadyPaidProfitGap() public {
        _deposit(alice, 10_000e6);
        uint256 id = _reviewLoan();
        _repay(id);
        _settle(id);
        uint256 shares = _deposit(bob, 10_000e6);
        vm.prank(bob);
        uint256 redeemed = earn.redeem(shares, 0);
        assertLe(redeemed, 10_000e6);
        assertApproxEqAbs(redeemed, 10_000e6, 2);
    }

    function testMaturityBlocksWithdrawalUntilLossIsBooked() public {
        _deposit(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_maturity(id));
        vm.prank(alice);
        vm.expectRevert(EarnVault.SettlementDue.selector);
        earn.redeem(100e18, 0);
        _settle(id);
        assertEq(earn.totalAssets(), 9000e6);
        assertApproxEqAbs(earn.convertToAssets(100e18), 90e6, 1);
    }

    function testExitBeforeMaturityUsesAccruedValueAndLeavesFutureLossToRemainingHolder() public {
        _deposit(alice, 9000e6);
        uint256 shares = _deposit(bob, 1000e6);
        uint256 id = _reviewLoan();
        vm.warp(_maturity(id) - 1);
        vm.prank(bob);
        uint256 redeemed = earn.redeem(shares, 0);
        assertGt(redeemed, 1008e6);
        assertEq(earn.balanceOf(bob), 0);
        vm.warp(_maturity(id));
        _settle(id);
        earn.recover(id);
        emit log_named_uint("pre-maturity exit, USDG raw", redeemed);
        emit log_named_uint("remaining cash assets after default, USDG raw", earn.totalAssets());
        assertEq(earn.totalAssets(), 10_000e6 - redeemed - 1000e6);
        assertEq(earn.pocketClaimable(1, bob), 0);
        assertEq(earn.pocketClaimable(1, alice), 100e18);
    }
}
