// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentPreflight} from "./IntentPreflight.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @dev Consumes every plan without a check. Behind it a fill router runs each vault's own `purchase` with nothing in
/// front: the answer the verifier's preflight must mirror.
contract UncheckedVerifier {
    address public immutable FACTORY;
    address public immutable CORE;

    constructor(address factory, address core) {
        FACTORY = factory;
        CORE = core;
    }

    function consume(IntentQuoteVerifier.Plan calldata p, bytes calldata, address) external pure returns (bytes32) {
        return keccak256(abi.encode(p.listingId));
    }

    function consumeSecondary(IntentQuoteVerifier.SecondaryPlan calldata p, bytes calldata, address)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(p.loanId));
    }
}

/// @notice Regression coverage for signed primary reserve ceilings and the live buyer preflight: availability and the
/// collateral grade floor (M-48, M-49, M-52, M-74, M-45's floor raise), collateral admission (M-72), the originator
/// (M-66), the vault's registry floor (M-86) and the exclusive expiry (L-23). Each mirror is checked against the
/// vaults' own purchases on both sides of its boundary.
contract IntentQuotePreflightTest is IntentSecondaryBaseTest {
    function _primary() internal returns (IntentQuoteVerifier.Plan memory) {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, 4);
        return _plan(id, vaults, counts);
    }

    function _grade(uint8 rank) internal {
        address[] memory tokens = new address[](1);
        uint8[] memory ranks = new uint8[](1);
        tokens[0] = address(nvda);
        ranks[0] = rank;
        grades.setGrades(tokens, ranks);
    }

    function _refused(IntentQuoteVerifier.Plan memory p, IntentQuoteVerifier.Refusal expected) internal {
        bytes32 digest = verifier.planHash(p);
        bytes memory signature = _sign(p);
        assertEq(uint8(IntentPreflight.reason(verifier, p, signature, p.filler)), uint8(expected));
        vm.expectRevert(abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, expected));
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(p.allocations.length));
        assertFalse(verifier.consumed(digest));
        assertEq(core.getLoan(p.listingId).filled, 0);
        assertEq(_loanOf(first, p.listingId).principal, 0);
    }

    /// @dev A fill router over an unchecked verifier, named by the factory: only the vaults' own checks remain.
    function _uncheckedRouter() internal returns (IntentFillRouter loose) {
        UncheckedVerifier lax = new UncheckedVerifier(address(partnerFactory), address(core));
        loose = new IntentFillRouter(IntentQuoteVerifier(address(lax)), IERC20(address(usdg)));
        _rebindFillRouter(address(loose));
    }

    /// @dev Whether the vaults' purchases accept `p` with no verifier in front. Nothing is kept.
    function _purchaseAccepts(IntentQuoteVerifier.Plan memory p) internal returns (bool ok) {
        uint256 snapshot = vm.snapshotState();
        IntentFillRouter loose = _uncheckedRouter();
        vm.prank(p.filler);
        (ok,) = address(loose).call(abi.encodeCall(IntentFillRouter.fill, (p, "", _shares(p.allocations.length))));
        vm.revertToStateAndDelete(snapshot);
    }

    function _secondaryPurchaseAccepts(IntentQuoteVerifier.SecondaryPlan memory p) internal returns (bool ok) {
        uint256 snapshot = vm.snapshotState();
        IntentFillRouter loose = _uncheckedRouter();
        vm.prank(p.filler);
        (ok,) = address(loose).call(abi.encodeCall(IntentFillRouter.fillSecondary, (p, "")));
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev The preflight's answer, held to the vaults' own: `NONE` exactly when their purchases go through.
    function _mirrors(IntentQuoteVerifier.Plan memory p) internal returns (IntentQuoteVerifier.Refusal reason) {
        reason = _reason(p);
        assertEq(_purchaseAccepts(p), reason == IntentQuoteVerifier.Refusal.NONE, "preflight mirrors purchase");
    }

    function _mirrorsSecondary(IntentQuoteVerifier.SecondaryPlan memory p)
        internal
        returns (IntentQuoteVerifier.Refusal reason)
    {
        reason = _secondaryReason(p);
        assertEq(_secondaryPurchaseAccepts(p), reason == IntentQuoteVerifier.Refusal.NONE, "preflight mirrors purchase");
    }

    /// @dev A vault whose manager is `who`, with deposits.
    function _vaultCuratedBy(address who, uint256 deposit, bool secondary) internal returns (IntentVault vault) {
        partnerFactory.setCreator(who, true);
        IntentVault.Mandate memory m = mandate;
        m.curator = who;
        m.feeBps = 1000;
        m.minRateGrade = 2;
        m.executionCapBps = BUY_CAP_BPS;
        vm.prank(who);
        vault = IntentVault(partnerFactory.create(m, secondary, EXTRA_BPS, "Test vault"));
        vm.prank(carol);
        usdg.approve(address(vault), MAX);
        vm.prank(carol);
        vault.deposit(deposit, 0);
    }

    function _allowNvda(bool allowed) internal {
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), allowed, Lane.STOCK, 1e18, 1000e18, 100_000e18);
    }

    /// @dev The highest registry cost the vault's floor still admits for an allocation, by the vault's own formula:
    /// what the purchase keeps after its execution fee against the grade's share of that cost.
    function _highestAdmittedCost(IntentQuoteVerifier.Allocation memory a) internal pure returns (uint32 cost) {
        uint256 kept = a.interest - a.executionFee;
        while (IntentFeeMath.minimumInterest(a.principal, cost + 1, a.minRateGrade) <= kept) ++cost;
    }

    function testPrimaryCeilingIsSignedAndFinite() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        bytes memory signature = _sign(p);
        bytes32 digest = verifier.planHash(p);
        ++p.allocations[0].maxReserveShares;
        assertNotEq(verifier.planHash(p), digest);
        assertEq(
            uint8(IntentPreflight.reason(verifier, p, signature, p.filler)),
            uint8(IntentQuoteVerifier.Refusal.BAD_SIGNATURE)
        );
        p.allocations[0].maxReserveShares = type(uint128).max;
        _refused(p, IntentQuoteVerifier.Refusal.RESERVE_BOUND);
        uint256 live =
            first.RESERVE().previewWithdraw(uint256(p.allocations[0].principal) + p.allocations[0].executionFee);
        p.allocations[0].maxReserveShares = uint128(live + live / 100 + 1);
        _refused(p, IntentQuoteVerifier.Refusal.RESERVE_BOUND);
        p.allocations[0].maxReserveShares = uint128(live + live / 100);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
        assertEq(uint8(core.getLoan(p.listingId).state), uint8(V2State.ACTIVE));
    }

    function testReservePurchaseCannotWidenSignedCeilingAndCallerCanTighten() public {
        uint256 cash = first.cash();
        vm.prank(fillers[0]);
        fills.investReserve(address(first), cash, 0);
        IntentQuoteVerifier.Plan memory p = _primary();
        uint128 live = p.allocations[0].maxReserveShares;
        uint256 held = reserve.balanceOf(address(first));
        --p.allocations[0].maxReserveShares;
        bytes memory signature = _sign(p);
        vm.expectRevert(IntentVault.Slippage.selector);
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(1));
        assertFalse(verifier.consumed(verifier.planHash(p)));
        assertEq(reserve.balanceOf(address(first)), held);
        assertEq(core.getLoan(p.listingId).filled, 0);

        p.allocations[0].maxReserveShares = live;
        signature = _sign(p);
        uint256[] memory tighter = new uint256[](1);
        tighter[0] = live - 1;
        vm.expectRevert(IntentVault.Slippage.selector);
        vm.prank(p.filler);
        fills.fill(p, signature, tighter);
        assertFalse(verifier.consumed(verifier.planHash(p)));
        assertEq(reserve.balanceOf(address(first)), held);
        _fill(p);
        assertLe(held - reserve.balanceOf(address(first)), live);
        assertEq(uint8(core.getLoan(p.listingId).state), uint8(V2State.ACTIVE));
    }

    function testSignedZeroCeilingPreservesCashOnlyFunding() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        p.allocations[0].maxReserveShares = 0;
        uint256 held = reserve.balanceOf(address(first));
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
        assertEq(reserve.balanceOf(address(first)), held);
        assertTrue(verifier.consumed(verifier.planHash(p)));
    }

    function testPrimaryPauseAndFillerShutdownRefuseBeforeConsumptionThenRecover() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.prank(curator);
        first.setPaused(true);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        vm.prank(curator);
        first.setPaused(false);
        vm.prank(curator);
        first.setFillersOpen(false);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        vm.prank(curator);
        first.setFillersOpen(true);
        _fill(p);
        assertTrue(verifier.consumed(verifier.planHash(p)));
    }

    function testPrimaryNoHoldersRefusesBeforeConsumption() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        uint256 shares = first.balanceOf(alice);
        vm.prank(alice);
        first.redeem(shares, 0);
        assertEq(first.totalSupply(), 0);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
    }

    function testPrimaryMaturityBoundaryRefusesBeforeConsumption() public {
        _fill(_primary());
        vm.warp(first.earliestMaturity() - 1);
        _modeled(address(nvda), COST_BPS);
        IntentQuoteVerifier.Plan memory p = _primary();
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.warp(first.earliestMaturity());
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
    }

    /// @dev The same availability mirror on the secondary route, held to the buyers' own purchases.
    function testSecondaryPauseFillerShutdownAndNoHoldersMirrorPurchase() public {
        uint256 id = _onSale(1070e6 + 3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.prank(buyerCurator);
        buyerB.setPaused(true);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        vm.prank(buyerCurator);
        buyerB.setPaused(false);
        vm.prank(buyerCurator);
        buyerB.setFillersOpen(false);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        vm.prank(buyerCurator);
        buyerB.setFillersOpen(true);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        uint256 shares = buyerB.balanceOf(carol);
        vm.prank(carol);
        buyerB.redeem(shares, 0);
        assertEq(buyerB.totalSupply(), 0);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        assertFalse(verifier.consumed(verifier.secondaryPlanHash(p)));
    }

    function testPrimaryLiveGradeDowngradeWithdrawalAndFloorChange() public {
        _grade(5);
        IntentQuoteVerifier.Plan memory p = _primary();
        vm.prank(curator);
        first.setMinGrade(5);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        // M-45: the manager raises the floor above the live grade after signing.
        vm.prank(curator);
        first.setMinGrade(6);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        vm.prank(curator);
        first.setMinGrade(5);
        _grade(4);
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        _grade(0);
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        _grade(5);
        _fill(p);
        assertTrue(verifier.consumed(verifier.planHash(p)));
    }

    function testPrimaryGradeExpiresWhilePlanRemainsAlive() public {
        _grade(5);
        vm.prank(curator);
        first.setMinGrade(5);
        vm.warp(block.timestamp + 7 days);
        _modeled(address(nvda), COST_BPS);
        IntentQuoteVerifier.Plan memory p = _primary();
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.warp(block.timestamp + 1);
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
    }

    function testSecondaryLiveGradeDowngradeWithdrawalAndFloorRaiseRefuseThenRecover() public {
        uint256 id = _onSale(1070e6 + 3);
        _grade(5);
        vm.prank(buyerCurator);
        buyerA.setMinGrade(5);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        bytes32 digest = verifier.secondaryPlanHash(p);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        // M-45: the manager raises the floor above the live grade after signing.
        vm.prank(buyerCurator);
        buyerA.setMinGrade(6);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        vm.prank(buyerCurator);
        buyerA.setMinGrade(5);
        _grade(4);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        _grade(0);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        assertFalse(verifier.consumed(digest));
        assertEq(_loanOf(buyerA, id).principal, 0);
        assertEq(sellerMarket.nonces(id), p.nonce);
        _grade(5);
        _buy(p);
        assertTrue(verifier.consumed(digest));
    }

    function testSecondaryGradeExpiresWhilePlanRemainsAlive() public {
        _grade(5);
        vm.warp(block.timestamp + 4 days);
        uint256 id = _onSale(1070e6 + 3); // The fixture advances three further days.
        vm.prank(buyerCurator);
        buyerA.setMinGrade(5);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_secondaryReason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.warp(block.timestamp + 1);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        assertFalse(verifier.consumed(verifier.secondaryPlanHash(p)));
    }

    function testZeroGradeFloorPreservesBothRoutesWithoutPublishedGrade() public {
        _grade(0);
        _fill(_primary());
        uint256 id = _onSale(1070e6 + 3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        _buy(_marketPlan(id, vaults, masks));
        assertGt(_loanOf(buyerA, id).principal, 0);
    }

    // ---------------------------------------------------------------- M-72: collateral admission

    function testPrimaryAssetRemovalRefusesBeforeConsumption() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        // The manager drops the token after signing; a removal applies at once.
        vm.prank(curator);
        first.setAsset(address(nvda), false);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        // A vault that still picks it funds the same listing.
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(second, 4);
        IntentQuoteVerifier.Plan memory other = _plan(p.listingId, vaults, counts);
        assertEq(uint8(_mirrors(other)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(other);
    }

    function testPrimaryRegistryDisableRefusesThenRecovers() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        _allowNvda(false);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _refused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        _allowNvda(true);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
        assertTrue(verifier.consumed(verifier.planHash(p)));
    }

    function testSecondaryAssetRemovalRefusesBeforeConsumption() public {
        uint256 id = _onSale(1070e6 + 3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.prank(buyerCurator);
        buyerB.setAsset(address(nvda), false);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        assertFalse(verifier.consumed(verifier.secondaryPlanHash(p)));
        assertEq(sellerMarket.nonces(id), p.nonce);
    }

    function testSecondaryRegistryDisableRefusesThenRecovers() public {
        uint256 id = _onSale(1070e6 + 3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        _allowNvda(false);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE);
        _allowNvda(true);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _buy(p);
        assertTrue(verifier.consumed(verifier.secondaryPlanHash(p)));
    }

    // ---------------------------------------------------------------- M-66: the originator

    function testPrimaryVaultManagedByTheBorrowerIsRefused() public {
        IntentVault own = _vaultCuratedBy(borrower, 10_000e6, false);
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(own, 4);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.SELF_DEALING));
        _refused(p, IntentQuoteVerifier.Refusal.SELF_DEALING);
        // A vault of another manager funds it.
        (vaults, counts) = _one(first, 4);
        p = _plan(id, vaults, counts);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
    }

    /// @dev The core's record of `id`, as both the verifier and the vault's policy read it, with another originator.
    function _originatedBy(uint256 id, address originator) internal {
        V2Loan memory l = core.getLoan(id);
        l.originator = originator;
        vm.mockCall(address(core), abi.encodeCall(GageV2Vault.getLoan, (id)), abi.encode(l));
    }

    /// @dev No vault originates a loan today: the core safe-mints the borrower's right, which a vault does not accept.
    /// Its policy refuses one all the same, and so does the mirror; the core's record is mocked to show both.
    function testPrimaryVaultAsOriginatorIsRefused() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        _originatedBy(p.listingId, address(first));
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.SELF_DEALING));
        _refused(p, IntentQuoteVerifier.Refusal.SELF_DEALING);
        vm.clearMockedCalls();
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
    }

    function testSecondaryBuyerAsOriginatorIsRefused() public {
        uint256 id = _onSale(1070e6 + 3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        _originatedBy(id, address(buyerC));
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.SELF_DEALING));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.SELF_DEALING);
        vm.clearMockedCalls();
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _buy(p);
    }

    function testSecondaryBuyerManagedByTheBorrowerIsRefused() public {
        uint256 id = _onSale(1070e6 + 3);
        IntentVault own = _vaultCuratedBy(borrower, 300e6, true);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        vaults[2] = own;
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.SELF_DEALING));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.SELF_DEALING);
        (vaults, masks) = _twoOneOne();
        p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_mirrorsSecondary(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _buy(p);
    }

    // ---------------------------------------------------------------- M-86: the vault's registry floor

    function testRegistryCostRaisedThenRestoredOrLowered() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        _modeled(address(nvda), 1400);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR));
        _refused(p, IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR);
        _modeled(address(nvda), 1);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE), "a lower cost still funds");
        _modeled(address(nvda), COST_BPS);
        _fill(p);
        assertTrue(verifier.consumed(verifier.planHash(p)));
    }

    function testRegistryCostExpiringWhilePlanRemainsAliveRefuses() public {
        vm.warp(block.timestamp + grades.MAX_AGE() - 30);
        IntentQuoteVerifier.Plan memory p = _primary();
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.warp(block.timestamp + 31);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NO_MODELED_COST));
        _refused(p, IntentQuoteVerifier.Refusal.NO_MODELED_COST);
        _modeled(address(nvda), COST_BPS);
        _fill(p);
    }

    /// @dev The mirror and the vault agree to the basis point: the highest admitted cost funds, one more is refused.
    function testRegistryFloorBoundaryAgreesWithPurchase() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        uint32 highest = _highestAdmittedCost(p.allocations[0]);
        assertGt(highest, COST_BPS);
        _modeled(address(nvda), highest + 1);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR));
        _refused(p, IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR);
        _modeled(address(nvda), highest);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
    }

    /// @dev A vault without a rate grade has no registry floor, on chain or in the mirror.
    function testNoRateGradeNeedsNoRegistryCost() public {
        IntentVault ungraded = _vault(1000, 0);
        vm.warp(block.timestamp + grades.MAX_AGE() + 1);
        assertEq(grades.modeledCostOf(address(nvda), T21), 0);
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(ungraded, 4);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(uint8(_mirrors(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _fill(p);
    }

    function testFuzz_RegistryFloorPreflightMirrorsPurchase(uint32 registryBps, uint128 fee, bool strict) public {
        IntentVault vault = strict == (first.minRateGrade() == 3) ? first : second;
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(vault, 4);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        IntentQuoteVerifier.Allocation memory a = p.allocations[0];
        (, uint256 most) = IntentFeeMath.executionFee(a.interest, a.minimum, a.capBps);
        a.executionFee = uint128(bound(fee, 0, most));
        a.maxReserveShares = uint128(vault.RESERVE().previewWithdraw(uint256(a.principal) + a.executionFee));
        _modeled(address(nvda), uint32(bound(registryBps, 1, 3000)));
        IntentQuoteVerifier.Refusal reason = _mirrors(p);
        assertTrue(
            reason == IntentQuoteVerifier.Refusal.NONE || reason == IntentQuoteVerifier.Refusal.BELOW_RETURN_FLOOR
        );
    }

    // ---------------------------------------------------------------- L-23: a plan is dead at its expiry

    function testPrimaryExpiryIsExclusive() public {
        IntentQuoteVerifier.Plan memory p = _primary();
        vm.warp(uint256(p.expiry) - 1);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.warp(p.expiry);
        _refused(p, IntentQuoteVerifier.Refusal.EXPIRED);
    }

    function testSecondaryExpiryIsExclusive() public {
        uint256 id = _onSale(1070e6 + 3);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        vm.warp(uint256(p.expiry) - 1);
        assertEq(uint8(_secondaryReason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        vm.warp(p.expiry);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.EXPIRED);
        assertFalse(verifier.consumed(verifier.secondaryPlanHash(p)));
    }
}
