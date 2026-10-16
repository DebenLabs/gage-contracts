// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {EarnV3BaseTest} from "../earn/EarnV3Base.t.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AutoCashoutRouter} from "../../src/autocashout/AutoCashoutRouter.sol";

/// @notice The auto cash-out router on an unbridged core with a 1-day term and a real Uniswap v4 PoolManager holding a
/// deep NVDA/USDG pool at 100 USDG per NVDA. A borrower pledges 100 NVDA (10,000 USDG) and owes 9,900 USDG back after one
/// day; the keeper cashes the loan out in its last fifteen minutes and the borrower withdraws the gain.
contract AutoCashoutRouterTest is EarnV3BaseTest, V4Fixture {
    uint32 internal constant DAY = 1 days;
    uint256 internal constant PLEDGE = 100e18;
    uint128 internal constant CAP = 9900e6;
    uint128 internal constant PRINCIPAL = 9850e6;

    AutoCashoutRouter internal router;
    PoolKey internal key;
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");
    address internal mallory = makeAddr("mallory");

    function setUp() public override {
        super.setUp();
        uint32[] memory terms = new uint32[](3);
        terms[0] = DAY;
        terms[1] = T7;
        terms[2] = T21;
        vm.prank(safe);
        registry.setTerms(terms);

        _deployV4();
        // 100 USDG buys one NVDA; 100,000 NVDA and 10,000,000 USDG a side, so selling the 100 pledged NVDA costs about
        // 0.4% (the 0.3% pool fee and 0.1% of price impact) and fetches about 9,960 USDG.
        key = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        nvda.mint(lp, 200_000e18);
        usdg.mint(lp, 20_000_000e6);
        _addRawLiquidity(key, FULL_LOWER, FULL_UPPER, 1e18, lp);

        router = new AutoCashoutRouter(core, poolManager, keeper, address(this));
    }

    // ---------------------------------------------------------------- fixture

    /// @dev A 1-day NVDA loan, funded in full by alice, with the router approved for its right.
    function _loan() internal returns (uint256 id) {
        id = _list(borrower, address(nvda), PLEDGE, PRINCIPAL, CAP, DAY);
        vm.prank(alice);
        core.fund(id, 4);
        vm.prank(borrower);
        core.approve(address(router), id);
    }

    function _end(uint256 id) internal view returns (uint256) {
        V2Loan memory l = core.getLoan(id);
        return uint256(l.fundedAt) + l.term + core.GRACE();
    }

    function _intoWindow(uint256 id) internal {
        vm.warp(_end(id) - 5 minutes);
    }

    function _cashOut(uint256 id, uint256 minNet) internal returns (uint256) {
        vm.prank(keeper);
        return router.cashOut(id, key, minNet);
    }

    /// @dev Push the pool's NVDA price down by selling `amount` NVDA into it.
    function _dump(uint256 amount) internal {
        nvda.mint(mallory, amount);
        bool nvdaIsZero = address(nvda) < address(usdg);
        _swap(key, nvdaIsZero, -int256(amount), mallory);
    }

    // ---------------------------------------------------------------- happy path

    function test_cashOut_creditsTheGainLessTheFee() public {
        uint256 id = _loan();
        _intoWindow(id);
        uint256 feeBefore = usdg.balanceOf(treasury);

        uint256 net = _cashOut(id, 1);

        uint256 fee = usdg.balanceOf(treasury) - feeBefore;
        uint256 gain = net + fee;
        // 100 NVDA sell for about 9,960 USDG: the gain over the 9,900 USDG cap is about 60 USDG.
        assertGt(gain, 55e6, "gain");
        assertLt(gain, 65e6, "gain bound");
        assertEq(fee, gain * router.FEE_BPS() / 10_000, "fee");
        assertEq(router.owed(borrower), net, "credited");
        assertEq(router.totalOwed(), net, "total");
        assertEq(usdg.balanceOf(address(router)), net, "router holds the credit");
        assertEq(nvda.balanceOf(address(router)), 0, "no collateral left");
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID), "repaid");
        // The lenders were paid the whole cap.
        assertEq(core.cashCredit(alice), CAP, "lender credit");
    }

    function test_cashOut_emitsTheBreakdown() public {
        uint256 id = _loan();
        _intoWindow(id);
        uint256 feeBefore = usdg.balanceOf(treasury);
        vm.recordLogs();
        uint256 net = _cashOut(id, 1);
        uint256 fee = usdg.balanceOf(treasury) - feeBefore;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != AutoCashoutRouter.CashedOut.selector) {
                continue;
            }
            found = true;
            assertEq(uint256(logs[i].topics[1]), id, "id");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), borrower, "holder");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(nvda), "token");
            (uint256 sold, uint256 proceeds, uint128 cap, uint256 loggedFee, uint256 loggedNet) =
                abi.decode(logs[i].data, (uint256, uint256, uint128, uint256, uint256));
            assertEq(sold, PLEDGE, "sold");
            assertEq(cap, CAP, "cap");
            assertEq(loggedFee, fee, "fee");
            assertEq(loggedNet, net, "net");
            assertEq(proceeds, uint256(CAP) + fee + net, "proceeds");
        }
        assertTrue(found, "CashedOut emitted");
    }

    function test_withdraw_paysTheHolderOnce() public {
        uint256 id = _loan();
        _intoWindow(id);
        uint256 net = _cashOut(id, 1);
        uint256 before = usdg.balanceOf(borrower);

        vm.prank(borrower);
        router.withdraw(borrower);

        assertEq(usdg.balanceOf(borrower) - before, net, "paid");
        assertEq(router.owed(borrower), 0, "cleared");
        assertEq(router.totalOwed(), 0, "total cleared");
        vm.prank(borrower);
        vm.expectRevert(AutoCashoutRouter.NothingOwed.selector);
        router.withdraw(borrower);
    }

    function test_withdrawFor_deliversToTheAccountItself() public {
        uint256 id = _loan();
        _intoWindow(id);
        uint256 net = _cashOut(id, 1);
        uint256 before = usdg.balanceOf(borrower);

        vm.prank(mallory);
        router.withdrawFor(borrower);

        assertEq(usdg.balanceOf(borrower) - before, net, "delivered to the holder");
        assertEq(usdg.balanceOf(mallory), 0, "never to the caller");
    }

    function test_withdraw_refusesAnEmptyRecipient() public {
        uint256 id = _loan();
        _intoWindow(id);
        _cashOut(id, 1);
        vm.startPrank(borrower);
        vm.expectRevert(AutoCashoutRouter.InvalidRecipient.selector);
        router.withdraw(address(0));
        vm.expectRevert(AutoCashoutRouter.InvalidRecipient.selector);
        router.withdraw(address(router));
        vm.stopPrank();
    }

    function test_setApprovalForAll_coversEveryLoan() public {
        uint256 id = _list(borrower, address(nvda), PLEDGE, PRINCIPAL, CAP, DAY);
        vm.prank(alice);
        core.fund(id, 4);
        vm.prank(borrower);
        core.setApprovalForAll(address(router), true);
        _intoWindow(id);
        assertGt(_cashOut(id, 1), 0, "cashed out");
    }

    // ---------------------------------------------------------------- when and who

    function test_cashOut_refusesBeforeTheWindow() public {
        uint256 id = _loan();
        uint256 closes = _end(id);
        // Read before the prank: `vm.prank` binds to the very next external call, a view included.
        uint256 opens = closes - router.WINDOW();
        vm.warp(opens - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AutoCashoutRouter.OutsideWindow.selector, opens, closes));
        router.cashOut(id, key, 1);
    }

    function test_cashOut_opensExactlyAtTheWindow() public {
        uint256 id = _loan();
        vm.warp(_end(id) - router.WINDOW());
        assertGt(_cashOut(id, 1), 0, "first second");
    }

    function test_cashOut_refusesOnceRepaymentCloses() public {
        uint256 id = _loan();
        uint256 closes = _end(id);
        uint256 opens = closes - router.WINDOW();
        vm.warp(closes);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AutoCashoutRouter.OutsideWindow.selector, opens, closes));
        router.cashOut(id, key, 1);
        // The default then runs as it would without the router.
        core.finalizeDefault(id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED), "defaulted");
    }

    function test_cashOut_onlyTheKeeper() public {
        uint256 id = _loan();
        _intoWindow(id);
        vm.prank(borrower);
        vm.expectRevert(AutoCashoutRouter.NotKeeper.selector);
        router.cashOut(id, key, 1);
    }

    function test_cashOut_needsTheHoldersApproval() public {
        uint256 id = _list(borrower, address(nvda), PLEDGE, PRINCIPAL, CAP, DAY);
        vm.prank(alice);
        core.fund(id, 4);
        _intoWindow(id);
        vm.prank(keeper);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        router.cashOut(id, key, 1);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE), "untouched");
    }

    function test_cashOut_refusesALoanThatIsNotActive() public {
        uint256 id = _list(borrower, address(nvda), PLEDGE, PRINCIPAL, CAP, DAY);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AutoCashoutRouter.NotActive.selector, id));
        router.cashOut(id, key, 1);
    }

    function test_cashOut_refusesAZeroMinimum() public {
        uint256 id = _loan();
        _intoWindow(id);
        vm.prank(keeper);
        vm.expectRevert(AutoCashoutRouter.ZeroMinimum.selector);
        router.cashOut(id, key, 0);
    }

    // ---------------------------------------------------------------- price protection

    function test_cashOut_revertsWhenTheCollateralSellsBelowTheCap() public {
        uint256 id = _loan();
        _intoWindow(id);
        // About 2% lower: 100 NVDA now fetch less than the 9,900 USDG cap.
        _dump(1000e18);
        vm.prank(keeper);
        vm.expectPartialRevert(AutoCashoutRouter.InsufficientProceeds.selector);
        router.cashOut(id, key, 1);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE), "untouched");
        assertEq(core.ownerOf(id), borrower, "right kept");
    }

    function test_cashOut_holdsTheKeepersMinimum() public {
        uint256 id = _loan();
        _intoWindow(id);
        vm.prank(keeper);
        vm.expectPartialRevert(AutoCashoutRouter.BelowMinimum.selector);
        router.cashOut(id, key, 1000e6);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE), "untouched");
    }

    function test_cashOut_refusesAPoolWithHooks() public {
        uint256 id = _loan();
        _intoWindow(id);
        PoolKey memory hooked = key;
        hooked.hooks = IHooks(address(0xBEEF));
        vm.prank(keeper);
        vm.expectRevert(AutoCashoutRouter.InvalidPool.selector);
        router.cashOut(id, hooked, 1);
    }

    function test_cashOut_refusesAPoolForAnotherToken() public {
        uint256 id = _loan();
        _intoWindow(id);
        PoolKey memory other = _initPoolAtPrice(address(meme), 1e18, address(usdg), 1e6, address(0));
        vm.prank(keeper);
        vm.expectRevert(AutoCashoutRouter.InvalidPool.selector);
        router.cashOut(id, other, 1);
    }

    // ---------------------------------------------------------------- owner switches

    function test_pause_stopsCashOutsButNotWithdrawals() public {
        uint256 a = _loan();
        _intoWindow(a);
        uint256 net = _cashOut(a, 1);

        router.pause();
        uint256 b = _loan();
        _intoWindow(b);
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.cashOut(b, key, 1);

        uint256 before = usdg.balanceOf(borrower);
        vm.prank(borrower);
        router.withdraw(borrower);
        assertEq(usdg.balanceOf(borrower) - before, net, "withdrawal while paused");

        router.unpause();
        assertGt(_cashOut(b, 1), 0, "resumed");
    }

    function test_setKeeper_onlyTheOwner() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        router.setKeeper(mallory);

        vm.expectRevert(AutoCashoutRouter.InvalidConfiguration.selector);
        router.setKeeper(address(0));

        vm.expectEmit(true, false, false, false, address(router));
        emit AutoCashoutRouter.KeeperSet(mallory);
        router.setKeeper(mallory);
        assertEq(router.keeper(), mallory, "keeper");
    }

    function test_pause_onlyTheOwner() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        router.pause();
    }

    function test_unlockCallback_onlyThePoolManager() public {
        vm.expectRevert(AutoCashoutRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }

    function test_constructor_refusesABadConfiguration() public {
        vm.expectRevert(AutoCashoutRouter.InvalidConfiguration.selector);
        new AutoCashoutRouter(GageV2Vault(address(0xdead)), poolManager, keeper, address(this));
        vm.expectRevert(AutoCashoutRouter.InvalidConfiguration.selector);
        new AutoCashoutRouter(core, IPoolManager(address(0xdead)), keeper, address(this));
        vm.expectRevert(AutoCashoutRouter.InvalidConfiguration.selector);
        new AutoCashoutRouter(core, poolManager, address(0), address(this));
    }

    /// @dev The sale's direction follows the pool's token order: a stock token sorted on USDG's other side sells too.
    function test_cashOut_sellsWhicheverSideUSDGIsOn() public {
        bool nvdaBelow = address(nvda) < address(usdg);
        MockERC20 stock;
        for (uint256 i; i < 16; ++i) {
            stock = new MockERC20("STOCK", "STOCK", 18);
            if ((address(stock) < address(usdg)) != nvdaBelow) break;
        }
        assertTrue((address(stock) < address(usdg)) != nvdaBelow, "opposite order");
        vm.prank(safe);
        registry.setERC20Allowed(address(stock), true, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        PoolKey memory other = _initPoolAtPrice(address(stock), 1e18, address(usdg), 100e6, address(0));
        stock.mint(lp, 200_000e18);
        _addRawLiquidity(other, FULL_LOWER, FULL_UPPER, 1e18, lp);

        stock.mint(borrower, PLEDGE);
        vm.prank(borrower);
        stock.approve(address(core), PLEDGE);
        uint256 id = _list(borrower, address(stock), PLEDGE, PRINCIPAL, CAP, DAY);
        vm.prank(alice);
        core.fund(id, 4);
        vm.prank(borrower);
        core.approve(address(router), id);
        _intoWindow(id);

        vm.prank(keeper);
        uint256 net = router.cashOut(id, other, 1);
        assertGt(net, 55e6, "gain");
        assertEq(stock.balanceOf(address(router)), 0, "all sold");
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID), "repaid");
    }

    function test_windowOf_reportsTheLastFifteenMinutes() public {
        uint256 id = _loan();
        (uint256 opens, uint256 closes) = router.windowOf(id);
        assertEq(closes, _end(id), "closes");
        assertEq(opens, closes - 15 minutes, "opens");
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Whatever the price at the end, a cash-out either credits exactly the gain less the fee and leaves the router
    /// holding only credits, or reverts and leaves the loan as it was.
    function testFuzz_cashOut_creditsOrLeavesTheLoan(uint256 dump, uint128 cap) public {
        dump = bound(dump, 0, 20_000e18);
        cap = uint128(bound(cap, 5000e6, 9990e6));
        uint256 id = _list(borrower, address(nvda), PLEDGE, cap - 10e6, cap, DAY);
        vm.prank(alice);
        core.fund(id, 4);
        vm.prank(borrower);
        core.approve(address(router), id);
        _intoWindow(id);
        if (dump != 0) _dump(dump);

        uint256 feeBefore = usdg.balanceOf(treasury);
        vm.prank(keeper);
        try router.cashOut(id, key, 1) returns (uint256 net) {
            uint256 fee = usdg.balanceOf(treasury) - feeBefore;
            assertEq(fee, (net + fee) * router.FEE_BPS() / 10_000, "fee on the gain");
            assertEq(router.owed(borrower), net, "credit");
            assertEq(usdg.balanceOf(address(router)), router.totalOwed(), "only credits held");
            assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID), "repaid");
        } catch {
            assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE), "untouched");
            assertEq(router.totalOwed(), 0, "nothing credited");
            assertEq(usdg.balanceOf(address(router)), 0, "nothing held");
        }
    }
}
