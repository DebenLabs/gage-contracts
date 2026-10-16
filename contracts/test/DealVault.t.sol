// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {BaseTest} from "./Base.t.sol";
import {DealVault} from "../src/DealVault.sol";
import {IDealVault, DealState, Deal, BidState, Bid} from "../src/interfaces/IDealVault.sol";
import {ICollateralRegistry, Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {ERC20Adapter} from "../src/libraries/ERC20Adapter.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DealVaultTest is BaseTest {
    uint256 internal constant AMOUNT = 100e18;
    uint128 internal constant CAP = 8000e6;
    uint128 internal constant PRICE = 7960e6;

    // ================================================================= constructor

    function test_constructor_setsImmutables() public view {
        assertEq(address(vault.USDG()), address(usdg));
        assertEq(address(vault.REGISTRY()), address(registry));
        assertEq(vault.FEE_SINK(), address(feeSink));
        assertEq(vault.POSITION_MANAGER(), address(0));
        assertEq(vault.GRACE(), GRACE);
        assertEq(vault.MIN_GRACE(), 24 hours);
        assertEq(vault.MAX_LISTING_EXPIRY(), 7 days);
        assertEq(vault.MAX_FEE_BPS(), 200);
    }

    function test_constructor_revertsGraceBelowMinimum() public {
        vm.expectRevert(
            abi.encodeWithSelector(IDealVault.GraceBelowMinimum.selector, uint48(24 hours - 1), uint48(24 hours))
        );
        new DealVault(usdg, registry, address(feeSink), address(0), 24 hours - 1);
    }

    function test_constructor_acceptsMinimumGrace() public {
        DealVault v = new DealVault(usdg, registry, address(feeSink), address(0), 24 hours);
        assertEq(v.GRACE(), 24 hours);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert(IDealVault.ZeroAddress.selector);
        new DealVault(IERC20(address(0)), registry, address(feeSink), address(0), GRACE);
        vm.expectRevert(IDealVault.ZeroAddress.selector);
        new DealVault(usdg, ICollateralRegistry(address(0)), address(feeSink), address(0), GRACE);
        vm.expectRevert(IDealVault.ZeroAddress.selector);
        new DealVault(usdg, registry, address(0), address(0), GRACE);
    }

    // ================================================================= list

    function test_list_escrowsCollateralAndEmits() public {
        uint40 le = _listingExpiry();
        vm.expectEmit(address(vault));
        emit IDealVault.Listed(1, borrower, Kind.ERC20, address(nvda), AMOUNT, CAP, T7, le, 0);
        vm.prank(borrower);
        uint256 dealId = vault.list(_collateral(address(nvda), AMOUNT), CAP, T7, le, 0);

        assertEq(dealId, 1);
        assertEq(vault.dealCount(), 1);
        Deal memory d = vault.getDeal(dealId);
        assertEq(d.borrower, borrower);
        assertEq(uint8(d.kind), uint8(Kind.ERC20));
        assertEq(uint8(d.state), uint8(DealState.LISTED));
        assertEq(d.term, T7);
        assertEq(d.listingExpiry, le);
        assertEq(d.token, address(nvda));
        assertEq(d.amountOrTokenId, AMOUNT);
        assertEq(d.cap, CAP);
        assertEq(d.minPrice, 0);
        assertEq(d.lender, address(0));
        assertEq(d.price, 0);
        assertEq(d.fundedAt, 0);
        assertEq(d.expiry, 0);
        assertEq(nvda.balanceOf(address(vault)), AMOUNT);
        assertEq(nvda.balanceOf(borrower), 10_000e18 - AMOUNT);
        assertEq(vault.openRaw(address(nvda)), AMOUNT);
    }

    function test_list_storesMinPrice() public {
        uint256 id = _list(borrower, address(nvda), AMOUNT, CAP, T21, 7000e6);
        Deal memory d = vault.getDeal(id);
        assertEq(d.minPrice, 7000e6);
        assertEq(d.term, T21);
    }

    function test_list_revertsWhenPaused() public {
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        _listDefault();
    }

    function test_list_revertsZeroCap() public {
        vm.expectRevert(IDealVault.InvalidCap.selector);
        _list(borrower, address(nvda), AMOUNT, 0, T7, 0);
    }

    function test_list_revertsMinPriceAboveCap() public {
        vm.expectRevert(IDealVault.InvalidMinPrice.selector);
        _list(borrower, address(nvda), AMOUNT, CAP, T7, CAP + 1);
    }

    function test_list_revertsTermNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(IDealVault.TermNotAllowed.selector, uint32(14 days)));
        _list(borrower, address(nvda), AMOUNT, CAP, 14 days, 0);
    }

    function test_list_revertsListingExpiryNotInFuture() public {
        vm.expectRevert(IDealVault.InvalidListingExpiry.selector);
        vm.prank(borrower);
        vault.list(_collateral(address(nvda), AMOUNT), CAP, T7, uint40(block.timestamp), 0);
    }

    function test_list_revertsListingExpiryTooFar() public {
        vm.expectRevert(IDealVault.InvalidListingExpiry.selector);
        vm.prank(borrower);
        vault.list(_collateral(address(nvda), AMOUNT), CAP, T7, uint40(block.timestamp + 7 days + 1), 0);
    }

    function test_list_acceptsMaxListingExpiry() public {
        vm.prank(borrower);
        uint256 id = vault.list(_collateral(address(nvda), AMOUNT), CAP, T7, uint40(block.timestamp + 7 days), 0);
        assertEq(vault.getDeal(id).listingExpiry, block.timestamp + 7 days);
    }

    function test_list_revertsTokenNotAllowed() public {
        MockERC20 x = new MockERC20("Unlisted", "X", 18);
        x.mint(borrower, 1e18);
        vm.prank(borrower);
        x.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ERC20Adapter.TokenNotAllowed.selector, address(x)));
        _list(borrower, address(x), 1e18, CAP, T7, 0);
    }

    function test_list_revertsAfterTokenDelisted() public {
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ERC20Adapter.TokenNotAllowed.selector, address(nvda)));
        _listDefault();
    }

    function test_list_revertsBelowMinimum() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Adapter.BelowMinimum.selector, address(nvda), NVDA_MIN - 1, NVDA_MIN)
        );
        _list(borrower, address(nvda), NVDA_MIN - 1, CAP, T7, 0);
    }

    function test_list_revertsAboveDealMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Adapter.AboveDealMax.selector, address(nvda), NVDA_MAX_DEAL + 1, NVDA_MAX_DEAL)
        );
        _list(borrower, address(nvda), NVDA_MAX_DEAL + 1, CAP, T7, 0);
    }

    function test_list_revertsOpenCapExceeded() public {
        for (uint256 i = 0; i < 5; ++i) {
            _list(borrower, address(nvda), 1000e18, CAP, T7, 0);
        }
        assertEq(vault.openRaw(address(nvda)), NVDA_MAX_OPEN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Adapter.OpenCapExceeded.selector, address(nvda), NVDA_MAX_OPEN, 1e18, NVDA_MAX_OPEN
            )
        );
        _list(borrower, address(nvda), 1e18, CAP, T7, 0);
    }

    function test_list_openCapIsPerAsset() public {
        for (uint256 i = 0; i < 5; ++i) {
            _list(borrower, address(nvda), 1000e18, CAP, T7, 0);
        }
        uint256 id = _list(borrower, address(aapl), 1000e18, CAP, T7, 0);
        assertEq(vault.getDeal(id).token, address(aapl));
    }

    function test_list_openCapFreesOnCancel() public {
        uint256 first = _list(borrower, address(nvda), 1000e18, CAP, T7, 0);
        for (uint256 i = 0; i < 4; ++i) {
            _list(borrower, address(nvda), 1000e18, CAP, T7, 0);
        }
        vm.prank(borrower);
        vault.cancel(first);
        assertEq(vault.openRaw(address(nvda)), 4000e18);
        _list(borrower, address(nvda), 1000e18, CAP, T7, 0);
        assertEq(vault.openRaw(address(nvda)), 5000e18);
    }

    function test_list_revertsFeeOnTransferToken() public {
        vm.prank(safe);
        registry.setERC20Allowed(address(feeToken), true, Lane.STOCK, 1e18, 1000e18, 5000e18);
        vm.expectRevert(abi.encodeWithSelector(ERC20Adapter.TransferAmountMismatch.selector, AMOUNT, 99e18));
        _list(borrower, address(feeToken), AMOUNT, CAP, T7, 0);
    }

    function test_list_revertsWithoutApproval() public {
        vm.prank(borrower);
        nvda.approve(address(vault), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, AMOUNT)
        );
        _listDefault();
    }

    function test_list_revertsPositionKindWithoutPositionManager() public {
        Collateral memory c = Collateral({kind: Kind.UNIV4_POSITION, token: address(0xBEEF), amountOrTokenId: 1});
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vm.prank(borrower);
        vault.list(c, CAP, T7, _listingExpiry(), 0);
    }

    function test_list_revertsPositionKindWrongNFTContract() public {
        DealVault v = new DealVault(usdg, registry, address(feeSink), address(0xBEEF), GRACE);
        Collateral memory c = Collateral({kind: Kind.UNIV4_POSITION, token: address(0xCAFE), amountOrTokenId: 1});
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vm.prank(borrower);
        v.list(c, CAP, T7, _listingExpiry(), 0);
    }

    // ================================================================= cancel

    function test_cancel_creditsBorrowerAndEmits() public {
        uint256 id = _listDefault();
        vm.expectEmit(address(vault));
        emit IDealVault.Cancelled(id);
        vm.prank(borrower);
        vault.cancel(id);

        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.CANCELLED));
        assertEq(vault.balanceERC20(borrower, address(nvda)), AMOUNT);
        assertEq(vault.openRaw(address(nvda)), 0);
        assertEq(nvda.balanceOf(address(vault)), AMOUNT, "stays until withdrawn");

        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
        assertEq(nvda.balanceOf(borrower), 10_000e18);
        assertEq(nvda.balanceOf(address(vault)), 0);
    }

    function test_cancel_revertsNotBorrower() public {
        uint256 id = _listDefault();
        vm.expectRevert(IDealVault.NotBorrower.selector);
        vm.prank(other);
        vault.cancel(id);
    }

    function test_cancel_revertsNotListed() public {
        (uint256 funded,) = _fundDeal();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, funded));
        vm.prank(borrower);
        vault.cancel(funded);

        uint256 id = _listDefault();
        vm.prank(borrower);
        vault.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, id));
        vm.prank(borrower);
        vault.cancel(id);

        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, 999));
        vm.prank(borrower);
        vault.cancel(999);
    }

    function test_cancel_leavesOpenBidsWithdrawable() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.prank(borrower);
        vault.cancel(id);
        vm.prank(lender);
        vault.withdrawBid(bidId);
        assertEq(vault.balanceUSDG(lender), PRICE);
    }

    function test_cancel_worksWhilePaused() public {
        uint256 id = _listDefault();
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.prank(borrower);
        vault.cancel(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.CANCELLED));
    }

    // ================================================================= bid

    function test_bid_escrowsUSDGAndEmits() public {
        uint256 id = _listDefault();
        uint40 exp = uint40(block.timestamp + 1 days);
        vm.expectEmit(address(vault));
        emit IDealVault.BidPlaced(1, id, lender, PRICE, exp);
        vm.prank(lender);
        uint256 bidId = vault.bid(id, PRICE, exp, lender);

        assertEq(bidId, 1);
        assertEq(vault.bidCount(), 1);
        Bid memory b = vault.getBid(bidId);
        assertEq(b.dealId, id);
        assertEq(b.lender, lender);
        assertEq(b.price, PRICE);
        assertEq(b.expiry, exp);
        assertEq(uint8(b.state), uint8(BidState.OPEN));
        assertEq(usdg.balanceOf(address(vault)), PRICE);
        assertEq(usdg.balanceOf(lender), 10_000_000e6 - PRICE);
    }

    function test_bid_multipleBidsOnOneDeal() public {
        uint256 id = _listDefault();
        _bid(lender, id, 7900e6);
        _bid(lender2, id, 7950e6);
        _bid(lender, id, 7960e6);
        assertEq(vault.bidCount(), 3);
        assertEq(usdg.balanceOf(address(vault)), 7900e6 + 7950e6 + 7960e6);
    }

    function test_bid_atCapAndAtMinPrice() public {
        uint256 id = _list(borrower, address(nvda), AMOUNT, CAP, T7, 7000e6);
        _bid(lender, id, CAP);
        _bid(lender2, id, 7000e6);
    }

    function test_bid_revertsWhenPaused() public {
        uint256 id = _listDefault();
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        _bid(lender, id, PRICE);
    }

    function test_bid_revertsNotListed() public {
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, 999));
        _bid(lender, 999, PRICE);

        uint256 id = _listDefault();
        vm.prank(borrower);
        vault.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, id));
        _bid(lender, id, PRICE);

        (uint256 funded,) = _fundDeal();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, funded));
        _bid(lender2, funded, PRICE);
    }

    function test_bid_revertsListingExpired() public {
        uint256 id = _listDefault();
        vm.warp(vault.getDeal(id).listingExpiry);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.ListingExpired.selector, id));
        _bid(lender, id, PRICE);
    }

    function test_bid_acceptedUntilTheLastSecond() public {
        uint256 id = _listDefault();
        uint40 le = vault.getDeal(id).listingExpiry;
        vm.warp(le - 1);
        vm.prank(lender);
        vault.bid(id, PRICE, le, lender);
    }

    function test_bid_revertsZeroPrice() public {
        uint256 id = _listDefault();
        vm.expectRevert(IDealVault.ZeroPrice.selector);
        _bid(lender, id, 0);
    }

    function test_bid_revertsAboveCap() public {
        uint256 id = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.PriceAboveCap.selector, CAP + 1, CAP));
        _bid(lender, id, CAP + 1);
    }

    function test_bid_revertsBelowMinPrice() public {
        uint256 id = _list(borrower, address(nvda), AMOUNT, CAP, T7, 7000e6);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.PriceBelowMin.selector, 7000e6 - 1, 7000e6));
        _bid(lender, id, 7000e6 - 1);
    }

    function test_bid_revertsBidExpiryAfterListingExpiry() public {
        uint256 id = _listDefault();
        uint40 le = vault.getDeal(id).listingExpiry;
        vm.expectRevert(IDealVault.InvalidBidExpiry.selector);
        vm.prank(lender);
        vault.bid(id, PRICE, le + 1, lender);
    }

    function test_bid_revertsBidExpiryNotInFuture() public {
        uint256 id = _listDefault();
        vm.expectRevert(IDealVault.InvalidBidExpiry.selector);
        vm.prank(lender);
        vault.bid(id, PRICE, uint40(block.timestamp), lender);
    }

    function test_bid_revertsUnauthorizedLender() public {
        uint256 id = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.UnauthorizedLender.selector, other, lender));
        vm.prank(other);
        vault.bid(id, PRICE, uint40(block.timestamp + 1 days), lender);
    }

    function test_bid_routerMayBidForAnotherLender() public {
        uint256 id = _listDefault();
        vm.prank(safe);
        registry.setRouter(other, true);
        vm.prank(other);
        uint256 bidId = vault.bid(id, PRICE, uint40(block.timestamp + 1 days), lender);

        Bid memory b = vault.getBid(bidId);
        assertEq(b.lender, lender);
        assertEq(usdg.balanceOf(other), 10_000_000e6 - PRICE, "router paid");

        vm.prank(lender);
        vault.withdrawBid(bidId);
        assertEq(vault.balanceUSDG(lender), PRICE, "lender is credited");
    }

    function test_bid_routerRevertsZeroLender() public {
        uint256 id = _listDefault();
        vm.prank(safe);
        registry.setRouter(other, true);
        vm.expectRevert(IDealVault.ZeroAddress.selector);
        vm.prank(other);
        vault.bid(id, PRICE, uint40(block.timestamp + 1 days), address(0));
    }

    function test_bid_revertsWithoutUSDG() public {
        uint256 id = _listDefault();
        uint256 all = usdg.balanceOf(lender);
        vm.prank(lender);
        usdg.transfer(other, all);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, lender, 0, PRICE));
        _bid(lender, id, PRICE);
    }

    // ================================================================= withdrawBid

    function test_withdrawBid_creditsLenderAndEmits() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.expectEmit(address(vault));
        emit IDealVault.BidWithdrawn(bidId);
        vm.prank(lender);
        vault.withdrawBid(bidId);

        assertEq(uint8(vault.getBid(bidId).state), uint8(BidState.WITHDRAWN));
        assertEq(vault.balanceUSDG(lender), PRICE);
        assertEq(usdg.balanceOf(address(vault)), PRICE, "stays until withdrawn");
    }

    function test_withdrawBid_revertsNotLender() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.expectRevert(IDealVault.NotLender.selector);
        vm.prank(other);
        vault.withdrawBid(bidId);
    }

    function test_withdrawBid_revertsNotOpen() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.prank(lender);
        vault.withdrawBid(bidId);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.BidNotOpen.selector, bidId));
        vm.prank(lender);
        vault.withdrawBid(bidId);

        vm.expectRevert(abi.encodeWithSelector(IDealVault.BidNotOpen.selector, 999));
        vm.prank(lender);
        vault.withdrawBid(999);
    }

    function test_withdrawBid_acceptedBidCannotBeWithdrawn() public {
        (, uint256 bidId) = _fundDeal();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.BidNotOpen.selector, bidId));
        vm.prank(lender);
        vault.withdrawBid(bidId);
    }

    function test_withdrawBid_losingBidWithdrawableAfterFunding() public {
        uint256 id = _listDefault();
        uint256 winning = _bid(lender, id, PRICE);
        uint256 losing = _bid(lender2, id, 7900e6);
        vm.prank(borrower);
        vault.accept(id, winning);
        vm.prank(lender2);
        vault.withdrawBid(losing);
        assertEq(vault.balanceUSDG(lender2), 7900e6);
    }

    function test_withdrawBid_worksAfterListingExpiryAndWhilePaused() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.warp(block.timestamp + 30 days);
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.prank(lender);
        vault.withdrawBid(bidId);
        assertEq(vault.balanceUSDG(lender), PRICE);
    }

    // ================================================================= accept

    function test_accept_fundsDealAtomically() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        uint128 fee = _fee(PRICE);
        uint40 now_ = uint40(block.timestamp);

        vm.expectEmit(address(vault));
        emit IDealVault.Funded(id, bidId, lender, PRICE, fee, now_, now_ + T7);
        vm.prank(borrower);
        vault.accept(id, bidId);

        Deal memory d = vault.getDeal(id);
        assertEq(uint8(d.state), uint8(DealState.FUNDED));
        assertEq(d.lender, lender);
        assertEq(d.price, PRICE);
        assertEq(d.fee, fee);
        assertEq(d.fundedAt, now_);
        assertEq(d.expiry, now_ + T7);
        assertEq(uint8(vault.getBid(bidId).state), uint8(BidState.ACCEPTED));
        assertEq(vault.balanceUSDG(borrower), PRICE - fee);
        assertEq(vault.balanceUSDG(address(feeSink)), fee);
        assertEq(vault.claimableAt(id), now_ + T7 + GRACE);
        assertEq(usdg.balanceOf(address(vault)), PRICE, "no USDG moved");
        assertEq(fee, 39_800_000, "0.50% of 7,960 USDG");
    }

    function test_accept_21DayTerm() public {
        uint256 id = _list(borrower, address(nvda), AMOUNT, CAP, T21, 0);
        uint256 bidId = _bid(lender, id, PRICE);
        vm.prank(borrower);
        vault.accept(id, bidId);
        assertEq(vault.getDeal(id).expiry, block.timestamp + T21);
    }

    function test_accept_zeroFee() public {
        vm.prank(safe);
        registry.setFee(0);
        (uint256 id,) = _fundDeal();
        assertEq(vault.balanceUSDG(borrower), PRICE);
        assertEq(vault.balanceUSDG(address(feeSink)), 0);
        assertEq(vault.getDeal(id).price, PRICE);
    }

    function test_accept_maxFee() public {
        vm.prank(safe);
        registry.setFee(200);
        _fundDeal();
        assertEq(vault.balanceUSDG(address(feeSink)), (uint256(PRICE) * 200) / 10_000);
    }

    function test_accept_feeRoundsDown() public {
        uint256 id = _list(borrower, address(nvda), AMOUNT, 2_000_001, T7, 0);
        uint256 bidId = _bid(lender, id, 1_000_001);
        vm.prank(borrower);
        vault.accept(id, bidId);
        // 1,000,001 * 50 / 10,000 = 5,000.005 -> 5,000
        assertEq(vault.balanceUSDG(address(feeSink)), 5000);
        assertEq(vault.balanceUSDG(borrower), 1_000_001 - 5000);
    }

    function test_accept_revertsWhenPaused() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        vm.prank(borrower);
        vault.accept(id, bidId);
    }

    function test_accept_revertsNotBorrower() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.expectRevert(IDealVault.NotBorrower.selector);
        vm.prank(lender);
        vault.accept(id, bidId);
    }

    function test_accept_revertsNotListed() public {
        (uint256 id, uint256 bidId) = _fundDeal();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, id));
        vm.prank(borrower);
        vault.accept(id, bidId);
    }

    function test_accept_revertsBidDealMismatch() public {
        uint256 a = _listDefault();
        uint256 b = _listDefault();
        uint256 bidOnB = _bid(lender, b, PRICE);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.BidDealMismatch.selector, bidOnB, a));
        vm.prank(borrower);
        vault.accept(a, bidOnB);
    }

    function test_accept_revertsBidWithdrawn() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.prank(lender);
        vault.withdrawBid(bidId);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.BidNotOpen.selector, bidId));
        vm.prank(borrower);
        vault.accept(id, bidId);
    }

    function test_accept_revertsBidExpired() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.warp(vault.getBid(bidId).expiry);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.BidExpired.selector, bidId));
        vm.prank(borrower);
        vault.accept(id, bidId);
    }

    function test_accept_worksUntilLastSecondOfBid() public {
        uint256 id = _listDefault();
        uint256 bidId = _bid(lender, id, PRICE);
        vm.warp(vault.getBid(bidId).expiry - 1);
        vm.prank(borrower);
        vault.accept(id, bidId);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.FUNDED));
    }

    function test_accept_onlyOneBidPerDeal() public {
        uint256 id = _listDefault();
        uint256 first = _bid(lender, id, PRICE);
        uint256 second = _bid(lender2, id, CAP);
        vm.prank(borrower);
        vault.accept(id, first);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, id));
        vm.prank(borrower);
        vault.accept(id, second);
    }

    // ================================================================= reclaim

    function test_reclaim_earlyPaysCapAndReturnsCollateral() public {
        (uint256 id,) = _fundDeal();
        uint256 borrowerUSDG = usdg.balanceOf(borrower);

        vm.expectEmit(address(vault));
        emit IDealVault.Reclaimed(id);
        vm.prank(borrower);
        vault.reclaim(id);

        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
        assertEq(vault.balanceUSDG(lender), CAP, "exactly cap to the lender");
        assertEq(vault.balanceERC20(borrower, address(nvda)), AMOUNT);
        assertEq(vault.openRaw(address(nvda)), 0);
        assertEq(usdg.balanceOf(borrower), borrowerUSDG - CAP, "exactly cap from the borrower");
        assertEq(usdg.balanceOf(address(vault)), PRICE + CAP);
    }

    function test_reclaim_duringGrace() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id) - 1);
        vm.prank(borrower);
        vault.reclaim(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
    }

    function test_reclaim_afterGraceIfNotYetClaimed() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id) + 10 days);
        vm.prank(borrower);
        vault.reclaim(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
    }

    function test_reclaim_revertsNotBorrower() public {
        (uint256 id,) = _fundDeal();
        vm.expectRevert(IDealVault.NotBorrower.selector);
        vm.prank(lender);
        vault.reclaim(id);
    }

    function test_reclaim_revertsNotFunded() public {
        uint256 listed = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, listed));
        vm.prank(borrower);
        vault.reclaim(listed);

        (uint256 id,) = _fundDeal();
        vm.prank(borrower);
        vault.reclaim(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, id));
        vm.prank(borrower);
        vault.reclaim(id);
    }

    function test_reclaim_revertsAfterClaim() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, id));
        vm.prank(borrower);
        vault.reclaim(id);
    }

    function test_reclaim_revertsWithoutUSDG() public {
        (uint256 id,) = _fundDeal();
        uint256 all = usdg.balanceOf(borrower);
        vm.prank(borrower);
        usdg.transfer(other, all);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, borrower, 0, CAP));
        vm.prank(borrower);
        vault.reclaim(id);
    }

    function test_reclaim_worksWhilePaused() public {
        (uint256 id,) = _fundDeal();
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.prank(borrower);
        vault.reclaim(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
    }

    function test_reclaim_worksWhenLenderIsFrozen() public {
        (uint256 id,) = _fundDeal();
        usdg.setBlocked(lender, true);
        vm.prank(borrower);
        vault.reclaim(id);
        assertEq(vault.balanceUSDG(lender), CAP);

        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, lender));
        vm.prank(lender);
        vault.withdrawUSDG();

        usdg.setBlocked(lender, false);
        vm.prank(lender);
        vault.withdrawUSDG();
        assertEq(usdg.balanceOf(lender), 10_000_000e6 - PRICE + CAP);
    }

    // ================================================================= claim

    function test_claim_afterGraceCreditsLender() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id));
        vm.expectEmit(address(vault));
        emit IDealVault.Claimed(id);
        vm.prank(lender);
        vault.claim(id);

        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.CLAIMED));
        assertEq(vault.balanceERC20(lender, address(nvda)), AMOUNT);
        assertEq(vault.openRaw(address(nvda)), 0);
        assertEq(vault.balanceUSDG(lender), 0);
    }

    function test_claim_revertsBeforeGraceEnds() public {
        (uint256 id,) = _fundDeal();
        uint40 at = vault.claimableAt(id);
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, at));
        vm.prank(lender);
        vault.claim(id);
    }

    function test_claim_revertsAtExpiry() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.getDeal(id).expiry);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, vault.claimableAt(id)));
        vm.prank(lender);
        vault.claim(id);
    }

    function test_claim_revertsNotLender() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id));
        vm.expectRevert(IDealVault.NotLender.selector);
        vm.prank(borrower);
        vault.claim(id);
    }

    function test_claim_revertsNotFunded() public {
        uint256 listed = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, listed));
        vm.prank(lender);
        vault.claim(listed);
    }

    function test_claim_revertsAfterReclaim() public {
        (uint256 id,) = _fundDeal();
        vm.prank(borrower);
        vault.reclaim(id);
        vm.warp(vault.claimableAt(id));
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, id));
        vm.prank(lender);
        vault.claim(id);
    }

    function test_claim_revertsTwice() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, id));
        vm.prank(lender);
        vault.claim(id);
    }

    function test_claim_worksWhilePaused() public {
        (uint256 id,) = _fundDeal();
        vm.warp(vault.claimableAt(id));
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.prank(lender);
        vault.claim(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.CLAIMED));
    }

    function test_claimableAt_zeroForUnfunded() public {
        uint256 id = _listDefault();
        assertEq(vault.claimableAt(id), 0);
        assertEq(vault.claimableAt(999), 0);
    }

    // ================================================================= withdrawals

    function test_withdrawUSDG_transfersAndEmits() public {
        _fundDeal();
        uint256 owed = PRICE - _fee(PRICE);
        uint256 before = usdg.balanceOf(borrower);
        vm.expectEmit(address(vault));
        emit IDealVault.Withdrawn(borrower, address(usdg), owed);
        vm.prank(borrower);
        vault.withdrawUSDG();
        assertEq(vault.balanceUSDG(borrower), 0);
        assertEq(usdg.balanceOf(borrower), before + owed);
    }

    function test_withdrawUSDG_revertsNothing() public {
        vm.expectRevert(IDealVault.NothingToWithdraw.selector);
        vm.prank(other);
        vault.withdrawUSDG();
    }

    function test_withdrawUSDG_balancesAccumulateAcrossDeals() public {
        _fundDeal();
        _fundDeal();
        assertEq(vault.balanceUSDG(borrower), 2 * (PRICE - _fee(PRICE)));
        vm.prank(borrower);
        vault.withdrawUSDG();
        assertEq(vault.balanceUSDG(borrower), 0);
    }

    function test_withdrawERC20_transfersAndEmits() public {
        uint256 id = _listDefault();
        vm.prank(borrower);
        vault.cancel(id);
        vm.expectEmit(address(vault));
        emit IDealVault.Withdrawn(borrower, address(nvda), AMOUNT);
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
        assertEq(vault.balanceERC20(borrower, address(nvda)), 0);
        assertEq(nvda.balanceOf(borrower), 10_000e18);
    }

    function test_withdrawERC20_revertsNothing() public {
        vm.expectRevert(IDealVault.NothingToWithdraw.selector);
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
    }

    function test_withdrawCollateral_dispatchesByDealKind() public {
        uint256 id = _listDefault();
        vm.prank(borrower);
        vault.cancel(id);
        vm.prank(borrower);
        vault.withdrawCollateral(id);
        assertEq(nvda.balanceOf(borrower), 10_000e18);
    }

    function test_withdrawCollateral_revertsForUnknownDeal() public {
        vm.expectRevert(IDealVault.NothingToWithdraw.selector);
        vm.prank(borrower);
        vault.withdrawCollateral(999);
    }

    function test_withdrawCollateral_revertsForSomeoneElsesDeal() public {
        uint256 id = _listDefault();
        vm.prank(borrower);
        vault.cancel(id);
        vm.expectRevert(IDealVault.NothingToWithdraw.selector);
        vm.prank(other);
        vault.withdrawCollateral(id);
    }

    function test_withdrawPosition_revertsNothing() public {
        vm.expectRevert(IDealVault.NothingToWithdraw.selector);
        vm.prank(borrower);
        vault.withdrawPosition(1);
    }

    function test_withdraw_pausedStockTokenDelaysOnlyThatWithdrawal() public {
        (uint256 id,) = _fundDeal();
        vm.prank(borrower);
        vault.reclaim(id);
        nvda.setPaused(true);

        vm.expectRevert(MockERC20.EnforcedPause.selector);
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));

        vm.prank(lender);
        vault.withdrawUSDG();
        vm.prank(borrower);
        vault.withdrawUSDG();

        nvda.setPaused(false);
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
        assertEq(nvda.balanceOf(borrower), 10_000e18);
    }

    // ================================================================= pause: I3

    function test_pause_onlyBlocksListBidAccept() public {
        uint256 listed = _listDefault();
        uint256 openBid = _bid(lender2, listed, 7900e6);
        (uint256 funded,) = _fundDeal();
        (uint256 claimable,) = _fundDeal();
        vm.warp(vault.claimableAt(claimable));
        uint256 relisted = _listDefault();
        uint256 acceptable = _bid(lender, relisted, PRICE);

        vm.prank(safe);
        registry.pauseNewDeals(true);

        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        _listDefault();
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        _bid(lender, listed, PRICE);
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        vm.prank(borrower);
        vault.accept(relisted, acceptable);

        vm.prank(borrower);
        vault.cancel(listed);
        vm.prank(lender2);
        vault.withdrawBid(openBid);
        vm.prank(borrower);
        vault.reclaim(funded);
        vm.prank(lender);
        vault.claim(claimable);
        vm.prank(borrower);
        vault.withdrawUSDG();
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
        vm.prank(lender);
        vault.withdrawERC20(address(nvda));
        vm.prank(lender2);
        vault.withdrawUSDG();
    }

    // ================================================================= ERC-721 receiver: I10

    function test_onERC721Received_rejectsUnexpectedTransfer() public {
        vm.expectRevert(abi.encodeWithSelector(IDealVault.UnexpectedERC721.selector, other, other, 1));
        vm.prank(other);
        vault.onERC721Received(other, other, 1, "");
    }

    function test_onERC721Received_rejectsPositionManagerOutsideList() public {
        address pm = address(0xBEEF);
        DealVault v = new DealVault(usdg, registry, address(feeSink), pm, GRACE);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.UnexpectedERC721.selector, address(v), other, 1));
        vm.prank(pm);
        v.onERC721Received(address(v), other, 1, "");
    }

    // ================================================================= fee sink

    function test_feeSink_collectsCreditedFeesAndSweeps() public {
        _fundDeal();
        uint128 fee = _fee(PRICE);
        assertEq(feeSink.collect(), fee);
        assertEq(usdg.balanceOf(address(feeSink)), fee);
        assertEq(vault.balanceUSDG(address(feeSink)), 0);
        assertEq(feeSink.sweep(), fee);
        assertEq(usdg.balanceOf(treasury), fee);
    }

    // ================================================================= lifecycle, both branches

    function test_lifecycle_reclaimBranch() public {
        uint256 borrowerUSDG0 = usdg.balanceOf(borrower);
        uint256 lenderUSDG0 = usdg.balanceOf(lender);
        (uint256 id,) = _fundDeal();
        uint128 fee = _fee(PRICE);

        vm.prank(borrower);
        vault.withdrawUSDG();
        vm.warp(vault.getDeal(id).expiry - 1 hours);
        vm.prank(borrower);
        vault.reclaim(id);
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
        vm.prank(lender);
        vault.withdrawUSDG();
        feeSink.collect();

        assertEq(usdg.balanceOf(borrower), borrowerUSDG0 + PRICE - fee - CAP, "borrower paid the fixed cost + fee");
        assertEq(nvda.balanceOf(borrower), 10_000e18, "borrower has the NVDA back");
        assertEq(usdg.balanceOf(lender), lenderUSDG0 - PRICE + CAP, "lender earned cap - price");
        assertEq(usdg.balanceOf(address(feeSink)), fee);
        assertEq(usdg.balanceOf(address(vault)), 0, "vault is empty");
        assertEq(nvda.balanceOf(address(vault)), 0);
    }

    function test_lifecycle_walkAwayBranch() public {
        uint256 borrowerUSDG0 = usdg.balanceOf(borrower);
        uint256 lenderUSDG0 = usdg.balanceOf(lender);
        (uint256 id,) = _fundDeal();
        uint128 fee = _fee(PRICE);

        vm.prank(borrower);
        vault.withdrawUSDG();
        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.prank(lender);
        vault.withdrawERC20(address(nvda));
        feeSink.collect();

        assertEq(usdg.balanceOf(borrower), borrowerUSDG0 + PRICE - fee, "borrower keeps the proceeds");
        assertEq(nvda.balanceOf(borrower), 10_000e18 - AMOUNT);
        assertEq(usdg.balanceOf(lender), lenderUSDG0 - PRICE);
        assertEq(nvda.balanceOf(lender), 10_000e18 + AMOUNT, "lender holds the NVDA");
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(nvda.balanceOf(address(vault)), 0);
    }

    // ================================================================= fuzz

    function testFuzz_fee_neverExceedsMaxAndRoundsDown(uint128 price, uint16 bps) public {
        bps = uint16(bound(bps, 0, 200));
        price = uint128(bound(price, 1, type(uint128).max));
        vm.prank(safe);
        registry.setFee(bps);
        usdg.mint(lender, price);

        uint256 id = _list(borrower, address(nvda), AMOUNT, price, T7, 0);
        uint256 bidId = _bid(lender, id, price);
        vm.prank(borrower);
        vault.accept(id, bidId);

        uint256 fee = vault.balanceUSDG(address(feeSink));
        assertEq(fee, (uint256(price) * bps) / 10_000);
        assertLe(fee, (uint256(price) * 200) / 10_000);
        assertEq(fee + vault.balanceUSDG(borrower), price, "fee + proceeds == price");
    }

    function testFuzz_reclaim_anyTimeBeforeClaim(uint256 dt) public {
        dt = bound(dt, 0, 365 days);
        (uint256 id,) = _fundDeal();
        vm.warp(block.timestamp + dt);
        vm.prank(borrower);
        vault.reclaim(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
    }

    function testFuzz_claim_onlyAfterGrace(uint256 dt) public {
        dt = bound(dt, 0, uint256(T7) + GRACE + 30 days);
        (uint256 id,) = _fundDeal();
        uint256 fundedAt = block.timestamp;
        vm.warp(fundedAt + dt);
        if (dt < uint256(T7) + GRACE) {
            vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, vault.claimableAt(id)));
        }
        vm.prank(lender);
        vault.claim(id);
    }

    // ================================================================= meme lane: same adapter, own caps

    function test_memeLane_fullReclaimLifecycle() public {
        uint256 id = _list(borrower, address(meme), 50_000e18, 3500e6, T7, 0);
        assertEq(uint8(registry.getERC20Config(address(meme)).lane), uint8(Lane.MEME));
        assertEq(vault.openRaw(address(meme)), 50_000e18);
        uint256 bidId = _bid(lender, id, 3400e6);
        vm.prank(borrower);
        vault.accept(id, bidId);
        vm.prank(borrower);
        vault.reclaim(id);
        vm.prank(borrower);
        vault.withdrawERC20(address(meme));
        assertEq(meme.balanceOf(borrower), 1_000_000e18);
        assertEq(vault.balanceUSDG(lender), 3500e6);
        assertEq(vault.openRaw(address(meme)), 0);
    }

    function test_memeLane_walkAwayLeavesLenderHoldingTheMeme() public {
        uint256 id = _list(borrower, address(meme), 50_000e18, 3500e6, T7, 0);
        uint256 bidId = _bid(lender, id, 3400e6);
        vm.prank(borrower);
        vault.accept(id, bidId);
        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.prank(lender);
        vault.withdrawERC20(address(meme));
        assertEq(meme.balanceOf(lender), 1_000_000e18 + 50_000e18);
    }

    function test_memeLane_capsAreIndependentOfStockCaps() public {
        // 100,000 per deal, 500,000 open for the meme; 1,000 / 5,000 for NVDAx.
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Adapter.AboveDealMax.selector, address(meme), 100_000e18 + 1, 100_000e18)
        );
        _list(borrower, address(meme), 100_000e18 + 1, CAP, T7, 0);
        for (uint256 i = 0; i < 5; ++i) {
            _list(borrower, address(meme), 100_000e18, CAP, T7, 0);
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Adapter.OpenCapExceeded.selector, address(meme), 500_000e18, 1000e18, 500_000e18
            )
        );
        _list(borrower, address(meme), 1000e18, CAP, T7, 0);
        _listDefault(); // NVDAx unaffected
    }

    function test_memeLane_delistStopsNewListingsOnly() public {
        (uint256 id,) = _fundDealMeme();
        vm.prank(safe);
        registry.setERC20Allowed(address(meme), false, Lane.MEME, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ERC20Adapter.TokenNotAllowed.selector, address(meme)));
        _list(borrower, address(meme), 50_000e18, 3500e6, T7, 0);
        vm.prank(borrower);
        vault.reclaim(id);
        vm.prank(borrower);
        vault.withdrawERC20(address(meme));
        assertEq(meme.balanceOf(borrower), 1_000_000e18);
    }

    function _fundDealMeme() internal returns (uint256 id, uint256 bidId) {
        id = _list(borrower, address(meme), 50_000e18, 3500e6, T7, 0);
        bidId = _bid(lender, id, 3400e6);
        vm.prank(borrower);
        vault.accept(id, bidId);
    }

    // ================================================================= fund (D43: one-step funding at the asking price)

    function _listAsk(uint128 ask) internal returns (uint256 dealId) {
        vm.prank(borrower);
        dealId = vault.list(_collateral(address(nvda), 100e18), 8000e6, T7, 0, ask);
    }

    function test_fund_settlesAtAskInOneStep() public {
        uint256 id = _listAsk(PRICE);
        uint128 fee = _fee(PRICE);
        uint40 now_ = uint40(block.timestamp);

        vm.expectEmit(address(vault));
        emit IDealVault.BidPlaced(1, id, lender, PRICE, now_);
        vm.expectEmit(address(vault));
        emit IDealVault.Funded(id, 1, lender, PRICE, fee, now_, now_ + T7);
        vm.prank(lender);
        uint256 bidId = vault.fund(id, lender);

        assertEq(bidId, 1);
        Deal memory d = vault.getDeal(id);
        assertEq(uint8(d.state), uint8(DealState.FUNDED));
        assertEq(d.lender, lender);
        assertEq(d.price, PRICE);
        assertEq(d.fee, fee);
        assertEq(d.fundedAt, now_);
        assertEq(d.expiry, now_ + T7);
        Bid memory b = vault.getBid(bidId);
        assertEq(b.dealId, id);
        assertEq(b.lender, lender);
        assertEq(b.price, PRICE);
        assertEq(uint8(b.state), uint8(BidState.ACCEPTED));
        assertEq(vault.balanceUSDG(borrower), PRICE - fee);
        assertEq(vault.balanceUSDG(address(feeSink)), fee);
        assertEq(usdg.balanceOf(address(vault)), PRICE);
        assertEq(usdg.balanceOf(lender), 10_000_000e6 - PRICE);
        assertEq(vault.claimableAt(id), now_ + T7 + GRACE);
    }

    function test_fund_thenReclaimAndClaimBehaveAsAccepted() public {
        uint256 id = _listAsk(PRICE);
        vm.prank(lender);
        vault.fund(id, lender);
        vm.prank(borrower);
        vault.reclaim(id);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
        assertEq(vault.balanceUSDG(lender), 8000e6);
        assertEq(vault.balanceERC20(borrower, address(nvda)), 100e18);
    }

    function test_fund_revertsWithoutAskingPrice() public {
        uint256 id = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(IDealVault.NoAskingPrice.selector, id));
        vm.prank(lender);
        vault.fund(id, lender);
    }

    function test_fund_revertsWhenPaused() public {
        uint256 id = _listAsk(PRICE);
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        vm.prank(lender);
        vault.fund(id, lender);
    }

    function test_fund_revertsNotListed() public {
        uint256 id = _listAsk(PRICE);
        vm.prank(lender);
        vault.fund(id, lender);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, id));
        vm.prank(lender2);
        vault.fund(id, lender2);
    }

    function test_fund_revertsListingExpired() public {
        vm.prank(borrower);
        uint256 id = vault.list(_collateral(address(nvda), 100e18), 8000e6, T7, _listingExpiry(), PRICE);
        vm.warp(vault.getDeal(id).listingExpiry);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.ListingExpired.selector, id));
        vm.prank(lender);
        vault.fund(id, lender);
    }

    function test_fund_revertsUnauthorizedLender() public {
        uint256 id = _listAsk(PRICE);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.UnauthorizedLender.selector, other, lender));
        vm.prank(other);
        vault.fund(id, lender);
    }

    function test_fund_routerMayFundForAnotherLender() public {
        uint256 id = _listAsk(PRICE);
        address routerAddr = makeAddr("router");
        vm.prank(safe);
        registry.setRouter(routerAddr, true);
        usdg.mint(routerAddr, PRICE);
        vm.startPrank(routerAddr);
        usdg.approve(address(vault), PRICE);
        vault.fund(id, lender);
        vm.stopPrank();
        assertEq(vault.getDeal(id).lender, lender);
        vm.expectRevert(IDealVault.ZeroAddress.selector);
        vm.prank(routerAddr);
        vault.fund(id, address(0));
    }

    function test_fund_revertsWithoutUSDG() public {
        uint256 id = _listAsk(PRICE);
        address nobody = makeAddr("nobody");
        vm.startPrank(nobody);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, nobody, 0, uint256(PRICE))
        );
        vault.fund(id, nobody);
        vm.stopPrank();
    }

    function test_fund_afterOpenBidsLeavesThemWithdrawable() public {
        uint256 id = _listAsk(PRICE);
        uint256 bidId = _bid(lender2, id, PRICE);
        vm.prank(lender);
        vault.fund(id, lender);
        assertEq(uint8(vault.getBid(bidId).state), uint8(BidState.OPEN));
        vm.prank(lender2);
        vault.withdrawBid(bidId);
        assertEq(vault.balanceUSDG(lender2), PRICE);
    }

    // ================================================================= open-ended listings (D43)

    function test_list_zeroExpiryNeverExpires() public {
        uint256 id = _listAsk(PRICE);
        assertEq(vault.getDeal(id).listingExpiry, 0);
        vm.warp(block.timestamp + 400 days);
        vm.prank(lender);
        vault.fund(id, lender);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.FUNDED));
    }

    function test_list_zeroExpiryStillRejectsFarFutureAndPast() public {
        vm.expectRevert(IDealVault.InvalidListingExpiry.selector);
        vm.prank(borrower);
        vault.list(_collateral(address(nvda), 100e18), 8000e6, T7, uint40(block.timestamp + 8 days), 0);
    }

    function test_bid_onOpenEndedListingBoundedByMaxListingExpiry() public {
        uint256 id = _listAsk(PRICE);
        vm.expectRevert(IDealVault.InvalidBidExpiry.selector);
        vm.prank(lender);
        vault.bid(id, PRICE, uint40(block.timestamp + 7 days + 1), lender);
        vm.prank(lender);
        vault.bid(id, PRICE, uint40(block.timestamp + 7 days), lender);
    }
}
