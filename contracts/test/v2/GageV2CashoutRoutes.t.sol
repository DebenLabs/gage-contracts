// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {IUniV3Pool, IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {TestnetWETH} from "../../src/testnet/TestnetWETH.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";

/// @dev The canonical v3 factory and pool calls this suite makes to build its pools.
interface IV3FactorySetup {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolSetup {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @notice `cashOutDetailed` over real Uniswap pools, locally: the canonical v3 factory from the bytecode v4-core's
///         own v3/v4 differential tests deploy (`lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode`) and the
///         v4-core `PoolManager` artifact V4Fixture deploys. The fork suites run the same routes on the live chain
///         but skip without an RPC; these run in CI.
contract GageV2CashoutRoutesTest is V4Fixture {
    using SafeERC20 for IERC20;

    string internal constant V3_FACTORY_BYTECODE = "lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode";
    uint32 internal constant TERM = 7 days;
    uint128 internal constant CAP = 1100e6;
    uint256 internal constant COLLATERAL = 100e18;

    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal col;
    TestnetWETH internal weth;
    address internal v3Factory;
    address internal flashPool;
    address internal colWeth;
    PoolKey internal ethKey;
    PoolKey internal colEthKey;
    GageV2TokenRegistry internal registry;
    GageV2Vault internal vault;
    GageV2CashoutRouter internal router;
    address internal borrower = makeAddr("borrower");
    address internal lp = makeAddr("lp");
    address internal fees = makeAddr("fees");
    int256 internal lastDelta0;
    int256 internal lastDelta1;

    function setUp() public virtual {
        vm.warp(10_000);
        usdg = new MockERC20("test USDG", "tUSDG", 6);
        sgage = new MockERC20("test sGAGE", "tsGAGE", 18);
        col = new MockERC20("test collateral", "tCOL", 18);
        weth = new TestnetWETH();
        vm.deal(address(this), 20_000 ether);
        weth.deposit{value: 20_000 ether}();
        usdg.mint(address(this), 1e30);
        col.mint(address(this), 1e30);

        // Uniswap v3: the USDG/WETH flash source and a COL/WETH route pool, both full range at a raw price of 1.
        bytes memory code = vm.readFileBinary(V3_FACTORY_BYTECODE);
        address factory;
        assembly ("memory-safe") {
            factory := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(factory != address(0), "v3 factory");
        v3Factory = factory;
        flashPool = _v3Pool(address(usdg), address(weth), 500, 10, 1e13);
        colWeth = _v3Pool(address(col), address(weth), 3000, 60, 1e22);

        // Uniswap v4: native ETH/USDG at 3,000 USDG per ETH, and native ETH/COL at 1:1.
        _deployV4();
        vm.deal(lp, 30_000 ether);
        usdg.mint(lp, 1e30);
        col.mint(lp, 1e30);
        ethKey = _initPoolAtPrice(address(0), 1e18, address(usdg), 3000e6, address(0));
        _addRawLiquidityNative(ethKey, FULL_LOWER, FULL_UPPER, 5e16, lp, 2000 ether);
        colEthKey = _initPoolAtPrice(address(0), 1e18, address(col), 1e18, address(0));
        _addRawLiquidityNative(colEthKey, FULL_LOWER, FULL_UPPER, 1e22, lp, 20_000 ether);

        uint32[] memory terms = new uint32[](1);
        terms[0] = TERM;
        registry = new GageV2TokenRegistry(address(this), terms, v3Factory);
        registry.setERC20Allowed(address(col), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        vault = new GageV2Vault(
            registry, IERC20(address(usdg)), IERC20(address(sgage)), fees, 0, GageLegacyAdapter(address(0))
        );
        vault.REWARDS().bindFunderGate(new MockOpenFunderGate());
        router = new GageV2CashoutRouter(vault, IV2FlashPool(flashPool), poolManager, address(weth), address(this));
        router.setV3Route(colWeth, true);
        router.setV4Route(ethKey, true);
        router.setV4Route(colEthKey, true);
    }

    /// @dev Pashov M-40, M-83, M-85. The exit the admission fork suites use: COL to WETH on v3, `UNWRAP_WETH`, then
    /// native ETH to USDG on v4. The unwrap is an intermediate hop: the next route sells the ETH it produced back to
    /// the router's recorded balance, so the residual check passes (M-40). The v3 leg's `+amount` is exact input and
    /// passes the swap callback's check (M-83). The v4 leg's exact-input deltas pass `unlockCallback`'s signs (M-85).
    function test_threeHopExitThroughUnwrapAndNativeV4Repays() public {
        uint256 id = _activeLoan();
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](3);
        routes[0] = _route(GageV2CashoutRouter.RouteKind.V3, address(col), address(weth), 3000, ethKey);
        routes[1] = _route(GageV2CashoutRouter.RouteKind.UNWRAP_WETH, address(weth), address(0), 0, ethKey);
        routes[2] = _route(GageV2CashoutRouter.RouteKind.V4, address(0), address(usdg), 0, ethKey);
        (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net) = _cashOut(id, routes);

        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(financeFee, 550_000, "the 0.05% flash fee on the cap");
        assertGt(gross, 250_000e6, "about 99 ETH sold at 3,000 USDG");
        assertEq(usdg.balanceOf(borrower), net);
        assertEq(usdg.balanceOf(fees), platformFee);
        _assertNoResidue();
    }

    /// @dev Pashov M-40. An exit whose last route unwraps is refused on purpose: the router pays out USDG only. It
    /// fails before the residual check the finding names: no USDG was bought, so the flash repayment check reverts.
    function test_unwrapAsTheFinalRouteIsRefused() public {
        uint256 id = _activeLoan();
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = _route(GageV2CashoutRouter.RouteKind.V3, address(col), address(weth), 3000, ethKey);
        routes[1] = _route(GageV2CashoutRouter.RouteKind.UNWRAP_WETH, address(weth), address(0), 0, ethKey);
        GageV2CashoutRouter.Exit memory x = _exit(id, routes);
        vm.prank(borrower);
        vm.expectRevert(GageV2CashoutRouter.InsufficientOutput.selector);
        router.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    /// @dev Pashov M-83. On a real v3 pool a positive `amountSpecified` is exact input: the callback's input delta is
    /// exactly the amount and its output delta negative, which is what the router's swap callback requires. The
    /// recommended negative amount is exact output: the output delta is the amount and the input delta differs from
    /// it (on this pool it exceeds it), which fails that check.
    function test_v3PositiveAmountSpecifiedIsExactInput() public {
        bool colIs0 = IUniV3Pool(colWeth).token0() == address(col);
        uint160 limit = colIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        IV2FlashPool(colWeth).swap(address(this), colIs0, int256(1e18), limit, "");
        (int256 colDelta, int256 wethDelta) = colIs0 ? (lastDelta0, lastDelta1) : (lastDelta1, lastDelta0);
        assertEq(colDelta, 1e18, "+amount: the input delta is the amount");
        assertLt(wethDelta, 0, "+amount: the output delta is negative");

        IV2FlashPool(colWeth).swap(address(this), colIs0, -1e18, limit, "");
        (colDelta, wethDelta) = colIs0 ? (lastDelta0, lastDelta1) : (lastDelta1, lastDelta0);
        assertEq(wethDelta, -1e18, "-amount: the output delta is the amount");
        assertGt(colDelta, 1e18, "-amount: the input delta is not the amount");
    }

    /// @dev Pashov M-85. Two v4 legs, one per orientation, on the real `PoolManager`: COL to ETH on (ETH, COL) is
    /// `zeroForOne = false` and takes native ETH out; ETH to USDG on (ETH, USDG) is `zeroForOne = true` and settles
    /// native ETH in. Both pass `unlockCallback`'s sign checks: the input delta is negative, the output positive.
    function test_twoLegV4ExitInBothOrientationsRepays() public {
        assertEq(Currency.unwrap(colEthKey.currency1), address(col), "COL is currency1: zeroForOne = false");
        assertEq(Currency.unwrap(ethKey.currency0), address(0), "ETH is currency0: zeroForOne = true");
        uint256 id = _activeLoan();
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = _route(GageV2CashoutRouter.RouteKind.V4, address(col), address(0), 0, colEthKey);
        routes[1] = _route(GageV2CashoutRouter.RouteKind.V4, address(0), address(usdg), 0, ethKey);
        (uint256 gross,, uint256 platformFee, uint256 net) = _cashOut(id, routes);

        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertGt(gross, 250_000e6, "about 99 ETH sold at 3,000 USDG");
        assertEq(usdg.balanceOf(borrower), net);
        assertEq(usdg.balanceOf(fees), platformFee);
        _assertNoResidue();
    }

    /// @dev Pashov M-14 (acknowledged). By product policy (AUDIT-SCOPE §1.16) the cash-out is the holder's alone: an
    /// approved-for-all operator and a stranger are refused, so neither can spend the holder's approval to the router.
    /// The operator keeps its core right and repays through `reclaim` directly.
    function test_operatorIsRefusedButReclaimsThroughTheCore() public {
        uint256 id = _activeLoan();
        address operator = makeAddr("operator");
        vm.prank(borrower);
        vault.setApprovalForAll(operator, true);
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = _route(GageV2CashoutRouter.RouteKind.V4, address(col), address(0), 0, colEthKey);
        routes[1] = _route(GageV2CashoutRouter.RouteKind.V4, address(0), address(usdg), 0, ethKey);
        GageV2CashoutRouter.Exit memory x = _exit(id, routes);

        vm.prank(operator);
        vm.expectRevert(GageV2CashoutRouter.InvalidExit.selector);
        router.cashOutDetailed(x);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(GageV2CashoutRouter.InvalidExit.selector);
        router.cashOutDetailed(x);

        usdg.mint(operator, CAP);
        vm.startPrank(operator);
        usdg.approve(address(vault), CAP);
        vault.reclaim(id, operator);
        vm.stopPrank();
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
    }

    // ----------------------------------------------------------------- v3 callbacks

    /// @notice Pays a v3 mint made by this suite.
    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        _pay(IUniV3Pool(msg.sender).token0(), owed0);
        _pay(IUniV3Pool(msg.sender).token1(), owed1);
    }

    /// @notice Records the deltas a v3 pool passes and pays what it is owed.
    function uniswapV3SwapCallback(int256 delta0, int256 delta1, bytes calldata) external {
        (lastDelta0, lastDelta1) = (delta0, delta1);
        if (delta0 > 0) _pay(IUniV3Pool(msg.sender).token0(), uint256(delta0));
        if (delta1 > 0) _pay(IUniV3Pool(msg.sender).token1(), uint256(delta1));
    }

    // ----------------------------------------------------------------- helpers

    function _pay(address token, uint256 amount) internal {
        if (amount != 0) IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @dev A v3 pool from the factory, initialized at a raw price of 1, with `liquidity` over its full range.
    function _v3Pool(address tokenA, address tokenB, uint24 fee, int24 spacing, uint128 liquidity)
        internal
        returns (address pool)
    {
        pool = IV3FactorySetup(v3Factory).createPool(tokenA, tokenB, fee);
        IV3PoolSetup(pool).initialize(uint160(1 << 96));
        int24 top = TickMath.MAX_TICK / spacing * spacing;
        IV3PoolSetup(pool).mint(address(this), -top, top, liquidity, "");
    }

    /// @dev 100 COL for 1,000 USDG with a 1,100 USDG cap, funded by four lenders and approved to the router.
    function _activeLoan() internal returns (uint256 id) {
        col.mint(borrower, COLLATERAL);
        vm.startPrank(borrower);
        col.approve(address(vault), COLLATERAL);
        id = vault.list(
            Collateral(Kind.ERC20, address(col), COLLATERAL), 1000e6, CAP, TERM, uint40(block.timestamp + 1 days), false
        );
        vault.approve(address(router), id);
        vm.stopPrank();
        for (uint8 i; i < 4; ++i) {
            address lender = makeAddr(string(abi.encodePacked("lender", i)));
            usdg.mint(lender, 1000e6);
            vm.startPrank(lender);
            usdg.approve(address(vault), 1000e6);
            vault.fund(id, 1);
            vm.stopPrank();
        }
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    function _route(
        GageV2CashoutRouter.RouteKind kind,
        address tokenIn,
        address tokenOut,
        uint24 v3Fee,
        PoolKey memory key
    ) internal pure returns (GageV2CashoutRouter.Route memory) {
        return GageV2CashoutRouter.Route({
            kind: kind, tokenIn: tokenIn, tokenOut: tokenOut, v3Fee: v3Fee, key: key, minOut: 1
        });
    }

    function _exit(uint256 id, GageV2CashoutRouter.Route[] memory routes)
        internal
        view
        returns (GageV2CashoutRouter.Exit memory)
    {
        return GageV2CashoutRouter.Exit({
            loanId: id,
            recipient: borrower,
            minimumNet: 1,
            maxFinanceFee: 10e6,
            minUnderlying0: 0,
            minUnderlying1: 0,
            deadline: block.timestamp,
            routes: routes
        });
    }

    function _cashOut(uint256 id, GageV2CashoutRouter.Route[] memory routes)
        internal
        returns (uint256, uint256, uint256, uint256)
    {
        GageV2CashoutRouter.Exit memory x = _exit(id, routes);
        vm.prank(borrower);
        return router.cashOutDetailed(x);
    }

    /// @dev The router keeps nothing: no ETH, WETH, collateral or USDG.
    function _assertNoResidue() internal view {
        assertEq(address(router).balance, 0, "router ETH");
        assertEq(weth.balanceOf(address(router)), 0, "router WETH");
        assertEq(col.balanceOf(address(router)), 0, "router COL");
        assertEq(usdg.balanceOf(address(router)), 0, "router USDG");
    }
}
