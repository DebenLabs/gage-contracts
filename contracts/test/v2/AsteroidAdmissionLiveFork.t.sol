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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {GageV2ZapRouter} from "../../src/v2/GageV2ZapRouter.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {LiveEngine} from "./fixtures/LiveEngine.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {UniV4PositionAdapter} from "../../src/libraries/UniV4PositionAdapter.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// Tests the deployed native V2 engine against the live ASTEROID/SPCX Doppler-hook pool. Only admissions and
/// test capital change locally, after the fork reopens the engine to new loans. The removal-hook exception is exercised
/// in both directions before any deposit.
contract AsteroidAdmissionLiveForkTest is V4Fixture {
    address constant ASTEROID = 0xFd82D8DB539b6AcE0D50815845133767e24F1E18;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant HOOK = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    bytes32 constant POOL = 0x15a09db785c7b5fc9d794f685a04e4ad38842a2035b9a8fab17909c0e54c425f;
    bytes32 constant STOCK_POOL = 0xcb6ffbcc84359535c2cc0a5688c0a76520ea6e0a4820fddd3ac8d7880e576370;
    bytes32 constant HOOK_HASH = 0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631;
    int24 constant LOWER = -887_272;
    int24 constant UPPER = 887_272;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey key;
    PoolKey stockKey;
    address borrower;
    address lender;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_ASTEROID_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_ASTEROID_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(ASTEROID.codehash, 0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56);
        assertEq(HOOK.codehash, HOOK_HASH);
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
        key = PoolKey(Currency.wrap(SPCX), Currency.wrap(ASTEROID), 8_388_608, 8, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        stockKey = PoolKey(Currency.wrap(SPCX), Currency.wrap(USDG), 10_000, 200, IHooks(address(0)));
        assertEq(_poolId(stockKey), STOCK_POOL);
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(stockKey));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(ASTEROID, true, Lane.MEME, 12_000e18, 200_000e18, 1_000_000e18);
        registry.setPoolRemovalHook(POOL, HOOK, HOOK_HASH);
        registry.setPoolAllowed(POOL, true, 1e15);
        cashout.setV4Route(key, true);
        vm.stopPrank();
        assertFalse(registry.poolInRangeRequired(POOL));
        borrower = makeAddr("ASTEROID borrower");
        lender = makeAddr("ASTEROID lender");
        deal(ASTEROID, borrower, 6_000_000e18);
        deal(SPCX, borrower, 20e18);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(ASTEROID).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        _approvePosm(borrower, ASTEROID);
        _approvePosm(borrower, SPCX);
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

    /// USDG raw value of `amount` raw ASTEROID at the current two-pool spot, before fees and impact.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        (, bytes memory memeData) = address(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b)
            .staticcall(abi.encodeWithSignature("getSlot0(bytes32)", POOL));
        (uint160 sqrtMeme,,,) = abi.decode(memeData, (uint160, int24, uint24, uint24));
        (, bytes memory stockData) = address(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b)
            .staticcall(abi.encodeWithSignature("getSlot0(bytes32)", STOCK_POOL));
        (uint160 sqrtStock,,,) = abi.decode(stockData, (uint160, int24, uint24, uint24));
        uint256 spcx = FullMath.mulDiv(amount, 1 << 192, uint256(sqrtMeme) * uint256(sqrtMeme));
        return FullMath.mulDiv(spcx, uint256(sqrtStock) * uint256(sqrtStock), 1 << 192);
    }

    /// Sell `amount` raw ASTEROID through the actual hooked pool and the SPCX/USDG pool; return USDG received.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        address trader = makeAddr("ASTEROID trader");
        deal(ASTEROID, trader, amount);
        _swap(key, false, -int256(amount), trader);
        uint256 spcxOut = IERC20(SPCX).balanceOf(trader);
        assertGt(spcxOut, 0);
        _swap(stockKey, true, -int256(spcxOut), trader);
        usdgOut = IERC20(USDG).balanceOf(trader);
    }

    function testAsteroid_removalHookExceptionGatesAdmission() public {
        vm.prank(registry.owner());
        registry.setPoolRemovalHook(POOL, address(0), bytes32(0));
        uint256 nft = _mint(key, LOWER, UPPER, 2e15, borrower, borrower);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, HOOK));
        vault.list(
            Collateral(Kind.UNIV4_POSITION, address(posm), nft),
            90e6,
            100e6,
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.prank(registry.owner());
        registry.setPoolRemovalHook(POOL, HOOK, HOOK_HASH);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
    }

    function testAsteroid_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(ASTEROID).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, ASTEROID, 100_000e18));
        _fund(id);
        assertEq(IERC20(ASTEROID).balanceOf(vault.getLoan(id).account), 100_000e18);
        _repay(id);
        assertEq(IERC20(ASTEROID).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, ASTEROID, 100_000e18));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(ASTEROID).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(ASTEROID).balanceOf(lender) - lenderBefore, 100_000e18);
    }

    function testAsteroid_lpReclaimUnwindAndDefaultRecovery() public {
        uint256 nft = _mint(key, LOWER, UPPER, 2e15, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
        _repay(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        uint256 b0 = IERC20(SPCX).balanceOf(borrower);
        uint256 b1 = IERC20(ASTEROID).balanceOf(borrower);
        _decrease(key, nft, 2e15, borrower, borrower);
        assertGt(IERC20(SPCX).balanceOf(borrower), b0);
        assertGt(IERC20(ASTEROID).balanceOf(borrower), b1);
        nft = _mint(key, LOWER, UPPER, 2e15, borrower, borrower);
        id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        _default(id);
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

    function testAsteroid_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ASTEROID, 11_999e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ASTEROID, 200_001e18));
        uint256 first;
        for (uint256 i; i < 5; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, ASTEROID, 200_000e18));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ASTEROID, 12_000e18));
        vm.prank(registry.owner());
        registry.setERC20Allowed(ASTEROID, false, Lane.MEME, 0, 0, 0);
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(ASTEROID).balanceOf(borrower), 5_200_000e18);
        CollateralRegistry old = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        assertFalse(old.getERC20Config(ASTEROID).allowed);
        assertFalse(old.getPoolConfig(POOL).allowed);
    }

    function testAsteroid_usdgZapUsesDeployedRouter() public {
        GageV2ZapRouter zap = GageV2ZapRouter(payable(0xDEa3b7B6f57c63CcE013a64BA42020C10Af083aD));
        GageV2ZapRouter.Swap[] memory swaps = new GageV2ZapRouter.Swap[](2);
        swaps[0] = GageV2ZapRouter.Swap(stockKey, false, 500e6, 1);
        swaps[1] = GageV2ZapRouter.Swap(key, true, 16e17, 1);
        GageV2ZapRouter.Zap memory z = GageV2ZapRouter.Zap(
            USDG,
            500e6,
            false,
            key,
            LOWER,
            UPPER,
            1e15 + 1,
            100e6,
            90e6,
            7 days,
            block.timestamp + 60,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.startPrank(borrower);
        IERC20(USDG).approve(address(zap), 500e6);
        (uint256 id, uint256 nft, uint128 liquidity) = zap.zapAndList(z, swaps);
        vm.stopPrank();
        assertGt(liquidity, 1e15);
        assertEq(vault.ownerOf(id), borrower);
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
        _fund(id);
        _repay(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function testAsteroid_twoHopCashoutThroughSpcx() public {
        uint256 nft = _mint(key, LOWER, UPPER, 5e19, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x;
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1;
        x.minUnderlying1 = 1;
        x.deadline = block.timestamp;
        x.routes = new GageV2CashoutRouter.Route[](2);
        x.routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, ASTEROID, SPCX, 0, key, 1);
        x.routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, SPCX, USDG, 0, stockKey, 1);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(posm.getPositionLiquidity(nft), 0);
    }

    function testAsteroid_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(200_000e18);
        uint256 out = _sellTwoHop(200_000e18);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testAsteroid_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(1_000_000e18);
        uint256 out = _sellTwoHop(1_000_000e18);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }

    function testAsteroid_minimumLiquidityRejected() public {
        uint256 nft = _mint(key, LOWER, UPPER, 1e15, borrower, borrower);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }
}
