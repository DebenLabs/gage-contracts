// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TokenLayerFixture} from "./TokenLayerFixture.sol";
import {LPStreamer} from "../../src/token/LPStreamer.sol";
import {ILPStreamer} from "../../src/interfaces/token/ILPStreamer.sol";
import {IDrip} from "../../src/interfaces/token/IDrip.sol";

/// @notice The streamer on a real v4 pool next to the (unfixed) LPRewards it mirrors: pots, the accrual mirror,
///         the bounty report's one-block position, liquidity changes, the collect order, and solvency (D64).
contract LPStreamerTest is TokenLayerFixture {
    LPStreamer internal streamer;

    function setUp() public override {
        super.setUp();
        streamer = new LPStreamer(sgage, lpRewards);
        vm.prank(treasury);
        sgage.approve(address(streamer), type(uint256).max);
    }

    // ================================================================= pots

    function test_pot_fixedAtEpochStartFromTheEpochBefore() public {
        _deposit(700e18);
        assertEq(streamer.pending(), 700e18);
        assertEq(streamer.pot(1), 0);
        vm.warp(_startOf(1));
        _deposit(300e18); // rolls first: 700 becomes pot 1, then 300 waits for pot 2
        assertEq(streamer.pot(1), 700e18);
        assertEq(streamer.rate(1), (700e18 * 1e27) / _budget(1));
        assertEq(streamer.pending(), 300e18);
        vm.warp(_startOf(3)); // two boundaries at once: the pending goes to epoch 2, epoch 3 gets nothing
        streamer.checkpoint(seedId);
        assertEq(streamer.pot(2), 300e18);
        assertEq(streamer.pot(3), 0);
        assertEq(streamer.assignedThrough(), 3);
    }

    function test_deposit_refusedForTheLastEpoch() public {
        uint256 at = _startOf(51);
        vm.warp(at);
        vm.expectRevert(ILPStreamer.ScheduleOver.selector);
        vm.prank(treasury);
        streamer.deposit(1);
    }

    // ================================================================= the mirror

    function test_pays_byAccrualShareOverTheEpoch() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1); // 4
        uint256 b = _mintFullRange(pool, LIQ2, lp2, lp2); // 1
        _deposit(1000e18);
        vm.warp(_startOf(1));
        uint256[] memory ids = _two(a, b);
        streamer.checkpointMany(ids);
        vm.warp(_startOf(2) - 1);
        streamer.checkpointMany(ids);
        assertApproxEqRel(streamer.earned(a), 800e18, 1e14);
        assertApproxEqRel(streamer.earned(b), 200e18, 1e14);
        assertLe(streamer.earned(a) + streamer.earned(b), 1000e18, "never more than the pot");
    }

    function test_view_isRightBeforeAnyoneRolls() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        _deposit(1000e18); // pot 1
        vm.warp(_startOf(1));
        streamer.checkpoint(a);
        _deposit(500e18); // waits for pot 2
        vm.warp(_startOf(2) + 3 days + 12 hours); // nobody has rolled epoch 2 yet
        uint256 shown = streamer.earned(a);
        uint256 expected = ((_budget(1) + _budget(2) / 2) * 500e18) / _budget(2);
        assertApproxEqRel(shown, expected, 1e14, "the view already prices epoch 2 from the pending deposit");
        streamer.checkpoint(a); // rolls
        assertEq(streamer.earned(a), shown);
    }

    /// @dev The keeper's rule: checkpoint every position just before each boundary, so an interval never spans
    ///      into an epoch whose pot is smaller, or empty, with a whole epoch's accrual in it.
    function test_keeper_checkpointBeforeTheBoundaryKeepsTheEpochWhole() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        uint256 b = _mintFullRange(pool, LIQ1, lp2, lp2);
        _deposit(1000e18); // pot 1 only; epoch 2 gets nothing
        vm.warp(_startOf(1));
        streamer.checkpointMany(_two(a, b));
        vm.warp(_startOf(2) - 10 minutes);
        streamer.checkpoint(a); // the keeper's pre-boundary checkpoint, for a only
        vm.warp(_startOf(2) + 1 hours);
        streamer.checkpointMany(_two(a, b));
        assertApproxEqRel(
            streamer.earned(a), (uint256(500e18) * (7 days - 10 minutes)) / 7 days, 1e14, "a keeps its epoch"
        );
        assertEq(streamer.earned(b), 0, "b's whole span reaches into the empty epoch and pays nothing");
    }

    /// @dev The report: mint in range in the block that matters, collect, leave. Zero seconds of holding.
    function test_jit_mintedForOneBlockEarnsNothing() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        _deposit(1000e18);
        vm.warp(_startOf(1));
        streamer.checkpoint(a);
        vm.warp(_startOf(2) - 1);
        uint256 c = _mintFullRange(pool, LIQ1 * 100, lp2, lp2);
        streamer.checkpoint(c);
        streamer.checkpoint(c);
        assertEq(streamer.earned(c), 0, "zero seconds of holding earns nothing");
        vm.expectRevert(abi.encodeWithSelector(ILPStreamer.NothingToCollect.selector, c));
        vm.prank(lp2);
        streamer.collect(c);
        _decrease(pool, c, LIQ1 * 100, lp2, lp2);
        streamer.checkpoint(a);
        assertApproxEqRel(streamer.earned(a), 1000e18, 1e14, "the position that held all week takes it all");
    }

    function test_liquidityChanges_mirrorTheHookExactly() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        uint256 b = _mintFullRange(pool, LIQ1, lp2, lp2);
        _deposit(1000e18);
        vm.warp(_startOf(1));
        uint256[] memory ids = _two(a, b);
        streamer.checkpointMany(ids);
        vm.warp(_startOf(1) + 3 days + 12 hours);
        _decrease(pool, b, LIQ1, lp2, lp2); // b leaves half way; the hook banks what it held
        vm.warp(_startOf(2) - 1);
        uint256 c = _mintFullRange(pool, LIQ1, lp2, lp2); // and comes back for the last second
        streamer.checkpoint(c);
        streamer.checkpointMany(ids);
        assertApproxEqRel(streamer.earned(a), 750e18, 1e14, "half of the first half, all of the second");
        assertApproxEqRel(streamer.earned(b), 250e18, 1e14, "only the time it held");
        assertEq(streamer.earned(c), 0);
    }

    function test_seedEarnsNothing() public {
        _mintFullRange(pool, LIQ1, lp1, lp1);
        _deposit(1000e18);
        vm.warp(_startOf(1));
        streamer.checkpoint(seedId);
        vm.warp(_startOf(2) - 1);
        streamer.checkpoint(seedId);
        assertEq(streamer.earned(seedId), 0);
    }

    // ================================================================= ordering and griefing

    function test_collectOrder_streamerFirstKeepsTheAccrual() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        _deposit(1000e18);
        vm.warp(_startOf(1));
        streamer.checkpoint(a);
        vm.warp(_startOf(1) + 3 days);
        // the wrong order: LPRewards.collect resets the accrual the streamer reads
        vm.prank(lp1);
        lpRewards.collect(a);
        streamer.checkpoint(a);
        assertEq(streamer.earned(a), 0, "the interval before the collect is forfeited");
        // the right order for the rest of the epoch
        vm.warp(_startOf(2) - 1);
        vm.prank(lp1);
        uint256 got = streamer.collect(a);
        assertApproxEqRel(got, uint256(4000e18) / 7, 1e14, "four of the seven days");
        vm.prank(lp1);
        lpRewards.collect(a);
        assertEq(streamer.earned(a), 0);
        // into the streamer's own 7-day quadratic drip, not the wallet
        bytes32 dripId = streamer.dripIdOf(a, 1);
        IDrip streamDrip = streamer.DRIP(); // into a local: a prank binds to the very next external call
        IDrip.DripAccount memory d = streamDrip.getDrip(lp1, dripId);
        assertEq(d.total, got);
        assertEq(d.length, 7 days);
        assertEq(d.start, block.timestamp);
        assertEq(sgage.balanceOf(address(streamer)), 1000e18 - got, "moved to the drip");
        vm.warp(block.timestamp + 3 days + 12 hours);
        assertEq(streamDrip.unlocked(lp1, dripId), got / 4, "25% half way (D48)");
        vm.warp(block.timestamp + 3 days + 12 hours);
        uint256 before = sgage.balanceOf(lp1);
        vm.prank(lp1);
        streamDrip.claim(dripId);
        assertEq(sgage.balanceOf(lp1), before + got, "everything at the end");
    }

    function test_drip_isTheStreamersOwnWithItAsTheOnlyGrantor() public view {
        assertTrue(streamer.DRIP().isGrantor(address(streamer)));
        assertFalse(streamer.DRIP().isGrantor(address(lpRewards)));
        assertFalse(drip.isGrantor(address(streamer)), "the live Drip does not know it");
        assertEq(streamer.DRIP_LENGTH(), lpRewards.LP_DRIP_LENGTH());
    }

    function test_thirdPartyLPRewardsCheckpointsChangeNothing() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        _deposit(1000e18);
        vm.warp(_startOf(1));
        streamer.checkpoint(a);
        for (uint256 d = 1; d <= 6; ++d) {
            vm.warp(_startOf(1) + d * 1 days);
            vm.prank(other);
            lpRewards.checkpoint(a);
        }
        vm.warp(_startOf(2) - 1);
        streamer.checkpoint(a);
        assertApproxEqRel(streamer.earned(a), 1000e18, 1e14);
    }

    // ================================================================= spanning intervals and solvency

    function test_spanningInterval_paysAtTheSmallestRateItTouches() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        _deposit(1000e18); // pot 1
        vm.warp(_startOf(1));
        streamer.checkpoint(a);
        _deposit(500e18); // pot 2
        vm.warp(_startOf(2) + 3 days + 12 hours);
        streamer.checkpoint(a);
        // exact would be 1000 + 250; the smallest rate, epoch 2's, applies to the whole interval
        uint256 expected = ((_budget(1) + _budget(2) / 2) * 500e18) / _budget(2);
        assertApproxEqRel(streamer.earned(a), expected, 1e14);
        assertLt(streamer.earned(a), 1250e18);
    }

    function test_solvency_neverPaysMoreThanDeposited() public {
        uint256 a = _mintFullRange(pool, LIQ1, lp1, lp1);
        uint256 b = _mintFullRange(pool, LIQ2, lp2, lp2);
        uint256 deposited;
        for (uint256 e = 0; e < 3; ++e) {
            vm.warp(_startOf(e) + 1 hours);
            _deposit(1000e18 * (e + 1));
            deposited += 1000e18 * (e + 1);
            vm.warp(_startOf(e) + 2 days);
            streamer.checkpointMany(_two(a, b));
            if (e == 1) _decrease(pool, b, LIQ2 / 2, lp2, lp2);
        }
        vm.warp(_startOf(4) + 1 days);
        vm.prank(lp1);
        uint256 ga = streamer.collect(a);
        vm.prank(lp2);
        uint256 gb = streamer.collect(b);
        assertLe(ga + gb, deposited);
        assertEq(sgage.balanceOf(address(streamer)), deposited - ga - gb);
        assertEq(streamer.DRIP().totalLocked(), ga + gb, "collected amounts sit in the drip");
        assertGt(ga, gb);
    }

    // ================================================================= helpers

    function _deposit(uint256 amount) internal {
        vm.prank(treasury);
        streamer.deposit(amount);
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _startOf(uint256 e) internal view returns (uint256) {
        return emissions.epochStart(e);
    }

    function _budget(uint256 e) internal view returns (uint256) {
        return lpRewards.emissionRate(e) * emissions.EPOCH();
    }
}
