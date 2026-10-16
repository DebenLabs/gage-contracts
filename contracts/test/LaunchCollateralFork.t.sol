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

/// @notice Production candidates exercised against live deployed code on a local fork only.
/// Initial token inventory is a fixture; this is lifecycle evidence, not admission or an issuer-control audit.
contract LaunchCollateralForkTest is V4Fixture {
    uint128 constant LIQUIDITY = 1e18;
    address meme;
    address stock;
    address hook;
    bytes32 hookHash;
    bytes32 idPool;

    function _fork() internal {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
    }

    function testFork_aiNVDA_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"2e8c31162b855a2ffa90f6f8634643ad6f111e18")),
            address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27
        );
    }

    function testFork_bonerHIMS_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"98096d17e191b3da1d5f99a6d7b3584351b11e18")),
            address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0x9c89b04303dfa76f3f6fb02c2b77be0e8a00ab8fa00d507119acd54ab3e8640d
        );
    }

    function testFork_mooMU_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"d9db30bb0d2b8d2eae3826a1372117e058791e18")),
            address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0xc3cc877a8a7d28efdb5dbec9ae71724652431e6411aa1a9fc8928028da554aa1
        );
    }

    function testFork_spacehoodSPCX_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"fe7e19cbce2f896c6c528bc355baf5a768291e18")),
            address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0x225cc98f7d66b29fef96377becc7bf89582e2ab7b923a09aee9719fd80eb94ca
        );
    }

    function testFork_icoinAAPL_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"5d6ef090a1461b11c9427ac319260122d1c61e18")),
            address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0xc39187cec78a076c41a4085598b4cc05be2ed9b04a3443167471fa0fc4984188
        );
    }

    function testFork_pairSPY_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"6b1d42927b1a84ec28fa88d4fc6fa7af404966be")),
            address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")),
            10_000,
            200,
            address(bytes20(hex"16d1560630ce74af4478d9b8ad46548a092a2000")),
            bytes32(0),
            0xf224a070c8626c890a085b258cf562ee4bf052b6d1d59104b3b44d722640c001
        );
    }

    function testFork_doggieTSLA_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"a9efe2fc94de79734c03051515f48f254ce61e18")),
            address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0x141be60316aeb3aa7c0e0d8e4fbdc0aa78105e6e462cfc03b8a0f0c59f0bf3f8
        );
    }

    function testFork_earnSPY_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"a3b6aee90017b72c0812dc1e013de70eb2917ba3")),
            address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")),
            8_388_608,
            200,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0x1fb9a45079b017a6661016ba7dea29e1c4864b0874c21f63e137a52e71c3395b
        );
    }

    function testFork_schiffyGLD_reclaimDefaultUnwind() public {
        _pair(
            address(bytes20(hex"42afa2124ca5a2b83898e46b2da9a190995b1e18")),
            address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e")),
            8_388_608,
            8,
            address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")),
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631,
            0xc749412e31087a6e6f9210af575bc9100159fbc9f45da3ca8b26b31f3bf5777e
        );
    }

    function testFork_SPY_tokenReclaimDefault() public {
        _token(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")), Lane.STOCK);
    }

    function testFork_GLD_tokenReclaimDefault() public {
        _token(address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e")), Lane.STOCK);
    }

    function testFork_SPCX_tokenReclaimDefault() public {
        _token(address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea")), Lane.STOCK);
    }

    function testFork_AAPL_tokenReclaimDefault() public {
        _token(address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9")), Lane.STOCK);
    }

    function testFork_NVDA_tokenReclaimDefault() public {
        _token(address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec")), Lane.STOCK);
    }

    function testFork_GOOGL_tokenReclaimDefault() public {
        _token(address(bytes20(hex"2e0847e8910a9732eb3fb1bb4b70a580adad4fe3")), Lane.STOCK);
    }

    function testFork_TSLA_tokenReclaimDefault() public {
        _token(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d")), Lane.STOCK);
    }

    function testFork_DJT_tokenReclaimDefault() public {
        _token(address(bytes20(hex"1d11f0496982706c5e14a514d4e79f2e6bde4516")), Lane.STOCK);
    }

    function testFork_META_tokenReclaimDefault() public {
        _token(address(bytes20(hex"c0d6457c16cc70d6790dd43521c899c87ce02f35")), Lane.STOCK);
    }

    function testFork_PLTR_tokenReclaimDefault() public {
        _token(address(bytes20(hex"894e1ec2d74ffe5aef8dc8a9e84686accb964f2a")), Lane.STOCK);
    }

    function testFork_AMD_tokenReclaimDefault() public {
        _token(address(bytes20(hex"86923f96303d656e4aa86d9d42d1e57ad2023fdc")), Lane.STOCK);
    }

    function testFork_MU_tokenReclaimDefault() public {
        _token(address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd")), Lane.STOCK);
    }

    function testFork_HIMS_tokenReclaimDefault() public {
        _token(address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09")), Lane.STOCK);
    }

    function testFork_AI_tokenReclaimDefault() public {
        _token(address(bytes20(hex"2e8c31162b855a2ffa90f6f8634643ad6f111e18")), Lane.MEME);
    }

    function testFork_BONER_tokenReclaimDefault() public {
        _token(address(bytes20(hex"98096d17e191b3da1d5f99a6d7b3584351b11e18")), Lane.MEME);
    }

    function testFork_MOO_tokenReclaimDefault() public {
        _token(address(bytes20(hex"d9db30bb0d2b8d2eae3826a1372117e058791e18")), Lane.MEME);
    }

    function testFork_SPACEHOOD_tokenReclaimDefault() public {
        _token(address(bytes20(hex"fe7e19cbce2f896c6c528bc355baf5a768291e18")), Lane.MEME);
    }

    function testFork_ICOIN_tokenReclaimDefault() public {
        _token(address(bytes20(hex"5d6ef090a1461b11c9427ac319260122d1c61e18")), Lane.MEME);
    }

    function testFork_PAIR_tokenReclaimDefault() public {
        _token(address(bytes20(hex"6b1d42927b1a84ec28fa88d4fc6fa7af404966be")), Lane.MEME);
    }

    function testFork_DOGGIE_tokenReclaimDefault() public {
        _token(address(bytes20(hex"a9efe2fc94de79734c03051515f48f254ce61e18")), Lane.MEME);
    }

    function testFork_EARN_tokenReclaimDefault() public {
        _token(address(bytes20(hex"a3b6aee90017b72c0812dc1e013de70eb2917ba3")), Lane.MEME);
    }

    function testFork_SCHIFFY_tokenReclaimDefault() public {
        _token(address(bytes20(hex"42afa2124ca5a2b83898e46b2da9a190995b1e18")), Lane.MEME);
    }

    function testFork_BOW_tokenReclaimDefault() public {
        _token(address(bytes20(hex"451b42a15100c340ca12f7c66de06fac5ea2d751")), Lane.MEME);
    }

    function testFork_OPTIMUS_tokenReclaimDefault() public {
        _token(address(bytes20(hex"0ff9072a1ead154d92c2d2fef16afba6028ce2b2")), Lane.MEME);
    }

    function testFork_GG_tokenReclaimDefault() public {
        _token(address(bytes20(hex"cacb0e9caccee63ec4d82952e561a291c68bcb68")), Lane.MEME);
    }

    function _pair(address m, address s, uint24 fee, int24 spacing, address h, bytes32 hh, bytes32 pid) internal {
        meme = m;
        stock = s;
        hook = h;
        hookHash = hh;
        idPool = pid;
        _fork();
        if (hookHash != bytes32(0)) assertEq(hook.codehash, hookHash);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        assertEq(address(posm.poolManager()), address(poolManager));

        (Currency c0, Currency c1) = _sorted(meme, stock);
        PoolKey memory key = PoolKey(c0, c1, fee, spacing, IHooks(hook));
        assertEq(_poolId(key), idPool);
        _exercisePair(key);
    }

    function _exercisePair(PoolKey memory key) internal {
        address borrower = makeAddr("LP borrower");
        address lender = makeAddr("LP lender");
        // Starting wallet inventory is a fixture; every mint, custody move and removal executes live code.
        deal(meme, borrower, 10_000e18);
        deal(stock, borrower, 100e18);
        _approvePosm(borrower, meme);
        _approvePosm(borrower, stock);
        // Resolve the chain's USDG from the configured test environment rather than silently use a fixture token.
        IERC20 usdg = IERC20(vm.envAddress("ROBINHOOD_USDG"));
        uint32[] memory terms = new uint32[](1);
        terms[0] = 7 days;
        CollateralRegistry registry = new CollateralRegistry(address(this), terms, 100);
        registry.setERC20Allowed(meme, true, Lane.MEME, 1, type(uint256).max, type(uint256).max);
        registry.setERC20Allowed(stock, true, Lane.STOCK, 1, type(uint256).max, type(uint256).max);
        registry.setPoolAllowed(idPool, true, 1);
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
            uint256 id = _mint(
                key,
                (-887_272 / key.tickSpacing) * key.tickSpacing,
                (887_272 / key.tickSpacing) * key.tickSpacing,
                LIQUIDITY,
                borrower,
                borrower
            );
            Collateral memory collateral = Collateral(Kind.UNIV4_POSITION, address(posm), id);
            if (i == 0 && hookHash != bytes32(0)) {
                vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, hook));
                vm.prank(borrower);
                vault.list(collateral, 100e6, 7 days, 0, 90e6);
            }
            if (hookHash != bytes32(0)) registry.setPoolRemovalHook(idPool, hook, hookHash);
            vm.prank(borrower);
            uint256 dealId = vault.list(collateral, 100e6, 7 days, 0, 90e6);
            assertEq(IERC721(address(posm)).ownerOf(id), address(vault));
            vm.prank(lender);
            vault.fund(dealId, lender);
            // Revoking admission affects future listings, never repayment or collateral withdrawal.
            registry.setPoolRemovalHook(idPool, address(0), bytes32(0));
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
            uint256 before0 = IERC20(meme).balanceOf(receiver);
            uint256 before1 = IERC20(stock).balanceOf(receiver);
            _decrease(key, id, LIQUIDITY, receiver, receiver);
            assertGt(IERC20(meme).balanceOf(receiver), before0);
            assertGt(IERC20(stock).balanceOf(receiver), before1);
            assertEq(posm.getPositionLiquidity(id), 0);
        }
    }

    function _token(address token, Lane lane) internal {
        _fork();
        IERC20 usdg = IERC20(vm.envAddress("ROBINHOOD_USDG"));
        uint32[] memory terms = new uint32[](1);
        terms[0] = 7 days;
        CollateralRegistry registry = new CollateralRegistry(address(this), terms, 100);
        registry.setERC20Allowed(token, true, lane, 1, 100e18, 200e18);
        DealVault vault = new DealVault(usdg, registry, address(this), address(0), 2 days);
        address borrower = makeAddr("token borrower");
        address lender = makeAddr("token lender");
        deal(token, borrower, 200e18);
        deal(address(usdg), borrower, 1000e6);
        deal(address(usdg), lender, 1000e6);
        vm.startPrank(borrower);
        IERC20(token).approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        usdg.approve(address(vault), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            registry.setERC20Allowed(token, true, lane, 1, 100e18, 200e18);
            vm.prank(borrower);
            uint256 id = vault.list(Collateral(Kind.ERC20, token, 100e18), 100e6, 7 days, 0, 90e6);
            assertEq(IERC20(token).balanceOf(address(vault)), 100e18);
            vm.prank(lender);
            vault.fund(id, lender);
            registry.setERC20Allowed(token, false, lane, 1, 100e18, 200e18);
            address receiver;
            if (i == 0) {
                vm.prank(borrower);
                vault.reclaim(id);
                receiver = borrower;
            } else {
                vm.warp(vault.claimableAt(id));
                vm.prank(lender);
                vault.claim(id);
                receiver = lender;
            }
            uint256 beforeBalance = IERC20(token).balanceOf(receiver);
            vm.prank(receiver);
            vault.withdrawERC20(token);
            assertEq(IERC20(token).balanceOf(receiver) - beforeBalance, 100e18);
            assertEq(IERC20(token).balanceOf(address(vault)), 0);
            assertEq(vault.openRaw(token), 0);
        }
    }
}
