// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2ZapRouter} from "../../src/v2/GageV2ZapRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {LiveEngine} from "./fixtures/LiveEngine.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {UniV4PositionAdapter} from "../../src/libraries/UniV4PositionAdapter.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// Minimal canonical v3 NonfungiblePositionManager surface used by the tests.
interface IV3Positions {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IV3PoolView {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function liquidity() external view returns (uint128);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

interface IWETH9 {
    function withdraw(uint256) external;
}

/// Tests the deployed native V2 engine against the canonical v3 WETH / INDEX pool (the token's pricing route, the
/// published cash-out route and an LP market) and the hook-free v4 INDEX / USDG pool (a second LP market that is
/// deliberately not a cash-out route: it is far shallower than the v3 pool). The user-linked native ETH / INDEX v4
/// pool with the IndexFeeHook is proven inadmissible. Only the admissions and test capital change locally, after the
/// fork reopens the engine to new loans and withdraws the admissions mainnet has since applied.
contract IndexAdmissionLiveForkTest is V4Fixture {
    address constant INDEX = 0x56910D4409F3a0C78C64DD8D0545FF0705389870;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant ETH_POOL = 0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant V3_POOL = 0xD29893fFac8b29eC4Db2cfE0CDB3FE1377c028Ff;
    bytes32 constant V3_ID = bytes32(uint256(uint160(V3_POOL)));
    bytes32 constant USDG_POOL = 0x2500e77b68040591e0e75acaa612616fa6b4eaa33423ce35add57413c63ffa67;
    bytes32 constant LINKED_POOL = 0x00dd2df2f17d431cf3a0938f06c9cf9abc5e9643b6cc466ca3f71f3af246edf3;
    address constant LINKED_HOOK = 0x2cD91bD228ff4c537031d6b8204782090c84c0cC;
    int24 constant FULL_LOWER_100 = -887_200;
    int24 constant FULL_UPPER_100 = 887_200;
    uint128 constant LP_MIN = 1e15;
    uint128 constant LP_PER_DEAL = 3e20;
    uint128 constant LP_AGGREGATE = 15e20;
    uint128 constant USDG_LP_MIN = 1e15;
    uint256 constant MIN = 3000e18;
    uint256 constant PER_DEAL = 500_000e18;
    uint256 constant AGGREGATE = 1_500_000e18;
    uint256 constant DEALT = 20_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    // The deployed mainnet router predates the merged router errors and still reverts RouteNotAllowed().
    bytes4 internal constant LEGACY_ROUTE_NOT_ALLOWED = bytes4(keccak256("RouteNotAllowed()"));
    PoolKey ethKey;
    PoolKey usdgKey;
    PoolKey linkedKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_INDEX_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_INDEX_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(INDEX.codehash, 0x4ee19c3a5cda0991509f65faa494c490942df5f19fc79659306a125c15b41d84);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(0x22658055B70b8B09616B1e0953f2A51cc66cF493);
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), 0x1D9f88705D398Cd13Af4e35A74ef21253734f153);
        // Mainnet has since closed this engine to new loans. It is reopened on this fork only.
        LiveEngine.reopen(vault);
        cashout = GageV2CashoutRouter(payable(0x38E37cC00427Dd2A930d2A31e29E4104530d671b));
        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        usdgKey = PoolKey(Currency.wrap(INDEX), Currency.wrap(USDG), 7000, 100, IHooks(address(0)));
        linkedKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(INDEX), 10_000, 200, IHooks(LINKED_HOOK));
        assertEq(_poolId(ethKey), ETH_POOL);
        assertEq(_poolId(usdgKey), USDG_POOL);
        assertEq(_poolId(linkedKey), LINKED_POOL);
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(ethKey));
        // Mainnet has since applied these admissions. They are withdrawn on this fork only, so the probe starts
        // from the unadmitted state it was written against and applies the admissions itself.
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(INDEX, false, Lane.MEME, 0, 0, 0);
        registry.setV3PoolAllowed(V3_POOL, false, 0, 0, 0);
        registry.setPoolInRangeRequired(V3_ID, false);
        cashout.setV3Route(V3_POOL, false);
        registry.setPoolAllowed(USDG_POOL, false, 0);
        registry.setPoolInRangeRequired(USDG_POOL, false);
        vm.stopPrank();
        assertFalse(registry.getERC20Config(INDEX).allowed);
        assertFalse(registry.getV3PoolConfig(V3_POOL).allowed);
        assertFalse(registry.getPoolConfig(USDG_POOL).allowed);
        assertFalse(registry.getPoolConfig(LINKED_POOL).allowed);
        assertFalse(cashout.v3Allowed(V3_POOL));
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(usdgKey));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(INDEX, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        registry.setV3PoolAllowed(V3_POOL, true, LP_MIN, LP_PER_DEAL, LP_AGGREGATE);
        registry.setPoolInRangeRequired(V3_ID, true);
        cashout.setV3Route(V3_POOL, true);
        registry.setPoolAllowed(USDG_POOL, true, USDG_LP_MIN);
        registry.setPoolInRangeRequired(USDG_POOL, true);
        vm.stopPrank();
        assertTrue(registry.poolInRangeRequired(V3_ID));
        assertTrue(registry.poolInRangeRequired(USDG_POOL));
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(usdgKey));
        assertFalse(registry.getPoolConfig(LINKED_POOL).allowed);
        borrower = makeAddr("INDEX borrower");
        lender = makeAddr("INDEX lender");
        deal(INDEX, borrower, DEALT);
        deal(WETH, borrower, 20 ether);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(INDEX).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(V3_MANAGER).setApprovalForAll(address(vault), true);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        IERC20(WETH).approve(V3_MANAGER, type(uint256).max);
        IERC20(INDEX).approve(V3_MANAGER, type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        _approvePosm(borrower, INDEX);
        _approvePosm(borrower, USDG);
    }

    /// Pays the v3 pool for this contract's own exact-input swaps.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        assertEq(msg.sender, V3_POOL);
        if (amount0Delta > 0) IERC20(WETH).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(INDEX).transfer(msg.sender, uint256(amount1Delta));
    }

    function _list(Collateral memory c) internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(c, 90e6, 100e6, 7 days, uint40(block.timestamp + 1 days), false);
    }

    function _fund(uint256 id) internal {
        vm.prank(lender);
        vault.fund(id, 4);
    }

    function _repay(uint256 id) internal {
        vm.startPrank(borrower);
        vault.reclaim(id, borrower);
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
    }

    function _default(uint256 id) internal {
        vm.warp(block.timestamp + 7 days + vault.GRACE());
        vault.finalizeDefault(id);
        vm.prank(lender);
        vault.recoverDefault(id, 0, 0, block.timestamp);
    }

    function _sqrt(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (, bytes memory data) = STATE_VIEW.staticcall(abi.encodeWithSignature("getSlot0(bytes32)", poolId));
        (sqrtPriceX96,,,) = abi.decode(data, (uint160, int24, uint24, uint24));
    }

    /// USDG raw value of `amount` raw INDEX at the current two-pool spot (v3 then ETH/USDG), before fees and impact.
    /// The v3 pool holds WETH as token0, so WETH per INDEX is 2^192 / sqrtPrice^2.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        (uint160 sqrtToken,,,,,,) = IV3PoolView(V3_POOL).slot0();
        uint256 sqrtEth = _sqrt(ETH_POOL);
        uint256 eth = FullMath.mulDiv(amount, 1 << 192, uint256(sqrtToken) * sqrtToken);
        return FullMath.mulDiv(eth, sqrtEth * sqrtEth, 1 << 192);
    }

    /// USDG raw value of `amount` raw INDEX at the v4 INDEX / USDG spot (INDEX is currency0).
    function _spotUSDGViaUsdgPool(uint256 amount) internal view returns (uint256) {
        uint256 sqrtP = _sqrt(USDG_POOL);
        return FullMath.mulDiv(amount, sqrtP * sqrtP, 1 << 192);
    }

    /// Exact-input v4 swap by this contract; native ETH is paid as value and received as balance.
    function _swapExact(PoolKey memory k, address tokenIn, uint256 amount) internal returns (uint256 out) {
        bool zeroForOne = tokenIn == Currency.unwrap(k.currency0);
        address output = Currency.unwrap(zeroForOne ? k.currency1 : k.currency0);
        uint256 beforeIn = _balance(tokenIn);
        uint256 beforeOut = _balance(output);
        if (tokenIn != address(0)) IERC20(tokenIn).approve(address(swapRouter), amount);
        swapRouter.swap{value: tokenIn == address(0) ? amount : 0}(
            k,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(beforeIn - _balance(tokenIn), amount, "Partial fill or input transfer mismatch");
        out = _balance(output) - beforeOut;
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// Sell `amount` raw INDEX through the v3 pool, unwrap the WETH and sell it through ETH/USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(INDEX, address(this), amount);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        IV3PoolView(V3_POOL).swap(address(this), false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, "");
        assertEq(IERC20(INDEX).balanceOf(address(this)), 0, "Partial v3 fill");
        uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        assertGt(wethOut, 0);
        IWETH9(WETH).withdraw(wethOut);
        usdgOut = _swapExact(ethKey, address(0), wethOut);
    }

    /// Sell `amount` raw INDEX through the v4 INDEX / USDG pool in one hop.
    function _sellUsdgPool(uint256 amount) internal returns (uint256 usdgOut) {
        deal(INDEX, address(this), amount);
        usdgOut = _swapExact(usdgKey, INDEX, amount);
    }

    /// Mint a WETH / INDEX v3 position for the borrower sized from the pool's current price.
    function _mintV3(int24 lower, int24 upper, uint128 targetLiquidity)
        internal
        returns (uint256 nft, uint128 liquidity)
    {
        (uint160 sqrtP,,,,,,) = IV3PoolView(V3_POOL).slot0();
        uint256 amount0 = FullMath.mulDiv(targetLiquidity, 1 << 96, sqrtP) + 1;
        uint256 amount1 = FullMath.mulDiv(targetLiquidity, sqrtP, 1 << 96) + 1;
        vm.prank(borrower);
        (nft, liquidity,,) = IV3Positions(V3_MANAGER)
            .mint(
                IV3Positions.MintParams(
                    WETH, INDEX, 10_000, lower, upper, amount0, amount1, 0, 0, borrower, block.timestamp
                )
            );
    }

    function _unwindV3(uint256 nft) internal {
        (,,,,,,, uint128 liquidity,,,,) = IV3Positions(V3_MANAGER).positions(nft);
        vm.startPrank(borrower);
        IV3Positions(V3_MANAGER)
            .decreaseLiquidity(IV3Positions.DecreaseLiquidityParams(nft, liquidity, 0, 0, block.timestamp));
        IV3Positions(V3_MANAGER)
            .collect(IV3Positions.CollectParams(nft, borrower, type(uint128).max, type(uint128).max));
        vm.stopPrank();
    }

    /// Two-hop cash-out routes: INDEX -> WETH on the v3 pool, unwrap, ETH -> USDG.
    function _v3Routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](3);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, INDEX, WETH, 10_000, ethKey, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.UNWRAP_WETH, WETH, address(0), 0, ethKey, 1);
        routes[2] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, address(0), USDG, 0, ethKey, 1);
    }

    /// Single-hop INDEX -> USDG on the v4 INDEX / USDG pool: not a published route, used to prove the router refuses it.
    function _usdgRoutes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](1);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, INDEX, USDG, 0, usdgKey, 1);
    }

    function _exit(uint256 id, GageV2CashoutRouter.Route[] memory routes, uint256 minUnderlying1)
        internal
        view
        returns (GageV2CashoutRouter.Exit memory x)
    {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1; // ERC20 collateral recovers a single asset; the second minimum must be zero.
        x.minUnderlying1 = minUnderlying1;
        x.deadline = block.timestamp;
        x.routes = routes;
    }

    function _cashOutClean(uint256 id, GageV2CashoutRouter.Exit memory x) internal returns (uint256 net) {
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerEth = address(cashout).balance;
        uint256 routerWeth = IERC20(WETH).balanceOf(address(cashout));
        uint256 routerToken = IERC20(INDEX).balanceOf(address(cashout));
        uint256 routerUsdg = IERC20(USDG).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(address(cashout).balance, routerEth);
        assertEq(IERC20(WETH).balanceOf(address(cashout)), routerWeth);
        assertEq(IERC20(INDEX).balanceOf(address(cashout)), routerToken);
        assertEq(IERC20(USDG).balanceOf(address(cashout)), routerUsdg);
    }

    function testIndex_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(INDEX).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, INDEX, PER_DEAL));
        _fund(id);
        assertEq(IERC20(INDEX).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(INDEX).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, INDEX, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(INDEX).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(INDEX).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testIndex_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INDEX, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INDEX, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, INDEX, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INDEX, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(INDEX, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INDEX, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(INDEX).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(INDEX).allowed);
        assertFalse(primary.getPoolConfig(V3_ID).allowed);
        assertFalse(primary.getPoolConfig(USDG_POOL).allowed);
        assertFalse(memeUsdg.getERC20Config(INDEX).allowed);
        assertFalse(memeUsdg.getPoolConfig(V3_ID).allowed);
        assertFalse(memeUsdg.getPoolConfig(USDG_POOL).allowed);
        assertFalse(ponsWeth.getERC20Config(INDEX).allowed);
        assertFalse(ponsWeth.getPoolConfig(V3_ID).allowed);
        assertFalse(ponsWeth.getPoolConfig(USDG_POOL).allowed);
    }

    function testIndex_twoHopCashoutThroughV3AndEth() public {
        uint256 id = _list(Collateral(Kind.ERC20, INDEX, PER_DEAL));
        _fund(id);
        _cashOutClean(id, _exit(id, _v3Routes(), 0));
    }

    function testIndex_usdgPoolIsNotACashoutRoute() public {
        uint256 id = _list(Collateral(Kind.ERC20, INDEX, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _exit(id, _usdgRoutes(), 0);
        vm.prank(borrower);
        vm.expectRevert(LEGACY_ROUTE_NOT_ALLOWED);
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _cashOutClean(id, _exit(id, _v3Routes(), 0));
    }

    function testIndex_cashoutRoutesRequireAdmission() public {
        uint256 id = _list(Collateral(Kind.ERC20, INDEX, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        vm.prank(cashout.owner());
        cashout.setV3Route(V3_POOL, false);
        GageV2CashoutRouter.Exit memory x = _exit(id, _v3Routes(), 0);
        vm.prank(borrower);
        vm.expectRevert(LEGACY_ROUTE_NOT_ALLOWED);
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testIndex_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testIndex_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }

    function testIndex_v3LpReclaimUnwindAndDefaultRecovery() public {
        (uint256 nft, uint128 liquidity) = _mintV3(-887_200, 887_200, 2e20);
        assertGt(liquidity, LP_MIN);
        assertLe(liquidity, LP_PER_DEAL);
        uint256 id = _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, nft));
        _fund(id);
        assertEq(IERC721(V3_MANAGER).ownerOf(nft), vault.getLoan(id).account);
        _repay(id);
        assertEq(IERC721(V3_MANAGER).ownerOf(nft), borrower);
        uint256 w0 = IERC20(WETH).balanceOf(borrower);
        uint256 t0 = IERC20(INDEX).balanceOf(borrower);
        _unwindV3(nft);
        assertGt(IERC20(WETH).balanceOf(borrower), w0);
        assertGt(IERC20(INDEX).balanceOf(borrower), t0);
        (nft,) = _mintV3(-887_200, 887_200, 2e20);
        id = _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, nft));
        _fund(id);
        vm.warp(block.timestamp + 7 days + vault.GRACE());
        vault.finalizeDefault(id);
        vm.prank(lender);
        vault.recoverDefault(id, 1, 1, block.timestamp);
        GageV2CollateralAccount account = GageV2CollateralAccount(payable(vault.getLoan(id).account));
        for (uint8 asset; asset < 2; ++asset) {
            address token = account.recoveryTokens(asset);
            uint256 amount = account.recoveryAmounts(asset);
            assertGt(amount, 0);
            uint256 before = IERC20(token).balanceOf(lender);
            vm.prank(lender);
            vault.withdrawRecovery(id, asset, lender);
            assertEq(IERC20(token).balanceOf(lender) - before, amount);
        }
        (,,,,,,, uint128 left,,,,) = IV3Positions(V3_MANAGER).positions(nft);
        assertEq(left, 0);
    }

    function testIndex_v3LpLimitsRangeAndRevocation() public {
        (uint256 big, uint128 bigLiquidity) = _mintV3(-887_200, 887_200, LP_PER_DEAL + 1e19);
        assertGt(bigLiquidity, LP_PER_DEAL);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, big));
        assertEq(IERC721(V3_MANAGER).ownerOf(big), borrower);
        (, int24 tick,,,,,) = IV3PoolView(V3_POOL).slot0();
        int24 above = ((tick / 200) + 20) * 200;
        (uint256 outOfRange,) = _mintV3(above, above + 2000, 1e17);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, outOfRange));
        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            (uint256 nft, uint128 liquidity) = _mintV3(-887_200, 887_200, LP_PER_DEAL - 1e18);
            assertLe(liquidity, LP_PER_DEAL);
            ids[i] = _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, nft));
        }
        // Five positions leave under 5e18 of aggregate headroom; the sixth exceeds it while staying above the minimum.
        (uint256 sixth,) = _mintV3(-887_200, 887_200, 1e19);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, sixth));
        vm.prank(registry.owner());
        registry.setV3PoolAllowed(V3_POOL, false, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, sixth));
        vm.startPrank(borrower);
        vault.cancelFunding(ids[0]);
        vault.withdrawCollateral(ids[0], borrower);
        vm.stopPrank();
        assertEq(IERC721(V3_MANAGER).ownerOf(sixth), borrower);
    }

    function testIndex_v3LpCashoutThroughV3Route() public {
        (uint256 nft,) = _mintV3(-887_200, 887_200, 2e20);
        uint256 id = _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, nft));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _exit(id, _v3Routes(), 1);
        vm.prank(cashout.owner());
        cashout.setV3Route(V3_POOL, false);
        vm.prank(borrower);
        vm.expectRevert(LEGACY_ROUTE_NOT_ALLOWED);
        cashout.cashOutDetailed(x);
        vm.prank(cashout.owner());
        cashout.setV3Route(V3_POOL, true);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        (,,,,,,, uint128 left,,,,) = IV3Positions(V3_MANAGER).positions(nft);
        assertEq(left, 0);
    }

    function testIndex_usdgLpReclaimUnwindAndDefaultRecovery() public {
        uint256 nft = _mint(usdgKey, FULL_LOWER_100, FULL_UPPER_100, 2e15, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
        _repay(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        uint256 b0 = IERC20(USDG).balanceOf(borrower);
        uint256 b1 = IERC20(INDEX).balanceOf(borrower);
        _decrease(usdgKey, nft, 2e15, borrower, borrower);
        assertGt(IERC20(USDG).balanceOf(borrower), b0);
        assertGt(IERC20(INDEX).balanceOf(borrower), b1);
        nft = _mint(usdgKey, FULL_LOWER_100, FULL_UPPER_100, 2e15, borrower, borrower);
        id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        vm.warp(block.timestamp + 7 days + vault.GRACE());
        vault.finalizeDefault(id);
        vm.prank(lender);
        vault.recoverDefault(id, 1, 1, block.timestamp);
        GageV2CollateralAccount account = GageV2CollateralAccount(payable(vault.getLoan(id).account));
        for (uint8 asset; asset < 2; ++asset) {
            address token = account.recoveryTokens(asset);
            uint256 amount = account.recoveryAmounts(asset);
            assertGt(amount, 0);
            uint256 before = IERC20(token).balanceOf(lender);
            vm.prank(lender);
            vault.withdrawRecovery(id, asset, lender);
            assertEq(IERC20(token).balanceOf(lender) - before, amount);
        }
        assertEq(posm.getPositionLiquidity(nft), 0);
    }

    function testIndex_usdgLpMinimumRangeAndRevocation() public {
        uint256 nft = _mint(usdgKey, FULL_LOWER_100, FULL_UPPER_100, 1e15, borrower, borrower);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        (, bytes memory data) = STATE_VIEW.staticcall(abi.encodeWithSignature("getSlot0(bytes32)", USDG_POOL));
        (, int24 tick,,) = abi.decode(data, (uint160, int24, uint24, uint24));
        int24 above = ((tick / 100) + 20) * 100;
        uint256 outOfRange = _mint(usdgKey, above, above + 1000, 2e15, borrower, borrower);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), outOfRange));
        uint256 ok = _mint(usdgKey, FULL_LOWER_100, FULL_UPPER_100, 2e15, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), ok));
        vm.prank(registry.owner());
        registry.setPoolAllowed(USDG_POOL, false, 0);
        uint256 later = _mint(usdgKey, FULL_LOWER_100, FULL_UPPER_100, 2e15, borrower, borrower);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), later));
        vm.startPrank(borrower);
        vault.cancelFunding(id);
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
        assertEq(IERC721(address(posm)).ownerOf(ok), borrower);
    }

    /// A USDG LP exit unwinds INDEX plus USDG; the INDEX leg sells through the published v3 route, the USDG leg stays.
    function testIndex_usdgLpCashoutThroughV3Route() public {
        uint256 nft = _mint(usdgKey, FULL_LOWER_100, FULL_UPPER_100, 2e15, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _exit(id, _usdgRoutes(), 1);
        vm.prank(borrower);
        vm.expectRevert(LEGACY_ROUTE_NOT_ALLOWED);
        cashout.cashOutDetailed(x);
        x = _exit(id, _v3Routes(), 1);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(posm.getPositionLiquidity(nft), 0);
    }

    function testIndex_usdgZapUsesDeployedRouter() public {
        GageV2ZapRouter zap = GageV2ZapRouter(payable(0xDEa3b7B6f57c63CcE013a64BA42020C10Af083aD));
        // Approve before assembling the large struct so via-IR need not retain its fields across both calls.
        vm.startPrank(borrower);
        IERC20(USDG).approve(address(zap), 500e6);
        GageV2ZapRouter.Swap[] memory swaps = new GageV2ZapRouter.Swap[](1);
        swaps[0] = GageV2ZapRouter.Swap(usdgKey, false, 250e6, 1);
        GageV2ZapRouter.Zap memory z = GageV2ZapRouter.Zap(
            USDG,
            500e6,
            false,
            usdgKey,
            FULL_LOWER_100,
            FULL_UPPER_100,
            1e15 + 1,
            100e6,
            90e6,
            7 days,
            block.timestamp + 60,
            uint40(block.timestamp + 1 days),
            false
        );
        (uint256 id, uint256 nft, uint128 liquidity) = zap.zapAndList(z, swaps);
        vm.stopPrank();
        assertGt(liquidity, 1e15);
        assertEq(vault.ownerOf(id), borrower);
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
        _fund(id);
        _repay(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    /// The user-linked native ETH / INDEX pool: the hook allows minting, but native ETH can never be allowlisted and the
    /// immutable validator rejects the position even with the pool allowlisted; the owner can still unwind it.
    function testIndex_linkedNativeEthLpRejectedAndOwnerCanUnwind() public {
        vm.deal(borrower, 10 ether);
        uint256 nft = posm.nextTokenId();
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            linkedKey, -887_200, 887_200, uint256(1e18), type(uint128).max, type(uint128).max, borrower, bytes("")
        );
        params[1] = abi.encode(linkedKey.currency0, linkedKey.currency1);
        params[2] = abi.encode(address(0), borrower);
        vm.prank(borrower);
        posm.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp + 1);
        assertGt(posm.getPositionLiquidity(nft), 0);
        vm.prank(registry.owner());
        vm.expectRevert();
        registry.setERC20Allowed(address(0), true, Lane.ETH, 1, 1, 1);
        vm.prank(borrower);
        vm.expectRevert();
        vault.list(
            Collateral(Kind.UNIV4_POSITION, address(posm), nft),
            90e6,
            100e6,
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.prank(registry.owner());
        registry.setPoolAllowed(LINKED_POOL, true, 1);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.PairNotAllowed.selector, address(0), INDEX));
        vault.list(
            Collateral(Kind.UNIV4_POSITION, address(posm), nft),
            90e6,
            100e6,
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.prank(registry.owner());
        registry.setPoolAllowed(LINKED_POOL, false, 0);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        uint256 ethBefore = borrower.balance;
        uint256 tokenBefore = IERC20(INDEX).balanceOf(borrower);
        _decrease(linkedKey, nft, 1e18, borrower, borrower);
        assertEq(posm.getPositionLiquidity(nft), 0);
        assertGt(borrower.balance, ethBefore);
        assertGt(IERC20(INDEX).balanceOf(borrower), tokenBefore);
    }
}
