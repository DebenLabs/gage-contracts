// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";

/// @notice The execution-fee ceiling a vault's manager sets, at creation and afterwards (D32), and the vault's rate
/// floor measured after that fee (D7).
/// @dev The ceilings used here are fixture values. No production ceiling is selected by these tests.
contract IntentExecutionBoundsTest is IntentAccountingBaseTest {
    uint256 internal constant GROSS = 100e6;

    function _vaultAt(uint16 capBps, uint8 minRateGrade) internal returns (IntentVault vault) {
        mandate.executionCapBps = capBps;
        mandate.minRateGrade = minRateGrade;
        vm.prank(curator);
        vault = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
        vm.prank(alice);
        usdg.approve(address(vault), MAX);
        vm.prank(alice);
        vault.deposit(10_000e6, 0);
    }

    function _fund(IntentVault vault, uint256 id, uint256 executionFee) internal {
        vm.prank(fillers[0]);
        router.fund(vault, id, UNITS, executionFee);
    }

    function _modeled(uint32 bps) internal {
        address[] memory tokens = new address[](1);
        uint32[] memory terms = new uint32[](1);
        uint32[] memory costs = new uint32[](1);
        tokens[0] = address(nvda);
        terms[0] = T21;
        costs[0] = bps;
        grades.setModeledCosts(tokens, terms, costs);
    }

    function _listing() internal returns (uint256) {
        return _list(borrower, address(nvda), 100e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21);
    }

    function testAVaultTakesItsExecutionCeilingFromItsManagersMandate() public {
        IntentVault first = _vaultAt(2000, 0);
        assertEq(first.executionCapBps(), 2000);
        IntentVault second = _vaultAt(500, 0);
        assertEq(second.executionCapBps(), 500);
        assertEq(first.executionCapBps(), 2000, "one vault's ceiling is not another's");
        IntentVault none = _vaultAt(0, 0);
        assertEq(none.executionCapBps(), 0, "zero allows no execution fee");
    }

    function testAMandateAboveTheCompileTimeBoundIsRefused() public {
        uint16 most = IntentFeeMath.MAX_EXECUTION_CAP_BPS;
        assertEq(most, 5000);
        _vaultAt(most, 0);
        mandate.executionCapBps = most + 1;
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
    }

    function testTheManagerMovesTheCeilingEitherWayWithinTheBoundAndEmits() public {
        IntentVault vault = _vaultAt(2000, 0);
        uint16 most = IntentFeeMath.MAX_EXECUTION_CAP_BPS;
        uint16[4] memory moves = [uint16(0), most, 1, 2500];
        for (uint256 i; i < moves.length; ++i) {
            vm.expectEmit(address(vault));
            emit IntentVault.ExecutionCapSet(moves[i]);
            vm.prank(curator);
            vault.setExecutionCap(moves[i]);
            assertEq(vault.executionCapBps(), moves[i]);
        }
        vm.prank(curator);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        vault.setExecutionCap(most + 1);
        assertEq(vault.executionCapBps(), 2500);
    }

    function testOnlyTheManagerMovesTheCeiling() public {
        IntentVault vault = _vaultAt(2000, 0);
        address[3] memory others = [alice, fillers[0], address(this)];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(IntentVault.NotCurator.selector);
            vault.setExecutionCap(100);
        }
        assertEq(vault.executionCapBps(), 2000);
    }

    function testAMovedCeilingGovernsTheNextPurchaseAndLeavesABookedFeeAlone() public {
        IntentVault vault = _vaultAt(2000, 0);
        uint256 a = _listing();
        _fund(vault, a, 20e6);
        vm.prank(curator);
        vault.setExecutionCap(500);
        uint256 b = _listing();
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        router.fund(vault, b, UNITS, 5e6 + 1);
        _fund(vault, b, 5e6);
        (,,,,,,,,,,,,,, uint128 earlier,) = vault.loans(a);
        (,,,,,,,,,,,,,, uint128 later,) = vault.loans(b);
        assertEq(earlier, 20e6, "the fee of a purchase already made");
        assertEq(later, 5e6);
        vm.prank(curator);
        vault.setExecutionCap(4000);
        uint256 c = _listing();
        _fund(vault, c, 40e6);
    }

    function testAnExecutionFeeAboveTheCeilingIsRefusedAndTheCeilingItselfIsAccepted() public {
        uint16[5] memory caps = [uint16(0), 1, 2000, 2500, IntentFeeMath.MAX_EXECUTION_CAP_BPS];
        for (uint256 i; i < caps.length; ++i) {
            IntentVault vault = _vaultAt(caps[i], 0);
            uint256 ceiling = GROSS * caps[i] / 10_000;
            uint256 id = _listing();
            vm.prank(fillers[0]);
            vm.expectRevert(IntentVault.LimitExceeded.selector);
            router.fund(vault, id, UNITS, ceiling + 1);
            _fund(vault, id, ceiling);
            (,,,,,,,,,,,,,, uint128 booked,) = vault.loans(id);
            assertEq(booked, ceiling);
        }
    }

    function testFuzz_TheCeilingHoldsForEveryPurchaseSize(uint8 units, uint16 capBps, uint96 fee) public {
        units = uint8(bound(units, 1, UNITS));
        capBps = uint16(bound(capBps, 0, IntentFeeMath.MAX_EXECUTION_CAP_BPS));
        IntentVault vault = _vaultAt(capBps, 0);
        // An awkward cost, so the quarters round differently.
        uint256 lent = 1_000_000_003;
        uint256 owed = 1_100_000_010;
        uint256 id = _list(borrower, address(nvda), 100e18, uint128(lent), uint128(owed), T21);
        uint256 principal;
        uint256 repayment;
        for (uint8 i; i < units; ++i) {
            principal += lent / 4 + (i < lent % 4 ? 1 : 0);
            repayment += owed / 4 + (i < owed % 4 ? 1 : 0);
        }
        uint256 ceiling = (repayment - principal) * capBps / 10_000;
        uint256 asked = bound(fee, 0, repayment - principal);
        vm.prank(fillers[0]);
        if (asked > ceiling) vm.expectRevert(IntentVault.LimitExceeded.selector);
        router.fund(vault, id, units, asked);
    }

    /// @dev Grade C asks for 75% of the modeled cost. Modeled 10% on 1,000 USDG is 100; the floor is 75.
    function testTheRateFloorIsMeasuredOnWhatTheExecutionFeeLeaves() public {
        _modeled(1000);
        IntentVault vault = _vaultAt(IntentFeeMath.MAX_EXECUTION_CAP_BPS, 2);
        uint256 id = _listing();
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(vault, id, UNITS, 25e6 + 1);
        _fund(vault, id, 25e6);
    }

    function testAListingUnderTheFloorIsRefusedEvenWithNoExecutionFee() public {
        _modeled(1400);
        IntentVault vault = _vaultAt(2000, 2);
        // 100 offered against a floor of 105.
        uint256 id = _listing();
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(vault, id, UNITS, 0);
    }

    function testTheManagerFeeDoesNotChangeTheRoomForTheExecutionFee() public {
        _modeled(1000);
        mandate.feeBps = 500;
        IntentVault low = _vaultAt(IntentFeeMath.MAX_EXECUTION_CAP_BPS, 2);
        mandate.feeBps = 1500;
        IntentVault high = _vaultAt(IntentFeeMath.MAX_EXECUTION_CAP_BPS, 2);
        uint256 a = _listing();
        uint256 b = _listing();
        _fund(low, a, 25e6);
        _fund(high, b, 25e6);
        uint256 c = _listing();
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(high, c, UNITS, 25e6 + 1);
    }
}
