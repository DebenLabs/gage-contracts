// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {IntentPreflight} from "./IntentPreflight.sol";

/// @notice S9-04: a signed secondary plan binds every term it names, every allocation stands on its own, and a plan
/// that fails any check moves nothing (SEC-05, SEC-24, SEC-25).
contract IntentSecondaryPlansTest is IntentSecondaryBaseTest {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), an asking price of about 1,067 after the 1% trade fee and the seller's manager fee; the odd
    /// units exercise the per-quarter remainder rule.
    uint128 internal constant PRICE = 1070e6 + 3;

    function _valid() internal returns (IntentQuoteVerifier.SecondaryPlan memory p) {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_secondaryReason(p)), uint8(IntentQuoteVerifier.Refusal.NONE), "fixture plan is valid");
    }

    // ---------------------------------------------------------------- authorization and domain

    function test_signatureLifeEpochAndFillerAreBound() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        // Another key.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, verifier.secondaryPlanHash(p));
        vm.prank(p.filler);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BAD_SIGNATURE)
        );
        fills.fillSecondary(p, abi.encodePacked(r, s, v));
        // Another filler named, or an unadmitted one.
        p.filler = fillers[1];
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.FILLER_NOT_ADMITTED);
        p.filler = fillers[0];
        // Life and time.
        p.issuedAt = uint40(block.timestamp + 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.NOT_YET_VALID);
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 5 minutes + 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.LIFE_TOO_LONG);
        p.expiry = uint40(block.timestamp + 90);
        // Revocation of all outstanding plans, primary and secondary alike.
        verifier.revokeAll();
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.EPOCH_REVOKED);
        p.epoch = verifier.epoch();
        // Revocation of one digest.
        verifier.revoke(verifier.secondaryPlanHash(p));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.CONSUMED);
    }

    function test_expiredPlanAndStaleValuationFail() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        vm.warp(block.timestamp + 91);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.EXPIRED);
        p = _valid();
        p.valuedAt = uint40(block.timestamp - 4 minutes);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.STALE_EVIDENCE);
        p.valuedAt = uint40(block.timestamp + 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.STALE_EVIDENCE);
        p.valuedAt = uint40(block.timestamp);
        p.modelAnnualBps = 0;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.NO_MODELED_COST);
        p = _valid();
        p.policyVersion = 2;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.WRONG_FEE_POLICY);
    }

    function test_aSecondarySignatureIsWorthNothingElsewhere() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        bytes memory signature = _signSecondary(p);
        bytes32 digest = verifier.secondaryPlanHash(p);
        // Another loan, another engine, another chain: each is a different digest the signature does not cover.
        p.loanId += 1;
        assertTrue(verifier.secondaryPlanHash(p) != digest);
        p.loanId -= 1;
        p.engine = address(0xE1);
        IntentQuoteVerifier.Refusal reason = IntentPreflight.secondaryReason(verifier, p, signature, p.filler);
        assertEq(uint8(reason), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE));
        p.engine = address(core);
        vm.chainId(block.chainid + 1);
        reason = IntentPreflight.secondaryReason(verifier, p, signature, p.filler);
        assertEq(uint8(reason), uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE));
        vm.chainId(block.chainid - 1);
        reason = IntentPreflight.secondaryReason(verifier, p, signature, p.filler);
        assertEq(uint8(reason), uint8(IntentQuoteVerifier.Refusal.NONE));
        // A primary plan's type hash is not a secondary plan's.
        assertTrue(verifier.PLAN_TYPEHASH() != verifier.SECONDARY_PLAN_TYPEHASH());
    }

    function test_everySignedTermChangesTheDigest() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        bytes32 digest = verifier.secondaryPlanHash(p);
        IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[1];
        a.maxReserveShares += 1;
        assertTrue(verifier.secondaryPlanHash(p) != digest, "reserve bound");
        a.maxReserveShares -= 1;
        a.policyRevision += 1;
        assertTrue(verifier.secondaryPlanHash(p) != digest, "policy revision");
        a.policyRevision -= 1;
        p.minRewards[2] += 1;
        assertTrue(verifier.secondaryPlanHash(p) != digest, "reward floor");
        p.minRewards[2] -= 1;
        p.evidence = bytes32(uint256(p.evidence) ^ 1);
        assertTrue(verifier.secondaryPlanHash(p) != digest, "evidence");
        p.evidence = bytes32(uint256(p.evidence) ^ 1);
        assertEq(verifier.secondaryPlanHash(p), digest);
    }

    /// The rate service reads both before it quotes a secondary plan (services/valuation/src/rates/intent/
    /// secondary.ts); a verifier that lost either view would stop every secondary quote.
    function test_theRateServiceCapabilityReadsAnswer() public view {
        assertTrue(verifier.LENDER_SPLIT());
        assertEq(verifier.SECONDARY_POLICY_VERSION(), 1);
    }

    /// An engine without the split sale cannot deliver one bundle to several vaults. A verifier over it answers
    /// `LENDER_SPLIT` false, which the rate service reads before it quotes, and refuses every secondary plan up front
    /// (`UNSUPPORTED_ENGINE`), before any vault pays, instead of letting the purchase revert at the sale.
    function test_anEngineWithoutSplitDeliveryIsRefusedUpFront() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        // The engine lacks `buyLenderSplit`: a call to it reverts with no data, as a call to a missing function does.
        vm.mockCallRevert(address(core), abi.encodeWithSelector(GageV2Vault.buyLenderSplit.selector), "");
        IntentQuoteVerifier legacy = new IntentQuoteVerifier(IntentFactory(address(partnerFactory)));
        assertFalse(legacy.LENDER_SPLIT(), "no split sale");
        assertTrue(verifier.LENDER_SPLIT(), "the fixture's engine has one");
        IntentFillRouter legacyFills = new IntentFillRouter(legacy, IERC20(address(usdg)));
        _rebindFillRouter(address(legacyFills));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, legacy.secondaryPlanHash(p));
        bytes memory signature = abi.encodePacked(r, s, v);
        IntentQuoteVerifier.Refusal reason = IntentPreflight.secondaryReason(legacy, p, signature, p.filler);
        assertEq(uint8(reason), uint8(IntentQuoteVerifier.Refusal.UNSUPPORTED_ENGINE));
        uint256 assets = buyerA.totalAssets();
        vm.prank(p.filler);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.UNSUPPORTED_ENGINE)
        );
        legacyFills.fillSecondary(p, signature);
        assertEq(buyerA.totalAssets(), assets, "no vault paid");
    }

    /// Only the split sale's own refusal of an ask that does not exist marks an engine able to split: a probe that
    /// succeeds, or fails any other way, does not.
    function test_theSplitProbeReadsOnlyTheSplitSalesOwnRefusal() public {
        bytes memory probe = abi.encodeWithSelector(GageV2Vault.buyLenderSplit.selector);
        IntentFactory factory = IntentFactory(address(partnerFactory));
        vm.mockCall(address(core), probe, "");
        assertFalse(new IntentQuoteVerifier(factory).LENDER_SPLIT(), "a probe that succeeds");
        vm.clearMockedCalls();
        vm.mockCallRevert(address(core), probe, abi.encodeWithSelector(GageV2Vault.WrongState.selector));
        assertFalse(new IntentQuoteVerifier(factory).LENDER_SPLIT(), "another refusal");
        vm.clearMockedCalls();
        assertTrue(new IntentQuoteVerifier(factory).LENDER_SPLIT(), "the core's own split sale");
    }

    // ---------------------------------------------------------------- listing and loan

    function test_listingAndLoanMustBeExactlyAsSigned() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        p.price += 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ASK_CHANGED);
        p = _valid();
        p.nonce += 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ASK_CHANGED);
        p = _valid();
        p.cap += 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.LISTING_CHANGED);
        p = _valid();
        p.expiry = p.maturity + 1;
        p.issuedAt = p.maturity - 2 minutes;
        vm.warp(p.issuedAt);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.LOAN_NOT_ACTIVE);
    }

    /// The plan's signed `maxFeeBps` bounds the trade fee the sale charges, as the ask's own bound does. The fee is the
    /// registry's at the purchase: the sale snapshots it into the core ask it posts in the same transaction. A plan
    /// signed under a lower bound than that fee is refused before any vault pays (r1 held the signed bound against a
    /// wallet's core ask only).
    function test_theTradeFeeMustBeWithinThePlansSignedBound() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        assertEq(core.REGISTRY().tradeFeeBps(), 100);
        p.maxFeeBps = 99;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ASK_CHANGED);
        // The seller accepts up to 2% and the plan is signed at 1%: a fee raised after signing stays within the
        // seller's bound but not the plan's.
        uint256 id = p.loanId;
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        sellerMarket.list(id, PRICE, deadline, 200);
        p = _marketPlan(id, _vaultsOf(p), _masksOf(p));
        assertEq(p.maxFeeBps, 100, "signed at the fee of the moment");
        vm.prank(safe);
        registry.setTradeFee(101);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ASK_CHANGED);
        // At the signed bound the same plan buys, and the sale charges exactly that fee, once.
        vm.prank(safe);
        registry.setTradeFee(100);
        uint256 credit = core.cashCredit(treasury);
        _buy(p);
        assertEq(core.cashCredit(treasury) - credit, uint256(PRICE) * 100 / 10_000);
    }

    function test_aVaultSellsOnlyThroughItsOwnMarket() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        p.market = address(0);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MARKET_MISMATCH);
        p = _valid();
        p.market = address(buyerC.LENDER_MARKET());
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MARKET_MISMATCH);
        p = _valid();
        vm.prank(curator);
        seller.setPaused(true);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.SELLER_UNAVAILABLE);
    }

    // ---------------------------------------------------------------- allocations

    function test_masksMustBeDisjointNonemptyAndCoverTheListingExactly() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        uint8 original = p.allocations[1].slots;
        // Overlap.
        p.allocations[1].slots = original | p.allocations[0].slots;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MASKS_INVALID);
        // Empty.
        p.allocations[1].slots = 0;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MASKS_INVALID);
        p.allocations[1].slots = original;
        // Missing a quarter: drop the last allocation.
        IntentQuoteVerifier.SecondaryAllocation[] memory two = new IntentQuoteVerifier.SecondaryAllocation[](2);
        two[0] = p.allocations[0];
        two[1] = p.allocations[1];
        IntentQuoteVerifier.SecondaryAllocation[] memory all = p.allocations;
        p.allocations = two;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MASKS_INVALID);
        p.allocations = all;
        // A quarter outside the listing.
        p.slots = 7;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ASK_CHANGED);
        p = _valid();
        p.allocations = new IntentQuoteVerifier.SecondaryAllocation[](0);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.EMPTY_PLAN);
    }

    function test_oneEntryPerVaultInAscendingOrderAndNeverTheSeller() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        (p.allocations[0], p.allocations[1]) = (p.allocations[1], p.allocations[0]);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.VAULTS_NOT_ORDERED);
        p = _valid();
        p.allocations[1].vault = p.allocations[0].vault;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.VAULTS_NOT_ORDERED);
        p = _valid();
        p.allocations[2].vault = address(type(uint160).max);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.UNKNOWN_VAULT);
    }

    function test_theSolverCannotShiftPriceOrRightsBetweenVaults() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        // Same total, one raw unit moved from one vault's price to another's.
        p.allocations[0].price += 1;
        p.allocations[1].price -= 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
        p = _valid();
        p.allocations[0].repayment += 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
    }

    /// @dev A listing priced below its quarter count: 3 raw units over four quarters split 1, 1, 1, 0, so the vault
    /// taking quarter 3 alone would pay nothing. The vault reads a zero price as a funding purchase, which an active
    /// loan never is, so the verifier refuses the plan instead of approving one that can never execute.
    function test_anAllocationPricedAtZeroIsRefused() public {
        uint256 id = _onSale(3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint256 zero;
        for (uint256 i; i < p.allocations.length; ++i) {
            if (p.allocations[i].price == 0) {
                assertEq(p.allocations[i].slots, 8, "only quarter 3 is priced zero");
                ++zero;
            }
        }
        assertEq(zero, 1, "one allocation is priced zero");
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
    }

    function test_eachVaultStandsOnItsOwnFloorAndCeiling() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        // One vault's fee one raw unit over its own ceiling, even with another's fee lowered to make room.
        p.allocations[0].executionFee += 1;
        p.allocations[1].executionFee -= 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.FEE_ABOVE_CEILING);
        p = _valid();
        p.allocations[2].minimum -= 1;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MINIMUM_MISMATCH);
        // A model requirement above what the quarters return beyond their price refuses the plan outright, whatever
        // fee any vault would have waived.
        p = _valid();
        modelBps = 20_000;
        p = _marketPlan(p.loanId, _vaultsOf(p), _masksOf(p));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR);
        modelBps = MODEL_BPS;
    }

    function test_termsTheVaultChangedAfterSigningRefuse() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        IntentVault v = IntentVault(p.allocations[0].vault);
        vm.prank(buyerCurator);
        v.setExecutionCap(BUY_CAP_BPS - 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MANDATE_CHANGED);
        p = _valid();
        v = IntentVault(p.allocations[2].vault);
        vm.prank(buyerCurator);
        v.setPaused(true);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
    }

    function test_reserveBoundsAreFiniteAndNearTheLiveRate() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        p.allocations[0].maxReserveShares = type(uint128).max;
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.RESERVE_BOUND);
        p = _valid();
        uint256 live = p.allocations[1].maxReserveShares;
        p.allocations[1].maxReserveShares = uint128(live + live / 100 + 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.RESERVE_BOUND);
        p.allocations[1].maxReserveShares = uint128(live + live / 100);
        assertEq(uint8(_secondaryReason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
    }

    function _vaultsOf(IntentQuoteVerifier.SecondaryPlan memory p) internal pure returns (IntentVault[] memory v) {
        v = new IntentVault[](p.allocations.length);
        for (uint256 i; i < v.length; ++i) {
            v[i] = IntentVault(p.allocations[i].vault);
        }
    }

    function _masksOf(IntentQuoteVerifier.SecondaryPlan memory p) internal pure returns (uint8[] memory m) {
        m = new uint8[](p.allocations.length);
        for (uint256 i; i < m.length; ++i) {
            m[i] = p.allocations[i].slots;
        }
    }

    // ---------------------------------------------------------------- the digest the service signs

    /// @dev The vector the quote service's tests hash too (docs/intent-v1/evidence/s9-secondary-plan-vector.json): fixed
    /// chain, fixed verifier address, fixed plan. A change to the schema changes this digest on both sides.
    function testTheGoldenSecondaryPlanHashesToThePublishedDigest() public {
        address fixedVerifier = 0x00000000000000000000000000000000000e1F1E;
        vm.etch(fixedVerifier, address(verifier).code);
        vm.chainId(46_630);
        IntentQuoteVerifier.SecondaryPlan memory p;
        p.engine = 0x1111111111111111111111111111111111111111;
        p.loanId = 42;
        p.seller = 0x2222222222222222222222222222222222222222;
        p.market = 0x3333333333333333333333333333333333333333;
        p.slots = 15;
        p.price = 1_040_000_003;
        p.nonce = 3;
        p.maxFeeBps = 100;
        p.filler = 0x4444444444444444444444444444444444444444;
        p.token = 0x5555555555555555555555555555555555555555;
        p.collateral = 100e18;
        p.principal = 1_000_000_003;
        p.cap = 1_100_000_010;
        p.maturity = 1_791_555_200;
        p.modelAnnualBps = 1000;
        p.policyVersion = 1;
        p.epoch = 7;
        p.valuedAt = 1_790_000_000;
        p.issuedAt = 1_790_000_000;
        p.expiry = 1_790_000_090;
        p.evidence = keccak256("s9 golden evidence");
        p.minRewards = [uint128(1), 2, 3, 4];
        p.allocations = new IntentQuoteVerifier.SecondaryAllocation[](3);
        p.allocations[0] = IntentQuoteVerifier.SecondaryAllocation(
            0x6666666666666666666666666666666666666666,
            5,
            520_000_002,
            550_000_006,
            3_333_334,
            5_999_999,
            1e18,
            1,
            300,
            2000,
            1000
        );
        p.allocations[1] = IntentQuoteVerifier.SecondaryAllocation(
            0x7777777777777777777777777777777777777777,
            2,
            260_000_001,
            275_000_002,
            1_666_667,
            2_999_999,
            0,
            2,
            0,
            2000,
            1500
        );
        p.allocations[2] = IntentQuoteVerifier.SecondaryAllocation(
            0x8888888888888888888888888888888888888888,
            8,
            260_000_000,
            275_000_002,
            1_666_667,
            3_000_000,
            7,
            1,
            10_000,
            5000,
            500
        );
        bytes32 digest = IntentQuoteVerifier(fixedVerifier).secondaryPlanHash(p);
        emit log_named_bytes32("golden secondary", digest);
        assertEq(
            digest,
            vm.parseJsonBytes32(vm.readFile("../docs/intent-v1/evidence/s9-secondary-plan-vector.json"), ".digest")
        );
    }

    /// @dev Recomputed from the published type strings, independently of the contract's own hashing.
    function testTheSecondaryDigestIsTheEip712HashOfThePublishedTypes() public {
        IntentQuoteVerifier.SecondaryPlan memory p = _valid();
        bytes32[] memory parts = new bytes32[](p.allocations.length);
        for (uint256 i; i < parts.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            parts[i] = keccak256(
                abi.encode(
                    keccak256(
                        "SecondaryAllocation(address vault,uint8 slots,uint128 price,uint128 repayment,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint64 policyRevision,uint16 extraBps,uint16 capBps,uint16 managerBps)"
                    ),
                    a.vault,
                    a.slots,
                    a.price,
                    a.repayment,
                    a.minimum,
                    a.executionFee,
                    a.maxReserveShares,
                    a.policyRevision,
                    a.extraBps,
                    a.capBps,
                    a.managerBps
                )
            );
        }
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    verifier.SECONDARY_PLAN_TYPEHASH(),
                    p.engine,
                    p.loanId,
                    p.seller,
                    p.market,
                    p.slots,
                    p.price,
                    p.nonce,
                    p.maxFeeBps,
                    p.filler,
                    p.token,
                    p.collateral
                ),
                abi.encode(
                    p.principal,
                    p.cap,
                    p.maturity,
                    p.modelAnnualBps,
                    p.policyVersion,
                    p.epoch,
                    p.valuedAt,
                    p.issuedAt,
                    p.expiry,
                    p.evidence,
                    keccak256(abi.encodePacked(p.minRewards)),
                    keccak256(abi.encodePacked(parts))
                )
            )
        );
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            verifier.eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        assertEq(verifier.secondaryPlanHash(p), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
