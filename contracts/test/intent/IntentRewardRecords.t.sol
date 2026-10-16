// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentBridgedBaseTest} from "./IntentBridgedBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev `_openLoans._inner._values.length`, the count of open reward records, pinned by `IntentVaultSettingsLayout`.
uint256 constant OPEN_RECORDS_SLOT = 29;

/// @notice A vault's reward records on a native core: nothing a record earned is left for holders who arrive after it
/// settles, at zero supply or otherwise.
contract IntentRewardRecordsTest is IntentAccountingBaseTest {
    /// @dev Pashov M-59, M-60. A record kept open after its booking (its claim failed) refuses the last exit, and the
    /// last exit that succeeds collects it for the holder of record. Nothing is left to harvest at zero supply, so
    /// nothing reaches a later depositor.
    function testLastExitCollectsARetainedRecordBeforeZeroSupply() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        uint256 earned = coreRewards.claimable(id, address(partner));
        assertGt(earned, 0);
        vm.mockCallRevert(address(coreRewards), abi.encodeWithSelector(GageV2Rewards.claim.selector), "paused");
        _book(id);
        assertTrue(_ln(id).settled);
        assertEq(_openRecords(), 1, "the settled record stays open while its claim fails");
        uint256 shares = partner.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IntentVault.RewardsPending.selector);
        partner.redeem(shares, 0);
        vm.clearMockedCalls();

        _exitAll(alice);
        assertEq(partner.totalSupply(), 0);
        assertEq(_openRecords(), 0);
        assertEq(coreRewards.claimable(id, address(partner)), 0, "nothing is left to harvest at zero supply");
        assertEq(sgage.balanceOf(address(partner)), partner.accountedRewards(), "every sGAGE held has an owner");
        assertApproxEqAbs(partner.rewardClaimable(alice), earned, 10_000);

        vm.warp(_startOf(id) + 60 days);
        partner.harvestRewards(_ids(id));
        _enter(bob, 1000e6);
        partner.harvestRewards(_ids(id));
        assertEq(sgage.balanceOf(address(partner)), partner.accountedRewards());
        assertEq(partner.rewardClaimable(bob), 0, "a later depositor inherits nothing");
    }

    /// @dev Pashov M-73. The core closes the vault's allocation at repayment, so the vault's claimable on the repaid
    /// loan, which its record collects when it is booked, is fixed from then on: it does not grow after the loan's
    /// term. The record itself is not booked here.
    function testSettledRecordClaimableIsFrozen() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        uint256 frozen = coreRewards.claimable(id, address(partner));
        assertGt(frozen, 0);
        vm.warp(_startOf(id) + 60 days);
        assertEq(coreRewards.claimable(id, address(partner)), frozen);
    }

    /// @dev Pashov M-73. A record retired at zero claimable (repaid in its activation second, booked one second later)
    /// never regains any: a later depositor and a later harvest find nothing.
    function testRecordRetiredAtZeroStaysZero() public {
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        _repay(id);
        vm.warp(_startOf(id) + 1);
        _book(id);
        assertTrue(_ln(id).settled);
        assertEq(_openRecords(), 0, "retired at zero claimable");
        _enter(bob, 1000e6);
        vm.warp(_startOf(id) + 60 days);
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        partner.harvestRewards(_ids(id));
        assertEq(sgage.balanceOf(address(partner)), 0);
        assertEq(partner.rewardClaimable(bob), 0);
    }

    function _openRecords() internal view returns (uint256) {
        return uint256(vm.load(address(partner), bytes32(OPEN_RECORDS_SLOT)));
    }
}

/// @notice A vault's reward records on a bridged core, against the real local legacy adapter, Drip and DealRewards.
/// @dev The adapter pays `min(requested, liquid)`. Here its allocation exceeds the legacy grant by a recycled prefund
/// and the lender share is not half, so the adapter's and the legacy curves round apart: this is the case where a
/// claim could be paid short, if it ever were.
contract IntentRewardRecordsBridgedTest is IntentBridgedBaseTest {
    using stdStorage for StdStorage;

    uint16 internal constant LENDER_SHARE_BPS = 3333;
    /// @dev Below the adapter's maximum for this fee, so the adapter adds recycled sGAGE to the legacy grant.
    uint256 internal constant LEGACY_GRANT = 555e18 + 13;
    uint256 internal constant PREFUND = 100e18 + 7;

    function setUp() public override {
        super.setUp();
        vm.prank(safe);
        dealRewards.setEpochRates(0, RATE7, RATE21, PRICE, LENDER_SHARE_BPS);
    }

    /// @dev Pashov H-04's stated trigger, M-42, M-43, and M-41's share-change half. The borrower claims first at
    /// every sample, and the vault's deposit, redemption or harvest that follows is still paid its whole claimable:
    /// 623 samples over a 21-day loan (every second of the first and last minute, every 3,607 seconds between). No
    /// sample leaves a remainder for `RewardsPending`, and the prefund is drawn on: without it, a claim here would be
    /// paid short.
    function testEveryBridgedVaultClaimIsPaidInFull() public {
        (uint256 id, uint256 aid) = _open();
        uint256 start = core.getLoan(id).fundedAt;
        uint256 samples;
        for (uint256 t = 1; t <= 60; ++t) {
            vm.warp(start + t);
            _probe(id, samples++);
        }
        for (uint256 t = 61; t < T21 - 60; t += 3607) {
            vm.warp(start + t);
            _probe(id, samples++);
        }
        for (uint256 t = T21 - 60; t < T21; ++t) {
            vm.warp(start + t);
            _probe(id, samples++);
        }
        assertEq(samples, 623);
        assertLt(bridge.loan(aid).liquid, PREFUND, "the prefund paid what the legacy drips had not yet unlocked");
    }

    /// @dev Pashov M-41 and M-73, bridged; behaviour only, as M-41's capacity half duplicates H-04. The borrower claims
    /// and repays 2 days and 17 seconds in, and a third party recycles the loan's surplus at 12 days. The vault's
    /// settlement, also at 12 days, is still paid in full, its record leaves the open set in that call, and its
    /// claimable stays zero long after the term. No settlement in the repayment second is tested here.
    function testEarlyRepaymentRetiresTheBridgedRecord() public {
        (uint256 id, uint256 aid) = _open();
        uint256 start = core.getLoan(id).fundedAt;
        vm.warp(start + 2 days + 17);
        vm.startPrank(borrower);
        coreRewards.claim(id, borrower);
        core.reclaim(id, borrower);
        vm.stopPrank();
        vm.warp(start + 12 days);
        assertGt(bridge.recycle(aid), 0, "the unearned surplus is freed");

        uint256 owed = coreRewards.claimable(id, address(partner));
        assertGt(owed, 0);
        uint256 held = sgage.balanceOf(address(partner));
        assertEq(_openRecords(), 1);
        partner.settle(_ids(id));
        (,,,,, bool settled,,,,,,,,,,) = partner.loans(id);
        assertTrue(settled);
        assertEq(sgage.balanceOf(address(partner)) - held, owed, "paid in full");
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        assertEq(_openRecords(), 0, "the settled record holds no capacity");

        vm.warp(start + 40 days);
        assertEq(coreRewards.claimable(id, address(partner)), 0);
        vm.prank(lender2);
        partner.deposit(1e6, 0);
    }

    /// @dev A 21-day loan fully bought by the vault, with odd amounts. Recycled sGAGE from earlier loans sits in the
    /// adapter as `recycledFree`, and the epoch's remaining legacy budget is held at `LEGACY_GRANT`.
    function _open() internal returns (uint256 id, uint256 aid) {
        vm.prank(treasury);
        sgage.transfer(address(bridge), PREFUND);
        stdstore.target(address(bridge)).sig(bridge.recycledFree.selector).checked_write(PREFUND);
        vm.mockCall(address(emissions), abi.encodeWithSelector(Emissions.remaining.selector), abi.encode(LEGACY_GRANT));
        vm.prank(borrower);
        id = core.list(
            Collateral(Kind.ERC20, address(nvda), 1e18),
            999_999_937,
            1_099_999_991,
            T21,
            uint40(block.timestamp + 1 days),
            false
        );
        intentRouter.fund(partner, id, 4, 0);
        vm.clearMockedCalls();

        aid = bridge.adapterId(address(core), id);
        GageLegacyAdapter.Loan memory source = bridge.loan(aid);
        (uint128 legacy, uint128 legacyLender, uint128 legacyBorrower) = dealRewards.rewardOf(source.legacyId);
        assertEq(legacy, LEGACY_GRANT);
        assertEq(source.liquid, PREFUND, "the whole prefund backs this allocation");
        assertEq(uint256(source.borrowerReward) + source.lenderReward, legacy + PREFUND);
        assertGt(source.lenderReward, legacyLender);
        assertGt(source.borrowerReward, legacyBorrower);
    }

    /// @dev The borrower drains the shared source first; then a deposit, a redemption or a harvest, in turn.
    function _probe(uint256 id, uint256 sample) internal {
        if (coreRewards.claimable(id, borrower) != 0) {
            vm.prank(borrower);
            coreRewards.claim(id, borrower);
            assertEq(coreRewards.claimable(id, borrower), 0, "the borrower is paid in full");
        }
        uint256 owed = coreRewards.claimable(id, address(partner));
        uint256 held = sgage.balanceOf(address(partner));
        if (sample % 3 == 0) {
            vm.prank(lender2);
            partner.deposit(1e6, 0);
        } else if (sample % 3 == 1) {
            uint256 shares = partner.convertToShares(1e6);
            vm.prank(lender);
            partner.redeem(shares, 0);
        } else {
            partner.harvestRewards(_ids(id));
        }
        assertEq(sgage.balanceOf(address(partner)) - held, owed, "the vault's whole claimable was paid");
        assertEq(coreRewards.claimable(id, address(partner)), 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _openRecords() internal view returns (uint256) {
        return uint256(vm.load(address(partner), bytes32(OPEN_RECORDS_SLOT)));
    }
}

/// @notice The arithmetic lemma under the bridged tests, on a model of the formulas rather than the contracts.
contract IntentRewardRecordsBoundTest is Test {
    /// @dev Pashov H-04, M-41, M-42, M-43. `GageLegacyAdapter.open` takes a legacy grant split `ll`/`lb` and an
    /// allocation at least as large on each side, `prefund` more in total. The adapter's `_earned` and `Drip._unlocked`
    /// share the start, the term and the rounded-down curve `amount * e^2 / T^2`, so the loan's earned rewards never
    /// exceed its drips' unlocked amount plus the prefund, at any second of either term.
    function testFuzz_EarnedNeverExceedsUnlockedPlusPrefund(
        uint256 ll,
        uint256 lb,
        uint256 prefund,
        uint256 toLender,
        bool longTerm,
        uint256 elapsed
    ) public pure {
        ll = bound(ll, 0, 5e27);
        lb = bound(lb, 0, 5e27);
        prefund = bound(prefund, 0, 5e27);
        toLender = bound(toLender, 0, prefund);
        uint256 term = longTerm ? 21 days : 7 days;
        elapsed = bound(elapsed, 0, term);
        uint256 square = elapsed * elapsed;
        uint256 denominator = term * term;
        uint256 earned =
            Math.mulDiv(lb + prefund - toLender, square, denominator) + Math.mulDiv(ll + toLender, square, denominator);
        uint256 unlocked = ll * square / denominator + lb * square / denominator;
        assertLe(earned, unlocked + prefund);
    }
}
