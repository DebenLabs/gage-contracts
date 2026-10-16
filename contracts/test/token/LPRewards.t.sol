// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {TokenLayerFixture} from "./TokenLayerFixture.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {LPHook} from "../../src/token/LPHook.sol";
import {LPRewards} from "../../src/token/LPRewards.sol";
import {SeedTimelock} from "../../src/token/SeedTimelock.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";
import {ISeedTimelock} from "../../src/interfaces/token/ISeedTimelock.sol";
import {IDrip} from "../../src/interfaces/token/IDrip.sol";
import {PositionMath} from "../../src/libraries/PositionMath.sol";
import {MockRevertingLPRewards} from "../mocks/MockRevertingLPRewards.sol";

/// @notice The liquidity side of the token layer on a real v4 pool with LPHook: T5 and the LP score.
contract LPRewardsTest is TokenLayerFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ================================================================= hook: T5

    function test_hook_addressEncodesExactlyTheTwoFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
        assertTrue(Hooks.hasPermission(hook, Hooks.AFTER_ADD_LIQUIDITY_FLAG));
        assertTrue(Hooks.hasPermission(hook, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(hook, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(hook, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG));
        assertFalse(Hooks.hasPermission(hook, Hooks.BEFORE_SWAP_FLAG));
    }

    function test_hook_recordsAddAndRemoveByTokenId() public {
        uint256 next = posm.nextTokenId();
        vm.expectEmit(address(hook));
        emit LPHook.LiquidityChangeRecorded(next, true);
        uint256 id = _mintFullRange(pool, LIQ1, lp1, lp1);
        assertEq(id, next);
        assertGt(lpRewards.positionState(id).weight, 0, "checkpointed on add");
        assertEq(lpRewards.totalWeight(), lpRewards.positionState(id).weight);

        vm.expectEmit(address(hook));
        emit LPHook.LiquidityChangeRecorded(id, false);
        _decrease(pool, id, LIQ1, lp1, lp1);
        assertEq(lpRewards.positionState(id).weight, 0, "checkpointed on remove");
        assertEq(lpRewards.totalWeight(), 0);
    }

    function test_hook_neverRevertsWhenRewardsFail() public {
        MockRevertingLPRewards bad = new MockRevertingLPRewards();
        (, bytes32 salt) = HookMiner.find(
            address(this), HOOK_FLAGS, type(LPHook).creationCode, abi.encode(poolManager, address(posm), address(this))
        );
        // a second hook needs a different address: different constructor args are not available, so vary the salt
        // search start by mining from a fresh pool of salts
        LPHook hook2 = _deploySecondHook(salt);
        hook2.setLPRewards(ILPRewards(address(bad)));
        PoolKey memory pool2 = _initPoolAtPrice(address(gage), 1e18, address(sgage), 1000e18, address(hook2));

        for (uint8 mode = 0; mode < 3; ++mode) {
            bad.setMode(mode);
            uint256 next = posm.nextTokenId();
            vm.expectEmit(address(hook2));
            emit LPHook.RecordFailed(next, true);
            uint256 id = _mintFullRange(pool2, LIQ2, lp1, lp1);
            vm.expectEmit(address(hook2));
            emit LPHook.RecordFailed(id, false);
            _decrease(pool2, id, LIQ2, lp1, lp1);
        }
        // the mock's counter is rolled back by its own reverts; the RecordFailed events above are the proof
    }

    function test_hook_ignoresLiquidityNotFromPositionManager() public {
        uint256 weightBefore = lpRewards.totalWeight();
        _addRawLiquidity(pool, FULL_LOWER, FULL_UPPER, int256(uint256(LIQ2)), lp1);
        assertEq(lpRewards.totalWeight(), weightBefore, "raw liquidity earns nothing");
    }

    function test_hook_setLPRewardsOnceByDeployer() public {
        vm.expectRevert(LPHook.AlreadySet.selector);
        hook.setLPRewards(lpRewards);
        (, bytes32 salt) = HookMiner.find(
            address(this), HOOK_FLAGS, type(LPHook).creationCode, abi.encode(poolManager, address(posm), address(this))
        );
        LPHook hook2 = _deploySecondHook(salt);
        vm.expectRevert(LPHook.NotDeployer.selector);
        vm.prank(other);
        hook2.setLPRewards(lpRewards);
    }

    function test_onLiquidityChange_onlyHook() public {
        vm.expectRevert(ILPRewards.NotHook.selector);
        vm.prank(other);
        lpRewards.onLiquidityChange(1);
    }

    function _reserve1() internal view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(pool.toId());
        (, uint256 a1) = PositionMath.amountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(FULL_LOWER), TickMath.getSqrtPriceAtTick(FULL_UPPER), SEED_LIQ
        );
        return a1;
    }

    // ================================================================= weights

    function test_weight_isValueInGAGE() public {
        uint256 id = _mintFullRange(pool, LIQ1, lp1, lp1);
        (uint256 value, bool inRange) = lpRewards.valueInGAGE(id);
        assertTrue(inRange);
        assertEq(value, _expectedValue(id));
        assertEq(lpRewards.positionState(id).weight, value);
        // a full-range position holds equal value on both sides
        (uint160 sqrtP,,,) = poolManager.getSlot0(pool.toId());
        (uint256 a0, uint256 a1) = PositionMath.amountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(FULL_LOWER), TickMath.getSqrtPriceAtTick(FULL_UPPER), LIQ1
        );
        uint256 gageSide = Currency.unwrap(pool.currency0) == address(gage) ? a0 : a1;
        assertApproxEqRel(value, 2 * gageSide, 1e15, "two equal halves");
    }

    function test_weight_zeroOutOfRangeAndBackInRange() public {
        (, int24 tick,,) = poolManager.getSlot0(pool.toId());
        int24 lower = ((tick / TICK_SPACING) + 5) * TICK_SPACING;
        int24 upper = lower + 20 * TICK_SPACING;
        uint256 id = _mint(pool, lower, upper, LIQ2, lp1, lp1);
        assertEq(lpRewards.positionState(id).weight, 0, "out of range scores nothing");
        (uint256 value, bool inRange) = lpRewards.valueInGAGE(id);
        assertGt(value, 0);
        assertFalse(inRange);

        // The range is above the current tick, so the price (currency1 per currency0) must rise: buy currency0 by
        // paying currency1, in steps, until the tick sits inside the range.
        int24 tickAfter = tick;
        // each step pays 0.25% of the pool's currency1 reserves, about half a percent of price
        uint256 step = _reserve1() / 400;
        for (uint256 i = 0; i < 200 && tickAfter < lower; ++i) {
            _swap(pool, false, -int256(step), lp2);
            (, tickAfter,,) = poolManager.getSlot0(pool.toId());
        }
        assertTrue(tickAfter >= lower && tickAfter < upper, "swap moved the price into the range");
        lpRewards.checkpoint(id);
        assertGt(lpRewards.positionState(id).weight, 0, "in range after a poke");
    }

    function test_weight_seedIsZero() public view {
        assertEq(lpRewards.seedTokenId(), seedId);
        assertEq(lpRewards.positionState(seedId).weight, 0);
        assertEq(lpRewards.totalWeight(), 0);
    }

    function test_weight_wrongPoolIsZero() public {
        PoolKey memory stock = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        _approvePosm(lp1, address(nvda));
        _approvePosm(lp1, address(usdg));
        uint256 id = _mintFullRange(stock, 1e15, lp1, lp1);
        lpRewards.checkpoint(id);
        assertEq(lpRewards.positionState(id).weight, 0);
        (uint256 v, bool inRange) = lpRewards.valueInGAGE(id);
        assertEq(v, 0);
        assertFalse(inRange);
    }

    function test_setSeed_onceByDeployer() public {
        vm.expectRevert(ILPRewards.SeedAlreadySet.selector);
        lpRewards.setSeed(1);
        LPRewards fresh = new LPRewards(sgage, drip, emissions, posm, address(hook), pool, address(this));
        vm.expectRevert(ILPRewards.NotSeedTimelock.selector);
        vm.prank(other);
        fresh.setSeed(1);
    }

    // ================================================================= emissions by score

    function test_emissions_splitByWeightOverTime() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        uint256 b = _mintFullRange(pool, LIQ2, lp2, lp2);
        uint256 wa = lpRewards.positionState(a).weight;
        uint256 wb = lpRewards.positionState(b).weight;
        assertApproxEqRel(wa, 4 * wb, 1e12, "weights follow liquidity");

        vm.warp(block.timestamp + 1 days);
        (uint256 ea,) = lpRewards.earned(a);
        (uint256 eb,) = lpRewards.earned(b);
        uint256 total = _rate0() * 1 days;
        assertApproxEqRel(ea + eb, total, 1e9, "one day of the liquidity rate");
        assertApproxEqRel(ea, (total * wa) / (wa + wb), 1e9, "pro rata by weight");
        assertApproxEqRel(eb, (total * wb) / (wa + wb), 1e9);
    }

    function test_emissions_integrateAcrossEpochBoundary() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.warp(emissions.epochStart(1) - 1 days);
        lpRewards.checkpoint(a);
        (uint256 e0,) = lpRewards.earned(a);
        vm.warp(emissions.epochStart(1) + 1 days);
        (uint256 e1,) = lpRewards.earned(a);
        uint256 rate1 = emissions.liquidityBudget(1) / emissions.EPOCH();
        assertApproxEqRel(e1 - e0, _rate0() * 1 days + rate1 * 1 days, 1e9, "piecewise across the boundary");
        assertLt(rate1, _rate0(), "the second week pays less");
    }

    function test_emissions_stopAfterWeek52() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.warp(emissions.epochStart(52));
        lpRewards.checkpoint(a);
        (uint256 e52,) = lpRewards.earned(a);
        vm.warp(emissions.epochStart(52) + 30 days);
        (uint256 later,) = lpRewards.earned(a);
        assertEq(later, e52, "nothing after the schedule");
    }

    function test_emissions_nothingBeforeLaunchOrForLatecomers() public {
        // a fresh Emissions launching in 2 days, read by a second LPRewards on the same pool (views only)
        Emissions e2 = new Emissions(safe, address(this));
        LPRewards r2 = new LPRewards(sgage, drip, e2, posm, address(hook), pool, address(this));
        e2.wire(sgage, r2, dealRewardsStub);
        vm.prank(safe);
        e2.launch(uint40(block.timestamp + 2 days));
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        r2.checkpoint(a);
        vm.warp(block.timestamp + 1 days);
        (uint256 e,) = r2.earned(a);
        assertEq(e, 0, "nothing before launch");
        vm.warp(block.timestamp + 2 days);
        (e,) = r2.earned(a);
        assertApproxEqRel(e, (e2.liquidityBudget(0) / e2.EPOCH()) * 1 days, 1e9, "one day since launch");
    }

    function test_flashAddRemove_earnsNothing() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        _decrease(pool, a, LIQ1, lp1, lp1);
        (uint256 e,) = lpRewards.earned(a);
        assertEq(e, 0);
    }

    function test_undistributed_whileNothingIsInRange_isBurnable() public {
        vm.warp(block.timestamp + 1 days);
        lpRewards.checkpoint(seedId);
        assertApproxEqRel(lpRewards.undistributed(), _rate0() * 1 days, 1e9);
        uint256 supply = sgage.totalSupply();
        uint256 amount = lpRewards.undistributed();
        vm.prank(other);
        lpRewards.burnUndistributed();
        assertEq(sgage.totalSupply(), supply - amount);
        assertEq(lpRewards.undistributed(), 0);
        assertTrue(emissions.released(0), "burning released the epoch first");
        vm.expectRevert(LPRewards.NothingUndistributed.selector);
        lpRewards.burnUndistributed();
    }

    // ================================================================= lumps

    function test_lump_splitByCurrentWeightsOnly() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.startPrank(treasury);
        sgage.approve(address(lpRewards), 1000e18);
        lpRewards.notifyLump(1000e18);
        vm.stopPrank();
        uint256 b = _mintFullRange(pool, LIQ2, lp2, lp2); // arrives after the lump
        (, uint256 la) = lpRewards.earned(a);
        (, uint256 lb) = lpRewards.earned(b);
        assertApproxEqAbs(la, 1000e18, 1e6, "the only position present takes the whole lump");
        assertEq(lb, 0);
    }

    function test_lump_withNoWeightIsUndistributed() public {
        vm.startPrank(treasury);
        sgage.approve(address(lpRewards), 5e18);
        lpRewards.notifyLump(5e18);
        vm.stopPrank();
        assertGe(lpRewards.undistributed(), 5e18);
    }

    // ================================================================= collect

    function test_collect_dripsEmissionsAndPaysLumpsAtOnce() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.startPrank(treasury);
        sgage.approve(address(lpRewards), 1000e18);
        lpRewards.notifyLump(1000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        (uint256 em, uint256 lump) = lpRewards.earned(a);
        assertGt(em, 0);

        uint256 balBefore = sgage.balanceOf(lp1);
        vm.prank(lp1);
        (uint256 gotEm, uint256 gotLump) = lpRewards.collect(a);
        assertEq(gotEm, em);
        assertEq(gotLump, lump);
        assertEq(sgage.balanceOf(lp1), balBefore + lump, "lump paid at once");
        _assertDrip(lp1, lpRewards.dripIdOf(a, 1), em);
        assertTrue(emissions.released(0), "collect released the epoch");
        _assertNothingEarned(a);
    }

    function test_collect_secondCollectOpensSecondDrip() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(lp1);
        lpRewards.collect(a);
        vm.expectRevert(abi.encodeWithSelector(ILPRewards.NothingToCollect.selector, a));
        vm.prank(lp1);
        lpRewards.collect(a);

        vm.warp(block.timestamp + 1 days);
        vm.prank(lp1);
        (uint256 em3,) = lpRewards.collect(a);
        assertGt(em3, 0);
        _assertDrip(lp1, lpRewards.dripIdOf(a, 2), em3);
    }

    function _assertDrip(address who, bytes32 dripId, uint256 total) internal view {
        IDrip.DripAccount memory d = drip.getDrip(who, dripId);
        assertEq(d.total, total, "emissions into a drip");
        assertEq(d.length, 7 days);
        assertEq(d.start, block.timestamp);
    }

    function _assertNothingEarned(uint256 tokenId) internal view {
        (uint256 em, uint256 lump) = lpRewards.earned(tokenId);
        assertEq(em, 0);
        assertEq(lump, 0);
    }

    function test_collect_onlyOwnerAndFollowsTheNFT() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(ILPRewards.NotOwner.selector, a, lp2));
        vm.prank(lp2);
        lpRewards.collect(a);

        vm.prank(lp1);
        IERC721(address(posm)).transferFrom(lp1, lp2, a);
        (uint256 em,) = lpRewards.earned(a);
        vm.prank(lp2);
        (uint256 got,) = lpRewards.collect(a);
        assertEq(got, em, "unclaimed rewards travel with the NFT");
        assertEq(drip.getDrip(lp2, lpRewards.dripIdOf(a, 1)).total, em);
    }

    function test_checkpoint_anyoneAnyTime() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(other);
        lpRewards.checkpoint(a);
        assertEq(lpRewards.positionState(a).lastCheckpoint, block.timestamp);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = seedId;
        vm.prank(other);
        lpRewards.checkpointMany(ids);
    }

    function test_solvency_balanceCoversEarnedAndUndistributed() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        uint256 b = _mintFullRange(pool, LIQ2, lp2, lp2);
        vm.warp(block.timestamp + 3 days);
        vm.prank(lp1);
        lpRewards.collect(a);
        vm.warp(block.timestamp + 5 days);
        // the keeper (or any collect) releases every started epoch's tokens before they are needed
        emissions.release(1);
        (uint256 ea, uint256 la) = lpRewards.earned(a);
        (uint256 eb, uint256 lb) = lpRewards.earned(b);
        lpRewards.checkpoint(b);
        assertGe(sgage.balanceOf(address(lpRewards)), ea + la + eb + lb + lpRewards.undistributed());
    }

    // ================================================================= seed timelock

    function test_seedTimelock_lockCollectRelease() public {
        uint40 lockedAt = uint40(block.timestamp);
        uint40 releaseAt = lockedAt + 365 days;
        vm.prank(treasury);
        IERC721(address(posm)).approve(address(seedTimelock), seedId);
        vm.expectEmit(address(seedTimelock));
        emit ISeedTimelock.Locked(seedId, releaseAt);
        vm.prank(treasury);
        seedTimelock.lock(seedId);
        assertEq(seedTimelock.LOCK_LENGTH(), 365 days);
        assertEq(seedTimelock.releaseAt(), releaseAt);
        assertEq(IERC721(address(posm)).ownerOf(seedId), address(seedTimelock));
        assertEq(lpRewards.positionState(seedId).weight, 0, "still scores zero");

        // The old 180-day unlock must remain closed; fees are still collectible during the extended lock.
        vm.warp(lockedAt + 180 days);
        vm.expectRevert(abi.encodeWithSelector(ISeedTimelock.StillLocked.selector, releaseAt));
        seedTimelock.release();
        _swap(pool, true, -int256(uint256(100_000e18)), lp2);
        _swap(pool, false, -int256(uint256(100_000e18)), lp2);
        uint256 g0 = gage.balanceOf(treasury);
        uint256 s0 = sgage.balanceOf(treasury);
        uint256 callerGage = gage.balanceOf(other);
        uint256 callerSgage = sgage.balanceOf(other);
        vm.prank(other);
        (uint256 a0, uint256 a1) = seedTimelock.collectFees();
        assertGt(a0, 0, "currency0 fees collected");
        assertGt(a1, 0, "currency1 fees collected");
        bool gageIsZero = Currency.unwrap(pool.currency0) == address(gage);
        assertEq(gage.balanceOf(treasury), g0 + (gageIsZero ? a0 : a1));
        assertEq(sgage.balanceOf(treasury), s0 + (gageIsZero ? a1 : a0));
        assertEq(gage.balanceOf(other), callerGage, "caller cannot redirect GAGE fees");
        assertEq(sgage.balanceOf(other), callerSgage, "caller cannot redirect sGAGE fees");
        assertEq(posm.getPositionLiquidity(seedId), SEED_LIQ, "liquidity untouched");
        assertEq(IERC721(address(posm)).ownerOf(seedId), address(seedTimelock));
        assertEq(seedTimelock.releaseAt(), releaseAt, "collection does not change the lock");

        vm.warp(releaseAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ISeedTimelock.StillLocked.selector, releaseAt));
        seedTimelock.release();
        vm.warp(releaseAt);
        vm.prank(other);
        seedTimelock.release();
        assertEq(IERC721(address(posm)).ownerOf(seedId), treasury);
        assertEq(posm.getPositionLiquidity(seedId), SEED_LIQ);
    }

    function test_seedTimelock_rejectsOtherNFTsAndDoubleLock() public {
        uint256 a = _mintFullRange(pool, LIQ2, lp1, lp1);
        vm.expectRevert(abi.encodeWithSelector(SeedTimelock.UnexpectedERC721.selector, lp1, lp1, a));
        vm.prank(lp1);
        IERC721(address(posm)).safeTransferFrom(lp1, address(seedTimelock), a);

        vm.prank(treasury);
        IERC721(address(posm)).approve(address(seedTimelock), seedId);
        vm.prank(treasury);
        seedTimelock.lock(seedId);
        vm.expectRevert(ISeedTimelock.AlreadyLocked.selector);
        vm.prank(lp1);
        seedTimelock.lock(a);
    }

    function test_seedTimelock_revertsBeforeLock() public {
        vm.expectRevert(ISeedTimelock.NotLocked.selector);
        seedTimelock.collectFees();
        vm.expectRevert(ISeedTimelock.NotLocked.selector);
        seedTimelock.release();
    }
}
