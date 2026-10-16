// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TokenBaseTest} from "./TokenBase.t.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {IEmissions} from "../../src/interfaces/token/IEmissions.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";

contract EmissionsTest is TokenBaseTest {
    uint32 internal constant T1D = 1 days;

    function _warpToEpoch(uint256 e) internal {
        vm.warp(emissions.epochStart(e));
    }

    // ----------------------------------------------------------------- the table

    function test_table_sumsToReserveAndDecays() public view {
        assertEq(emissions.prefixSum(51), RESERVE);
        assertEq(emissions.prefixSum(99), RESERVE);
        assertEq(emissions.weekly(0), emissions.WEEK_ONE());
        assertApproxEqRel(emissions.weekly(0), 401_676_823e18, 1e12, "week one ~401.7M");
        assertApproxEqRel(emissions.weekly(51), 1_863_137e18, 1e12, "week 52 ~1.86M");
        uint256 sum;
        for (uint256 i = 0; i < 52; ++i) {
            uint256 w = emissions.weekly(i);
            if (i > 0) assertApproxEqRel(w, (emissions.weekly(i - 1) * 9) / 10, 1e6, "10% decay");
            sum += w;
            assertEq(emissions.prefixSum(i), sum, "prefix");
        }
        assertEq(sum, RESERVE);
        assertGe(emissions.prefixSum(6), RESERVE / 2, "half by week 7");
        assertGe(emissions.prefixSum(21), (RESERVE * 9) / 10, "90% by week 22");
    }

    function test_table_outOfRangeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochOutOfRange.selector, 52));
        emissions.weekly(52);
    }

    // ----------------------------------------------------------------- launch and wiring

    function test_launch_onceInTheFuture() public {
        Emissions e = new Emissions(safe, address(this));
        vm.prank(safe);
        vm.expectRevert(Emissions.NotWired.selector);
        e.launch(uint40(block.timestamp));
        e.wire(sgage, lpMock_(), address(dealRewards));
        vm.startPrank(safe);
        vm.expectRevert(IEmissions.LaunchInPast.selector);
        e.launch(uint40(block.timestamp - 8 days));
        e.launch(uint40(block.timestamp + 1 days));
        vm.expectRevert(IEmissions.AlreadyLaunched.selector);
        e.launch(uint40(block.timestamp + 2 days));
        vm.stopPrank();
        assertEq(e.epochStart(3), block.timestamp + 1 days + 21 days);
    }

    function test_wire_onceByDeployer() public {
        Emissions e = new Emissions(safe, address(this));
        vm.expectRevert(Emissions.NotDeployer.selector);
        vm.prank(other);
        e.wire(sgage, lpMock_(), address(dealRewards));
        e.wire(sgage, lpMock_(), address(dealRewards));
        vm.expectRevert(Emissions.AlreadyWired.selector);
        e.wire(sgage, lpMock_(), address(dealRewards));
    }

    function test_epochMath() public {
        assertEq(emissions.currentEpoch(), 0);
        _warpToEpoch(3);
        assertEq(emissions.currentEpoch(), 3);
        assertEq(emissions.epochOf(uint40(block.timestamp - 1)), 2);
        assertEq(emissions.epochOf(uint40(emissions.launchAt() - 10)), 0, "pre-launch maps to epoch 0");
        _warpToEpoch(60);
        assertEq(emissions.currentEpoch(), 52, "capped after the schedule");
        assertTrue(emissions.scheduleOver());
    }

    // ----------------------------------------------------------------- shares and budgets

    function test_defaultBudgets() public view {
        uint256 w = emissions.weekly(0);
        assertEq(emissions.liquidityBudget(0), w - (w * 6000) / 10_000);
        uint256 deals = (w * 6000) / 10_000;
        assertEq(emissions.dealBudget(0, 21 days), (deals * 7000) / 10_000);
        assertEq(emissions.dealBudget(0, 7 days), deals - (deals * 7000) / 10_000);
        assertEq(emissions.dealBudget(0, T1D), emissions.dealBudget(0, 7 days), "short terms use the 7-day budget");
        assertEq(emissions.dealBudget(0, 30 days), emissions.dealBudget(0, 21 days), "long terms use the 21-day budget");
        assertEq(emissions.liquidityBudget(0) + emissions.dealBudget(0, 7 days) + emissions.dealBudget(0, 21 days), w);
    }

    function test_setShares_boundsAndTiming() public {
        vm.startPrank(safe);
        emissions.setShares(2, 8000, 9000);
        assertEq(emissions.dealShareBps(2), 8000);
        assertEq(emissions.term21ShareBps(2), 9000);
        vm.expectRevert(IEmissions.SharesOutOfBounds.selector);
        emissions.setShares(2, 8001, 7000);
        vm.expectRevert(IEmissions.SharesOutOfBounds.selector);
        emissions.setShares(2, 1999, 7000);
        vm.expectRevert(IEmissions.SharesOutOfBounds.selector);
        emissions.setShares(2, 6000, 4999);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochAlreadyStarted.selector, 0));
        emissions.setShares(0, 6000, 7000);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochOutOfRange.selector, 52));
        emissions.setShares(52, 6000, 7000);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        emissions.setShares(3, 6000, 7000);
    }

    // ----------------------------------------------------------------- release

    function test_release_streamsLiquidityBudgetOnce() public {
        vm.expectEmit(address(emissions));
        emit IEmissions.Released(
            0, emissions.liquidityBudget(0), emissions.dealBudget(0, 7 days), emissions.dealBudget(0, 21 days)
        );
        emissions.release(0);
        assertTrue(emissions.released(0));
        assertEq(lpMock.lastEpoch(), 0);
        assertEq(lpMock.lastEmissions(), emissions.liquidityBudget(0));
        assertEq(sgage.balanceOf(address(lpMock)), emissions.liquidityBudget(0));
        assertEq(emissions.totalOut(), emissions.liquidityBudget(0));
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochAlreadyReleased.selector, 0));
        emissions.release(0);
    }

    function test_release_revertsBeforeEpochStartsAndOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochNotStarted.selector, 1));
        emissions.release(1);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochOutOfRange.selector, 52));
        emissions.release(52);
    }

    function test_release_anyoneAnyOrder() public {
        _warpToEpoch(2);
        vm.prank(other);
        emissions.release(2);
        vm.prank(other);
        emissions.release(0);
        assertEq(emissions.totalOut(), emissions.liquidityBudget(0) + emissions.liquidityBudget(2));
    }

    // ----------------------------------------------------------------- reserve

    function test_reserve_onlyDealRewardsWithinRemaining() public {
        emissions.release(0);
        uint256 budget7 = emissions.dealBudget(0, 7 days);
        vm.expectRevert(IEmissions.NotDealRewards.selector);
        vm.prank(other);
        emissions.reserve(0, 7 days, 1, other);

        vm.startPrank(address(dealRewards));
        emissions.reserve(0, 7 days, budget7 - 1, other);
        assertEq(emissions.reserved(0, 7 days), budget7 - 1);
        assertEq(emissions.remaining(0, 7 days), 1);
        assertEq(sgage.balanceOf(other), budget7 - 1);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.BudgetExceeded.selector, 0, 7 days, 1, 2));
        emissions.reserve(0, 7 days, 2, other);
        emissions.reserve(0, T1D, 1, other);
        assertEq(emissions.remaining(0, 7 days), 0);
        vm.stopPrank();
    }

    function test_reserve_requiresRelease() public {
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochNotReleased.selector, 0));
        vm.prank(address(dealRewards));
        emissions.reserve(0, 7 days, 1, other);
    }

    // ----------------------------------------------------------------- rollover

    function test_rollover_afterGraceSendsUnreservedToLiquidity() public {
        emissions.release(0);
        vm.prank(address(dealRewards));
        emissions.reserve(0, 21 days, 1000e18, other);
        uint256 expected = emissions.dealBudget(0, 7 days) + emissions.dealBudget(0, 21 days) - 1000e18;

        vm.warp(emissions.epochStart(1) + emissions.REGISTRATION_GRACE() - 1);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochNotEnded.selector, 0));
        emissions.rollover(0);

        vm.warp(emissions.epochStart(1) + emissions.REGISTRATION_GRACE());
        vm.expectEmit(address(emissions));
        emit IEmissions.RolledOver(0, expected);
        emissions.rollover(0);
        assertTrue(emissions.rolledOver(0));
        assertEq(lpMock.lumpsTotal(), expected);
        assertEq(emissions.remaining(0, 7 days), 0);
        assertEq(emissions.remaining(0, 21 days), 0);
        assertEq(emissions.totalOut(), emissions.weekly(0), "the whole week is out");

        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochAlreadyRolledOver.selector, 0));
        vm.prank(address(dealRewards));
        emissions.reserve(0, 7 days, 1, other);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochAlreadyRolledOver.selector, 0));
        emissions.rollover(0);
    }

    function test_rollover_requiresRelease() public {
        _warpToEpoch(2);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochNotReleased.selector, 0));
        emissions.rollover(0);
    }

    // ----------------------------------------------------------------- finalize and the ceiling

    function test_finalize_burnsRemainderAfterEveryEpochSettles() public {
        for (uint256 e = 0; e < 52; ++e) {
            _warpToEpoch(e);
            emissions.release(e);
        }
        vm.warp(emissions.epochStart(52) + emissions.REGISTRATION_GRACE() - 1);
        vm.expectRevert(IEmissions.ScheduleNotOver.selector);
        emissions.finalize();
        vm.warp(emissions.epochStart(52) + emissions.REGISTRATION_GRACE());
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochNotEnded.selector, 0));
        emissions.finalize();
        for (uint256 e = 0; e < 52; ++e) {
            emissions.rollover(e);
        }
        // Everything was released and rolled over, so nothing is left; simulate dust to prove the burn path.
        deal(address(sgage), address(emissions), 123);
        uint256 supply = sgage.totalSupply();
        vm.expectEmit(address(emissions));
        emit IEmissions.Finalized(123);
        emissions.finalize();
        assertEq(sgage.totalSupply(), supply - 123);
        assertEq(sgage.balanceOf(address(emissions)), 0);
        assertEq(emissions.totalOut(), RESERVE, "every week paid out in full");
    }

    /// @dev T2 over the whole schedule: cumulative out never exceeds the prefix sum of the current epoch.
    function test_T2_ceilingHoldsAcrossTheSchedule() public {
        for (uint256 e = 0; e < 52; ++e) {
            vm.warp(emissions.epochStart(e) + emissions.REGISTRATION_GRACE());
            emissions.release(e);
            uint256 half = emissions.dealBudget(e, 7 days) / 2;
            vm.prank(address(dealRewards));
            emissions.reserve(e, 7 days, half, other);
            assertLe(emissions.totalOut(), emissions.prefixSum(e), "T2");
            if (e > 0) emissions.rollover(e - 1);
            assertLe(emissions.totalOut(), emissions.prefixSum(e), "T2 after rollover");
            assertEq(sgage.balanceOf(address(emissions)), RESERVE - emissions.totalOut(), "nothing leaves unaccounted");
        }
    }

    function lpMock_() internal view returns (ILPRewards) {
        return ILPRewards(address(lpMock));
    }
}
