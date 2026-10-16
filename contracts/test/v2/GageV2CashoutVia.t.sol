// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {GageV2CashoutRoutesTest, IV3FactorySetup, IV3PoolSetup} from "./GageV2CashoutRoutes.t.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {IUniV3Factory, IUniV3Pool, IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {TestnetAggregator} from "../../src/testnet/TestnetAggregator.sol";

/// @dev An aggregator's router as `cashOutVia` meets one: it takes the input it is approved for from its caller and
///      pays what it sells for from its own stock to a recipient.
contract ViaMockAggregator {
    function sell(IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, uint256 amountOut, address to) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        if (amountOut != 0) tokenOut.transfer(to, amountOut);
    }

    /// @dev As `sell`, then sends `back` of the input token to the caller: part of what it took, or more from stock.
    function sellAndSendBack(
        IERC20 tokenIn,
        uint256 amountIn,
        uint256 back,
        IERC20 tokenOut,
        uint256 amountOut,
        address to
    ) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenIn.transfer(msg.sender, back);
        tokenOut.transfer(to, amountOut);
    }

    function decline() external pure {
        revert("declined");
    }
}

/// @dev A V3 pool's flash as `cashOutVia` meets it, for a pool whose token0 sorts below USDG (both USDG/WETH pools on
///      mainnet): it sends what is asked of each token, calls back with each fee, and requires the repayment.
contract ViaMockLender {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint256 public lent0;
    uint256 public lent1;
    uint256 public fee1Charged;

    constructor(address t0, address t1, uint24 fee_) {
        (token0, token1, fee) = (t0, t1, fee_);
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(amount0 == 0, "token0 is not lent here");
        uint256 fee1 = (amount1 * fee + 1e6 - 1) / 1e6;
        uint256 before = IERC20(token1).balanceOf(address(this));
        (lent0, lent1, fee1Charged) = (amount0, amount1, fee1);
        IERC20(token1).transfer(recipient, amount1);
        GageV2CashoutRouter(payable(msg.sender)).uniswapV3FlashCallback(0, fee1, data);
        require(IERC20(token1).balanceOf(address(this)) >= before + fee1, "F1");
    }
}

/// @dev An executor that sells through a V3 pool: an exact-input swap whose callback pays the pool from its caller's
///      approval.
contract ViaV3Executor {
    function sell(address pool, address tokenIn, uint256 amountIn, address to) external {
        bool zeroForOne = IUniV3Pool(pool).token0() == tokenIn;
        IV2FlashPool(pool)
            .swap(
                to,
                zeroForOne,
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(msg.sender)
            );
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data) external {
        (address token, uint256 owed) = amount0 > 0
            ? (IUniV3Pool(msg.sender).token0(), uint256(amount0))
            : (IUniV3Pool(msg.sender).token1(), uint256(amount1));
        IERC20(token).transferFrom(abi.decode(data, (address)), msg.sender, owed);
    }
}

/// @dev An executor that sells through the PoolManager, which the cash-out's V3 flash leaves unlocked: an exact-input
///      swap paid from its caller's approval.
contract ViaV4Executor is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    function sell(PoolKey calldata key, address tokenIn, uint256 amountIn, address to) external {
        PM.unlock(abi.encode(msg.sender, key, Currency.unwrap(key.currency0) == tokenIn, amountIn, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) =
            abi.decode(data, (address, PoolKey, bool, uint256, address));
        BalanceDelta d = PM.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        PM.take(output, to, uint128(zeroForOne ? d.amount1() : d.amount0()));
        PM.sync(input);
        IERC20(Currency.unwrap(input)).transferFrom(payer, address(PM), amountIn);
        PM.settle();
        return "";
    }
}

/// @dev An executor that takes its input, then makes the one call it is armed with and bubbles that call's revert; an
///      unlock it starts calls the router's `unlockCallback` from inside.
contract ViaReentrantExecutor is IUnlockCallback {
    address internal immutable ROUTER;
    address internal _target;
    bytes internal _call;

    constructor(address router) {
        ROUTER = router;
    }

    function arm(address target, bytes calldata data) external {
        (_target, _call) = (target, data);
    }

    function sell(IERC20 tokenIn, uint256 amountIn) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        _bubble(_target, _call);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        _bubble(ROUTER, abi.encodeCall(GageV2CashoutRouter.unlockCallback, (data)));
        return "";
    }

    /// @dev A V3 flash this executor starts calls it back (a V3 pool calls back its caller): pass it on to the router.
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        _bubble(ROUTER, abi.encodeCall(GageV2CashoutRouter.uniswapV3FlashCallback, (fee0, fee1, data)));
    }

    function _bubble(address target, bytes memory data) internal {
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}

/// @notice `cashOutVia` (D245): the whole collateral sold through one admitted executor, an aggregator's router, with
///         the cap flash-borrowed from a V3 factory pool the caller names. Same fixture as the route suite (real v3
///         factory bytecode, real PoolManager, real core), plus a second USDG lender and a hookless COL/USDG v4 pool.
/// @dev Inherits the route suite, whose tests run again here unchanged: `cashOutDetailed` is untouched by D245.
contract GageV2CashoutViaTest is GageV2CashoutRoutesTest {
    uint256 internal constant FEE_500 = 550_000;
    uint256 internal constant FEE_3000 = 3_300_000;
    uint256 internal constant SALE = 5000e6;

    /// @dev A second USDG lender: the factory's 0.3% COL/USDG pool, 3,000 USDG per COL, full range.
    address internal usdgCol;
    /// @dev A hookless COL/USDG v4 pool at the same price.
    PoolKey internal colUsdgKey;
    ViaMockAggregator internal agg;

    function setUp() public override {
        super.setUp();
        usdgCol = _v3PoolAt(address(col), 1e18, address(usdg), 3000e6, 3000, 60, 1e17);
        colUsdgKey = _initPoolAtPrice(address(col), 1e18, address(usdg), 3000e6, address(0));
        _addRawLiquidity(colUsdgKey, FULL_LOWER, FULL_UPPER, 1e17, lp);
        agg = new ViaMockAggregator();
        usdg.mint(address(agg), 2e30);
        router.setExecutor(address(agg), true);
    }

    // ----------------------------------------------------------------- the entry

    function test_cashOutDetailed_selectorAndBehaviourUnchanged() public pure {
        assertEq(
            GageV2CashoutRouter.cashOutDetailed.selector,
            bytes4(
                keccak256(
                    "cashOutDetailed((uint256,address,uint256,uint256,uint256,uint256,uint256,(uint8,address,address,uint24,(address,address,uint24,int24,address),uint256)[]))"
                )
            ),
            "cashOutDetailed keeps the deployed routers' selector"
        );
        assertEq(
            GageV2CashoutRouter.cashOutVia.selector,
            bytes4(
                keccak256("cashOutVia((uint256,address,uint256,uint256,uint256,address,bytes,address,uint24,uint256))")
            ),
            "cashOutVia's selector, as the app and the valuation service encode it"
        );
    }

    function test_cashOutVia_sellsWholeCollateralThroughAdmittedExecutor() public {
        uint256 id = _activeLoan();
        uint256 lenderBefore = usdg.balanceOf(flashPool);
        uint256 remainder = SALE - CAP - FEE_500;
        uint256 platformFee = remainder * 50 / 10_000;
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);

        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.SoldVia(id, address(agg), flashPool, COLLATERAL, SALE, FEE_500);
        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.CashedOut(
            id, borrower, borrower, SALE, CAP, FEE_500, platformFee, remainder - platformFee
        );
        vm.prank(borrower);
        (uint256 gross, uint256 financeFee, uint256 fee, uint256 net) = router.cashOutVia(x);

        assertEq(gross, SALE, "gross is the sale");
        assertEq(financeFee, FEE_500, "the 0.05% flash fee on the cap");
        assertEq(fee, platformFee, "0.5% of the remainder");
        assertEq(net, remainder - platformFee, "net");
        assertEq(usdg.balanceOf(borrower), net, "the recipient paid net");
        assertEq(usdg.balanceOf(fees), platformFee, "the fee recipient paid");
        assertEq(usdg.balanceOf(flashPool), lenderBefore + FEE_500, "the lender repaid with its fee");
        assertEq(col.balanceOf(address(agg)), COLLATERAL, "the whole collateral sold");
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(col.allowance(address(router), address(agg)), 0, "no approval left behind");
        assertEq(usdg.allowance(address(router), address(vault)), 0, "no USDG approval left behind");
        _assertNoResidue();
    }

    /// @dev The fee math is `cashOutDetailed`'s: 0.5% of what remains after the cap and the flash fee, floored.
    function testFuzz_cashOutVia_feeMathEqualsCashOutDetailed(uint256 usdgOut) public {
        usdgOut = bound(usdgOut, CAP + FEE_500 + 1, 1e30);
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, usdgOut);
        vm.prank(borrower);
        (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net) = router.cashOutVia(x);
        uint256 r = usdgOut - CAP - FEE_500;
        assertEq(gross, usdgOut, "gross");
        assertEq(financeFee, FEE_500, "finance fee");
        assertEq(platformFee, r * 50 / 10_000, "platform fee");
        assertEq(net, r - r * 50 / 10_000, "net");
        _assertNoResidue();
    }

    function test_cashOutVia_lendsFromAPoolChosenPerCall() public {
        uint256 id = _activeLoan();
        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.SoldVia(id, address(agg), flashPool, COLLATERAL, SALE, FEE_500);
        vm.prank(borrower);
        router.cashOutVia(_via(id, SALE));

        id = _activeLoan();
        uint256 lenderBefore = usdg.balanceOf(usdgCol);
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        (x.flashToken, x.flashFee) = (address(col), 3000);
        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.SoldVia(id, address(agg), usdgCol, COLLATERAL, SALE, FEE_3000);
        vm.prank(borrower);
        (,, uint256 platformFee, uint256 net) = router.cashOutVia(x);
        uint256 r = SALE - CAP - FEE_3000;
        assertEq(net, r - r * 50 / 10_000, "net after the 0.3% lender's fee");
        assertEq(platformFee, r * 50 / 10_000, "fee");
        assertEq(usdg.balanceOf(usdgCol), lenderBefore + FEE_3000, "the second lender repaid with its fee");
        _assertNoResidue();
    }

    /// @dev Both USDG/WETH pools on mainnet hold USDG as token1, so `cashOutVia` asks them for amount1: the branch this
    ///      fixture's pools, where USDG sorts first, never take (the D245 reviews). A lender whose token0 sorts below
    ///      USDG takes it.
    function test_cashOutVia_borrowsUsdgAsToken1WhenTheOtherTokenSortsFirst() public {
        assertEq(IUniV3Pool(flashPool).token0(), address(usdg), "this fixture's lenders hold USDG as token0");
        address low = address(0x1000);
        assertLt(uint160(low), uint160(address(usdg)), "the lender's other token sorts below USDG");
        ViaMockLender lender = new ViaMockLender(low, address(usdg), 500);
        usdg.mint(address(lender), 10_000e6);
        vm.mockCall(
            v3Factory,
            abi.encodeCall(IUniV3Factory.getPool, (address(usdg), low, uint24(500))),
            abi.encode(address(lender))
        );
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        (x.flashToken, x.flashFee) = (low, 500);
        uint256 lenderBefore = usdg.balanceOf(address(lender));

        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.SoldVia(id, address(agg), address(lender), COLLATERAL, SALE, FEE_500);
        vm.prank(borrower);
        (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net) = router.cashOutVia(x);

        assertEq(lender.lent0(), 0, "nothing of token0");
        assertEq(lender.lent1(), CAP, "the cap, as token1");
        assertEq(lender.fee1Charged(), FEE_500, "the fee on the cap, as token1");
        uint256 r = SALE - CAP - FEE_500;
        assertEq(gross, SALE, "gross");
        assertEq(financeFee, FEE_500, "finance fee");
        assertEq(platformFee, r * 50 / 10_000, "fee");
        assertEq(net, r - r * 50 / 10_000, "net");
        assertEq(usdg.balanceOf(address(lender)), lenderBefore + FEE_500, "the lender repaid with its fee");
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        _assertNoResidue();
    }

    /// @dev The lender is locked while it lends: a route through it reverts, and the caller names another.
    function test_cashOutVia_routeThroughTheLenderRevertsLOK() public {
        ViaV3Executor v3 = new ViaV3Executor();
        router.setExecutor(address(v3), true);
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, 0);
        x.executor = address(v3);
        x.data = abi.encodeCall(ViaV3Executor.sell, (usdgCol, address(col), COLLATERAL, address(router)));
        (x.flashToken, x.flashFee) = (address(col), 3000);
        vm.prank(borrower);
        vm.expectRevert(bytes("LOK"));
        router.cashOutVia(x);

        (x.flashToken, x.flashFee) = (address(weth), 500);
        vm.prank(borrower);
        (uint256 gross,,, uint256 net) = router.cashOutVia(x);
        assertGt(gross, 250_000e6, "about 100 COL sold at 3,000 USDG");
        assertEq(usdg.balanceOf(borrower), net, "paid");
        _assertNoResidue();
    }

    function test_cashOutVia_sellsThroughAV4PoolDuringTheFlash() public {
        ViaV4Executor v4 = new ViaV4Executor(poolManager);
        router.setExecutor(address(v4), true);
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, 0);
        x.executor = address(v4);
        x.data = abi.encodeCall(ViaV4Executor.sell, (colUsdgKey, address(col), COLLATERAL, address(router)));
        uint256 pmCol = col.balanceOf(address(poolManager));
        vm.prank(borrower);
        (uint256 gross,,, uint256 net) = router.cashOutVia(x);
        assertEq(col.balanceOf(address(poolManager)), pmCol + COLLATERAL, "sold through the v4 pool");
        assertGt(gross, 250_000e6, "about 100 COL sold at 3,000 USDG");
        assertEq(usdg.balanceOf(borrower), net, "paid");
        _assertNoResidue();
    }

    /// @dev The stand-in r7 admits on the testnet (D245), selling over a v3 + v4 split, exactly as it quoted.
    function test_cashOutVia_throughTheTestnetAggregator() public {
        TestnetAggregator standIn = new TestnetAggregator(poolManager, IUniV3Factory(v3Factory));
        router.setExecutor(address(standIn), true);
        uint256 id = _activeLoan();
        TestnetAggregator.Swap memory s;
        (s.tokenIn, s.tokenOut, s.amountIn, s.minReturn) = (address(col), address(usdg), COLLATERAL, 1);
        (s.recipient, s.deadline) = (address(router), block.timestamp);
        s.paths = new TestnetAggregator.Path[](2);
        s.paths[0].amountIn = COLLATERAL / 2;
        s.paths[0].hops = new TestnetAggregator.Hop[](1);
        s.paths[0].hops[0] = TestnetAggregator.Hop(TestnetAggregator.Venue.V3, address(usdg), 3000, 0);
        s.paths[1].amountIn = COLLATERAL - COLLATERAL / 2;
        s.paths[1].hops = new TestnetAggregator.Hop[](1);
        s.paths[1].hops[0] = TestnetAggregator.Hop(TestnetAggregator.Venue.V4, address(usdg), 3000, TICK_SPACING);
        uint256 quoted;
        try standIn.quote(s) {
            revert("quote returned");
        } catch (bytes memory err) {
            assertEq(bytes4(err), TestnetAggregator.Quoted.selector, "Quoted");
            assembly ("memory-safe") {
                quoted := mload(add(err, 36))
            }
        }
        s.minReturn = quoted * 9950 / 10_000;

        GageV2CashoutRouter.ExitVia memory x = _via(id, 0);
        x.executor = address(standIn);
        x.data = abi.encodeCall(TestnetAggregator.swap, (s));
        x.minUsdgOut = s.minReturn;
        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.SoldVia(id, address(standIn), flashPool, COLLATERAL, quoted, FEE_500);
        vm.prank(borrower);
        (uint256 gross,,, uint256 net) = router.cashOutVia(x);
        assertEq(gross, quoted, "sold exactly as quoted");
        assertEq(usdg.balanceOf(borrower), net, "paid");
        assertEq(col.balanceOf(address(standIn)), 0, "the stand-in holds nothing");
        assertEq(usdg.balanceOf(address(standIn)), 0, "the stand-in holds nothing");
        _assertNoResidue();
    }

    // ----------------------------------------------------------------- refusals

    function test_cashOutVia_refusesALenderTheFactoryDoesNotHave() public {
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.flashFee = 3000;
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector));
        (x.flashToken, x.flashFee) = (address(usdg), 500);
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector));
    }

    function test_cashOutVia_refusesAnExecutorNotAdmitted() public {
        uint256 id = _activeLoan();
        ViaMockAggregator other = new ViaMockAggregator();
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.executor = address(other);
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.InvalidExecutor.selector));
        router.setExecutor(address(agg), false);
        _expectVia(_via(id, SALE), abi.encodeWithSelector(GageV2CashoutRouter.InvalidExecutor.selector));
    }

    /// @dev As `cashOutDetailed` (Pashov M-14, acknowledged): the holder's alone, never an operator's or a stranger's.
    function test_cashOutVia_holderOnly() public {
        uint256 id = _activeLoan();
        address operator = makeAddr("operator");
        vm.prank(borrower);
        vault.setApprovalForAll(operator, true);
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        vm.prank(operator);
        vm.expectRevert(GageV2CashoutRouter.InvalidExit.selector);
        router.cashOutVia(x);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(GageV2CashoutRouter.InvalidExit.selector);
        router.cashOutVia(x);
    }

    function test_cashOutVia_refusesABadExit() public {
        uint256 id = _activeLoan();
        bytes memory invalid = abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector);
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.recipient = address(0);
        _expectVia(x, invalid);
        x = _via(id, SALE);
        x.recipient = address(router);
        _expectVia(x, invalid);
        x = _via(id, SALE);
        x.minimumNet = 0;
        _expectVia(x, invalid);
        x = _via(id, SALE);
        x.deadline = block.timestamp - 1;
        _expectVia(x, invalid);
        x = _via(id, SALE);
        x.deadline = block.timestamp + router.MAX_EXECUTION_WINDOW() + 1;
        _expectVia(x, invalid);
    }

    /// @dev Only an ACTIVE loan: a listing still funding is refused; a repaid or defaulted loan's right is burned, so the
    ///      holder check fails first, as for `cashOutDetailed`.
    function test_cashOutVia_refusesALoanNotActive() public {
        col.mint(borrower, COLLATERAL);
        vm.startPrank(borrower);
        col.approve(address(vault), COLLATERAL);
        uint256 listed = vault.list(
            Collateral(Kind.ERC20, address(col), COLLATERAL), 1000e6, CAP, TERM, uint40(block.timestamp + 1 days), false
        );
        vm.stopPrank();
        _expectVia(_via(listed, SALE), abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector));

        uint256 repaid = _activeLoan();
        usdg.mint(borrower, CAP);
        vm.startPrank(borrower);
        usdg.approve(address(vault), CAP);
        vault.reclaim(repaid, borrower);
        vm.stopPrank();
        _expectVia(_via(repaid, SALE), abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, repaid));

        uint256 defaulted = _activeLoan();
        vm.warp(block.timestamp + TERM + vault.GRACE());
        vault.finalizeDefault(defaulted);
        GageV2CashoutRouter.ExitVia memory x = _via(defaulted, SALE);
        _expectVia(x, abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, defaulted));

        // A loan read as DEFAULTED while its holder still holds the right is refused by the state check itself.
        uint256 id = _activeLoan();
        V2Loan memory l = vault.getLoan(id);
        l.state = V2State.DEFAULTED;
        vm.mockCall(address(vault), abi.encodeCall(GageV2Vault.getLoan, (id)), abi.encode(l));
        _expectVia(_via(id, SALE), abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector));
    }

    function test_cashOutVia_refusesUSDGCollateral() public {
        uint256 id = _activeLoan();
        V2Loan memory l = vault.getLoan(id);
        l.token = address(usdg);
        vm.mockCall(address(vault), abi.encodeCall(GageV2Vault.getLoan, (id)), abi.encode(l));
        _expectVia(_via(id, SALE), abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector));
    }

    function test_cashOutVia_shortSaleReverts() public {
        uint256 id = _activeLoan();
        _expectVia(_via(id, CAP + FEE_500 - 1), abi.encodeWithSelector(GageV2CashoutRouter.InsufficientOutput.selector));
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE), "nothing moved");
    }

    function test_cashOutVia_belowMinUsdgOutReverts() public {
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.minUsdgOut = SALE + 1;
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.InsufficientOutput.selector));
        x.minUsdgOut = SALE;
        vm.prank(borrower);
        router.cashOutVia(x);
    }

    function test_cashOutVia_belowMinimumNetReverts() public {
        uint256 id = _activeLoan();
        uint256 r = SALE - CAP - FEE_500;
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.minimumNet = r - r * 50 / 10_000 + 1;
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.InsufficientOutput.selector));
        x.minimumNet -= 1;
        vm.prank(borrower);
        router.cashOutVia(x);
    }

    function test_cashOutVia_financeFeeAboveMaxReverts() public {
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.maxFinanceFee = FEE_500 - 1;
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.InsufficientOutput.selector));
        x.maxFinanceFee = FEE_500;
        vm.prank(borrower);
        router.cashOutVia(x);
    }

    /// @dev No dust (D245): every unit of the collateral must leave, and none may come back.
    function test_cashOutVia_leftoverCollateralReverts() public {
        uint256 id = _activeLoan();
        bytes memory invalid = abi.encodeWithSelector(GageV2CashoutRouter.InvalidExit.selector);
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        // Takes less than the whole collateral.
        x.data = abi.encodeCall(
            ViaMockAggregator.sell, (IERC20(address(col)), COLLATERAL - 1, IERC20(address(usdg)), SALE, address(router))
        );
        _expectVia(x, invalid);
        // Takes all of it, then refunds part.
        x.data = abi.encodeCall(
            ViaMockAggregator.sellAndSendBack,
            (IERC20(address(col)), COLLATERAL, 1, IERC20(address(usdg)), SALE, address(router))
        );
        _expectVia(x, invalid);
        // Takes all of it, then pushes more collateral in than it took.
        col.mint(address(agg), 5e18);
        x.data = abi.encodeCall(
            ViaMockAggregator.sellAndSendBack,
            (IERC20(address(col)), COLLATERAL, COLLATERAL + 5e18, IERC20(address(usdg)), SALE, address(router))
        );
        _expectVia(x, invalid);
    }

    function test_cashOutVia_executorCannotPullMoreThanTheCollateral() public {
        uint256 id = _activeLoan();
        col.mint(address(router), 7e18);
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.data = abi.encodeCall(
            ViaMockAggregator.sell, (IERC20(address(col)), COLLATERAL + 1, IERC20(address(usdg)), SALE, address(router))
        );
        _expectVia(
            x,
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(agg), COLLATERAL, COLLATERAL + 1
            )
        );
        assertEq(col.balanceOf(address(router)), 7e18, "the router's own collateral stays");
    }

    function test_cashOutVia_preexistingBalancesNeverSpentOrPaid() public {
        uint256 id = _activeLoan();
        usdg.mint(address(router), 123e6);
        col.mint(address(router), 7e18);
        weth.transfer(address(router), 1e18);
        vm.deal(address(router), 1 ether);
        vm.prank(borrower);
        (,, uint256 platformFee, uint256 net) = router.cashOutVia(_via(id, SALE));
        uint256 r = SALE - CAP - FEE_500;
        assertEq(net, r - r * 50 / 10_000, "what an empty router pays");
        assertEq(usdg.balanceOf(borrower), net, "recipient");
        assertEq(usdg.balanceOf(fees), platformFee, "fee recipient");
        assertEq(usdg.balanceOf(address(router)), 123e6, "router USDG");
        assertEq(col.balanceOf(address(router)), 7e18, "router COL");
        assertEq(weth.balanceOf(address(router)), 1e18, "router WETH");
        assertEq(address(router).balance, 1 ether, "router ETH");
    }

    function test_cashOutVia_bubblesTheExecutorsRevert() public {
        uint256 id = _activeLoan();
        GageV2CashoutRouter.ExitVia memory x = _via(id, SALE);
        x.data = abi.encodeCall(ViaMockAggregator.decline, ());
        _expectVia(x, abi.encodeWithSignature("Error(string)", "declined"));
    }

    function test_cashOutVia_poolThatNeverCallsBackReverts() public {
        uint256 id = _activeLoan();
        vm.mockCall(flashPool, abi.encodeWithSelector(IV2FlashPool.flash.selector), "");
        _expectVia(_via(id, SALE), abi.encodeWithSelector(GageV2CashoutRouter.BadCallback.selector));
    }

    /// @dev One ERC-721 approval of the router serves both entries.
    function test_cashOutVia_oneApprovalServesBothEntries() public {
        uint256 id = _activeLoan();
        uint256 snap = vm.snapshotState();
        vm.prank(borrower);
        router.cashOutVia(_via(id, SALE));
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID), "through the executor");
        vm.revertToState(snap);
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = _route(GageV2CashoutRouter.RouteKind.V4, address(col), address(0), 0, colEthKey);
        routes[1] = _route(GageV2CashoutRouter.RouteKind.V4, address(0), address(usdg), 0, ethKey);
        _cashOut(id, routes);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID), "through the admitted routes");
    }

    // ----------------------------------------------------------------- reentry, from inside the executor's call

    function test_cashOutVia_reentersCashOutDetailed() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        GageV2CashoutRouter.Exit memory e = _exit(x.loanId, new GageV2CashoutRouter.Route[](0));
        ex.arm(address(router), abi.encodeCall(GageV2CashoutRouter.cashOutDetailed, (e)));
        _expectVia(x, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
    }

    function test_cashOutVia_reentersCashOutVia() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(address(router), abi.encodeCall(GageV2CashoutRouter.cashOutVia, (x)));
        _expectVia(x, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));
    }

    function test_cashOutVia_callsFlashCallbackDirectly() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(address(router), abi.encodeCall(GageV2CashoutRouter.uniswapV3FlashCallback, (0, 0, "")));
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.BadCallback.selector));
    }

    /// @dev With the second pool lending, `FLASH_POOL` is free to flash: a V3 pool calls back its caller, here the
    ///      executor, which passes the callback on to the router; the router finds the aggregator branch already
    ///      cleared and the caller not `FLASH_POOL`. With `FLASH_POOL` lending, it is locked.
    function test_cashOutVia_triggersFlashPoolFlash() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(flashPool, abi.encodeCall(IV2FlashPool.flash, (address(router), 1, 0, "")));
        (x.flashToken, x.flashFee) = (address(col), 3000);
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.BadCallback.selector));
        (x.flashToken, x.flashFee) = (address(weth), 500);
        _expectVia(x, abi.encodeWithSignature("Error(string)", "LOK"));
    }

    function test_cashOutVia_callsSwapCallback() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(
            address(router),
            abi.encodeCall(GageV2CashoutRouter.uniswapV3SwapCallback, (1, -1, abi.encode(address(col), uint256(1))))
        );
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.BadCallback.selector));
    }

    function test_cashOutVia_callsUnlockCallback() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(address(router), abi.encodeCall(GageV2CashoutRouter.unlockCallback, ("")));
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.BadCallback.selector));
    }

    function test_cashOutVia_unlocksThePoolManagerAndCallsBack() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(address(poolManager), abi.encodeCall(IPoolManager.unlock, ("")));
        _expectVia(x, abi.encodeWithSelector(GageV2CashoutRouter.BadCallback.selector));
    }

    function test_cashOutVia_flashesOrSwapsTheLockedLender() public {
        (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) = _reentrant();
        ex.arm(flashPool, abi.encodeCall(IV2FlashPool.flash, (address(ex), 1, 0, "")));
        _expectVia(x, abi.encodeWithSignature("Error(string)", "LOK"));
        ex.arm(
            flashPool,
            abi.encodeCall(IV2FlashPool.swap, (address(ex), true, int256(1), TickMath.MIN_SQRT_PRICE + 1, bytes("")))
        );
        _expectVia(x, abi.encodeWithSignature("Error(string)", "LOK"));
    }

    /// @dev The aggregator branch answers its lender only during `cashOutVia`'s flash. Both entries run back to back in
    ///      one transaction (a forge test is one), which shows the transient slots are clear after each.
    function test_uniswapV3FlashCallback_aggregatorBranchOnlyDuringCashOutVia() public {
        vm.prank(flashPool);
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3FlashCallback(0, 0, "");
        vm.prank(usdgCol);
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3FlashCallback(0, 0, "");

        uint256 first = _activeLoan();
        uint256 second = _activeLoan();
        vm.prank(borrower);
        router.cashOutVia(_via(first, SALE));
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = _route(GageV2CashoutRouter.RouteKind.V4, address(col), address(0), 0, colEthKey);
        routes[1] = _route(GageV2CashoutRouter.RouteKind.V4, address(0), address(usdg), 0, ethKey);
        _cashOut(second, routes);
        assertEq(uint256(vault.getLoan(first).state), uint256(V2State.REPAID), "first");
        assertEq(uint256(vault.getLoan(second).state), uint256(V2State.REPAID), "second");
        vm.prank(flashPool);
        vm.expectRevert(GageV2CashoutRouter.BadCallback.selector);
        router.uniswapV3FlashCallback(0, 0, "");
    }

    // ----------------------------------------------------------------- admission

    function test_setExecutor_ownerOnlyAndNeverADependency() public {
        ViaMockAggregator other = new ViaMockAggregator();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setExecutor(address(other), true);

        // The fee recipient is an account without code here; give it some so the dependency check itself refuses it.
        vm.etch(fees, hex"00");
        address bridge = address(new ViaMockAggregator());
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.BRIDGE.selector), abi.encode(bridge));
        // sGAGE, which the core holds and pays, is never an executor either (the D245 reviews).
        address sgage = address(vault.SGAGE());
        if (sgage.code.length == 0) vm.etch(sgage, hex"00");
        address[14] memory refused = [
            makeAddr("an account"),
            address(router),
            address(vault),
            address(usdg),
            address(weth),
            v3Factory,
            flashPool,
            address(poolManager),
            fees,
            address(vault.REGISTRY()),
            address(vault.REWARDS()),
            vault.ACCOUNT_IMPLEMENTATION(),
            bridge,
            sgage
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(GageV2CashoutRouter.InvalidExecutor.selector);
            router.setExecutor(refused[i], true);
            assertFalse(router.executorAllowed(refused[i]), "never admitted");
        }

        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.ExecutorSet(address(other), true);
        router.setExecutor(address(other), true);
        assertTrue(router.executorAllowed(address(other)), "admitted");
        vm.expectEmit(address(router));
        emit GageV2CashoutRouter.ExecutorSet(address(other), false);
        router.setExecutor(address(other), false);
        assertFalse(router.executorAllowed(address(other)), "dropped");
        // Dropping needs no check.
        router.setExecutor(makeAddr("an account"), false);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev A v3 pool where `amountB` of `tokenB` buys `amountA` of `tokenA`, with `liquidity` over its full range.
    function _v3PoolAt(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        uint24 fee,
        int24 spacing,
        uint128 liquidity
    ) internal returns (address pool) {
        pool = IV3FactorySetup(v3Factory).createPool(tokenA, tokenB, fee);
        IV3PoolSetup(pool)
            .initialize(tokenA < tokenB ? _sqrtPriceX96(amountB, amountA) : _sqrtPriceX96(amountA, amountB));
        int24 top = TickMath.MAX_TICK / spacing * spacing;
        IV3PoolSetup(pool).mint(address(this), -top, top, liquidity, "");
    }

    /// @dev An exit selling the whole collateral to the suite's aggregator for `usdgOut`, `FLASH_POOL` lending.
    function _via(uint256 id, uint256 usdgOut) internal view returns (GageV2CashoutRouter.ExitVia memory) {
        return GageV2CashoutRouter.ExitVia({
            loanId: id,
            recipient: borrower,
            minimumNet: 1,
            maxFinanceFee: 10e6,
            deadline: block.timestamp,
            executor: address(agg),
            data: abi.encodeCall(
                ViaMockAggregator.sell,
                (IERC20(address(col)), COLLATERAL, IERC20(address(usdg)), usdgOut, address(router))
            ),
            flashToken: address(weth),
            flashFee: 500,
            minUsdgOut: 1
        });
    }

    function _expectVia(GageV2CashoutRouter.ExitVia memory x, bytes memory err) internal {
        vm.prank(borrower);
        vm.expectRevert(err);
        router.cashOutVia(x);
    }

    /// @dev A loan and an exit through a reentrant executor the owner admitted.
    function _reentrant() internal returns (ViaReentrantExecutor ex, GageV2CashoutRouter.ExitVia memory x) {
        ex = new ViaReentrantExecutor(address(router));
        router.setExecutor(address(ex), true);
        x = _via(_activeLoan(), 0);
        x.executor = address(ex);
        x.data = abi.encodeCall(ViaReentrantExecutor.sell, (IERC20(address(col)), COLLATERAL));
    }
}
