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
contract SnapAdmissionForkTest is V4Fixture {
    using StateLibrary for IPoolManager;

    address constant SNAP = address(bytes20(hex"f6589f11bc40b669e584073f428b05562f568733"));
    address constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));
    bytes32 constant POOL = 0x2e4cc4c65587faca7a08b69a13c86ca8c86599d90ad818ceaa1a875176f5fb52;
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
        key = PoolKey(Currency.wrap(USDG), Currency.wrap(SNAP), 1950, 20, IHooks(address(0)));
        assertEq(_poolId(key), POOL);
        vm.startPrank(registry.owner());
        // Preserve the exact approved raw minimum from the original SNAP evidence block.
        registry.setERC20Allowed(SNAP, true, Lane.STOCK, 18_522_671_862_958_979_683, 200e18, 1000e18);
        vm.stopPrank();
        borrower = makeAddr("SNAP borrower");
        lender = makeAddr("SNAP lender");
        deal(SNAP, borrower, 100_000e18);
        deal(USDG, borrower, 10_000e6);
        deal(USDG, lender, 10_000e6);
        vm.startPrank(borrower);
        IERC20(SNAP).approve(address(vault), type(uint256).max);
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

    function testFork_SNAP_tokenReclaimDefaultExactTransfers() public {
        uint256 baseline = IERC20(SNAP).balanceOf(address(vault));
        for (uint256 i; i < 2; ++i) {
            vm.prank(borrower);
            uint256 id = vault.list(Collateral(Kind.ERC20, SNAP, 100e18), 100e6, 7 days, 0, 90e6);
            assertEq(IERC20(SNAP).balanceOf(address(vault)) - baseline, 100e18);
            address receiver = _settle(id, i == 1);
            uint256 beforeBalance = IERC20(SNAP).balanceOf(receiver);
            vm.prank(receiver);
            vault.withdrawERC20(SNAP);
            assertEq(IERC20(SNAP).balanceOf(receiver) - beforeBalance, 100e18);
            assertEq(IERC20(SNAP).balanceOf(address(vault)), baseline);
        }
    }

    function _swap(address token, uint256 amount, uint160 limit) internal returns (uint256 spent, uint256 output) {
        bool z = token == USDG;
        address other = z ? SNAP : USDG;
        deal(token, address(this), amount);
        uint256 beforeOut = IERC20(other).balanceOf(address(this));
        IERC20(token).approve(address(swapRouter), amount);
        swapRouter.swap(key, SwapParams(z, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), "");
        spent = amount - IERC20(token).balanceOf(address(this));
        output = IERC20(other).balanceOf(address(this)) - beforeOut;
    }

    function testFork_SNAP_measuredDepth() public {
        swapRouter = new PoolSwapTest(poolManager);
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(POOL));
        uint256 snapshot = vm.snapshotState();
        (, uint256 snapOut) = _swap(USDG, 1e15, price / 2);
        assertTrue(vm.revertToState(snapshot));
        (, uint256 usdgOut) = _swap(SNAP, 1e24, price * 2);
        assertTrue(vm.revertToState(snapshot));
        uint256 depth = usdgOut + Math.mulDiv(snapOut, 1 << 192, uint256(price) * price);
        uint256 perDealSpot = Math.mulDiv(200e18, 1 << 192, uint256(price) * price);
        uint256 aggregateSpot = Math.mulDiv(1000e18, 1 << 192, uint256(price) * price);
        emit log_named_uint("SNAP output inventory", snapOut);
        emit log_named_uint("USDG output inventory", usdgOut);
        emit log_named_uint("Depth USDG raw", depth);
        assertLe(perDealSpot, depth * 2 / 100);
        assertLe(aggregateSpot, depth / 10);
    }

    function _exit(uint256 amount) internal {
        swapRouter = new PoolSwapTest(poolManager);
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(POOL));
        uint256 spot = Math.mulDiv(amount, 1 << 192, uint256(price) * price);
        (uint256 spent, uint256 output) = _swap(SNAP, amount, price * 2);
        assertEq(spent, amount, "Partial fill or transfer mismatch");
        emit log_named_uint("SNAP raw input", amount);
        emit log_named_uint("Spot USDG raw", spot);
        emit log_named_uint("Received USDG raw", output);
        assertGe(output, spot * 95 / 100, "Exit exceeds 5 percent all-in loss");
    }

    function testFork_SNAP_perDealExit() public {
        _exit(200e18);
    }

    function testFork_SNAP_aggregateExit() public {
        _exit(1000e18);
    }
}
