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
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {UniV4PositionAdapter} from "../src/libraries/UniV4PositionAdapter.sol";
import {Collateral, Kind} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";

/// All state changes are local fork fixtures. Uses the existing deployed Gage vault and registry.
contract NudesAdmissionForkTest is V4Fixture {
    using StateLibrary for IPoolManager;

    address constant NUDES = address(bytes20(hex"be98b75361935b18d688409424a869a4c3dc7401"));
    address constant SNAP = address(bytes20(hex"f6589f11bc40b669e584073f428b05562f568733"));
    address constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));
    address constant HOOK = address(bytes20(hex"778b0c4eea7d35d66513b587ba87fc9084b0eacc"));
    bytes32 constant POOL = 0x383957bce2341f59ff97c47eda2ad3b3b839b7050adc8a4747a398abca0ad552;
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
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        registry = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        vault = DealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
        assertEq(address(vault.REGISTRY()), address(registry));
        key = PoolKey(Currency.wrap(NUDES), Currency.wrap(SNAP), 0, 200, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        assertEq(uint160(HOOK) & 769, 512);
        vm.startPrank(registry.owner());
        // Exact approved minimum, preserved across activation price changes.
        uint256 minimum = 6_572_421_705_573_701_134_530;
        registry.setERC20Allowed(SNAP, true, Lane.STOCK, 18_522_671_862_958_979_683, 200e18, 1000e18);
        registry.setERC20Allowed(NUDES, true, Lane.MEME, minimum, 20_000e18, 100_000e18);
        vm.stopPrank();
        borrower = makeAddr("NUDES borrower");
        lender = makeAddr("NUDES lender");
        deal(NUDES, borrower, 100_000e18);
        deal(SNAP, borrower, 100e18);
        deal(USDG, borrower, 10_000e6);
        deal(USDG, lender, 10_000e6);
        vm.startPrank(borrower);
        IERC20(NUDES).approve(address(vault), type(uint256).max);
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

    function testFork_NUDES_tokenReclaimDefaultExactTransfers() public {
        uint256 baseline = IERC20(NUDES).balanceOf(address(vault));
        for (uint256 i; i < 2; ++i) {
            vm.prank(borrower);
            uint256 id = vault.list(Collateral(Kind.ERC20, NUDES, 10_000e18), 100e6, 7 days, 0, 90e6);
            assertEq(IERC20(NUDES).balanceOf(address(vault)) - baseline, 10_000e18);
            address receiver = _settle(id, i == 1);
            uint256 beforeBalance = IERC20(NUDES).balanceOf(receiver);
            vm.prank(receiver);
            vault.withdrawERC20(NUDES);
            assertEq(IERC20(NUDES).balanceOf(receiver) - beforeBalance, 10_000e18);
            assertEq(IERC20(NUDES).balanceOf(address(vault)), baseline);
        }
    }

    function testFork_NUDES_SNAP_LP_deployedHookGuardWithMetadataFixture() public {
        vm.prank(registry.owner());
        registry.setPoolAllowed(POOL, true, 1);
        // Isolate the live vault guard with the exact onchain PoolKey. No real NFT is minted:
        // the initial real full-range mint attempt reverted in this pool's beforeAddLiquidity hook.
        uint256 nft = type(uint256).max;
        vm.mockCall(address(posm), abi.encodeWithSelector(IERC721.ownerOf.selector, nft), abi.encode(borrower));
        vm.mockCall(
            address(posm),
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, nft),
            abi.encode(key, PositionInfo.wrap(0))
        );
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, HOOK));
        vm.prank(borrower);
        vault.list(Collateral(Kind.UNIV4_POSITION, address(posm), nft), 100e6, 7 days, 0, 90e6);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function _stockKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(SNAP), 1950, 20, IHooks(address(0)));
    }

    function _swap(PoolKey memory k, address token, uint256 amount, bool requireFull)
        internal
        returns (uint256 output)
    {
        bool z = token == Currency.unwrap(k.currency0);
        address other = Currency.unwrap(z ? k.currency1 : k.currency0);
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(_poolId(k)));
        uint256 beforeIn = IERC20(token).balanceOf(address(this));
        uint256 beforeOut = IERC20(other).balanceOf(address(this));
        IERC20(token).approve(address(swapRouter), amount);
        swapRouter.swap(
            k, SwapParams(z, -int256(amount), z ? price / 2 : price * 2), PoolSwapTest.TestSettings(false, false), ""
        );
        if (requireFull) {
            assertEq(beforeIn - IERC20(token).balanceOf(address(this)), amount, "Partial fill or transfer mismatch");
        }
        output = IERC20(other).balanceOf(address(this)) - beforeOut;
    }

    function _exit(uint256 amount) internal {
        swapRouter = new PoolSwapTest(poolManager);
        (uint160 n,,,) = poolManager.getSlot0(PoolId.wrap(POOL));
        (uint160 s,,,) = poolManager.getSlot0(PoolId.wrap(_poolId(_stockKey())));
        uint256 spot = Math.mulDiv(amount, uint256(n) * n, uint256(s) * s);
        deal(NUDES, address(this), amount);
        uint256 snapOut = _swap(key, NUDES, amount, true);
        uint256 output = _swap(_stockKey(), SNAP, snapOut, true);
        emit log_named_uint("NUDES raw input", amount);
        emit log_named_uint("Intermediate SNAP raw", snapOut);
        emit log_named_uint("Spot USDG raw", spot);
        emit log_named_uint("Received USDG raw", output);
        assertGe(output, spot * 95 / 100, "Exit exceeds 5 percent all-in loss");
    }

    function testFork_NUDES_perDealExit() public {
        _exit(20_000e18);
    }

    function testFork_NUDES_aggregateExit() public {
        _exit(100_000e18);
    }

    function testFork_NUDES_measuredRouteDepth() public {
        swapRouter = new PoolSwapTest(poolManager);
        (uint160 n,,,) = poolManager.getSlot0(PoolId.wrap(POOL));
        (uint160 s,,,) = poolManager.getSlot0(PoolId.wrap(_poolId(_stockKey())));
        uint256 snapshot = vm.snapshotState();
        deal(NUDES, address(this), 1e24);
        uint256 snapOut = _swap(key, NUDES, 1e24, false);
        assertTrue(vm.revertToState(snapshot));
        deal(SNAP, address(this), 5000e18);
        uint256 nudesOut = _swap(key, SNAP, 5000e18, true);
        assertTrue(vm.revertToState(snapshot));
        uint256 memeDepth =
            Math.mulDiv(snapOut, 1 << 192, uint256(s) * s) + Math.mulDiv(nudesOut, uint256(n) * n, uint256(s) * s);
        deal(SNAP, address(this), 1e24);
        uint256 usdOut = _swap(_stockKey(), SNAP, 1e24, false);
        assertTrue(vm.revertToState(snapshot));
        deal(USDG, address(this), 1e15);
        uint256 stockOut = _swap(_stockKey(), USDG, 1e15, false);
        assertTrue(vm.revertToState(snapshot));
        uint256 stockDepth = usdOut + Math.mulDiv(stockOut, 1 << 192, uint256(s) * s);
        uint256 depth = Math.min(memeDepth, stockDepth);
        emit log_named_uint("NUDES pool depth USDG raw", memeDepth);
        emit log_named_uint("SNAP pool depth USDG raw", stockDepth);
        assertLe(Math.mulDiv(20_000e18, uint256(n) * n, uint256(s) * s), depth / 100);
        assertLe(Math.mulDiv(100_000e18, uint256(n) * n, uint256(s) * s), depth * 5 / 100);
    }
}
