// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PrivateLaneBaseTest} from "./PrivateLaneBase.t.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {PrivateBorrowRouter} from "../../src/private/PrivateBorrowRouter.sol";
import {IPrivacyPool, IPrivacyPoolsEntrypoint} from "../../src/private/IPrivacyPools.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPrivacyPool, MockPrivacyPoolsEntrypoint} from "../mocks/MockPrivacyPool.sol";
import {MockQuirkERC20} from "../mocks/MockQuirkERC20.sol";

/// @notice The private lane's router against a pool that makes the checks Privacy Pools v1.3.0 makes (processooor,
/// context, association-set root, nullifier) without verifying a Groth16 proof. The real contracts, with real proofs,
/// run in PrivateBorrowRouterRealPool.t.sol.
contract PrivateBorrowRouterTest is PrivateLaneBaseTest {
    struct Args {
        MockPrivacyPool pool;
        IPrivacyPool.WithdrawProof proof;
        PrivateBorrowRouter.Terms terms;
        PrivateBorrowRouter.RootAttestation attestation;
        IntentQuoteVerifier.Plan plan;
        bytes signature;
    }

    MockPrivacyPoolsEntrypoint internal entrypoint;
    MockPrivacyPool internal pool;

    uint256 internal constant ROOT = 0xA5B0;
    uint256 internal constant POOLED = 10_000e18;

    uint256 internal nextNullifier = 1;

    function setUp() public override {
        super.setUp();
        entrypoint = new MockPrivacyPoolsEntrypoint();
        entrypoint.setRoot(ROOT);
        pool = _pool(nvda);
        entrypoint.register(address(nvda), address(pool));
        _deployLane(address(entrypoint));
    }

    // ---------------------------------------------------------------- fixture

    function _pool(MockERC20 token) internal returns (MockPrivacyPool p) {
        p = new MockPrivacyPool(
            address(token), entrypoint, uint256(keccak256(abi.encode("scope", token, nextNullifier)))
        );
        token.mint(address(p), POOLED);
    }

    function _planAhead(uint256 id, address token, uint128 principal, uint128 cap, uint8 a, uint8 b)
        internal
        view
        returns (IntentQuoteVerifier.Plan memory)
    {
        return _planAhead(id, token, COLLATERAL, principal, cap, a, b);
    }

    /// @dev What a prover commits to: the router as processooor, the terms as the withdrawal's data, the pool's scope.
    function _proof(MockPrivacyPool p, PrivateBorrowRouter.Terms memory t, uint256 amount)
        internal
        returns (IPrivacyPool.WithdrawProof memory proof)
    {
        proof.pubSignals[0] = uint256(keccak256(abi.encode("commitment", nextNullifier)));
        proof.pubSignals[1] = nextNullifier++;
        proof.pubSignals[2] = amount;
        proof.pubSignals[3] = 0x57A7E;
        proof.pubSignals[4] = 20;
        proof.pubSignals[5] = entrypoint.latestRoot();
        proof.pubSignals[6] = 10;
        proof.pubSignals[7] = p.context(IPrivacyPool.Withdrawal(address(lane), abi.encode(t)));
    }

    /// @dev Everything an honest borrow carries: a proof, the screener's attestation, and the plan for the next id.
    function _prepared(uint128 principal, uint128 cap) internal returns (Args memory a) {
        a.pool = pool;
        a.terms = _terms(principal, cap);
        a.proof = _proof(pool, a.terms, COLLATERAL);
        a.attestation = _attest(entrypoint.latestRoot());
        a.plan = _planAhead(core.loanCount() + 1, address(nvda), principal, cap, 2, 2);
        a.signature = _sign(a.plan);
    }

    function _default() internal returns (Args memory) {
        return _prepared(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
    }

    function _send(address from, Args memory a) internal returns (uint256) {
        uint256[] memory limits = _shares(a.plan.allocations.length);
        vm.prank(from);
        return lane.borrow(IPrivacyPool(address(a.pool)), a.proof, a.terms, a.attestation, a.plan, a.signature, limits);
    }

    function _borrow(uint128 principal, uint128 cap) internal returns (uint256) {
        return _send(fresh, _prepared(principal, cap));
    }

    function _quirk(MockQuirkERC20.Quirk quirk) internal returns (MockQuirkERC20 token) {
        vm.etch(address(nvda), address(new MockQuirkERC20("NVDA", "NVDA", 18)).code);
        token = MockQuirkERC20(address(nvda));
        token.setQuirk(address(lane), quirk);
    }

    // ---------------------------------------------------------------- borrow

    function test_Borrow_WithdrawsListsAndFundsInOneTransaction() public {
        Args memory a = _default();
        uint256 expected = core.loanCount() + 1;
        vm.expectEmit(true, true, true, true, address(lane));
        emit PrivateBorrowRouter.PrivateBorrow(
            expected, fresh, address(nvda), COLLATERAL, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21
        );
        uint256 id = _send(fresh, a);

        assertEq(id, expected, "id");
        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active");
        assertEq(l.originator, fresh, "originator is the proof's borrower");
        assertEq(core.ownerOf(id), fresh, "borrower right");
        assertEq(l.fundedAt, block.timestamp, "funded now");
        assertEq(l.collateral, COLLATERAL, "the withdrawn value is the collateral");
        assertEq(nvda.balanceOf(l.account), COLLATERAL, "collateral escrowed");
        assertEq(nvda.balanceOf(address(pool)), POOLED - COLLATERAL, "it came out of the pool");
        assertTrue(pool.nullifierHashes(a.proof.pubSignals[1]), "the note is spent");
        assertEq(core.cashCredit(fresh), l.principal - l.originationFee, "proceeds credited to the borrower");

        assertEq(nvda.balanceOf(address(lane)), 0, "router keeps no collateral");
        assertEq(usdg.balanceOf(address(lane)), 0, "router keeps no USDG");
        assertEq(nvda.allowance(address(lane), address(core)), 0, "allowance reset");
        assertEq(lane.openPrincipal(address(nvda)), REVIEW_PRINCIPAL, "open principal");
        (address token, uint128 principal, bool open) = lane.opened(id);
        assertEq(token, address(nvda));
        assertEq(principal, REVIEW_PRINCIPAL);
        assertTrue(open);

        vm.prank(fresh);
        core.withdrawUSDG(payout);
        assertEq(usdg.balanceOf(payout), l.principal - l.originationFee, "proceeds paid to a separate address");
    }

    function test_Borrow_AnyoneMaySubmit_TheProofNamesTheBorrower() public {
        uint256 id = _send(relayer, _default());
        V2Loan memory l = core.getLoan(id);
        assertEq(l.originator, fresh, "the proof's borrower, not the submitter");
        assertEq(core.ownerOf(id), fresh, "the right goes to the borrower");
        assertEq(core.cashCredit(fresh), l.principal - l.originationFee, "and the cash");
        assertEq(core.cashCredit(relayer), 0, "the submitter gets no cash");
        assertEq(nvda.balanceOf(relayer), 0, "nor collateral");
        assertEq(core.balanceOf(relayer), 0, "nor a right");
    }

    function test_Borrow_TakesNothingFromTheCaller() public {
        address team = makeAddr("team-wallet");
        nvda.mint(team, COLLATERAL);
        vm.prank(team);
        nvda.approve(address(lane), MAX);
        uint256 id = _send(team, _default());
        assertEq(nvda.balanceOf(team), COLLATERAL, "the caller's own tokens are never pulled");
        assertEq(core.getLoan(id).originator, fresh, "the loan is the proof's, not the caller's");
        assertEq(nvda.balanceOf(address(pool)), POOLED - COLLATERAL, "the collateral is the pool's withdrawal");
    }

    function test_Borrow_RefusesAPoolTheEntrypointDoesNotList() public {
        MockPrivacyPool rogue = _pool(nvda);
        Args memory a = _default();
        a.pool = rogue;
        a.proof = _proof(rogue, a.terms, COLLATERAL);
        vm.expectRevert(PrivateBorrowRouter.UnknownPool.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAPoolListedForAnotherToken() public {
        MockPrivacyPool memePool = _pool(meme);
        entrypoint.register(address(meme), address(memePool));
        Args memory a = _default();
        a.pool = memePool;
        a.proof = _proof(memePool, a.terms, COLLATERAL);
        vm.expectRevert(PrivateBorrowRouter.UnknownPool.selector);
        _send(fresh, a);
    }

    function testFuzz_Borrow_RefusesTermsTheProofDidNotBind(uint8 field) public {
        Args memory a = _default();
        field = field % 6;
        if (field == 0) a.terms.borrower = relayer;
        else if (field == 1) a.terms.principal -= 1;
        else if (field == 2) a.terms.cap += 1;
        else if (field == 3) a.terms.term = 7 days;
        else if (field == 4) a.terms.fundingDeadline += 1;
        else a.terms.withRewards = false;
        vm.expectRevert(MockPrivacyPool.ContextMismatch.selector);
        _send(relayer, a);
    }

    function test_Borrow_RefusesASpentNote() public {
        Args memory a = _default();
        _send(fresh, a);
        a.plan = _planAhead(core.loanCount() + 1, address(nvda), a.terms.principal, a.terms.cap, 2, 2);
        a.signature = _sign(a.plan);
        vm.expectRevert(MockPrivacyPool.NullifierAlreadySpent.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAZeroWithdrawal() public {
        Args memory a = _default();
        a.proof = _proof(pool, a.terms, 0);
        vm.expectRevert(PrivateBorrowRouter.ZeroCollateral.selector);
        _send(fresh, a);
    }

    // ---------------------------------------------------------------- attestation

    function test_Borrow_RefusesWhileTheAttesterIsDisabled() public {
        Args memory a = _default();
        lane.setAttester(address(0));
        vm.expectRevert(PrivateBorrowRouter.AttesterDisabled.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesARootTheEntrypointNoLongerHolds() public {
        Args memory a = _default();
        entrypoint.setRoot(ROOT + 1);
        vm.expectRevert(PrivateBorrowRouter.AttestationRootMismatch.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationOfAnotherRoot() public {
        Args memory a = _default();
        a.attestation = _attest(ROOT + 1);
        vm.expectRevert(PrivateBorrowRouter.AttestationRootMismatch.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationForAnotherToken() public {
        Args memory a = _default();
        uint40 at = uint40(block.timestamp);
        a.attestation = _attestWith(ATTESTER_KEY, address(lane), block.chainid, ROOT, address(meme), at, at + 2 minutes);
        vm.expectRevert(PrivateBorrowRouter.AttestationTokenMismatch.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationByAnotherKey() public {
        Args memory a = _default();
        uint40 at = uint40(block.timestamp);
        a.attestation = _attestWith(0xBAD, address(lane), block.chainid, ROOT, address(nvda), at, at + 2 minutes);
        vm.expectRevert(PrivateBorrowRouter.BadAttestation.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationForAnotherRouter() public {
        PrivateBorrowRouter other = new PrivateBorrowRouter(
            fills, IPrivacyPoolsEntrypoint(address(entrypoint)), vm.addr(ATTESTER_KEY), address(this)
        );
        Args memory a = _default();
        uint40 at = uint40(block.timestamp);
        a.attestation =
            _attestWith(ATTESTER_KEY, address(other), block.chainid, ROOT, address(nvda), at, at + 2 minutes);
        vm.expectRevert(PrivateBorrowRouter.BadAttestation.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationForAnotherChain() public {
        Args memory a = _default();
        uint40 at = uint40(block.timestamp);
        a.attestation =
            _attestWith(ATTESTER_KEY, address(lane), block.chainid + 1, ROOT, address(nvda), at, at + 2 minutes);
        vm.expectRevert(PrivateBorrowRouter.BadAttestation.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnExpiredAttestation() public {
        uint40 at = uint40(block.timestamp);
        PrivateBorrowRouter.RootAttestation memory stale =
            _attestWith(ATTESTER_KEY, address(lane), block.chainid, ROOT, address(nvda), at, at + 2 minutes);
        vm.warp(block.timestamp + 2 minutes + 1);
        Args memory a = _default();
        a.attestation = stale;
        vm.expectRevert(PrivateBorrowRouter.AttestationNotCurrent.selector);
        _send(fresh, a);
    }

    function test_Borrow_AcceptsAnAttestationUntilItsLastSecond() public {
        uint40 at = uint40(block.timestamp);
        PrivateBorrowRouter.RootAttestation memory last =
            _attestWith(ATTESTER_KEY, address(lane), block.chainid, ROOT, address(nvda), at, at + 2 minutes);
        vm.warp(block.timestamp + 2 minutes);
        Args memory a = _default();
        a.attestation = last;
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationNotYetIssued() public {
        Args memory a = _default();
        uint40 at = uint40(block.timestamp + 1);
        a.attestation = _attestWith(ATTESTER_KEY, address(lane), block.chainid, ROOT, address(nvda), at, at + 1 minutes);
        vm.expectRevert(PrivateBorrowRouter.AttestationNotCurrent.selector);
        _send(fresh, a);
    }

    function test_Borrow_RefusesAnAttestationLivingLongerThanTwoMinutes() public {
        Args memory a = _default();
        uint40 at = uint40(block.timestamp);
        a.attestation =
            _attestWith(ATTESTER_KEY, address(lane), block.chainid, ROOT, address(nvda), at, at + 2 minutes + 1);
        vm.expectRevert(PrivateBorrowRouter.AttestationTooLong.selector);
        _send(fresh, a);
    }

    /// @dev A cap on the time left alone would let a long-dated attestation back borrows near its end.
    function test_Borrow_RefusesALongDatedAttestationNearItsEnd() public {
        vm.warp(block.timestamp + 1 days);
        Args memory a = _default();
        uint40 at = uint40(block.timestamp - 1 hours);
        a.attestation = _attestWith(
            ATTESTER_KEY, address(lane), block.chainid, ROOT, address(nvda), at, uint40(block.timestamp + 1)
        );
        vm.expectRevert(PrivateBorrowRouter.AttestationTooLong.selector);
        _send(fresh, a);
    }

    // ---------------------------------------------------------------- transfers

    function test_Borrow_RefusesAShortPush() public {
        pool.setShort(1);
        Args memory a = _default();
        vm.expectRevert(
            abi.encodeWithSelector(PrivateBorrowRouter.InexactTransfer.selector, COLLATERAL, COLLATERAL - 1)
        );
        _send(fresh, a);
    }

    function test_Borrow_RefusesATaxedFirstLegAndLeavesStrayTokensAlone() public {
        _quirk(MockQuirkERC20.Quirk.INTO_TAX);
        nvda.mint(address(lane), 5e18);
        Args memory a = _default();
        vm.expectRevert(
            abi.encodeWithSelector(PrivateBorrowRouter.InexactTransfer.selector, COLLATERAL, COLLATERAL - 1e18)
        );
        _send(fresh, a);
        assertEq(nvda.balanceOf(address(lane)), 5e18, "the stray balance is untouched");
    }

    function test_Borrow_RefusesASenderSurchargeOnTheSecondLeg() public {
        _quirk(MockQuirkERC20.Quirk.FROM_SURCHARGE);
        nvda.mint(address(lane), 5e18);
        Args memory a = _default();
        vm.expectRevert(PrivateBorrowRouter.StrayBalance.selector);
        _send(fresh, a);
        assertEq(nvda.balanceOf(address(lane)), 5e18, "the stray balance is untouched");
    }

    function test_Borrow_RefusesASurplusOnReceipt() public {
        _quirk(MockQuirkERC20.Quirk.INTO_BONUS);
        Args memory a = _default();
        vm.expectRevert(
            abi.encodeWithSelector(PrivateBorrowRouter.InexactTransfer.selector, COLLATERAL, COLLATERAL + 1e18)
        );
        _send(fresh, a);
    }

    function testFuzz_Borrow_RouterEndsWithTheBalanceItStarted(uint96 stray, uint96 strayCash, uint96 amount) public {
        ICollateralRegistry.ERC20Config memory cfg = registry.getERC20Config(address(nvda));
        amount = uint96(bound(amount, cfg.minAmount, cfg.maxDealRaw < POOLED ? cfg.maxDealRaw : POOLED));
        nvda.mint(address(lane), stray);
        usdg.mint(address(lane), strayCash);
        Args memory a = _default();
        a.proof = _proof(pool, a.terms, amount);
        a.plan.collateral = amount;
        a.signature = _sign(a.plan);
        uint256 id = _send(fresh, a);
        assertEq(nvda.balanceOf(address(lane)), stray, "collateral balance unchanged");
        assertEq(usdg.balanceOf(address(lane)), strayCash, "USDG balance unchanged");
        assertEq(nvda.balanceOf(core.getLoan(id).account), amount, "escrow holds exactly the withdrawn value");
    }

    // ---------------------------------------------------------------- plan and core

    function test_Borrow_RevertsBeforeFundingWhenTheIdWasTaken() public {
        Args memory a = _default();
        uint256 planned = a.plan.listingId;
        assertEq(_listing(), planned, "someone else took the planned id");
        vm.expectRevert(abi.encodeWithSelector(PrivateBorrowRouter.ListingMismatch.selector, planned + 1, planned));
        _send(fresh, a);
        assertEq(nvda.balanceOf(address(pool)), POOLED, "the pool keeps the deposit");
        assertFalse(pool.nullifierHashes(a.proof.pubSignals[1]), "the note is not spent");
        assertEq(uint8(core.getLoan(planned).state), uint8(V2State.FUNDING), "the other listing is untouched");
    }

    function test_Borrow_RevertsOnAClosedToken() public {
        Args memory a = _default();
        a.plan = _planAhead(core.loanCount() + 1, address(meme), a.terms.principal, a.terms.cap, 2, 2);
        a.signature = _sign(a.plan);
        vm.expectRevert(PrivateBorrowRouter.TokenClosed.selector);
        _send(fresh, a);
    }

    function test_Borrow_RevertsOverTheCap() public {
        lane.setTokenCap(address(nvda), 1500e6);
        _borrow(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        Args memory a = _default();
        vm.expectRevert(abi.encodeWithSelector(PrivateBorrowRouter.CapExceeded.selector, 2000e6, 1500e6));
        _send(fresh, a);
    }

    function test_Borrow_RevertsWhenTheCapWasLoweredBelowWhatIsOpen() public {
        _borrow(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        lane.setTokenCap(address(nvda), 500e6);
        Args memory a = _default();
        vm.expectRevert(abi.encodeWithSelector(PrivateBorrowRouter.CapExceeded.selector, 2000e6, 500e6));
        _send(fresh, a);
    }

    function test_Borrow_RefusesAPlanSignedForAnotherFiller() public {
        partnerFactory.setFiller(fillers[0], true);
        Args memory a = _default();
        a.plan.filler = fillers[0];
        a.signature = _sign(a.plan);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.WRONG_FILLER)
        );
        _send(fresh, a);
    }

    function test_Borrow_RefusesAPlanNotSignedByTheQuoteSigner() public {
        Args memory a = _default();
        a.signature = _signWith(0xBAD, a.plan);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BAD_SIGNATURE)
        );
        _send(fresh, a);
    }

    function test_Borrow_NeedsTheRegistryToAdmitTheRouter() public {
        vm.prank(safe);
        registry.setRouter(address(lane), false);
        Args memory a = _default();
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        _send(fresh, a);
    }

    function test_Borrow_NeedsTheFactoryToAdmitTheFiller() public {
        partnerFactory.setFiller(address(lane), false);
        Args memory a = _default();
        vm.expectRevert(
            abi.encodeWithSelector(
                IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.FILLER_NOT_ADMITTED
            )
        );
        _send(fresh, a);
    }

    // ---------------------------------------------------------------- release

    function test_Release_ReturnsCapacityAfterRepayment() public {
        uint256 id = _borrow(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        usdg.mint(fresh, REVIEW_CAP);
        vm.startPrank(fresh);
        usdg.approve(address(core), MAX);
        core.reclaim(id, fresh);
        vm.stopPrank();
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID), "repaid");

        vm.expectEmit(true, true, false, true, address(lane));
        emit PrivateBorrowRouter.Released(id, address(nvda), uint128(REVIEW_PRINCIPAL));
        lane.release(_ids(id));
        assertEq(lane.openPrincipal(address(nvda)), 0, "capacity back");
        (,, bool open) = lane.opened(id);
        assertFalse(open);

        vm.recordLogs();
        lane.release(_ids(id));
        assertEq(vm.getRecordedLogs().length, 0, "a second release does nothing");
    }

    function test_Release_ReturnsCapacityAfterDefault() public {
        uint256 id = _borrow(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        V2Loan memory l = core.getLoan(id);
        vm.warp(uint256(l.fundedAt) + l.term + core.GRACE());
        core.finalizeDefault(id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED), "defaulted");
        lane.release(_ids(id));
        assertEq(lane.openPrincipal(address(nvda)), 0, "capacity back");
    }

    function test_Release_SkipsLoansStillOpenAndUnknownIds() public {
        uint256 id = _borrow(uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP));
        uint256 other = _listing();
        uint256[] memory both = new uint256[](2);
        both[0] = id;
        both[1] = other;
        lane.release(both);
        assertEq(lane.openPrincipal(address(nvda)), REVIEW_PRINCIPAL, "still counts while active");
        (,, bool open) = lane.opened(id);
        assertTrue(open);
    }

    // ---------------------------------------------------------------- admin

    function test_SetTokenCap_IsBoundedAndOwned() public {
        vm.expectEmit(true, false, false, true, address(lane));
        emit PrivateBorrowRouter.TokenCapSet(address(meme), 1e6);
        lane.setTokenCap(address(meme), 1e6);
        assertEq(lane.tokenCap(address(meme)), 1e6);

        uint128 max = lane.MAX_TOKEN_CAP();
        lane.setTokenCap(address(meme), max);
        vm.expectRevert(PrivateBorrowRouter.InvalidCap.selector);
        lane.setTokenCap(address(meme), max + 1);
        vm.expectRevert(PrivateBorrowRouter.InvalidCap.selector);
        lane.setTokenCap(address(0), 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lane.setTokenCap(address(meme), 1e6);
    }

    function test_SetAttester_RotatesAndDisables_OwnerOnly() public {
        uint256 nextKey = 0xB0B;
        address next = vm.addr(nextKey);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lane.setAttester(next);

        vm.expectEmit(true, true, false, false, address(lane));
        emit PrivateBorrowRouter.AttesterSet(vm.addr(ATTESTER_KEY), next);
        lane.setAttester(next);
        assertEq(lane.attester(), next);

        Args memory a = _default();
        vm.expectRevert(PrivateBorrowRouter.BadAttestation.selector);
        _send(fresh, a);
        uint40 at = uint40(block.timestamp);
        a.attestation = _attestWith(nextKey, address(lane), block.chainid, ROOT, address(nvda), at, at + 2 minutes);
        _send(fresh, a);

        vm.expectEmit(true, true, false, false, address(lane));
        emit PrivateBorrowRouter.AttesterSet(next, address(0));
        lane.setAttester(address(0));
        Args memory b = _default();
        vm.expectRevert(PrivateBorrowRouter.AttesterDisabled.selector);
        _send(fresh, b);
    }

    function test_AttestationDigest_IsTheTypedDataForThisChainAndRouter() public view {
        assertEq(
            lane.attestationDigest(ROOT, address(nvda), 1000, 1120),
            _digest(address(lane), block.chainid, ROOT, address(nvda), 1000, 1120),
            "the screener signs exactly this digest"
        );
        assertEq(lane.MAX_ATTESTATION_LIFE(), 2 minutes);
    }

    /// @dev The same vector the screener's signer pins (services/screener/test/attest.test.ts), computed with viem.
    function test_AttestationDigest_MatchesTheScreenersVector() public pure {
        assertEq(
            _digest(
                0x1111111111111111111111111111111111111111,
                46_630,
                12_345,
                0x5845eF6154052AE3001efE14DC873654269b8A18,
                1000,
                1120
            ),
            0xeeafa1573aa9199ba8a6f9dcdcf47edbe6583493cbcd7cfad3ae5f7e82dc7b46
        );
    }

    /// @dev The same vector the app pins (web/src/test/privateBorrow.test.ts): the withdrawal data its proof commits to.
    function test_TermsEncoding_MatchesTheAppsVector() public pure {
        PrivateBorrowRouter.Terms memory t = PrivateBorrowRouter.Terms({
            borrower: 0x1111111111111111111111111111111111111111,
            principal: 1000e6,
            cap: 1100e6,
            term: 21 days,
            fundingDeadline: 1_800_000_000,
            withRewards: false
        });
        assertEq(keccak256(abi.encode(t)), 0x23b1c5addfdcd068dd96fa42cbefb81ab6f8cc3a2f2fba6fa6490d62e9b277da);
    }

    function test_Constructor_RefusesAMissingPart() public {
        IPrivacyPoolsEntrypoint ep = IPrivacyPoolsEntrypoint(address(entrypoint));
        address key = vm.addr(ATTESTER_KEY);
        vm.expectRevert(PrivateBorrowRouter.InvalidConfiguration.selector);
        new PrivateBorrowRouter(IntentFillRouter(makeAddr("nothing")), ep, key, address(this));
        vm.expectRevert(PrivateBorrowRouter.InvalidConfiguration.selector);
        new PrivateBorrowRouter(fills, IPrivacyPoolsEntrypoint(makeAddr("no entrypoint")), key, address(this));
        vm.expectRevert(PrivateBorrowRouter.InvalidConfiguration.selector);
        new PrivateBorrowRouter(fills, ep, address(0), address(this));
    }
}
