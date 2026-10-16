// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {TokenLayerFixture} from "./TokenLayerFixture.sol";
import {Buyback} from "../../src/token/Buyback.sol";
import {CreatorFeeSplitter} from "../../src/token/CreatorFeeSplitter.sol";
import {ReinvestRouter} from "../../src/token/ReinvestRouter.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";
import {IBuyback} from "../../src/interfaces/token/IBuyback.sol";
import {ICreatorFeeSplitter} from "../../src/interfaces/token/ICreatorFeeSplitter.sol";
import {IReinvestRouter} from "../../src/interfaces/token/IReinvestRouter.sol";
import {IsGAGE} from "../../src/interfaces/token/IsGAGE.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";
import {PositionMath} from "../../src/libraries/PositionMath.sol";

/// @notice Buyback (T6), CreatorFeeSplitter (T7) and ReinvestRouter (T8) on real pools: ETH/USDG, ETH/GAGE (the
///         launch pool stand-in) and GAGE/sGAGE with LPHook.
contract RoutersTest is TokenLayerFixture {
    receive() external payable {}

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey internal usdgEth;
    PoolKey internal gageEth;
    Buyback internal buyback;
    CreatorFeeSplitter internal splitter;
    ReinvestRouter internal reinvest;
    address internal ops = makeAddr("ops");
    uint256 internal constant THRESHOLD = 100e6;

    function setUp() public virtual override {
        super.setUp();
        vm.deal(treasury, 10_000 ether);
        vm.deal(lp1, 1000 ether);
        vm.deal(lp2, 1000 ether);
        usdg.mint(treasury, 100_000_000e6);

        // 1 ETH = 3,000 USDG; 1 ETH = 1,000 GAGE (so 1 GAGE = 3 USDG); 1 GAGE = 1,000 sGAGE
        usdgEth = _initPoolAtPrice(address(0), 1e18, address(usdg), 3000e6, address(0));
        gageEth = _initPoolAtPrice(address(0), 1e18, address(gage), 1000e18, address(0));
        _addRawLiquidityNative(usdgEth, FULL_LOWER, FULL_UPPER, 1e17, treasury, 2000 ether);
        _addRawLiquidityNative(gageEth, FULL_LOWER, FULL_UPPER, 1e22, treasury, 400 ether);

        buyback = new Buyback(
            Buyback.Params({
                poolManager: poolManager,
                usdg: usdg,
                sgage: IsGAGE(address(sgage)),
                gage: address(gage),
                usdgEth: usdgEth,
                gageEth: gageEth,
                gageSgage: pool,
                launchPoolFeePips: 3000,
                threshold: THRESHOLD,
                bountyBps: 50,
                initialOwner: safe
            })
        );
        splitter = new CreatorFeeSplitter(
            CreatorFeeSplitter.Params({
                poolManager: poolManager,
                positionManager: posm,
                permit2: permit2,
                opsWallet: ops,
                sgage: sgage,
                gage: address(gage),
                gageEth: gageEth,
                gageSgage: pool,
                launchPoolFeePips: 3000,
                ponsClaimTarget: address(0),
                ponsClaimCalldata: "",
                threshold: 0.01 ether,
                bountyBps: 50,
                initialOwner: safe
            })
        );
        lpRewards.setFloor(address(splitter));
        reinvest = new ReinvestRouter(
            ReinvestRouter.Params({
                poolManager: poolManager,
                posm: posm,
                permit2: IAllowanceTransfer(PERMIT2),
                sgage: sgage,
                gage: gage,
                usdg: usdg,
                gageSgage: pool,
                gageEth: gageEth,
                usdgEth: usdgEth
            })
        );
        vm.prank(lp1);
        sgage.approve(address(reinvest), type(uint256).max);
        vm.prank(lp1);
        usdg.approve(address(reinvest), type(uint256).max);
        usdg.mint(lp1, 1_000_000e6);
        vm.label(address(buyback), "Buyback");
        vm.label(address(splitter), "CreatorFeeSplitter");
        vm.label(address(reinvest), "ReinvestRouter");
    }

    function _range() internal view returns (IReinvestRouter.Range memory r) {
        (, int24 tick,,) = poolManager.getSlot0(pool.toId());
        int24 mid = (tick / TICK_SPACING) * TICK_SPACING;
        r = IReinvestRouter.Range({tickLower: mid - 50 * TICK_SPACING, tickUpper: mid + 50 * TICK_SPACING});
    }

    // ================================================================= Buyback: T6

    function test_buyback_buysAndBurnsWithinTheBound() public {
        usdg.mint(address(buyback), 1000e6);
        uint256 supply = sgage.totalSupply();
        uint256 callerUSDG = usdg.balanceOf(other);
        vm.prank(other);
        uint256 burned = buyback.buyback(500e6);
        assertGt(burned, 0);
        assertEq(sgage.totalSupply(), supply - burned, "burned, not kept");
        assertEq(buyback.totalBurned(), burned);
        assertEq(usdg.balanceOf(other), callerUSDG + (500e6 * 50) / 10_000, "bounty paid");
        assertEq(usdg.balanceOf(address(buyback)), 500e6, "the rest stays for the next clip");
        assertEq(gage.balanceOf(address(buyback)), 0, "holds no GAGE");
        assertEq(sgage.balanceOf(address(buyback)), 0, "holds no sGAGE");
        assertEq(address(buyback).balance, 0, "holds no ETH");
        // 497.5 USDG ~ 0.1658 ETH ~ 165.8 GAGE ~ 165,800 sGAGE at spot, less 0.3%, 0.3% and 3% pool fees
        uint256 expected = (((165_800e18 * 997) / 1000) * 997 / 1000) * 97 / 100;
        assertApproxEqRel(burned, expected, 1e16, "three legs at spot within fees and impact");
    }

    function test_buyback_thresholdAndClipBounds() public {
        usdg.mint(address(buyback), 99e6);
        vm.expectRevert(abi.encodeWithSelector(IBuyback.BelowThreshold.selector, 99e6, THRESHOLD));
        buyback.buyback(1e6);
        usdg.mint(address(buyback), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IBuyback.ClipTooLarge.selector, 101e6, 100e6));
        buyback.buyback(101e6);
        vm.expectRevert(abi.encodeWithSelector(IBuyback.ClipTooLarge.selector, 0, 100e6));
        buyback.buyback(0);
    }

    function test_buyback_impactBoundRejectsOversizedClips() public {
        // the ETH/USDG pool holds ~200 ETH each side; a 300k USDG clip moves the price far more than 1%
        usdg.mint(address(buyback), 300_000e6);
        vm.expectPartialRevert(IV4SwapperErrors.TooLittleOut.selector);
        buyback.buyback(300_000e6);
    }

    function test_buyback_ownerSettersBounded() public {
        vm.startPrank(safe);
        buyback.setThreshold(5e6);
        assertEq(buyback.threshold(), 5e6);
        buyback.setBounty(100);
        vm.expectRevert(IBuyback.BountyOutOfBounds.selector);
        buyback.setBounty(101);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        buyback.setThreshold(1);
    }

    function test_buyback_rejectsWrongPools() public {
        Buyback.Params memory p = Buyback.Params({
            poolManager: poolManager,
            usdg: usdg,
            sgage: IsGAGE(address(sgage)),
            gage: address(gage),
            usdgEth: gageEth, // wrong
            gageEth: gageEth,
            gageSgage: pool,
            launchPoolFeePips: 3000,
            threshold: THRESHOLD,
            bountyBps: 50,
            initialOwner: safe
        });
        vm.expectRevert(Buyback.PoolMismatch.selector);
        new Buyback(p);
    }

    // ================================================================= CreatorFeeSplitter: T7

    function test_split_halfToOpsHalfToFloor() public {
        _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.deal(address(splitter), 0.2 ether);
        uint256 opsBefore = ops.balance;
        uint256 callerBefore = other.balance;
        vm.prank(other);
        uint256 gageToFloor = splitter.split();
        uint256 bounty = (0.1 ether * 50) / 10_000;
        assertEq(ops.balance, opsBefore + 0.1 ether - bounty, "ops half less the bounty");
        assertEq(other.balance, callerBefore + bounty, "bounty from the ops half");
        // 0.1 ETH ~ 100 GAGE at spot, less the 0.3% launch-pool fee
        assertApproxEqRel(gageToFloor, (100e18 * 997) / 1000, 2e16);
        assertEq(address(splitter).balance, 0, "holds no ETH");
        assertLt(gage.balanceOf(address(splitter)), 1e15, "at most dust of GAGE left");
        assertEq(sgage.balanceOf(address(splitter)), 0);
        (uint256 gageIn, uint256 sgageIn) = splitter.floorBacking();
        assertApproxEqRel(gageIn, gageToFloor, 1e15, "the band holds the GAGE");
        assertEq(sgageIn, 0, "and no sGAGE");
    }

    function test_split_bandSitsOnTheGageSideAndCarriesNoWeight() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        uint256 weightBefore = lpRewards.totalWeight();
        vm.deal(address(splitter), 0.2 ether);
        int24 tick = _currentTick(pool);
        splitter.split();
        assertEq(splitter.floorCount(), 1);
        uint256 id = splitter.floorTokenIds(0);
        assertEq(IERC721(address(posm)).ownerOf(id), address(splitter), "the band belongs to the splitter");
        (int24 lower, int24 upper, uint128 liquidity, bool swept) = splitter.bands(id);
        assertGt(liquidity, 0);
        assertFalse(swept);
        assertEq(upper - lower, splitter.BAND_TICKS());
        if (splitter.GAGE_IS_CURRENCY0()) assertGt(lower, tick, "GAGE-only band sits above the tick");
        else assertLe(upper, tick, "GAGE-only band sits at or below the tick");
        assertEq(lpRewards.positionState(id).weight, 0, "floor carries no weight");
        assertEq(lpRewards.totalWeight(), weightBefore, "LP weight untouched");
        assertGt(lpRewards.positionState(a).weight, 0);
    }

    function test_split_sameBandTopsUp_ratchetsWhenPriceMoves() public {
        _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.deal(address(splitter), 0.1 ether);
        splitter.split();
        uint256 id = splitter.floorTokenIds(0);
        (,, uint128 liq1,) = splitter.bands(id);
        vm.deal(address(splitter), 0.1 ether);
        splitter.split();
        assertEq(splitter.floorCount(), 1, "same price, same band");
        (,, uint128 liq2,) = splitter.bands(id);
        assertGt(liq2, liq1, "topped up");

        // sGAGE gets dearer in GAGE: buy sGAGE with GAGE until the tick leaves the band's neighbourhood
        bool sgageIsZero = !splitter.GAGE_IS_CURRENCY0();
        gage.mint(other, 1_000_000e18);
        (int24 lowerBefore,) = splitter.bandNow();
        for (uint256 i = 0; i < 40; ++i) {
            _swap(pool, !sgageIsZero, -int256(uint256(2000e18)), other);
            (int24 lowerNow,) = splitter.bandNow();
            if (lowerNow != lowerBefore) break;
        }
        (int24 lowerAfter,) = splitter.bandNow();
        assertTrue(lowerAfter != lowerBefore, "price moved to a new band");
        vm.deal(address(splitter), 0.1 ether);
        splitter.split();
        assertEq(splitter.floorCount(), 2, "a new band above the old one");
        (,, uint128 liqOld,) = splitter.bands(id);
        assertEq(liqOld, liq2, "the old band is untouched");
    }

    function test_sweep_burnsWhatTheFloorBought() public {
        _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.deal(address(splitter), 0.2 ether);
        splitter.split();
        uint256 id = splitter.floorTokenIds(0);
        (int24 lower, int24 upper,,) = splitter.bands(id);
        vm.expectRevert(abi.encodeWithSelector(ICreatorFeeSplitter.FloorStillHolding.selector, id, _currentTick(pool)));
        splitter.sweep(id);

        // sell sGAGE into the pool until the market falls through the band
        bool sgageIsZero = !splitter.GAGE_IS_CURRENCY0();
        uint256 supplyBefore = sgage.totalSupply();
        // the seed and lp1 are deep: it takes millions of sGAGE to move the price five percent
        for (uint256 i = 0; i < 80; ++i) {
            _swap(pool, sgageIsZero, -int256(uint256(500_000e18)), treasury);
            int24 t = _currentTick(pool);
            if (splitter.GAGE_IS_CURRENCY0() ? t >= upper : t < lower) break;
        }
        int24 tick = _currentTick(pool);
        assertTrue(splitter.GAGE_IS_CURRENCY0() ? tick >= upper : tick < lower, "market is through the band");
        (uint256 gageLeft, uint256 sgageHeld) = splitter.floorBacking();
        assertEq(gageLeft, 0, "the band spent its GAGE");
        assertGt(sgageHeld, 0, "and holds the sGAGE it bought");

        uint256 burned = splitter.sweep(id);
        // what the band bought plus the sGAGE swap fees it earned on the way through (the pool charges 3%)
        assertGe(burned, sgageHeld, "everything the band bought is burned");
        assertLe(burned, (sgageHeld * 105) / 100, "plus at most the fees earned");
        assertEq(sgage.totalSupply(), supplyBefore - burned, "supply fell by the burn");
        assertEq(sgage.balanceOf(address(splitter)), 0);
        (,, uint128 liq, bool swept) = splitter.bands(id);
        assertTrue(swept);
        assertEq(liq, 0);
        vm.expectRevert(abi.encodeWithSelector(ICreatorFeeSplitter.AlreadySwept.selector, id));
        splitter.sweep(id);
        vm.expectRevert(abi.encodeWithSelector(ICreatorFeeSplitter.NotAFloorBand.selector, 999));
        splitter.sweep(999);
        // a later split at the recovered price opens a fresh band even if it lands on the same ticks
        vm.deal(address(splitter), 0.1 ether);
        splitter.split();
        assertEq(splitter.floorCount(), 2);
    }

    function test_collect_burnsFeeSGAGEKeepsFeeGAGE() public {
        _mintFullRange(pool, LIQ1, lp1, lp1);
        vm.deal(address(splitter), 0.2 ether);
        splitter.split();
        uint256 id = splitter.floorTokenIds(0);
        // trade through the band and back so it earns fees on both sides
        bool sgageIsZero = !splitter.GAGE_IS_CURRENCY0();
        gage.mint(other, 1_000_000e18);
        for (uint256 i = 0; i < 20; ++i) {
            _swap(pool, sgageIsZero, -int256(uint256(20_000e18)), treasury);
        }
        for (uint256 i = 0; i < 20; ++i) {
            _swap(pool, !sgageIsZero, -int256(uint256(20e18)), other);
        }
        uint256 supplyBefore = sgage.totalSupply();
        (uint256 sgageBurned, uint256 gageKept) = splitter.collect(id);
        assertEq(sgage.totalSupply(), supplyBefore - sgageBurned);
        assertEq(gage.balanceOf(address(splitter)), gageKept, "fee GAGE waits for the next band");
        assertGt(sgageBurned + gageKept, 0, "some fee was earned");
    }

    function test_floor_setOnceByTheDeployer() public {
        vm.expectRevert(ILPRewards.FloorAlreadySet.selector);
        lpRewards.setFloor(address(1));
        vm.prank(other);
        vm.expectRevert(ILPRewards.NotSeedTimelock.selector);
        lpRewards.setFloor(address(1));
        assertEq(lpRewards.floor(), address(splitter));
    }

    function test_split_belowThresholdReverts() public {
        vm.deal(address(splitter), 0.009 ether);
        vm.expectRevert(abi.encodeWithSelector(ICreatorFeeSplitter.BelowThreshold.selector, 0.009 ether, 0.01 ether));
        splitter.split();
    }

    function test_claim_isNoOpWithoutAPonsTarget() public {
        assertEq(splitter.claim(), 0);
    }

    function test_split_receivesETH() public {
        (bool ok,) = address(splitter).call{value: 0.2 ether}("");
        assertTrue(ok);
        assertEq(address(splitter).balance, 0.2 ether);
    }

    // ================================================================= ReinvestRouter: T8

    function test_reinvestMatch_withETH_mintsToCallerAndRefunds() public {
        uint256 amount = 10_000e18; // sGAGE ≈ 10 GAGE of value
        IReinvestRouter.Range memory r = _range();
        uint256 next = posm.nextTokenId();
        uint256 ethBefore = lp1.balance;
        vm.prank(lp1);
        (uint256 tokenId, uint128 liquidity) = reinvest.reinvestMatch{value: 0.05 ether}(
            amount, r, IReinvestRouter.PayAsset.ETH, 0.05 ether, 1, block.timestamp + 1
        );
        assertEq(tokenId, next);
        assertGt(liquidity, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), lp1, "position is the caller's");
        assertGt(lpRewards.positionState(tokenId).weight, 0, "the hook recorded it");
        assertLt(ethBefore - lp1.balance, 0.02 ether, "about 10 GAGE = 0.01 ETH spent, the rest refunded");
        _assertRouterEmpty();
        assertLt(sgage.balanceOf(address(reinvest)), 1);
    }

    function test_reinvestMatch_withUSDG() public {
        uint256 amount = 10_000e18;
        IReinvestRouter.Range memory r = _range();
        uint256 usdgBefore = usdg.balanceOf(lp1);
        vm.prank(lp1);
        (uint256 tokenId, uint128 liquidity) =
            reinvest.reinvestMatch(amount, r, IReinvestRouter.PayAsset.USDG, 100e6, 1, block.timestamp + 1);
        assertGt(liquidity, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), lp1);
        uint256 spent = usdgBefore - usdg.balanceOf(lp1);
        assertGt(spent, 25e6);
        assertLt(spent, 40e6, "about 10 GAGE at 3 USDG each");
        _assertRouterEmpty();
    }

    function test_reinvestMatch_slippageAndDeadline() public {
        IReinvestRouter.Range memory r = _range();
        vm.expectRevert(ReinvestRouter.Expired.selector);
        vm.prank(lp1);
        reinvest.reinvestMatch{value: 0.05 ether}(
            1000e18, r, IReinvestRouter.PayAsset.ETH, 0.05 ether, 1, block.timestamp - 1
        );
        vm.expectPartialRevert(IV4SwapperErrors.TooMuchIn.selector);
        vm.prank(lp1);
        reinvest.reinvestMatch{value: 0.0001 ether}(
            10_000e18, r, IReinvestRouter.PayAsset.ETH, 0.0001 ether, 1, block.timestamp + 1
        );
        vm.expectPartialRevert(IReinvestRouter.SlippageExceeded.selector);
        vm.prank(lp1);
        reinvest.reinvestMatch{value: 0.05 ether}(
            10_000e18, r, IReinvestRouter.PayAsset.ETH, 0.05 ether, type(uint128).max, block.timestamp + 1
        );
    }

    function test_reinvestMatch_rangeWithoutSGAGESideReverts() public {
        (, int24 tick,,) = poolManager.getSlot0(pool.toId());
        int24 mid = (tick / TICK_SPACING) * TICK_SPACING;
        // a range entirely on the GAGE-only side of the price
        bool sgageIs0 = Currency.unwrap(pool.currency0) == address(sgage);
        IReinvestRouter.Range memory r = sgageIs0
            ? IReinvestRouter.Range({tickLower: mid - 200 * TICK_SPACING, tickUpper: mid - 100 * TICK_SPACING})
            : IReinvestRouter.Range({tickLower: mid + 100 * TICK_SPACING, tickUpper: mid + 200 * TICK_SPACING});
        vm.expectRevert(ReinvestRouter.RangeHoldsNoSGAGE.selector);
        vm.prank(lp1);
        reinvest.reinvestMatch{value: 0.05 ether}(
            1000e18, r, IReinvestRouter.PayAsset.ETH, 0.05 ether, 1, block.timestamp + 1
        );
    }

    function test_reinvestZap_sellsPartAndMints() public {
        uint256 amount = 10_000e18;
        IReinvestRouter.Range memory r = _range();
        uint256 next = posm.nextTokenId();
        vm.prank(lp1);
        (uint256 tokenId, uint128 liquidity) =
            reinvest.reinvestZap(amount, amount / 2, r, amount / 2, 1, block.timestamp + 1);
        assertEq(tokenId, next);
        assertGt(liquidity, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), lp1);
        _assertRouterEmpty();
    }

    function test_reinvestZap_bounds() public {
        IReinvestRouter.Range memory r = _range();
        vm.expectRevert(ReinvestRouter.SellExceedsAmount.selector);
        vm.prank(lp1);
        reinvest.reinvestZap(1000e18, 2000e18, r, 2000e18, 1, block.timestamp + 1);
        vm.expectPartialRevert(IReinvestRouter.SlippageExceeded.selector);
        vm.prank(lp1);
        reinvest.reinvestZap(1000e18, 600e18, r, 500e18, 1, block.timestamp + 1);
        vm.expectRevert(IReinvestRouter.ZeroAmount.selector);
        vm.prank(lp1);
        reinvest.reinvestZap(0, 0, r, 0, 1, block.timestamp + 1);
    }

    function test_increaseMatch_addsToOwnPositionOnly() public {
        IReinvestRouter.Range memory r = _range();
        vm.prank(lp1);
        (uint256 tokenId, uint128 l0) = reinvest.reinvestMatch{value: 0.05 ether}(
            10_000e18, r, IReinvestRouter.PayAsset.ETH, 0.05 ether, 1, block.timestamp + 1
        );
        vm.prank(lp1);
        IERC721(address(posm)).approve(address(reinvest), tokenId);
        vm.prank(lp1);
        uint128 added = reinvest.increaseMatch{value: 0.05 ether}(
            tokenId, 10_000e18, IReinvestRouter.PayAsset.ETH, 0.05 ether, 1, block.timestamp + 1
        );
        assertGt(added, 0);
        assertEq(posm.getPositionLiquidity(tokenId), l0 + added, "same position, more liquidity");
        assertGt(lpRewards.positionState(tokenId).weight, 0);
        _assertRouterEmpty();

        vm.expectRevert(abi.encodeWithSelector(IReinvestRouter.NotPositionOwner.selector, tokenId));
        vm.prank(lp2);
        reinvest.increaseMatch{value: 0.05 ether}(
            tokenId, 1000e18, IReinvestRouter.PayAsset.ETH, 0.05 ether, 1, block.timestamp + 1
        );
    }

    function test_increaseZap_addsToOwnPosition() public {
        IReinvestRouter.Range memory r = _range();
        vm.prank(lp1);
        (uint256 tokenId, uint128 l0) = reinvest.reinvestZap(10_000e18, 5000e18, r, 5000e18, 1, block.timestamp + 1);
        vm.prank(lp1);
        IERC721(address(posm)).approve(address(reinvest), tokenId);
        vm.prank(lp1);
        uint128 added = reinvest.increaseZap(tokenId, 10_000e18, 5000e18, 5000e18, 1, block.timestamp + 1);
        assertGt(added, 0);
        assertEq(posm.getPositionLiquidity(tokenId), l0 + added);
        _assertRouterEmpty();
    }

    function test_reinvest_rejectsPositionsInOtherPools() public {
        PoolKey memory stock = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        _approvePosm(lp1, address(nvda));
        _approvePosm(lp1, address(usdg));
        uint256 id = _mintFullRange(stock, 1e15, lp1, lp1);
        vm.expectRevert(ReinvestRouter.PoolMismatch.selector);
        vm.prank(lp1);
        reinvest.increaseMatch{value: 0.01 ether}(
            id, 1000e18, IReinvestRouter.PayAsset.ETH, 0.01 ether, 1, block.timestamp + 1
        );
    }

    function _assertRouterEmpty() internal view {
        assertEq(address(reinvest).balance, 0, "router holds no ETH");
        assertEq(gage.balanceOf(address(reinvest)), 0, "router holds no GAGE");
        assertEq(sgage.balanceOf(address(reinvest)), 0, "router holds no sGAGE");
        assertEq(usdg.balanceOf(address(reinvest)), 0, "router holds no USDG");
    }
}
