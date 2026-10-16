// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {ICollateralRegistry, Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {FeeFloor} from "../../src/token/FeeFloor.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {ICreatorFeeSplitter} from "../../src/interfaces/token/ICreatorFeeSplitter.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";

/// @notice What the pinned mainnet fork suites of Project Intent share: the opt-in LOCAL fork of Robinhood Chain
/// mainnet (4663) at one pinned block, the live fee route read from launch/live/4663.json and read back, the live
/// zero-grace core and Morpho reserve, and one reconciled `DealFeeRouter.process` clip through the live pools.
/// Nothing is ever sent to the chain: no key signs a transaction, no broadcast happens, and every balance handed out
/// is a `deal` storage edit of the fork VM.
/// @dev Skipped unless INTENT_MAINNET_FORK_URL is set, so normal runs use no RPC. That variable is separate from
/// ROBINHOOD_RPC_URL on purpose: it is meant to hold the public node. INTENT_MAINNET_FORK_BLOCK pins the block; when
/// it is unset the suite pins a block just behind the head and records it, so the run can be repeated from Foundry's
/// RPC cache. The public node serves historical state for minutes only, so a pin must be recent when first used.
abstract contract IntentMainnetForkBase is Test {
    string internal constant MANIFEST = "../launch/live/4663.json";
    uint32 internal constant T21 = 21 days;
    uint8 internal constant UNITS = 4;
    /// @dev One cent of six-decimal USDG: the grain of the clip search.
    uint256 internal constant CENT = 1e4;
    /// @dev A lagging backend of a public node may not have the very last blocks yet.
    uint256 internal constant HEAD_MARGIN = 16;
    /// @dev The clip search stops adding stand-in USDG here even if a whole pot still fits the impact bound.
    uint256 internal constant MAX_POT = 1_000_000e6;

    string internal manifest;
    uint256 internal pinnedBlock;
    bytes32 internal pinnedHash;
    uint256 internal pinnedTime;

    DealFeeRouter internal processor;
    FeeFloor internal feeFloor;
    FeeSink internal feeSink;
    IERC20 internal usdg;
    IERC20 internal gage;
    address internal poolManager;
    IPositionManager internal posm;
    GageV2Vault internal core;
    address internal reserve;

    address internal anyone = makeAddr("s7-fork-arbitrary-caller");

    /// @dev Select the pinned fork and read the manifest. False when no URL is configured: the suite skips itself.
    function _fork() internal returns (bool forked) {
        string memory rpc = vm.envOr("INTENT_MAINNET_FORK_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        uint256 blk = vm.envOr("INTENT_MAINNET_FORK_BLOCK", uint256(0));
        if (blk == 0) {
            // Taken once: the head, less a margin, becomes the pin of everything that follows.
            vm.createSelectFork(rpc);
            blk = block.number - HEAD_MARGIN;
        }
        vm.createSelectFork(rpc, blk);
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet only");
        pinnedBlock = blk;
        pinnedTime = block.timestamp;
        // BLOCKHASH exposes the pinned header once the local block number has moved past it.
        vm.roll(blk + 1);
        pinnedHash = blockhash(blk);
        vm.roll(blk);

        manifest = vm.readFile(MANIFEST);
        assertEq(vm.parseJsonUint(manifest, ".chainId"), 4663, "manifest chain");
        processor = DealFeeRouter(payable(vm.parseJsonAddress(manifest, ".DealFeeRouter")));
        feeFloor = FeeFloor(payable(vm.parseJsonAddress(manifest, ".FeeFloor")));
        feeSink = FeeSink(vm.parseJsonAddress(manifest, ".FeeSink"));
        usdg = IERC20(vm.parseJsonAddress(manifest, ".USDG"));
        gage = IERC20(vm.parseJsonAddress(manifest, ".GAGE"));
        poolManager = vm.parseJsonAddress(manifest, ".PoolManager");
        posm = IPositionManager(vm.parseJsonAddress(manifest, ".PositionManager"));
        vm.label(address(processor), "DealFeeRouter");
        vm.label(address(feeFloor), "FeeFloor");
        vm.label(address(feeSink), "FeeSink");
        vm.label(address(usdg), "USDG");
        vm.label(address(gage), "GAGE");
        return true;
    }

    // ---------------------------------------------------------------- R5-A1: the live route at the pinned block

    struct Readback {
        uint256 threshold;
        uint256 available;
        uint256 batchRemaining;
        uint256 processed;
        uint256 gageAdded;
        uint256 floorCount;
        int24 bandLower;
        int24 bandUpper;
        bool graduated;
    }

    /// @dev Identities, routing, runtime presence and the active threshold. The manifest names the floor twice
    /// (`FeeFloor` and `CreatorFeeSplitter`); both must be the floor the router deposits into.
    function _readback() internal view returns (Readback memory r) {
        assertEq(block.chainid, 4663);
        assertEq(block.number, pinnedBlock, "pinned");
        assertGt(address(processor).code.length, 0, "router code");
        assertGt(address(feeFloor).code.length, 0, "floor code");
        assertGt(address(feeSink).code.length, 0, "sink code");
        assertGt(address(gage).code.length, 0, "GAGE code");
        assertGt(address(usdg).code.length, 0, "USDG code");
        assertEq(vm.parseJsonAddress(manifest, ".CreatorFeeSplitter"), address(feeFloor), "one floor, two names");
        assertEq(uint8(feeSink.route()), uint8(FeeSink.Route.BUYBACK), "FeeSink.route");
        assertEq(feeSink.buyback(), address(processor), "FeeSink.buyback");
        assertEq(address(feeSink.USDG()), address(usdg));
        assertEq(address(feeSink.vault()), vm.parseJsonAddress(manifest, ".DealVault"), "FeeSink.vault");
        assertEq(address(processor.FLOOR()), address(feeFloor), "router FLOOR");
        assertEq(address(processor.GAGE()), address(gage), "router GAGE");
        assertEq(address(processor.USDG()), address(usdg), "router USDG");
        assertEq(address(processor.FEE_SINK()), address(feeSink), "router FEE_SINK");
        assertEq(address(processor.POOL_MANAGER()), poolManager, "router POOL_MANAGER");
        assertEq(feeFloor.GAGE(), address(gage), "floor GAGE");
        assertEq(address(feeFloor.SGAGE()), vm.parseJsonAddress(manifest, ".sGAGE"), "floor sGAGE");
        assertEq(address(feeFloor.POSM()), address(posm), "floor POSM");
        assertEq(address(processor.PONS_CURVE()), vm.parseJsonAddress(manifest, ".pons.curve"), "router Pons curve");
        assertEq(processor.LAUNCH_POOL_FEE_PIPS(), vm.parseJsonUint(manifest, ".pons.hookFeePips"), "hook fee");
        assertEq(processor.MAX_IMPACT_BPS(), 100, "the router's own 1% bound");
        (PoolKey memory usdgEth, PoolKey memory gageEth) = processor.pools();
        assertEq(
            keccak256(abi.encode(usdgEth)), vm.parseJsonBytes32(manifest, ".pools.usdgEth.poolId"), "USDG/ETH pool"
        );
        assertEq(
            keccak256(abi.encode(gageEth)), vm.parseJsonBytes32(manifest, ".pools.gageEth.poolId"), "GAGE/ETH pool"
        );
        assertEq(Currency.unwrap(usdgEth.currency1), address(usdg));
        assertEq(Currency.unwrap(gageEth.currency1), address(gage));

        r.threshold = processor.threshold();
        assertGe(r.threshold, processor.MIN_THRESHOLD());
        assertLe(r.threshold, processor.MAX_THRESHOLD());
        r.available = processor.availableUSDG();
        assertEq(
            r.available,
            usdg.balanceOf(address(processor)) + usdg.balanceOf(address(feeSink))
                + feeSink.vault().balanceUSDG(address(feeSink)),
            "available = router + sink + vault credit"
        );
        r.batchRemaining = processor.batchRemaining();
        r.processed = processor.totalUSDGProcessed();
        r.gageAdded = processor.totalGAGEAdded();
        r.floorCount = feeFloor.floorCount();
        (r.bandLower, r.bandUpper) = feeFloor.bandNow();
        (bool ok, bytes memory data) =
            address(processor.PONS_CURVE()).staticcall(abi.encodeWithSignature("graduated()"));
        r.graduated = ok && abi.decode(data, (bool));
    }

    // ---------------------------------------------------------------- the live core and reserve

    /// @dev The last engine the manifest lists is the zero-grace one Earn v3 lends through; its reserve is Earn v3's.
    function _liveCoreAndReserve() internal {
        uint256 last;
        while (vm.keyExistsJson(manifest, string.concat(".nativeV2.engines[", vm.toString(last + 1), "]"))) ++last;
        string memory at = string.concat(".nativeV2.engines[", vm.toString(last), "]");
        core = GageV2Vault(vm.parseJsonAddress(manifest, string.concat(at, ".engine")));
        assertEq(vm.parseJsonUint(manifest, string.concat(at, ".grace")), 0, "manifest: zero grace");
        assertEq(core.GRACE(), 0, "Intent lends only through a zero-grace core");
        assertEq(address(core.USDG()), address(usdg));
        assertEq(address(core.REGISTRY()), vm.parseJsonAddress(manifest, string.concat(at, ".registry")));
        assertEq(vm.parseJsonAddress(manifest, ".earnV3.strategies[0].EarnCore"), address(core), "Earn v3's core");
        reserve = vm.parseJsonAddress(manifest, ".earnV3.strategies[0].EarnReserve");
        assertGt(reserve.code.length, 0, "reserve code");
    }

    /// @dev The first stock token of the manifest that the live registry of that core admits today.
    function _admittedStock() internal view returns (address token, ICollateralRegistry.ERC20Config memory config) {
        ICollateralRegistry registry = ICollateralRegistry(address(core.REGISTRY()));
        assertFalse(registry.newDealsPaused(), "the live core accepts new listings");
        assertTrue(registry.isTermAllowed(T21), "21 days is a live term");
        for (uint256 i; vm.keyExistsJson(manifest, string.concat(".nativeV2.assets[", vm.toString(i), "]")); ++i) {
            string memory at = string.concat(".nativeV2.assets[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(manifest, string.concat(at, ".lane")))) != keccak256("STOCK")) {
                continue;
            }
            token = vm.parseJsonAddress(manifest, string.concat(at, ".token"));
            config = registry.getERC20Config(token);
            if (config.allowed && config.lane == Lane.STOCK) return (token, config);
        }
        revert("no admitted stock token");
    }

    // ---------------------------------------------------------------- the route's balances

    struct Route {
        uint256 processorUSDG;
        uint256 sinkUSDG;
        uint256 vaultCredit;
        uint256 available;
        uint256 batchRemaining;
        uint256 processed;
        uint256 gageAdded;
        uint256 poolUSDG;
        uint256 floorGAGE;
        uint256 floorUSDG;
        uint256 floorCount;
        uint256 processorGAGE;
        uint256 processorETH;
        uint256 opsETH;
    }

    function _route() internal view returns (Route memory r) {
        r.processorUSDG = usdg.balanceOf(address(processor));
        r.sinkUSDG = usdg.balanceOf(address(feeSink));
        r.vaultCredit = feeSink.vault().balanceUSDG(address(feeSink));
        r.available = processor.availableUSDG();
        r.batchRemaining = processor.batchRemaining();
        r.processed = processor.totalUSDGProcessed();
        r.gageAdded = processor.totalGAGEAdded();
        r.poolUSDG = usdg.balanceOf(poolManager);
        r.floorGAGE = gage.balanceOf(address(feeFloor));
        r.floorUSDG = usdg.balanceOf(address(feeFloor));
        r.floorCount = feeFloor.floorCount();
        r.processorGAGE = gage.balanceOf(address(processor));
        r.processorETH = address(processor).balance;
        r.opsETH = feeFloor.OPS_WALLET().balance;
    }

    /// @dev Whether one clip would go through now, with nothing kept: the fork VM's state is restored either way.
    function _fits(uint256 clip) internal returns (bool ok, bytes memory reason) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(anyone);
        try processor.process(clip) {
            ok = true;
        } catch (bytes memory data) {
            reason = data;
        }
        vm.revertToState(snapshot);
    }

    struct Search {
        uint256 standIn;
        uint256 pot;
        uint256 largestPassing;
        uint256 smallestFailing;
        bytes failure;
        uint256 trials;
    }

    /// @dev Stand-in USDG is added to the processor until a whole-pot clip no longer fits its 1% impact bound, then
    /// the boundary is found to the cent. `lo` always passes and `hi` always fails, whatever lies between them.
    function _search(uint256 potNow, uint256 threshold) internal returns (Search memory s) {
        uint256 held = usdg.balanceOf(address(processor));
        uint256 pot = potNow < threshold ? threshold : potNow;
        uint256 lo;
        uint256 hi;
        while (true) {
            deal(address(usdg), address(processor), held + (pot - potNow));
            ++s.trials;
            (bool ok, bytes memory reason) = _fits(pot);
            if (!ok) {
                (hi, s.failure) = (pot, reason);
                break;
            }
            lo = pot;
            if (pot >= MAX_POT) break;
            pot *= 2;
        }
        s.pot = pot;
        s.standIn = pot - potNow;
        if (hi == 0) {
            // The pools took the largest pot tried: the only clip that fails is one above the pot.
            s.largestPassing = lo;
            return s;
        }
        if (lo == 0) {
            ++s.trials;
            (bool ok,) = _fits(CENT);
            require(ok, "no clip fits the impact bound at this block, not even one cent");
            lo = CENT;
        }
        while (hi - lo > CENT) {
            uint256 mid = (lo + hi) / 2 / CENT * CENT;
            if (mid <= lo) mid = lo + CENT;
            ++s.trials;
            (bool ok, bytes memory reason) = _fits(mid);
            if (ok) lo = mid;
            else (hi, s.failure) = (mid, reason);
        }
        (s.largestPassing, s.smallestFailing) = (lo, hi);
    }

    struct Clip {
        address caller;
        uint256 usdgIn;
        uint256 ethOut;
        uint256 gageBought;
        uint256 gageAdded;
        uint256 received;
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint256 gageIn;
        uint128 bandLiquidity;
        uint128 bandLiquidityBefore;
        bool newBand;
    }

    function _process(uint256 clip) internal returns (Clip memory c) {
        vm.recordLogs();
        vm.prank(anyone);
        uint256 added = processor.process(clip);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(processor) && topic == DealFeeRouter.FloorFunded.selector) {
                c.caller = address(uint160(uint256(logs[i].topics[1])));
                (c.usdgIn, c.ethOut, c.gageBought, c.gageAdded) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                ++seen;
            } else if (logs[i].emitter == address(feeFloor) && topic == FeeFloor.GAGEDeposited.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(processor), "deposited by the router");
                (c.received,) = abi.decode(logs[i].data, (uint256, uint256));
                ++seen;
            } else if (logs[i].emitter == address(feeFloor) && topic == ICreatorFeeSplitter.FloorAdded.selector) {
                c.tokenId = uint256(logs[i].topics[1]);
                (c.tickLower, c.tickUpper, c.gageIn, c.bandLiquidity) =
                    abi.decode(logs[i].data, (int24, int24, uint256, uint128));
                ++seen;
            }
        }
        assertEq(seen, 3, "FloorFunded, GAGEDeposited and FloorAdded");
        assertEq(c.gageAdded, added);
    }

    function _processReconciled(Route memory a, uint256 clip) internal returns (Clip memory c) {
        // A dry run names the band this clip lands in, so its liquidity can be read before the clip as well.
        uint256 snapshot = vm.snapshotState();
        uint256 tokenId = _process(clip).tokenId;
        vm.revertToState(snapshot);
        (,, uint128 liquidityBefore,) = feeFloor.bands(tokenId);

        c = _process(clip);
        Route memory b = _route();
        assertEq(c.tokenId, tokenId);
        assertEq(c.caller, anyone, "permissionless");
        assertEq(c.usdgIn, clip, "FloorFunded.usdgIn");
        assertEq(a.available - b.available, clip, "USDG out of the router's pot");
        assertEq(b.poolUSDG - a.poolUSDG, clip, "USDG into the pool manager, exactly");
        assertEq(b.sinkUSDG + b.vaultCredit, 0, "upstream fees were pulled in");
        assertEq(b.processorUSDG, b.available, "the rest of the batch is held by the router");
        assertEq(b.batchRemaining, a.available - clip, "and is still open");
        assertEq(b.processed - a.processed, clip, "totalUSDGProcessed");
        assertEq(b.gageAdded - a.gageAdded, c.gageAdded, "totalGAGEAdded");
        // The router hands over its whole GAGE balance; the floor adds what it holds, earlier remainders included,
        // and keeps what the band's liquidity rounding leaves.
        assertEq(c.received, c.gageBought + a.processorGAGE, "every GAGE bought reached the floor");
        assertEq(a.floorGAGE + c.received, b.floorGAGE + c.gageAdded, "received = added + what waits in the floor");
        assertEq(c.gageIn, c.gageAdded);
        assertGt(c.gageAdded, 0);
        assertEq(b.processorGAGE, 0);
        assertEq(b.processorETH, a.processorETH, "no ETH kept");
        assertEq(b.opsETH, a.opsETH, "no operations deduction on this path");
        assertEq(b.floorUSDG, a.floorUSDG, "the floor never touches USDG");
        assertEq(gage.allowance(address(processor), address(feeFloor)), 0);
        (,, uint128 liquidity,) = feeFloor.bands(c.tokenId);
        assertEq(liquidity, c.bandLiquidity, "the band's recorded liquidity");
        assertEq(posm.getPositionLiquidity(c.tokenId), liquidity, "is the position's real liquidity");
        c.newBand = b.floorCount == a.floorCount + 1;
        c.bandLiquidityBefore = liquidityBefore;
        assertGt(c.bandLiquidity, liquidityBefore, "the band grew");
    }

    // ---------------------------------------------------------------- evidence helpers

    function _n(string memory object, string memory key, uint256 value) internal returns (string memory) {
        return vm.serializeString(object, key, vm.toString(value));
    }

    /// @dev Revert data without its selector.
    function _tail(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    function _reasonName(bytes memory failure) internal pure returns (string memory) {
        if (failure.length == 0) return "none: the largest pot tried still fit";
        bytes4 selector = bytes4(failure);
        if (selector == IV4SwapperErrors.TooLittleOut.selector) return "TooLittleOut(got, minOut)";
        if (selector == DealFeeRouter.ClipTooLarge.selector) return "ClipTooLarge(requested, available)";
        return "other";
    }
}
