// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest} from "../earn/EarnV3Base.t.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {EarnHandler} from "./EarnV3Handler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice The third Earn design as stateful properties over random call sequences.
/// @dev foundry.toml enables fail_on_revert=true in the default and nightly profiles.
contract EarnVaultInvariants is EarnV3BaseTest {
    EarnHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new EarnHandler(earn, core, usdg, sgage, reserve, [nvda, meme], borrower);
        bytes4[] memory selectors = new bytes4[](25);
        selectors[0] = EarnHandler.deposit.selector;
        selectors[1] = EarnHandler.redeem.selector;
        selectors[2] = EarnHandler.claimPocket.selector;
        selectors[3] = EarnHandler.claimRewards.selector;
        selectors[4] = EarnHandler.investReserve.selector;
        selectors[5] = EarnHandler.divestReserve.selector;
        selectors[6] = EarnHandler.reserveGain.selector;
        selectors[7] = EarnHandler.reserveLoss.selector;
        selectors[8] = EarnHandler.curatorFunds.selector;
        selectors[9] = EarnHandler.fillLoan.selector;
        selectors[10] = EarnHandler.borrowerRepays.selector;
        selectors[11] = EarnHandler.borrowerCancels.selector;
        selectors[12] = EarnHandler.thirdPartyFinalizesDefault.selector;
        selectors[13] = EarnHandler.pushCoreCredit.selector;
        selectors[14] = EarnHandler.warp.selector;
        selectors[15] = EarnHandler.warpPastMaturity.selector;
        selectors[16] = EarnHandler.settle.selector;
        selectors[17] = EarnHandler.recover.selector;
        selectors[18] = EarnHandler.harvestRewards.selector;
        selectors[19] = EarnHandler.claimFees.selector;
        selectors[20] = EarnHandler.setLaneWeight.selector;
        selectors[21] = EarnHandler.setFee.selector;
        selectors[22] = EarnHandler.curatorFunds.selector; // weight the loan path
        selectors[23] = EarnHandler.withdrawCommitment.selector;
        selectors[24] = EarnHandler.setLimits.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The handler must be able to walk the whole lifecycle, or the invariants above prove nothing.
    function testEveryHandlerActionHasAReachableSuccessfulPath() public {
        handler.deposit(0, 50_000e6);
        handler.deposit(1, 20_000e6);
        handler.investReserve(10_000e6);
        handler.reserveGain(500e6);
        handler.reserveLoss(100e6);
        handler.divestReserve(1e18);
        handler.curatorFunds(0, 2000e6, 500, 4); // a stock loan, all four quarters
        handler.curatorFunds(1, 1000e6, 500, 2); // a meme loan, two quarters
        handler.fillLoan(1);
        handler.curatorFunds(2, 1500e6, 300, 1);
        handler.withdrawCommitment(2);
        handler.curatorFunds(3, 1500e6, 300, 1);
        handler.borrowerCancels(3);
        assertEq(handler.loanCount(), 4);
        handler.warp(2 days);
        assertGt(earn.accruedInterest(), 0, "open loans earn their fixed cost as the term runs");
        handler.borrowerRepays(0);
        handler.pushCoreCredit();
        handler.settle(0);
        assertGt(handler.ghostProfit(), 0, "a repayment was booked as profit");
        handler.harvestRewards(0);
        handler.claimRewards(0);
        handler.claimRewards(1);
        assertGt(sgage.balanceOf(handler.actors(0)), 0, "rewards reached a holder");
        handler.claimFees();
        handler.warpPastMaturity();
        assertGe(block.timestamp, earn.earliestMaturity());
        handler.thirdPartyFinalizesDefault(1);
        handler.settle(0);
        handler.recover(1);
        assertGt(earn.pocketCount(), 0, "a default opened a pocket");
        assertEq(earn.earliestMaturity(), type(uint40).max, "every open loan settled");
        handler.claimPocket(0, 0);
        assertGt(meme.balanceOf(handler.actors(0)), 0, "the pocket paid a holder of record");
        handler.setLaneWeight(0, 5000);
        handler.setFee(500);
        handler.setMaxTotalDeposits(200_000e6);
        handler.setLimits(5000e6, 5000, 500);
        handler.setPaused(true);
        handler.setPaused(false);
        handler.redeem(1, 1000e18);
        invariant_usdgHeldMatchesTheLedgers();
        invariant_principalLedgersAndTheOpenSetReconcile();
        invariant_pocketsAreHeldForTheHoldersOfRecord();
    }

    /// @dev What the strategy holds in realized terms, for holders and fees, is exactly what came in less what left,
    /// plus the profit it booked and the interest a written-off loan had earned into the price, less the losses it
    /// booked, plus reserve gains less reserve losses. Interest still accruing on open loans is on neither side:
    /// a redemption that takes some of it out is an advance the loan's outcome settles. The reserve is read by its
    /// USDG balance: the strategy is its only depositor, so the identity carries no rounding.
    function invariant_valueIsConserved() public view {
        uint256 held = earn.cash() + usdg.balanceOf(address(reserve)) + earn.performingPrincipal() + earn.curatorFees()
            + earn.protocolFees();
        uint256 inflow =
            handler.ghostDeposited() + handler.ghostProfit() + handler.ghostEarnedLost() + handler.ghostReserveGains();
        uint256 outflow =
            handler.ghostRedeemed() + handler.ghostFeesPaid() + handler.ghostLosses() + handler.ghostReserveLosses();
        assertEq(held + outflow, inflow, "value is conserved");
    }

    /// @dev Fees come only out of booked profit, never above the rate bound, and every fee taken is still held or
    /// was paid out.
    function invariant_feesComeOnlyFromProfit() public view {
        assertLe(handler.ghostFees(), handler.ghostProfit() * earn.MAX_FEE_BPS() / 10_000, "fee within the bound");
        assertEq(
            earn.curatorFees() + earn.protocolFees() + handler.ghostFeesPaid(), handler.ghostFees(), "fees held or paid"
        );
    }

    /// @dev Every USDG the vault holds is in exactly one ledger, but for core credit someone pushed in since
    /// the last harvest.
    function invariant_usdgHeldMatchesTheLedgers() public view {
        uint256 accounted = earn.cash() + earn.curatorFees() + earn.protocolFees() + earn.pocketLiability(address(usdg))
            + earn.unassignedCash();
        assertEq(usdg.balanceOf(address(earn)), accounted + handler.ghostPushedUnharvested());
    }

    function invariant_reserveSharesMatchTheReserve() public view {
        assertEq(earn.reserveShares(), reserve.balanceOf(address(earn)));
    }

    function invariant_sharesReconcile() public view {
        uint256 balances;
        for (uint256 i; i < 3; ++i) {
            balances += earn.balanceOf(handler.actors(i));
        }
        assertEq(balances, earn.totalSupply());
    }

    function invariant_principalLedgersAndTheOpenSetReconcile() public view {
        uint256 performing;
        uint256[3] memory lanes;
        uint256 open;
        uint40 earliest = type(uint40).max;
        open = 0;
        for (uint256 i; i < handler.loanCount(); ++i) {
            uint256 id = handler.loanIds(i);
            EarnVault.Loan memory ln = _loan(id);
            if (ln.settled) {
                // A withdrawn commitment is refunded even if others filled the listing and let it default.
                assertTrue(
                    ln.snapshotId != 0 || ln.withdrawn || core.getLoan(id).state != V2State.DEFAULTED,
                    "a default is settled only through a write-off unless the commitment was withdrawn"
                );
                continue;
            }
            ++open;
            performing += ln.principal;
            lanes[uint8(ln.lane)] += ln.principal;
            if (ln.maturity < earliest) earliest = ln.maturity;
        }
        assertEq(performing, earn.performingPrincipal());
        assertEq(lanes[0], earn.lanePrincipal(EarnLane.STOCK));
        assertEq(lanes[1], earn.lanePrincipal(EarnLane.MEME));
        assertEq(lanes[2], earn.lanePrincipal(EarnLane.LP));
        assertEq(earliest, earn.earliestMaturity());
        if (open == 0) assertEq(earliest, type(uint40).max);
    }

    function invariant_pocketsAreHeldForTheHoldersOfRecord() public view {
        uint256 count = earn.pocketCount();
        uint256 nvdaOwed;
        uint256 memeOwed;
        for (uint256 pocketId = 1; pocketId <= count; ++pocketId) {
            (, address token, uint256 amount, uint256 supply, uint256 claimed,) = earn.pockets(pocketId);
            assertGt(supply, 0);
            uint256 claimable;
            for (uint256 i; i < 3; ++i) {
                claimable += earn.pocketClaimable(pocketId, handler.actors(i));
            }
            assertLe(claimed + claimable, amount, "a pocket never owes more than it holds");
            assertGe(claimed + claimable + 3, amount, "at most one unit of rounding per holder");
            if (token == address(nvda)) nvdaOwed += amount - claimed;
            else memeOwed += amount - claimed;
        }
        assertEq(earn.pocketLiability(address(nvda)), nvdaOwed);
        assertEq(earn.pocketLiability(address(meme)), memeOwed);
        assertGe(nvda.balanceOf(address(earn)), nvdaOwed);
        assertGe(meme.balanceOf(address(earn)), memeOwed);
    }

    function invariant_rewardsAreConserved() public view {
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            owed += earn.rewardClaimable(handler.actors(i));
        }
        assertLe(owed, earn.accountedRewards());
        assertLe(earn.accountedRewards(), sgage.balanceOf(address(earn)));
    }

    /// @dev Open loans never earn more than their fixed cost less the fee, and shares are never worth more than
    /// the assets: interest is recognized as the term runs and at most in full.
    function invariant_interestIsBoundedByTheFixedCost() public view {
        uint256 ceiling;
        uint256 rate;
        for (uint256 i; i < handler.loanCount(); ++i) {
            EarnVault.Loan memory ln = _loan(handler.loanIds(i));
            if (ln.settled) continue;
            ceiling += ln.interest;
            rate += ln.rate;
        }
        assertEq(rate, earn.accrualRate(), "the running rate is the open loans' rates");
        assertLe(earn.accruedInterest(), ceiling, "accrued interest within the open loans' fixed costs");
        assertEq(
            earn.totalAssets(),
            earn.cash() + reserve.convertToAssets(earn.reserveShares()) + earn.performingPrincipal()
                + earn.accruedInterest()
        );
        uint256 supply = earn.totalSupply();
        if (supply != 0) {
            assertLe(earn.convertToAssets(supply), earn.totalAssets() + 1);
        }
    }

    function invariant_pricingIsOnlyPausedByAnUnsettledDefault() public view {
        if (block.timestamp < earn.earliestMaturity()) return;
        // Something open has passed its maturity; a settle call must be able to clear it.
        uint256 open;
        for (uint256 i; i < handler.loanCount(); ++i) {
            if (!_loan(handler.loanIds(i)).settled) ++open;
        }
        assertGt(open, 0);
    }
}
