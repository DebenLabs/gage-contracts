// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest} from "../earn/EarnV3Base.t.sol";

/// @notice S2 candidate comparison, kept as evidence for the accounting policy note.
/// @dev Candidate A keeps immediate recognition of an early repayment and adds a complete synchronization: every
/// known outcome is booked before any entry or exit is priced. It is emulated here on the unchanged engine (the
/// legacy EarnVault, the accounting the S1 partner vault started from) by settling the whole open set immediately
/// before each pricing action, which is exactly what an enforced check would do. Candidate B, the partner vault's
/// adopted candidate, is covered by IntentAccounting.t.sol on the same loan and the same numbers.
contract IntentRecognitionCandidatesTest is EarnV3BaseTest {
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

    function _syncedDeposit(address who, uint256 id, uint256 assets) internal returns (uint256 shares) {
        earn.settle(_ids(id));
        shares = _deposit(who, assets);
    }

    function _syncedRedeem(address who, uint256 id, uint256 shares) internal returns (uint256 assets) {
        earn.settle(_ids(id));
        vm.prank(who);
        assets = earn.redeem(shares, 0);
    }

    /// @dev What candidate A fixes: the entrant arrives after the repayment, which is booked before they are priced.
    function testCandidateAStopsEntryAfterTheRepayment() public {
        _deposit(alice, 10_000e6);
        uint256 id = _reviewLoan();
        _repay(id);
        uint256 shares = _syncedDeposit(bob, id, 10_000e6);
        assertLe(_syncedRedeem(bob, id, shares), 10_000e6);
    }

    /// @dev What candidate A cannot fix: the entrant arrives first. Nothing is unbooked when they are priced, the
    /// repayment lands, and the synchronization itself hands them their share of the remaining interest. The
    /// borrower chooses when to repay, so the borrower can be the entrant. Same capture as the documented case.
    function testCandidateADoesNotStopEntryBeforeTheRepayment() public {
        _deposit(alice, 10_000e6);
        uint256 id = _reviewLoan();
        uint256 shares = _syncedDeposit(bob, id, 10_000e6);
        _repay(id);
        uint256 captured = _syncedRedeem(bob, id, shares) - 10_000e6;
        emit log_named_uint("candidate A, entrant captured, USDG raw", captured);
        assertGt(captured, 38e6);
        assertLt(captured, 39e6);
        assertApproxEqAbs(earn.convertToAssets(earn.balanceOf(alice)) + captured, 90e6 + 10_000e6, 3);
    }
}
