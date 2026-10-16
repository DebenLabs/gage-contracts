// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {LiveEngine} from "./fixtures/LiveEngine.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
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

/// Tests the deployed native V2 engine against the canonical v3 WETH / INJOH pool, which is both the token's
/// pricing and cash-out route and the admitted LP market. Only the token admission, the v3 LP admission, the v3
/// cash-out route and test capital change locally, after the fork reopens the engine to new loans and withdraws the
/// admission mainnet has since applied.
contract InjohAdmissionLiveForkTest is V4Fixture {
    address constant INJOH = 0x2cC0FAC44B8252f6B10208B091aFf2c94B4da77D;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant ETH_POOL = 0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V3_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant V3_POOL = 0xB09fa4f04032b9d9e690ac4a1d29523b5f9A72DC;
    bytes32 constant V3_ID = bytes32(uint256(uint160(V3_POOL)));
    uint128 constant LP_MIN = 1e15;
    uint128 constant LP_PER_DEAL = 3e20;
    uint128 constant LP_AGGREGATE = 15e20;
    uint256 constant MIN = 50_000e18;
    uint256 constant PER_DEAL = 500_000e18;
    uint256 constant AGGREGATE = 1_500_000e18;
    uint256 constant DEALT = 100_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    // The deployed mainnet router predates the merged router errors and still reverts RouteNotAllowed().
    bytes4 internal constant LEGACY_ROUTE_NOT_ALLOWED = bytes4(keccak256("RouteNotAllowed()"));
    PoolKey ethKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_INJOH_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_INJOH_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(INJOH.codehash, 0x7e6ca88b216c0b26c5f8497f3e7106648f4bcd8ed41eedfa1c80787fb407f4e2);
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
        assertEq(_poolId(ethKey), ETH_POOL);
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(ethKey));
        // Mainnet has since applied this admission. It is withdrawn on this fork only, so the probe starts from the
        // unadmitted state it was written against and applies the admission itself.
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(INJOH, false, Lane.MEME, 0, 0, 0);
        registry.setV3PoolAllowed(V3_POOL, false, 0, 0, 0);
        registry.setPoolInRangeRequired(V3_ID, false);
        cashout.setV3Route(V3_POOL, false);
        vm.stopPrank();
        assertFalse(registry.getERC20Config(INJOH).allowed);
        assertFalse(registry.getV3PoolConfig(V3_POOL).allowed);
        assertFalse(cashout.v3Allowed(V3_POOL));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(INJOH, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        registry.setV3PoolAllowed(V3_POOL, true, LP_MIN, LP_PER_DEAL, LP_AGGREGATE);
        registry.setPoolInRangeRequired(V3_ID, true);
        cashout.setV3Route(V3_POOL, true);
        vm.stopPrank();
        assertTrue(registry.poolInRangeRequired(V3_ID));
        borrower = makeAddr("INJOH borrower");
        lender = makeAddr("INJOH lender");
        deal(INJOH, borrower, DEALT);
        deal(WETH, borrower, 20 ether);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(INJOH).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(V3_MANAGER).setApprovalForAll(address(vault), true);
        IERC20(WETH).approve(V3_MANAGER, type(uint256).max);
        IERC20(INJOH).approve(V3_MANAGER, type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    /// Pays the v3 pool for this contract's own exact-input swaps.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        assertEq(msg.sender, V3_POOL);
        if (amount0Delta > 0) IERC20(WETH).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(INJOH).transfer(msg.sender, uint256(amount1Delta));
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

    /// USDG raw value of `amount` raw INJOH at the current two-pool spot, before fees and impact.
    /// The v3 pool holds WETH as token0, so WETH per INJOH is 2^192 / sqrtPrice^2.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        (uint160 sqrtToken,,,,,,) = IV3PoolView(V3_POOL).slot0();
        uint256 sqrtEth = _sqrt(ETH_POOL);
        uint256 eth = FullMath.mulDiv(amount, 1 << 192, uint256(sqrtToken) * sqrtToken);
        return FullMath.mulDiv(eth, sqrtEth * sqrtEth, 1 << 192);
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

    /// Sell `amount` raw INJOH through the v3 pool, unwrap the WETH and sell it through ETH/USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(INJOH, address(this), amount);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        IV3PoolView(V3_POOL).swap(address(this), false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, "");
        assertEq(IERC20(INJOH).balanceOf(address(this)), 0, "Partial v3 fill");
        uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        assertGt(wethOut, 0);
        IWETH9(WETH).withdraw(wethOut);
        usdgOut = _swapExact(ethKey, address(0), wethOut);
    }

    /// Mint a WETH / INJOH v3 position for the borrower sized from the pool's current price.
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
                    WETH, INJOH, 10_000, lower, upper, amount0, amount1, 0, 0, borrower, block.timestamp
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

    /// Cash-out routes shared by token and LP exits: INJOH -> WETH on the v3 pool, unwrap, ETH -> USDG.
    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](3);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, INJOH, WETH, 10_000, ethKey, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.UNWRAP_WETH, WETH, address(0), 0, ethKey, 1);
        routes[2] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, address(0), USDG, 0, ethKey, 1);
    }

    function _erc20Exit(uint256 id) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1; // ERC20 collateral recovers a single asset; the second minimum must be zero.
        x.minUnderlying1 = 0;
        x.deadline = block.timestamp;
        x.routes = _routes();
    }

    function _lpExit(uint256 id) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1;
        x.minUnderlying1 = 1;
        x.deadline = block.timestamp;
        x.routes = _routes();
    }

    function testInjoh_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(INJOH).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, INJOH, PER_DEAL));
        _fund(id);
        assertEq(IERC20(INJOH).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(INJOH).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, INJOH, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(INJOH).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(INJOH).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testInjoh_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INJOH, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INJOH, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, INJOH, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INJOH, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(INJOH, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, INJOH, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(INJOH).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(INJOH).allowed);
        assertFalse(primary.getPoolConfig(V3_ID).allowed);
        assertFalse(memeUsdg.getERC20Config(INJOH).allowed);
        assertFalse(memeUsdg.getPoolConfig(V3_ID).allowed);
        assertFalse(ponsWeth.getERC20Config(INJOH).allowed);
        assertFalse(ponsWeth.getPoolConfig(V3_ID).allowed);
    }

    function testInjoh_twoHopCashoutThroughV3AndEth() public {
        uint256 id = _list(Collateral(Kind.ERC20, INJOH, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerEth = address(cashout).balance;
        uint256 routerWeth = IERC20(WETH).balanceOf(address(cashout));
        uint256 routerToken = IERC20(INJOH).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(address(cashout).balance, routerEth);
        assertEq(IERC20(WETH).balanceOf(address(cashout)), routerWeth);
        assertEq(IERC20(INJOH).balanceOf(address(cashout)), routerToken);
    }

    function testInjoh_cashoutRouteRequiresAdmission() public {
        uint256 id = _list(Collateral(Kind.ERC20, INJOH, PER_DEAL));
        _fund(id);
        vm.prank(cashout.owner());
        cashout.setV3Route(V3_POOL, false);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        vm.prank(borrower);
        vm.expectRevert(LEGACY_ROUTE_NOT_ALLOWED);
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testInjoh_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testInjoh_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }

    function testInjoh_v3LpReclaimUnwindAndDefaultRecovery() public {
        (uint256 nft, uint128 liquidity) = _mintV3(-887_200, 887_200, 2e20);
        assertGt(liquidity, LP_MIN);
        assertLe(liquidity, LP_PER_DEAL);
        uint256 id = _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, nft));
        _fund(id);
        assertEq(IERC721(V3_MANAGER).ownerOf(nft), vault.getLoan(id).account);
        _repay(id);
        assertEq(IERC721(V3_MANAGER).ownerOf(nft), borrower);
        uint256 w0 = IERC20(WETH).balanceOf(borrower);
        uint256 t0 = IERC20(INJOH).balanceOf(borrower);
        _unwindV3(nft);
        assertGt(IERC20(WETH).balanceOf(borrower), w0);
        assertGt(IERC20(INJOH).balanceOf(borrower), t0);
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

    function testInjoh_v3LpLimitsRangeAndRevocation() public {
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

    function testInjoh_v3LpCashoutThroughV3Route() public {
        (uint256 nft,) = _mintV3(-887_200, 887_200, 2e20);
        uint256 id = _list(Collateral(Kind.UNIV3_POSITION, V3_MANAGER, nft));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _lpExit(id);
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
}
