// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// Current V3 custody, reclaim, recovery and executable route checks for Cookware token only.
contract CookAdmissionLiveForkTest is V4Fixture {
    address constant COOK = 0xE10195999A422314155b1e158281DBd4F27adc46;
    address constant HOOD = 0x32aC8C1D7672667D5EbdEa22935F7B06fC8D496f;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant HOOK = 0x4Eb1976978756Bd56802d8162f2271844924e0cc;
    address constant HOOD_HOOK = address(0);
    bytes32 constant POOL = 0x10ea32252ee4aea2be282068a974f394684657b12d7dc976b5f4f41390455180;
    bytes32 constant HOOD_POOL = 0x7fb39eb653999feb9f0d3b1410848911383dfc681f3585229df4aa5b560bf0ba;
    uint256 constant MIN = 100_000e18;
    uint256 constant PER_DEAL = 200_000e18;
    uint256 constant AGGREGATE = 1_000_000e18;
    uint256 constant DEALT = 100_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey key;
    PoolKey hoodKey;
    PoolKey directKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_COOK_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_COOK_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(COOK.codehash, vm.envBytes32("GAGE_COOK_TOKEN_HASH"));
        assertEq(HOOK.codehash, vm.envBytes32("GAGE_COOK_HOOK_HASH"));
        address hookImplementation =
            address(uint160(uint256(vm.load(HOOK, bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)))));
        assertEq(hookImplementation.codehash, vm.envBytes32("GAGE_COOK_HOOK_IMPLEMENTATION_HASH"));
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        key = PoolKey(Currency.wrap(HOOD), Currency.wrap(COOK), 3000, 200, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        hoodKey = PoolKey(Currency.wrap(HOOD), Currency.wrap(USDG), 2000, 20, IHooks(HOOD_HOOK));
        assertEq(_poolId(hoodKey), HOOD_POOL);
        assertFalse(registry.getERC20Config(COOK).allowed);
        assertFalse(registry.getERC20Config(HOOD).allowed);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(key));
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(hoodKey));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(COOK, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        cashout.setV4Route(key, true);
        cashout.setV4Route(hoodKey, true);
        directKey = PoolKey(Currency.wrap(USDG), Currency.wrap(COOK), 9000, 90, IHooks(address(0)));
        assertEq(_poolId(directKey), 0x33ec1cc715a975b9fe6b638ca378a57909dff6279a808f80170ecf376f7cb50e);
        cashout.setV4Route(directKey, true);
        vm.stopPrank();
        borrower = makeAddr("COOK borrower");
        lender = makeAddr("COOK lender");
        deal(COOK, borrower, DEALT);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(COOK).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
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

    /// COOK is currency1 of COOK/HOOD; HOOD is currency0 of HOOD/USDG.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        uint256 a = _sqrt(POOL);
        uint256 b = _sqrt(HOOD_POOL);
        uint256 hood = FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, a), 1 << 96, a);
        return FullMath.mulDiv(FullMath.mulDiv(hood, b, 1 << 96), b, 1 << 96);
    }

    /// Exact-input v4 swap by this contract; hook charges and the dynamic LP fee come out of the swap.
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

    /// Sell `amount` raw COOK through the LunchTaxHookPair pool, then the HOOD through HOOD / USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(COOK, address(this), amount);
        uint256 hoodOut = _swapExact(key, COOK, amount);
        assertGt(hoodOut, 0);
        usdgOut = _swapExact(hoodKey, HOOD, hoodOut);
    }

    /// Cash-out routes: COOK -> HOOD on the LunchTaxHookPair pool, HOOD -> USDG.
    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, COOK, HOOD, 0, key, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, HOOD, USDG, 0, hoodKey, 1);
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

    function testCook_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(COOK).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, COOK, PER_DEAL));
        _fund(id);
        assertEq(IERC20(COOK).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(COOK).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, COOK, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(COOK).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(COOK).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testCook_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, COOK, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, COOK, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, COOK, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, COOK, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(COOK, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, COOK, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(COOK).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(COOK).allowed);
        assertFalse(memeUsdg.getERC20Config(COOK).allowed);
        assertFalse(ponsWeth.getERC20Config(COOK).allowed);
        // HOOD stays a routing hop only.
        assertFalse(registry.getERC20Config(HOOD).allowed);
    }

    function testCook_twoHopCashoutThroughLunchTaxHookPairPoolAndHood() public {
        uint256 id = _list(Collateral(Kind.ERC20, COOK, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerHood = IERC20(HOOD).balanceOf(address(cashout));
        uint256 routerToken = IERC20(COOK).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(IERC20(HOOD).balanceOf(address(cashout)), routerHood);
        assertEq(IERC20(COOK).balanceOf(address(cashout)), routerToken);
    }

    function testCook_cashoutRequiresBothLegs() public {
        uint256 id = _list(Collateral(Kind.ERC20, COOK, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        vm.prank(cashout.owner());
        cashout.setV4Route(key, false);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        vm.startPrank(cashout.owner());
        cashout.setV4Route(key, true);
        cashout.setV4Route(hoodKey, false);
        vm.stopPrank();
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testCook_directUsdgCashout() public {
        uint256 id = _list(Collateral(Kind.ERC20, COOK, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        x.routes = new GageV2CashoutRouter.Route[](1);
        x.routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, COOK, USDG, 0, directKey, 1);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
    }

    function testCook_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testCook_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }
}
