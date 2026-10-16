// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
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
contract HookrAdmissionForkTest is V4Fixture {
    using StateLibrary for IPoolManager;

    address constant HOOKR = address(bytes20(hex"18e674231a58c239dc7daedcffe15ec3a24cff5c"));
    address constant USDG = address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"));
    address constant HOOK = address(bytes20(hex"0000000000000000000000000000000000000000"));
    bytes32 constant POOL = 0x590dcb6a87828bf688b48089a62239b693378f1fb64d2286e6a399ed8c005fdf;
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
        assertEq(HOOKR.codehash, 0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        registry = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        vault = DealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
        assertEq(address(vault.REGISTRY()), address(registry));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(HOOKR), 2500, 25, IHooks(HOOK));
        assertEq(_poolId(key), POOL);
        assertEq(uint160(HOOK) & 769, 0);
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(HOOKR, true, Lane.MEME, 5000e18, 100_000e18, 500_000e18);
        registry.setPoolAllowed(POOL, true, 1);
        vm.stopPrank();
        borrower = makeAddr("HOOKR borrower");
        lender = makeAddr("HOOKR lender");
        deal(HOOKR, borrower, 100_000e18);
        deal(USDG, borrower, 10_000e6);
        deal(USDG, lender, 10_000e6);
        vm.startPrank(borrower);
        IERC20(HOOKR).approve(address(vault), type(uint256).max);
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

    function testFork_HOOKR_tokenReclaimDefaultExactTransfers() public {
        uint256 baseline = IERC20(HOOKR).balanceOf(address(vault));
        for (uint256 i; i < 2; ++i) {
            vm.prank(borrower);
            uint256 id = vault.list(Collateral(Kind.ERC20, HOOKR, 10_000e18), 100e6, 7 days, 0, 90e6);
            assertEq(IERC20(HOOKR).balanceOf(address(vault)) - baseline, 10_000e18);
            address receiver = _settle(id, i == 1);
            uint256 beforeBalance = IERC20(HOOKR).balanceOf(receiver);
            vm.prank(receiver);
            vault.withdrawERC20(HOOKR);
            assertEq(IERC20(HOOKR).balanceOf(receiver) - beforeBalance, 10_000e18);
            assertEq(IERC20(HOOKR).balanceOf(address(vault)), baseline);
        }
    }

    function _swapExact(PoolKey memory k, address token, uint256 amount) internal returns (uint256 out) {
        bool zeroForOne = token == Currency.unwrap(k.currency0);
        address output = Currency.unwrap(zeroForOne ? k.currency1 : k.currency0);
        (uint160 sqrt,,,) = poolManager.getSlot0(PoolId.wrap(_poolId(k)));
        uint256 beforeIn = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 beforeOut = output == address(0) ? address(this).balance : IERC20(output).balanceOf(address(this));
        if (token != address(0)) IERC20(token).approve(address(swapRouter), amount);
        swapRouter.swap{value: token == address(0) ? amount : 0}(
            k,
            SwapParams(zeroForOne, -int256(amount), zeroForOne ? sqrt / 2 : sqrt * 2),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(
            beforeIn - (token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this))),
            amount,
            "Partial fill or input transfer mismatch"
        );
        out = (output == address(0) ? address(this).balance : IERC20(output).balanceOf(address(this))) - beforeOut;
    }

    function testFork_HOOKR_exitLimits() public {
        swapRouter = new PoolSwapTest(poolManager);
        (uint160 s,,,) = poolManager.getSlot0(PoolId.wrap(POOL));
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 2; i++) {
            uint256 amount = i == 0 ? 100_000e18 : 500_000e18;
            PoolKey memory usdKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
            (uint160 usdS,,,) = poolManager.getSlot0(PoolId.wrap(_poolId(usdKey)));
            uint256 spotEth = Math.mulDiv(amount, 1 << 192, uint256(s) * s);
            uint256 spot = Math.mulDiv(spotEth, uint256(usdS) * usdS, 1 << 192);
            deal(HOOKR, address(this), amount);
            uint256 outEth = _swapExact(key, HOOKR, amount);
            uint256 out = _swapExact(usdKey, address(0), outEth);
            emit log_named_uint(i == 0 ? "perDealInput" : "aggregateInput", amount);
            emit log_named_uint("spotUSDGRaw", spot);
            emit log_named_uint("exitUSDGRaw", out);
            emit log_named_uint("exitBpsBeforeGas", out * 10_000 / spot);
            assertGe(out * 10_000 / spot, 9500);
            vm.revertToState(snapshot);
            snapshot = vm.snapshotState();
        }
    }

    function testFork_HOOKR_limitsAndRevocation() public {
        deal(HOOKR, borrower, 600_000e18);
        vm.startPrank(borrower);
        vm.expectRevert();
        vault.list(Collateral(Kind.ERC20, HOOKR, 4999e18), 100e6, 7 days, 0, 90e6);
        vm.expectRevert();
        vault.list(Collateral(Kind.ERC20, HOOKR, 100_001e18), 100e6, 7 days, 0, 90e6);
        uint256 first;
        for (uint256 i; i < 5; i++) {
            uint256 id = vault.list(Collateral(Kind.ERC20, HOOKR, 100_000e18), 100e6, 7 days, 0, 90e6);
            if (i == 0) first = id;
        }
        vm.expectRevert();
        vault.list(Collateral(Kind.ERC20, HOOKR, 5000e18), 100e6, 7 days, 0, 90e6);
        vm.stopPrank();
        assertEq(vault.openRaw(HOOKR), 500_000e18);
        vm.prank(registry.owner());
        registry.setERC20Allowed(HOOKR, false, Lane.MEME, 0, 0, 0);
        uint256 beforeBalance = IERC20(HOOKR).balanceOf(borrower);
        vm.prank(borrower);
        vault.cancel(first);
        vm.prank(borrower);
        vault.withdrawCollateral(first);
        assertEq(IERC20(HOOKR).balanceOf(borrower) - beforeBalance, 100_000e18);
        assertEq(vault.openRaw(HOOKR), 400_000e18);
    }

    receive() external payable {}

    function testFork_HOOKR_ETH_existingVaultsRejectAndOwnerCanUnwind() public {
        _approvePosm(borrower, HOOKR);
        deal(borrower, 10 ether);
        uint256 nft = posm.nextTokenId();
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            int24(-887_250),
            int24(887_250),
            uint256(1e18),
            type(uint128).max,
            type(uint128).max,
            borrower,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(address(0), borrower);
        vm.prank(borrower);
        posm.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp + 1);
        assertGt(posm.getPositionLiquidity(nft), 0);
        address[2] memory vaults = [address(vault), address(0xc23A08282AA1A9141C6fD7A29e7dFbFe841cC6B6)];
        address[2] memory regs = [address(registry), address(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d)];
        for (uint256 i; i < 2; i++) {
            CollateralRegistry reg = CollateralRegistry(regs[i]);
            vm.startPrank(reg.owner());
            reg.setMemePairs(7);
            reg.setERC20Allowed(HOOKR, true, Lane.MEME, 5000e18, 100_000e18, 500_000e18);
            reg.setPoolAllowed(POOL, true, 1);
            vm.stopPrank();
            vm.prank(borrower);
            IERC721(address(posm)).setApprovalForAll(vaults[i], true);
            vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.PairNotAllowed.selector, address(0), HOOKR));
            vm.prank(borrower);
            DealVault(vaults[i]).list(Collateral(Kind.UNIV4_POSITION, address(posm), nft), 100e6, 7 days, 0, 90e6);
            assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        }
        uint256 ethBefore = borrower.balance;
        uint256 tokenBefore = IERC20(HOOKR).balanceOf(borrower);
        _decrease(key, nft, 1e18, borrower, borrower);
        assertEq(posm.getPositionLiquidity(nft), 0);
        assertGt(borrower.balance, ethBefore);
        assertGt(IERC20(HOOKR).balanceOf(borrower), tokenBefore);
    }
}
