// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnBaseTest} from "../EarnBase.t.sol";
import {HybridVault, EarnLane} from "../../src/HybridVault.sol";
import {HybridFees} from "../../src/HybridFees.sol";
import {HybridHandler} from "./HybridHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The pooled share vault (D82) as stateful properties over random call sequences.
/// @dev foundry.toml enables fail_on_revert=true in default and inherited nightly profiles.
contract HybridVaultInvariants is EarnBaseTest {
    HybridHandler internal handler;

    function setUp() public override {
        super.setUp();
        curator = makeAddr("earn-invariant-curator");
        p.curator = curator;
        p.laneWeights = [uint16(6000), uint16(4000), uint16(0)];
        p.maxLoanTerm = T21;
        p.minReturnBps = 200;
        p.maxGageExposureBps = 6000;
        p.minDeposit = 100e6;
        p.maxTotalDeposits = 100_000e6;
        hybrid = new HybridVault(p);
        hybridFees = new HybridFees(address(hybrid), 2500, floor, curator);
        hybrid.setFees(address(hybridFees));
        vm.startPrank(curator);
        hybrid.setTokenCeiling(address(nvda), 10_000e6);
        hybrid.setTokenCeiling(address(meme), 100e6);
        hybridFees.setCuratorRecipient(makeAddr("earn-invariant-fees"));
        hybrid.setFee(1000);
        vm.stopPrank();
        handler = new HybridHandler(hybrid, vault, usdg, reserve, [nvda, meme]);
        targetSelector(FuzzSelector({addr: address(handler), selectors: _selectors()}));
        targetContract(address(handler));
    }

    function _selectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](34);
        selectors[0] = HybridHandler.deposit.selector;
        selectors[1] = HybridHandler.redeem.selector;
        selectors[2] = HybridHandler.withdraw.selector;
        selectors[3] = HybridHandler.requestRedeem.selector;
        selectors[4] = HybridHandler.cancelRequest.selector;
        selectors[5] = HybridHandler.serveRequests.selector;
        selectors[6] = HybridHandler.claim.selector;
        selectors[7] = HybridHandler.claimPocket.selector;
        selectors[8] = HybridHandler.claimRewards.selector;
        selectors[9] = HybridHandler.investReserve.selector;
        selectors[10] = HybridHandler.divestReserve.selector;
        selectors[11] = HybridHandler.reserveGain.selector;
        selectors[12] = HybridHandler.reserveLoss.selector;
        selectors[13] = HybridHandler.reserveLiquidity.selector;
        selectors[14] = HybridHandler.approveLoan.selector;
        selectors[15] = HybridHandler.revokeLoan.selector;
        selectors[16] = HybridHandler.fund.selector;
        selectors[17] = HybridHandler.fillLoan.selector;
        selectors[18] = HybridHandler.cancelFunding.selector;
        selectors[19] = HybridHandler.withdrawCommitment.selector;
        selectors[20] = HybridHandler.borrowerReclaim.selector;
        selectors[21] = HybridHandler.warp.selector;
        selectors[22] = HybridHandler.warpPastGrace.selector;
        selectors[23] = HybridHandler.markOverdue.selector;
        selectors[24] = HybridHandler.settle.selector;
        selectors[25] = HybridHandler.harvestCash.selector;
        selectors[26] = HybridHandler.harvestRewards.selector;
        selectors[27] = HybridHandler.claimFees.selector;
        selectors[28] = HybridHandler.setLaneWeight.selector;
        selectors[29] = HybridHandler.setTokenCeiling.selector;
        selectors[30] = HybridHandler.setFee.selector;
        selectors[31] = HybridHandler.setPaused.selector;
        // Weight the loan path so the fuzzer funds, fills and settles more often.
        selectors[32] = HybridHandler.approveLoan.selector;
        selectors[33] = HybridHandler.fund.selector;
    }

    // ---------------------------------------------------------------- USDG and the reserve

    /// @dev The USDG balance is exactly the sum of the four cash ledgers, each of which matches its ghost, and every
    /// USDG that ever entered is accounted for by what left through the depositor, reserve, core and fee ledgers.
    function invariant_usdgBalanceMatchesLedgersAndGhostFlows() public view {
        uint256 balance = usdg.balanceOf(address(hybrid));
        assertEq(
            balance,
            hybrid.cash() + hybrid.feeAccrued() + hybrid.claimableTotal() + hybrid.harvestedCash()
                - hybrid.assignedCash() + handler.ghostUSDGPocketLiability(),
            "USDG must equal cash + fees + claimable + unassigned harvests + recovery pockets"
        );
        assertEq(hybrid.harvestedCash(), handler.ghostHarvestedCash(), "harvested cash differs from core credits");
        assertEq(hybrid.assignedCash(), handler.ghostAssignedCash(), "assigned cash differs from settled payouts");
        assertEq(hybrid.claimableTotal(), handler.ghostClaimableTotal(), "claimable total differs from served chunks");
        assertEq(
            vault.cashCredit(address(hybrid)),
            handler.ghostCoreReturns() - handler.ghostHarvestedCash(),
            "core credit must be what the core returned less what was harvested"
        );
        assertEq(
            balance + handler.ghostReserveDeposits() + handler.ghostFundedPrincipal() + handler.ghostPaidOut()
                + handler.ghostClaimed() + handler.ghostPocketPaidUSDG() + handler.ghostFeesPaid(),
            handler.ghostDeposits() + handler.ghostReserveRedemptions() + handler.ghostHarvestedCash(),
            "USDG cannot leave the depositor, reserve, core or fee ledgers"
        );
    }

    /// @dev The strategy's reserve receipt equals its own count and the ghost mint/burn ledger; reserve gains and
    /// losses move only assets, never shares.
    function invariant_reserveSharesAndReserveTotalsReconcile() public view {
        uint256 held = reserve.balanceOf(address(hybrid));
        assertEq(held, hybrid.reserveShares(), "reserve balance must equal the recorded reserve shares");
        assertEq(
            held + handler.ghostReserveSharesBurned(),
            handler.ghostReserveSharesMinted(),
            "reserve shares differ from the mint and burn ledgers"
        );
        assertEq(reserve.totalSupply(), held, "only the strategy holds reserve shares");
        assertEq(
            reserve.totalAssets() + handler.ghostReserveRedemptions() + handler.ghostReserveLosses(),
            handler.ghostReserveDeposits() + handler.ghostReserveGains(),
            "gains and losses must move only the reserve asset balance"
        );
    }

    // ---------------------------------------------------------------- shares and requests

    /// @dev Balances equal the ghost ledger and sum to the supply; locked shares equal pending shares equal the
    /// shares of every open request, all three tracked separately.
    function invariant_sharesLockedAndRequestsReconcile() public view {
        uint256 supply;
        uint256 locked;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address who = handler.actors(i);
            assertEq(hybrid.balanceOf(who), handler.ghostShares(who), "balance differs from the share ledger");
            assertEq(hybrid.lockedShares(who), handler.ghostLocked(who), "locked differs from the request ledger");
            assertLe(hybrid.lockedShares(who), hybrid.balanceOf(who), "locked shares are owned shares");
            assertEq(hybrid.claimable(who), handler.ghostClaimable(who), "claimable differs from served chunks");
            supply += hybrid.balanceOf(who);
            locked += hybrid.lockedShares(who);
        }
        assertEq(supply, hybrid.totalSupply(), "balances must sum to the supply");
        assertEq(supply, handler.ghostSupply(), "supply differs from the share ledger");
        assertEq(locked, hybrid.pendingShares(), "locked shares must equal pending shares");
        assertEq(locked, handler.ghostPending(), "pending shares differ from the request ledger");
        uint256 open;
        uint256 count = hybrid.requestCount();
        assertEq(count, handler.ghostRequestCount(), "request count differs from the request ledger");
        for (uint256 id = 1; id <= count; ++id) {
            (address owner, uint256 shares) = hybrid.requests(id);
            assertEq(owner, handler.ghostRequestOwner(id), "a request keeps its owner");
            assertEq(shares, handler.ghostRequestShares(id), "request shares differ from the FIFO model");
            if (id < hybrid.requestHead()) assertEq(shares, 0, "nothing open remains behind the head");
            open += shares;
        }
        assertEq(open, hybrid.pendingShares(), "open requests must sum to pending shares");
        assertLe(hybrid.requestHead(), count + 1, "the head never runs past the tail");
    }

    // ---------------------------------------------------------------- loans

    /// @dev Performing and overdue principal are the sums of the funded, unsettled loans in each state; lane and
    /// borrower ledgers partition the same total; every per-loan record is fixed at funding.
    function invariant_principalLedgersReconcile() public view {
        uint256 performing;
        uint256 overdue;
        for (uint256 i; i < handler.fundedCount(); ++i) {
            uint256 id = handler.fundedIds(i);
            assertTrue(hybrid.funded(id), "a funded loan stays funded");
            assertEq(hybrid.positionPrincipal(id), handler.ghostPositionPrincipal(id), "principal cannot change");
            assertEq(hybrid.loanSlots(id), handler.ghostSlots(id), "funded quarters cannot change");
            assertEq(hybrid.loanFeeBps(id), handler.ghostLoanFee(id), "fee changes cannot reprice existing loans");
            assertEq(uint256(hybrid.loanLane(id)), uint256(handler.ghostLoanLane(id)), "a loan keeps its lane");
            assertEq(hybrid.terminal(id), handler.ghostTerminal(id), "terminal differs from the model");
            assertEq(hybrid.withdrawn(id), handler.ghostWithdrawn(id), "withdrawn differs from the model");
            assertEq(hybrid.overdue(id), handler.ghostOverdueFlag(id), "overdue differs from the model");
            if (hybrid.terminal(id)) continue;
            if (hybrid.overdue(id)) overdue += hybrid.positionPrincipal(id);
            else performing += hybrid.positionPrincipal(id);
        }
        assertEq(hybrid.performingPrincipal(), performing, "performing principal must be the open, on-time loans");
        assertEq(hybrid.overduePrincipal(), overdue, "overdue principal must be the open, written-down loans");
        assertEq(performing, handler.ghostPerforming(), "performing principal differs from the model");
        assertEq(overdue, handler.ghostOverdue(), "overdue principal differs from the model");
        uint256 lanes;
        for (uint256 lane; lane < 3; ++lane) {
            uint256 amount = hybrid.lanePrincipal(EarnLane(lane));
            assertEq(amount, handler.ghostLanePrincipal(EarnLane(lane)), "lane principal differs from the model");
            lanes += amount;
        }
        assertEq(lanes, performing + overdue, "lanes must partition the open principal");
        uint256 borrowersTotal;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address who = handler.borrowers(i);
            assertEq(hybrid.borrowerPrincipal(who), handler.ghostBorrowerPrincipal(who), "borrower principal differs");
            borrowersTotal += hybrid.borrowerPrincipal(who);
        }
        assertEq(borrowersTotal, performing + overdue, "borrowers must partition the open principal");
        assertLe(
            performing + overdue + hybrid.approvedPrincipal(), p.maxTotalDeposits, "commitments stay inside the mandate"
        );
    }

    // ---------------------------------------------------------------- price, lock and mark

    /// @dev Locked profit decays linearly to zero at the window's end and never exceeds what was reported net of
    /// fees; full assets fall short of the profit still locked only by reserve losses taken while it was locked;
    /// what shares are priced on never exceeds full assets; the mark never falls.
    function invariant_profitLockAndPriceBounds() public view {
        uint256 lockedNow = hybrid.lockedProfitNow();
        assertLe(lockedNow, hybrid.lockedProfit(), "unlocking never adds profit");
        assertLe(hybrid.lockedProfit(), handler.ghostNetProfitReported(), "locked profit exceeds reported profit");
        if (block.timestamp >= hybrid.unlockEnd()) assertEq(lockedNow, 0, "the window ends with nothing locked");
        assertLe(hybrid.unlockStart(), hybrid.unlockEnd(), "the window is ordered");
        uint256 full = hybrid.fullAssets();
        assertGe(full + handler.ghostLossAgainstLock(), lockedNow, "locked profit is backed but for reserve losses");
        assertLe(hybrid.totalAssets(), full, "the price base never exceeds full assets");
        assertEq(hybrid.totalAssets(), full > lockedNow ? full - lockedNow : 0, "the price base is full less locked");
        assertEq(
            full + handler.pendingLoss(),
            hybrid.cash() + reserve.convertToAssets(hybrid.reserveShares()) + hybrid.performingPrincipal(),
            "full assets price impaired loans at zero before their write-down transaction"
        );
        assertGe(hybrid.highWaterPrice(), handler.highWaterSeen(), "the mark never decreases");
    }

    // ---------------------------------------------------------------- pockets

    /// @dev Every pocket's balances of record sum to its supply and match the ghost snapshot; claims never exceed
    /// the pocket and the unclaimed remainder is still held by the strategy, per token.
    function invariant_pocketsHeldForHoldersOfRecord() public view {
        assertEq(hybrid.pocketCount(), handler.ghostPocketCount(), "pocket count differs from the model");
        uint256[2] memory unclaimed;
        uint256 unclaimedUSDG;
        for (uint256 pocketId = 1; pocketId <= hybrid.pocketCount(); ++pocketId) {
            (, address token, uint256 amount, uint256 supply, uint256 claimed) = hybrid.pockets(pocketId);
            assertEq(token, handler.ghostPocketToken(pocketId), "a pocket keeps its token");
            assertEq(amount, handler.ghostPocketAmount(pocketId), "a pocket keeps its amount");
            assertEq(supply, handler.ghostPocketSupply(pocketId), "a pocket keeps its supply");
            assertEq(claimed, handler.ghostPocketClaimedTotal(pocketId), "claimed differs from the claim ledger");
            assertLe(claimed, amount, "claims never exceed the pocket");
            uint256 recorded;
            uint256 entitled;
            for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
                address who = handler.actors(i);
                uint256 balance = hybrid.balanceOfAt(who, pocketId);
                assertEq(balance, handler.ghostBalanceAt(pocketId, who), "balance of record differs from the ghost");
                recorded += balance;
                entitled += Math.mulDiv(amount, balance, supply);
                if (hybrid.pocketClaimed(pocketId, who)) {
                    assertEq(hybrid.pocketClaimable(pocketId, who), 0, "a claimed pocket pays nothing more");
                } else {
                    assertEq(hybrid.pocketClaimable(pocketId, who), Math.mulDiv(amount, balance, supply));
                }
            }
            assertEq(recorded, supply, "balances of record must sum to the pocket supply");
            assertLe(entitled, amount, "entitlements never exceed the pocket");
            if (token == address(usdg)) unclaimedUSDG += amount - claimed;
            else unclaimed[token == address(handler.tokens(0)) ? 0 : 1] += amount - claimed;
        }
        for (uint256 t; t < 2; ++t) {
            MockERC20 token = handler.tokens(t);
            assertEq(token.balanceOf(address(hybrid)), unclaimed[t], "unclaimed collateral is held by the strategy");
        }
        assertEq(unclaimedUSDG, handler.ghostUSDGPocketLiability(), "USDG recovery pockets differ from the model");
    }

    // ---------------------------------------------------------------- rewards

    /// @dev Everything harvested is claimable, paid or parked in the remainder, up to the per-harvest and
    /// per-balance-change rounding the accumulator loses; the strategy holds every unpaid unit.
    function invariant_rewardsConserved() public view {
        uint256 claimable;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            claimable += hybrid.rewardClaimable(handler.actors(i));
        }
        uint256 accrued = handler.ghostRewardsAccrued();
        uint256 distributed =
            claimable + handler.ghostRewardsPaid() + hybrid.rewardRemainder() + handler.ghostRewardOrphan();
        assertLe(distributed, accrued, "virtual reward entitlements cannot be created");
        assertLe(accrued - distributed, handler.ghostRewardDust(), "rewards lost beyond accumulator rounding");
        assertEq(hybrid.rewardRemainder(), handler.ghostRewardRemainder(), "the remainder differs from the model");
        assertEq(
            sgage.balanceOf(address(hybrid)),
            handler.ghostRewardsHarvested() - handler.ghostRewardsPaid(),
            "the strategy holds every harvested reward it has not paid"
        );
    }

    // ---------------------------------------------------------------- fees

    /// @dev Fees accrued are exactly the fees the vault reported at settlement, which are exactly the fees the
    /// independent high-water model expected, less what the companion has already received.
    function invariant_feesAccruedMatchReportedAndModeled() public view {
        assertEq(hybrid.feeAccrued() + handler.ghostFeesPaid(), handler.ghostFeesReported(), "fees differ from events");
        assertEq(handler.ghostFeesReported(), handler.ghostFeesModeled(), "reported fees differ from the model");
        assertEq(usdg.balanceOf(address(hybridFees)), 0, "the companion is always drained by the handler");
    }

    // ---------------------------------------------------------------- conservation of holder value

    /// @dev No holder is worth more than the price base, holders together are worth at most the price base, and the
    /// value held for holders, claimants, the fee companion and unsettled loans is exactly what the strategy has.
    function invariant_holderValueBoundedByConservation() public view {
        uint256 total = hybrid.totalAssets();
        uint256 sum;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address who = handler.actors(i);
            uint256 value = hybrid.convertToAssets(hybrid.balanceOf(who));
            assertLe(value, total, "no holder is worth more than the vault");
            assertLe(hybrid.claimable(who), hybrid.claimableTotal(), "no claimant is owed more than the total");
            sum += value;
        }
        assertLe(sum, total, "holders together are worth at most the price base");
        assertEq(
            total + hybrid.lockedProfitNow() + handler.pendingLoss() + hybrid.claimableTotal() + hybrid.feeAccrued()
                + hybrid.harvestedCash() - hybrid.assignedCash() + handler.ghostUSDGPocketLiability(),
            usdg.balanceOf(address(hybrid)) + reserve.convertToAssets(hybrid.reserveShares())
                + hybrid.performingPrincipal(),
            "value held for everyone is exactly cash, reserve and performing loans"
        );
    }

    // ---------------------------------------------------------------- reachability and unwinding

    /// @dev A deterministic trace ensures each advertised fuzz action actually reaches an admissible state.
    function testEveryHandlerActionHasAReachableSuccessfulPath() public {
        handler.setFee(1000, true);
        handler.approveLoan(0, 0, 500e6, 3);
        handler.fund(0);
        handler.borrowerReclaim(0);
        handler.harvestCash();
        handler.settle(0);
        handler.claimFees();
        handler.approveLoan(1, 1, 500e6, 7);
        handler.fund(1);
        handler.warp(2 days);
        handler.warp(2 days);
        handler.warp(2 days);
        handler.warp(2 days);
        handler.markOverdue(1);
        assertTrue(hybrid.overdue(handler.fundedIds(1)), "the second loan is written down at term end");
        handler.warpPastGrace(1, 0);
        handler.settle(1);
        handler.claimPocket(0, 1);
        handler.approveLoan(2, 0, 300e6, 1);
        handler.fund(2);
        handler.fillLoan(2);
        handler.warp(3 days);
        handler.harvestRewards(2);
        handler.claimRewards(0);
        handler.borrowerReclaim(2);
        handler.settle(2);
        handler.approveLoan(3, 0, 300e6, 0);
        handler.fund(3);
        handler.cancelFunding(3);
        handler.settle(3);
        handler.approveLoan(4, 0, 300e6, 1);
        handler.fund(4);
        handler.withdrawCommitment(4);
        handler.settle(4);
        handler.deposit(0, 100e6);
        handler.investReserve(0, 500e6);
        handler.redeem(0, 10e12);
        handler.withdraw(1, 10e6);
        handler.requestRedeem(2, 50e12);
        handler.requestRedeem(3, 50e12);
        handler.cancelRequest(0);
        // The bounded scan charges the cancelled head row before it reaches the next live request.
        handler.serveRequests(2, type(uint256).max);
        handler.claim(3);
        handler.divestReserve(10e12);
        handler.reserveGain(100e6);
        handler.reserveLoss(10e6);
        handler.reserveLiquidity(false);
        handler.reserveLiquidity(true);
        handler.setLaneWeight(uint256(EarnLane.STOCK), 5000);
        handler.setTokenCeiling(0, 9000e6);
        handler.setPaused(true);
        handler.setPaused(false);
        handler.approveLoan(2, 0, 100e6, 3);
        uint256 approvalBefore = hybrid.approvedPrincipal();
        handler.revokeLoan(5);
        assertLt(hybrid.approvedPrincipal(), approvalBefore, "revoke must remove a live approval");
        bytes4[] memory selectors = _selectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertGt(
                handler.calls(selectors[i]),
                0,
                string.concat("advertised handler action never reached a successful call: ", vm.toString(i))
            );
        }
        _assertAll();
        afterInvariant();
    }

    /// @dev A request whose whole value rounds below one USDG unit is handed back instead of stalling the queue, so
    /// nobody holding `minDeposit` can block every later request for the price of one share.
    function testDustRequestAtTheHeadIsReturnedAndTheQueueMovesOn() public {
        address griefer = handler.actors(0);
        address requester = handler.actors(1);
        // A loan takes most of the liquidity, so the honest requester must queue.
        handler.approveLoan(0, 0, 5000e6, 7);
        handler.fund(0);
        handler.approveLoan(1, 0, 2000e6, 7);
        handler.fund(1);
        vm.prank(griefer);
        uint256 dust = hybrid.requestRedeem(1);
        uint256 held = hybrid.balanceOf(requester);
        vm.prank(requester);
        hybrid.requestRedeem(held);
        assertEq(hybrid.convertToAssets(1), 0, "one share is worth less than one USDG unit");
        assertGt(hybrid.cash(), 100e6, "there is liquidity to serve part of the honest request");
        vm.expectEmit(true, true, false, true, address(hybrid));
        emit HybridVault.RequestCancelled(dust, griefer, 1);
        hybrid.serveRequests(10, type(uint256).max);
        assertGt(hybrid.claimable(requester), 0, "an honest request behind a dust request is still served");
        assertEq(hybrid.lockedShares(griefer), 0, "the dust request is handed back");
        (, uint256 remaining) = hybrid.requests(dust);
        assertEq(remaining, 0);
    }

    function afterInvariant() public {
        handler.finish();
        _assertAll();
        assertEq(hybrid.totalSupply(), 0, "every share is redeemed after unwinding");
        assertEq(hybrid.pendingShares(), 0, "no request is left open after unwinding");
        assertEq(hybrid.claimableTotal(), 0, "every served amount is claimed after unwinding");
        assertEq(hybrid.performingPrincipal() + hybrid.overduePrincipal(), 0, "every loan resolves after unwinding");
        assertEq(hybrid.feeAccrued(), 0, "every fee is collected after unwinding");
        assertEq(hybrid.harvestedCash(), hybrid.assignedCash(), "every harvest is assigned after unwinding");
        assertEq(vault.cashCredit(address(hybrid)), 0, "no core credit is left after unwinding");
    }

    function _assertAll() internal view {
        invariant_usdgBalanceMatchesLedgersAndGhostFlows();
        invariant_reserveSharesAndReserveTotalsReconcile();
        invariant_sharesLockedAndRequestsReconcile();
        invariant_principalLedgersReconcile();
        invariant_profitLockAndPriceBounds();
        invariant_pocketsHeldForHoldersOfRecord();
        invariant_rewardsConserved();
        invariant_feesAccruedMatchReportedAndModeled();
        invariant_holderValueBoundedByConservation();
    }
}
