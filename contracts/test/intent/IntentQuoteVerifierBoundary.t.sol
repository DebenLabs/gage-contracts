// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {IntentDemoPlanRouter} from "../../src/testnet/IntentDemoPlanRouter.sol";
import {TestnetOnly} from "../../src/testnet/TestnetOnly.sol";

import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";

/// @notice S3: signed funding plans, continued: invalidation, the S4 boundary and the digest the service signs.
/// @dev Split from `IntentQuoteVerifier.t.sol` when the fourth category (D41) took the whole suite past the IR
/// optimizer's stack limit in one contract; the cases are unchanged. Fixture values, not launch settings.
contract IntentQuoteVerifierBoundaryTest is IntentPlanBaseTest {
    // ---------------------------------------------------------------- invalidation

    function testACuratorTighteningTheRateGradeRefusesOutstandingPlans() public {
        IntentVault loose = first.minRateGrade() == 2 ? first : second;
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(loose, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        IntentLimits.setMinRateGrade(loose, 3);
        _assertRefused(p, IntentQuoteVerifier.Refusal.MANDATE_CHANGED);
        _fill(_plan(id, vaults, counts));
    }

    function testAManagerMovingTheExecutionCeilingRefusesOutstandingPlans() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        // Up or down, a plan signed under another ceiling is refused; one signed under the new ceiling fills.
        _moveCeiling(first, CAP_BPS + 1);
        _assertRefused(p, IntentQuoteVerifier.Refusal.MANDATE_CHANGED);
        _moveCeiling(first, CAP_BPS - 1);
        _assertRefused(p, IntentQuoteVerifier.Refusal.MANDATE_CHANGED);
        _fill(_plan(id, vaults, counts));
    }

    function _moveCeiling(IntentVault vault, uint16 bps) internal {
        vm.prank(curator);
        vault.setExecutionCap(bps);
    }

    function testTheOwnerOrTheSignerRevokesOnePlanOrAllOfThem() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes32 digest = verifier.planHash(p);
        vm.prank(curator);
        vm.expectRevert(IntentQuoteVerifier.NotAuthority.selector);
        verifier.revoke(digest);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentQuoteVerifier.NotAuthority.selector);
        verifier.revokeAll();
        vm.expectEmit(address(verifier));
        emit IntentQuoteVerifier.Revoked(digest);
        vm.prank(signer);
        verifier.revoke(digest);
        _assertRefused(p, IntentQuoteVerifier.Refusal.CONSUMED);

        IntentQuoteVerifier.Plan memory q = _plan(id, vaults, counts);
        q.expiry += 1;
        vm.expectEmit(address(verifier));
        emit IntentQuoteVerifier.EpochAdvanced(1);
        verifier.revokeAll();
        _assertRefused(q, IntentQuoteVerifier.Refusal.EPOCH_REVOKED);
        q.epoch = 1;
        _fill(q);
    }

    // ---------------------------------------------------------------- the S4 boundary

    /// @dev The router these tests fund through is the testnet fixture of the public S3 demonstration, not S4's.
    function testTheDemonstrationRouterCannotExistOnMainnet() public {
        vm.chainId(4663);
        vm.expectRevert(TestnetOnly.MainnetForbidden.selector);
        new IntentDemoPlanRouter(verifier);
    }

    function testOnlyTheFactorysRouterConsumes() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
        verifier.consume(p, signature, fillers[0]);
        vm.prank(signer);
        vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
        verifier.consume(p, signature, fillers[0]);
    }

    function testAFailedFundingConsumesNothing() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        vm.prank(curator);
        first.setPaused(true);
        vm.prank(fillers[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE)
        );
        quoted.fill(p, signature);
        assertFalse(verifier.consumed(verifier.planHash(p)));
        vm.prank(curator);
        first.setPaused(false);
        _fill(p);
    }

    /// @dev R2-A4: two plans, each valid when signed, together past the vault's limit per asset. The limit is the
    /// vault's, counted when it funds, so the second funding fails whole and its plan is not used up.
    function testTwoOutstandingPlansCannotTogetherPassAVaultsLimit() public {
        IntentLimits.setLimits(first, 1_000_000e6, 1500, 0);
        uint256 a = _listing();
        uint256 b = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory one = _plan(a, vaults, counts);
        IntentQuoteVerifier.Plan memory two = _plan(b, vaults, counts);
        assertEq(uint8(_reason(one)), uint8(IntentQuoteVerifier.Refusal.NONE));
        assertEq(uint8(_reason(two)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(one);
        bytes memory signature = _sign(two);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        quoted.fill(two, signature);
        assertFalse(verifier.consumed(verifier.planHash(two)));
        assertEq(uint8(core.getLoan(b).state), uint8(V2State.FUNDING));
    }

    /// @dev The vault checks its own ceiling and floor whoever signed: a router that skipped the verifier gains nothing.
    function testTheVaultHoldsItsOwnCeilingAndFloorWithoutTheVerifier() public {
        _rebindFillRouter(address(router));
        uint256 id = _listing();
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        router.fund(first, id, UNITS, 20e6 + 1);
        IntentVault strict = first.minRateGrade() == 3 ? first : second;
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(strict, id, UNITS, 10e6 + 1);
    }

    // ---------------------------------------------------------------- the digest the service signs

    /// @dev The policy versions a signed plan names are the verifier's; the arithmetic vectors the quote service
    /// replays name the same ones.
    function testThePolicyVersionsAreTheOnesTheArithmeticVectorsWereGeneratedFor() public view {
        string memory primary = vm.readFile("../docs/intent-v1/evidence/s3-fee-vectors.json");
        assertEq(vm.parseJsonUint(primary, ".feePolicyVersion"), verifier.FEE_POLICY_VERSION());
        string memory secondary = vm.readFile("../docs/intent-v1/evidence/s9-secondary-vectors.json");
        assertEq(vm.parseJsonUint(secondary, ".secondaryPolicyVersion"), verifier.SECONDARY_POLICY_VERSION());
    }

    /// @dev The vector the quote service's tests sign and hash too (docs/intent-v1/evidence/s3-plan-v2-vector.json):
    /// fixed chain, fixed verifier address, fixed plan. A change to the schema changes this digest on both sides.
    function testTheGoldenPlanVectorHashesToThePublishedDigest() public {
        address fixedVerifier = 0x00000000000000000000000000000000000e1F1E;
        vm.etch(fixedVerifier, address(verifier).code);
        vm.chainId(46_630);
        IntentQuoteVerifier.Plan memory p;
        p.engine = 0x1111111111111111111111111111111111111111;
        p.listingId = 42;
        p.filler = 0x2222222222222222222222222222222222222222;
        p.token = 0x3333333333333333333333333333333333333333;
        p.kind = 0;
        p.collateral = 100e18;
        p.principal = 1_000_000_003;
        p.cap = 1_100_000_010;
        p.term = 1_814_400;
        p.costBps = 1000;
        p.feePolicy = 1;
        p.epoch = 7;
        p.issuedAt = 1_790_000_000;
        p.expiry = 1_790_000_090;
        p.evidence = keccak256("s3 golden evidence");
        p.allocations = new IntentQuoteVerifier.Allocation[](2);
        p.allocations[0] = IntentQuoteVerifier.Allocation({
            vault: 0x4444444444444444444444444444444444444444,
            units: 1,
            principal: 250_000_001,
            interest: 25_000_002,
            minimum: 18_750_001,
            executionFee: 5_000_000,
            maxReserveShares: 255_000_001,
            minRateGrade: 2,
            capBps: 2000,
            managerBps: 1000
        });
        p.allocations[1] = IntentQuoteVerifier.Allocation({
            vault: 0x5555555555555555555555555555555555555555,
            units: 3,
            principal: 750_000_002,
            interest: 75_000_005,
            minimum: 67_500_001,
            executionFee: 7_500_004,
            maxReserveShares: 757_500_006,
            minRateGrade: 3,
            capBps: 2000,
            managerBps: 1500
        });
        bytes32 digest = IntentQuoteVerifier(fixedVerifier).planHash(p);
        emit log_named_bytes32("golden", digest);
        assertEq(digest, GOLDEN_DIGEST);
    }

    /// @dev Recomputed from the type strings, independently of the contract's own hashing.
    function testThePlanDigestIsTheEip712HashOfThePublishedTypes() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes32 allocationType = keccak256(
            "Allocation(address vault,uint8 units,uint128 principal,uint128 interest,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint8 minRateGrade,uint16 capBps,uint16 managerBps)"
        );
        assertEq(allocationType, verifier.ALLOCATION_TYPEHASH());
        bytes32[] memory parts = new bytes32[](2);
        for (uint256 i; i < 2; ++i) {
            parts[i] = keccak256(abi.encode(allocationType, p.allocations[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                verifier.PLAN_TYPEHASH(),
                p.engine,
                p.listingId,
                p.filler,
                p.token,
                p.kind,
                p.collateral,
                p.principal,
                p.cap,
                p.term,
                p.costBps,
                p.feePolicy,
                p.epoch,
                p.issuedAt,
                p.expiry,
                p.evidence,
                keccak256(abi.encodePacked(parts))
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("gage Intent quotes"),
                keccak256("1"),
                block.chainid,
                address(verifier)
            )
        );
        assertEq(verifier.planHash(p), keccak256(abi.encodePacked(hex"1901", domain, structHash)));
    }
}
