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

interface IMusebookEarn {
    function CURATOR() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRADES() external view returns (address);
    function pickedAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external;
}

interface IMusebookGrades {
    function publisher() external view returns (address);
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external;
}

/// Token-only admission, custody and executable exit validation on a pinned local fork.
contract MusebookAdmissionLiveForkTest is V4Fixture {
    address constant MUSEBOOK = address(bytes20(hex"91a2dae9699f0b82540b5886b0d8759c22820ba3"));
    address constant META = address(bytes20(hex"c0d6457c16cc70d6790dd43521c899c87ce02f35"));
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant HOOK = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address constant META_HOOK = address(0);
    bytes32 constant HOOK_HASH = 0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631;
    bytes32 constant POOL = 0x40a433930370f6cdf0a78debc2c6dd599c23bd428c0d67dd8b5373e4f101557f;
    bytes32 constant META_POOL = 0x5875d407a42965b0e768c8925cea290e06fa50603ef34fc99eb92a1050e6ae36;
    uint256 constant MIN = 500_000e18;
    uint256 constant PER_DEAL = 10_000_000e18;
    uint256 constant AGGREGATE = 50_000_000e18;
    uint256 constant DEALT = 1_000_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey key;
    PoolKey metaKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_MUSEBOOK_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_MUSEBOOK_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        // Canonical fixed-implementation clone of the compiler-verified DopplerERC20V1 (same bytes as BONER and ASTEROID).
        assertEq(
            MUSEBOOK.code,
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
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        key = PoolKey(Currency.wrap(MUSEBOOK), Currency.wrap(META), 0x800000, 200, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        metaKey = PoolKey(Currency.wrap(USDG), Currency.wrap(META), 3000, 60, IHooks(META_HOOK));
        assertEq(_poolId(metaKey), META_POOL);
        assertFalse(registry.getERC20Config(MUSEBOOK).allowed);
        assertTrue(registry.getERC20Config(META).allowed);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(key));
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(metaKey));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(MUSEBOOK, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        cashout.setV4Route(key, true);
        vm.stopPrank();
        borrower = makeAddr("MUSEBOOK borrower");
        lender = makeAddr("MUSEBOOK lender");
        deal(MUSEBOOK, borrower, DEALT);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(MUSEBOOK).approve(address(vault), type(uint256).max);
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

    /// USDG raw value of `amount` raw MUSEBOOK at the current two-pool spot, before hook charges, fees and impact.
    /// MUSEBOOK is currency0 of its pool (META per MUSEBOOK = sqrt^2 / 2^192); USDG is currency0 of the META pool
    /// (META per USDG = sqrt^2 / 2^192), so USDG per MUSEBOOK = sqrtMusebook^2 / sqrtMeta^2.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        uint256 sqrtMusebook = _sqrt(POOL);
        uint256 sqrtMeta = _sqrt(META_POOL);
        uint256 meta = FullMath.mulDiv(FullMath.mulDiv(amount, sqrtMusebook, 1 << 96), sqrtMusebook, 1 << 96);
        return FullMath.mulDiv(FullMath.mulDiv(meta, 1 << 96, sqrtMeta), 1 << 96, sqrtMeta);
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

    /// Sell `amount` raw MUSEBOOK through the Doppler pool, then the META through META / USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(MUSEBOOK, address(this), amount);
        uint256 metaOut = _swapExact(key, MUSEBOOK, amount);
        assertGt(metaOut, 0);
        usdgOut = _swapExact(metaKey, META, metaOut);
    }

    /// Cash-out routes: MUSEBOOK -> META on the Doppler pool, META -> USDG.
    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, MUSEBOOK, META, 0, key, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, META, USDG, 0, metaKey, 1);
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

    function testMusebook_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(MUSEBOOK).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL));
        _fund(id);
        assertEq(IERC20(MUSEBOOK).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(MUSEBOOK).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(MUSEBOOK).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(MUSEBOOK).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testMusebook_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, MUSEBOOK, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, MUSEBOOK, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(MUSEBOOK, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, MUSEBOOK, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(MUSEBOOK).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(MUSEBOOK).allowed);
        assertFalse(memeUsdg.getERC20Config(MUSEBOOK).allowed);
        assertFalse(ponsWeth.getERC20Config(MUSEBOOK).allowed);
        // Existing META admission remains enabled.
        assertTrue(registry.getERC20Config(META).allowed);
    }

    function testMusebook_twoHopCashoutThroughDopplerPoolAndMeta() public {
        uint256 id = _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerMeta = IERC20(META).balanceOf(address(cashout));
        uint256 routerToken = IERC20(MUSEBOOK).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(IERC20(META).balanceOf(address(cashout)), routerMeta);
        assertEq(IERC20(MUSEBOOK).balanceOf(address(cashout)), routerToken);
    }

    function testMusebook_cashoutRequiresBothLegs() public {
        uint256 id = _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL));
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
        cashout.setV4Route(metaKey, false);
        vm.stopPrank();
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testMusebook_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testMusebook_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }

    function testMusebook_existingMemesVaultCanFundAfterAdmissionAndNormalGradePublication() public {
        IMusebookEarn earn = IMusebookEarn(address(bytes20(hex"c04a365061e5d3cf7f614cf353494294b0e3f0c9")));
        assertEq(earn.REGISTRY(), address(registry));
        assertEq(earn.pickedAssets(), 0);
        uint256 id = _list(Collateral(Kind.ERC20, MUSEBOOK, PER_DEAL));
        // Mirror the existing D132 keeper policy: publish TOP_RANK for an admitted token.
        IMusebookGrades grades = IMusebookGrades(earn.GRADES());
        address[] memory tokens = new address[](1);
        tokens[0] = MUSEBOOK;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 10;
        vm.prank(grades.publisher());
        grades.setGrades(tokens, ranks);
        uint256 before = earn.freeLiquidity();
        vm.prank(earn.CURATOR());
        earn.fund(id, 4, type(uint256).max);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(before - earn.freeLiquidity(), 90e6);
        assertEq(IERC20(MUSEBOOK).balanceOf(vault.getLoan(id).account), PER_DEAL);
    }
}
