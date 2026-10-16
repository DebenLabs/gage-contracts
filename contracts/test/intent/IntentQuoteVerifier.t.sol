// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentPreflight} from "./IntentPreflight.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Kind} from "../../src/types/Types.sol";

import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";

/// @notice S3: signed funding plans, checked against the chain as it stands and used once.
/// @dev Ceilings, grades and costs here are fixture values; none is a launch setting.
contract IntentQuoteVerifierTest is IntentPlanBaseTest {
    // ---------------------------------------------------------------- S3-A1, S3-A2: an executable plan

    function testOneVaultFundsAWholeListingOnAPlanAndTheFeeIsTheReferenceFee() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        IntentQuoteVerifier.Allocation memory a = p.allocations[0];
        // Grade C of a 10% modeled cost on 1,000 is 75; a 20% ceiling on 100 is 20, and 100 - 20 keeps 80.
        assertEq(a.interest, 100e6);
        assertEq(a.minimum, first.minRateGrade() == 2 ? 75e6 : 90e6);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        bytes32 digest = verifier.planHash(p);
        _fill(p);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
        assertEq(_executionFeeOf(first, id), a.executionFee);
        assertTrue(verifier.consumed(digest));
    }

    function testTwoVaultsCompleteAListingInOnePlanEachOnItsOwnTerms() public {
        uint256 id = _list(borrower, address(nvda), 100e18, 1_000_000_003, 1_100_000_010, T21);
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(p.allocations[0].principal + p.allocations[1].principal, 1_000_000_003);
        assertEq(p.allocations[0].interest + p.allocations[1].interest, 100_000_007);
        _fill(p);
        assertEq(_executionFeeOf(first, id), p.allocations[0].executionFee);
        assertEq(_executionFeeOf(second, id), p.allocations[1].executionFee);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
    }

    /// @dev Grade B keeps 90 of 100, so the fee is the 10 the floor leaves, under the 20 the ceiling allows.
    function testTheFeeIsWhatTheFloorLeavesWhenThatIsUnderTheCeilingAndOneUnitMoreIsRefused() public {
        IntentVault strict = first.minRateGrade() == 3 ? first : second;
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(strict, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(p.allocations[0].minimum, 90e6);
        assertEq(p.allocations[0].executionFee, 10e6);
        p.allocations[0].executionFee += 1;
        _assertRefused(p, IntentQuoteVerifier.Refusal.FEE_ABOVE_CEILING);
        p.allocations[0].executionFee -= 1;
        _fill(p);
    }

    function testALowerFeeThanTheReferenceIsAccepted() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        p.allocations[0].executionFee = 1;
        p.allocations[0].maxReserveShares = uint128(first.RESERVE().previewWithdraw(p.allocations[0].principal + 1));
        _fill(p);
        assertEq(_executionFeeOf(first, id), 1);
    }

    function testAListingUnderTheFloorIsRefusedEvenWithNoFee() public {
        // The model asks 14%: grade C keeps 105 of it, and the listing offers 100.
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        p.costBps = 1400;
        p.allocations[0].minimum = uint128(IntentFeeMath.minimumInterest(1000e6, 1400, p.allocations[0].minRateGrade));
        p.allocations[0].executionFee = 0;
        _assertRefused(p, IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR);
    }

    function testASignedMinimumThatIsNotTheRecomputedOneIsRefused() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        p.allocations[0].minimum -= 1;
        _assertRefused(p, IntentQuoteVerifier.Refusal.MINIMUM_MISMATCH);
        p.allocations[0].minimum += 1;
        p.costBps = 0;
        _assertRefused(p, IntentQuoteVerifier.Refusal.NO_MODELED_COST);
    }

    function testFuzz_AnAcceptedFeeNeverPassesTheCeilingOrBreaksTheFloor(
        uint128 principal,
        uint16 premiumBps,
        uint32 costBps,
        uint128 fee
    ) public {
        principal = uint128(bound(principal, 100e6, 4000e6));
        premiumBps = uint16(bound(premiumBps, 1, 3000));
        costBps = uint32(bound(costBps, 1, 4000));
        uint128 cap = principal + uint128(uint256(principal) * premiumBps / 10_000) + 3;
        uint256 id = _list(borrower, address(nvda), 100e18, principal, cap, T21);
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(2, 2);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        p.costBps = costBps;
        bool refused;
        for (uint256 i; i < 2; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            a.minimum = uint128(IntentFeeMath.minimumInterest(a.principal, costBps, a.minRateGrade));
            a.executionFee = uint128(bound(fee, 0, a.interest));
            a.maxReserveShares = uint128(vaults[i].RESERVE().previewWithdraw(uint256(a.principal) + a.executionFee));
            uint256 ceiling = uint256(a.interest) * a.capBps / 10_000;
            if (a.interest < a.minimum || a.executionFee > ceiling || a.interest - a.executionFee < a.minimum) {
                refused = true;
            } else if (
                // The vault's own floor on the registry's cost, which the verifier mirrors (M-86).
                a.interest - a.executionFee < IntentFeeMath.minimumInterest(a.principal, COST_BPS, a.minRateGrade)
            ) {
                refused = true;
            }
        }
        IntentQuoteVerifier.Refusal reason = _reason(p);
        assertEq(reason != IntentQuoteVerifier.Refusal.NONE, refused);
    }

    // ---------------------------------------------------------------- S3-A3: identity, time and single use

    function testAPlanIsUsedOnce() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        _fill(p);
        _assertRefused(p, IntentQuoteVerifier.Refusal.CONSUMED);
    }

    function testAPlanIsRefusedBeforeItsIssueTimeAfterItsExpiryAndWhenItLivesTooLong() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        uint40 issued = p.issuedAt;
        p.issuedAt = issued + 1;
        p.expiry = issued + 60;
        _assertRefused(p, IntentQuoteVerifier.Refusal.NOT_YET_VALID);
        p.issuedAt = issued;
        p.expiry = issued + verifier.MAX_QUOTE_LIFE() + 1;
        _assertRefused(p, IntentQuoteVerifier.Refusal.LIFE_TOO_LONG);
        p.expiry = issued + 90;
        // Dead at its expiry (L-23): the last second it can be used is the one before.
        vm.warp(uint256(issued) + 90);
        _assertRefused(p, IntentQuoteVerifier.Refusal.EXPIRED);
        vm.warp(uint256(issued) + 89);
        _fill(p);
    }

    function testAPlanSignedForAnotherChainOrAnotherVerifierIsRefused() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        IntentQuoteVerifier other = new IntentQuoteVerifier(partnerFactory);
        IntentQuoteVerifier.Refusal elsewhere = IntentPreflight.reason(other, p, signature, p.filler);
        assertEq(uint8(elsewhere), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE), "another verifier");
        vm.chainId(4663);
        IntentQuoteVerifier.Refusal mainnet = IntentPreflight.reason(verifier, p, signature, p.filler);
        assertEq(uint8(mainnet), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE), "another chain");
    }

    function testAnythingAlteredAfterSigningBreaksTheSignature() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        p.allocations[0].executionFee -= 1;
        IntentQuoteVerifier.Refusal fee = IntentPreflight.reason(verifier, p, signature, p.filler);
        assertEq(uint8(fee), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE), "fee");
        p.allocations[0].executionFee += 1;
        p.allocations[0].vault = address(second);
        IntentQuoteVerifier.Refusal vault = IntentPreflight.reason(verifier, p, signature, p.filler);
        assertEq(uint8(vault), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE), "vault");
        p.allocations[0].vault = address(first);
        p.expiry += 1;
        IntentQuoteVerifier.Refusal expiry = IntentPreflight.reason(verifier, p, signature, p.filler);
        assertEq(uint8(expiry), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE), "expiry");
    }

    function testOnlyTheFactorysSignerSignsAndNoSignerOrNoRouterClosesEverything() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        IntentQuoteVerifier.Refusal stranger = IntentPreflight.reason(verifier, p, _signWith(0xBAD, p), p.filler);
        assertEq(uint8(stranger), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE));
        IntentQuoteVerifier.Refusal short_ = IntentPreflight.reason(verifier, p, hex"1234", p.filler);
        assertEq(uint8(short_), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE));
        partnerFactory.setQuoteSigner(address(0));
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.FILLS_CLOSED));
        partnerFactory.setQuoteSigner(signer);
        partnerFactory.setFillRouter(address(0));
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.FILLS_CLOSED));
        // A replaced signer's outstanding plans die with it.
        partnerFactory.setFillRouter(address(quoted));
        partnerFactory.setQuoteSigner(vm.addr(0xBEEF));
        _assertRefused(p, IntentQuoteVerifier.Refusal.BAD_SIGNATURE);
    }

    function testAPlanNamesItsEngineItsFeePolicyAndItsFiller() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        p.engine = address(0xE1);
        _assertRefused(p, IntentQuoteVerifier.Refusal.WRONG_ENGINE);
        p.engine = address(core);
        p.feePolicy += 1;
        _assertRefused(p, IntentQuoteVerifier.Refusal.WRONG_FEE_POLICY);
        p.feePolicy -= 1;
        // Another admitted filler cannot use a plan issued to the first.
        partnerFactory.setFiller(fillers[1], true);
        bytes memory signature = _sign(p);
        IntentQuoteVerifier.Refusal taken = IntentPreflight.reason(verifier, p, signature, fillers[1]);
        assertEq(uint8(taken), uint8(IntentQuoteVerifier.Refusal.WRONG_FILLER));
        vm.prank(fillers[1]);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.WRONG_FILLER)
        );
        quoted.fill(p, signature);
    }

    function testADisabledFillerAPartnerCuratorAndAListingsOwnBorrowerAreRefused() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        partnerFactory.setFiller(fillers[0], false);
        _assertRefused(p, IntentQuoteVerifier.Refusal.FILLER_NOT_ADMITTED);
        // Creating vaults confers no funding authority (D13).
        p.filler = curator;
        _assertRefused(p, IntentQuoteVerifier.Refusal.FILLER_NOT_ADMITTED);
        partnerFactory.setFiller(borrower, true);
        p.filler = borrower;
        _assertRefused(p, IntentQuoteVerifier.Refusal.SELF_DEALING);
    }

    function testAPlanNamesOnlyThisFactorysVaultsEachOnceInAddressOrder() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(2, 2);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        (p.allocations[0], p.allocations[1]) = (p.allocations[1], p.allocations[0]);
        _assertRefused(p, IntentQuoteVerifier.Refusal.VAULTS_NOT_ORDERED);
        p.allocations[0] = p.allocations[1];
        _assertRefused(p, IntentQuoteVerifier.Refusal.VAULTS_NOT_ORDERED);
        p = _plan(id, vaults, counts);
        p.allocations[0].vault = address(partner) < address(first) ? address(0xdead) : address(1);
        _assertRefused(p, IntentQuoteVerifier.Refusal.UNKNOWN_VAULT);
        p.allocations = new IntentQuoteVerifier.Allocation[](0);
        _assertRefused(p, IntentQuoteVerifier.Refusal.EMPTY_PLAN);
    }

    // ---------------------------------------------------------------- S3-A1, S3-A6: the listing as the core holds it

    function testAPlanBindsTheListingAsTheCoreRecordsIt() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        p.collateral += 1;
        _assertRefused(p, IntentQuoteVerifier.Refusal.LISTING_CHANGED);
        p.collateral -= 1;
        p.cap += 1;
        _assertRefused(p, IntentQuoteVerifier.Refusal.LISTING_CHANGED);
        p.cap -= 1;
        p.token = address(meme);
        _assertRefused(p, IntentQuoteVerifier.Refusal.LISTING_CHANGED);
        p.token = address(nvda);
        p.term = T7;
        _assertRefused(p, IntentQuoteVerifier.Refusal.LISTING_CHANGED);
        p.term = T21;
        vm.prank(borrower);
        core.cancelFunding(id);
        _assertRefused(p, IntentQuoteVerifier.Refusal.LISTING_NOT_FUNDING);
    }

    /// @dev The kind is the core's, so a position listing cannot be relabelled as a token. The core here holds token
    /// collateral only, so a position is simulated: a plan that names it truthfully passes the verifier, and the
    /// vault's own asset policy refuses the funding.
    function testAPositionBackedListingIsRefusedAndCannotBeRelabelledAsAToken() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        V2Loan memory l = core.getLoan(id);
        Kind[2] memory kinds = [Kind.UNIV4_POSITION, Kind.UNIV3_POSITION];
        for (uint256 i; i < kinds.length; ++i) {
            l.kind = kinds[i];
            vm.mockCall(address(core), abi.encodeWithSelector(GageV2Vault.getLoan.selector, id), abi.encode(l));
            p.kind = uint8(Kind.ERC20);
            assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.LISTING_CHANGED), "relabelled");
            p.kind = uint8(kinds[i]);
            assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE), "truthful");
            bytes memory signature = _sign(p);
            vm.prank(p.filler);
            vm.expectRevert(IntentVault.IneligibleDeal.selector);
            quoted.fill(p, signature);
        }
    }

    function testAManualLenderTakingAUnitAfterSigningRefusesThePlanAndANewPlanFundsTheRest() public {
        uint256 id = _list(borrower, address(nvda), 100e18, 1_000_000_003, 1_100_000_010, T21);
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory stale = _plan(id, vaults, counts);
        vm.prank(fillers[1]);
        core.fund(id, 1);
        _assertRefused(stale, IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
        (vaults, counts) = _one(first, 3);
        IntentQuoteVerifier.Plan memory fresh = _plan(id, vaults, counts);
        // The first unit carried the extra raw units; the three that are left do not.
        assertEq(fresh.allocations[0].principal, 750_000_002);
        _fill(fresh);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
    }

    function testAPlanMustFundEveryUnitThatIsLeft() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, 3);
        _assertRefused(_plan(id, vaults, counts), IntentQuoteVerifier.Refusal.INCOMPLETE_PLAN);
        (vaults, counts) = _two(2, 1);
        _assertRefused(_plan(id, vaults, counts), IntentQuoteVerifier.Refusal.INCOMPLETE_PLAN);
        (vaults, counts) = _two(3, 2);
        _assertRefused(_plan(id, vaults, counts), IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
        (vaults, counts) = _two(4, 0);
        _assertRefused(_plan(id, vaults, counts), IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
        (vaults, counts) = _two(0, 4);
        _assertRefused(_plan(id, vaults, counts), IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
    }
}
