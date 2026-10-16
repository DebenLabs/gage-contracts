// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EarnV3BaseTest} from "./EarnV3Base.t.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {EarnFactory} from "../../src/earn/EarnFactory.sol";
import {FillRouter} from "../../src/earn/FillRouter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @notice A strategy created by the factory, filled by a filler through the router on a signed quote.
contract FillRouterTest is EarnV3BaseTest {
    EarnFactory internal factory;
    FillRouter internal router;
    address internal signer;
    uint256 internal signerKey;
    address internal filler = makeAddr("intent-filler");
    address internal stranger = makeAddr("stranger");

    function _deploy() internal override {
        factory = new EarnFactory(
            EarnFactory.Params({
                core: address(core),
                reserve: address(reserve),
                grades: address(grades),
                protocolRecipient: floor,
                protocolShareBps: 1000,
                initialOwner: address(this)
            })
        );
        earn = EarnVault(payable(factory.create(p.mandate)));
        router = new FillRouter(factory);
        (signer, signerKey) = makeAddrAndKey("quote-signer");
        factory.setFillRouter(address(router));
        factory.setQuoteSigner(signer);
        factory.setFiller(filler, true);
        vm.prank(curator);
        earn.setFeeRecipient(feeRecipient);
        address[3] memory depositors = [alice, bob, carol];
        for (uint256 i; i < depositors.length; ++i) {
            vm.prank(depositors[i]);
            usdg.approve(address(earn), type(uint256).max);
        }
    }

    /// @dev The quote as the rating service would issue it: the listing exactly as the core records it.
    function _quote(uint256 id) internal view returns (FillRouter.Quote memory q) {
        V2Loan memory l = core.getLoan(id);
        q = FillRouter.Quote({
            strategy: address(earn),
            listingId: id,
            token: l.token,
            collateral: l.collateral,
            principal: l.principal,
            cap: l.cap,
            term: l.term,
            costBps: 300, // the model's 3% for the term; the fixture's listings offer 5%
            expiry: uint40(block.timestamp + 90)
        });
    }

    function _sign(FillRouter.Quote memory q, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, router.quoteHash(q));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Notice the listing and wait out the minimum age, as the keeper would.
    function _aged(uint256 id) internal {
        router.notice(id);
        vm.warp(block.timestamp + router.MIN_AGE());
    }

    function _fillVia(address who, uint256 id, uint8 units) internal {
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(who);
        router.fill(q, units, MAX, sig);
    }

    // ---------------------------------------------------------------- the happy path

    function testAFillerFundsWithinTheMandateOnASignedQuoteAndTheStrategyBooksItAsACuratorFund() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        bytes32 digest = router.quoteHash(q);
        vm.expectEmit(true, true, true, true, address(router));
        emit FillRouter.Filled(address(earn), id, filler, UNITS, digest);
        _fillVia(filler, id, UNITS);
        assertEq(_state(id) == V2State.ACTIVE, true, "the fill activated the loan");
        assertEq(earn.performingPrincipal(), 1000e6);
        assertEq(earn.cash(), 9000e6);
        assertEq(core.lenders(id)[0], address(earn), "the strategy, not the filler, is the lender of record");
        // The loan then runs, repays and settles exactly as a curator-funded loan.
        vm.warp(_maturity(id) - 1);
        _repay(id);
        _settle(id);
        assertEq(earn.cash(), 10_000e6 + 50e6 - 7.5e6, "principal, interest, less the 15% fee");
    }

    function testTheCuratorStillFundsDirectlyWithoutAQuote() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, UNITS);
        assertEq(_state(id) == V2State.ACTIVE, true);
    }

    function testAFillerTopsUpAListingTheStrategyAlreadyHolds() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _fund(id, 2);
        _aged(id);
        _fillVia(filler, id, 2);
        assertEq(_state(id) == V2State.ACTIVE, true);
        assertEq(_loan(id).principal, 1000e6);
    }

    function testTheSameQuoteServesEveryQuarterWhileItLives() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
        vm.warp(block.timestamp + 30);
        vm.prank(filler);
        router.fill(q, 3, MAX, sig);
        assertEq(_state(id) == V2State.ACTIVE, true);
    }

    // ---------------------------------------------------------------- who may fill

    function testNobodyReachesFundOnTheStrategyButTheCuratorAndTheRouter() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        vm.prank(filler);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.fund(id, UNITS, MAX);
        vm.prank(address(this));
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.fund(id, UNITS, MAX);
    }

    function testOnlyAllowlistedFillersUntilPublicFillIsOn() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(stranger);
        vm.expectRevert(FillRouter.NotFiller.selector);
        router.fill(q, 1, MAX, sig);
        factory.setPublicFill(true);
        assertTrue(factory.canFill(stranger));
        vm.prank(stranger);
        router.fill(q, 1, MAX, sig);
        factory.setPublicFill(false);
        factory.setFiller(filler, false);
        vm.prank(filler);
        vm.expectRevert(FillRouter.NotFiller.selector);
        router.fill(q, 1, MAX, sig);
    }

    function testTheCuratorCanCloseFillersOutAndOpenThemAgain() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        vm.prank(filler);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setFillersOpen(false);
        vm.prank(curator);
        vm.expectEmit(true, true, true, true, address(earn));
        emit EarnVault.FillersOpenSet(false);
        earn.setFillersOpen(false);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(EarnVault.NotCurator.selector);
        router.fill(q, UNITS, MAX, sig);
        _fund(id, 1); // the curator is never closed out
        vm.prank(curator);
        earn.setFillersOpen(true);
        vm.prank(filler);
        router.fill(q, 3, MAX, sig);
        assertEq(_state(id) == V2State.ACTIVE, true);
    }

    function testAReplacedRouterFillsNothingAndAZeroRouterClosesThePath() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter old = router;
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        FillRouter next = new FillRouter(factory);
        factory.setFillRouter(address(next));
        vm.prank(filler);
        vm.expectRevert(EarnVault.NotCurator.selector);
        old.fill(q, 1, MAX, sig);
        // The new router has its own stamps and its own signing domain.
        vm.prank(filler);
        vm.expectRevert(FillRouter.TooYoung.selector);
        next.fill(q, 1, MAX, sig);
        factory.setFillRouter(address(0));
        vm.prank(filler);
        vm.expectRevert(EarnVault.NotCurator.selector);
        old.fill(q, 1, MAX, sig);
        vm.expectRevert(EarnFactory.InvalidConfiguration.selector);
        factory.setFillRouter(stranger);
    }

    function testAFillerNeverFundsItsOwnListing() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        factory.setFiller(borrower, true);
        vm.prank(borrower);
        vm.expectRevert(FillRouter.SelfDealing.selector);
        router.fill(q, 1, MAX, sig);
    }

    function testTheStrategyMustComeFromTheFactory() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        EarnVault other = new EarnVault(p); // same mandate, not the factory's
        FillRouter.Quote memory q = _quote(id);
        q.strategy = address(other);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.NotAVault.selector);
        router.fill(q, 1, MAX, sig);
    }

    // ---------------------------------------------------------------- the stamp and the age

    function testNoticeStampsAFundingListingOnceAndRefusesWhatIsNotListed() public {
        uint256 id = _listed(1000e6);
        vm.expectRevert(FillRouter.NotListed.selector);
        router.notice(id + 1); // no such listing yet: a stamp cannot be written ahead of a listing
        vm.expectEmit(true, true, true, true, address(router));
        emit FillRouter.Noticed(id, uint40(block.timestamp));
        router.notice(id);
        uint40 at = router.seenAt(id);
        assertEq(at, uint40(block.timestamp));
        vm.warp(block.timestamp + 1 hours);
        router.notice(id); // a second notice changes nothing
        assertEq(router.seenAt(id), at);
        _deposit(alice, 10_000e6);
        _fund(id, UNITS);
        uint256 activeId = id;
        assertEq(_state(activeId) == V2State.ACTIVE, true);
        uint256 later = _listed(500e6);
        _fund(later, UNITS);
        vm.expectRevert(FillRouter.NotListed.selector);
        router.notice(later); // active, not funding: never stamped
    }

    function testAListingIsFilledOnlyOnceItIsOldEnough() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.TooYoung.selector);
        router.fill(q, 1, MAX, sig); // never noticed
        router.notice(id);
        vm.warp(block.timestamp + router.MIN_AGE() - 1);
        q.expiry = uint40(block.timestamp + 60);
        sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.TooYoung.selector);
        router.fill(q, 1, MAX, sig);
        vm.warp(block.timestamp + 1);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
    }

    // ---------------------------------------------------------------- the quote

    function testAQuoteIsRefusedOnceExpiredOrWhenItLivesTooLong() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        q.expiry = uint40(block.timestamp - 1);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteExpired.selector);
        router.fill(q, 1, MAX, sig);
        q.expiry = uint40(block.timestamp + router.MAX_QUOTE_LIFE() + 1);
        sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteExpired.selector);
        router.fill(q, 1, MAX, sig);
        q.expiry = uint40(block.timestamp + router.MAX_QUOTE_LIFE());
        sig = _sign(q, signerKey);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
    }

    function testAQuoteBindsTheListingAsTheCoreRecordsIt() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        uint256 other = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig;
        q.listingId = other; // a quote for one listing fits no other, even at identical terms
        sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.TooYoung.selector); // `other` was never noticed
        router.fill(q, 1, MAX, sig);
        router.notice(other);
        vm.warp(block.timestamp + router.MIN_AGE());
        FillRouter.Quote memory fresh = _quote(id);
        FillRouter.Quote memory wrong = _quote(id);
        wrong.cap = fresh.cap + 1;
        sig = _sign(wrong, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteMismatch.selector);
        router.fill(wrong, 1, MAX, sig);
        wrong = _quote(id);
        wrong.principal = fresh.principal - 1;
        sig = _sign(wrong, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteMismatch.selector);
        router.fill(wrong, 1, MAX, sig);
        wrong = _quote(id);
        wrong.collateral = fresh.collateral + 1;
        sig = _sign(wrong, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteMismatch.selector);
        router.fill(wrong, 1, MAX, sig);
        wrong = _quote(id);
        wrong.term = T21;
        sig = _sign(wrong, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteMismatch.selector);
        router.fill(wrong, 1, MAX, sig);
        wrong = _quote(id);
        wrong.token = address(meme);
        sig = _sign(wrong, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.QuoteMismatch.selector);
        router.fill(wrong, 1, MAX, sig);
    }

    function testASignatureFromAnyoneButTheSignerIsRefusedAndNoSignerRefusesAll() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig;
        (, uint256 otherKey) = makeAddrAndKey("not-the-signer");
        sig = _sign(q, otherKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BadSignature.selector);
        router.fill(q, 1, MAX, sig);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BadSignature.selector);
        router.fill(q, 1, MAX, hex"");
        // A signature over other fields does not verify for this quote, even a genuine one. (A memory struct
        // assignment aliases, so the variant is built afresh.)
        FillRouter.Quote memory tampered = _quote(id);
        tampered.expiry = q.expiry + 1;
        sig = _sign(tampered, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BadSignature.selector);
        router.fill(q, 1, MAX, sig);
        factory.setQuoteSigner(address(0));
        sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BadSignature.selector);
        router.fill(q, 1, MAX, sig);
        factory.setQuoteSigner(signer);
        sig = _sign(q, signerKey);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
    }

    // ---------------------------------------------------------------- the rate floor

    function testTheFloorDefaultsToCAndTheCuratorMovesItWithinTheBounds() public {
        assertEq(router.floorOf(address(earn)), router.FLOOR_C(), "C until the curator sets one");
        assertEq(router.floorBps(address(earn)), 0);
        vm.prank(filler);
        vm.expectRevert(FillRouter.NotCurator.selector);
        router.setFloor(address(earn), 9000);
        vm.prank(curator);
        vm.expectRevert(FillRouter.NotAVault.selector);
        router.setFloor(stranger, 9000);
        vm.prank(curator);
        vm.expectRevert(FillRouter.InvalidConfiguration.selector);
        router.setFloor(address(earn), 7499);
        vm.prank(curator);
        vm.expectRevert(FillRouter.InvalidConfiguration.selector);
        router.setFloor(address(earn), 20_001);
        vm.prank(curator);
        vm.expectEmit(true, true, true, true, address(router));
        emit FillRouter.FloorSet(address(earn), 9000);
        router.setFloor(address(earn), 9000);
        assertEq(router.floorOf(address(earn)), 9000);
    }

    function testAListingUnderTheFloorShareOfTheQuotedCostIsRefused() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6); // offers 5% for the term
        _aged(id);
        FillRouter.Quote memory q = _quote(id);
        q.costBps = 667; // C: 75% of 6.67% is 5.0025%, just over the offer
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BelowFloor.selector);
        router.fill(q, 1, MAX, sig);
        q = _quote(id);
        q.costBps = 666; // 75% of 6.66% is 4.995%, under the offer
        sig = _sign(q, signerKey);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
        // At A the listing must offer the whole modeled cost.
        uint16 floorA = router.FLOOR_A();
        vm.prank(curator);
        router.setFloor(address(earn), floorA);
        q = _quote(id);
        q.costBps = 501;
        sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BelowFloor.selector);
        router.fill(q, 1, MAX, sig);
        q = _quote(id);
        q.costBps = 500;
        sig = _sign(q, signerKey);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
        // No model, no fill, at any floor.
        q = _quote(id);
        q.costBps = 0;
        sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(FillRouter.BelowFloor.selector);
        router.fill(q, 1, MAX, sig);
        // The curator's own fund reads nothing from the router.
        _fund(id, 2);
        assertEq(_state(id) == V2State.ACTIVE, true);
    }

    function testTheCostIsPartOfTheSignedQuote() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        FillRouter.Quote memory signed = _quote(id);
        signed.costBps = 300;
        bytes memory sig = _sign(signed, signerKey);
        FillRouter.Quote memory q = _quote(id);
        q.costBps = 200; // a filler cannot lower the cost the signer quoted
        vm.prank(filler);
        vm.expectRevert(FillRouter.BadSignature.selector);
        router.fill(q, 1, MAX, sig);
    }

    // ---------------------------------------------------------------- the service's signature

    /// @dev The rates service signs with viem under the same domain and types (services/valuation/src/rates/quotes.ts);
    /// the digest and signature below were produced there for this exact quote, chain 4663 and router
    /// 0x1111…1111 with the private key 0x…01, so the router's typehash and encoding are checked across languages.
    function testTheRouterComputesTheDigestTheServiceSigns() public view {
        FillRouter.Quote memory q = FillRouter.Quote({
            strategy: 0x2222222222222222222222222222222222222222,
            listingId: 7,
            token: 0x3333333333333333333333333333333333333333,
            collateral: 100e18,
            principal: 1000e6,
            cap: 1050e6,
            term: 604_800,
            costBps: 300,
            expiry: 1_800_000_000
        });
        bytes32 structHash = keccak256(
            abi.encode(
                router.QUOTE_TYPEHASH(),
                q.strategy,
                q.listingId,
                q.token,
                q.collateral,
                q.principal,
                q.cap,
                q.term,
                q.costBps,
                q.expiry
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("gage FillRouter"),
                keccak256("1"),
                uint256(4663),
                0x1111111111111111111111111111111111111111
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        assertEq(digest, 0xc99380c9b6efd72752e20e4c64ab5df1b82741b62b18af73e5f5544b7764b589, "the service's digest");
        bytes memory sig =
            hex"aa29a9e0a777303f2aaaa484ae26d96a04087f7beebd6576f1a2b486135b064a0d3944180494ddd8178df38b1a96f4be71034b7133132f222f8261e1d9408b641c";
        assertEq(ECDSA.recover(digest, sig), vm.addr(1), "the service's signature recovers to its key");
        // The router's own domain differs only by chain and address, so its digest is the same construction.
        (, string memory name, string memory version,,,,) = router.eip712Domain();
        assertEq(name, "gage FillRouter");
        assertEq(version, "1");
        bytes32 live = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(router)
            )
        );
        assertEq(router.quoteHash(q), keccak256(abi.encodePacked("\x19\x01", live, structHash)));
    }

    // ---------------------------------------------------------------- the mandate still rules

    function testTheStrategyRefusesAQuotedListingOutsideItsMandateOrWhilePaused() public {
        _deposit(alice, 10_000e6);
        uint256 id = _listed(1000e6);
        _aged(id);
        vm.prank(curator);
        earn.setLaneWeight(EarnLane.STOCK, 0);
        FillRouter.Quote memory q = _quote(id);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(filler);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        router.fill(q, 1, MAX, sig);
        vm.prank(curator);
        earn.setLaneWeight(EarnLane.STOCK, 6000);
        vm.prank(curator);
        earn.setPaused(true);
        vm.prank(filler);
        vm.expectRevert(EarnVault.PausedError.selector);
        router.fill(q, 1, MAX, sig);
        vm.prank(curator);
        earn.setPaused(false);
        vm.prank(filler);
        router.fill(q, 1, MAX, sig);
    }

    // ---------------------------------------------------------------- the reserve

    function testOnlyTheCuratorOrAFillerThroughTheRouterInvestsTheReserve() public {
        _deposit(alice, 10_000e6);
        vm.prank(stranger);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.investReserve(1000e6, 0);
        vm.prank(stranger);
        vm.expectRevert(FillRouter.NotFiller.selector);
        router.investReserve(address(earn), 1000e6, 0);
        vm.prank(filler);
        vm.expectRevert(FillRouter.NotAVault.selector);
        router.investReserve(stranger, 1000e6, 0);
        vm.prank(filler);
        router.investReserve(address(earn), 1000e6, 0);
        assertEq(earn.cash(), 9000e6);
        vm.prank(curator);
        earn.investReserve(1000e6, 0);
        assertEq(earn.cash(), 8000e6);
    }

    // ---------------------------------------------------------------- the factory's switches

    function testTheFactorySwitchesAreTheOwnersAndEmit() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFillRouter(address(router));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setQuoteSigner(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setPublicFill(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.setFiller(stranger, true);
        vm.stopPrank();
        vm.expectEmit(true, true, true, true, address(factory));
        emit EarnFactory.QuoteSignerSet(stranger);
        factory.setQuoteSigner(stranger);
        vm.expectEmit(true, true, true, true, address(factory));
        emit EarnFactory.PublicFillSet(true);
        factory.setPublicFill(true);
        vm.expectEmit(true, true, true, true, address(factory));
        emit EarnFactory.FillerSet(stranger, true);
        factory.setFiller(stranger, true);
        vm.expectRevert(EarnFactory.InvalidConfiguration.selector);
        factory.setFiller(address(0), true);
        vm.expectEmit(true, true, true, true, address(factory));
        emit EarnFactory.FillRouterSet(address(0));
        factory.setFillRouter(address(0));
        assertEq(address(router.FACTORY()), address(factory));
        assertEq(address(router.CORE()), address(core));
        vm.expectRevert(FillRouter.InvalidConfiguration.selector);
        new FillRouter(EarnFactory(stranger));
    }
}
