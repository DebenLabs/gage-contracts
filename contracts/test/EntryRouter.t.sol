// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {EntryRouter} from "../src/EntryRouter.sol";
import {IDealVault, Deal, DealState, Bid, BidState} from "../src/interfaces/IDealVault.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";

/// @dev A caller that cannot receive ETH, to exercise the refund failure path.
contract Rejecter {
    EntryRouter internal immutable ROUTER;

    constructor(EntryRouter router) {
        ROUTER = router;
    }

    function go(uint256 dealId, uint128 price, uint40 bidExpiry) external payable returns (uint256) {
        return ROUTER.bidWithETH{value: msg.value}(dealId, price, bidExpiry, "", new bytes[](0), block.timestamp + 1);
    }
}

contract EntryRouterTest is BaseTest {
    uint128 internal constant PRICE = 7960e6;
    bytes internal commands;
    bytes[] internal inputs;

    function _exp() internal view returns (uint40) {
        return uint40(block.timestamp + 1 days);
    }

    function test_constructor_state() public view {
        assertEq(address(router.VAULT()), address(vault));
        assertEq(address(router.USDG()), address(usdg));
        assertEq(address(router.UNIVERSAL_ROUTER()), address(ur));
    }

    function test_constructor_revertsZero() public {
        vm.expectRevert(EntryRouter.ZeroAddress.selector);
        new EntryRouter(IDealVault(address(0)), usdg, ur);
        vm.expectRevert(EntryRouter.ZeroAddress.selector);
        new EntryRouter(vault, IERC20(address(0)), ur);
        vm.expectRevert(EntryRouter.ZeroAddress.selector);
        new EntryRouter(vault, usdg, IUniversalRouter(address(0)));
    }

    function test_bidWithETH_placesBidForCallerAndRefundsUSDG() public {
        uint256 id = _listDefault();
        uint256 usdgBefore = usdg.balanceOf(lender);
        uint256 ethBefore = lender.balance;
        uint40 exp = _exp();

        // 3 ETH at 3,000 USDG/ETH = 9,000 USDG; 7,960 escrowed, 1,040 refunded.
        vm.expectEmit(address(router));
        emit EntryRouter.BidWithETH(lender, id, 1, 3 ether, 9000e6, 1040e6, 0);
        vm.prank(lender);
        uint256 bidId = router.bidWithETH{value: 3 ether}(id, PRICE, exp, commands, inputs, block.timestamp + 1);

        Bid memory b = vault.getBid(bidId);
        assertEq(b.lender, lender, "lender is the caller, not the router");
        assertEq(b.price, PRICE);
        assertEq(b.expiry, exp);
        assertEq(uint8(b.state), uint8(BidState.OPEN));
        assertEq(usdg.balanceOf(address(vault)), PRICE);
        assertEq(usdg.balanceOf(lender), usdgBefore + 1040e6, "USDG dust refunded");
        assertEq(lender.balance, ethBefore - 3 ether);
        assertEq(usdg.balanceOf(address(router)), 0, "router holds nothing");
        assertEq(address(router).balance, 0);
        assertEq(usdg.allowance(address(router), address(vault)), 0);
    }

    function test_bidWithETH_exactAmountNoRefund() public {
        uint256 id = _listDefault();
        // 7,960 USDG at 3,000 USDG/ETH = 2.653333... ETH; use a price that divides.
        ur.setRate(1000e6);
        uint256 usdgBefore = usdg.balanceOf(lender);
        vm.prank(lender);
        router.bidWithETH{value: 7.96 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
        assertEq(usdg.balanceOf(lender), usdgBefore);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    function test_bidWithETH_refundsUnusedETH() public {
        uint256 id = _listDefault();
        ur.setConsumeBps(5000);
        uint256 ethBefore = lender.balance;
        // 3 ETH sent, 1.5 spent -> 4,500 USDG; bid 4,000.
        vm.prank(lender);
        router.bidWithETH{value: 3 ether}(id, 4000e6, _exp(), commands, inputs, block.timestamp + 1);
        assertEq(lender.balance, ethBefore - 1.5 ether, "unused ETH refunded");
        assertEq(address(router).balance, 0);
    }

    function test_bidWithETH_revertsInsufficientUSDG() public {
        uint256 id = _listDefault();
        vm.expectRevert(abi.encodeWithSelector(EntryRouter.InsufficientUSDG.selector, 3000e6, 3001e6));
        vm.prank(lender);
        router.bidWithETH{value: 1 ether}(id, 3001e6, _exp(), commands, inputs, block.timestamp + 1);
    }

    function test_bidWithETH_revertsNoETH() public {
        uint256 id = _listDefault();
        vm.expectRevert(EntryRouter.NoETH.selector);
        vm.prank(lender);
        router.bidWithETH(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
    }

    function test_bidWithETH_revertsWhenRouterNotAllowlisted() public {
        uint256 id = _listDefault();
        vm.prank(safe);
        registry.setRouter(address(router), false);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.UnauthorizedLender.selector, address(router), lender));
        vm.prank(lender);
        router.bidWithETH{value: 3 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
    }

    function test_bidWithETH_bubblesVaultErrors() public {
        uint256 id = _listDefault();
        vm.prank(borrower);
        vault.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotListed.selector, id));
        vm.prank(lender);
        router.bidWithETH{value: 3 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
    }

    function test_bidWithETH_bubblesRouterErrors() public {
        uint256 id = _listDefault();
        vm.expectRevert(MockUniversalRouter.DeadlinePassed.selector);
        vm.prank(lender);
        router.bidWithETH{value: 3 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp - 1);
    }

    function test_bidWithETH_revertsRefundFailed() public {
        uint256 id = _listDefault();
        Rejecter r = new Rejecter(router);
        vm.deal(address(r), 3 ether);
        ur.setConsumeBps(5000);
        vm.expectRevert(EntryRouter.RefundFailed.selector);
        r.go{value: 3 ether}(id, 4000e6, _exp());
    }

    function test_bidWithETH_contractCallerWithoutETHRefundSucceeds() public {
        uint256 id = _listDefault();
        Rejecter r = new Rejecter(router);
        vm.deal(address(r), 3 ether);
        uint256 bidId = r.go{value: 3 ether}(id, PRICE, _exp());
        assertEq(vault.getBid(bidId).lender, address(r));
        assertEq(usdg.balanceOf(address(r)), 1040e6, "USDG dust still refunded");
    }

    function test_bidWithETH_lenderCanWithdrawBidAndUSDG() public {
        uint256 id = _listDefault();
        vm.prank(lender);
        uint256 bidId = router.bidWithETH{value: 3 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
        uint256 before = usdg.balanceOf(lender);
        vm.prank(lender);
        vault.withdrawBid(bidId);
        vm.prank(lender);
        vault.withdrawUSDG();
        assertEq(usdg.balanceOf(lender), before + PRICE);
    }

    function test_bidWithETH_acceptedBidRecordsCallerAsLender() public {
        uint256 id = _listDefault();
        vm.prank(lender);
        uint256 bidId = router.bidWithETH{value: 3 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
        vm.prank(borrower);
        vault.accept(id, bidId);
        assertEq(vault.getDeal(id).lender, lender);
    }

    function test_bidWithETH_strayUSDGIsSweptToNextCaller() public {
        uint256 id = _listDefault();
        usdg.mint(address(router), 5e6);
        uint256 before = usdg.balanceOf(lender);
        vm.prank(lender);
        router.bidWithETH{value: 3 ether}(id, PRICE, _exp(), commands, inputs, block.timestamp + 1);
        assertEq(usdg.balanceOf(lender), before + 1040e6 + 5e6);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    // ================================================================= fundWithETH (D43)

    function _listAsk() internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(_collateral(address(nvda), 100e18), 8000e6, T7, 0, PRICE);
    }

    function test_fundWithETH_fundsAtAskAndRefunds() public {
        uint256 id = _listAsk();
        uint256 usdgBefore = usdg.balanceOf(lender);
        uint256 ethBefore = lender.balance;

        vm.expectEmit(address(router));
        emit EntryRouter.FundedWithETH(lender, id, 1, 3 ether, 9000e6, 1040e6, 0);
        vm.prank(lender);
        uint256 bidId = router.fundWithETH{value: 3 ether}(id, commands, inputs, block.timestamp + 1);

        Deal memory d = vault.getDeal(id);
        assertEq(uint8(d.state), uint8(DealState.FUNDED));
        assertEq(d.lender, lender, "lender is the caller, not the router");
        assertEq(d.price, PRICE);
        assertEq(uint8(vault.getBid(bidId).state), uint8(BidState.ACCEPTED));
        assertEq(usdg.balanceOf(lender), usdgBefore + 1040e6, "USDG dust refunded");
        assertEq(lender.balance, ethBefore - 3 ether);
        assertEq(usdg.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(usdg.allowance(address(router), address(vault)), 0);
    }

    function test_fundWithETH_revertsInsufficientUSDG() public {
        uint256 id = _listAsk();
        // 1 ETH = 3,000 USDG < 7,960
        vm.expectRevert(abi.encodeWithSelector(EntryRouter.InsufficientUSDG.selector, 3000e6, PRICE));
        vm.prank(lender);
        router.fundWithETH{value: 1 ether}(id, commands, inputs, block.timestamp + 1);
    }

    function test_fundWithETH_revertsNoETH() public {
        uint256 id = _listAsk();
        vm.expectRevert(EntryRouter.NoETH.selector);
        vm.prank(lender);
        router.fundWithETH{value: 0}(id, commands, inputs, block.timestamp + 1);
    }

    function test_fundWithETH_bubblesVaultErrors() public {
        uint256 id = _listDefault(); // no asking price
        vm.expectRevert(abi.encodeWithSelector(IDealVault.NoAskingPrice.selector, id));
        vm.prank(lender);
        router.fundWithETH{value: 3 ether}(id, commands, inputs, block.timestamp + 1);
    }
}
