// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice Local cold-storage measurements for live pricing at the 64-record limit (Pashov I-03).
/// @dev Uses the unbridged core and reserve mocks from the accounting fixture. These execution measurements do not
/// include the chain's L1 data charge or the additional work of bridged reward claims.
contract IntentLivePricingGasTest is IntentAccountingBaseTest {
    uint256 internal constant FULL_BOOK = 64;
    uint256 internal constant INITIAL_ASSETS = 102_000e6;
    uint256 internal constant LOAN_PRINCIPAL = 100e6;
    uint256 internal constant LOAN_NET_INTEREST = 9e6;
    // The same per-operation ceiling used by IntentAccountingGas.t.sol and documented in AUDIT-SCOPE.md.
    uint256 internal constant GAS_BUDGET = 32_000_000;

    function testColdPricingAndShareOperationsAtMaxCapacity() public {
        _enter(alice, 100_000e6);
        _enter(bob, 2000e6);
        uint256[] memory ids = new uint256[](FULL_BOOK);
        for (uint256 i; i < FULL_BOOK; ++i) {
            ids[i] = _list(borrower, address(nvda), 1e18, uint128(LOAN_PRINCIPAL), 110e6, T21);
            _route(ids[i], UNITS);
        }

        uint256 start = _startOf(ids[0]);
        vm.warp(start + 1 days);
        uint256 earlierAssets = partner.totalAssets();
        vm.warp(start + 3 days);
        _assertFullBook(ids, V2State.ACTIVE);
        uint256 activeAssets = _measureOperations("ACTIVE");
        assertGt(activeAssets, earlierAssets, "active loans still earn interest");
        assertApproxEqAbs(
            activeAssets,
            INITIAL_ASSETS + _scheduled(FULL_BOOK * LOAN_NET_INTEREST, 3 days, T21),
            1,
            "the full book prices the elapsed net interest"
        );

        for (uint256 i; i < FULL_BOOK; ++i) {
            _repay(ids[i]);
            assertEq(core.getLoan(ids[i]).closedAt, start + 3 days);
        }
        assertEq(partner.totalAssets(), activeAssets, "repayment preserves the price at the closing second");

        vm.warp(start + 10 days);
        _assertFullBook(ids, V2State.REPAID);
        uint256 repaidAssets = _measureOperations("REPAID, not booked");
        assertEq(repaidAssets, activeAssets, "unbooked repayments stop price growth across the full book");
        _assertFullBook(ids, V2State.REPAID);
        assertEq(partner.pocketCount(), 0, "the measurements did not book a repayment");
    }

    function _assertFullBook(uint256[] memory ids, V2State expectedState) internal view {
        assertEq(ids.length, FULL_BOOK);
        assertEq(partner.performingPrincipal(), FULL_BOOK * LOAN_PRINCIPAL);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(uint256(_state(ids[i])), uint256(expectedState));
            LoanView memory ln = _ln(ids[i]);
            assertFalse(ln.settled, "all 64 records remain open in the strategy");
            assertGt(ln.rate, 0, "all 64 records participate in live pricing");
        }
    }

    function _measureOperations(string memory stateLabel) internal returns (uint256 assets) {
        _coolPricingAccounts();
        assets = partner.totalAssets();
        uint256 viewGas = vm.lastCallGas().gasTotalUsed;
        uint256 depositGas = _measureDeposit();
        uint256 redeemGas = _measureRedeem();

        emit log_named_uint(string.concat("totalAssets, 64 ", stateLabel, ", cold"), viewGas);
        emit log_named_uint(string.concat("deposit, 64 ", stateLabel, ", cold"), depositGas);
        emit log_named_uint(string.concat("redeem, 64 ", stateLabel, ", cold"), redeemGas);
        assertLt(viewGas, GAS_BUDGET, "cold totalAssets exceeds the full-book gas budget");
        assertLt(depositGas, GAS_BUDGET, "cold deposit exceeds the full-book gas budget");
        assertLt(redeemGas, GAS_BUDGET, "cold redeem exceeds the full-book gas budget");
    }

    function _measureDeposit() internal returns (uint256 gas) {
        uint256 snapshot = vm.snapshotState();
        uint256 assetsBefore = partner.totalAssets();
        uint256 sharesBefore = partner.balanceOf(bob);
        uint256 expectedShares = partner.convertToShares(1000e6);
        _coolPricingAccounts();
        vm.prank(bob);
        uint256 shares = partner.deposit(1000e6, expectedShares);
        gas = vm.lastCallGas().gasTotalUsed;
        assertGt(shares, 0);
        assertEq(shares, expectedShares);
        assertEq(partner.balanceOf(bob), sharesBefore + shares);
        assertEq(partner.totalAssets(), assetsBefore + 1000e6);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _measureRedeem() internal returns (uint256 gas) {
        uint256 snapshot = vm.snapshotState();
        uint256 assetsBefore = partner.totalAssets();
        uint256 sharesBefore = partner.balanceOf(bob);
        uint256 shares = sharesBefore / 2;
        uint256 expectedAssets = partner.convertToAssets(shares);
        _coolPricingAccounts();
        vm.prank(bob);
        uint256 assets = partner.redeem(shares, expectedAssets);
        gas = vm.lastCallGas().gasTotalUsed;
        assertGt(assets, 0);
        assertEq(assets, expectedAssets);
        assertEq(partner.balanceOf(bob), sharesBefore - shares);
        assertEq(partner.totalAssets(), assetsBefore - assets);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    /// @dev Vm.cool marks an account and all its storage slots cold. Reset every contract touched by these paths
    /// after previews and fixture checks. Each share operation restores its snapshot so both exercise the pending
    /// reward claim path independently, without a preceding measurement consuming those rewards.
    function _coolPricingAccounts() internal {
        address lens = address(partner.RESERVE_LENS());
        vm.cool(address(partner));
        vm.cool(address(core));
        vm.cool(address(coreRewards));
        vm.cool(address(usdg));
        vm.cool(address(sgage));
        vm.cool(address(reserve));
        vm.cool(lens);
    }
}
