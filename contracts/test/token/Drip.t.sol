// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {Drip} from "../../src/token/Drip.sol";
import {IDrip} from "../../src/interfaces/token/IDrip.sol";

contract DripTest is TokenBaseTest {
    bytes32 internal constant ID = keccak256("drip-1");
    uint128 internal constant TOTAL = 1000e18;
    uint32 internal constant LEN = 21 days;
    address internal grantor;

    function setUp() public override {
        super.setUp();
        grantor = address(lpMock); // a grantor with sGAGE to give
        deal(address(sgage), grantor, 10_000e18);
        vm.prank(grantor);
        sgage.approve(address(drip), type(uint256).max);
    }

    function _grant(address to, bytes32 id, uint128 total, uint40 start, uint32 len) internal {
        vm.prank(grantor);
        drip.grant(to, id, total, start, len);
    }

    // ----------------------------------------------------------------- grant

    function test_grant_pullsTokensAndEmits() public {
        uint40 start = uint40(block.timestamp);
        vm.expectEmit(address(drip));
        emit IDrip.Granted(borrower, ID, TOTAL, start, LEN, grantor);
        _grant(borrower, ID, TOTAL, start, LEN);
        IDrip.DripAccount memory d = drip.getDrip(borrower, ID);
        assertEq(d.total, TOTAL);
        assertEq(d.claimed, 0);
        assertEq(d.start, start);
        assertEq(d.length, LEN);
        assertEq(sgage.balanceOf(address(drip)), TOTAL);
        assertEq(drip.totalLocked(), TOTAL);
    }

    function test_grant_onlyGrantors() public {
        deal(address(sgage), other, TOTAL);
        vm.prank(other);
        sgage.approve(address(drip), TOTAL);
        vm.expectRevert(abi.encodeWithSelector(IDrip.NotGrantor.selector, other));
        vm.prank(other);
        drip.grant(borrower, ID, TOTAL, uint40(block.timestamp), LEN);
    }

    function test_grant_rejectsDuplicateZeroAndBadLength() public {
        _grant(borrower, ID, TOTAL, uint40(block.timestamp), LEN);
        vm.expectRevert(abi.encodeWithSelector(IDrip.DripExists.selector, borrower, ID));
        _grant(borrower, ID, TOTAL, uint40(block.timestamp), LEN);
        vm.expectRevert(IDrip.ZeroAmount.selector);
        _grant(borrower, keccak256("x"), 0, uint40(block.timestamp), LEN);
        vm.expectRevert(IDrip.ZeroLength.selector);
        _grant(borrower, keccak256("y"), TOTAL, uint40(block.timestamp), 0);
        vm.expectRevert(IDrip.ZeroAddress.selector);
        _grant(address(0), keccak256("z"), TOTAL, uint40(block.timestamp), LEN);
    }

    function test_setGrantors_onceByDeployer() public {
        Drip d = new Drip(sgage, address(this));
        vm.expectRevert(Drip.NotDeployer.selector);
        vm.prank(other);
        d.setGrantors(other, other);
        d.setGrantors(address(dealRewards), address(lpMock));
        vm.expectRevert(IDrip.GrantorsAlreadySet.selector);
        d.setGrantors(other, other);
        assertTrue(d.isGrantor(address(dealRewards)));
        assertFalse(d.isGrantor(other));
        assertFalse(d.isGrantor(address(0)));
    }

    // ----------------------------------------------------------------- the curve

    function test_curve_pointsOnTheParabola() public {
        uint40 start = uint40(block.timestamp);
        _grant(borrower, ID, TOTAL, start, LEN);
        assertEq(drip.unlocked(borrower, ID), 0, "nothing at start");
        vm.warp(start + LEN / 10);
        assertEq(drip.unlocked(borrower, ID), TOTAL / 100, "1% at one tenth");
        vm.warp(start + LEN / 2);
        assertEq(drip.unlocked(borrower, ID), TOTAL / 4, "25% half way");
        vm.warp(start + (LEN * 9) / 10);
        assertEq(drip.unlocked(borrower, ID), (TOTAL * 81) / 100, "81% at nine tenths");
        vm.warp(start + LEN);
        assertEq(drip.unlocked(borrower, ID), TOTAL, "exact at the end");
        vm.warp(start + LEN + 365 days);
        assertEq(drip.unlocked(borrower, ID), TOTAL, "stays at total");
    }

    function test_curve_nothingBeforeStart() public {
        uint40 start = uint40(block.timestamp + 3 days);
        _grant(borrower, ID, TOTAL, start, LEN);
        assertEq(drip.unlocked(borrower, ID), 0);
        vm.warp(start);
        assertEq(drip.unlocked(borrower, ID), 0);
        vm.warp(start + 1);
        assertGt(drip.unlocked(borrower, ID), 0);
    }

    function testFuzz_curve_monotoneAndBounded(uint128 total, uint32 len, uint32 t1, uint32 t2) public {
        total = uint128(bound(total, 1, 5_000_000_000e18));
        len = uint32(bound(len, 1, 365 days));
        t1 = uint32(bound(t1, 0, 2 * uint256(len)));
        t2 = uint32(bound(t2, t1, 2 * uint256(len)));
        deal(address(sgage), grantor, total);
        uint40 start = uint40(block.timestamp);
        _grant(borrower, ID, total, start, len);
        vm.warp(start + t1);
        uint128 u1 = drip.unlocked(borrower, ID);
        vm.warp(start + t2);
        uint128 u2 = drip.unlocked(borrower, ID);
        assertLe(u1, u2, "monotone");
        assertLe(u2, total, "bounded");
        if (t2 >= len) assertEq(u2, total, "exact at and after the end");
    }

    // ----------------------------------------------------------------- claims

    function test_claim_transfersUnlockedMinusClaimed() public {
        uint40 start = uint40(block.timestamp);
        _grant(borrower, ID, TOTAL, start, LEN);
        vm.warp(start + LEN / 2);
        vm.expectEmit(address(drip));
        emit IDrip.Claimed(borrower, ID, TOTAL / 4);
        vm.prank(borrower);
        assertEq(drip.claim(ID), TOTAL / 4);
        assertEq(sgage.balanceOf(borrower), TOTAL / 4);
        assertEq(drip.claimable(borrower, ID), 0);
        assertEq(drip.totalLocked(), TOTAL - TOTAL / 4);

        vm.expectRevert(IDrip.NothingClaimable.selector);
        vm.prank(borrower);
        drip.claim(ID);

        vm.warp(start + LEN);
        vm.prank(borrower);
        assertEq(drip.claim(ID), TOTAL - TOTAL / 4);
        assertEq(sgage.balanceOf(borrower), TOTAL);
        assertEq(drip.totalLocked(), 0);
        assertEq(sgage.balanceOf(address(drip)), 0);
    }

    function test_claimMany_sumsAcrossDrips() public {
        uint40 start = uint40(block.timestamp);
        _grant(borrower, ID, TOTAL, start, LEN);
        _grant(borrower, keccak256("drip-2"), TOTAL, start, LEN);
        vm.warp(start + LEN);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ID;
        ids[1] = keccak256("drip-2");
        vm.prank(borrower);
        assertEq(drip.claimMany(ids), 2 * TOTAL);
    }

    function test_claim_revertsNoDrip() public {
        vm.expectRevert(abi.encodeWithSelector(IDrip.NoDrip.selector, other, ID));
        vm.prank(other);
        drip.claim(ID);
    }

    function test_claim_onlyTheAccount() public {
        _grant(borrower, ID, TOTAL, uint40(block.timestamp), LEN);
        vm.warp(block.timestamp + LEN);
        vm.expectRevert(abi.encodeWithSelector(IDrip.NoDrip.selector, other, ID));
        vm.prank(other);
        drip.claim(ID);
    }

    /// @dev T3: there is no function that releases early. The surface is grant, claim, claimMany, setGrantors.
    function test_T3_noEarlyReleaseSurface() public {
        _grant(borrower, ID, TOTAL, uint40(block.timestamp), LEN);
        string[4] memory sigs = ["release(bytes32)", "unlock(bytes32)", "setStart(bytes32,uint40)", "owner()"];
        for (uint256 i = 0; i < sigs.length; ++i) {
            (bool ok,) = address(drip).call(abi.encodeWithSignature(sigs[i], ID, 0));
            assertFalse(ok, sigs[i]);
        }
        assertEq(drip.claimable(borrower, ID), 0);
    }
}
