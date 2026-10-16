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
import {GageV2ZapRouter} from "../../src/v2/GageV2ZapRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {LiveEngine} from "./fixtures/LiveEngine.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// Tests the deployed native V2 engine, bridge and custody implementation. Only admissions and test capital change
/// locally, after the fork reopens the engine to new loans.
contract ZzzAdmissionLiveForkTest is V4Fixture {
    address constant ZZZ = address(0x007dbf38976f6d3b9c529e7d9484a71898b409ee6a);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant POOL = 0xdd96a8b750ee5eb3c13dcf874ee7dfdfd8b2b04706ed676db7b9921536290641;
    GageV2Vault vault;
    GageV2Registry registry;
    PoolKey key;
    address borrower;
    address lender;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_ZZZ_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_ZZZ_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(ZZZ.codehash, 0x3d5ba33c3a94f655c16348011ff2c72f6ce8085239454ce4a6c4bf284e84a597);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        vault = GageV2Vault(0x22658055B70b8B09616B1e0953f2A51cc66cF493);
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), 0x1D9f88705D398Cd13Af4e35A74ef21253734f153);
        // Mainnet has since closed this engine to new loans. It is reopened on this fork only.
        LiveEngine.reopen(vault);
        key = PoolKey(Currency.wrap(USDG), Currency.wrap(ZZZ), 9800, 98, IHooks(address(0)));
        assertEq(_poolId(key), POOL);
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(ZZZ, true, Lane.MEME, 1000e18, 20_000e18, 100_000e18);
        registry.setPoolAllowed(POOL, true, 1e15);
        registry.setPoolInRangeRequired(POOL, true);
        vm.stopPrank();
        borrower = makeAddr("ZZZ borrower");
        lender = makeAddr("ZZZ lender");
        deal(ZZZ, borrower, 120_000e18);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(ZZZ).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        _approvePosm(borrower, ZZZ);
        _approvePosm(borrower, USDG);
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

    function testZZZ_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(ZZZ).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, ZZZ, 10_000e18));
        _fund(id);
        assertEq(IERC20(ZZZ).balanceOf(vault.getLoan(id).account), 10_000e18);
        _repay(id);
        assertEq(IERC20(ZZZ).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, ZZZ, 10_000e18));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(ZZZ).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(ZZZ).balanceOf(lender) - lenderBefore, 10_000e18);
    }

    function testZZZ_lpReclaimUnwindAndDefaultRecovery() public {
        uint256 nft = _mint(key, -887_194, 887_194, 2e15, borrower, borrower);
        uint256 id = _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        _fund(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), vault.getLoan(id).account);
        _repay(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        uint256 b0 = IERC20(USDG).balanceOf(borrower);
        uint256 b1 = IERC20(ZZZ).balanceOf(borrower);
        _decrease(key, nft, 2e15, borrower, borrower);
        assertGt(IERC20(USDG).balanceOf(borrower), b0);
        assertGt(IERC20(ZZZ).balanceOf(borrower), b1);
        nft = _mint(key, -887_194, 887_194, 2e15, borrower, borrower);
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

    function testZZZ_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ZZZ, 999e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ZZZ, 20_001e18));
        uint256 first;
        for (uint256 i; i < 5; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, ZZZ, 20_000e18));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, ZZZ, 1000e18));
        vm.prank(registry.owner());
        registry.setERC20Allowed(ZZZ, false, Lane.MEME, 0, 0, 0);
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(ZZZ).balanceOf(borrower), 40_000e18);
        CollateralRegistry old = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        assertFalse(old.getERC20Config(ZZZ).allowed);
        assertFalse(old.getPoolConfig(POOL).allowed);
    }

    function testZZZ_usdgZapUsesDeployedRouter() public {
        GageV2ZapRouter zap = GageV2ZapRouter(payable(0xDEa3b7B6f57c63CcE013a64BA42020C10Af083aD));
        GageV2ZapRouter.Swap[] memory swaps = new GageV2ZapRouter.Swap[](1);
        swaps[0] = GageV2ZapRouter.Swap(key, true, 250e6, 1);
        GageV2ZapRouter.Zap memory z = GageV2ZapRouter.Zap(
            USDG,
            500e6,
            false,
            key,
            -887_194,
            887_194,
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

    function testZZZ_minimumLiquidityRejected() public {
        uint256 nft = _mint(key, -887_194, 887_194, 1e15, borrower, borrower);
        vm.expectRevert();
        _list(Collateral(Kind.UNIV4_POSITION, address(posm), nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }
}
