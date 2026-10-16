// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2VaultTest} from "./GageV2Vault.t.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

using {unitsOf} for GageV2Vault;
using {remainingLenderReward} for GageV2Rewards;

/// @notice Lender sales on the core, the whole bundle to one recipient: one ask over a lender's quarters, bought once
/// through `buyLenderSplit`, the core's only lender sale since X-scope-09 (`GageV2LenderSplit` covers several
/// recipients). The recipient checks and the per-quarter reward bounds are the ledger's (`transferLenders`).
contract GageV2LenderSalesTest is GageV2VaultTest {
    /// @dev The standalone ledger of the partition fuzz below reads its registry from its deployer, this suite.
    function REGISTRY() external view returns (GageV2TokenRegistry) {
        return registry;
    }

    function _all(address a) internal pure returns (address[4] memory to) {
        to = [a, a, a, a];
    }

    /// @dev The seller's ask for `slots` at 260 USDG, bought for `buyer` with no reward bound.
    function _ask(uint256 id, address seller, uint8 slots) internal returns (V2LenderSplit memory p) {
        vm.prank(seller);
        vault.setLenderAsk(id, slots, 260e6, uint40(block.timestamp + 1 days), 100);
        V2LenderAsk memory a = vault.getLenderAsk(id, seller);
        uint128[4] memory none;
        p = V2LenderSplit(seller, slots, a.price, a.feeBps, a.nonce, _all(buyer), none);
    }

    function test_lenderSaleTransfersRepaymentAndKeepsEarnedRewards() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM / 2);
        uint256 sellerEarned = rewards.claimable(id, lender[0]);
        V2Loan memory beforeLoan = vault.getLoan(id);
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        uint256 cash = usdg.balanceOf(buyer);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        assertEq(usdg.balanceOf(buyer), cash - 260e6);
        assertEq(vault.cashCredit(lender[0]), 257_400_000);
        assertEq(vault.cashCredit(fees), 12_600_000);
        assertEq(vault.unitsOf(id, buyer), 1);
        assertEq(vault.unitsOf(id, lender[0]), 0);
        assertEq(rewards.claimable(id, lender[0]), sellerEarned);
        assertEq(rewards.claimable(id, buyer), 0);
        assertEq(vault.getLoan(id).fundedAt, beforeLoan.fundedAt);
        assertEq(vault.getLoan(id).cap, beforeLoan.cap);
        assertEq(vault.ownerOf(id), borrower);
        vm.prank(lender[0]);
        rewards.claim(id, lender[0]);
        vm.warp(block.timestamp + TERM / 4);
        assertGt(rewards.claimable(id, buyer), 0);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        assertEq(vault.cashCredit(buyer), 275e6);
        assertEq(vault.cashCredit(lender[0]), 257_400_000);
        uint256 earnedAtClose = rewards.claimable(id, buyer);
        vm.warp(block.timestamp + TERM);
        assertEq(rewards.claimable(id, buyer), earnedAtClose);
        vm.prank(buyer);
        rewards.claim(id, buyer);
        _assertCash();
        _assertRewards();
    }

    function test_nonAdjacentBundleTransfersExactQuartersAndAllDefaultRights() public {
        uint256 id = _list(1000e6 + 3, 1100e6 + 1, 100e18 + 3);
        vm.prank(lender[0]);
        vault.fund(id, 1);
        vm.prank(lender[1]);
        vault.fund(id, 1);
        vm.prank(lender[0]);
        vault.fund(id, 1);
        vm.prank(lender[2]);
        vault.fund(id, 1);
        V2LenderSplit memory p = _ask(id, lender[0], 5);
        assertEq(vault.getLenderAsk(id, lender[0]).slots, 5);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        vm.warp(block.timestamp + TERM + GRACE);
        vault.finalizeDefault(id);
        vm.prank(buyer);
        vault.recoverDefault(id, 0, 0, block.timestamp);
        vm.prank(buyer);
        vault.withdrawRecovery(id, 0, buyer);
        vm.prank(lender[1]);
        vault.withdrawRecovery(id, 0, lender[1]);
        vm.prank(lender[2]);
        vault.withdrawRecovery(id, 0, lender[2]);
        assertEq(stock.balanceOf(buyer), 50e18 + 2);
        assertEq(stock.balanceOf(buyer) + stock.balanceOf(lender[1]) + stock.balanceOf(lender[2]), 100e18 + 3);
        vm.expectRevert(GageV2Vault.NothingToClaim.selector);
        vm.prank(lender[0]);
        vault.withdrawRecovery(id, 0, lender[0]);
        vm.expectRevert(GageV2Vault.NothingToClaim.selector);
        vm.prank(buyer);
        vault.withdrawRecovery(id, 0, buyer);
    }

    function test_priorClaimsRepeatedSalesAndBorrowerLenderOverlapConserveAllocation() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM / 4);
        vm.prank(lender[0]);
        rewards.claim(id, lender[0]);
        for (uint8 i; i < 12; ++i) {
            address seller = vault.lenders(id)[0];
            V2LenderSplit memory p = _ask(id, seller, 1);
            p.recipients = _all(seller == borrower ? lender[0] : borrower);
            vm.prank(buyer);
            vault.buyLenderSplit(id, p);
        }
        vm.warp(vault.getLoan(id).fundedAt + TERM);
        uint256 total;
        address[6] memory actors = [borrower, buyer, lender[0], lender[1], lender[2], lender[3]];
        for (uint8 i; i < actors.length; ++i) {
            total += sgage.balanceOf(actors[i]) + rewards.claimable(id, actors[i]);
            if (rewards.claimable(id, actors[i]) > 0) {
                vm.prank(actors[i]);
                rewards.claim(id, actors[i]);
            }
        }
        V2Loan memory l = vault.getLoan(id);
        assertEq(total, uint256(l.borrowerReward) + l.lenderReward);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        _assertCash();
        _assertRewards();
    }

    function test_staleRelistDeadlineAndExactBundleBinding() public {
        uint256 id = _active();
        V2LenderSplit memory old = _ask(id, lender[0], 1);
        // Posting again is the only way to replace an ask (there is no cancellation): the earlier nonce is stale.
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, old);
        p.slots = 3;
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        p.slots = 1;
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
    }

    function test_ownershipAndStateAreRequiredAndZeroOrOutsideMasksFail() public {
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vault.fund(id, 1);
        vm.expectRevert(GageV2Vault.WrongState.selector);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 1, 1, uint40(block.timestamp + 1), 100);
        vm.prank(lender[1]);
        vault.fund(id, 3);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 3, 1, uint40(block.timestamp + 1), 100);
        vm.expectRevert(GageV2Vault.InvalidUnits.selector);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 0, 1, uint40(block.timestamp + 1), 100);
        vm.expectRevert(GageV2Vault.InvalidUnits.selector);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 16, 1, uint40(block.timestamp + 1), 100);
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        // The ledger refuses a zero recipient, the core and the seller itself, before anything moves.
        address[3] memory refused = [address(0), address(vault), lender[0]];
        for (uint256 i; i < refused.length; ++i) {
            p.recipients = _all(refused[i]);
            vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
            vm.prank(buyer);
            vault.buyLenderSplit(id, p);
        }
        assertEq(vault.lenders(id)[0], lender[0]);
        assertEq(vault.getLenderAsk(id, lender[0]).nonce, p.nonce);
    }

    function test_feeIsSnapshottedAndBothSidesApproveIt() public {
        uint256 id = _active();
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 1, 260e6, uint40(block.timestamp + 1 days), 99);
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        registry.setTradeFee(200);
        p.maxFeeBps = 99;
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        p.maxFeeBps = 100;
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        assertEq(vault.cashCredit(lender[0]), 257_400_000);
    }

    function test_failedPaymentRollsBackOwnershipRewardsAndAsk() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM / 2);
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        uint256 earned = rewards.claimable(id, lender[0]);
        vm.prank(buyer);
        usdg.approve(address(vault), 0);
        vm.expectRevert();
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        assertEq(vault.unitsOf(id, lender[0]), 1);
        assertEq(vault.unitsOf(id, buyer), 0);
        assertEq(rewards.claimable(id, lender[0]), earned);
        assertEq(vault.getLenderAsk(id, lender[0]).nonce, p.nonce);
        assertEq(vault.cashCredit(lender[0]), 0);
        _assertCash();
        _assertRewards();
    }

    function test_minimumRemainingRewardsProtectsDelayedPurchases() public {
        uint256 id = _active();
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        p.minRewards[0] = uint128(rewards.remainingLenderReward(id, 1));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        p.minRewards[0] = uint128(rewards.remainingLenderReward(id, 1));
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
    }

    function test_lenderSalesContinueAfterTheDeadlineUntilFinalization() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM + GRACE);
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        registry.pauseNewDeals(true);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        assertEq(rewards.remainingLenderReward(id, 1), 0);
        V2LenderSplit memory next = _ask(id, lender[1], 2);
        // The borrower's window is over: the quarter the buyer holds settles as collateral, never as cash.
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.reclaim(id, borrower);
        vault.finalizeDefault(id);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, next);
        assertEq(vault.lenders(id)[1], lender[1], "the refused sale moved nothing");
        vm.prank(buyer);
        vault.recoverDefault(id, 0, 0, block.timestamp);
        assertEq(vault.claimableRecovery(id, 0, buyer), 25e18);
        assertEq(vault.cashCredit(buyer), 0);
        _assertCash();
    }

    /// @dev An ask priced while the loan could still be repaid must not survive into the recovery-only phase: its
    /// price was set for a repayment claim, and past the window the quarter is a collateral claim (D162).
    function test_anAskPostedBeforeTheWindowClosesExpiresWithIt() public {
        uint256 id = _active();
        uint256 windowEnd = uint256(vault.getLoan(id).fundedAt) + TERM + GRACE;
        vm.warp(windowEnd - 1 hours);
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.setLenderAsk(id, 1, 260e6, uint40(windowEnd + 1), 100);
        // Up to the close is allowed, and such an ask dies with the window.
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 1, 260e6, uint40(windowEnd), 100);
        V2LenderAsk memory a = vault.getLenderAsk(id, lender[0]);
        uint128[4] memory none;
        V2LenderSplit memory stale = V2LenderSplit(lender[0], 1, a.price, a.feeBps, a.nonce, _all(buyer), none);
        vm.warp(windowEnd);
        vm.prank(buyer);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vault.buyLenderSplit(id, stale);
        // Once the window has closed, the recovery claim may be offered again, priced as what it now is.
        V2LenderSplit memory fresh = _ask(id, lender[0], 1);
        vm.prank(buyer);
        vault.buyLenderSplit(id, fresh);
        assertEq(vault.lenders(id)[0], buyer);
    }

    function test_defaultFinalizationInvalidatesEveryAskBeforeRecovery() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM + GRACE);
        V2LenderSplit memory p = _ask(id, lender[0], 1);
        vault.finalizeDefault(id);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
        vm.expectRevert(GageV2Vault.WrongState.selector);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 1, 1, uint40(block.timestamp + 1), 100);
    }

    function testFuzz_lenderCurvePartitionConservesEveryRawUnit(uint128 total, uint32 elapsed, uint8 mask) public {
        total = uint128(bound(total, 1, 1e30));
        elapsed = uint32(bound(elapsed, 0, TERM));
        mask = uint8(bound(mask, 1, 15));
        GageV2Rewards ledger = new GageV2Rewards(sgage, GageLegacyAdapter(address(0)));
        ledger.bindFunderGate(new MockOpenFunderGate());
        sgage.mint(address(this), total);
        sgage.approve(address(ledger), total);
        ledger.fund(total);
        address[4] memory initial = [lender[0], lender[0], lender[0], lender[0]];
        ledger.activate(1, borrower, initial, TERM, 0, total);
        uint256 start = block.timestamp;
        vm.warp(start + elapsed);
        uint256 before = ledger.claimable(1, lender[0]);
        if (before > 0) {
            vm.prank(lender[0]);
            ledger.claim(1, lender[0]);
        }
        uint128[4] memory none;
        ledger.transferLenders(1, lender[0], mask, _all(borrower), none);
        ledger.transferLenders(1, borrower, mask, _all(buyer), none);
        ledger.transferLenders(1, buyer, mask, _all(lender[0]), none);
        ledger.transferLenders(1, lender[0], mask, _all(buyer), none);
        assertEq(ledger.claimable(1, borrower), 0);
        assertEq(ledger.claimable(1, buyer), 0);
        vm.warp(start + TERM);
        ledger.close(1);
        assertEq(before + ledger.claimable(1, lender[0]) + ledger.claimable(1, buyer), total);
        if (ledger.claimable(1, lender[0]) > 0) {
            vm.prank(lender[0]);
            ledger.claim(1, lender[0]);
        }
        if (ledger.claimable(1, buyer) > 0) {
            vm.prank(buyer);
            ledger.claim(1, buyer);
        }
        assertEq(ledger.claimable(1, borrower) + ledger.claimable(1, lender[0]) + ledger.claimable(1, buyer), 0);
        assertEq(ledger.freeBudget(), 0);
        assertEq(sgage.balanceOf(address(ledger)), 0);
    }
}
