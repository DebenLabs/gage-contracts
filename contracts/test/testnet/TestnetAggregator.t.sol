// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {IUniV3Factory, IUniV3Pool} from "../../src/interfaces/IUniV3.sol";
import {TestnetOnly} from "../../src/testnet/TestnetOnly.sol";
import {TestnetAggregator} from "../../src/testnet/TestnetAggregator.sol";

/// @dev The canonical v3 factory and pool calls this suite makes to build its pools.
interface IAggV3FactorySetup {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IAggV3PoolSetup {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @dev A token whose every transfer, once armed, calls the aggregator back with the swap it is armed with.
contract AggReentrantToken is ERC20 {
    TestnetAggregator internal _agg;
    bytes internal _call;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(TestnetAggregator agg, bytes calldata data) external {
        (_agg, _call) = (agg, data);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(_agg) != address(0) && from != address(0)) {
            (bool ok, bytes memory err) = address(_agg).call(_call);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(err, 0x20), mload(err))
                }
            }
        }
    }
}

/// @notice The testnet stand-in for KyberSwap's router (D245) over a real Uniswap v4 PoolManager and the canonical v3
///         factory: exact-input sales across up to four paths of up to three hops, every pool used once, exact quotes.
contract TestnetAggregatorTest is V4Fixture {
    string internal constant V3_FACTORY_BYTECODE = "lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode";

    MockERC20 internal usdg;
    MockERC20 internal a;
    MockERC20 internal b;
    MockERC20 internal c;
    MockERC20 internal d;
    address internal v3Factory;
    /// @dev v3 A/USDG 0.05% and B/USDG 0.3%, both full range; D/USDG 0.3% narrow, to run dry.
    address internal aUsdgV3;
    address internal bUsdgV3;
    address internal dUsdgV3;
    /// @dev v4 hookless A/USDG 0.3% and A/C 0.3%, full range; D/USDG 0.3% narrow; C/USDG only behind a hook.
    PoolKey internal aUsdgV4;
    PoolKey internal acV4;
    PoolKey internal dUsdgV4;
    PoolKey internal cUsdgHooked;
    TestnetAggregator internal agg;

    address internal seller = makeAddr("seller");
    address internal recipient = makeAddr("recipient");
    address internal lp = makeAddr("lp");

    function setUp() public {
        vm.warp(10_000);
        usdg = new MockERC20("test USDG", "tUSDG", 6);
        a = new MockERC20("token A", "A", 18);
        b = new MockERC20("token B", "B", 18);
        c = new MockERC20("token C", "C", 18);
        d = new MockERC20("token D", "D", 18);
        address[5] memory tokens = [address(usdg), address(a), address(b), address(c), address(d)];
        for (uint256 i; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(address(this), 1e30);
            MockERC20(tokens[i]).mint(lp, 1e30);
        }

        bytes memory code = vm.readFileBinary(V3_FACTORY_BYTECODE);
        address factory;
        assembly ("memory-safe") {
            factory := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(factory != address(0), "v3 factory");
        v3Factory = factory;
        // 10 USDG per A and 5 USDG per B; D at 1 USDG over a narrow range.
        aUsdgV3 = _v3Pool(address(a), 1e18, address(usdg), 10e6, 500, 10, 1e17, true);
        bUsdgV3 = _v3Pool(address(b), 1e18, address(usdg), 5e6, 3000, 60, 1e17, true);
        dUsdgV3 = _v3Pool(address(d), 1e18, address(usdg), 1e6, 3000, 60, 1e12, false);

        _deployV4();
        aUsdgV4 = _initPoolAtPrice(address(a), 1e18, address(usdg), 10e6, address(0));
        _addRawLiquidity(aUsdgV4, FULL_LOWER, FULL_UPPER, 1e17, lp);
        // 2 C per A.
        acV4 = _initPoolAtPrice(address(a), 1e18, address(c), 2e18, address(0));
        _addRawLiquidity(acV4, FULL_LOWER, FULL_UPPER, 1e22, lp);
        dUsdgV4 = _initPoolAtPrice(address(d), 1e18, address(usdg), 1e6, address(0));
        int24 tick = _currentTick(dUsdgV4) / TICK_SPACING * TICK_SPACING;
        _addRawLiquidity(dUsdgV4, tick - 120, tick + 120, 1e12, lp);
        // A dynamic-fee pool whose hook has no flags: a hooked pool the stand-in's hookless keys never name.
        (cUsdgHooked.currency0, cUsdgHooked.currency1) = _sorted(address(c), address(usdg));
        (cUsdgHooked.fee, cUsdgHooked.tickSpacing) = (0x800000, TICK_SPACING);
        cUsdgHooked.hooks = IHooks(address(0x10000));
        poolManager.initialize(cUsdgHooked, _sqrtPriceAt(address(c), 1e18, address(usdg), 1e6));

        agg = new TestnetAggregator(poolManager, IUniV3Factory(v3Factory));
        for (uint256 i; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(seller, 1e24);
            vm.prank(seller);
            IERC20(tokens[i]).approve(address(agg), type(uint256).max);
        }
    }

    // ----------------------------------------------------------------- construction

    function test_constructor_revertsOnMainnet() public {
        vm.chainId(4663);
        vm.expectRevert(TestnetOnly.MainnetForbidden.selector);
        new TestnetAggregator(poolManager, IUniV3Factory(v3Factory));
    }

    function test_constructor_refusesAManagerOrFactoryWithoutCode() public {
        vm.expectRevert(TestnetAggregator.BadSwap.selector);
        new TestnetAggregator(IPoolManager(makeAddr("no manager")), IUniV3Factory(v3Factory));
        vm.expectRevert(TestnetAggregator.BadSwap.selector);
        new TestnetAggregator(poolManager, IUniV3Factory(makeAddr("no factory")));
    }

    // ----------------------------------------------------------------- shapes

    function test_swap_oneV3Hop() public {
        _assertSale(_single(address(a), address(usdg), 10e18, _v3(address(usdg), 500)));
    }

    function test_swap_oneV4Hop() public {
        _assertSale(_single(address(usdg), address(a), 100e6, _v4(address(a))));
    }

    function test_swap_twoHopPathThroughV4ThenV3() public {
        TestnetAggregator.Hop[] memory hops = new TestnetAggregator.Hop[](2);
        hops[0] = _v4(address(a));
        hops[1] = _v3(address(usdg), 500);
        _assertSale(_one(address(c), address(usdg), 20e18, hops));
    }

    function test_swap_twoPathSplitOverV3AndV4() public {
        _assertSale(_split(address(a), address(usdg), 6e18, 4e18));
    }

    function test_swap_splitBuysTheOtherWay() public {
        TestnetAggregator.Swap memory s = _split(address(a), address(usdg), 0, 0);
        (s.tokenIn, s.tokenOut, s.amountIn) = (address(usdg), address(a), 100e6);
        s.paths[0].amountIn = 30e6;
        s.paths[0].hops[0] = _v3(address(a), 500);
        s.paths[1].amountIn = 70e6;
        s.paths[1].hops[0] = _v4(address(a));
        _assertSale(s);
    }

    // ----------------------------------------------------------------- pull, fees, minimums

    function test_swap_pullsExactlyAmountIn() public {
        TestnetAggregator.Swap memory s = _single(address(a), address(usdg), 10e18, _v3(address(usdg), 500));
        address payer = makeAddr("payer");
        a.mint(payer, 20e18);
        vm.startPrank(payer);
        a.approve(address(agg), 10e18 - 1);
        vm.expectRevert();
        agg.swap(s);
        a.approve(address(agg), 10e18);
        agg.swap(s);
        vm.stopPrank();
        assertEq(a.balanceOf(payer), 10e18, "exactly amountIn taken");
        assertEq(a.allowance(payer, address(agg)), 0, "the approval used up");
    }

    function test_swap_refusesAFeeOnTransferToken() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20();
        fot.mint(seller, 1e18);
        vm.prank(seller);
        fot.approve(address(agg), 1e18);
        TestnetAggregator.Swap memory s = _single(address(fot), address(usdg), 1e18, _v4(address(usdg)));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TestnetAggregator.InexactPull.selector, 1e18, 99e16));
        agg.swap(s);
    }

    function test_swap_minReturn() public {
        TestnetAggregator.Swap memory s = _single(address(a), address(usdg), 10e18, _v3(address(usdg), 500));
        uint256 out = _quote(s);
        s.minReturn = out + 1;
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TestnetAggregator.ReturnTooLow.selector, out, out + 1));
        agg.swap(s);
        s.minReturn = out;
        vm.prank(seller);
        assertEq(agg.swap(s), out, "exactly the minimum");
    }

    /// @dev Tokens sent to the stand-in outside a swap are neither sold nor paid out: every figure is measured above them.
    function test_swap_neverPaysOutWhatItAlreadyHeld() public {
        TestnetAggregator.Swap memory s = _split(address(a), address(usdg), 6e18, 4e18);
        uint256 quoted = _quote(s);
        a.mint(address(agg), 1e18);
        usdg.mint(address(agg), 7e6);
        vm.prank(seller);
        assertEq(agg.swap(s), quoted, "the quote, not the stray balance");
        assertEq(usdg.balanceOf(recipient), quoted, "the recipient paid the sale only");
        assertEq(a.balanceOf(address(agg)), 1e18, "stray input kept");
        assertEq(usdg.balanceOf(address(agg)), 7e6, "stray output kept");
    }

    function test_swap_expired() public {
        TestnetAggregator.Swap memory s = _single(address(a), address(usdg), 10e18, _v3(address(usdg), 500));
        s.deadline = block.timestamp - 1;
        vm.prank(seller);
        vm.expectRevert(TestnetAggregator.Expired.selector);
        agg.swap(s);
    }

    // ----------------------------------------------------------------- validation

    function test_swap_badSwap() public {
        TestnetAggregator.Swap memory s = _split(address(a), address(usdg), 6e18, 4e18);
        TestnetAggregator.Swap memory bad = _copy(s);
        bad.tokenIn = address(0);
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.tokenOut = address(0);
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.tokenOut = address(a);
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.amountIn = 10e18 + 1;
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.recipient = address(0);
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.recipient = address(agg);
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.paths = new TestnetAggregator.Path[](0);
        bad.amountIn = 0;
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        bad = _copy(s);
        bad.paths = new TestnetAggregator.Path[](5);
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
        // An amount above int256's range.
        bad = _single(address(a), address(usdg), uint256(type(int256).max) + 1, _v3(address(usdg), 500));
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadSwap.selector));
    }

    function test_swap_badPath() public {
        TestnetAggregator.Swap memory s = _split(address(a), address(usdg), 6e18, 4e18);
        bytes memory bad1 = abi.encodeWithSelector(TestnetAggregator.BadPath.selector, 1);
        // No hops.
        TestnetAggregator.Swap memory bad = _copy(s);
        bad.paths[1].hops = new TestnetAggregator.Hop[](0);
        _expectSwapRevert(bad, bad1);
        // Four hops.
        bad = _copy(s);
        bad.paths[1].hops = new TestnetAggregator.Hop[](4);
        _expectSwapRevert(bad, bad1);
        // The last hop ends elsewhere.
        bad = _copy(s);
        bad.paths[1].hops[0] = _v4(address(c));
        _expectSwapRevert(bad, bad1);
        // A token visited twice: A to C, back to A, then USDG.
        bad = _copy(s);
        TestnetAggregator.Hop[] memory loop = new TestnetAggregator.Hop[](3);
        (loop[0], loop[1], loop[2]) = (_v4(address(c)), _v4(address(a)), _v4(address(usdg)));
        bad.paths[1].hops = loop;
        _expectSwapRevert(bad, bad1);
        // A hop to the zero address or to its own input.
        bad = _copy(s);
        TestnetAggregator.Hop[] memory two = new TestnetAggregator.Hop[](2);
        (two[0], two[1]) = (_v4(address(0)), _v4(address(usdg)));
        bad.paths[1].hops = two;
        _expectSwapRevert(bad, bad1);
        // A path that sells nothing.
        bad = _copy(s);
        (bad.paths[0].amountIn, bad.paths[1].amountIn) = (10e18, 0);
        _expectSwapRevert(bad, bad1);
        // A V3 hop naming a tick spacing.
        bad = _copy(s);
        bad.paths[0].hops[0].tickSpacing = 10;
        _expectSwapRevert(bad, abi.encodeWithSelector(TestnetAggregator.BadPath.selector, 0));
    }

    function test_swap_repeatedPool() public {
        // Both paths through the same v3 pool.
        TestnetAggregator.Swap memory s = _split(address(a), address(usdg), 6e18, 4e18);
        s.paths[1].hops[0] = _v3(address(usdg), 500);
        _expectSwapRevert(s, abi.encodeWithSelector(TestnetAggregator.RepeatedPool.selector, 1, 0));
        // Both through the same v4 pool.
        s = _split(address(a), address(usdg), 6e18, 4e18);
        s.paths[0].hops[0] = _v4(address(usdg));
        _expectSwapRevert(s, abi.encodeWithSelector(TestnetAggregator.RepeatedPool.selector, 1, 0));
    }

    function test_swap_unknownPool() public {
        TestnetAggregator.Swap memory s = _single(address(a), address(usdg), 10e18, _v3(address(usdg), 100));
        _expectSwapRevert(s, abi.encodeWithSelector(TestnetAggregator.UnknownPool.selector, 0, 0));
    }

    function test_swap_partialFillReverts() public {
        // The narrow D/USDG pools run dry well before 1,000 D.
        TestnetAggregator.Swap memory s = _single(address(d), address(usdg), 1000e18, _v3(address(usdg), 3000));
        _expectSwapRevert(s, abi.encodeWithSelector(TestnetAggregator.PartialFill.selector, 0, 0));
        s = _single(address(d), address(usdg), 1000e18, _v4(address(usdg)));
        _expectSwapRevert(s, abi.encodeWithSelector(TestnetAggregator.PartialFill.selector, 0, 0));
        // And a quote says so too, rather than pricing a fill that would not happen.
        vm.expectRevert(abi.encodeWithSelector(TestnetAggregator.PartialFill.selector, 0, 0));
        agg.quote(s);
    }

    function test_swap_hookedPoolNotReachable() public {
        TestnetAggregator.Swap memory s = _single(address(c), address(usdg), 1e18, _v4(address(usdg)));
        vm.prank(seller);
        vm.expectRevert();
        agg.swap(s);
        s.paths[0].hops[0].fee = 0x800000;
        vm.prank(seller);
        vm.expectRevert();
        agg.swap(s);
    }

    // ----------------------------------------------------------------- quotes

    function test_quote_equalsSwap() public {
        TestnetAggregator.Hop[] memory hops = new TestnetAggregator.Hop[](2);
        hops[0] = _v4(address(a));
        hops[1] = _v3(address(usdg), 500);
        TestnetAggregator.Swap[4] memory shapes = [
            _single(address(a), address(usdg), 10e18, _v3(address(usdg), 500)),
            _single(address(usdg), address(a), 100e6, _v4(address(a))),
            _one(address(c), address(usdg), 20e18, hops),
            _split(address(a), address(usdg), 6e18, 4e18)
        ];
        for (uint256 i; i < shapes.length; ++i) {
            uint256 snap = vm.snapshotState();
            (uint256 quoted, uint256[] memory pathOut) = _quoteWithPaths(shapes[i]);
            uint256 sum;
            for (uint256 j; j < pathOut.length; ++j) {
                sum += pathOut[j];
            }
            assertEq(sum, quoted, "the paths add up");
            vm.prank(seller);
            assertEq(agg.swap(shapes[i]), quoted, "the quote is the swap");
            vm.revertToState(snap);
        }
    }

    function test_quote_takesNothingAndIgnoresMinReturnAndDeadline() public {
        TestnetAggregator.Swap memory s = _split(address(a), address(usdg), 6e18, 4e18);
        (s.minReturn, s.deadline, s.recipient) = (type(uint256).max, 0, address(0));
        uint256 before = a.balanceOf(seller);
        vm.prank(seller);
        assertGt(_quote(s), 0, "quoted");
        assertEq(a.balanceOf(seller), before, "nothing taken");
    }

    function test_quoteHop_onlySelf() public {
        vm.expectRevert(TestnetAggregator.BadSwap.selector);
        agg.quoteHop(address(a), _v3(address(usdg), 500), 1e18);
    }

    // ----------------------------------------------------------------- callbacks and reentry

    function test_callbacks_answerOnlyTheirPool() public {
        vm.expectRevert(TestnetAggregator.NotPool.selector);
        agg.uniswapV3SwapCallback(1, -1, abi.encode(address(a), uint256(1), uint256(0), uint256(0)));
        vm.prank(aUsdgV3);
        vm.expectRevert(TestnetAggregator.NotPool.selector);
        agg.uniswapV3SwapCallback(1, -1, abi.encode(address(a), uint256(1), uint256(0), uint256(0)));
        vm.expectRevert(TestnetAggregator.NotPoolManager.selector);
        agg.unlockCallback("");
    }

    function test_swap_reentryRefused() public {
        AggReentrantToken re = new AggReentrantToken();
        re.mint(seller, 2e18);
        vm.prank(seller);
        re.approve(address(agg), type(uint256).max);
        TestnetAggregator.Swap memory s = _single(address(re), address(usdg), 1e18, _v4(address(usdg)));
        re.arm(agg, abi.encodeCall(TestnetAggregator.swap, (s)));
        vm.prank(seller);
        vm.expectRevert(TestnetAggregator.Reentered.selector);
        agg.swap(s);
    }

    // ----------------------------------------------------------------- v3 mint callback of this suite

    /// @notice Pays the suite's own v3 mints.
    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        if (owed0 != 0) IERC20(IUniV3Pool(msg.sender).token0()).transfer(msg.sender, owed0);
        if (owed1 != 0) IERC20(IUniV3Pool(msg.sender).token1()).transfer(msg.sender, owed1);
    }

    // ----------------------------------------------------------------- helpers

    function _sqrtPriceAt(address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        internal
        pure
        returns (uint160)
    {
        return tokenA < tokenB ? _sqrtPriceX96(amountB, amountA) : _sqrtPriceX96(amountA, amountB);
    }

    /// @dev A v3 pool where `amountB` of `tokenB` buys `amountA` of `tokenA`, with `liquidity` over its full range or
    ///      over twelve spacings around the price.
    function _v3Pool(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        uint24 fee,
        int24 spacing,
        uint128 liquidity,
        bool full
    ) internal returns (address pool) {
        pool = IAggV3FactorySetup(v3Factory).createPool(tokenA, tokenB, fee);
        uint160 price = _sqrtPriceAt(tokenA, amountA, tokenB, amountB);
        IAggV3PoolSetup(pool).initialize(price);
        int24 top = TickMath.MAX_TICK / spacing * spacing;
        int24 tick = TickMath.getTickAtSqrtPrice(price) / spacing * spacing;
        (int24 lower, int24 upper) = full ? (-top, top) : (tick - 2 * spacing, tick + 2 * spacing);
        IAggV3PoolSetup(pool).mint(address(this), lower, upper, liquidity, "");
    }

    function _v3(address tokenOut, uint24 fee) internal pure returns (TestnetAggregator.Hop memory) {
        return TestnetAggregator.Hop({venue: TestnetAggregator.Venue.V3, tokenOut: tokenOut, fee: fee, tickSpacing: 0});
    }

    function _v4(address tokenOut) internal pure returns (TestnetAggregator.Hop memory) {
        return TestnetAggregator.Hop({
            venue: TestnetAggregator.Venue.V4, tokenOut: tokenOut, fee: 3000, tickSpacing: TICK_SPACING
        });
    }

    function _one(address tokenIn, address tokenOut, uint256 amountIn, TestnetAggregator.Hop[] memory hops)
        internal
        view
        returns (TestnetAggregator.Swap memory s)
    {
        s.tokenIn = tokenIn;
        s.tokenOut = tokenOut;
        s.amountIn = amountIn;
        s.minReturn = 1;
        s.recipient = recipient;
        s.deadline = block.timestamp;
        s.paths = new TestnetAggregator.Path[](1);
        s.paths[0] = TestnetAggregator.Path({amountIn: amountIn, hops: hops});
    }

    function _single(address tokenIn, address tokenOut, uint256 amountIn, TestnetAggregator.Hop memory hop)
        internal
        view
        returns (TestnetAggregator.Swap memory)
    {
        TestnetAggregator.Hop[] memory hops = new TestnetAggregator.Hop[](1);
        hops[0] = hop;
        return _one(tokenIn, tokenOut, amountIn, hops);
    }

    /// @dev `tokenIn` to `tokenOut` (A and USDG) in two paths: `onV3` through the v3 0.05% pool, `onV4` through v4.
    function _split(address tokenIn, address tokenOut, uint256 onV3, uint256 onV4)
        internal
        view
        returns (TestnetAggregator.Swap memory s)
    {
        s = _single(tokenIn, tokenOut, onV3 + onV4, _v3(tokenOut, 500));
        s.paths[0].amountIn = onV3;
        TestnetAggregator.Path[] memory paths = new TestnetAggregator.Path[](2);
        paths[0] = s.paths[0];
        TestnetAggregator.Hop[] memory hops = new TestnetAggregator.Hop[](1);
        hops[0] = _v4(tokenOut);
        paths[1] = TestnetAggregator.Path({amountIn: onV4, hops: hops});
        s.paths = paths;
    }

    /// @dev A deep copy, so one case's edits never reach the next.
    function _copy(TestnetAggregator.Swap memory s) internal pure returns (TestnetAggregator.Swap memory) {
        return abi.decode(abi.encode(s), (TestnetAggregator.Swap));
    }

    function _expectSwapRevert(TestnetAggregator.Swap memory s, bytes memory err) internal {
        vm.prank(seller);
        vm.expectRevert(err);
        agg.swap(s);
    }

    function _quoteWithPaths(TestnetAggregator.Swap memory s)
        internal
        returns (uint256 amountOut, uint256[] memory pathOut)
    {
        try agg.quote(s) {
            revert("quote returned");
        } catch (bytes memory err) {
            assertEq(bytes4(err), TestnetAggregator.Quoted.selector, "Quoted");
            assembly ("memory-safe") {
                // Drop the selector: the rest is the ABI encoding of (amountOut, pathOut).
                let len := mload(err)
                err := add(err, 4)
                mstore(err, sub(len, 4))
            }
            (amountOut, pathOut) = abi.decode(err, (uint256, uint256[]));
        }
    }

    function _quote(TestnetAggregator.Swap memory s) internal returns (uint256 amountOut) {
        (amountOut,) = _quoteWithPaths(s);
    }

    /// @dev Sells `s` from the seller and checks the stand-in's whole contract: exactly `amountIn` pulled, the output at
    ///      the recipient and equal to the return value and to the quote, nothing held afterwards.
    function _assertSale(TestnetAggregator.Swap memory s) internal {
        IERC20 tokenIn = IERC20(s.tokenIn);
        IERC20 tokenOut = IERC20(s.tokenOut);
        uint256 quoted = _quote(s);
        uint256 sellerIn = tokenIn.balanceOf(seller);
        uint256 recipientOut = tokenOut.balanceOf(recipient);
        vm.expectEmit(address(agg));
        emit TestnetAggregator.Swapped(seller, s.tokenIn, s.tokenOut, s.amountIn, quoted, recipient);
        vm.prank(seller);
        uint256 out = agg.swap(s);
        assertGt(out, 0, "something bought");
        assertEq(out, quoted, "the quote");
        assertEq(sellerIn - tokenIn.balanceOf(seller), s.amountIn, "exactly amountIn pulled");
        assertEq(tokenOut.balanceOf(recipient) - recipientOut, out, "the output at the recipient");
        address[5] memory tokens = [address(usdg), address(a), address(b), address(c), address(d)];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(agg)), 0, "the stand-in holds nothing");
        }
    }
}
