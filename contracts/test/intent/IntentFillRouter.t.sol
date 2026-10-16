// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {MockFeeProcessor} from "../mocks/MockFeeProcessor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @dev A verifier that accepts anything, for the two cases the real one can never let through: a plan that does
/// not complete its listing, and an engine with more lender units than four.
contract AcceptingVerifier {
    address public immutable FACTORY;
    address public immutable CORE;

    constructor(address factory, address core) {
        FACTORY = factory;
        CORE = core;
    }

    function consume(IntentQuoteVerifier.Plan calldata, bytes calldata, address) external pure returns (bytes32) {
        return keccak256("accepted");
    }
}

/// @dev S4-A5 fixture: a vault of an engine with finer units. It pays the fee it was told to, nothing else.
contract FineUnitVault {
    IERC20 internal immutable USDG;
    uint256 public owedFee;
    uint256 public settles;

    constructor(IERC20 usdg) {
        USDG = usdg;
    }

    function purchase(uint256, uint8, uint256, uint256, uint256 executionFee) external {
        owedFee += executionFee;
    }

    function settle(uint256[] calldata) external {
        ++settles;
    }

    function collectExecutionFees() external returns (uint256 amount) {
        amount = owedFee;
        owedFee = 0;
        USDG.transfer(msg.sender, amount);
    }
}

contract FineUnitCore {
    function getLoan(uint256) external view returns (V2Loan memory l) {
        l.state = V2State.ACTIVE;
        l.fundedAt = uint40(block.timestamp);
    }
}

contract FineUnitFactory {
    address public protocolRecipient = address(0xF100);
}

/// @notice S4: one transaction funds a whole listing from several vaults and settles every execution fee, or nothing.
contract IntentFillRouterTest is IntentPlanBaseTest {
    IntentFillRouter internal fills;
    IntentVault internal third;

    function _deployRouter() internal override returns (address) {
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(usdg)));
        return address(fills);
    }

    function setUp() public override {
        super.setUp();
        partnerFactory.setFiller(fillers[0], true);
    }

    // ---------------------------------------------------------------- fixture

    function _shares(uint256 count) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            limits[i] = type(uint256).max;
        }
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal override {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(p.allocations.length));
    }

    function _assertRefused(IntentQuoteVerifier.Plan memory p, IntentQuoteVerifier.Refusal expected) internal override {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        vm.expectRevert(abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, expected));
        fills.fill(p, signature, _shares(p.allocations.length));
    }

    function _awkward() internal returns (uint256) {
        return _list(borrower, address(nvda), 100e18, 1_000_000_003, 1_100_000_010, T21);
    }

    struct Held {
        uint40 maturity;
        uint128 principal;
        uint128 rate;
        uint128 executionFee;
        bool executionEarned;
    }

    function _held(IntentVault vault, uint256 id) internal view returns (Held memory h) {
        (,,, h.maturity,,,,,, h.principal,,, h.rate,, h.executionFee, h.executionEarned) = vault.loans(id);
    }

    /// @dev Everything a failed fill must leave exactly as it was.
    function _snapshot(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                core.getLoan(id).filled,
                first.totalAssets(),
                first.cash(),
                first.executionPending(),
                first.executionFees(),
                second.totalAssets(),
                second.cash(),
                second.executionPending(),
                usdg.balanceOf(address(fills)),
                fills.totalOwed()
            )
        );
    }

    // ---------------------------------------------------------------- S4-A1, S4-A3: one transaction, every ledger

    function testSeveralVaultsCompleteAListingAndEveryLedgerIsFinalInTheSameTransaction() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        uint256 fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
        _fill(p);
        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE));
        for (uint256 i; i < 2; ++i) {
            Held memory h = _held(vaults[i], id);
            // The vault that bought first had not seen the loan active; the router brought it to the same activation.
            assertEq(h.maturity, uint256(l.fundedAt) + l.term, "common activation");
            assertGt(h.rate, 0, "accruing");
            assertTrue(h.executionEarned);
            assertEq(h.executionFee, p.allocations[i].executionFee);
            assertEq(h.principal, p.allocations[i].principal);
            assertEq(vaults[i].executionPending(), 0);
            assertEq(vaults[i].executionFees(), 0, "handed to the router");
        }
        assertEq(usdg.balanceOf(address(fills)), fee);
        assertEq(fills.totalOwed(), fee);
        assertEq(fills.owed(p.filler), 0, "the filler is owed nothing (D49)");
        assertEq(fills.owed(feeProcessor), fee, "the protocol recipient takes every execution fee");
    }

    function testAFillPublishesEachContributionAndTheSplitItWasEarnedUnder() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes32 digest = verifier.planHash(p);
        uint256 fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
        for (uint256 i; i < 2; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            vm.expectEmit(address(fills));
            emit IntentFillRouter.Contribution(digest, a.vault, a.units, a.principal, a.interest, a.executionFee);
        }
        vm.expectEmit(address(fills));
        emit IntentFillRouter.Filled(digest, id, fillers[0], uint40(block.timestamp), 1_000_000_003, fee, feeProcessor);
        _fill(p);
    }

    /// @dev R3's identity, per vault, to the unit: what the loan earns is the execution fee, the performance fee
    /// and what depositors keep, priced or as the earnings claim of its last second (M-01), and the execution fee is
    /// expensed once.
    function testEveryVaultReconcilesThroughRepaymentAndNoFeeIsChargedTwice() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        _fill(p);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        for (uint256 i; i < 2; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            vaults[i].settle(_ids(id));
            uint256 performance = vaults[i].curatorFees() + vaults[i].protocolFees();
            assertEq(performance, IntentFeeMath.performanceFee(a.interest, a.executionFee, a.managerBps));
            assertEq(
                vaults[i].totalAssets() + vaults[i].pocketLiability(address(usdg)) + a.executionFee + performance,
                10_000e6 + a.interest
            );
            assertEq(vaults[i].executionFees(), 0);
        }
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.sweepStale(address(first));
    }

    // ---------------------------------------------------------------- S4-A1, S4-A2: all of it or none of it

    function testAFailureInTheFirstTheMiddleOrTheLastContributionLeavesNothingBehind() public {
        third = _vault(1200, 2);
        IntentVault[] memory vaults = new IntentVault[](3);
        (vaults[0], vaults[1], vaults[2]) = (first, second, third);
        // Address order, as a plan needs it.
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (address(vaults[j]) < address(vaults[i])) (vaults[i], vaults[j]) = (vaults[j], vaults[i]);
            }
        }
        uint8[] memory counts = new uint8[](3);
        (counts[0], counts[1], counts[2]) = (1, 1, 2);
        uint256 id = _awkward();
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        bytes32 digest = verifier.planHash(p);
        for (uint256 broken; broken < 3; ++broken) {
            IntentVault v = vaults[broken];
            (uint128 cap, uint16 asset, uint16 buffer) = (v.maxLoanPrincipal(), v.maxAssetBps(), v.bufferBps());
            bytes32 before_ = _snapshot(id);
            uint256 thirdAssets = third.totalAssets();
            // Its manager now keeps every asset liquid, so this vault cannot pay for its units. The verifier does not
            // mirror the buffer: the plan passes preflight, and every purchase before this one runs and is undone.
            uint256 state = vm.snapshotState();
            IntentLimits.setLimits(v, cap, asset, 10_000);
            assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE), "passes preflight");
            vm.prank(fillers[0]);
            vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
            fills.fill(p, signature, _shares(3));
            assertEq(_snapshot(id), before_, "balances");
            assertEq(third.totalAssets(), thirdAssets, "balances");
            assertFalse(verifier.consumed(digest), "the plan is not used up");
            for (uint256 k; k < 3; ++k) {
                assertEq(_held(vaults[k], id).principal, 0, "no contribution is kept");
            }
            // Back to the buffer it had: lowering it again would wait three hours (D53), so the state is restored.
            vm.revertToState(state);
            assertEq(v.bufferBps(), buffer);
        }
        // A pause is refused before any purchase runs (M-49), and the plan stays usable.
        vm.prank(curator);
        vaults[1].setPaused(true);
        vm.prank(fillers[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE)
        );
        fills.fill(p, signature, _shares(3));
        vm.prank(curator);
        vaults[1].setPaused(false);
        assertFalse(verifier.consumed(digest));
        vm.prank(fillers[0]);
        fills.fill(p, signature, _shares(3));
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
    }

    function testAFeeThatDoesNotArriveExactlyRevertsTheWholeFill() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes32 before_ = _snapshot(id);
        // The last step of all fails: the second vault reports one unit less than the plan signed.
        vm.mockCall(
            address(second),
            abi.encodeWithSelector(IntentVault.collectExecutionFees.selector),
            abi.encode(uint256(p.allocations[1].executionFee) - 1)
        );
        bytes memory signature = _sign(p);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentFillRouter.FeeMismatch.selector);
        fills.fill(p, signature, _shares(2));
        vm.clearMockedCalls();
        assertEq(_snapshot(id), before_);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.FUNDING));
        assertFalse(verifier.consumed(verifier.planHash(p)));
    }

    /// @dev The real verifier never lets an incomplete plan through. Behind one that does, the router still refuses
    /// to leave a vault holding part of a listing that did not activate.
    function testEveryPurchaseSucceedingIsNotEnoughTheListingMustHaveActivated() public {
        AcceptingVerifier lax = new AcceptingVerifier(address(partnerFactory), address(core));
        IntentFillRouter loose = new IntentFillRouter(IntentQuoteVerifier(address(lax)), IERC20(address(usdg)));
        _rebindFillRouter(address(loose));
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 2);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentFillRouter.NotActivated.selector);
        loose.fill(p, "", _shares(2));
        assertEq(core.getLoan(id).filled, 0);
        assertEq(_held(first, id).principal, 0);
    }

    function testAManualLenderMovingBeforeExecutionAnExpiredPlanOrTooLittleLiquidityFailSafely() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        // A manual lender takes a unit: the signed purchases are no longer the listing's empty units.
        vm.prank(fillers[1]);
        core.fund(id, 1);
        _assertRefused(p, IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
        // A plan made for what was left stops completing the listing when that lender walks away again.
        (vaults, counts) = _two(1, 2);
        IntentQuoteVerifier.Plan memory rest = _plan(id, vaults, counts);
        vm.prank(fillers[1]);
        core.withdrawCommitment(id);
        _assertRefused(rest, IntentQuoteVerifier.Refusal.ALLOCATION_CHANGED);
        // Too little liquidity in the last vault: the first vault's purchase is rolled back with it.
        (vaults, counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory again = _plan(id, vaults, counts);
        // Its manager now keeps nearly everything liquid, so it cannot pay for three units.
        IntentLimits.setLimits(second, 1_000_000e6, 10_000, 9500);
        bytes32 before_ = _snapshot(id);
        bytes memory signature = _sign(again);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        fills.fill(again, signature, _shares(2));
        assertEq(_snapshot(id), before_);
        assertEq(_held(first, id).principal, 0, "no retained contribution");
        vm.warp(block.timestamp + 91);
        _assertRefused(again, IntentQuoteVerifier.Refusal.EXPIRED);
    }

    function testAReserveSlippageLimitIsEachPurchasesOwn() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentFillRouter.LengthMismatch.selector);
        fills.fill(p, signature, _shares(1));
    }

    // ---------------------------------------------------------------- S4-A3, R3-A4: earned money stays earned

    function testEarnedFeesArePaidOnceToTheRecipientsOfTheDayTheyWereEarned() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        _fill(p);
        uint256 protocolPart = fills.owed(feeProcessor);
        assertGt(protocolPart, 0);
        assertEq(fills.owed(p.filler), 0, "the filler is owed nothing (D49)");
        assertEq(fills.totalOwed(), protocolPart, "every unit owed is the protocol recipient's");
        // Every later setting: a new protocol recipient.
        address laterProcessor = address(new MockFeeProcessor(address(usdg)));
        partnerFactory.setProtocolRecipient(laterProcessor);
        assertEq(fills.owed(feeProcessor), protocolPart);
        assertEq(fills.owed(laterProcessor), 0, "earned fees stay with the recipient of the day");
        assertEq(fills.totalOwed(), protocolPart);
        // Anyone may trigger a payment; the money only goes to the recipient.
        uint256 before_ = usdg.balanceOf(feeProcessor);
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.expectEmit(address(fills));
        emit IntentFillRouter.Claimed(feeProcessor, protocolPart);
        vm.prank(bob);
        assertEq(fills.claim(feeProcessor), protocolPart);
        assertEq(usdg.balanceOf(feeProcessor) - before_, protocolPart);
        assertEq(usdg.balanceOf(bob), bobBefore);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(feeProcessor);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(p.filler);
        assertEq(fills.totalOwed(), 0);
        assertEq(usdg.balanceOf(address(fills)), 0);
        // The next fill is earned under the new settings: all of it to the new protocol recipient.
        uint256 next = _awkward();
        IntentQuoteVerifier.Plan memory q = _plan(next, vaults, counts);
        _fill(q);
        uint256 fee = uint256(q.allocations[0].executionFee) + q.allocations[1].executionFee;
        assertEq(fills.owed(laterProcessor), fee);
        assertEq(fills.owed(feeProcessor), 0, "the former recipient earns nothing from a later fill");
        assertEq(fills.totalOwed(), fee);
    }

    /// @dev D49: V1 has no filler share, so every execution fee goes to the protocol recipient, which must be a fee
    /// processor (D30). The router has no setting for it; a later filler model comes with a new router.
    function testTheFillerShareIsLockedAtZeroAndTheProtocolTakesEveryUnit() public {
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        for (uint256 i; i < 2; ++i) {
            uint256 owedBefore = fills.owed(feeProcessor);
            uint256 id = _awkward();
            IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
            uint256 fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
            _fill(p);
            assertEq(fills.owed(feeProcessor) - owedBefore, fee);
            assertEq(fills.owed(p.filler), 0);
            assertEq(fills.totalOwed(), fills.owed(feeProcessor), "every unit owed is the protocol recipient's");
            assertEq(usdg.balanceOf(address(fills)), fills.totalOwed());
        }
    }

    /// @dev Inherited earned fees must be swept to the protocol before the next fill's exact-fee check can pass.
    function testInheritedFeesMustBeSweptBeforeTheNextFill() public {
        _rebindFillRouter(address(router));
        uint256 old = _listing();
        vm.prank(fillers[0]);
        router.fund(first, old, UNITS, 7e6);
        assertEq(first.executionFees(), 7e6);
        _rebindFillRouter(address(fills));
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentFillRouter.FeeMismatch.selector);
        fills.fill(p, signature, _shares(1));
        vm.expectEmit(address(fills));
        emit IntentFillRouter.StaleFeesSwept(address(first), feeProcessor, 7e6);
        fills.sweepStale(address(first));
        assertEq(fills.owed(feeProcessor), 7e6);
        vm.expectRevert(IntentFillRouter.NotAVault.selector);
        fills.sweepStale(address(core));
        vm.prank(fillers[0]);
        fills.fill(p, signature, _shares(1));
    }

    /// @dev Pashov M-17 clean-router control. A completed fill leaves no fee for a later settlement to earn again.
    /// Shutdown therefore has nothing to sweep; M-22's positive inherited balance is covered separately below.
    function testNoSettleOrShutdownLeavesAFeeToSweepOrToMismatchTheNextFill() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        _fill(p);
        uint256 fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
        // Anyone settles the active loan before the next fill.
        vm.warp(block.timestamp + 1 days);
        for (uint256 i; i < 2; ++i) {
            vm.prank(bob);
            vaults[i].settle(_ids(id));
            assertEq(vaults[i].executionFees() + vaults[i].executionPending(), 0, "settled by a stranger");
        }
        // Fills shut: the curator closes fillers and the owner zeroes the quote signer.
        partnerFactory.setQuoteSigner(address(0));
        for (uint256 i; i < 2; ++i) {
            vm.prank(curator);
            vaults[i].setFillersOpen(false);
            vaults[i].settle(_ids(id));
            assertEq(vaults[i].executionFees() + vaults[i].executionPending(), 0, "settled while shut");
            vm.expectRevert(IntentFillRouter.NothingOwed.selector);
            fills.sweepStale(address(vaults[i]));
        }
        // Reopened: nothing to sweep.
        partnerFactory.setQuoteSigner(signer);
        for (uint256 i; i < 2; ++i) {
            vm.prank(curator);
            vaults[i].setFillersOpen(true);
            vm.expectRevert(IntentFillRouter.NothingOwed.selector);
            fills.sweepStale(address(vaults[i]));
        }
        IntentQuoteVerifier.Plan memory q = _plan(_awkward(), vaults, counts);
        _fill(q);
        fee += uint256(q.allocations[0].executionFee) + q.allocations[1].executionFee;
        assertEq(fills.owed(feeProcessor), fee, "each fill collected its own fees");
        assertEq(first.executionFees() + second.executionFees(), 0);
    }

    /// @dev Pashov M-17. A loan settled as defaulted by a stranger at the end of its term earns no fee a second time:
    /// its vaults hold nothing pending, earned or to sweep, and fill again.
    function testALoanSettledAsDefaultedLeavesNoFeeToSweepOrToMismatchTheNextFill() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        _fill(_plan(id, vaults, counts));
        vm.warp(_maturity(id));
        for (uint256 i; i < 2; ++i) {
            vm.prank(bob);
            vaults[i].settle(_ids(id));
        }
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED));
        for (uint256 i; i < 2; ++i) {
            assertEq(vaults[i].executionFees() + vaults[i].executionPending(), 0);
            vm.expectRevert(IntentFillRouter.NothingOwed.selector);
            fills.sweepStale(address(vaults[i]));
        }
        // Modeled costs are published with a lifetime; the next fill needs a fresh one.
        _modeled(address(nvda), COST_BPS);
        _fill(_plan(_awkward(), vaults, counts));
        assertEq(first.executionFees() + second.executionFees(), 0);
    }

    // ---------------------------------------------------------------- M-22: earned liabilities survive funding shutdown

    function _leaveEarnedFees() internal {
        _rebindFillRouter(address(router));
        uint256 id = _listing();
        vm.prank(fillers[0]);
        router.fund(first, id, UNITS, 7e6);
        assertEq(first.executionFees(), 7e6);
        assertEq(first.executionPending(), 0);
        _rebindFillRouter(address(fills));
    }

    function _assertEarnedFeesCollectible(bool closeFillers, bool zeroSigner) internal {
        _leaveEarnedFees();
        uint256 assets = first.totalAssets();
        uint256 cash = first.cash();
        uint256 held = usdg.balanceOf(address(first));
        uint256 bobHeld = usdg.balanceOf(bob);
        if (closeFillers) {
            vm.prank(curator);
            first.setFillersOpen(false);
        }
        if (zeroSigner) partnerFactory.setQuoteSigner(address(0));

        // Collection authorization does not reopen purchases or reserve investment.
        uint256 next = _awkward();
        vm.prank(address(fills));
        vm.expectRevert(IntentVault.NotCurator.selector);
        first.purchase(next, UNITS, 0, type(uint256).max, 0);
        vm.prank(address(fills));
        vm.expectRevert(IntentVault.NotCurator.selector);
        first.investReserve(1e6, 0);

        vm.expectEmit(address(first));
        emit IntentVault.ExecutionFeesCollected(address(fills), 7e6);
        vm.expectEmit(address(fills));
        emit IntentFillRouter.StaleFeesSwept(address(first), feeProcessor, 7e6);
        vm.prank(bob);
        assertEq(fills.sweepStale(address(first)), 7e6);
        assertEq(first.executionFees() + first.executionPending(), 0);
        assertEq(first.cash(), cash, "collection changes no priced cash");
        assertEq(first.totalAssets(), assets, "collection changes no NAV");
        assertEq(usdg.balanceOf(address(first)), held - 7e6);
        assertEq(usdg.balanceOf(address(fills)), 7e6);
        assertEq(usdg.balanceOf(bob), bobHeld, "the sweep caller receives no fee");
        assertEq(fills.totalOwed(), 7e6);
        assertEq(fills.owed(feeProcessor), 7e6);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.sweepStale(address(first));

        if (zeroSigner) partnerFactory.setQuoteSigner(signer);
        if (closeFillers) {
            vm.prank(curator);
            first.setFillersOpen(true);
        }
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(next, vaults, counts);
        _fill(p);
        assertEq(uint8(core.getLoan(next).state), uint8(V2State.ACTIVE));
        assertEq(first.executionFees() + first.executionPending(), 0);
        assertEq(fills.owed(feeProcessor), 7e6 + p.allocations[0].executionFee);
        assertEq(usdg.balanceOf(address(fills)), fills.totalOwed());
    }

    function testEarnedFeesRemainCollectibleWithFillersClosed() public {
        _assertEarnedFeesCollectible(true, false);
    }

    function testEarnedFeesRemainCollectibleWithQuoteSignerUnset() public {
        _assertEarnedFeesCollectible(false, true);
    }

    function testEarnedFeesRemainCollectibleWithBothFundingGatesClosed() public {
        _assertEarnedFeesCollectible(true, true);
    }

    function testClosedFundingCollectionStillRequiresTheCurrentRouter() public {
        _leaveEarnedFees();
        vm.prank(curator);
        first.setFillersOpen(false);
        partnerFactory.setQuoteSigner(address(0));
        uint256 held = usdg.balanceOf(address(first));
        address[5] memory strangers = [curator, fillers[0], signer, bob, address(router)];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(IntentVault.NotCurator.selector);
            first.collectExecutionFees();
            assertEq(first.executionFees(), 7e6);
            assertEq(usdg.balanceOf(address(first)), held);
        }
        // Zero router remains the factory owner's complete stop for collection.
        partnerFactory.setFillRouter(address(0));
        vm.prank(address(fills));
        vm.expectRevert(IntentVault.NotCurator.selector);
        first.collectExecutionFees();
        assertEq(first.executionFees(), 7e6);
        assertEq(usdg.balanceOf(address(first)), held);
        partnerFactory.setFillRouter(address(fills));
        assertEq(fills.sweepStale(address(first)), 7e6);
        assertEq(fills.owed(feeProcessor), 7e6);
        assertEq(first.executionFees(), 0);
    }

    function testClosedFundingCollectionDoesNotTakePendingFees() public {
        _rebindFillRouter(address(router));
        uint256 id = _listing();
        vm.prank(fillers[0]);
        router.fund(first, id, 2, 7e6);
        _rebindFillRouter(address(fills));
        vm.prank(curator);
        first.setFillersOpen(false);
        partnerFactory.setQuoteSigner(address(0));
        uint256 held = usdg.balanceOf(address(first));
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.sweepStale(address(first));
        assertEq(first.executionFees(), 0);
        assertEq(first.executionPending(), 7e6);
        assertEq(usdg.balanceOf(address(first)), held);
        assertEq(fills.totalOwed(), 0);
    }

    // ---------------------------------------------------------------- S4-A4: no way around the router

    function testNobodyFundsCollectsOrConsumesExceptThroughTheRouter() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        address[3] memory strangers = [curator, fillers[0], signer];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(IntentVault.NotCurator.selector);
            first.purchase(id, UNITS, 0, type(uint256).max, 0);
            vm.prank(strangers[i]);
            vm.expectRevert(IntentVault.NotCurator.selector);
            first.collectExecutionFees();
            vm.prank(strangers[i]);
            vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
            verifier.consume(p, signature, strangers[i]);
        }
        // A partner's curator, and an admitted filler using someone else's plan, get nowhere through the router.
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.WRONG_FILLER)
        );
        fills.fill(p, signature, _shares(1));
        partnerFactory.setFiller(fillers[0], false);
        _assertRefused(p, IntentQuoteVerifier.Refusal.FILLER_NOT_ADMITTED);
    }

    /// @dev The factory binds the first router it names (L-02, L-03, L-05): it can no longer name another, only close
    /// fills, and then its own router funds nothing either.
    function testARouterTheFactoryNoLongerNamesFundsNothing() public {
        uint256 id = _awkward();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        partnerFactory.setFillRouter(address(router));
        partnerFactory.setFillRouter(address(0));
        vm.prank(fillers[0]);
        vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
        fills.fill(p, signature, _shares(1));
    }

    function testOnlyAnAdmittedFillerMovesIdleCashIntoTheReserveAndOnlyForAVault() public {
        vm.prank(bob);
        vm.expectRevert(IntentFillRouter.NotFiller.selector);
        fills.investReserve(address(first), 1000e6, 0);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentFillRouter.NotAVault.selector);
        fills.investReserve(address(core), 1000e6, 0);
        vm.prank(fillers[0]);
        assertGt(fills.investReserve(address(first), 1000e6, 0), 0);
    }

    // ---------------------------------------------------------------- S4-A5: nothing here counts in quarters

    /// @dev Eight vaults take one unit each of an eight-unit listing on a local fixture engine. The deployed core has
    /// four units; this shows only that the router's interface and fee accounting do not depend on that number.
    function testTheRoutersAccountingDoesNotDependOnFourUnits() public {
        FineUnitFactory fineFactory = new FineUnitFactory();
        AcceptingVerifier lax = new AcceptingVerifier(address(fineFactory), address(new FineUnitCore()));
        IntentFillRouter fine = new IntentFillRouter(IntentQuoteVerifier(address(lax)), IERC20(address(usdg)));
        IntentQuoteVerifier.Plan memory p;
        p.listingId = 1;
        p.allocations = new IntentQuoteVerifier.Allocation[](8);
        uint256 fee;
        for (uint256 i; i < 8; ++i) {
            FineUnitVault vault = new FineUnitVault(IERC20(address(usdg)));
            usdg.mint(address(vault), 1e6);
            p.allocations[i].vault = address(vault);
            p.allocations[i].units = 1;
            p.allocations[i].principal = 125e6;
            p.allocations[i].interest = 12_500_001;
            p.allocations[i].executionFee = uint128(100_000 + i);
            p.allocations[i].maxReserveShares = p.allocations[i].principal + p.allocations[i].executionFee;
            fee += 100_000 + i;
        }
        vm.prank(bob);
        fine.fill(p, "", _shares(8));
        assertEq(fine.totalOwed(), fee);
        assertEq(fine.owed(bob), 0, "the filler's share is zero (D49)");
        assertEq(fine.owed(address(0xF100)), fee, "the protocol recipient is owed every unit");
        assertEq(usdg.balanceOf(address(fine)), fee);
        // Every vault but the last was brought to the activation.
        assertEq(FineUnitVault(p.allocations[0].vault).settles(), 1);
        assertEq(FineUnitVault(p.allocations[7].vault).settles(), 0);
    }

    function testTheRouterNeedsARealVerifierAndToken() public {
        vm.expectRevert(IntentFillRouter.InvalidConfiguration.selector);
        new IntentFillRouter(IntentQuoteVerifier(address(0xdead)), IERC20(address(usdg)));
        vm.expectRevert(IntentFillRouter.InvalidConfiguration.selector);
        new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(0xdead)));
    }

    function testFuzz_TheRouterHoldsExactlyWhatItOwes(uint128 principal, uint16 premiumBps, uint8 units) public {
        principal = uint128(bound(principal, 100e6, 4000e6));
        premiumBps = uint16(bound(premiumBps, 800, 3000));
        units = uint8(bound(units, 1, 3));
        uint128 cap = principal + uint128(uint256(principal) * premiumBps / 10_000) + 3;
        uint256 id = _list(borrower, address(nvda), 100e18, principal, cap, T21);
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(units, UNITS - units);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        vm.assume(_reason(p) == IntentQuoteVerifier.Refusal.NONE);
        _fill(p);
        uint256 fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
        assertEq(usdg.balanceOf(address(fills)), fee);
        assertEq(fills.owed(feeProcessor), fee, "the protocol recipient is owed every unit (D49)");
        assertEq(fills.owed(p.filler), 0);
        assertEq(fills.totalOwed(), fee);
        assertEq(
            first.executionFees() + second.executionFees() + first.executionPending() + second.executionPending(), 0
        );
    }
}
