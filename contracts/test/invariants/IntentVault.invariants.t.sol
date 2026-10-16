// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "../intent/IntentAccountingBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLimit} from "../../src/intent/IntentVaultState.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentHandler, IntentInvariantRouter} from "./IntentHandler.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @notice The partner vault's accounting (S2, as D51 left it) as stateful properties over random call sequences.
/// @dev fail_on_revert=true. Includes reserve impairment/recovery and reward delivery/claim actions.
contract IntentVaultInvariants is IntentAccountingBaseTest {
    IntentHandler internal handler;

    /// @dev The forwarding router is the first and only router the factory names, and so the one it binds.
    function _namesStandInRouter() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        IntentInvariantRouter forwarding = new IntentInvariantRouter(partnerFactory);
        partnerFactory.setFillRouter(address(forwarding));
        handler = new IntentHandler(partner, forwarding, core, usdg, reserve, [nvda, gold], borrower, fillers[0]);
        // S9: the vault buys existing positions, with no extra return asked; enabling waits (proposed D37).
        IntentAssetPolicy policy = partner.ASSET_POLICY();
        vm.prank(curator);
        policy.setSecondaryPolicy(true, 0);
        vm.warp(block.timestamp + policy.SECONDARY_LOOSEN_DELAY());
        policy.activateSecondaryPolicy();
        bytes4[] memory selectors = new bytes4[](37);
        selectors[0] = IntentHandler.deposit.selector;
        selectors[1] = IntentHandler.redeem.selector;
        selectors[2] = IntentHandler.redeemAll.selector;
        selectors[3] = IntentHandler.roundTrip.selector;
        selectors[4] = IntentHandler.claimPocket.selector;
        selectors[5] = IntentHandler.investReserve.selector;
        selectors[6] = IntentHandler.divestReserve.selector;
        selectors[7] = IntentHandler.reserveGain.selector;
        selectors[8] = IntentHandler.fillerFunds.selector;
        selectors[9] = IntentHandler.topUp.selector;
        selectors[10] = IntentHandler.fillLoan.selector;
        selectors[11] = IntentHandler.borrowerRepays.selector;
        selectors[12] = IntentHandler.borrowerCancels.selector;
        selectors[13] = IntentHandler.thirdPartyFinalizesDefault.selector;
        selectors[14] = IntentHandler.withdrawCommitment.selector;
        selectors[15] = IntentHandler.pushCoreCredit.selector;
        selectors[16] = IntentHandler.warp.selector;
        selectors[17] = IntentHandler.warpPastMaturity.selector;
        selectors[18] = IntentHandler.settle.selector;
        selectors[19] = IntentHandler.settleOneRepaidEarly.selector;
        selectors[20] = IntentHandler.recover.selector;
        selectors[21] = IntentHandler.claimFees.selector;
        selectors[22] = IntentHandler.setLimit.selector;
        selectors[23] = IntentHandler.activateLimit.selector;
        // Weight the path S2 changed: loans that are funded, repaid and booked before the end of their term.
        selectors[24] = IntentHandler.fillerFunds.selector;
        selectors[25] = IntentHandler.borrowerRepays.selector;
        selectors[26] = IntentHandler.routerCollects.selector;
        selectors[27] = IntentHandler.reserveLoss.selector;
        selectors[28] = IntentHandler.recapitalize.selector;
        selectors[29] = IntentHandler.harvestRewards.selector;
        selectors[30] = IntentHandler.deliverRewards.selector;
        selectors[31] = IntentHandler.claimRewards.selector;
        selectors[32] = IntentHandler.setExecutionCap.selector;
        selectors[33] = IntentHandler.vaultBuysAsk.selector;
        selectors[34] = IntentHandler.vaultSells.selector;
        selectors[35] = IntentHandler.claimPockets.selector;
        selectors[36] = IntentHandler.cancelLimit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The handler must be able to walk every S2 transition, or the invariants below prove nothing.
    function testEveryHandlerActionHasAReachableSuccessfulPath() public {
        handler.deposit(0, 50_000e6);
        handler.deposit(1, 20_000e6);
        handler.investReserve(10_000e6);
        handler.reserveGain(500e6);
        handler.divestReserve(1e18);
        // The third argument seeds both the premium and the execution fee; these seeds give a fee above zero.
        handler.fillerFunds(0, 2000e6, 123_456_789, 4); // a stock loan on the 21-day term, all four quarters
        assertGt(handler.ghostExecutionEarned(), 0, "a completed fill earned its execution fee");
        handler.routerCollects();
        assertEq(handler.ghostExecutionCollected(), handler.ghostExecutionEarned(), "the router collected it");
        assertEq(partner.executionFees(), 0);
        handler.fillerFunds(1, 1000e6, 987_654_321, 2); // a commodity loan, two quarters
        assertGt(partner.executionPending(), 0, "a partial purchase holds its fee pending");
        handler.topUp(1);
        assertEq(handler.ghostTopUps(), 1);
        handler.fillLoan(1);
        handler.fillerFunds(2, 1500e6, 555_555_551, 1);
        handler.withdrawCommitment(2);
        handler.fillerFunds(3, 1500e6, 777_777_773, 1);
        handler.borrowerCancels(3);
        assertEq(handler.loanCount(), 4);
        handler.warp(2 days);
        handler.borrowerRepays(0);
        handler.roundTrip(2, 1_000_000e6);
        handler.pushCoreCredit();
        handler.settleOneRepaidEarly(0);
        assertEq(handler.ghostEarlySettlements(), 1, "a repayment was booked before the end of its term");
        handler.settle(0);
        assertGt(handler.ghostExecutionReversed(), 0, "a refunded purchase returned its execution fee");
        assertEq(partner.executionPending(), 0, "every fee is earned or returned once its loan is seen");
        assertGt(partner.pocketLiability(address(usdg)), 0, "the early booking opened its earnings claim");
        assertEq(handler.ghostEarningsPockets(), 1);
        handler.roundTrip(2, 1_000_000e6);
        handler.claimFees();
        handler.warpPastMaturity();
        handler.thirdPartyFinalizesDefault(1);
        handler.settle(0);
        handler.recover(1);
        assertGt(partner.pocketCount(), 0, "a default opened a pocket");
        handler.claimPocket(0, 0);
        assertGt(handler.ghostEarningsClaimed(), 0, "a holder collected its part of the earnings claim");
        handler.claimPockets(1);
        handler.warpPastMaturity();
        handler.settle(0);
        assertEq(partner.earliestMaturity(), type(uint40).max, "every open loan settled");
        // D53: tightenings apply at once; a loosening applies once its three hours have passed.
        handler.setLimit(uint8(IntentLimit.CATEGORY_STOCK), 5000);
        handler.setLimit(uint8(IntentLimit.MAX_LOAN_PRINCIPAL), 5000e6);
        handler.setLimit(uint8(IntentLimit.MAX_ASSET_BPS), 5000);
        handler.setLimit(uint8(IntentLimit.BUFFER_BPS), 500);
        assertEq(partner.maxLoanPrincipal(), 5000e6, "tightened at once");
        handler.setLimit(uint8(IntentLimit.MAX_LOAN_PRINCIPAL), 6000e6);
        handler.activateLimit(uint8(IntentLimit.MAX_LOAN_PRINCIPAL));
        assertEq(partner.maxLoanPrincipal(), 5000e6, "the raise waits");
        vm.warp(block.timestamp + 3 hours);
        handler.activateLimit(uint8(IntentLimit.MAX_LOAN_PRINCIPAL));
        assertEq(partner.maxLoanPrincipal(), 6000e6, "and applies after its three hours");
        handler.setLimit(uint8(IntentLimit.MAX_ASSET_BPS), 6000);
        handler.cancelLimit(uint8(IntentLimit.MAX_ASSET_BPS));
        handler.setExecutionCap(0);
        assertEq(partner.executionCapBps(), 0, "the manager closed the execution fee");
        handler.setExecutionCap(5000);
        assertEq(partner.executionCapBps(), 5000, "and opened it again, to the bound");
        handler.setPaused(true);
        handler.setPaused(false);
        handler.redeem(1, 1000e18);
        // A second early repayment, still unclaimed when the last holder leaves: the claim stays open to it.
        handler.fillerFunds(0, 1000e6, 500, 4);
        handler.warp(1 days);
        handler.borrowerRepays(4);
        handler.settleOneRepaidEarly(4);
        handler.redeemAll(0);
        handler.redeemAll(1);
        assertEq(handler.ghostLastHolderExits(), 1, "the last holder left with a claim still open");
        assertEq(partner.totalSupply(), 0);
        handler.claimPockets(0);
        handler.claimPockets(1);
        handler.deposit(0, 5000e6);
        handler.fillerFunds(0, 1000e6, 123_456_789, 4);
        handler.warp(1 days);
        handler.deliverRewards(handler.loanCount() - 1);
        handler.harvestRewards(handler.loanCount() - 1);
        handler.claimRewards(0);
        assertGt(handler.ghostRewardsPaid(), 0);
        handler.investReserve(1000e6);
        handler.reserveLoss(500e6);
        handler.recapitalize(100e6);
        assertEq(handler.ghostReserveLosses(), 500e6);
        assertEq(handler.ghostRecapitalized(), 100e6);
        // S9: a bought position, then the vault's sale of it through its own market.
        handler.vaultBuysAsk(0, 1000e6, 490e6, 5);
        assertEq(handler.ghostAcquisitions(), 1, "the vault bought quarters of an active loan");
        // A sale gain needs a window of at least a second (D51).
        handler.warp(1 minutes);
        handler.vaultSells(handler.loanCount() - 1, 600e6);
        assertEq(handler.ghostSales(), 1, "and sold them on");
        invariant_rewardsAreBackedAndCannotBePaidTwice();
        invariant_usdgHeldMatchesTheLedgers();
        invariant_ledgersAndTheOpenSetReconcile();
        invariant_pricedAssetsAreTheLedgers();
        invariant_earningsClaimsAreBackedAndPaidOnce();
        invariant_valueIsConserved();
    }

    /// @dev The nightly run's shrunk counterexample (25 September 2026): value reached the vault while no share was
    /// out, so a newcomer's deposit bought few shares, and the virtual shares took 0.26% of the next earnings claim.
    function testFewSharesSequenceLeavesTheEarningsClaimWhole() public {
        handler.deposit(2_752_144_835, 2_173_672_379_153_961_195_187_128_725);
        handler.recapitalize(
            7_812_430_456_225_222_372_248_119_825_521_262_150_380_820_430_408_292_514_181_572_928_655_458
        );
        handler.redeemAll(669_880_949_315);
        handler.investReserve(
            78_805_512_191_647_263_829_508_620_837_253_969_603_632_069_873_344_861_296_970_182_923_532_978
        );
        handler.reserveGain(379_838_403_209_198_204_995_429_392_168_645_401_060_494_817_770_665);
        handler.deposit(36_372_073_511_611_056_887_602_373_682_473, 862);
        handler.fillerFunds(326_969_817, 1_491_691_422, 16, 148);
        handler.borrowerRepays(46_641_254_089_743_970_937_590_200_337_833_874_291_427_750_210_710_161_087_075_939);
        handler.warp(11_009);
        handler.settle(10_918_496_080_963_533_353_370_798_607_476_587_206_377_546_867);
        assertEq(partner.pocketCount(), 1, "the sequence no longer opens an earnings claim");
        assertLt(partner.totalSupply(), 1e15, "the sequence no longer leaves few shares");
        invariant_pocketsAreHeldForTheHoldersOfRecord();
    }

    /// @dev D51 in place of D40's replays: after an early booking, a complete reserve loss cannot reach the earnings
    /// claim. The priced equity it wipes out leaves the vault impaired, closed to new money, and the claim still pays.
    function testCompleteReserveLossLeavesTheEarningsClaimWhole() public {
        handler.deposit(0, 50_000e6);
        handler.fillerFunds(0, 2000e6, 500, 4);
        handler.warp(2 days);
        handler.borrowerRepays(0);
        handler.settleOneRepaidEarly(0);
        uint256 claim = partner.pocketLiability(address(usdg));
        assertGt(claim, 0);
        handler.investReserve(type(uint256).max);
        assertEq(partner.cash(), 0, "all of cash can be invested: the claim is not cash");
        handler.reserveLoss(type(uint256).max);
        assertEq(partner.pocketLiability(address(usdg)), claim, "the reserve loss reached the claim");
        assertGe(usdg.balanceOf(address(partner)), claim);
        assertTrue(_isImpaired(), "the loss wiped out priced equity");
        handler.roundTrip(1, 1_000_000e6);
        assertEq(handler.ghostRoundTrips(), 0, "an impaired vault takes no new money");
        handler.claimPocket(0, 0);
        assertApproxEqAbs(handler.ghostEarningsClaimed(), claim, 1, "the sole holder's claim was paid in full");
        invariant_usdgHeldMatchesTheLedgers();
        invariant_pricedAssetsAreTheLedgers();
        invariant_earningsClaimsAreBackedAndPaidOnce();
        invariant_valueIsConserved();
    }

    /// @dev The vault's own `Impaired` guard, probed rather than recomputed: a zero deposit is refused whatever happens,
    /// and it stops at the guard exactly when the guard holds. Only the pause and settlement checks come before it.
    function _isImpaired() internal returns (bool) {
        assertFalse(partner.paused() || block.timestamp >= partner.earliestMaturity(), "the guard is reachable");
        (bool ok, bytes memory why) = address(partner).call(abi.encodeCall(IntentVault.deposit, (0, 0)));
        assertFalse(ok, "a zero deposit is refused");
        return bytes4(why) == IntentVault.Impaired.selector;
    }

    /// @dev Realized value: what the vault holds for holders and fees is what came in less what left, plus booked
    /// profit and the interest a written-off loan had earned into the price, less booked losses, plus reserve gains.
    /// Paid interest is realized cash, so it sits in `cash` on the left whether or not its schedule has earned it.
    /// @dev Wherever the manager moves it, the ceiling stays inside the compile-time bound.
    function invariant_theExecutionCeilingStaysWithinItsBound() public view {
        assertLe(partner.executionCapBps(), IntentFeeMath.MAX_EXECUTION_CAP_BPS, "ceiling within bound");
    }

    function invariant_valueIsConserved() public view {
        uint256 held = partner.cash() + usdg.balanceOf(address(reserve)) + partner.performingPrincipal()
            + partner.curatorFees() + partner.protocolFees() + partner.executionPending() + partner.executionFees()
            + partner.pocketLiability(address(usdg));
        uint256 inflow = handler.ghostDeposited() + handler.ghostProfit() + handler.ghostEarnedLost()
            + handler.ghostReserveGains() + handler.ghostRecapitalized();
        // S4: collected execution fees left to the fill router; they are an outflow, counted exactly once. D51: paid
        // earnings claims left to their holders.
        uint256 outflow = handler.ghostRedeemed() + handler.ghostFeesPaid() + handler.ghostLosses()
            + handler.ghostExecutionCollected() + handler.ghostReserveLosses() + handler.ghostEarningsClaimed();
        assertEq(held + outflow, inflow, "value is conserved");
    }

    /// @dev An execution fee is booked once and then held in exactly one place: pending until its loan is seen
    /// active, earned from then on until the fill router collects it (S4), or back in cash after a refund.
    function invariant_executionFeesAreBookedOnceAndHeldInOnePlace() public view {
        assertEq(partner.executionFees() + handler.ghostExecutionCollected(), handler.ghostExecutionEarned(), "earned");
        assertEq(
            usdg.balanceOf(address(handler.ROUTER())), handler.ghostExecutionCollected(), "collected fees left once"
        );
        assertEq(
            partner.executionPending() + handler.ghostExecutionEarned() + handler.ghostExecutionReversed(),
            handler.ghostExecutionBooked(),
            "pending, earned and reversed are every fee booked"
        );
        uint256 pending;
        uint256 earned;
        for (uint256 i; i < handler.loanCount(); ++i) {
            (uint128 fee, bool isEarned) = handler.executionOf(handler.loanIds(i));
            if (isEarned) earned += fee;
            else pending += fee;
        }
        assertEq(pending, partner.executionPending(), "the pending ledger is the loans' unearned fees");
        assertEq(
            earned,
            partner.executionFees() + handler.ghostExecutionCollected(),
            "the earned ledger and what the router collected are the loans' earned fees"
        );
    }

    function invariant_feesComeOnlyFromProfit() public view {
        assertLe(handler.ghostFees(), handler.ghostProfit() * partner.feeBps() / 10_000, "fee within the fixed rate");
        assertEq(
            partner.curatorFees() + partner.protocolFees() + handler.ghostFeesPaid(),
            handler.ghostFees(),
            "fees held or paid"
        );
    }

    function invariant_usdgHeldMatchesTheLedgers() public view {
        uint256 accounted = partner.cash() + partner.curatorFees() + partner.protocolFees() + partner.executionPending()
            + partner.executionFees() + partner.pocketLiability(address(usdg)) + partner.unassignedCash();
        assertEq(usdg.balanceOf(address(partner)), accounted + handler.ghostPushedUnharvested());
    }

    function invariant_sharesReconcile() public view {
        uint256 balances;
        for (uint256 i; i < 3; ++i) {
            balances += partner.balanceOf(handler.actors(i));
        }
        assertEq(balances, partner.totalSupply());
    }

    /// @dev Lent principal, the running rate and the open set all follow from the loans' own records. An open record
    /// never carries an earnings claim: a claim is opened as its record settles (D51).
    function invariant_ledgersAndTheOpenSetReconcile() public view {
        uint256 performing;
        uint256 ceiling;
        uint256[4] memory lanes;
        uint40 earliest = type(uint40).max;
        for (uint256 i; i < handler.loanCount(); ++i) {
            uint256 id = handler.loanIds(i);
            IntentHandler.LoanView memory v = handler.loanView(id);
            if (v.settled) {
                assertEq(v.rate, 0, "a settled loan earns nothing");
                // A vault that sold every quarter it held (S8 seller, S9 resale) has no exposure to a later default:
                // its record was dropped at the sale, whatever the loan did afterwards.
                assertTrue(
                    v.snapshotId != 0 || v.withdrawn || core.getLoan(id).state != V2State.DEFAULTED
                        || core.unitsOf(id, address(partner)) == 0,
                    "a default is settled only through a write-off unless the commitment was withdrawn or sold"
                );
                if (v.repaid) {
                    // An earnings claim is an early repayment, or a sale above book whose buyer now holds every
                    // quarter the vault had: in neither does the vault still lend.
                    assertTrue(
                        core.getLoan(id).state == V2State.REPAID || core.unitsOf(id, address(partner)) == 0,
                        "an earnings claim backs no quarter the vault still holds"
                    );
                }
                continue;
            }
            assertFalse(v.repaid, "an open record carries an earnings claim");
            ceiling += v.interest;
            if (v.maturity < earliest) earliest = v.maturity;
            performing += v.principal;
            lanes[uint8(v.lane)] += v.principal;
        }
        assertEq(performing, partner.performingPrincipal());
        assertEq(lanes[0], partner.categoryPrincipal(IntentCategory.STOCK));
        assertEq(lanes[3], partner.categoryPrincipal(IntentCategory.COMMODITY));
        assertEq(earliest, partner.earliestMaturity());
        assertLe(partner.accruedInterest(), ceiling, "accrued interest within the open loans' fixed costs");
    }

    /// @dev Priced assets are exactly the ledgers: cash, the reserve, lent principal and the interest earned so far.
    /// Earnings claims are outside all of them, and everything priced is either liquid or lent.
    function invariant_pricedAssetsAreTheLedgers() public {
        uint256 liquid = partner.cash() + reserve.convertToAssets(partner.reserveShares());
        uint256 gross = liquid + partner.performingPrincipal() + partner.accruedInterest();
        assertEq(partner.totalAssets(), gross);
        // The guard refuses new risk exactly at zero equity; a paused or due vault refuses before reaching it.
        if (!partner.paused() && block.timestamp < partner.earliestMaturity()) {
            assertEq(_isImpaired(), partner.totalSupply() != 0 && gross == 0, "the vault's Impaired guard");
        }
        assertLe(partner.freeLiquidity(), liquid);
        assertGe(partner.totalAssets(), partner.freeLiquidity());
        uint256 supply = partner.totalSupply();
        if (supply == 0) {
            // `fund` lends nothing at zero supply. The handler's loans are 25 USDG a unit or more, so none can stay
            // lent through the last holder's exit either; a position of one or two raw units can, above par (see
            // docs/intent-v1/evidence/s8-zero-supply-finding.json, residual).
            assertEq(partner.performingPrincipal(), 0, "nothing is lent without a holder");
        } else {
            assertLe(partner.convertToAssets(supply), partner.totalAssets() + 1);
        }
    }

    /// @dev Every USDG pocket is an earnings claim (D51): what they hold is every claim opened less every claim paid,
    /// and each one's supply is its window's length in seconds at the clock's precision, less the part of the clock's
    /// movement over the window that its virtual shares carried.
    function invariant_earningsClaimsAreBackedAndPaidOnce() public view {
        assertEq(
            partner.pocketLiability(address(usdg)),
            handler.ghostEarningsOpened() - handler.ghostEarningsClaimed(),
            "earnings claims held are those opened less those paid"
        );
        uint256 count = partner.pocketCount();
        for (uint256 pocketId = 1; pocketId <= count; ++pocketId) {
            (uint256 loanId, address token,, uint256 supply,, uint64 snapshotId) = partner.pockets(pocketId);
            if (token != address(usdg)) continue;
            assertEq(snapshotId, 0, "an earnings claim has no snapshot");
            uint256 w = partner.exposureWindow(loanId);
            uint256 moved = uint104(w) - (w >> 152);
            assertEq(
                (supply + 1e12 * moved) % 1e33, 0, "an earnings claim's supply is its holders' seconds of exposure"
            );
            assertGt(supply, 0);
            IntentHandler.LoanView memory v = handler.loanView(loanId);
            assertTrue(v.repaid && v.settled, "an earnings claim belongs to a settled record");
        }
    }

    function invariant_pocketsAreHeldForTheHoldersOfRecord() public view {
        uint256 count = partner.pocketCount();
        for (uint256 pocketId = 1; pocketId <= count; ++pocketId) {
            (,, uint256 amount, uint256 supply, uint256 claimed,) = partner.pockets(pocketId);
            assertGt(supply, 0);
            uint256 claimable;
            for (uint256 i; i < 3; ++i) {
                claimable += partner.pocketClaimable(pocketId, handler.actors(i));
            }
            assertLe(claimed + claimable, amount, "a pocket never owes more than it holds");
            // A unit of rounding per holder, and for an earnings claim the clock's own rounding: about a millionth
            // of each second under the share ceiling, twice that for a window ending inside an interpolated reading.
            // The virtual shares hold no part of it.
            assertGe(claimed + claimable + 4 + 2 * amount / 1e6, amount, "a pocket's holders cannot claim it all");
        }
    }

    function invariant_rewardsAreBackedAndCannotBePaidTwice() public view {
        uint256 claims;
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            claims += partner.rewardClaimable(actor);
            paid += sgage.balanceOf(actor);
        }
        assertLe(claims, partner.accountedRewards());
        assertGe(sgage.balanceOf(address(partner)), partner.accountedRewards());
        assertEq(paid, handler.ghostRewardsPaid());
    }

    function invariant_pricingIsOnlyPausedByAnOpenLoanPastItsTerm() public view {
        if (block.timestamp < partner.earliestMaturity()) return;
        uint256 open;
        for (uint256 i; i < handler.loanCount(); ++i) {
            if (!handler.loanView(handler.loanIds(i)).settled) ++open;
        }
        assertGt(open, 0);
    }
}
