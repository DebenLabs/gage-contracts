// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {DealVault} from "../../src/DealVault.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";
import {Drip} from "../../src/token/Drip.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {LPRewards} from "../../src/token/LPRewards.sol";
import {SeedTimelock} from "../../src/token/SeedTimelock.sol";
import {ISeedTimelock} from "../../src/interfaces/token/ISeedTimelock.sol";
import {Deal} from "../../src/interfaces/IDealVault.sol";

/// @notice The token layer on the live testnet state after E2EToken.s.sol, under time warp: drips unlock on the
///         curve, epochs release and roll over, the seed is released after its lock, and the supply invariants hold.
/// @dev Env: GAGE_DEPLOYMENT, GAGE_E2E_RPC. Skips itself when either is unset.
contract TokenLayerForkTest is Test {
    DealVault internal vault;
    SGAGE internal sgage;
    Drip internal drip;
    Emissions internal emissions;
    DealRewards internal dealRewards;
    LPRewards internal lpRewards;
    SeedTimelock internal seedTimelock;
    IERC721 internal posm;
    address internal deployer;
    address internal borrower;
    uint256 internal seedId;
    uint256 internal reinvestId;

    function setUp() public {
        string memory path = vm.envOr("GAGE_DEPLOYMENT", string(""));
        string memory rpc = vm.envOr("GAGE_E2E_RPC", string(""));
        if (bytes(path).length == 0 || bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, ".DealRewards") || !vm.keyExistsJson(json, ".reinvestTokenId")) {
            vm.skip(true);
            return;
        }
        vault = DealVault(vm.parseJsonAddress(json, ".DealVault"));
        sgage = SGAGE(vm.parseJsonAddress(json, ".sGAGE"));
        drip = Drip(vm.parseJsonAddress(json, ".Drip"));
        emissions = Emissions(vm.parseJsonAddress(json, ".Emissions"));
        dealRewards = DealRewards(vm.parseJsonAddress(json, ".DealRewards"));
        lpRewards = LPRewards(vm.parseJsonAddress(json, ".LPRewards"));
        seedTimelock = SeedTimelock(vm.parseJsonAddress(json, ".SeedTimelock"));
        posm = IERC721(vm.parseJsonAddress(json, ".PositionManager"));
        deployer = vm.parseJsonAddress(json, ".deployer");
        borrower = vm.parseJsonAddress(json, ".borrower");
        seedId = vm.parseJsonUint(json, ".seedTokenId");
        reinvestId = vm.parseJsonUint(json, ".reinvestTokenId");
    }

    function test_live_dealDripUnlocksOnTheCurve() public {
        Deal memory d = vault.getDeal(1);
        bytes32 id = dealRewards.dripIdOf(1, d.lender);
        uint128 total = drip.getDrip(d.lender, id).total;
        assertGt(total, 0);
        uint40 start = drip.getDrip(d.lender, id).start;
        vm.warp(start + d.term / 2);
        assertEq(drip.unlocked(d.lender, id), total / 4, "25% half way");
        vm.warp(start + d.term);
        uint256 before = sgage.balanceOf(d.lender);
        vm.prank(d.lender);
        drip.claim(id);
        assertEq(sgage.balanceOf(d.lender), before + total, "everything at the end");
    }

    function test_live_epochReleaseAndRollover() public {
        uint256 e = emissions.currentEpoch();
        uint256 before = sgage.balanceOf(address(lpRewards));
        vm.warp(emissions.epochStart(e + 1) + emissions.REGISTRATION_GRACE());
        if (!emissions.released(e + 1)) emissions.release(e + 1);
        emissions.rollover(e);
        assertTrue(emissions.rolledOver(e));
        assertGt(sgage.balanceOf(address(lpRewards)), before, "epoch budgets moved to LPRewards");
        assertLe(emissions.totalOut(), emissions.prefixSum(e + 1), "T2");
    }

    function test_live_lpPositionKeepsEarning() public {
        (uint256 em0,) = lpRewards.earned(reinvestId);
        vm.warp(block.timestamp + 1 days);
        (uint256 em1,) = lpRewards.earned(reinvestId);
        assertGt(em1, em0, "emissions keep accruing to the position");
        vm.prank(borrower);
        (uint256 collected,) = lpRewards.collect(reinvestId);
        assertEq(collected, em1);
    }

    function test_live_seedReleasesAfterTheLock() public {
        assertEq(posm.ownerOf(seedId), address(seedTimelock));
        vm.expectRevert(abi.encodeWithSelector(ISeedTimelock.StillLocked.selector, seedTimelock.releaseAt()));
        seedTimelock.release();
        vm.warp(seedTimelock.releaseAt());
        seedTimelock.release();
        assertEq(posm.ownerOf(seedId), seedTimelock.TREASURY());
        assertEq(lpRewards.positionState(seedId).weight, 0, "the seed never scored");
    }

    function test_live_supplyInvariants() public view {
        assertLe(sgage.totalSupply(), sgage.TOTAL_SUPPLY_AT_MINT(), "T1");
        assertEq(sgage.balanceOf(address(drip)), drip.totalLocked(), "Drip holds exactly what is locked");
        assertLe(emissions.totalOut(), emissions.prefixSum(emissions.currentEpoch()), "T2");
        assertEq(sgage.balanceOf(address(emissions)), emissions.RESERVE() - emissions.totalOut(), "reserve accounting");
    }
}
