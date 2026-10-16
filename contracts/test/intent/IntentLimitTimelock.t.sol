// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentPartnersTest} from "./IntentPartners.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentLimit, INTENT_MAX_LOAN_PRINCIPAL} from "../../src/intent/IntentVaultState.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";

/// @dev Intent D53: each risk limit tightens at once and loosens after three hours, with no creation ceiling or floor.
/// The fixture vault is created at 1,500 USDG a loan, 60% a token, no buffer, no Loan grade floor, stocks 60% and
/// commodities 30%.
contract IntentLimitTimelockTest is IntentPartnersTest {
    IntentAssetPolicy internal policy;
    IntentLimit internal constant STOCKS = IntentLimit.CATEGORY_STOCK;
    IntentLimit internal constant COMMODITIES = IntentLimit.CATEGORY_COMMODITY;

    function setUp() public override {
        super.setUp();
        policy = partner.ASSET_POLICY();
    }

    function _readyAt(IntentLimit limit) internal view returns (uint64 readyAt) {
        (, readyAt) = policy.pendingLimit(limit);
    }

    function testTighteningAppliesAtOnce() public {
        vm.expectEmit(address(policy));
        emit IntentAssetPolicy.LimitSet(IntentLimit.MAX_LOAN_PRINCIPAL, 1000e6);
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1000e6);
        assertEq(partner.maxLoanPrincipal(), 1000e6);
        assertEq(_readyAt(IntentLimit.MAX_LOAN_PRINCIPAL), 0, "nothing queued");
        vm.startPrank(curator);
        // The caps tighten downward, the floors upward.
        policy.setLimit(IntentLimit.MAX_ASSET_BPS, 1000);
        policy.setLimit(COMMODITIES, 1000);
        policy.setLimit(IntentLimit.BUFFER_BPS, 2000);
        policy.setLimit(IntentLimit.MIN_RATE_GRADE, 3);
        vm.stopPrank();
        assertEq(partner.maxAssetBps(), 1000);
        assertEq(partner.categoryWeightBps(IntentCategory.COMMODITY), 1000);
        assertEq(partner.bufferBps(), 2000);
        assertEq(partner.minRateGrade(), 3);
    }

    function testLooseningWaitsThreeHoursThenAnyoneActivatesItPastTheCreationValue() public {
        uint256 at = block.timestamp;
        vm.expectEmit(address(policy));
        emit IntentAssetPolicy.LimitQueued(IntentLimit.MAX_LOAN_PRINCIPAL, 5000e6, at + 10_800);
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 5000e6);
        assertEq(partner.maxLoanPrincipal(), 1500e6, "the loosening waits");
        (uint128 value, uint64 readyAt) = policy.pendingLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        assertEq(value, 5000e6);
        assertEq(readyAt, at + 10_800);
        vm.warp(readyAt - 1);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        vm.warp(readyAt);
        vm.expectEmit(address(partner));
        emit IntentVault.LimitsSet(5000e6, 6000, 0);
        vm.prank(bob);
        policy.activateLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        assertEq(partner.maxLoanPrincipal(), 5000e6, "no ceiling from creation");
        assertEq(_readyAt(IntentLimit.MAX_LOAN_PRINCIPAL), 0);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
    }

    function testEveryLimitLoosensOnlyAfterItsWaitAndNoCreationFloorHolds() public {
        mandate.minRateGrade = 3;
        mandate.bufferBps = 2000;
        partner = _create();
        policy = partner.ASSET_POLICY();
        IntentLimit[6] memory limits = [
            IntentLimit.MAX_LOAN_PRINCIPAL,
            IntentLimit.MAX_ASSET_BPS,
            STOCKS,
            COMMODITIES,
            IntentLimit.BUFFER_BPS,
            IntentLimit.MIN_RATE_GRADE
        ];
        // More per loan, per token and per category; less cash kept free; a lower floor than the one created.
        uint128[6] memory looser = [uint128(3000e6), 10_000, 10_000, 10_000, 0, 1];
        vm.startPrank(curator);
        for (uint256 i; i < limits.length; ++i) {
            policy.setLimit(limits[i], looser[i]);
        }
        vm.stopPrank();
        assertEq(partner.maxLoanPrincipal(), 1500e6);
        assertEq(partner.maxAssetBps(), 6000);
        assertEq(partner.categoryWeightBps(IntentCategory.STOCK), 6000);
        assertEq(partner.categoryWeightBps(IntentCategory.COMMODITY), 3000);
        assertEq(partner.bufferBps(), 2000);
        assertEq(partner.minRateGrade(), 3);
        vm.warp(block.timestamp + 3 hours);
        for (uint256 i; i < limits.length; ++i) {
            policy.activateLimit(limits[i]);
        }
        assertEq(partner.maxLoanPrincipal(), 3000e6);
        assertEq(partner.maxAssetBps(), 10_000);
        assertEq(partner.categoryWeightBps(IntentCategory.STOCK), 10_000);
        assertEq(partner.categoryWeightBps(IntentCategory.COMMODITY), 10_000);
        assertEq(partner.bufferBps(), 0);
        assertEq(partner.minRateGrade(), 1);
    }

    function testATighteningOrTheSameValueDropsTheQueuedLoosening() public {
        vm.startPrank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 5000e6);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1200e6);
        assertEq(partner.maxLoanPrincipal(), 1200e6);
        assertEq(_readyAt(IntentLimit.MAX_LOAN_PRINCIPAL), 0, "the tightening dropped the queued raise");
        policy.setLimit(IntentLimit.MIN_RATE_GRADE, 2);
        policy.setLimit(IntentLimit.MIN_RATE_GRADE, 0);
        policy.setLimit(IntentLimit.MIN_RATE_GRADE, 2);
        vm.stopPrank();
        assertEq(partner.minRateGrade(), 2);
        assertEq(_readyAt(IntentLimit.MIN_RATE_GRADE), 0, "restating the value in force drops the queued lowering");
        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateLimit(IntentLimit.MIN_RATE_GRADE);
    }

    function testANewLooseningReplacesTheQueuedOneAndRestartsItsWait() public {
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_ASSET_BPS, 8000);
        uint64 first = _readyAt(IntentLimit.MAX_ASSET_BPS);
        vm.warp(first - 1);
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_ASSET_BPS, 9000);
        (uint128 value, uint64 readyAt) = policy.pendingLimit(IntentLimit.MAX_ASSET_BPS);
        assertEq(value, 9000);
        assertEq(readyAt, first - 1 + 10_800);
        vm.warp(first);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateLimit(IntentLimit.MAX_ASSET_BPS);
        // The queues are per limit: another limit's loosening neither waits on nor replaces this one.
        vm.prank(curator);
        policy.setLimit(STOCKS, 7000);
        vm.warp(readyAt);
        policy.activateLimit(IntentLimit.MAX_ASSET_BPS);
        assertEq(partner.maxAssetBps(), 9000);
        assertEq(partner.categoryWeightBps(IntentCategory.STOCK), 6000);
        assertGt(_readyAt(STOCKS), 0);
    }

    function testOnlyTheManagerMovesOrCancelsAndOnlyThePolicyApplies() public {
        vm.prank(bob);
        vm.expectRevert(IntentAssetPolicy.NotCurator.selector);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1);
        vm.prank(curator);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.cancelLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 4000e6);
        vm.prank(bob);
        vm.expectRevert(IntentAssetPolicy.NotCurator.selector);
        policy.cancelLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        vm.expectEmit(address(policy));
        emit IntentAssetPolicy.LimitCancelled(IntentLimit.MAX_LOAN_PRINCIPAL);
        vm.prank(curator);
        policy.cancelLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        vm.warp(block.timestamp + 3 hours);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.activateLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        assertEq(partner.maxLoanPrincipal(), 1500e6);
        // No one reaches the vault's limits but its policy, the manager included.
        address[2] memory callers = [curator, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IntentVault.NotCurator.selector);
            partner.applyLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1_000_000e6);
        }
    }

    function testBoundsInCodeAndTheUniverseHold() public {
        vm.startPrank(curator);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, INTENT_MAX_LOAN_PRINCIPAL + 1);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, INTENT_MAX_LOAN_PRINCIPAL);
        IntentLimit[4] memory shares = [IntentLimit.MAX_ASSET_BPS, IntentLimit.BUFFER_BPS, STOCKS, COMMODITIES];
        for (uint256 i; i < shares.length; ++i) {
            vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
            policy.setLimit(shares[i], 10_001);
        }
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.setLimit(IntentLimit.MIN_RATE_GRADE, 5);
        // D41: a category outside the vault's universe stays closed for good; zero there is no change.
        IntentLimit[2] memory outside = [IntentLimit.CATEGORY_MEME, IntentLimit.CATEGORY_RH_ECOSYSTEM];
        for (uint256 i; i < outside.length; ++i) {
            vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
            policy.setLimit(outside[i], 1);
            policy.setLimit(outside[i], 0);
        }
        vm.stopPrank();
        assertEq(partner.categoryWeightBps(IntentCategory.MEME), 0);
        // An enum outside the eight limits is refused by the decoder.
        (bool ok,) = address(policy).call(abi.encodeWithSelector(IntentAssetPolicy.setLimit.selector, uint8(8), 1));
        assertFalse(ok);
        // The same bound holds at creation.
        mandate.maxLoanPrincipal = INTENT_MAX_LOAN_PRINCIPAL + 1;
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
    }

    /// @dev A loosening admits nothing until it applies; a tightening refuses at once.
    function testFundingFollowsTheLimitInForce() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(2000e6);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, 4);
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 3000e6);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, 4);
        vm.warp(_readyAt(IntentLimit.MAX_LOAN_PRINCIPAL));
        policy.activateLimit(IntentLimit.MAX_LOAN_PRINCIPAL);
        _route(id, 4);
        assertEq(partner.performingPrincipal(), 2000e6);
        uint256 next = _listed(1000e6);
        vm.prank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 999e6);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, next, 4);
    }

    /// @dev Steward (D177): a key allowed only to reduce risk is granted `tightenLimit`, which refuses any loosening.
    function testTightenLimitAppliesAtOnceAndRefusesALoosening() public {
        vm.startPrank(curator);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 4000e6);
        policy.tightenLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1000e6);
        assertEq(partner.maxLoanPrincipal(), 1000e6);
        assertEq(_readyAt(IntentLimit.MAX_LOAN_PRINCIPAL), 0, "the tightening drops the queued raise");
        policy.tightenLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1000e6);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.tightenLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1000e6 + 1);
        policy.tightenLimit(IntentLimit.BUFFER_BPS, 1000);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.tightenLimit(IntentLimit.BUFFER_BPS, 999);
        policy.tightenLimit(IntentLimit.MIN_RATE_GRADE, 2);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.tightenLimit(IntentLimit.MIN_RATE_GRADE, 1);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.tightenLimit(COMMODITIES, 3001);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.tightenLimit(IntentLimit.CATEGORY_MEME, 1);
        vm.stopPrank();
        assertEq(_readyAt(IntentLimit.MIN_RATE_GRADE), 0, "a refused loosening queues nothing");
        vm.prank(bob);
        vm.expectRevert(IntentAssetPolicy.NotCurator.selector);
        policy.tightenLimit(IntentLimit.MAX_LOAN_PRINCIPAL, 1);
    }

    function testTheHelperReachesEitherDirection() public {
        IntentLimits.setLimits(partner, 2500e6, 9000, 500);
        assertEq(partner.maxLoanPrincipal(), 2500e6);
        assertEq(partner.maxAssetBps(), 9000);
        assertEq(partner.bufferBps(), 500);
        IntentLimits.setCategoryWeight(partner, IntentCategory.STOCK, 100);
        IntentLimits.setMinRateGrade(partner, 4);
        assertEq(partner.categoryWeightBps(IntentCategory.STOCK), 100);
        assertEq(partner.minRateGrade(), 4);
    }
}

/// @dev Intent D54: every vault is named by its manager at creation, and only its manager renames it.
contract IntentVaultNamesTest is IntentPartnersTest {
    function testTheNameIsRecordedAtCreation() public {
        vm.prank(curator);
        address created = partnerFactory.create(mandate, false, 0, "Robinhood blue chips");
        assertEq(partnerFactory.nameOf(created), "Robinhood blue chips");
        assertEq(partnerFactory.nameOf(address(partner)), "Test vault");
    }

    function testCreationEmitsTheNameInUtf8() public {
        address predicted = vm.computeCreateAddress(address(partnerFactory), vm.getNonce(address(partnerFactory)));
        vm.expectEmit(address(partnerFactory));
        emit IntentFactory.VaultNamed(predicted, unicode"Café ☕ vault");
        vm.prank(curator);
        address created = partnerFactory.create(mandate, false, 0, unicode"Café ☕ vault");
        assertEq(created, predicted);
        assertEq(partnerFactory.nameOf(created), unicode"Café ☕ vault");
    }

    function testANameIsOneTo48Bytes() public {
        string memory longest = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv";
        assertEq(bytes(longest).length, 48);
        vm.startPrank(curator);
        vm.expectRevert(IntentFactory.InvalidName.selector);
        partnerFactory.create(mandate, false, 0, "");
        vm.expectRevert(IntentFactory.InvalidName.selector);
        partnerFactory.create(mandate, false, 0, string.concat(longest, "w"));
        address created = partnerFactory.create(mandate, false, 0, longest);
        vm.stopPrank();
        assertEq(partnerFactory.nameOf(created), longest);
    }

    function testOnlyTheManagerRenamesItsOwnVault() public {
        vm.expectEmit(address(partnerFactory));
        emit IntentFactory.VaultNamed(address(partner), "Steady stocks");
        vm.prank(curator);
        partnerFactory.setName(address(partner), "Steady stocks");
        assertEq(partnerFactory.nameOf(address(partner)), "Steady stocks");
        vm.prank(bob);
        vm.expectRevert(IntentFactory.NotManager.selector);
        partnerFactory.setName(address(partner), "Mine now");
        // The factory's owner cannot rename it either, and an address that is not a vault has no name to set.
        vm.expectRevert(IntentFactory.NotManager.selector);
        partnerFactory.setName(address(partner), "Owner's pick");
        vm.prank(curator);
        vm.expectRevert(IntentFactory.NotManager.selector);
        partnerFactory.setName(address(router), "Not a vault");
        vm.prank(curator);
        vm.expectRevert(IntentFactory.InvalidName.selector);
        partnerFactory.setName(address(partner), "");
        assertEq(partnerFactory.nameOf(address(partner)), "Steady stocks");
    }
}
