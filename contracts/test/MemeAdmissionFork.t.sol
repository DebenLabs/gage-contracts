// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "./utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {UniV4PositionAdapter} from "../src/libraries/UniV4PositionAdapter.sol";
import {Collateral, Kind} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";

/// All state changes are local fork fixtures. Uses the existing deployed Gage vault and registry.
contract MemeAdmissionForkTest is V4Fixture {
    using StateLibrary for IPoolManager;

    address constant MEME = address(bytes20(hex"385f4f8ae47651ce5f58f5265395a669f8281e18"));
    address constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));
    address constant HOOK = address(bytes20(hex"0000000000000000000000000000000000000000"));
    bytes32 constant POOL = 0x4b7c86491df95f366b31217b2950d2c5136a2f19b6879613eac73d0e69092a1a;
    CollateralRegistry registry;
    DealVault vault;
    PoolKey key;
    address borrower;
    address lender;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_EVIDENCE_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(MEME.codehash, 0xf10f86b05965a827a332e6c73086f18026fbe3917f4bffbec3f938b3b5397b56);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        registry = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        vault = DealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
        assertEq(address(vault.REGISTRY()), address(registry));
        key = PoolKey(Currency.wrap(MEME), Currency.wrap(USDG), 6999, 70, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        assertEq(uint160(HOOK) & 769, 0);
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(MEME, true, Lane.MEME, 1000e18, 50_000e18, 250_000e18);
        registry.setPoolAllowed(POOL, true, 1);
        vm.stopPrank();
        borrower = makeAddr("MEME borrower");
        lender = makeAddr("MEME lender");
        deal(MEME, borrower, 100_000e18);
        deal(USDG, borrower, 10_000e6);
        deal(USDG, lender, 10_000e6);
        vm.startPrank(borrower);
        IERC20(MEME).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    function _settle(uint256 id, bool defaulted) internal returns (address receiver) {
        vm.prank(lender);
        vault.fund(id, lender);
        if (defaulted) {
            vm.warp(vault.claimableAt(id));
            vm.prank(lender);
            vault.claim(id);
            return lender;
        }
        vm.prank(borrower);
        vault.reclaim(id);
        return borrower;
    }

    function testFork_MEME_tokenReclaimDefaultExactTransfers() public {
        uint256 baseline = IERC20(MEME).balanceOf(address(vault));
        for (uint256 i; i < 2; ++i) {
            vm.prank(borrower);
            uint256 id = vault.list(Collateral(Kind.ERC20, MEME, 10_000e18), 100e6, 7 days, 0, 90e6);
            assertEq(IERC20(MEME).balanceOf(address(vault)) - baseline, 10_000e18);
            address receiver = _settle(id, i == 1);
            uint256 beforeBalance = IERC20(MEME).balanceOf(receiver);
            vm.prank(receiver);
            vault.withdrawERC20(MEME);
            assertEq(IERC20(MEME).balanceOf(receiver) - beforeBalance, 10_000e18);
            assertEq(IERC20(MEME).balanceOf(address(vault)), baseline);
        }
    }

    function _swapExact(PoolKey memory k, address token, uint256 amount) internal returns (uint256 out) {
        bool zeroForOne = token == Currency.unwrap(k.currency0);
        address output = Currency.unwrap(zeroForOne ? k.currency1 : k.currency0);
        (uint160 sqrt,,,) = poolManager.getSlot0(PoolId.wrap(_poolId(k)));
        uint256 beforeIn = IERC20(token).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        IERC20(token).approve(address(swapRouter), amount);
        swapRouter.swap(
            k,
            SwapParams(zeroForOne, -int256(amount), zeroForOne ? sqrt / 2 : sqrt * 2),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(beforeIn - IERC20(token).balanceOf(address(this)), amount, "Partial fill or input transfer mismatch");
        out = IERC20(output).balanceOf(address(this)) - beforeOut;
    }

    function testFork_MEME_exitLimits() public {
        swapRouter = new PoolSwapTest(poolManager);
        (uint160 s,,,) = poolManager.getSlot0(PoolId.wrap(POOL));
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 2; i++) {
            uint256 amount = i == 0 ? 50_000e18 : 250_000e18;
            uint256 spot = Math.mulDiv(amount, uint256(s) * s, 1 << 192);
            deal(MEME, address(this), amount);
            uint256 out = _swapExact(key, MEME, amount);
            emit log_named_uint(i == 0 ? "perDealInput" : "aggregateInput", amount);
            emit log_named_uint("spotUSDGRaw", spot);
            emit log_named_uint("exitUSDGRaw", out);
            emit log_named_uint("exitBpsBeforeGas", out * 10_000 / spot);
            assertGe(out * 10_000 / spot, 9500);
            vm.revertToState(snapshot);
            snapshot = vm.snapshotState();
        }
    }

    function testFork_MEME_limitsAndRevocation() public {
        deal(MEME, borrower, 300_000e18);
        vm.startPrank(borrower);
        vm.expectRevert();
        vault.list(Collateral(Kind.ERC20, MEME, 999e18), 100e6, 7 days, 0, 90e6);
        vm.expectRevert();
        vault.list(Collateral(Kind.ERC20, MEME, 50_001e18), 100e6, 7 days, 0, 90e6);
        uint256 first;
        for (uint256 i; i < 5; i++) {
            uint256 id = vault.list(Collateral(Kind.ERC20, MEME, 50_000e18), 100e6, 7 days, 0, 90e6);
            if (i == 0) first = id;
        }
        vm.expectRevert();
        vault.list(Collateral(Kind.ERC20, MEME, 1000e18), 100e6, 7 days, 0, 90e6);
        vm.stopPrank();
        assertEq(vault.openRaw(MEME), 250_000e18);
        vm.prank(registry.owner());
        registry.setERC20Allowed(MEME, false, Lane.MEME, 0, 0, 0);
        uint256 beforeBalance = IERC20(MEME).balanceOf(borrower);
        vm.prank(borrower);
        vault.cancel(first);
        vm.prank(borrower);
        vault.withdrawCollateral(first);
        assertEq(IERC20(MEME).balanceOf(borrower) - beforeBalance, 50_000e18);
        assertEq(vault.openRaw(MEME), 200_000e18);
    }

    function testFork_MEME_USDG_LP_rejectedEvenWithPairMask() public {
        vm.prank(registry.owner());
        registry.setMemePairs(7);
        _approvePosm(borrower, MEME);
        _approvePosm(borrower, USDG);
        uint256 nft = _mint(key, -887_250, 887_250, 1e15, borrower, borrower);
        assertGt(posm.getPositionLiquidity(nft), 0);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.PairNotAllowed.selector, MEME, USDG));
        vm.prank(borrower);
        vault.list(Collateral(Kind.UNIV4_POSITION, address(posm), nft), 100e6, 7 days, 0, 90e6);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        _decrease(key, nft, 1e15, borrower, borrower);
        assertEq(posm.getPositionLiquidity(nft), 0);
    }

    function testFork_MEME_USDG_existingV2ReclaimDefaultUnwind() public {
        vault = DealVault(0xc23A08282AA1A9141C6fD7A29e7dFbFe841cC6B6);
        registry = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        assertEq(address(vault.REGISTRY()), address(registry));
        assertEq(vault.POSITION_MANAGER(), address(posm));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(MEME, true, Lane.MEME, 1000e18, 50_000e18, 250_000e18);
        registry.setPoolAllowed(POOL, true, 1);
        vm.stopPrank();
        _approvePosm(borrower, MEME);
        _approvePosm(borrower, USDG);
        vm.startPrank(borrower);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        for (uint256 i; i < 2; i++) {
            uint256 nft = _mint(key, -887_250, 887_250, 1e15, borrower, borrower);
            vm.prank(borrower);
            uint256 id = vault.list(Collateral(Kind.UNIV4_POSITION, address(posm), nft), 100e6, 7 days, 0, 90e6);
            assertEq(IERC721(address(posm)).ownerOf(nft), address(vault));
            address receiver = _settle(id, i == 1);
            vm.prank(receiver);
            vault.withdrawPosition(nft);
            assertEq(IERC721(address(posm)).ownerOf(nft), receiver);
            uint256 before0 = IERC20(MEME).balanceOf(receiver);
            uint256 before1 = IERC20(USDG).balanceOf(receiver);
            _decrease(key, nft, 1e15, receiver, receiver);
            assertGt(IERC20(MEME).balanceOf(receiver), before0);
            assertGt(IERC20(USDG).balanceOf(receiver), before1);
            assertEq(posm.getPositionLiquidity(nft), 0);
        }
    }
}
