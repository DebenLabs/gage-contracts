// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealVaultV2} from "../../src/DealVaultV2.sol";
import {DealVault} from "../../src/DealVault.sol";
import {LPFeeForwarder} from "../../src/LPFeeForwarder.sol";
import {Kind, Collateral} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @notice Fork only: never broadcasts. Fresh LP minted into the real mainnet PONS/USDG pool on a local fork.
contract PonsLPV2ForkTest is V4Fixture {
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PROCESSOR = 0xEaE95cD11e1105BF1E82033c918ff17f931B0245;
    address constant V1 = 0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF;
    address borrower = makeAddr("v2-fork-borrower");
    address lender = makeAddr("v2-fork-lender");
    address trader = makeAddr("v2-fork-trader");
    bool enabled;
    DealVaultV2 v2;
    LPFeeForwarder forwarder;
    CollateralRegistry registry;
    PoolKey key;
    uint128 constant LIQ = 1e15;
    uint128 constant CAP = 100e6;
    uint128 constant PRICE = 90e6;
    uint256 originalCount;
    bytes32 originalCode;

    function setUp() public {
        string memory rpc = vm.envOr("PONS_LP_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("PONS_LP_FORK_BLOCK", uint256(57_185_944)));
        enabled = true;
        assertEq(block.chainid, 4663);
        originalCount = DealVault(V1).dealCount();
        originalCode = V1.codehash;
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        key = PoolKey(Currency.wrap(PONS), Currency.wrap(USDG), 3000, 60, IHooks(address(0)));
        assertEq(_poolId(key), 0x4be9657ec9002e528f4f17a5c43edc525a07f888f7b180c2afbf75e096c4f38a);
        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        registry = new CollateralRegistry(address(this), terms, 100);
        registry.setMemePairs(2);
        registry.setInRangeRequired(true);
        registry.setERC20Allowed(PONS, true, Lane.MEME, 1, type(uint128).max, type(uint128).max);
        registry.setPoolAllowed(_poolId(key), true, 1);
        forwarder = new LPFeeForwarder(IERC20(USDG), PROCESSOR);
        v2 = new DealVaultV2(IERC20(USDG), registry, address(forwarder), address(posm), 2 days);
        forwarder.bind(v2);
        deal(PONS, borrower, 100_000e18);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        deal(PONS, trader, 10_000e18);
        _approvePosm(borrower, PONS);
        _approvePosm(borrower, USDG);
        vm.startPrank(borrower);
        IERC721(address(posm)).setApprovalForAll(address(v2), true);
        IERC20(USDG).approve(address(v2), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(v2), type(uint256).max);
    }

    function _fundPosition() internal returns (uint256 id, uint256 nft) {
        nft = _mintFullRange(key, LIQ, borrower, borrower);
        vm.prank(borrower);
        id = v2.list(
            Collateral(Kind.UNIV4_POSITION, address(posm), nft), CAP, 7 days, uint40(block.timestamp + 1 days), PRICE
        );
        vm.prank(lender);
        v2.fund(id, lender);
        _swap(key, true, -int256(1000e18), trader);
        assertEq(posm.getPositionLiquidity(nft), LIQ);
    }

    function _oldUnchanged() internal view {
        assertEq(DealVault(V1).dealCount(), originalCount);
        assertEq(V1.codehash, originalCode);
    }

    function testFork_reclaim_collectFees_unwind_forwardFees() public {
        if (!enabled) {
            vm.skip(true);
            return;
        }
        (uint256 id, uint256 nft) = _fundPosition();
        vm.prank(borrower);
        v2.reclaim(id);
        vm.prank(borrower);
        v2.withdrawCollateral(id);
        uint256 beforeFees = IERC20(PONS).balanceOf(borrower);
        _decrease(key, nft, 0, borrower, borrower);
        assertGt(IERC20(PONS).balanceOf(borrower), beforeFees, "actual swap fees follow returned NFT");
        _decrease(key, nft, LIQ, borrower, borrower);
        assertEq(posm.getPositionLiquidity(nft), 0);
        uint256 before = IERC20(USDG).balanceOf(PROCESSOR);
        forwarder.forward();
        assertEq(IERC20(USDG).balanceOf(PROCESSOR) - before, PRICE / 100);
        vm.prank(lender);
        v2.withdrawUSDG();
        _oldUnchanged();
    }

    function testFork_default_delist_collectFees_unwind() public {
        if (!enabled) {
            vm.skip(true);
            return;
        }
        (uint256 id, uint256 nft) = _fundPosition();
        registry.pauseNewDeals(true);
        registry.setPoolAllowed(_poolId(key), false, 1);
        vm.warp(v2.claimableAt(id));
        vm.prank(lender);
        v2.claim(id);
        vm.prank(lender);
        v2.withdrawCollateral(id);
        uint256 before = IERC20(PONS).balanceOf(lender);
        _decrease(key, nft, LIQ, lender, lender);
        assertGt(IERC20(PONS).balanceOf(lender), before);
        assertEq(posm.getPositionLiquidity(nft), 0);
        _oldUnchanged();
    }
}
