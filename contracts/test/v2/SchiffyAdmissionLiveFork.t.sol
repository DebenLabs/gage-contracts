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

interface IFablesFee {
    function ABSOLUTE_MAX_FEE() external view returns (uint24);
    function maxFee(bytes32 poolId) external view returns (uint24);
}

/// Tests the deployed current V3 engine against SCHIFFY as token-only MEME collateral. Its pricing and cash-out route is
/// the exact SCHIFFY / GLD Doppler-hook pool (v4, dynamic fee) and then the GLD / USDG FablesRWA-hook pool (v4, dynamic
/// fee capped at 1.5%). GLD is a hop, not collateral. Only the token admission, the two v4 cash-out legs and test
/// capital change locally.
contract SchiffyAdmissionLiveForkTest is V4Fixture {
    address constant SCHIFFY = 0x42aFA2124ca5a2B83898E46B2dA9a190995b1E18;
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant HOOK = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address constant GLD_HOOK = 0xB608a78761f179f7C56f15E7D13921B92F00a080;
    bytes32 constant HOOK_HASH = 0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631;
    bytes32 constant POOL = 0xc749412e31087a6e6f9210af575bc9100159fbc9f45da3ca8b26b31f3bf5777e;
    bytes32 constant GLD_POOL = 0xfe281bbfa9aa658c1aa9c2ad1b0c62c4286f96c7cb1074296b54e869935a7a3a;
    uint256 constant MIN = 12_000e18;
    uint256 constant PER_DEAL = 200_000e18;
    uint256 constant AGGREGATE = 1_000_000e18;
    uint256 constant DEALT = 100_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey key;
    PoolKey gldKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_SCHIFFY_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_SCHIFFY_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        // Canonical fixed-implementation clone of the compiler-verified DopplerERC20V1 (same bytes as BONER and ASTEROID).
        assertEq(
            SCHIFFY.code,
            abi.encodePacked(
                hex"3d3d3d3d363d3d37363d73",
                address(0x3Be8B97Fd0e713B5aBE0649Fa830223B6B4BC599),
                hex"5af43d3d93803e602a57fd5bf3"
            )
        );
        assertEq(
            address(0x3Be8B97Fd0e713B5aBE0649Fa830223B6B4BC599).codehash,
            0x67a382a66d2b14a7032698e11c9ae4432435d2c803429d5c660692289ad10e12
        );
        assertEq(HOOK.codehash, HOOK_HASH);
        // The GLD / USDG hook only overrides the LP fee before a swap: no delta, removal or after-swap permission.
        assertEq(uint160(GLD_HOOK) & 0x3fff, (1 << 13) | (1 << 7));
        assertLe(IFablesFee(GLD_HOOK).ABSOLUTE_MAX_FEE(), 15_000);
        assertLe(IFablesFee(GLD_HOOK).maxFee(GLD_POOL), 15_000);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        key = PoolKey(Currency.wrap(SCHIFFY), Currency.wrap(GLD), 0x800000, 8, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        gldKey = PoolKey(Currency.wrap(USDG), Currency.wrap(GLD), 0x800000, 10, IHooks(GLD_HOOK));
        assertEq(_poolId(gldKey), GLD_POOL);
        assertFalse(registry.getERC20Config(SCHIFFY).allowed);
        assertFalse(registry.getERC20Config(GLD).allowed);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(key));
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(gldKey));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(SCHIFFY, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        cashout.setV4Route(key, true);
        cashout.setV4Route(gldKey, true);
        vm.stopPrank();
        borrower = makeAddr("SCHIFFY borrower");
        lender = makeAddr("SCHIFFY lender");
        deal(SCHIFFY, borrower, DEALT);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(SCHIFFY).approve(address(vault), type(uint256).max);
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

    /// USDG raw value of `amount` raw SCHIFFY at the current two-pool spot, before hook charges, fees and impact.
    /// SCHIFFY is currency0 of its pool (GLD per SCHIFFY = sqrt^2 / 2^192); USDG is currency0 of the GLD pool
    /// (GLD per USDG = sqrt^2 / 2^192), so USDG per SCHIFFY = sqrtSchiffy^2 / sqrtGld^2.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        uint256 sqrtSchiffy = _sqrt(POOL);
        uint256 sqrtGld = _sqrt(GLD_POOL);
        uint256 gld = FullMath.mulDiv(FullMath.mulDiv(amount, sqrtSchiffy, 1 << 96), sqrtSchiffy, 1 << 96);
        return FullMath.mulDiv(FullMath.mulDiv(gld, 1 << 96, sqrtGld), 1 << 96, sqrtGld);
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

    /// Sell `amount` raw SCHIFFY through the Doppler pool, then the GLD through GLD / USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(SCHIFFY, address(this), amount);
        uint256 gldOut = _swapExact(key, SCHIFFY, amount);
        assertGt(gldOut, 0);
        usdgOut = _swapExact(gldKey, GLD, gldOut);
    }

    /// Cash-out routes: SCHIFFY -> GLD on the Doppler pool, GLD -> USDG.
    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, SCHIFFY, GLD, 0, key, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, GLD, USDG, 0, gldKey, 1);
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

    function testSchiffy_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(SCHIFFY).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, SCHIFFY, PER_DEAL));
        _fund(id);
        assertEq(IERC20(SCHIFFY).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(SCHIFFY).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, SCHIFFY, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(SCHIFFY).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(SCHIFFY).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testSchiffy_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, SCHIFFY, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, SCHIFFY, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, SCHIFFY, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, SCHIFFY, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(SCHIFFY, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, SCHIFFY, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(SCHIFFY).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(SCHIFFY).allowed);
        assertFalse(memeUsdg.getERC20Config(SCHIFFY).allowed);
        assertFalse(ponsWeth.getERC20Config(SCHIFFY).allowed);
        // GLD stays a routing hop only.
        assertFalse(registry.getERC20Config(GLD).allowed);
    }

    function testSchiffy_twoHopCashoutThroughDopplerPoolAndGld() public {
        uint256 id = _list(Collateral(Kind.ERC20, SCHIFFY, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerGld = IERC20(GLD).balanceOf(address(cashout));
        uint256 routerToken = IERC20(SCHIFFY).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(IERC20(GLD).balanceOf(address(cashout)), routerGld);
        assertEq(IERC20(SCHIFFY).balanceOf(address(cashout)), routerToken);
    }

    function testSchiffy_cashoutRequiresBothLegs() public {
        uint256 id = _list(Collateral(Kind.ERC20, SCHIFFY, PER_DEAL));
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
        cashout.setV4Route(gldKey, false);
        vm.stopPrank();
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testSchiffy_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testSchiffy_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }
}
