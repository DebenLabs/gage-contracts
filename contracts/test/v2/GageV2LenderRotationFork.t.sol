// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {cashOwed} from "../helpers/CoreCash.sol";

using {cashOwed} for GageV2Vault;

/// @notice Rotate the actual deployed adapter, preserve every existing loan, and settle a sold new position.
/// @dev All changes occur on a local fork. Only test USDG/SPY capital and future reward terms are simulated.
contract GageV2LenderRotationForkTest is Test {
    GageV2Vault constant OLD = GageV2Vault(0x22658055B70b8B09616B1e0953f2A51cc66cF493);
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    GageV2Vault internal next;
    GageLegacyAdapter internal bridge;
    IERC20 internal usdg;
    address internal borrower = makeAddr("new borrower");
    address internal lender = makeAddr("new lender");
    address internal buyer = makeAddr("resale buyer");
    address internal existingBorrower = makeAddr("existing borrower");
    address internal existingLender = makeAddr("existing lender");

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_V2_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_V2_FORK_BLOCK"));
        bridge = OLD.BRIDGE();
        usdg = OLD.USDG();
        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        GageV2Registry registry = new GageV2Registry(address(this), terms, OLD.REGISTRY().V3_FACTORY());
        registry.setERC20Allowed(SPY, true, Lane.STOCK, 1, 1000e18, 10_000e18);
        next = new GageV2Vault(
            GageV2TokenRegistry(address(registry)), usdg, OLD.SGAGE(), OLD.FEE_RECIPIENT(), OLD.GRACE(), bridge
        );
        // An engine lends to no one until a funder gate is bound (D47); these accounts stand in for vaults.
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        next.REWARDS().bindFunderGate(openGate);
    }

    /// @dev Real active loans on the deployed engine are used as they stand. When the pinned block holds none (its
    ///      last loans closed, and that registry is already paused), one is opened on the local fork as a borrower
    ///      would have before the rotation: the adapter admin points the adapter back at that engine, as it stood then,
    ///      and the registry owner reopens listings and admits SPY for it. `_rotate` pauses the registry and moves the
    ///      adapter to the next engine again.
    function _ensureExistingLoan() internal {
        for (uint256 i = 1; i <= OLD.loanCount(); ++i) {
            if (OLD.getLoan(i).state == V2State.ACTIVE) return;
        }
        vm.prank(bridge.ADMIN());
        bridge.setEngine(address(OLD));
        GageV2Registry registry = GageV2Registry(address(OLD.REGISTRY()));
        address owner = registry.owner();
        vm.startPrank(owner);
        registry.pauseNewDeals(false);
        registry.setERC20Allowed(SPY, true, Lane.STOCK, 1, 1000e18, 10_000e18);
        vm.stopPrank();
        deal(SPY, existingBorrower, 1e18);
        vm.startPrank(existingBorrower);
        IERC20(SPY).approve(address(OLD), 1e18);
        uint256 id = OLD.list(
            Collateral(Kind.ERC20, SPY, 1e18), 100e6, 110e6, 7 days, uint40(vm.getBlockTimestamp() + 1 days), false
        );
        vm.stopPrank();
        deal(address(usdg), existingLender, 100e6);
        vm.startPrank(existingLender);
        usdg.approve(address(OLD), 100e6);
        OLD.fund(id, 4);
        vm.stopPrank();
        assertEq(uint256(OLD.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    function _rotate() internal {
        bytes32[] memory snapshots = new bytes32[](OLD.loanCount());
        for (uint256 i; i < snapshots.length; ++i) {
            snapshots[i] = keccak256(abi.encode(OLD.getLoan(i + 1), OLD.lenders(i + 1)));
        }
        GageV2Registry oldRegistry = GageV2Registry(address(OLD.REGISTRY()));
        vm.prank(oldRegistry.owner());
        oldRegistry.pauseNewDeals(true);
        vm.prank(bridge.ADMIN());
        bridge.setEngine(address(next));
        for (uint256 i; i < snapshots.length; ++i) {
            assertEq(keccak256(abi.encode(OLD.getLoan(i + 1), OLD.lenders(i + 1))), snapshots[i]);
            uint256 source = bridge.adapterId(address(OLD), i + 1);
            if (source != 0) assertEq(bridge.loan(source).engine, address(OLD));
        }
    }

    function _open() internal returns (uint256 id) {
        deal(SPY, borrower, 1e18);
        vm.startPrank(borrower);
        IERC20(SPY).approve(address(next), 1e18);
        id = next.list(
            Collateral(Kind.ERC20, SPY, 1e18), 100e6, 110e6, 7 days, uint40(vm.getBlockTimestamp() + 1 days), false
        );
        vm.stopPrank();
        deal(address(usdg), lender, 100e6);
        vm.startPrank(lender);
        usdg.approve(address(next), 100e6);
        next.fund(id, 4);
        vm.stopPrank();
    }

    function _sell(uint256 id) internal {
        vm.prank(lender);
        next.setLenderAsk(id, 5, 52e6, uint40(vm.getBlockTimestamp() + 1 days), 100);
        V2LenderAsk memory ask = next.getLenderAsk(id, lender);
        deal(address(usdg), buyer, 52e6);
        vm.startPrank(buyer);
        usdg.approve(address(next), 52e6);
        uint128[4] memory none;
        next.buyLenderSplit(id, V2LenderSplit(lender, 5, 52e6, 100, ask.nonce, [buyer, buyer, buyer, buyer], none));
        vm.stopPrank();
        assertEq(next.cashCredit(lender), 51_480_000);
        assertEq(next.cashCredit(OLD.FEE_RECIPIENT()), 520_000);
    }

    function testLiveRotation_existingLoansRepayAndRecoverOnTheirOriginalEngine() public {
        _ensureExistingLoan();
        _rotate();
        uint256 active;
        for (uint256 id = 1; id <= OLD.loanCount(); ++id) {
            V2Loan memory l = OLD.getLoan(id);
            if (l.state != V2State.ACTIVE) continue;
            ++active;
            address owner = OLD.ownerOf(id);
            address[4] memory holders = OLD.lenders(id);
            uint256[4] memory credits;
            for (uint8 i; i < 4; ++i) {
                credits[i] = OLD.cashCredit(holders[i]);
            }
            deal(address(usdg), owner, l.cap);
            vm.startPrank(owner);
            usdg.approve(address(OLD), l.cap);
            OLD.reclaim(id, owner);
            OLD.withdrawCollateral(id, owner);
            vm.stopPrank();
            assertEq(uint256(OLD.getLoan(id).state), uint256(V2State.REPAID));
            for (uint8 i; i < 4; ++i) {
                uint256 owed;
                for (uint8 j; j < 4; ++j) {
                    if (holders[i] == holders[j]) owed += l.cap / 4 + (j < l.cap % 4 ? 1 : 0);
                }
                assertEq(OLD.cashCredit(holders[i]), credits[i] + owed);
            }
        }
        assertGt(active, 0, "The deployed engine must hold an active loan at the rotation");
        uint256 id = _open();
        _sell(id);
        deal(address(usdg), borrower, 110e6);
        vm.startPrank(borrower);
        usdg.approve(address(next), 110e6);
        next.reclaim(id, borrower);
        next.withdrawCollateral(id, borrower);
        vm.stopPrank();
        assertEq(next.cashCredit(buyer), 55e6);
        assertEq(next.cashCredit(lender), 106_480_000);
        address[] memory holders = new address[](4);
        (holders[0], holders[1], holders[2], holders[3]) = (borrower, lender, buyer, next.FEE_RECIPIENT());
        assertEq(usdg.balanceOf(address(next)), next.cashOwed(holders));
    }

    function testLiveRotation_newSaleUsesExistingEmissionSourceAndPreservesEarnedClaims() public {
        _rotate();
        // Simulate a future epoch with positive rates; no sGAGE is minted or seeded.
        DealRewards source = bridge.REWARDS();
        uint256 epoch = source.EMISSIONS().currentEpoch() + 1;
        vm.warp(uint256(source.EMISSIONS().epochStart(epoch)) + 60);
        vm.prank(source.owner());
        source.setEpochRates(epoch, 100e18, 100e18, 1, 5000);
        uint256 id = _open();
        V2Loan memory l = next.getLoan(id);
        assertGt(l.lenderReward, 0);
        vm.warp(uint256(l.fundedAt) + l.term / 2);
        uint256 retained = next.REWARDS().claimable(id, lender);
        _sell(id);
        assertEq(next.REWARDS().claimable(id, lender), retained);
        assertEq(next.REWARDS().claimable(id, buyer), 0);
        GageV2Rewards nextRewards = next.REWARDS();
        vm.prank(lender);
        nextRewards.claim(id, lender);
        vm.warp(uint256(l.fundedAt) + uint256(l.term) * 3 / 4);
        deal(address(usdg), borrower, l.cap);
        vm.startPrank(borrower);
        usdg.approve(address(next), l.cap);
        next.reclaim(id, borrower);
        vm.stopPrank();
        uint256 sum;
        address[3] memory parties = [borrower, lender, buyer];
        for (uint8 i; i < 3; ++i) {
            sum += next.SGAGE().balanceOf(parties[i]) + nextRewards.claimable(id, parties[i]);
            if (nextRewards.claimable(id, parties[i]) > 0) {
                vm.prank(parties[i]);
                nextRewards.claim(id, parties[i]);
            }
        }
        assertEq(sum, uint256(l.borrowerReward) * 9 / 16 + uint256(l.lenderReward) * 9 / 16);
        assertEq(next.SGAGE().balanceOf(address(next.REWARDS())), 0);
        for (uint8 i; i < 3; ++i) {
            assertEq(nextRewards.claimable(id, parties[i]), 0);
        }
    }
}
