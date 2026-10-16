// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDealVault, DealState} from "../../src/interfaces/IDealVault.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {DealVault} from "../../src/DealVault.sol";
import {IEmissions} from "../../src/interfaces/token/IEmissions.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {GageLegacyParty} from "../../src/v2/GageLegacyParty.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {V2Loan, V2State, V2Ask} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {GageV2ForkTest} from "./GageV2Fork.t.sol";
import {LegacyAdmissionSnapshot} from "./research/LegacyAdmissionSnapshot.sol";
import {cashOwed} from "../helpers/CoreCash.sol";

using {cashOwed} for GageV2Vault;

/// @notice Full production engine against actual legacy emissions and actual v3/v4 pools.
/// @dev Only USDG/collateral test capital is seeded; sGAGE always comes from the existing mainnet reserve.
contract GageV2BridgedForkTest is GageV2ForkTest {
    IDealVault constant LEGACY = IDealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
    CollateralRegistry constant OLD_REGISTRY = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
    DealRewards constant OLD_REWARDS = DealRewards(0x5B95978dbE6193E9510aff8a8d78A92d84e6340d);
    GageLegacyAdapter internal bridge;

    function _bridge() internal override returns (GageLegacyAdapter) {
        bridge = new GageLegacyAdapter(address(this), LEGACY, OLD_REWARDS, IERC20(USDG));
        address[] memory tokens = LegacyAdmissionSnapshot.tokens();
        bytes32[] memory pools = LegacyAdmissionSnapshot.pools();
        vm.startPrank(OLD_REGISTRY.owner());
        OLD_REGISTRY.pauseNewDeals(true);
        for (uint256 i; i < tokens.length; ++i) {
            OLD_REGISTRY.setERC20Allowed(tokens[i], false, Lane.STOCK, 0, 0, 0);
        }
        for (uint256 i; i < pools.length; ++i) {
            OLD_REGISTRY.setPoolAllowed(pools[i], false, 0);
        }
        OLD_REGISTRY.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        OLD_REGISTRY.pauseNewDeals(false);
        vm.stopPrank();
        return bridge;
    }

    function _configureRewards() internal virtual override {
        bridge.setEngine(address(vault));
    }

    /// @dev Production shape: the engine has no grace window while the legacy vault keeps its 48 hours.
    function _grace() internal pure override returns (uint32) {
        return 0;
    }

    /// @dev Stops the current epoch from the reward owner the way the keeper holds an epoch at zero. Live mainnet may
    ///      already fund the current epoch, so a fork cannot rely on it having no allocation. The current epoch is
    ///      not a past epoch, so `setEpochRates` accepts it (src/token/DealRewards.sol:103).
    function _zeroEpoch() internal {
        uint256 epoch = OLD_REWARDS.EMISSIONS().currentEpoch();
        vm.prank(OLD_REWARDS.owner());
        OLD_REWARDS.setEpochRates(epoch, 0, 0, 1, 5000);
        assertEq(OLD_REWARDS.effectiveRates(epoch).rate7, 0);
    }

    function _nextEpoch() internal {
        uint256 epoch = OLD_REWARDS.EMISSIONS().currentEpoch() + 1;
        vm.warp(uint256(OLD_REWARDS.EMISSIONS().epochStart(epoch)) + 60);
        // The keeper posts a future epoch's rates late and holds them at zero as a stop, so a fork of live state
        // may have no allocation to test with; give this epoch and the next a positive schedule from the reward owner.
        for (uint256 e = epoch; e <= epoch + 1; ++e) {
            if (OLD_REWARDS.effectiveRates(e).rate7 == 0) {
                vm.prank(OLD_REWARDS.owner());
                OLD_REWARDS.setEpochRates(e, 100e18, 100e18, 1, 5000);
            }
        }
    }

    function _repay(uint256 id, address owner) internal {
        uint128 cap = vault.getLoan(id).cap;
        deal(USDG, owner, cap);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(vault), cap);
        vault.reclaim(id, owner);
        vault.withdrawCollateral(id, owner);
        vm.stopPrank();
    }

    /// @dev The engine holds exactly what it owes: the credits of this suite's accounts (borrower, buyer, lenders and
    /// the fee recipient) plus the contributions of loans still funding.
    function _cashBacked() internal view {
        address[] memory holders = new address[](7);
        (holders[0], holders[1], holders[2]) = (borrower, buyer, vault.FEE_RECIPIENT());
        for (uint256 i; i < 4; ++i) {
            holders[3 + i] = lender[i];
        }
        assertEq(IERC20(USDG).balanceOf(address(vault)), vault.cashOwed(holders));
        assertEq(IERC20(USDG).balanceOf(address(bridge)), 0);
    }

    function testBridge_actualFourthQuarterChargesLegacyFeeOnce() public {
        uint256 oldCount = LEGACY.dealCount();
        address feeSink = DealVault(address(LEGACY)).FEE_SINK();
        uint256 oldFees = LEGACY.balanceUSDG(feeSink);
        vm.startPrank(borrower);
        IERC20(SPY).approve(address(vault), 1e18);
        uint256 id =
            vault.list(Collateral(Kind.ERC20, SPY, 1e18), 90e6, 100e6, 7 days, uint40(block.timestamp + 1 days), false);
        vm.stopPrank();
        vm.prank(lender[0]);
        vault.fund(id, 3);
        assertEq(bridge.loanCount(), 0);
        assertEq(LEGACY.dealCount(), oldCount);
        assertEq(vault.cashCredit(borrower), 0);
        vm.prank(lender[1]);
        vault.fund(id, 1);
        assertEq(bridge.loanCount(), 1);
        assertEq(LEGACY.dealCount(), oldCount + 1);
        assertEq(vault.cashCredit(borrower), 89_100_000);
        assertEq(LEGACY.balanceUSDG(feeSink) - oldFees, 900_000);
        assertEq(vault.cashCredit(BUYBACK), 0);
        _cashBacked();
        _repay(id, borrower);
        assertEq(vault.cashCredit(lender[0]), 75e6);
        assertEq(vault.cashCredit(lender[1]), 25e6);
        assertEq(bridge.totalSupply(), 0);
        _cashBacked();
    }

    function testBridge_detailedCashoutReturnsExactWalletAndFeeDeltas() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        GageV2CashoutRouter.Exit memory x = _spyExit(id);
        uint256 borrowerBefore = IERC20(USDG).balanceOf(borrower);
        uint256 feeBefore = IERC20(USDG).balanceOf(BUYBACK);
        uint256 flashBefore = IERC20(USDG).balanceOf(FLASH);
        vm.prank(borrower);
        (uint256 gross, uint256 financing, uint256 fee, uint256 net) = router.cashOutDetailed(x);
        assertEq(IERC20(USDG).balanceOf(borrower) - borrowerBefore, net);
        assertEq(IERC20(USDG).balanceOf(BUYBACK) - feeBefore, fee);
        assertEq(IERC20(USDG).balanceOf(FLASH) - flashBefore, financing);
        assertEq(gross, 100e6 + financing + fee + net);
        assertEq(fee, (gross - 100e6 - financing) * 50 / 10_000);
        _cashBacked();
    }

    function testBridge_zeroNowNewEpochEarnsAndOriginalZeroStaysZero() public {
        _zeroEpoch();
        uint256 first = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        assertEq(vault.getLoan(first).borrowerReward, 0);
        _nextEpoch();
        uint256 second = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        assertGt(vault.getLoan(second).borrowerReward, 0);
        vm.warp(block.timestamp + 7 days);
        GageV2Rewards r = vault.REWARDS();
        vm.prank(borrower);
        r.claim(second, borrower);
        assertEq(IERC20(SGAGE).balanceOf(borrower), vault.getLoan(second).borrowerReward);
        assertEq(vault.REWARDS().claimable(first, borrower), 0);
        _cashBacked();
    }

    function testBridge_saleCloseClaimsAndRecyclingPreserveEveryEntitlement() public {
        _nextEpoch();
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        V2Loan memory l = vault.getLoan(id);
        uint256 source = bridge.adapterId(address(vault), id);
        vm.warp(uint256(l.fundedAt) + l.term / 2);
        vm.prank(borrower);
        vault.setAskWithMaxFee(id, 20e6, uint40(block.timestamp + 1 hours), type(uint16).max);
        V2Ask memory ask = vault.getAsk(id);
        vm.prank(buyer);
        vault.buy(id, borrower, ask.nonce, ask.price, 100, buyer);
        uint256 sellerEarned = uint256(l.borrowerReward) / 4;
        assertEq(vault.REWARDS().claimable(id, borrower), sellerEarned);
        vm.warp(uint256(l.fundedAt) + uint256(l.term) * 3 / 4);
        _repay(id, buyer);
        uint256 borrowerEarned = uint256(l.borrowerReward) * 9 / 16;
        uint256 lenderEarned = uint256(l.lenderReward) * 9 / 16;
        assertEq(vault.REWARDS().claimable(id, buyer), borrowerEarned - sellerEarned);
        // Future unvested drips cannot become today's liquid recycle budget.
        assertEq(bridge.recycle(source), 0);
        vm.warp(uint256(l.fundedAt) + l.term);
        uint256 recycled = bridge.recycle(source);
        assertEq(recycled, uint256(l.borrowerReward) + l.lenderReward - borrowerEarned - lenderEarned);
        GageV2Rewards r = vault.REWARDS();
        vm.prank(borrower);
        r.claim(id, borrower);
        vm.prank(buyer);
        r.claim(id, buyer);
        uint256 paid = IERC20(SGAGE).balanceOf(borrower) + IERC20(SGAGE).balanceOf(buyer);
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            r.claim(id, lender[i]);
            paid += IERC20(SGAGE).balanceOf(lender[i]);
        }
        assertEq(paid, borrowerEarned + lenderEarned);
        assertEq(bridge.loan(source).liquid, 0);
        assertEq(IERC20(SGAGE).balanceOf(address(bridge)), bridge.recycledFree());
        assertEq(IERC20(SGAGE).balanceOf(address(r)), 0);
        assertEq(bridge.loan(source).paid, borrowerEarned + lenderEarned);
        _cashBacked();
    }

    function testBridge_zeroGraceDefaultFinalizesAtMaturityAndTheLegacyDealSettlesLater() public {
        _nextEpoch();
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        V2Loan memory l = vault.getLoan(id);
        uint256 source = bridge.adapterId(address(vault), id);
        uint256 legacyId = bridge.loan(source).legacyId;
        uint256 maturity = uint256(l.fundedAt) + l.term;
        uint40 legacyClaimable = LEGACY.claimableAt(legacyId);
        assertEq(legacyClaimable, maturity + LEGACY.GRACE());
        vm.warp(maturity - 1);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.finalizeDefault(id);
        vm.warp(maturity);
        deal(USDG, borrower, l.cap);
        vm.startPrank(borrower);
        IERC20(USDG).approve(address(vault), l.cap);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.reclaim(id, borrower);
        vm.stopPrank();
        vault.finalizeDefault(id);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.DEFAULTED));
        assertEq(bridge.loan(source).closedAt, maturity);
        assertEq(uint256(LEGACY.getDeal(legacyId).state), uint256(DealState.FUNDED));
        assertEq(bridge.totalSupply(), 1, "the receipt waits in the legacy vault");
        // The lenders take the real collateral now; the receipt behind the legacy deal is not in their way.
        vm.prank(lender[0]);
        vault.recoverDefault(id, 0, 0, block.timestamp);
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            vault.withdrawRecovery(id, 0, lender[i]);
            assertEq(IERC20(SPY).balanceOf(lender[i]), 0.25e18);
        }
        // Nothing can repay the legacy deal any more, and nobody can settle it before its own grace ends.
        vm.prank(address(vault));
        vm.expectRevert(GageLegacyAdapter.InvalidLoan.selector);
        bridge.repay(id);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, legacyClaimable));
        bridge.settleLegacy(source);
        vm.warp(legacyClaimable);
        vm.prank(buyer);
        bridge.settleLegacy(source);
        assertEq(uint256(LEGACY.getDeal(legacyId).state), uint256(DealState.CLAIMED));
        assertEq(bridge.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, legacyId));
        bridge.settleLegacy(source);
        // The whole allocation vested over the term and is paid from the existing reserve once its drips mature.
        vm.warp(block.timestamp + 7 days);
        GageV2Rewards r = vault.REWARDS();
        uint256 paid;
        vm.prank(borrower);
        r.claim(id, borrower);
        paid += IERC20(SGAGE).balanceOf(borrower);
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            r.claim(id, lender[i]);
            paid += IERC20(SGAGE).balanceOf(lender[i]);
        }
        assertEq(paid, uint256(l.borrowerReward) + l.lenderReward);
        assertGt(paid, 0);
        _cashBacked();
    }

    function testBridge_lateFinalizeSettlesTheLegacyDealInTheSameCall() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        V2Loan memory l = vault.getLoan(id);
        uint256 source = bridge.adapterId(address(vault), id);
        uint256 legacyId = bridge.loan(source).legacyId;
        vm.warp(uint256(l.fundedAt) + l.term + LEGACY.GRACE());
        vault.finalizeDefault(id);
        assertEq(uint256(LEGACY.getDeal(legacyId).state), uint256(DealState.CLAIMED));
        assertEq(bridge.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, legacyId));
        bridge.settleLegacy(source);
        _cashBacked();
    }

    function testBridge_adapterAcceptsEnginesOfAnyGraceUpToTheEngineBound() public {
        GageV2TokenRegistry registry_ = vault.REGISTRY();
        (IERC20 cash, IERC20 reward) = (vault.USDG(), vault.SGAGE());
        GageV2Vault day = new GageV2Vault(registry_, cash, reward, BUYBACK, 1 days, bridge);
        bridge.setEngine(address(day));
        GageV2Vault week = new GageV2Vault(registry_, cash, reward, BUYBACK, 7 days, bridge);
        bridge.setEngine(address(week));
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(registry_, cash, reward, BUYBACK, 7 days + 1, bridge);
        bridge.setEngine(address(vault));
        assertEq(bridge.activeEngine(), address(vault));
    }

    function testBridge_engineRotationCannotRedirectOldCollateralOrOldRewards() public {
        _nextEpoch();
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        GageV2Vault next =
            new GageV2Vault(vault.REGISTRY(), vault.USDG(), vault.SGAGE(), BUYBACK, vault.GRACE(), bridge);
        bridge.setEngine(address(next));
        vm.expectRevert(GageLegacyAdapter.NotAuthorized.selector);
        vm.prank(address(next));
        bridge.repay(id);
        address account = vault.getLoan(id).account;
        vm.expectRevert(GageLegacyAdapter.NotAuthorized.selector);
        vm.prank(address(vault));
        bridge.open(999, account, 90e6, 100e6, 7 days, 900_000);
        vm.warp(block.timestamp + 3 days);
        _repay(id, borrower);
        GageV2Rewards r = vault.REWARDS();
        vm.prank(borrower);
        r.claim(id, borrower);
        assertGt(IERC20(SGAGE).balanceOf(borrower), 0);
        assertEq(bridge.loan(bridge.adapterId(address(vault), id)).engine, address(vault));
        assertEq(bridge.activeEngine(), address(next));
        _cashBacked();
    }

    function testBridge_outsidersCannotAdministerIssueReceiptsClaimSourceOrControlClones() public {
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        GageLegacyAdapter.Loan memory l = bridge.loan(bridge.adapterId(address(vault), id));
        address account = vault.getLoan(id).account;
        vm.startPrank(buyer);
        vm.expectRevert(GageLegacyAdapter.NotAuthorized.selector);
        bridge.setEngine(address(0));
        vm.expectRevert(GageLegacyAdapter.NotAuthorized.selector);
        bridge.open(1, account, 90e6, 100e6, 7 days, 900_000);
        vm.expectRevert(GageLegacyAdapter.NotAuthorized.selector);
        bridge.pay(1, 1);
        vm.expectRevert(GageLegacyParty.NotAdapter.selector);
        GageLegacyParty(l.borrower).repay(l.legacyId, 100e6);
        vm.expectRevert(GageLegacyAdapter.RestrictedReceipt.selector);
        bridge.transfer(borrower, 1);
        vm.stopPrank();
        _cashBacked();
    }

    function testBridge_sameBlockClosureEarnsZeroEvenAfterDripsMature() public {
        _nextEpoch();
        uint256 total;
        for (uint8 i; i < 5; ++i) {
            uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
            V2Loan memory l = vault.getLoan(id);
            total += uint256(l.borrowerReward) + l.lenderReward;
            _repay(id, borrower);
            assertEq(vault.REWARDS().claimable(id, borrower), 0);
        }
        vm.warp(block.timestamp + 7 days);
        for (uint256 id = 1; id <= 5; ++id) {
            bridge.recycle(id);
        }
        assertEq(bridge.recycledFree(), total);
        assertEq(IERC20(SGAGE).balanceOf(borrower), 0);
        assertEq(IERC20(SGAGE).balanceOf(address(bridge)), total);
        _cashBacked();
    }

    /// @dev Reads the clock through the cheatcode: under via-IR the optimizer folds repeated `block.timestamp`
    ///      arithmetic within one call, so a second `vm.warp(block.timestamp + 7 days)` would warp nowhere.
    function testBridge_newAllocationCanUseRecycledRewardsWithoutAnotherReserveWithdrawal() public {
        _nextEpoch();
        uint256 id = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        _repay(id, borrower);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 free = bridge.recycle(bridge.adapterId(address(vault), id));
        assertGt(free, 0);
        // Exhaustion is achieved via the real reserve API on the local fork, not by seeding any sGAGE.
        uint256 epoch = OLD_REWARDS.EMISSIONS().currentEpoch();
        uint256 remaining = OLD_REWARDS.EMISSIONS().remaining(epoch, 7 days);
        if (!OLD_REWARDS.EMISSIONS().released(epoch)) OLD_REWARDS.EMISSIONS().release(epoch);
        IEmissions emissions = OLD_REWARDS.EMISSIONS();
        vm.prank(address(OLD_REWARDS));
        emissions.reserve(epoch, 7 days, remaining, address(0x1234));
        uint256 beforeReserve = IERC20(SGAGE).balanceOf(address(OLD_REWARDS.EMISSIONS()));
        uint256 second = _open(Collateral(Kind.ERC20, SPY, 1e18), 100e6);
        V2Loan memory l = vault.getLoan(second);
        assertGt(l.borrowerReward, 0);
        assertEq(IERC20(SGAGE).balanceOf(address(OLD_REWARDS.EMISSIONS())), beforeReserve);
        assertEq(free - bridge.recycledFree(), uint256(l.borrowerReward) + l.lenderReward);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        GageV2Rewards r = vault.REWARDS();
        vm.prank(borrower);
        r.claim(second, borrower);
        assertEq(IERC20(SGAGE).balanceOf(borrower), l.borrowerReward);
    }
}
