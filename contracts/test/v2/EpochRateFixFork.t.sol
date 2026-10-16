// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";

/// @dev Actual deployed V2 and legacy contracts. Only test capital, owner calls and time are local simulations.
contract EpochRateFixForkTest is Test {
    DealRewards constant REWARDS = DealRewards(0x5B95978dbE6193E9510aff8a8d78A92d84e6340d);
    GageV2Vault constant VAULT = GageV2Vault(0x22658055B70b8B09616B1e0953f2A51cc66cF493);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant SPY = IERC20(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C);
    uint128 constant RATE = uint128(uint256(5e23) / 167);
    address borrower;
    address lender;
    /// @dev The epoch after the fork block's current one. It receives the corrected rates in advance, as the keeper
    ///      posts next week's rates, and one test stops them while it is current.
    uint256 rateEpoch;
    /// @dev The epoch after `rateEpoch`, posted at zero as the keeper's scheduled stop.
    uint256 stopEpoch;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_V2_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_V2_FORK_BLOCK"));
        borrower = makeAddr("epoch fix borrower");
        lender = makeAddr("epoch fix lender");
        deal(address(SPY), borrower, 10e18);
        deal(address(USDG), borrower, 1000e6);
        deal(address(USDG), lender, 1000e6);
        // Both epochs are relative to the fork block, because rates for an epoch already past revert
        // RatesForPastEpoch (DealRewards.sol:103).
        rateEpoch = REWARDS.EMISSIONS().currentEpoch() + 1;
        stopEpoch = rateEpoch + 1;
        assertLt(stopEpoch, REWARDS.EMISSIONS().WEEKS());
        vm.startPrank(REWARDS.owner());
        REWARDS.setEpochRates(stopEpoch, 0, 0, 167, 5000);
        REWARDS.setEpochRates(rateEpoch, RATE, RATE, 167, 5000);
        vm.stopPrank();
        // Mainnet has since moved originations to a newer engine: this engine's registry pauses new deals and the
        // adapter selects the successor. Their real owners select this engine again on the local fork, so loans keep
        // opening through the deployed V2 engine and legacy adapter under test.
        GageV2Registry registry = GageV2Registry(address(VAULT.REGISTRY()));
        vm.prank(registry.owner());
        registry.pauseNewDeals(false);
        GageLegacyAdapter bridge = VAULT.BRIDGE();
        vm.prank(bridge.ADMIN());
        bridge.setEngine(address(VAULT));
        vm.prank(borrower);
        SPY.approve(address(VAULT), type(uint256).max);
        vm.prank(borrower);
        USDG.approve(address(VAULT), type(uint256).max);
        vm.prank(lender);
        USDG.approve(address(VAULT), type(uint256).max);
    }

    function _open(uint32 term) internal returns (uint256 id) {
        vm.prank(borrower);
        id = VAULT.list(
            Collateral(Kind.ERC20, address(SPY), 1e18), 90e6, 100e6, term, uint40(block.timestamp + 1 days), true
        );
        vm.prank(lender);
        VAULT.fund(id, 4);
        assertEq(uint256(VAULT.getLoan(id).state), uint256(V2State.ACTIVE));
    }

    function testCorrectedSevenDayLoanPreservesEarnedRewardsAfterRateStop() public {
        vm.warp(REWARDS.EMISSIONS().epochStart(rateEpoch) + 1);
        uint256 id = _open(7 days);
        V2Loan memory loan = VAULT.getLoan(id);
        assertEq(uint256(loan.borrowerReward) + loan.lenderReward, uint256(loan.originationFee) * RATE / 1e6);
        vm.warp(uint256(loan.fundedAt) + 3 days);
        uint256 earned = VAULT.REWARDS().claimable(id, borrower);
        assertGt(earned, 0);
        vm.prank(REWARDS.owner());
        REWARDS.setEpochRates(rateEpoch, 0, 0, 167, 5000);
        assertEq(VAULT.REWARDS().claimable(id, borrower), earned);
        vm.startPrank(borrower);
        VAULT.reclaim(id, borrower);
        VAULT.withdrawCollateral(id, borrower);
        vm.stopPrank();
        uint256 before = VAULT.SGAGE().balanceOf(borrower);
        GageV2Rewards ledger = VAULT.REWARDS();
        vm.prank(borrower);
        ledger.claim(id, borrower);
        assertEq(VAULT.SGAGE().balanceOf(borrower) - before, earned);
        assertEq(SPY.balanceOf(borrower), 10e18);
    }

    function testCorrectedTwentyOneDayLoanGetsBoundedAllocation() public {
        vm.warp(REWARDS.EMISSIONS().epochStart(rateEpoch) + 1);
        uint256 id = _open(21 days);
        V2Loan memory loan = VAULT.getLoan(id);
        assertEq(uint256(loan.borrowerReward) + loan.lenderReward, uint256(loan.originationFee) * RATE / 1e6);
        vm.prank(borrower);
        VAULT.reclaim(id, borrower);
        vm.prank(borrower);
        VAULT.withdrawCollateral(id, borrower);
        assertEq(SPY.balanceOf(borrower), 10e18);
    }

    function testZeroEpochStillFundsRepaysAndWithdraws() public {
        vm.warp(REWARDS.EMISSIONS().epochStart(stopEpoch) + 1);
        uint256 id = _open(7 days);
        V2Loan memory loan = VAULT.getLoan(id);
        assertEq(loan.borrowerReward, 0);
        assertEq(loan.lenderReward, 0);
        vm.prank(borrower);
        VAULT.withdrawUSDG(borrower);
        assertEq(USDG.balanceOf(borrower), 1000e6 + loan.principal - loan.originationFee);
        vm.prank(borrower);
        VAULT.reclaim(id, borrower);
        vm.prank(borrower);
        VAULT.withdrawCollateral(id, borrower);
        vm.prank(lender);
        VAULT.withdrawUSDG(lender);
        assertEq(SPY.balanceOf(borrower), 10e18);
        assertEq(USDG.balanceOf(lender), 1000e6 - loan.principal + loan.cap);
        assertEq(uint256(VAULT.getLoan(id).state), uint256(V2State.REPAID));
    }
}
