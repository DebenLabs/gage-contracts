// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {GageV2TokenCollateralAccount} from "../../src/v2/GageV2TokenCollateralAccount.sol";
import {V2Loan, V2State, V2Ask} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";
import {cashOwed} from "../helpers/CoreCash.sol";
import {rewardsOwed} from "../helpers/RewardsOwed.sol";

using {unitsOf, cashOwed} for GageV2Vault;

/// @dev The engine fixture every core suite shares; the core's own cases are in `GageV2VaultTest` below, so a suite
/// that inherits only this fixture does not run them again.
abstract contract GageV2VaultBase is Test {
    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal stock;
    GageV2TokenRegistry internal registry;
    GageV2Vault internal vault;
    GageV2Rewards internal rewards;
    address internal borrower = makeAddr("borrower");
    address internal buyer = makeAddr("buyer");
    address internal fees = makeAddr("fees");
    address[4] internal lender;
    uint32 internal constant TERM = 7 days;
    uint32 internal constant GRACE = 1 days;

    function setUp() public virtual {
        vm.warp(10_000);
        usdg = new MockERC20("test USDG", "tUSDG", 6);
        sgage = new MockERC20("test sGAGE", "tsGAGE", 18);
        stock = new MockERC20("test stock", "tSTOCK", 18);
        uint32[] memory terms = new uint32[](1);
        terms[0] = TERM;
        registry = new GageV2TokenRegistry(address(this), terms, address(this));
        registry.setERC20Allowed(address(stock), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        registry.setRewardTerms(TERM, 100e18, 1, 5000);
        _deployVault(address(0), address(0));
        for (uint8 i; i < 4; ++i) {
            lender[i] = makeAddr(string(abi.encodePacked("lender", i)));
            usdg.mint(lender[i], 1_000_000e6);
        }
        usdg.mint(borrower, 1_000_000e6);
        usdg.mint(buyer, 1_000_000e6);
        stock.mint(borrower, 1_000_000e18);
        _approveVault();
    }

    /// @dev Every actor approves the current vault; call again after a redeploy.
    function _approveVault() internal {
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            usdg.approve(address(vault), type(uint256).max);
        }
        vm.startPrank(borrower);
        usdg.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(buyer);
        usdg.approve(address(vault), type(uint256).max);
    }

    function _deployVault(address v3, address v4) internal {
        _deployVault(v3, v4, GRACE);
    }

    /// @dev An engine lends to no one until a funder gate is bound (D47). These suites are about lending itself, so
    /// they bind a gate that names every account; a suite about the gate opts out and binds its own.
    function _opensToEveryone() internal view virtual returns (bool) {
        return true;
    }

    function _openToEveryone() internal {
        if (!_opensToEveryone()) return;
        // Deployed from its own address, so the fixture's later deployments keep the addresses they always had.
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate open = new MockOpenFunderGate();
        rewards.bindFunderGate(open);
    }

    /// @dev The position managers are ignored: the core admits tokens only and validates them itself (CORE-b-20).
    function _deployVault(address, address, uint32 grace) internal {
        vault = _newVault(fees, grace);
        rewards = vault.REWARDS();
        _openToEveryone();
        sgage.mint(address(this), 1_000_000e18);
        sgage.approve(address(rewards), type(uint256).max);
        rewards.fund(1_000_000e18);
    }

    /// @dev A core over the fixture's registry and tokens.
    function _newVault(address feeRecipient, uint32 grace) internal returns (GageV2Vault) {
        return new GageV2Vault(
            registry, IERC20(address(usdg)), IERC20(address(sgage)), feeRecipient, grace, GageLegacyAdapter(address(0))
        );
    }

    function _list(uint128 principal, uint128 cap, uint256 amount) internal returns (uint256 id) {
        vm.prank(borrower);
        return vault.list(
            Collateral(Kind.ERC20, address(stock), amount), principal, cap, TERM, uint40(block.timestamp + 1 days), true
        );
    }

    function _active() internal returns (uint256 id) {
        id = _list(1000e6, 1100e6, 100e18);
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            vault.fund(id, 1);
        }
    }

    function _trade(uint256 id, address seller, address receiver) internal {
        vm.prank(seller);
        vault.setAskWithMaxFee(id, 200e6, uint40(block.timestamp + 1 hours), type(uint16).max);
        V2Ask memory ask = vault.getAsk(id);
        vm.prank(buyer);
        vault.buy(id, seller, ask.nonce, 200e6, 100, receiver);
    }

    /// @dev Accounts a suite adds to the fixture's credit holders (borrower, buyer, fee recipient, lenders).
    function _extraCashHolders() internal view virtual returns (address[] memory) {
        return new address[](0);
    }

    /// @dev The fixture's actors (borrower, buyer, fee recipient, lenders) and the suite's extra holders.
    function _holders() internal view returns (address[] memory holders) {
        address[] memory extra = _extraCashHolders();
        holders = new address[](7 + extra.length);
        (holders[0], holders[1], holders[2]) = (borrower, buyer, fees);
        for (uint256 i; i < 4; ++i) {
            holders[3 + i] = lender[i];
        }
        for (uint256 i; i < extra.length; ++i) {
            holders[7 + i] = extra[i];
        }
    }

    /// @dev The core holds exactly what it owes: every account's credit plus the contributions of loans still
    /// funding. Any credit left out of the holders, or any leak, breaks the equality.
    function _assertCash() internal view {
        assertEq(usdg.balanceOf(address(vault)), vault.cashOwed(_holders()));
    }

    /// @dev The ledger's outstanding reward liability: the holders' claimable rewards plus the unearned remainder of
    /// every open allocation (the former `reserved` total).
    function _rewardsOwed() internal view returns (uint256) {
        return rewardsOwed(rewards, vault.loanCount(), _holders());
    }

    /// @dev The ledger holds exactly its free budget plus what it owes. Any reward left out of the holders, or any
    /// leak, breaks the equality.
    function _assertRewards() internal view {
        assertEq(sgage.balanceOf(address(rewards)), rewards.freeBudget() + _rewardsOwed());
    }
}

contract GageV2VaultTest is GageV2VaultBase {
    function test_accrualEndFreezesOnlyAtRepayment() public {
        uint256 repaid = _active();
        uint256 defaulted = _active();
        uint256 funding = _list(1000e6, 1100e6, 100e18);
        vm.warp(block.timestamp + 2 days);
        assertEq(vault.accrualEnd(repaid), block.timestamp);
        assertEq(vault.accrualEnd(funding), block.timestamp);
        vm.prank(borrower);
        vault.reclaim(repaid, borrower);
        uint256 closedAt = vault.getLoan(repaid).closedAt;
        assertEq(vault.accrualEnd(repaid), closedAt);

        vm.warp(uint256(vault.getLoan(defaulted).fundedAt) + TERM + GRACE);
        vault.finalizeDefault(defaulted);
        assertEq(vault.accrualEnd(repaid), closedAt);
        assertEq(vault.accrualEnd(defaulted), block.timestamp, "the caller keeps its own maturity cap");
        assertEq(vault.accrualEnd(funding), block.timestamp);
        _assertCash();
    }

    function test_onlyFourthUnitStartsClockProceedsFeesAndRewards() public {
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vault.fund(id, 3);
        vm.warp(block.timestamp + 12 hours);
        V2Loan memory l = vault.getLoan(id);
        assertEq(uint256(l.state), uint256(V2State.FUNDING));
        assertEq(l.fundedAt, 0);
        assertEq(vault.cashCredit(borrower), 0);
        assertEq(vault.cashCredit(fees), 0);
        assertEq(rewards.claimable(id, lender[0]), 0);
        vm.prank(lender[1]);
        vault.fund(id, 1);
        l = vault.getLoan(id);
        assertEq(l.fundedAt, block.timestamp);
        assertEq(vault.cashCredit(borrower), 990e6);
        assertEq(vault.cashCredit(fees), 10e6);
        assertEq(vault.unitsOf(id, lender[0]), 3);
        _assertCash();
        _assertRewards();
    }

    function test_withdrawRefillCancelRefundsExactlyAndPausePreservesExits() public {
        uint256 id = _list(1000e6 + 3, 1100e6, 100e18);
        vm.prank(lender[0]);
        vault.fund(id, 2);
        vm.prank(lender[1]);
        vault.fund(id, 1);
        vm.prank(lender[0]);
        vault.withdrawCommitment(id);
        assertEq(vault.cashCredit(lender[0]), 500e6 + 2);
        vm.prank(lender[2]);
        vault.fund(id, 1);
        registry.pauseNewDeals(true);
        vm.prank(borrower);
        vault.cancelFunding(id);
        assertEq(vault.cashCredit(lender[1]), 250e6 + 1);
        assertEq(vault.cashCredit(lender[2]), 250e6 + 1);
        vm.prank(borrower);
        vault.withdrawCollateral(id, borrower);
        assertEq(stock.balanceOf(borrower), 1_000_000e18);
        for (uint8 i; i < 3; ++i) {
            vault.withdrawUSDGFor(lender[i]);
        }
        assertEq(usdg.balanceOf(address(vault)), 0);
        _assertCash();
    }

    function test_timeoutAnyoneRefundsButCannotTakeCollateral() public {
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vault.fund(id, 1);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.cancelFunding(id);
        vm.warp(block.timestamp + 1 days);
        vault.cancelFunding(id);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.withdrawCollateral(id, buyer);
        vault.withdrawUSDGFor(lender[0]);
        assertEq(usdg.balanceOf(address(vault)), 0);
    }

    /// @dev The core checks only the caller against `collateralBeneficiary`, which is recorded on entering REPAID or
    /// CANCELLED. The originator of a funding, active or defaulted loan is refused, and so is anyone on an unknown id.
    function test_withdrawCollateralOnlyForTheRecordedBeneficiary() public {
        uint256 funding = _list(1000e6, 1100e6, 100e18);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.withdrawCollateral(funding, borrower);
        uint256 id = _active();
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.withdrawCollateral(id, borrower);
        vm.warp(block.timestamp + TERM + GRACE);
        vault.finalizeDefault(id);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.withdrawCollateral(id, borrower);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.withdrawCollateral(id + 1, borrower);
    }

    /// @dev The cash-out router's path: a right exercised for another beneficiary, which then takes the whole
    /// collateral with `withdrawCollateral`, once.
    function test_withdrawCollateralPaysAnotherBeneficiaryTheWholeCollateralOnce() public {
        address router = makeAddr("router");
        uint256 id = _active();
        vm.prank(borrower);
        vault.reclaim(id, router);
        address account = vault.getLoan(id).account;
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.NotAuthorized.selector);
        vault.withdrawCollateral(id, borrower);
        vm.expectEmit(address(vault));
        emit GageV2Vault.CollateralWithdrawn(id, router);
        vm.prank(router);
        vault.withdrawCollateral(id, router);
        assertEq(stock.balanceOf(router), 100e18);
        assertEq(stock.balanceOf(account), 0);
        assertTrue(GageV2TokenCollateralAccount(account).released());
        assertFalse(GageV2TokenCollateralAccount(account).recovered());
        vm.prank(router);
        vm.expectRevert(GageV2TokenCollateralAccount.InvalidState.selector);
        vault.withdrawCollateral(id, router);
        _assertCash();
    }

    function test_tradeChargesOnePercentAndPreservesEarnedRewardAcrossUnclaimedSale() public {
        uint256 id = _active();
        uint256 start = vault.getLoan(id).fundedAt;
        vm.warp(start + TERM / 2);
        _trade(id, borrower, buyer);
        assertEq(vault.ownerOf(id), buyer);
        assertEq(vault.cashCredit(borrower), 990e6 + 198e6);
        assertEq(vault.cashCredit(fees), 10e6 + 2e6);
        assertEq(rewards.claimable(id, borrower), 125e18);
        vm.warp(start + TERM * 4 / 5);
        vm.prank(buyer);
        vault.reclaim(id, buyer);
        assertEq(rewards.claimable(id, borrower), 125e18);
        assertEq(rewards.claimable(id, buyer), 195e18);
        vm.prank(borrower);
        rewards.claim(id, borrower);
        vm.prank(buyer);
        rewards.claim(id, buyer);
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            rewards.claim(id, lender[i]);
        }
        assertEq(rewards.freeBudget(), 1_000_000e18 - 640e18);
        assertEq(_rewardsOwed(), 0);
        _assertCash();
        _assertRewards();
    }

    function test_claimBeforeSaleAndSameAccountBorrowerLenderCannotDoubleClaim() public {
        uint256 id = _list(1000e6, 1100e6, 100e18);
        vm.prank(borrower);
        vault.fund(id, 2);
        vm.prank(lender[0]);
        vault.fund(id, 2);
        uint256 start = vault.getLoan(id).fundedAt;
        vm.warp(start + TERM / 2);
        vm.prank(borrower);
        rewards.claim(id, borrower);
        assertEq(sgage.balanceOf(borrower), 187.5e18);
        _trade(id, borrower, buyer);
        assertEq(rewards.claimable(id, borrower), 0);
        vm.warp(start + TERM);
        vm.prank(buyer);
        vault.reclaim(id, buyer);
        assertEq(rewards.claimable(id, borrower), 187.5e18);
        assertEq(rewards.claimable(id, buyer), 375e18);
        _assertRewards();
    }

    function test_unbridgedLedgerNamesNoBridge() public view {
        assertEq(address(rewards.BRIDGE()), address(0));
        assertEq(rewards.VAULT(), address(vault));
    }

    function test_underfundedRewardBudgetRevertsFourthContributionOnly() public {
        uint256 id = _list(20_000e6, 22_000e6, 100e18);
        // Drain the free budget through a separate valid reservation in a small ledger fixture.
        GageV2Rewards empty = new GageV2Rewards(sgage, GageLegacyAdapter(address(0)));
        vm.expectRevert(GageV2Rewards.InsufficientBudget.selector);
        empty.activate(1, borrower, lender, TERM, 1, 0);
        // The actual vault's last funding call is atomic when its reward allocation cannot be reserved.
        registry.setRewardTerms(TERM, 1_000_000e18, 1, 5000);
        id = _list(1000e6, 1100e6, 100e18);
        vm.prank(lender[0]);
        vault.fund(id, 3);
        uint256 beforeBalance = usdg.balanceOf(lender[1]);
        vm.prank(lender[1]);
        vm.expectRevert(GageV2Rewards.InsufficientBudget.selector);
        vault.fund(id, 1);
        assertEq(usdg.balanceOf(lender[1]), beforeBalance);
        assertEq(vault.getLoan(id).filled, 3);
        vm.prank(lender[0]);
        vault.withdrawCommitment(id);
        _assertCash();
    }

    function test_pausedOrBlockedRewardTokenDoesNotBlockRepaymentOrRecovery() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM / 2);
        sgage.setPaused(true);
        registry.pauseNewDeals(true);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        vm.prank(borrower);
        vault.withdrawCollateral(id, borrower);
        for (uint8 i; i < 4; ++i) {
            vault.withdrawUSDGFor(lender[i]);
        }
        vm.prank(borrower);
        vm.expectRevert(MockERC20.EnforcedPause.selector);
        rewards.claim(id, borrower);
        sgage.setPaused(false);
        vm.prank(borrower);
        rewards.claim(id, borrower);
        _assertRewards();
    }

    function test_fullCapRequiredAndRepaymentReturnsWholeCollateral() public {
        uint256 id = _active();
        vm.prank(borrower);
        usdg.approve(address(vault), 275e6);
        vm.prank(borrower);
        vm.expectRevert();
        vault.reclaim(id, borrower);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        vm.prank(borrower);
        usdg.approve(address(vault), 1100e6);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        for (uint8 i; i < 4; ++i) {
            assertEq(vault.cashCredit(lender[i]), 275e6);
        }
        vm.prank(borrower);
        vault.withdrawCollateral(id, borrower);
        vm.prank(borrower);
        vm.expectRevert();
        vault.withdrawCollateral(id, borrower);
        _assertCash();
    }

    function test_saleNoncePriceFeeAndRecipientAreBoundAndRawTransfersDisabled() public {
        uint256 id = _active();
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.UseMarketplace.selector);
        vault.transferFrom(borrower, buyer, id);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.UseMarketplace.selector);
        vault.safeTransferFrom(borrower, buyer, id);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.UseMarketplace.selector);
        vault.safeTransferFrom(borrower, buyer, id, "");
        vm.prank(borrower);
        vault.setAskWithMaxFee(id, 200e6, uint40(block.timestamp + 100), type(uint16).max);
        V2Ask memory ask = vault.getAsk(id);
        vm.prank(buyer);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vault.buy(id, borrower, ask.nonce, 199e6, 100, buyer);
        vm.prank(buyer);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vault.buy(id, borrower, ask.nonce, 200e6, 99, buyer);
        vm.prank(borrower);
        vault.cancelAsk(id);
        vm.prank(buyer);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        vault.buy(id, borrower, ask.nonce, 200e6, 100, buyer);
        assertEq(vault.ownerOf(id), borrower);
        _assertCash();
    }

    function test_repayClosesTheSecondDefaultOpens() public {
        uint256 id = _active();
        uint256 deadline = block.timestamp + TERM + GRACE;
        vm.warp(deadline - 1);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.finalizeDefault(id);
        vm.warp(deadline);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.setAskWithMaxFee(id, 1e6, uint40(block.timestamp + 1), type(uint16).max);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.reclaim(id, borrower);
        vault.finalizeDefault(id);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.DEFAULTED));
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.WrongState.selector);
        vault.reclaim(id, borrower);
        _assertCash();
    }

    function test_repayOneSecondBeforeTheDeadlineSettlesAndBlocksDefault() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM + GRACE - 1);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(GageV2Vault.WrongState.selector);
        vault.finalizeDefault(id);
        assertEq(vault.cashCredit(lender[0]), 275e6);
        _assertCash();
    }

    function test_zeroGraceEngineSettlesAtTheEndOfTheTerm() public {
        _deployVault(address(0), address(0), 0);
        _approveVault();
        assertEq(vault.GRACE(), 0);
        uint256 id = _active();
        uint256 maturity = uint256(vault.getLoan(id).fundedAt) + TERM;
        vm.warp(maturity - 1);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.finalizeDefault(id);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.setAskWithMaxFee(id, 1e6, uint40(maturity + 1), type(uint16).max);
        vm.warp(maturity);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.reclaim(id, borrower);
        vault.finalizeDefault(id);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.DEFAULTED));
        assertEq(vault.getLoan(id).closedAt, maturity);
        _assertCash();
        _assertRewards();
    }

    function test_constructorBoundsGraceAboveOnly() public {
        uint32 tooLong = vault.MAX_GRACE() + 1;
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        _newVault(fees, tooLong);
        assertEq(_newVault(fees, 0).GRACE(), 0);
        assertEq(_newVault(fees, 7 days).GRACE(), 7 days);
    }

    /// @dev A codeless registry, a zero fee recipient, a shared asset/sGAGE address (of either token's decimals) and
    /// swapped tokens are refused explicitly; a zero or codeless token has no decimals to decode, so construction
    /// reverts without data.
    function test_constructorRefusesABrokenIdentityAndAZeroFeeRecipient() public {
        GageV2TokenRegistry admitted = registry;
        IERC20 cash = IERC20(address(usdg));
        IERC20 reward = IERC20(address(sgage));
        GageLegacyAdapter none = GageLegacyAdapter(address(0));
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(GageV2TokenRegistry(address(0)), cash, reward, fees, 0, none);
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(GageV2TokenRegistry(makeAddr("no code")), cash, reward, fees, 0, none);
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(admitted, cash, reward, address(0), 0, none);
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(admitted, cash, cash, fees, 0, none);
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(admitted, reward, reward, fees, 0, none);
        vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
        new GageV2Vault(admitted, reward, cash, fees, 0, none);
        vm.expectRevert();
        new GageV2Vault(admitted, IERC20(address(0)), reward, fees, 0, none);
        vm.expectRevert();
        new GageV2Vault(admitted, cash, IERC20(makeAddr("no code")), fees, 0, none);
    }

    /// @dev The lent asset may have 6 to 18 decimals (a stock token has 18); outside that range it is refused.
    function test_constructorTakesALentAssetOfSixToEighteenDecimals() public {
        IERC20 reward = IERC20(address(sgage));
        GageLegacyAdapter none = GageLegacyAdapter(address(0));
        for (uint8 d = 5; d <= 19; ++d) {
            IERC20 cash = IERC20(address(new MockERC20("Lent", "LENT", d)));
            if (d < 6 || d > 18) {
                vm.expectRevert(GageV2Vault.InvalidConfiguration.selector);
                new GageV2Vault(registry, cash, reward, fees, 0, none);
            } else {
                assertEq(address(new GageV2Vault(registry, cash, reward, fees, 0, none).USDG()), address(cash));
            }
        }
    }

    function test_defaultProportionateUnderlyingAndIndependentWithdrawals() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM + GRACE);
        vault.finalizeDefault(id);
        // Nothing is claimable before the recovery is recorded, nor for an asset index above 1.
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Vault.NothingToClaim.selector);
        vault.withdrawRecovery(id, 0, lender[0]);
        vm.prank(lender[0]);
        vault.recoverDefault(id, 0, 0, block.timestamp);
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Vault.NothingToClaim.selector);
        vault.withdrawRecovery(id, 2, lender[0]);
        stock.setBlocked(lender[1], true);
        vm.prank(lender[1]);
        vm.expectRevert();
        vault.withdrawRecovery(id, 0, lender[1]);
        for (uint8 i; i < 4; ++i) {
            address recipient = i == 1 ? buyer : lender[i];
            vm.prank(lender[i]);
            vault.withdrawRecovery(id, 0, recipient);
            assertEq(stock.balanceOf(recipient), 25e18);
        }
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Vault.NothingToClaim.selector);
        vault.withdrawRecovery(id, 0, buyer);
        assertEq(stock.balanceOf(vault.getLoan(id).account), 0);
        _assertRewards();
    }

    function testFuzz_partitionsConserveCashAndDefaultUnderlying(uint128 principal, uint128 amount, uint8 first)
        public
    {
        principal = uint128(bound(principal, 4, 1_000_000e6));
        amount = uint128(bound(amount, 1, 1_000_000e18));
        first = uint8(bound(first, 1, 3));
        uint256 id = _list(principal, principal, amount);
        vm.prank(lender[0]);
        vault.fund(id, first);
        vm.prank(lender[1]);
        vault.fund(id, 4 - first);
        vm.warp(block.timestamp + TERM + GRACE);
        vault.finalizeDefault(id);
        vm.prank(lender[0]);
        vault.recoverDefault(id, 0, 0, block.timestamp);
        for (uint8 i; i < 2; ++i) {
            // Zero raw-unit allocations are possible for tiny collateral amounts.
            if (amount >= 4 || (i == 0 || amount > first)) {
                vm.prank(lender[i]);
                vault.withdrawRecovery(id, 0, lender[i]);
            }
        }
        assertEq(stock.balanceOf(lender[0]) + stock.balanceOf(lender[1]), amount);
        _assertCash();
        _assertRewards();
    }

    function test_deploymentSizesRespectEip170() public view {
        assertLe(address(vault).code.length, 24_576);
        // Four constructor arguments are appended to creation code (EIP-3860).
        assertLe(type(GageV2Vault).creationCode.length + 128, 49_152);
        assertLe(address(rewards).code.length, 24_576);
        assertLe(vault.ACCOUNT_IMPLEMENTATION().code.length, 24_576);
    }

    function test_rejectedNftReceiptRollsBackPaymentRewardCheckpointAndOwnership() public {
        uint256 id = _active();
        vm.warp(block.timestamp + TERM / 2);
        vm.prank(borrower);
        vault.setAskWithMaxFee(id, 200e6, uint40(block.timestamp + 100), type(uint16).max);
        V2Ask memory ask = vault.getAsk(id);
        uint256 cash = usdg.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert();
        vault.buy(id, borrower, ask.nonce, ask.price, 100, address(rewards));
        assertEq(vault.ownerOf(id), borrower);
        assertEq(usdg.balanceOf(buyer), cash);
        assertEq(vault.cashCredit(fees), 10e6);
        assertEq(rewards.claimable(id, borrower), 125e18);
        assertEq(vault.getAsk(id).nonce, ask.nonce);
        _assertCash();
        _assertRewards();
    }

    function test_tinyRewardsRemainMonotonicAcrossFrequentClaimsAndNoDustLiability() public {
        registry.setRewardTerms(TERM, 1, 1, 5000);
        uint256 id = _active(); // Ten wei total reward, five borrower and five lenders.
        uint256 start = vault.getLoan(id).fundedAt;
        for (uint256 step = 1; step <= 20; ++step) {
            vm.warp(start + TERM * step / 20);
            if (rewards.claimable(id, borrower) != 0) {
                vm.prank(borrower);
                rewards.claim(id, borrower);
            }
            for (uint8 i; i < 4; ++i) {
                if (rewards.claimable(id, lender[i]) != 0) {
                    vm.prank(lender[i]);
                    rewards.claim(id, lender[i]);
                }
            }
            _assertRewards();
        }
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        assertEq(_rewardsOwed(), 0);
        _assertRewards();
        assertEq(sgage.balanceOf(borrower), 5);
        uint256 total;
        for (uint8 i; i < 4; ++i) {
            total += sgage.balanceOf(lender[i]);
        }
        assertEq(total, 5);
    }

    function test_registryChangesCannotRepricePendingLoanOrExistingAsk() public {
        uint256 id = _list(1000e6, 1100e6, 100e18);
        registry.setFee(200);
        registry.setRewardTerms(TERM, 0, 1, 5000);
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            vault.fund(id, 1);
        }
        assertEq(vault.cashCredit(borrower), 990e6);
        assertEq(vault.getLoan(id).borrowerReward, 500e18);
        vm.prank(borrower);
        vault.setAskWithMaxFee(id, 200e6, uint40(block.timestamp + 100), type(uint16).max);
        V2Ask memory ask = vault.getAsk(id);
        registry.setTradeFee(200);
        vm.prank(buyer);
        vault.buy(id, borrower, ask.nonce, ask.price, 100, buyer);
        assertEq(vault.cashCredit(fees), 12e6);
    }

    function test_twentySameBlockSelfFundingLoopsEarnZeroAndPayEveryOriginationFee() public {
        uint256 initialCash = usdg.balanceOf(borrower);
        uint256 initialFree = rewards.freeBudget();
        for (uint256 cycle; cycle < 20; ++cycle) {
            uint256 id = _list(1000e6, 1100e6, 100e18);
            vm.startPrank(borrower);
            vault.fund(id, 4);
            vault.reclaim(id, borrower);
            vault.withdrawCollateral(id, borrower);
            vault.withdrawUSDG(borrower);
            vm.stopPrank();
            assertEq(rewards.claimable(id, borrower), 0, "borrower plus all four lender rewards are zero");
            vm.prank(borrower);
            vm.expectRevert(GageV2Rewards.NothingToClaim.selector);
            rewards.claim(id, borrower);
        }
        assertEq(usdg.balanceOf(borrower), initialCash - 200e6);
        assertEq(vault.cashCredit(fees), 200e6);
        assertEq(sgage.balanceOf(borrower), 0);
        assertEq(rewards.freeBudget(), initialFree);
        assertEq(_rewardsOwed(), 0);
        _assertCash();
        _assertRewards();
    }

    function test_twentyOneMinuteSelfFundingLoopsEarnOnlyTheirQuadraticFraction() public {
        uint256 initialCash = usdg.balanceOf(borrower);
        uint256 expected;
        for (uint256 cycle; cycle < 20; ++cycle) {
            uint256 id = _list(1000e6, 1100e6, 100e18);
            vm.startPrank(borrower);
            vault.fund(id, 4);
            // Read the per-loan start: via-IR may cache block.timestamp across vm.warp within this test transaction.
            vm.warp(uint256(vault.getLoan(id).fundedAt) + 1 minutes);
            vault.reclaim(id, borrower);
            vault.withdrawCollateral(id, borrower);
            vault.withdrawUSDG(borrower);
            uint256 oneSide = uint256(500e18) * 60 * 60 / (uint256(TERM) * TERM);
            expected += 2 * oneSide;
            assertEq(rewards.claimable(id, borrower), 2 * oneSide);
            rewards.claim(id, borrower);
            vm.stopPrank();
        }
        assertEq(usdg.balanceOf(borrower), initialCash - 200e6);
        assertEq(vault.cashCredit(fees), 200e6);
        assertEq(sgage.balanceOf(borrower), expected);
        assertLt(expected, 0.0002e18, "twenty one-minute loops earn less than 0.0002 sGAGE at these rates");
        assertEq(_rewardsOwed(), 0);
        assertEq(rewards.freeBudget(), 1_000_000e18 - expected);
        _assertRewards();
    }
}
