// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// Tests the deployed current V3 engine against the exact ORBIO / NVDA Pons V2 launch pool (v4, zero LP fee, after-swap
/// hook charge), which is both the token's pricing and cash-out route (then NVDA / USDG) and the admitted LP market.
/// Only the token admission, the pool admission, the v4 cash-out route and test capital change locally.
contract OrbioAdmissionLiveForkTest is V4Fixture {
    address constant ORBIO = 0xAa07A0e9209e16aC99708C3EC70159c6eF3128A3;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    bytes32 constant POOL = 0xa95b1fbdccb15d2b07509b980f63adab8a94303b1781f5ebc53b72942d12ddc1;
    bytes32 constant NVDA_POOL = 0x3bb34a44f1b2b5f32c034c38a53065a521a47b199700fa9bd19d60985ff24bf1;
    uint128 constant LP_MIN = 1e15;
    uint256 constant MIN = 2000e18;
    uint256 constant PER_DEAL = 150_000e18;
    uint256 constant AGGREGATE = 450_000e18;
    uint256 constant DEALT = 100_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey key;
    PoolKey nvdaKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_ORBIO_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_ORBIO_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(ORBIO.codehash, 0x67d7a9d1677c238d9dae8679f500586f7d189e7bcda59964f3ce634dcf7363cf);
        assertEq(HOOK.codehash, 0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db);
        // No before/after-remove or removal-return-delta permission: no removal-hook exception is needed.
        assertEq(uint160(HOOK) & 0x301, 0);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        key = PoolKey(Currency.wrap(ORBIO), Currency.wrap(NVDA), 0, 200, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        nvdaKey = PoolKey(Currency.wrap(USDG), Currency.wrap(NVDA), 3000, 60, IHooks(address(0)));
        assertEq(_poolId(nvdaKey), NVDA_POOL);
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(nvdaKey));
        assertTrue(registry.getERC20Config(NVDA).allowed);
        assertEq(uint8(registry.getERC20Config(NVDA).lane), uint8(Lane.STOCK));
        assertFalse(registry.getERC20Config(ORBIO).allowed);
        assertFalse(registry.getPoolConfig(POOL).allowed);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(key));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(ORBIO, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        registry.setPoolAllowed(POOL, true, LP_MIN);
        cashout.setV4Route(key, true);
        vm.stopPrank();
        assertFalse(registry.poolInRangeRequired(POOL));
        borrower = makeAddr("ORBIO borrower");
        lender = makeAddr("ORBIO lender");
        deal(ORBIO, borrower, DEALT);
        deal(NVDA, borrower, 1000e18);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(ORBIO).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        _approvePosm(borrower, ORBIO);
        _approvePosm(borrower, NVDA);
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
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
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
    }

    /// USDG raw value of `amount` raw ORBIO at the current two-pool spot, before hook charges, fees and impact.
    /// ORBIO is currency0 of its pool (NVDA per ORBIO = sqrt^2 / 2^192); USDG is currency0 of the NVDA pool
    /// (NVDA per USDG = sqrt^2 / 2^192), so USDG per ORBIO = sqrtOrbio^2 / sqrtNvda^2.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        uint256 sqrtOrbio = _sqrt(POOL);
        uint256 sqrtNvda = _sqrt(NVDA_POOL);
        uint256 nvda = FullMath.mulDiv(FullMath.mulDiv(amount, sqrtOrbio, 1 << 96), sqrtOrbio, 1 << 96);
        return FullMath.mulDiv(FullMath.mulDiv(nvda, 1 << 96, sqrtNvda), 1 << 96, sqrtNvda);
    }

    /// Exact-input v4 swap by this contract; the hook's after-swap charge comes out of the output.
    function _swapExact(PoolKey memory k, address tokenIn, uint256 amount) internal returns (uint256 out) {
        bool zeroForOne = tokenIn == Currency.unwrap(k.currency0);
        address output = Currency.unwrap(zeroForOne ? k.currency1 : k.currency0);
        uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        IERC20(tokenIn).approve(address(swapRouter), amount);
        swapRouter.swap(
            k,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(beforeIn - IERC20(tokenIn).balanceOf(address(this)), amount, "Partial fill or input transfer mismatch");
        out = IERC20(output).balanceOf(address(this)) - beforeOut;
    }

    /// Sell `amount` raw ORBIO through the launch pool (hook charge included), then the NVDA through NVDA / USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(ORBIO, address(this), amount);
        uint256 nvdaOut = _swapExact(key, ORBIO, amount);
        assertGt(nvdaOut, 0);
        usdgOut = _swapExact(nvdaKey, NVDA, nvdaOut);
    }

    /// Cash-out routes shared by token and LP exits: ORBIO -> NVDA on the launch pool, NVDA -> USDG.
    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, ORBIO, NVDA, 0, key, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, NVDA, USDG, 0, nvdaKey, 1);
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

    function testOrbio_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(ORBIO).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, ORBIO, PER_DEAL));
        _fund(id);
        assertEq(IERC20(ORBIO).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(ORBIO).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, ORBIO, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(ORBIO).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(ORBIO).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testOrbio_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ORBIO, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ORBIO, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, ORBIO, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ORBIO, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(ORBIO, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ORBIO, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(ORBIO).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(ORBIO).allowed);
        assertFalse(primary.getPoolConfig(POOL).allowed);
        assertFalse(memeUsdg.getERC20Config(ORBIO).allowed);
        assertFalse(memeUsdg.getPoolConfig(POOL).allowed);
        assertFalse(ponsWeth.getERC20Config(ORBIO).allowed);
        assertFalse(ponsWeth.getPoolConfig(POOL).allowed);
    }

    function testOrbio_twoHopCashoutThroughLaunchPoolAndNvda() public {
        uint256 id = _list(Collateral(Kind.ERC20, ORBIO, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerNvda = IERC20(NVDA).balanceOf(address(cashout));
        uint256 routerToken = IERC20(ORBIO).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(IERC20(NVDA).balanceOf(address(cashout)), routerNvda);
        assertEq(IERC20(ORBIO).balanceOf(address(cashout)), routerToken);
    }

    function testOrbio_cashoutRouteRequiresAdmission() public {
        uint256 id = _list(Collateral(Kind.ERC20, ORBIO, PER_DEAL));
        _fund(id);
        vm.prank(cashout.owner());
        cashout.setV4Route(key, false);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testOrbio_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testOrbio_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }

    function testOrbio_v4LpReclaimUnwindAndDefaultRecovery() public {
        uint256 nft = _mint(key, -887_200, 887_200, 5e19, borrower, borrower);
        assertGt(posm.getPositionLiquidity(nft), LP_MIN);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
        _repay(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        uint256 o0 = IERC20(ORBIO).balanceOf(borrower);
        uint256 n0 = IERC20(NVDA).balanceOf(borrower);
        _decrease(key, nft, posm.getPositionLiquidity(nft), borrower, borrower);
        assertGt(IERC20(ORBIO).balanceOf(borrower), o0);
        assertGt(IERC20(NVDA).balanceOf(borrower), n0);
        assertEq(posm.getPositionLiquidity(nft), 0);
        nft = _mint(key, -887_200, 887_200, 5e19, borrower, borrower);
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

    function testOrbio_v4LpMinimumRangePolicyAndRevocation() public {
        // Below the raw-liquidity floor: rejected, NFT stays with its owner.
        uint256 dust = _mint(key, -887_200, 887_200, uint128(LP_MIN), borrower, borrower);
        assertLe(posm.getPositionLiquidity(dust), LP_MIN);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), dust));
        assertEq(IERC721(address(posm)).ownerOf(dust), borrower);
        // Out of range is accepted while the pool's in-range policy is off, and rejected once it is switched on.
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(POOL));
        int24 above = ((tick / 200) + 20) * 200;
        uint256 outOfRange = _mint(key, above, above + 2000, 1e18, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), outOfRange));
        vm.startPrank(borrower);
        vault.cancelFunding(id);
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
        vm.prank(registry.owner());
        registry.setPoolInRangeRequired(POOL, true);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), outOfRange));
        vm.prank(registry.owner());
        registry.setPoolInRangeRequired(POOL, false);
        // Pool revocation closes the market; the NFT is never moved.
        uint256 nft = _mint(key, -887_200, 887_200, 1e18, borrower, borrower);
        vm.prank(registry.owner());
        registry.setPoolAllowed(POOL, false, 0);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    /// A funded position must be worth more than its repayment: 5e19 full-range liquidity is a few hundred USDG here.
    function testOrbio_v4LpCashoutThroughLaunchPoolRoute() public {
        uint256 nft = _mint(key, -887_200, 887_200, 5e19, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _lpExit(id);
        vm.prank(cashout.owner());
        cashout.setV4Route(key, false);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        vm.prank(cashout.owner());
        cashout.setV4Route(key, true);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(posm.getPositionLiquidity(nft), 0);
    }
}
