// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDealVault, DealState} from "../../src/interfaces/IDealVault.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealVault} from "../../src/DealVault.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {cashOwed} from "../helpers/CoreCash.sol";

using {cashOwed} for GageV2Vault;

/// @dev The deployed adapter's loan record, which still carries the `account` and `engineId` this source's adapter
///      dropped (REW-08); the fork reads the current engine's adapter through it.
interface ILegacyAdapterLoans {
    struct Loan {
        address engine;
        address ledger;
        address account;
        address borrower;
        address lender;
        uint256 engineId;
        uint256 legacyId;
        uint128 cap;
        uint128 borrowerReward;
        uint128 lenderReward;
        uint40 start;
        uint40 closedAt;
        uint32 term;
        uint256 liquid;
        uint256 paid;
    }

    function loan(uint256 id) external view returns (Loan memory);
}

/// @notice Rehearse the no-grace release on a fork: a second adapter over the live legacy vault, a zero-grace engine
///         behind it, the current engine left to its own adapter so its loans keep the terms they were funded under.
/// @dev All changes occur on a local fork. Only test USDG/SPY capital and future reward rates are simulated.
contract GageV2NoGraceRotationForkTest is Test {
    GageV2Vault constant CURRENT = GageV2Vault(0x08561C817A5bf5230f91C001800449f047e4c07d);
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    GageLegacyAdapter internal currentBridge;
    GageLegacyAdapter internal bridge;
    IDealVault internal legacy;
    GageV2Vault internal next;
    IERC20 internal usdg;
    address internal borrower = makeAddr("no-grace borrower");
    address internal lender = makeAddr("no-grace lender");
    address internal currentBorrower = makeAddr("current-engine borrower");
    address internal currentLender = makeAddr("current-engine lender");

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_V2_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_V2_FORK_BLOCK"));
        currentBridge = CURRENT.BRIDGE();
        legacy = currentBridge.VAULT();
        usdg = CURRENT.USDG();
        assertEq(CURRENT.GRACE(), legacy.GRACE(), "the current engine still mirrors the legacy grace");
        // The new adapter: same source vault and reward contracts, its own receipt, admitted by the legacy registry.
        bridge = new GageLegacyAdapter(address(this), legacy, currentBridge.REWARDS(), usdg);
        CollateralRegistry oldRegistry = CollateralRegistry(address(DealVault(address(legacy)).REGISTRY()));
        vm.prank(oldRegistry.owner());
        oldRegistry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        GageV2Registry registry = new GageV2Registry(address(this), terms, CURRENT.REGISTRY().V3_FACTORY());
        registry.setERC20Allowed(SPY, true, Lane.STOCK, 1, 1000e18, 10_000e18);
        next = new GageV2Vault(
            GageV2TokenRegistry(address(registry)), usdg, CURRENT.SGAGE(), CURRENT.FEE_RECIPIENT(), 0, bridge
        );
        // An engine lends to no one until a funder gate is bound (D47); these accounts stand in for vaults.
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        next.REWARDS().bindFunderGate(openGate);
        bridge.setEngine(address(next));
    }

    /// @dev Real active loans on the current engine are used as they stand. When the pinned block holds none (live
    ///      originations moved on, and that registry is already paused), one is opened on the local fork through the
    ///      deployed engine, its own adapter and the legacy vault, as a borrower would have before the cutover: the
    ///      registry owner reopens listings and admits SPY for it, and `_rotate` pauses the registry again.
    function _ensureCurrentLoan() internal {
        for (uint256 i = 1; i <= CURRENT.loanCount(); ++i) {
            if (CURRENT.getLoan(i).state == V2State.ACTIVE) return;
        }
        GageV2Registry registry = GageV2Registry(address(CURRENT.REGISTRY()));
        address owner = registry.owner();
        vm.startPrank(owner);
        registry.pauseNewDeals(false);
        registry.setERC20Allowed(SPY, true, Lane.STOCK, 1, 1000e18, 10_000e18);
        vm.stopPrank();
        deal(SPY, currentBorrower, 1e18);
        vm.startPrank(currentBorrower);
        IERC20(SPY).approve(address(CURRENT), 1e18);
        uint256 id = CURRENT.list(
            Collateral(Kind.ERC20, SPY, 1e18), 100e6, 110e6, 7 days, uint40(vm.getBlockTimestamp() + 1 days), false
        );
        vm.stopPrank();
        deal(address(usdg), currentLender, 100e6);
        vm.startPrank(currentLender);
        usdg.approve(address(CURRENT), 100e6);
        CURRENT.fund(id, 4);
        vm.stopPrank();
        assertEq(uint256(CURRENT.getLoan(id).state), uint256(V2State.ACTIVE));
        uint256 source = currentBridge.adapterId(address(CURRENT), id);
        assertEq(ILegacyAdapterLoans(address(currentBridge)).loan(source).engine, address(CURRENT));
    }

    /// @dev Pause the current engine's registry: no new listings and no funding there, so an unfilled listing is
    ///      refunded or cancelled rather than activated; its adapter stays with it and never serves the new engine.
    function _rotate() internal {
        bytes32[] memory snapshots = new bytes32[](CURRENT.loanCount());
        for (uint256 i; i < snapshots.length; ++i) {
            snapshots[i] = keccak256(abi.encode(CURRENT.getLoan(i + 1), CURRENT.lenders(i + 1)));
        }
        GageV2Registry oldRegistry = GageV2Registry(address(CURRENT.REGISTRY()));
        vm.prank(oldRegistry.owner());
        oldRegistry.pauseNewDeals(true);
        assertEq(currentBridge.activeEngine(), address(CURRENT));
        assertEq(bridge.activeEngine(), address(next));
        for (uint256 i; i < snapshots.length; ++i) {
            assertEq(keccak256(abi.encode(CURRENT.getLoan(i + 1), CURRENT.lenders(i + 1))), snapshots[i]);
            if (CURRENT.getLoan(i + 1).state == V2State.FUNDING) {
                deal(address(usdg), lender, 1e6);
                vm.startPrank(lender);
                usdg.approve(address(CURRENT), 1e6);
                vm.expectRevert(GageV2Vault.Paused.selector);
                CURRENT.fund(i + 1, 1);
                vm.stopPrank();
            }
        }
    }

    function _open() internal returns (uint256 id) {
        deal(SPY, borrower, 1e18);
        vm.startPrank(borrower);
        IERC20(SPY).approve(address(next), 1e18);
        id = next.list(
            Collateral(Kind.ERC20, SPY, 1e18), 100e6, 110e6, 7 days, uint40(vm.getBlockTimestamp() + 1 days), true
        );
        vm.stopPrank();
        deal(address(usdg), lender, 100e6);
        vm.startPrank(lender);
        usdg.approve(address(next), 100e6);
        next.fund(id, 4);
        vm.stopPrank();
        assertEq(uint256(next.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    function testNoGrace_currentLoansKeepTheirGraceAndNewLoansSettleAtMaturity() public {
        _ensureCurrentLoan();
        _rotate();
        uint256 active;
        for (uint256 id = 1; id <= CURRENT.loanCount(); ++id) {
            V2Loan memory l = CURRENT.getLoan(id);
            if (l.state != V2State.ACTIVE) continue;
            ++active;
            // The deployed engine keeps its race semantics: repayment stays open until a claim executes.
            uint256 late = uint256(l.fundedAt) + l.term + CURRENT.GRACE() + 1 hours;
            if (late > vm.getBlockTimestamp()) vm.warp(late);
            address owner = CURRENT.ownerOf(id);
            deal(address(usdg), owner, l.cap);
            vm.startPrank(owner);
            usdg.approve(address(CURRENT), l.cap);
            CURRENT.reclaim(id, owner);
            vm.stopPrank();
            assertEq(uint256(CURRENT.getLoan(id).state), uint256(V2State.REPAID));
        }
        assertGt(active, 0, "The current engine must hold an active loan at the rotation");
        uint256 id = _open();
        V2Loan memory l = next.getLoan(id);
        uint256 source = bridge.adapterId(address(next), id);
        uint256 legacyId = bridge.loan(source).legacyId;
        assertEq(legacy.getDeal(legacyId).fundedAt, l.fundedAt);
        uint256 maturity = uint256(l.fundedAt) + l.term;
        vm.warp(maturity - 1);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        next.finalizeDefault(id);
        vm.warp(maturity);
        deal(address(usdg), borrower, l.cap);
        vm.startPrank(borrower);
        usdg.approve(address(next), l.cap);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        next.reclaim(id, borrower);
        vm.stopPrank();
        next.finalizeDefault(id);
        assertEq(uint256(next.getLoan(id).state), uint256(V2State.DEFAULTED));
        assertEq(uint256(legacy.getDeal(legacyId).state), uint256(DealState.FUNDED));
        vm.startPrank(lender);
        next.recoverDefault(id, 0, 0, block.timestamp);
        next.withdrawRecovery(id, 0, lender);
        vm.stopPrank();
        assertEq(IERC20(SPY).balanceOf(lender), 1e18);
        vm.warp(legacy.claimableAt(legacyId));
        bridge.settleLegacy(source);
        assertEq(uint256(legacy.getDeal(legacyId).state), uint256(DealState.CLAIMED));
        assertEq(bridge.totalSupply(), 0);
        address[] memory holders = new address[](3);
        (holders[0], holders[1], holders[2]) = (borrower, lender, next.FEE_RECIPIENT());
        assertEq(usdg.balanceOf(address(next)), next.cashOwed(holders));
        assertEq(usdg.balanceOf(address(bridge)), 0);
    }

    function testNoGrace_newLoansEarnFromTheExistingEmissionSourceThroughTheNewAdapter() public {
        _rotate();
        DealRewards source = bridge.REWARDS();
        uint256 epoch = source.EMISSIONS().currentEpoch() + 1;
        vm.warp(uint256(source.EMISSIONS().epochStart(epoch)) + 60);
        vm.prank(source.owner());
        source.setEpochRates(epoch, 100e18, 100e18, 1, 5000);
        uint256 id = _open();
        V2Loan memory l = next.getLoan(id);
        assertGt(l.lenderReward, 0);
        assertGt(l.borrowerReward, 0);
        vm.warp(uint256(l.fundedAt) + l.term / 2);
        deal(address(usdg), borrower, l.cap);
        vm.startPrank(borrower);
        usdg.approve(address(next), l.cap);
        next.reclaim(id, borrower);
        vm.stopPrank();
        assertEq(
            uint256(legacy.getDeal(bridge.loan(bridge.adapterId(address(next), id)).legacyId).state),
            uint256(DealState.RECLAIMED)
        );
        vm.warp(block.timestamp + 7 days);
        GageV2Rewards nextRewards = next.REWARDS();
        vm.prank(borrower);
        nextRewards.claim(id, borrower);
        vm.prank(lender);
        nextRewards.claim(id, lender);
        uint256 paid = next.SGAGE().balanceOf(borrower) + next.SGAGE().balanceOf(lender);
        assertEq(paid, uint256(l.borrowerReward) / 4 + uint256(l.lenderReward) / 4);
        assertEq(next.SGAGE().balanceOf(address(next.REWARDS())), 0);
    }
}
