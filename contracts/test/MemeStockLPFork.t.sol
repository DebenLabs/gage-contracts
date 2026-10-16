// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Fixture} from "./utils/V4Fixture.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {UniV4PositionAdapter} from "../src/libraries/UniV4PositionAdapter.sol";
import {Collateral, Kind} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";

/// @notice Actual BONER/HIMS PoolManager, PositionManager, tokens and hook; all writes stay inside Foundry's fork.
contract MemeStockLPForkTest is V4Fixture {
    address constant BONER = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18;
    address constant HIMS = 0xCceE82fE024c36fA15E1005edE3E9e4787e23D09;
    address constant HOOK = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    bytes32 constant HOOK_HASH = 0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631;
    bytes32 constant POOL_ID = 0x9c89b04303dfa76f3f6fb02c2b77be0e8a00ab8fa00d507119acd54ab3e8640d;
    uint128 constant LIQUIDITY = 1e18;

    function testFork_bonerHims_borrowReclaimDefaultAndUnwind() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        assertEq(HOOK.codehash, HOOK_HASH, "reviewed hook runtime changed");
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        assertEq(address(posm.poolManager()), address(poolManager));
        PoolKey memory key = PoolKey(Currency.wrap(BONER), Currency.wrap(HIMS), 0x800000, 8, IHooks(HOOK));
        assertEq(_poolId(key), POOL_ID);
        address borrower = makeAddr("LP borrower");
        address lender = makeAddr("LP lender");
        // Starting wallet inventory is a fixture; every mint, custody move and removal executes live code.
        deal(BONER, borrower, 10_000e18);
        deal(HIMS, borrower, 100e18);
        _approvePosm(borrower, BONER);
        _approvePosm(borrower, HIMS);
        // Resolve the chain's USDG from the configured test environment rather than silently use a fixture token.
        IERC20 usdg = IERC20(vm.envAddress("ROBINHOOD_USDG"));
        uint32[] memory terms = new uint32[](1);
        terms[0] = 7 days;
        CollateralRegistry registry = new CollateralRegistry(address(this), terms, 100);
        registry.setERC20Allowed(BONER, true, Lane.MEME, 1, type(uint256).max, type(uint256).max);
        registry.setERC20Allowed(HIMS, true, Lane.STOCK, 1, type(uint256).max, type(uint256).max);
        registry.setPoolAllowed(POOL_ID, true, 1);
        DealVault vault = new DealVault(usdg, registry, address(this), address(posm), 1 days);
        deal(address(usdg), borrower, 1000e6);
        deal(address(usdg), lender, 1000e6);
        vm.startPrank(borrower);
        IERC721(address(posm)).setApprovalForAll(address(vault), true);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        usdg.approve(address(vault), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            uint256 id = _mint(key, -887_272, 887_272, LIQUIDITY, borrower, borrower);
            Collateral memory collateral = Collateral(Kind.UNIV4_POSITION, address(posm), id);
            if (i == 0) {
                vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, HOOK));
                vm.prank(borrower);
                vault.list(collateral, 100e6, 7 days, 0, 90e6);
            }
            registry.setPoolRemovalHook(POOL_ID, HOOK, HOOK_HASH);
            vm.prank(borrower);
            uint256 dealId = vault.list(collateral, 100e6, 7 days, 0, 90e6);
            assertEq(IERC721(address(posm)).ownerOf(id), address(vault));
            vm.prank(lender);
            vault.fund(dealId, lender);
            // Revoking admission affects future listings, never repayment or collateral withdrawal.
            registry.setPoolRemovalHook(POOL_ID, address(0), bytes32(0));
            address receiver;
            if (i == 0) {
                vm.prank(borrower);
                vault.reclaim(dealId);
                receiver = borrower;
            } else {
                vm.warp(vault.claimableAt(dealId));
                vm.prank(lender);
                vault.claim(dealId);
                receiver = lender;
            }
            vm.prank(receiver);
            vault.withdrawPosition(id);
            uint256 before0 = IERC20(BONER).balanceOf(receiver);
            uint256 before1 = IERC20(HIMS).balanceOf(receiver);
            _decrease(key, id, LIQUIDITY, receiver, receiver);
            assertGt(IERC20(BONER).balanceOf(receiver), before0);
            assertGt(IERC20(HIMS).balanceOf(receiver), before1);
            assertEq(posm.getPositionLiquidity(id), 0);
        }
    }
}
