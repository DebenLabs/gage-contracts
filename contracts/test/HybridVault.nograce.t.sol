// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnBaseTest} from "./EarnBase.t.sol";
import {GageV2Vault} from "../src/v2/GageV2Vault.sol";
import {V2State} from "../src/v2/V2Types.sol";

/// @notice An Earn strategy on a core without a grace window: a loan is repaid before its term ends or it defaults
///         that same second, so no written-down loan ever waits for a late repayment.
contract HybridVaultNoGraceTest is EarnBaseTest {
    function _grace() internal pure override returns (uint32) {
        return 0;
    }

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

    function testTheStrategyPinsTheCoreZeroGrace() public view {
        assertEq(vault.GRACE(), 0);
        assertEq(hybrid.GRACE(), 0);
    }

    function testDefaultIsFinalizedTheSecondTheTermEndsAndOpensThePocket() public {
        uint256 shares = _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        uint256 maturity = _defaultAt(id);
        assertEq(maturity, uint256(vault.getLoan(id).fundedAt) + T7);
        vm.warp(maturity - 1);
        hybrid.markOverdue(_ids(id));
        hybrid.settle(_ids(id));
        assertFalse(hybrid.overdue(id), "in term: nothing to write down");
        assertEq(uint256(_state(id)), uint256(V2State.ACTIVE));
        assertEq(hybrid.performingPrincipal(), 1000e6);
        vm.warp(maturity);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.reclaim(id, borrower);
        hybrid.settle(_ids(id));
        assertEq(uint256(_state(id)), uint256(V2State.DEFAULTED));
        assertEq(vault.getLoan(id).closedAt, maturity);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.overduePrincipal(), 0);
        assertEq(hybrid.totalAssets(), 0, "collateral is never priced");
        assertEq(hybrid.pocketCount(), 1);
        (uint256 dealId, address token, uint256 amount, uint256 supply,) = hybrid.pockets(1);
        assertEq(dealId, id);
        assertEq(token, address(nvda));
        assertEq(amount, 100e18);
        assertEq(supply, shares);
        assertEq(hybrid.pocketClaimable(1, lender), 100e18);
    }

    function testRepaymentOneSecondBeforeTheTermEndsIsOnTimeProfit() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(_defaultAt(id) - 1);
        _repay(id);
        hybrid.settle(_ids(id));
        assertEq(uint256(_state(id)), uint256(V2State.REPAID));
        assertEq(hybrid.pocketCount(), 0, "no write-down, so no recovery pocket");
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(hybrid.fullAssets(), 1045e6);
        vm.expectRevert(GageV2Vault.WrongState.selector);
        vault.finalizeDefault(id);
    }
}
