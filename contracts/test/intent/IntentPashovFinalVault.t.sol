// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";

/// @notice Pashov I-02: the rounding directions IntentFeeMath's header states, pinned on the functions themselves. The
/// two minimums round up to the next raw unit, toward the vault; every fee calculation rounds down.
contract IntentPashovFinalFeeMathTest is Test {
    uint256 internal constant BPS = 10_000;

    function testFuzz_TheMinimumsRoundUpAndEveryFeeRoundsDown(
        uint128 amount,
        uint16 annualBps,
        uint32 remaining,
        uint16 capBps,
        uint16 managerBps,
        uint128 executionFee
    ) public pure {
        uint256 year = BPS * 365 days;
        uint256 annual = bound(annualBps, 0, BPS);
        uint256 left = bound(remaining, 0, 365 days);
        // `secondaryMinimum`: the least raw unit at or above `amount * annual * left / (BPS * 365 days)`.
        uint256 minimum = IntentFeeMath.secondaryMinimum(amount, annual, left);
        uint256 exact = uint256(amount) * annual * left;
        assertGe(minimum * year, exact, "secondaryMinimum rounds up");
        if (minimum != 0) assertLt((minimum - 1) * year, exact, "by less than one raw unit");
        // `minimumInterest`: the least raw unit at or above the grade's share of the modeled cost (grade C, 75%).
        uint256 interest = IntentFeeMath.minimumInterest(amount, annual, 2);
        assertGe(interest * BPS * 100, uint256(amount) * annual * 75, "minimumInterest rounds up");
        if (interest != 0) assertLt((interest - 1) * BPS * 100, uint256(amount) * annual * 75);
        // `executionCap` and `performanceFee`: the greatest raw unit at or below the exact value.
        uint256 cap = bound(capBps, 0, IntentFeeMath.MAX_EXECUTION_CAP_BPS);
        uint256 ceiling = IntentFeeMath.executionCap(amount, cap);
        assertLe(ceiling * BPS, uint256(amount) * cap, "executionCap rounds down");
        assertGt((ceiling + 1) * BPS, uint256(amount) * cap);
        uint256 fee = bound(executionFee, 0, amount);
        uint256 rate = bound(managerBps, 500, 1500);
        uint256 performance = IntentFeeMath.performanceFee(amount, fee, rate);
        assertLe(performance * BPS, (amount - fee) * rate, "performanceFee rounds down");
        assertGt((performance + 1) * BPS, (amount - fee) * rate);
        // The protocol's part of a fee, as the vault takes it.
        uint256 share = performance * IntentFeeMath.PROTOCOL_SHARE_BPS / BPS;
        assertLe(share * BPS, performance * IntentFeeMath.PROTOCOL_SHARE_BPS, "the protocol's part rounds down");
        // `executionFee`: the rounded-down cap, or what the rounded-up minimum leaves; never past either bound.
        (bool ok, uint256 charged) = IntentFeeMath.executionFee(amount, minimum, cap);
        assertEq(ok, amount >= minimum);
        if (ok) {
            assertLe(charged, ceiling);
            assertLe(charged + minimum, amount);
        }
    }
}

/// @notice The accounting fixture, with a vault that buys existing positions and the steps of such a purchase.
abstract contract IntentPashovFinalBase is IntentAccountingBaseTest {
    /// @dev One whole unit of the lent asset.
    function _one() internal pure returns (uint256) {
        return 10 ** _cashDecimals();
    }

    /// @dev 100 NVDA for `principal`, repaid with `cap` within 21 days, listed without sGAGE rewards (a generation that
    /// lends another asset sets its own reward terms).
    function _listPlain(uint128 principal, uint128 cap) internal returns (uint256 id) {
        vm.prank(borrower);
        id = core.list(
            Collateral(Kind.ERC20, address(nvda), 100e18), principal, cap, T21, uint40(block.timestamp + 1 days), false
        );
    }

    /// @dev A vault on the fixture's factory that buys existing positions, asking no extra return, with 1,000 whole
    /// units deposited.
    function _secondaryVault() internal returns (IntentVault vault) {
        vm.prank(curator);
        vault = IntentVault(partnerFactory.create(mandate, true, 0, "Secondary buyer"));
        vm.startPrank(alice);
        usdg.approve(address(vault), MAX);
        vault.deposit(1000 * _one(), 0);
        vm.stopPrank();
    }

    /// @dev `fillers[0]` lends the whole of listing `id` on the core, activating it.
    function _lentByAWallet(uint256 id) internal {
        vm.prank(fillers[0]);
        core.fund(id, UNITS);
    }

    /// @dev `fillers[0]` offers the quarters `slots` of loan `id` for `price` until the loan's maturity.
    function _ask(uint256 id, uint8 slots, uint128 price) internal {
        // Read first: a prank binds to the very next external call, a view included.
        uint40 deadline = uint40(_maturity(id));
        vm.prank(fillers[0]);
        core.setLenderAsk(id, slots, price, deadline, 100);
    }

    /// @dev The fill router's purchase of `fillers[0]`'s ask: the vault pays the price to the router, which pays the
    /// core in the same transaction, and the quarters arrive in the vault.
    function _acquire(IntentVault vault, uint256 id, uint8 slots, uint128 price) internal {
        vm.prank(address(router));
        vault.purchase(id, slots, price, MAX, 0);
        V2LenderAsk memory ask = core.getLenderAsk(id, fillers[0]);
        address v = address(vault);
        uint128[4] memory none;
        vm.startPrank(address(router));
        usdg.approve(address(core), price);
        core.buyLenderSplit(id, V2LenderSplit(fillers[0], slots, price, ask.feeBps, ask.nonce, [v, v, v, v], none));
        vm.stopPrank();
    }
}

/// @notice Pashov's final findings on the vault, each pinned by the case that showed it.
contract IntentPashovFinalVaultTest is IntentPashovFinalBase {
    // ---------------------------------------------------------------- I-03

    /// @dev I-03: every deposit and redemption checkpoints each open record's reward claim, so the book holds at most
    /// 64 records (at 128, Pashov measured 27.79M gas steady and 34.43M with no claim ever made on the bridged core,
    /// against the chain's 32M per transaction). The 65th new record is refused; more quarters of a record the vault
    /// already holds open no record, so a full book still takes them.
    function testThe65thNewRecordIsRefusedWhileATopUpStillBuys() public {
        _enter(alice, 10_000e6);
        uint256[] memory ids = new uint256[](64);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
            _route(ids[i], 2);
        }
        uint256 next = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T7);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        router.fund(partner, next, UNITS, 0);
        _route(ids[0], 1);
        assertEq(_ln(ids[0]).principal, 75e6, "the top-up bought one more quarter");
        assertEq(partner.performingPrincipal(), 64 * 50e6 + 25e6);
    }

    // ---------------------------------------------------------------- L-04

    /// @dev The policy's refusal of a purchase, `IneligibleDeal`.
    function _refusedAsIneligible(uint256 id) internal {
        vm.prank(fillers[0]);
        vm.expectRevert(IntentAssetPolicy.IneligibleDeal.selector);
        router.fund(partner, id, UNITS, 0);
    }

    /// @dev L-04, Pashov's case: a seven-day listing of 1,000 USDG whose cap is 10^20 raw units. Funded through a
    /// compromised path, the vault would book the cap as interest and price it in as it accrued, for depositors to
    /// redeem against cash before the default. A purchase never books more interest than its principal: a cap past
    /// twice the principal is refused, and twice the principal exactly is still bought.
    function testAPurchaseNeverBooksMoreInterestThanItsPrincipal() public {
        _enter(alice, 10_000e6);
        _refusedAsIneligible(_list(borrower, address(nvda), 1e18, 1000e6, 1e20, T7));
        _refusedAsIneligible(_list(borrower, address(nvda), 1e18, 1000e6, 2000e6 + 1, T21));
        assertEq(partner.performingPrincipal(), 0);
        uint256 id = _list(borrower, address(nvda), 1e18, 1000e6, 2000e6, T21);
        _route(id, UNITS);
        assertEq(_ln(id).principal, 1000e6);
        assertEq(_ln(id).interest, 900e6, "the whole 1,000 of interest, less the 10% fee");
    }

    /// @dev L-04 for a bought position, whose principal is its price: what its quarters repay may be at most twice it.
    function testABoughtPositionNeverBooksMoreInterestThanItsPrice() public {
        IntentVault buyer = _secondaryVault();
        uint256 id = _list(borrower, address(nvda), 1e18, 1000e6, 1100e6, T21);
        _lentByAWallet(id);
        // The four quarters repay 1,100: at 549.99 they would book more than their price as interest.
        _ask(id, 15, 549.99e6);
        vm.prank(address(router));
        vm.expectRevert(IntentAssetPolicy.IneligibleDeal.selector);
        buyer.purchase(id, 15, 549.99e6, MAX, 0);
        _ask(id, 15, 550e6);
        _acquire(buyer, id, 15, 550e6);
        (,,,,,,,,, uint128 principal,, uint128 interest,,,,) = buyer.loans(id);
        assertEq(principal, 550e6);
        assertEq(interest, 495e6, "550 of interest, less the 10% fee");
    }

    // ---------------------------------------------------------------- I-01

    address internal donor = makeAddr("donor");

    /// @dev `donor` holds `amount` USDG, approved to the vault.
    function _donor(uint256 amount) internal {
        usdg.mint(donor, amount);
        vm.prank(donor);
        usdg.approve(address(partner), MAX);
    }

    /// @dev I-01: backing is added only while the curator has paused the vault, which closes deposits; exits stay
    /// open, so the holders already in take it. (Paused, an impaired vault can still be recapitalized:
    /// IntentMediumFixes.)
    function testRecapitalizeOnlyWhilePaused() public {
        _enter(alice, 1000e6);
        _donor(100e6);
        vm.prank(donor);
        vm.expectRevert(IntentVault.NotPaused.selector);
        partner.recapitalize(100e6);
        vm.prank(curator);
        partner.setPaused(true);
        uint256 supply = partner.totalSupply();
        vm.prank(donor);
        partner.recapitalize(100e6);
        assertEq(partner.totalSupply(), supply, "no share minted");
        assertEq(partner.totalAssets(), 1100e6);
        assertApproxEqAbs(_exitAll(alice), 1100e6, 1, "the holder took the backing");
    }

    /// @dev I-01, Pashov's sandwich: an attacker enters just ahead of the recapitalization and leaves just after it
    /// with part of it. On an open vault the recapitalization is refused, so the round trip gains nothing; paused, the
    /// vault refuses the entry, the backing stays with the holders already in, and an entrant after it is priced with
    /// it.
    function testARecapitalizationCannotBeSandwiched() public {
        _enter(alice, 1000e6);
        _donor(2000e6);
        uint256 shares = _enter(bob, 100_000e6);
        vm.prank(donor);
        vm.expectRevert(IntentVault.NotPaused.selector);
        partner.recapitalize(1000e6);
        assertLe(_exit(bob, shares), 100_000e6, "the attacker took part of the backing");
        vm.prank(curator);
        partner.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(IntentVault.PausedError.selector);
        partner.deposit(100_000e6, 0);
        vm.prank(donor);
        partner.recapitalize(1000e6);
        vm.prank(curator);
        partner.setPaused(false);
        shares = _enter(bob, 100_000e6);
        assertLe(_exit(bob, shares), 100_000e6, "the late entrant took part of the backing");
        assertApproxEqAbs(_exitAll(alice), 2000e6, 2, "the holder kept all of it");
    }

    // ---------------------------------------------------------------- L-01

    /// @dev The vault's own market, with bob approved to buy from it.
    function _market() internal returns (IntentLenderMarket market) {
        market = partner.LENDER_MARKET();
        vm.prank(bob);
        usdg.approve(address(market), MAX);
    }

    /// @dev The curator lists the vault's whole holding of `id` for `price` until the loan's maturity.
    function _offer(IntentLenderMarket market, uint256 id, uint128 price) internal returns (uint64 nonce) {
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        market.list(id, price, deadline, 100);
        nonce = market.nonces(id);
    }

    /// @dev Bob buys the listing, every quarter to himself.
    function _buyAll(IntentLenderMarket market, uint256 id, uint64 nonce, uint128 price) internal {
        uint128[4] memory none;
        vm.prank(bob);
        market.buySplit(id, nonce, price, [bob, bob, bob, bob], none);
    }

    /// @dev The listing price at which a sale of a review loan bought with no execution fee books exactly `net`: the
    /// core's 1% trade fee comes off the price, then the 10% manager fee off the profit over the principal.
    function _priceForNet(uint256 net) internal pure returns (uint128) {
        uint256 kept = net - REVIEW_PRINCIPAL;
        uint256 profit = kept * 10 / 9;
        profit = profit > 3 ? profit - 3 : 0;
        while (profit - profit / 10 < kept) {
            ++profit;
        }
        require(profit - profit / 10 == kept, "no exact profit");
        uint256 proceeds = REVIEW_PRINCIPAL + profit;
        uint256 guess = proceeds * 100 / 99;
        for (uint256 price = guess - 3; price <= guess + 3; ++price) {
            if (price - price / 100 == proceeds) return uint128(price);
        }
        revert("no exact price");
    }

    /// @dev L-01, Pashov's case: one second into the term the curator lists the vault's whole position at book value
    /// for a buyer it controls (another of its vaults; to the seller any buyer is the same), which would hand the buyer
    /// the whole interest still to come. The seller's holders now keep at least half of it, so the sale reverts.
    function testASaleAtBookOneSecondIntoTheTermIsRefused() public {
        IntentLenderMarket market = _market();
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 1);
        uint128 price = _priceForNet(REVIEW_PRINCIPAL + partner.accruedInterest());
        uint64 nonce = _offer(market, id, price);
        uint256 assets = partner.totalAssets();
        uint128[4] memory none;
        vm.prank(bob);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        market.buySplit(id, nonce, price, [bob, bob, bob, bob], none);
        address[4] memory lenders = core.lenders(id);
        for (uint8 i; i < 4; ++i) {
            assertEq(lenders[i], address(partner), "the vault still holds the loan");
        }
        assertEq(partner.totalAssets(), assets);
    }

    /// @dev L-01: at the floor exactly, book plus half of the interest still to come, the sale goes through, and what
    /// it books above book is the holders' earnings claim (D51): they keep what the position earned and half of the
    /// rest. One raw unit under the floor, the sale reverts.
    function testASaleKeepsHalfOfTheInterestStillToCome() public {
        IntentLenderMarket market = _market();
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_startOf(id) + 3 days);
        uint256 earned = partner.accruedInterest();
        uint256 remaining = _ln(id).interest - earned;
        uint256 floor = REVIEW_PRINCIPAL + earned + remaining / 2;
        uint128 under = _priceForNet(floor - 1);
        uint64 nonce = _offer(market, id, under);
        uint128[4] memory none;
        vm.prank(bob);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        market.buySplit(id, nonce, under, [bob, bob, bob, bob], none);
        uint128 price = _priceForNet(floor);
        nonce = _offer(market, id, price);
        uint256 assets = partner.totalAssets();
        _buyAll(market, id, nonce, price);
        assertEq(partner.pocketLiability(address(usdg)), remaining / 2, "half the rest is the holders' claim");
        assertApproxEqAbs(partner.totalAssets(), assets, 1, "the sale never lowers the share price");
        assertApproxEqAbs(_leave(alice), 10_000e6 + earned + remaining / 2, 2, "earned and half the rest");
    }

    /// @dev L-01 near maturity: almost nothing is still to come, so the floor is book plus a few raw units, and the
    /// sale books its gain above book as the holders' claim as before.
    function testNearMaturityTheFloorIsBookPlusAFewRawUnits() public {
        IntentLenderMarket market = _market();
        _enter(alice, 10_000e6);
        uint256 id = _reviewLoan();
        vm.warp(_maturity(id) - 1);
        uint256 earned = partner.accruedInterest();
        uint256 remaining = _ln(id).interest - earned;
        assertLt(remaining, 100, "less than a ten-thousandth of a USDG still to come");
        uint128 price = _priceForNet(REVIEW_PRINCIPAL + earned + remaining / 2);
        _buyAll(market, id, _offer(market, id, price), price);
        assertEq(partner.performingPrincipal(), 0);
        assertEq(partner.pocketLiability(address(usdg)), remaining / 2);
        assertApproxEqAbs(_leave(alice), 10_000e6 + earned + remaining / 2, 2);
    }
}

/// @notice Pashov I-04 at the lent asset's decimals: a purchase that opens a record carries at least one whole unit of
/// a six-decimal asset (1 USDG) and a tenth of one of an asset with more decimals (0.1 GLD), so dust purchases cannot
/// fill the book of open records. More quarters of a record already held are taken at any size.
abstract contract IntentPashovFinalDustTest is IntentPashovFinalBase {
    /// @dev The least a purchase that opens a record carries.
    function _floor() internal pure returns (uint256) {
        return _cashDecimals() == 6 ? _one() : _one() / 10;
    }

    function _refusedAsDust(uint256 id, uint8 units) internal {
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        router.fund(partner, id, units, 0);
    }

    function testDustFundingOpensNoRecord() public {
        _enter(alice, 1000 * _one());
        // The core's smallest listing, four raw units, one a quarter.
        _refusedAsDust(_listPlain(4, 4), UNITS);
        // One raw unit short of the floor.
        _refusedAsDust(_listPlain(uint128(_floor() - 1), uint128(_floor() - 1)), UNITS);
        assertEq(partner.performingPrincipal(), 0);
        // Exactly the floor opens a record.
        uint256 id = _listPlain(uint128(_floor()), uint128(_floor() * 11 / 10));
        _route(id, UNITS);
        assertEq(_ln(id).principal, _floor());
        assertEq(partner.performingPrincipal(), _floor());
    }

    /// @dev Two floors in four quarters: one quarter alone opens no record, two open it with one floor, and a third
    /// quarter, half a floor, tops it up.
    function testATopUpOfAHeldRecordTakesAnySize() public {
        _enter(alice, 1000 * _one());
        uint256 id = _listPlain(uint128(2 * _floor()), uint128(2 * _floor()));
        _refusedAsDust(id, 1);
        _route(id, 2);
        _route(id, 1);
        assertEq(_ln(id).principal, 3 * _floor() / 2);
    }

    /// @dev A bought position's principal is its price: under the floor it opens no record either.
    function testADustBoughtPositionOpensNoRecord() public {
        IntentVault buyer = _secondaryVault();
        // A wallet lends four floors (4.4 back), then offers one quarter, one floor repaying 1.1.
        uint256 id = _listPlain(uint128(4 * _floor()), uint128(44 * _floor() / 10));
        _lentByAWallet(id);
        _ask(id, 1, uint128(_floor() - 1));
        vm.prank(address(router));
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        buyer.purchase(id, 1, _floor() - 1, MAX, 0);
        _ask(id, 1, uint128(_floor()));
        _acquire(buyer, id, 1, uint128(_floor()));
        assertEq(core.lenders(id)[0], address(buyer));
        (,,,,,,,,, uint128 principal,,,,,,) = buyer.loans(id);
        assertEq(principal, _floor());
    }
}

contract IntentPashovFinalDustSixTest is IntentPashovFinalDustTest {}

contract IntentPashovFinalDustEighteenTest is IntentPashovFinalDustTest {
    function _cashDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
