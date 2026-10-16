// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnBaseTest} from "./EarnBase.t.sol";
import {HybridVault, EarnLane} from "../src/HybridVault.sol";
import {HybridFees} from "../src/HybridFees.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Kind} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State} from "../src/v2/V2Types.sol";
import {GageV2Vault} from "../src/v2/GageV2Vault.sol";
import {unitsOf} from "./helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @notice Adversarial cases for the pooled share vault: configuration bounds, deal predicates, dependency faults,
/// transfer integrity and the pooled mechanics (virtual shares, unlocking, the vault mark, requests, pockets, rewards).
/// @dev Uses the real Gage V2 core; the reserve mock's controls and a fault probe model external failures.
contract HybridVaultAdversarialTest is EarnBaseTest {
    uint256 internal constant ONE = 1e12; // shares per USDG unit at the initial price
    uint256 internal constant MAX = type(uint256).max;

    error ReserveViewUnavailable();

    function setUp() public override {
        super.setUp();
        vm.prank(curator);
        hybrid.setFee(1000);
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = hybrid.deposit(assets, 0);
    }

    function _fundLoan(uint128 principal) internal returns (uint256 id) {
        id = _listed(principal);
        _approve(id);
        hybrid.fund(id, MAX);
    }

    function _repaid(uint128 principal) internal returns (uint256 id) {
        id = _fundLoan(principal);
        _repay(id);
    }

    /// @dev Fund, let the term and grace pass, and settle the default into a side pocket.
    function _defaulted(uint128 principal) internal returns (uint256 id) {
        id = _fundLoan(principal);
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
    }

    /// @dev A one-week NVDA loan whose premium is a whole principal: it lifts the price far above any mark.
    function _bigPremium() internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 1000e18, 1000e6, 2000e6, T7);
        _approve(id);
        hybrid.fund(id, MAX);
    }

    function _unlock() internal {
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK());
    }

    function _mockLoan(uint256 id, V2Loan memory l) internal {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.getLoan.selector, id), abi.encode(l));
    }

    function _redeploy() internal {
        _deploy();
        vm.prank(curator);
        hybrid.setFee(1000);
    }

    function _ineligible(uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(HybridVault.IneligibleDeal.selector, id);
    }

    /// @dev Holds whenever nothing was sent to the strategy outside its own entrypoints.
    function _assertConserved() internal view {
        uint256 pocketUSDG;
        for (uint256 i = 1; i <= hybrid.pocketCount(); ++i) {
            (, address token, uint256 amount,, uint256 claimed) = hybrid.pockets(i);
            if (token == address(usdg)) pocketUSDG += amount - claimed;
        }
        assertEq(
            usdg.balanceOf(address(hybrid)),
            hybrid.cash() + hybrid.feeAccrued() + hybrid.claimableTotal() + pocketUSDG + hybrid.harvestedCash()
                - hybrid.assignedCash(),
            "USDG conservation"
        );
        assertEq(reserve.balanceOf(address(hybrid)), hybrid.reserveShares(), "reserve share conservation");
    }

    // ---------------------------------------------------------------- configuration and permissions

    function testConstructorEveryImmutableBoundInvalidConfiguration() public {
        for (uint256 i; i < 12; ++i) {
            HybridVault.Params memory bad = p;
            if (i == 0) bad.core = address(0);
            if (i == 1) bad.reserve = address(0);
            if (i == 2) bad.curator = address(0);
            if (i == 3) bad.maxLoanTerm = 0;
            if (i == 4) bad.maxLoanTerm = 90 days + 1;
            if (i == 5) bad.maxGageExposureBps = 0;
            if (i == 6) bad.maxGageExposureBps = 10_001;
            if (i == 7) bad.minDeposit = 0;
            if (i == 8) bad.maxTotalDeposits = bad.minDeposit - 1;
            if (i == 9) bad.minReturnBps = 10_001;
            if (i == 10) bad.laneWeights[0] = 10_001;
            if (i == 11) bad.laneWeights[1] = 1;
            vm.expectRevert(HybridVault.InvalidConfiguration.selector);
            new HybridVault(bad);
        }
    }

    function testConstructorAllowsDepositCapEqualToMinimum() public {
        p.maxTotalDeposits = p.minDeposit;
        _redeploy();
        _deposit(lender, p.minDeposit);
        assertEq(hybrid.fullAssets(), p.minDeposit);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.deposit(p.minDeposit, 0);
    }

    function testConstructorDependencyBoundsInvalidConfiguration() public {
        vm.mockCall(address(reserve), abi.encodeWithSelector(reserve.asset.selector), abi.encode(address(nvda)));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        new HybridVault(p);
        vm.clearMockedCalls();
        vm.mockCall(address(vault), abi.encodeWithSignature("GRACE()"), abi.encode(uint32(7 days + 1)));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        new HybridVault(p);
        vm.clearMockedCalls();
        vm.mockCall(address(vault), abi.encodeWithSignature("UNITS()"), abi.encode(uint8(3)));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        new HybridVault(p);
        vm.clearMockedCalls();
        vm.mockCall(address(usdg), abi.encodeWithSelector(usdg.decimals.selector), abi.encode(uint8(19)));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        new HybridVault(p);
        vm.clearMockedCalls();
        vm.mockCall(address(coreRewards), abi.encodeWithSignature("SGAGE()"), abi.encode(address(nvda)));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        new HybridVault(p);
        vm.clearMockedCalls();
        address[2] memory forbidden = [address(usdg), address(reserve)];
        for (uint256 i; i < 2; ++i) {
            vm.mockCall(address(vault), abi.encodeWithSignature("SGAGE()"), abi.encode(forbidden[i]));
            vm.mockCall(address(coreRewards), abi.encodeWithSignature("SGAGE()"), abi.encode(forbidden[i]));
            vm.expectRevert(HybridVault.InvalidConfiguration.selector);
            new HybridVault(p);
            vm.clearMockedCalls();
        }
        p.curator = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        new HybridVault(p);
    }

    function testSetterBoundsInvalidConfiguration() public {
        vm.startPrank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setLaneWeight(EarnLane.STOCK, 10_001);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setLaneWeight(EarnLane.MEME, 1);
        hybrid.setLaneWeight(EarnLane.STOCK, 9000);
        hybrid.setLaneWeight(EarnLane.MEME, 1000);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setLaneWeight(EarnLane.LP, 1);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setTokenCeiling(address(nvda), uint256(type(uint128).max) + 1);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setTokenCeiling(address(usdg), 1);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setTokenCeiling(address(reserve), 1);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setTokenCeiling(address(0x123), 1);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setFee(5001);
        hybrid.setFee(5000);
        // The deposit cap may be closed completely, but must fit the width of its field.
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setMaxTotalDeposits(uint256(type(uint128).max) + 1);
        hybrid.setMaxTotalDeposits(0);
        // Closing a token needs no registry or decimals check.
        hybrid.setTokenCeiling(address(nvda), 0);
        vm.stopPrank();
        assertEq(hybrid.tokenCeiling(address(nvda)), 0);
        assertEq(hybrid.feeBps(), 5000);
        assertEq(hybrid.params().maxTotalDeposits, 0);
        // A strategy without a companion cannot charge a fee at all.
        HybridVault fresh = new HybridVault(p);
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFee(1);
        vm.prank(curator);
        fresh.setFee(0);
    }

    function testAllCuratorEntrypointsRejectNotCurator() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        _approve(id);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.setPaused(true);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.setLaneWeight(EarnLane.STOCK, 5000);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.setTokenCeiling(address(nvda), 1);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.setFee(0);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.setMaxTotalDeposits(type(uint128).max);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.approveLoan(id, uint40(block.timestamp + 1), UNITS);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.revokeLoan(id);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.divestReserve(1, 0);
        vm.expectRevert(HybridFees.NotCurator.selector);
        hybridFees.setCuratorRecipient(treasury);
        hybrid.fund(id, MAX);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.withdrawCommitment(id);
    }

    function testAdmittingATokenNeedsRegistryPermissionAndSaneDecimals() public {
        MockERC20 malformed = new MockERC20("Malformed", "BAD", 37);
        vm.prank(safe);
        registry.setERC20Allowed(address(malformed), true, Lane.STOCK, 1, 1000, 5000);
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setTokenCeiling(address(malformed), 1);
        vm.prank(safe);
        registry.setERC20Allowed(address(aapl), false, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setTokenCeiling(address(aapl), 1e6);
        vm.prank(safe);
        registry.setERC20Allowed(address(aapl), true, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        vm.prank(curator);
        hybrid.setTokenCeiling(address(aapl), 1e6);
        assertEq(hybrid.tokenCeiling(address(aapl)), 1e6);
        assertEq(hybrid.tokenUnit(address(aapl)), 1e18);
    }

    function testMalformedRegistryTokenPolicyCannotAdmitOrApproveCollateral() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        bytes[4] memory responses = [
            abi.encode(uint256(1), uint256(0)),
            abi.encode(uint256(1), uint256(0), NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN, uint256(0)),
            abi.encode(uint256(1), uint256(3), NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN),
            abi.encode(uint256(2), uint256(0), NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN)
        ];
        for (uint256 i; i < responses.length; ++i) {
            vm.mockCall(
                address(registry), abi.encodeWithSelector(registry.getERC20Config.selector, address(nvda)), responses[i]
            );
            vm.prank(curator);
            vm.expectRevert(HybridVault.InvalidConfiguration.selector);
            hybrid.setTokenCeiling(address(nvda), 2000e6);
            vm.expectRevert(_ineligible(id));
            _approve(id);
            assertEq(hybrid.tokenCeiling(address(nvda)), 1000e6);
            assertEq(hybrid.approvedPrincipal(), 0);
        }
        vm.clearMockedCalls();
        _approve(id);
        assertEq(hybrid.approvedPrincipal(), 100e6);
    }

    function testFeeCompanionMustNameThisStrategyAndIsWiredOnce() public {
        HybridVault fresh = new HybridVault(p);
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFees(address(0));
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFees(address(hybridFees));
        HybridFees companion = new HybridFees(address(fresh), 2500, floor, curator);
        vm.prank(other);
        vm.expectRevert(HybridVault.NotCurator.selector);
        fresh.setFees(address(companion));
        // The deployer of the strategy may finish the wiring once.
        fresh.setFees(address(companion));
        assertEq(fresh.fees(), address(companion));
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFees(address(companion));
        // The wired state is checked before the caller.
        vm.prank(other);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFees(address(companion));
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        hybrid.setFees(address(hybridFees));
    }

    function testDepositReserveIsOnlySelfCallable() public {
        _deposit(lender, 10e6);
        vm.expectRevert(HybridVault.NotOwner.selector);
        hybrid.depositReserve(1e6, 0);
        vm.prank(address(reserve));
        vm.expectRevert(HybridVault.NotOwner.selector);
        hybrid.depositReserve(1e6, 0);
        assertEq(hybrid.reserveShares(), 0);
        assertEq(hybrid.cash(), 10e6);
    }

    function testBatchBoundsInvalidAmountOnEveryBoundedEntrypoint() public {
        for (uint256 n; n < 2; ++n) {
            uint256[] memory ids = new uint256[](n == 0 ? 0 : 33);
            vm.expectRevert(HybridVault.InvalidAmount.selector);
            hybrid.markOverdue(ids);
            vm.expectRevert(HybridVault.InvalidAmount.selector);
            hybrid.settle(ids);
            vm.expectRevert(HybridVault.InvalidAmount.selector);
            hybrid.harvestRewards(ids);
        }
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.settle(_ids(1));
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.harvestRewards(_ids(1));
    }

    function testViewsReportTheImmutableWiringAndLoanRecords() public {
        assertEq(address(hybrid.VAULT()), address(vault));
        assertEq(address(hybrid.CORE_REWARDS()), address(coreRewards));
        assertEq(address(hybrid.REGISTRY()), address(registry));
        assertEq(address(hybrid.RESERVE()), address(reserve));
        assertEq(address(hybrid.USDG()), address(usdg));
        assertEq(address(hybrid.REWARD_TOKEN()), address(sgage));
        assertEq(hybrid.CURATOR(), curator);
        assertEq(hybrid.GRACE(), GRACE);
        assertEq(hybrid.asset(), address(usdg));
        assertEq(hybrid.decimals(), 18);
        assertEq(hybrid.VIRTUAL_SHARES(), ONE);
        assertEq(hybrid.PROFIT_UNLOCK(), 7 days);
        assertEq(hybrid.params().curator, curator);
        assertEq(hybrid.params().maxTotalDeposits, p.maxTotalDeposits);
        assertEq(hybrid.laneWeightBps(EarnLane.STOCK), 10_000);
        assertEq(hybrid.tokenUnit(address(nvda)), 1e18);
        assertEq(hybrid.fees(), address(hybridFees));
        assertEq(hybrid.feeBps(), 1000);
        assertEq(hybrid.requestHead(), 1);
        assertFalse(hybrid.paused());
        _deposit(lender, 100e6);
        uint256 id = _listed(50e6);
        _approve(id);
        (uint40 validUntil, uint128 principal, uint64 epoch, uint8 units) = hybrid.approvals(id);
        assertEq(validUntil, block.timestamp + 1 hours);
        assertEq(principal, 50e6);
        assertEq(epoch, hybrid.approvalEpoch());
        assertEq(units, UNITS);
        assertEq(hybrid.approvedPrincipal(), 50e6);
        hybrid.fund(id, MAX);
        (validUntil, principal,,) = hybrid.approvals(id);
        assertEq(validUntil, 0);
        assertEq(principal, 0);
        assertEq(hybrid.approvedPrincipal(), 0);
        assertEq(hybrid.borrowerPrincipal(borrower), 50e6);
        assertEq(hybrid.positionPrincipal(id), 50e6);
        assertEq(hybrid.loanSlots(id), 0xF);
        assertEq(uint256(hybrid.loanLane(id)), uint256(EarnLane.STOCK));
        assertEq(hybrid.loanFeeBps(id), 1000);
        assertTrue(hybrid.funded(id));
        assertFalse(hybrid.terminal(id));
        assertEq(hybrid.pendingRequestAssets(), 0);
    }

    // ---------------------------------------------------------------- deal eligibility and approvals

    function testEveryDealPredicateRejectsIneligibleDeal() public {
        _deposit(lender, 10_000e6);
        uint256 id = _listed(100e6);
        V2Loan memory baseline = vault.getLoan(id);
        for (uint256 i; i < 12; ++i) {
            V2Loan memory l = vault.getLoan(id);
            if (i == 0) l.state = V2State.CANCELLED;
            if (i == 1) l.kind = Kind.UNIV4_POSITION;
            if (i == 2) l.token = address(aapl); // registry-allowed but not admitted here
            if (i == 3) l.principal = 0;
            if (i == 4) l.principal = uint128(hybrid.fullAssets() + 1);
            if (i == 5) l.term = p.maxLoanTerm + 1;
            if (i == 6) l.originator = address(hybrid);
            if (i == 7) l.originator = curator;
            if (i == 8) l.fundingDeadline = uint40(block.timestamp);
            if (i == 9) l.cap = l.principal + 1; // below the 2% minimum return
            if (i == 10) l.filled = 1; // four units no longer fit
            if (i == 11) l.collateral = 0; // above the price ceiling
            _mockLoan(id, l);
            vm.expectRevert(_ineligible(id));
            _approve(id);
            _mockLoan(id, baseline);
        }
        vm.clearMockedCalls();
        vm.expectRevert(_ineligible(id));
        _approve(id, 0);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        vm.expectRevert(_ineligible(id));
        _approve(id);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        // Exactly the minimum return is eligible.
        uint256 exact = _list(borrower, address(nvda), 100e18, 100e6, 102e6, T7);
        _approve(exact);
        _approve(id);
        hybrid.fund(id, MAX);
        vm.expectRevert(_ineligible(id));
        _approve(id);
    }

    function testPriceCeilingClosedTokenAndClosedLaneRejectIneligibleDeal() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6); // 100 NVDA for 100 USDG: exactly 1 USDG per share
        vm.prank(curator);
        hybrid.setTokenCeiling(address(nvda), 999_999);
        vm.expectRevert(_ineligible(id));
        _approve(id);
        vm.prank(curator);
        hybrid.setTokenCeiling(address(nvda), 1e6);
        _approve(id);
        vm.prank(curator);
        hybrid.setTokenCeiling(address(nvda), 0);
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        vm.prank(curator);
        hybrid.setTokenCeiling(address(nvda), 1e6);
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 0);
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        assertEq(hybrid.cash(), 1000e6);
        assertFalse(hybrid.funded(id));
    }

    function testRegistryEthSharesStockCategoryAndMemeUsesItsOwnCategory() public {
        _deposit(lender, 1000e6);
        vm.startPrank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 5000);
        hybrid.setLaneWeight(EarnLane.MEME, 5000);
        hybrid.setTokenCeiling(address(meme), 1000e6);
        vm.stopPrank();
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.ETH, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        uint256 eth = _fundLoan(300e6);
        uint256 memeLoan = _list(borrower, address(meme), 100e18, 300e6, 315e6, T7);
        _approve(memeLoan);
        hybrid.fund(memeLoan, MAX);
        assertEq(uint256(hybrid.loanLane(eth)), uint256(EarnLane.STOCK));
        assertEq(uint256(hybrid.loanLane(memeLoan)), uint256(EarnLane.MEME));
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 300e6);
        assertEq(hybrid.lanePrincipal(EarnLane.MEME), 300e6);
        assertEq(hybrid.lanePrincipal(EarnLane.LP), 0);
    }

    function testLaneCapBoundaryAndOneUnitOverIneligibleDeal() public {
        _deposit(lender, 1000e6);
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 6000);
        uint256 exact = _fundLoan(600e6);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 600e6);
        uint256 excess = _listed(1e6);
        vm.expectRevert(_ineligible(excess));
        _approve(excess);
        // Lowering the weight below the funded principal keeps the loan and blocks new ones until it repays.
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 1000);
        assertTrue(hybrid.funded(exact));
        vm.expectRevert(_ineligible(excess));
        _approve(excess);
        _repay(exact);
        hybrid.settle(_ids(exact));
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 0);
        _approve(excess);
        hybrid.fund(excess, MAX);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 1e6);
    }

    function testFundingRechecksTheLaneCapAfterApprovalAndAfterAReserveLoss() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(1000e6, 1);
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 6000);
        uint256 id = _listed(600e6);
        _approve(id);
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 5000);
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        vm.prank(curator);
        hybrid.setLaneWeight(EarnLane.STOCK, 6000);
        reserve.simulateLoss(1e6, other);
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.reserveShares(), 1000e18);
    }

    function testRegistryDisallowsBetweenApprovalAndFundingIneligibleDeal() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        _approve(id);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        assertEq(hybrid.cash(), 1000e6);
    }

    function testExternalFillersBetweenApprovalAndFundingIneligibleDeal() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(1000e6);
        _approve(id);
        vm.prank(fillers[0]);
        vault.fund(id, 1);
        // Four approved units no longer fit; approving what is left works until the deal activates without us.
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        _approve(id, 3);
        assertEq(hybrid.approvedPrincipal(), 750e6);
        _fill(id);
        assertEq(uint256(_state(id)), uint256(V2State.ACTIVE));
        vm.expectRevert(_ineligible(id));
        hybrid.fund(id, MAX);
        assertFalse(hybrid.funded(id));
        assertEq(hybrid.cash(), 1000e6);
        vm.prank(curator);
        hybrid.revokeLoan(id);
        assertEq(hybrid.approvedPrincipal(), 0);
    }

    function testApprovalTimeBoundsAndAnyoneRevokesAfterExpiry() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        vm.startPrank(curator);
        vm.expectRevert(HybridVault.ApprovalExpired.selector);
        hybrid.approveLoan(id, uint40(block.timestamp), UNITS);
        vm.expectRevert(HybridVault.ApprovalExpired.selector);
        hybrid.approveLoan(id, uint40(block.timestamp + 1 hours + 1), UNITS);
        hybrid.approveLoan(id, uint40(block.timestamp + 1), UNITS);
        vm.stopPrank();
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.revokeLoan(id);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(HybridVault.ApprovalExpired.selector);
        hybrid.fund(id, MAX);
        hybrid.revokeLoan(id);
        assertEq(hybrid.approvedPrincipal(), 0);
        assertEq(hybrid.cash(), 1000e6);
        assertFalse(hybrid.funded(id));
    }

    function testPauseInvalidatesApprovalsAndStaleRecordsNeverUnderflowOrDoubleCount() public {
        _deposit(lender, 2000e6);
        uint256 id = _listed(1000e6);
        _approve(id);
        assertEq(hybrid.approvedPrincipal(), 1000e6);
        vm.startPrank(curator);
        hybrid.setPaused(true);
        hybrid.setPaused(false);
        vm.stopPrank();
        assertEq(hybrid.approvalEpoch(), 2);
        assertEq(hybrid.approvedPrincipal(), 0);
        vm.expectRevert(HybridVault.ApprovalExpired.selector);
        hybrid.fund(id, MAX);
        uint256 next = _listed(500e6);
        _approve(next);
        assertEq(hybrid.approvedPrincipal(), 500e6);
        // Revoking the stale record subtracts nothing; re-approving it counts it exactly once.
        vm.prank(curator);
        hybrid.revokeLoan(id);
        assertEq(hybrid.approvedPrincipal(), 500e6);
        _approve(id);
        vm.prank(curator);
        hybrid.setPaused(true);
        vm.prank(curator);
        hybrid.setPaused(false);
        _approve(id);
        assertEq(hybrid.approvedPrincipal(), 1000e6);
        hybrid.fund(id, MAX);
        assertEq(hybrid.approvedPrincipal(), 0);
    }

    function testPausedStatePrecedesCallerAndArgumentsAndNeverBlocksExits() public {
        uint256 shares = _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        _approve(id);
        vm.expectRevert(HybridVault.ApprovalExpired.selector);
        hybrid.fund(0, 0);
        vm.prank(curator);
        hybrid.setPaused(true);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.approveLoan(id, uint40(block.timestamp + 1), UNITS);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.fund(id, 0);
        vm.prank(lender);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.deposit(1e6, 0);
        vm.expectRevert(HybridVault.PausedError.selector);
        hybrid.investReserve(1e6, 0);
        // Redemptions, requests, service and claims stay open.
        vm.prank(lender);
        hybrid.requestRedeem(100e18);
        hybrid.serveRequests(1, MAX);
        vm.prank(lender);
        assertEq(hybrid.claim(), 100e6);
        vm.prank(lender);
        assertEq(hybrid.redeem(shares - 100e18, 900e6), 900e6);
        assertEq(hybrid.totalSupply(), 0);
    }

    function testApprovedPrincipalCeilingLimitExceededAndReplacementDoesNotDoubleCount() public {
        p.maxTotalDeposits = 1000e6;
        _redeploy();
        _deposit(lender, 1000e6);
        uint256 first = _listed(1000e6);
        _approve(first);
        _approve(first);
        assertEq(hybrid.approvedPrincipal(), 1000e6);
        uint256 second = _listed(1e6);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        _approve(second);
        vm.prank(curator);
        hybrid.revokeLoan(first);
        assertEq(hybrid.approvedPrincipal(), 0);
        _approve(second);
        assertEq(hybrid.approvedPrincipal(), 1e6);
    }

    function testFundingRechecksApprovedPrincipalAndAllowsRepeatedBorrowerExposure() public {
        _redeploy();
        _deposit(lender, 3000e6);
        uint256 id = _listed(100e6);
        _approve(id);
        V2Loan memory l = vault.getLoan(id);
        l.principal += 4;
        _mockLoan(id, l);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.fund(id, MAX);
        vm.clearMockedCalls();
        hybrid.fund(id, MAX);
        uint256 second = _listed(1000e6);
        _approve(second);
        hybrid.fund(second, MAX);
        assertEq(hybrid.borrowerPrincipal(borrower), 1100e6);
        assertEq(hybrid.performingPrincipal(), 1100e6);
    }

    function testCorePauseAndTermChangesBlockFundingThroughTheCore() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        _approve(id);
        vm.prank(safe);
        registry.pauseNewDeals(true);
        vm.expectRevert(abi.encodeWithSignature("Paused()"));
        hybrid.fund(id, MAX);
        vm.prank(safe);
        registry.pauseNewDeals(false);
        uint32[] memory terms = new uint32[](1);
        terms[0] = T21;
        vm.prank(safe);
        registry.setTerms(terms);
        vm.expectRevert(abi.encodeWithSignature("InvalidTerms()"));
        hybrid.fund(id, MAX);
        assertEq(hybrid.cash(), 1000e6);
        assertFalse(hybrid.funded(id));
        assertEq(hybrid.performingPrincipal(), 0);
    }

    function testStrategyUnitsCannotBeSoldByOutsiders() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized()"));
        vault.setLenderAsk(id, 0xF, 1e6, uint40(block.timestamp + 1 hours), 100);
        assertEq(vault.unitsOf(id, address(hybrid)), 4);
    }

    function testPartialUnitsPayAndRecoverOnlyTheStrategyQuarters() public {
        _deposit(lender, 2000e6);
        uint256 a = _listed(1000e6);
        _approve(a, 2);
        hybrid.fund(a, MAX);
        assertEq(hybrid.positionPrincipal(a), 500e6);
        assertEq(hybrid.loanSlots(a), 0x3);
        assertEq(vault.unitsOf(a, address(hybrid)), 2);
        _fill(a);
        assertEq(uint256(_state(a)), uint256(V2State.ACTIVE));
        uint256 b = _listed(1000e6);
        _approve(b, 1);
        hybrid.fund(b, MAX);
        _fill(b);
        assertEq(hybrid.performingPrincipal(), 750e6);
        vm.warp(block.timestamp + T7 / 2);
        _repay(a);
        uint256 dueA = coreRewards.claimable(a, address(hybrid));
        uint256 dueB = coreRewards.claimable(b, address(hybrid));
        assertApproxEqAbs(dueA, coreRewards.claimable(a, fillers[0]) * 2, 2, "two quarters earn twice one");
        hybrid.settle(_ids(a));
        // Two of four quarters of a 1050 repayment: 525 back on 500 lent, 10% fee on the 25 premium.
        assertEq(hybrid.cash(), 2000e6 - 750e6 + 525e6 - 2.5e6);
        assertEq(hybrid.feeAccrued(), 2.5e6);
        assertEq(hybrid.performingPrincipal(), 250e6);
        hybrid.harvestRewards(_ids(a));
        uint256 ours = sgage.balanceOf(address(hybrid));
        assertGt(ours, 0);
        assertApproxEqAbs(ours, dueA + dueB, 2, "the checkpoint accrues every open strategy position");
        vm.warp(_defaultAt(b));
        hybrid.settle(_ids(b));
        (,, uint256 amount, uint256 supply,) = hybrid.pockets(1);
        assertEq(amount, 25e18, "one quarter of the collateral");
        assertEq(supply, 2000e18);
        assertEq(nvda.balanceOf(address(hybrid)), 25e18);
        assertEq(hybrid.performingPrincipal(), 0);
        _assertConserved();
    }

    function testWithdrawnCommitmentsAndBorrowerCancellationsRefundPrincipalOnly() public {
        _deposit(lender, 1000e6);
        uint256 a = _listed(800e6);
        _approve(a, 2);
        hybrid.fund(a, MAX);
        uint256 b = _listed(400e6);
        _approve(b, 1);
        hybrid.fund(b, MAX);
        assertEq(hybrid.performingPrincipal(), 500e6);
        vm.prank(curator);
        hybrid.withdrawCommitment(a);
        assertTrue(hybrid.withdrawn(a));
        vm.prank(curator);
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.withdrawCommitment(a);
        vm.prank(borrower);
        vault.cancelFunding(b);
        assertEq(uint256(_state(b)), uint256(V2State.CANCELLED));
        assertEq(vault.cashCredit(address(hybrid)), 500e6);
        hybrid.settle(_two(a, b));
        assertTrue(hybrid.terminal(a));
        assertTrue(hybrid.terminal(b));
        assertEq(hybrid.cash(), 1000e6);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.lockedProfit(), 0);
        assertEq(hybrid.feeAccrued(), 0);
        assertEq(hybrid.totalAssets(), 1000e6);
        assertEq(hybrid.borrowerPrincipal(borrower), 0);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 0);
        _assertConserved();
    }

    function testCancelledDealsAreOnlyAssignedAgainstRefundsThatArrived() public {
        uint256 unfunded = _listed(1000e6);
        vm.prank(borrower);
        vault.cancelFunding(unfunded);
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.settle(_ids(unfunded));
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        V2Loan memory l = vault.getLoan(id);
        l.state = V2State.CANCELLED;
        _mockLoan(id, l);
        hybrid.settle(_ids(id));
        assertFalse(hybrid.terminal(id), "a cancelled state without the refund cannot be assigned");
        assertEq(hybrid.performingPrincipal(), 1000e6);
        assertEq(hybrid.cash(), 0);
    }

    function testRepaymentDecrementsTheFundedLaneEvenIfTheRegistryLaneChanged() public {
        _deposit(lender, 1000e6);
        uint256 id = _repaid(1000e6);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.MEME, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        hybrid.settle(_ids(id));
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 0);
        assertEq(hybrid.lanePrincipal(EarnLane.MEME), 0);
        assertEq(hybrid.performingPrincipal(), 0);
    }

    function testWithdrawCommitmentRejectsUnknownActiveAndTerminalLoans() public {
        vm.prank(curator);
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.withdrawCommitment(999);
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.withdrawCommitment(id);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSignature("WrongState()"));
        hybrid.withdrawCommitment(id);
        assertFalse(hybrid.withdrawn(id));
        _repay(id);
        hybrid.settle(_ids(id));
        vm.prank(curator);
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.withdrawCommitment(id);
    }

    // ---------------------------------------------------------------- transfer integrity and dependency faults

    function testDepositMissingTokenMovementTransferAmountMismatch() public {
        _deposit(lender, 1e6);
        vm.mockCall(
            address(usdg),
            abi.encodeWithSelector(usdg.transferFrom.selector, lender, address(hybrid), 1e6),
            abi.encode(true)
        );
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.deposit(1e6, 0);
        assertEq(hybrid.cash(), 1e6);
        assertEq(hybrid.totalSupply(), 1e18);
    }

    function testPausedUSDGDepositEnforcedPausePreservesState() public {
        _deposit(lender, 1e6);
        usdg.setPaused(true);
        vm.prank(lender);
        vm.expectRevert(MockERC20.EnforcedPause.selector);
        hybrid.deposit(1e6, 0);
        vm.prank(lender);
        vm.expectRevert(MockERC20.EnforcedPause.selector);
        hybrid.redeem(1e18, 0);
        assertEq(hybrid.cash(), 1e6);
        assertEq(hybrid.balanceOf(lender), 1e18);
    }

    function testRedeemUndercreditsRecipientTransferAmountMismatch() public {
        uint256 shares = _deposit(lender, 1000e6);
        // Both tokens use the OpenZeppelin ERC-20 layout: model an upgrade that starts burning part of transfers.
        vm.etch(address(usdg), address(feeToken).code);
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.redeem(shares, 0);
        assertEq(hybrid.balanceOf(lender), shares);
        assertEq(usdg.balanceOf(address(hybrid)), 1000e6);
    }

    function testRedeemAndClaimMissingTokenMovementTransferAmountMismatch() public {
        uint256 shares = _deposit(lender, 1000e6);
        vm.prank(lender);
        hybrid.requestRedeem(shares / 2);
        hybrid.serveRequests(1, MAX);
        vm.mockCall(address(usdg), abi.encodeWithSelector(usdg.transfer.selector, lender, 500e6), abi.encode(true));
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.redeem(shares / 2, 0);
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.claim();
        assertEq(hybrid.balanceOf(lender), shares / 2);
        assertEq(hybrid.claimable(lender), 500e6);
    }

    function testMalformedOrRevertingBalanceOfPreservesShares() public {
        uint256 shares = _deposit(lender, 100e6);
        vm.mockCall(address(usdg), abi.encodeWithSelector(usdg.balanceOf.selector, address(hybrid)), hex"01");
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.redeem(shares, 0);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(usdg),
            abi.encodeWithSelector(usdg.balanceOf.selector, address(hybrid)),
            abi.encodeWithSelector(MockERC20.EnforcedPause.selector)
        );
        vm.prank(lender);
        vm.expectRevert(MockERC20.EnforcedPause.selector);
        hybrid.redeem(shares, 0);
        vm.clearMockedCalls();
        assertEq(hybrid.balanceOf(lender), shares);
        assertEq(hybrid.cash(), 100e6);
    }

    function testMalformedLoanRecordTransferAmountMismatch() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(100e6);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.getLoan.selector, id), hex"01");
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        _approve(id);
        vm.clearMockedCalls();
        _approve(id);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.getLoan.selector, id), hex"01");
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.fund(id, MAX);
        vm.clearMockedCalls();
        hybrid.fund(id, MAX);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.getLoan.selector, id), hex"01");
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.markOverdue(_ids(id));
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.settle(_ids(id));
        vm.clearMockedCalls();
        assertTrue(hybrid.funded(id));
        assertFalse(hybrid.terminal(id));
    }

    function testMalformedOrRevertingReserveViewsFailClosed() public {
        _deposit(lender, 100e6);
        hybrid.investReserve(50e6, 1);
        vm.mockCall(address(reserve), abi.encodeWithSelector(reserve.convertToAssets.selector), hex"01");
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.deposit(1e6, 0);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.totalAssets();
        vm.clearMockedCalls();
        vm.mockCall(address(reserve), abi.encodeWithSelector(reserve.maxWithdraw.selector), hex"01");
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.maxWithdraw(lender);
        vm.clearMockedCalls();
        vm.mockCallRevert(
            address(reserve),
            abi.encodeWithSelector(reserve.convertToAssets.selector),
            abi.encodeWithSelector(ReserveViewUnavailable.selector)
        );
        vm.prank(lender);
        vm.expectRevert(ReserveViewUnavailable.selector);
        hybrid.redeem(1e18, 0);
        vm.expectRevert(ReserveViewUnavailable.selector);
        hybrid.serveRequests(1, MAX);
        vm.clearMockedCalls();
        assertEq(hybrid.balanceOf(lender), 100e18);
        assertEq(hybrid.cash(), 50e6);
    }

    function testReserveDepositMissingMovementOrMisreportedSharesTransferAmountMismatch() public {
        _deposit(lender, 10e6);
        vm.mockCall(address(reserve), abi.encodeWithSelector(reserve.deposit.selector), abi.encode(uint256(1)));
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.investReserve(1e6, 0);
        vm.clearMockedCalls();
        assertEq(hybrid.cash(), 10e6);
        HybridReserveFaultProbe faulty = new HybridReserveFaultProbe(usdg);
        p.reserve = address(faulty);
        _redeploy();
        _deposit(lender, 10e6);
        faulty.configure(hybrid, 3);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.investReserve(1e6, 0);
        assertEq(hybrid.cash(), 10e6);
        assertEq(hybrid.reserveShares(), 0);
    }

    function testReserveWithdrawMisreportsUnderpaysOrMovesNothingTransferAmountMismatch() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(1000e6, 1);
        vm.mockCall(address(reserve), abi.encodeWithSelector(reserve.withdraw.selector), abi.encode(uint256(1)));
        vm.prank(lender);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.redeem(100e18, 0);
        vm.clearMockedCalls();
        assertEq(hybrid.reserveShares(), 1000e18);
        for (uint256 mode = 5; mode <= 6; ++mode) {
            HybridReserveFaultProbe faulty = new HybridReserveFaultProbe(usdg);
            p.reserve = address(faulty);
            _redeploy();
            uint256 shares = _deposit(lender, 1000e6);
            hybrid.investReserve(1000e6, 1);
            uint256 reserveShares = hybrid.reserveShares();
            faulty.configure(hybrid, mode);
            uint256 id = _listed(1000e6);
            _approve(id);
            vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
            hybrid.fund(id, MAX);
            vm.prank(lender);
            vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
            hybrid.redeem(shares, 0);
            assertEq(hybrid.reserveShares(), reserveShares);
            assertEq(hybrid.performingPrincipal(), 0);
            assertEq(hybrid.balanceOf(lender), shares);
        }
    }

    function testReserveRedeemMisreportsAssetsOrMovesNothingTransferAmountMismatch() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(1000e6, 1);
        vm.mockCall(address(reserve), abi.encodeWithSelector(reserve.redeem.selector), abi.encode(uint256(0)));
        vm.prank(curator);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.divestReserve(1000e18, 0);
        vm.clearMockedCalls();
        assertEq(hybrid.reserveShares(), 1000e18);
        HybridReserveFaultProbe faulty = new HybridReserveFaultProbe(usdg);
        p.reserve = address(faulty);
        _redeploy();
        _deposit(lender, 1000e6);
        hybrid.investReserve(1000e6, 1);
        uint256 reserveShares = hybrid.reserveShares();
        faulty.configure(hybrid, 4);
        vm.prank(curator);
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.divestReserve(reserveShares, 0);
        assertEq(hybrid.reserveShares(), reserveShares);
        assertEq(hybrid.cash(), 0);
    }

    function testReserveOverburnBeyondMaxReserveSharesIsSlippage() public {
        HybridReserveFaultProbe faulty = new HybridReserveFaultProbe(usdg);
        p.reserve = address(faulty);
        _redeploy();
        _deposit(lender, 2000e6);
        hybrid.investReserve(2000e6, 1);
        uint256 reserveShares = hybrid.reserveShares();
        faulty.configure(hybrid, 2);
        uint256 id = _listed(1000e6);
        _approve(id);
        uint256 quoted = faulty.previewWithdraw(1000e6);
        vm.expectRevert(HybridVault.Slippage.selector);
        hybrid.fund(id, quoted);
        assertEq(hybrid.reserveShares(), reserveShares);
        assertFalse(hybrid.funded(id));
        // Accepting the extra burn records exactly what the reserve took.
        hybrid.fund(id, quoted + 1);
        assertEq(hybrid.reserveShares(), reserveShares - quoted - 1);
        assertEq(faulty.balanceOf(address(hybrid)), hybrid.reserveShares());
    }

    function testReentrantReserveIsRejectedOnDepositAndWithdrawal() public {
        HybridReserveFaultProbe faulty = new HybridReserveFaultProbe(usdg);
        p.reserve = address(faulty);
        _redeploy();
        uint256 shares = _deposit(lender, 1000e6);
        faulty.configure(hybrid, 1);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        hybrid.investReserve(500e6, 0);
        assertEq(hybrid.reserveShares(), 0);
        assertEq(hybrid.cash(), 1000e6);
        faulty.configure(hybrid, 0);
        hybrid.investReserve(1000e6, 0);
        faulty.configure(hybrid, 7);
        vm.prank(lender);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        hybrid.redeem(shares, 0);
        assertEq(hybrid.balanceOf(lender), shares);
        assertEq(hybrid.reserveShares(), 1000e6);
    }

    function testCoreFundingMissingMovementTransferAmountMismatch() public {
        _deposit(lender, 1000e6);
        uint256 id = _listed(1000e6);
        _approve(id);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.fund.selector), bytes(""));
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.fund(id, MAX);
        vm.clearMockedCalls();
        assertEq(hybrid.cash(), 1000e6);
        assertFalse(hybrid.funded(id));
        assertEq(hybrid.approvedPrincipal(), 1000e6);
    }

    function testHarvestCashMissingMovementTransferAmountMismatch() public {
        _deposit(lender, 1000e6);
        _repaid(1000e6);
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.withdrawUSDG.selector), bytes(""));
        vm.expectRevert(HybridVault.TransferAmountMismatch.selector);
        hybrid.harvestCash();
        vm.clearMockedCalls();
        assertEq(hybrid.harvestedCash(), 0);
    }

    function testRecoveryMissingMovementDefersLoanAndPreservesRetry() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(_defaultAt(id));
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.withdrawRecovery.selector), bytes(""));
        hybrid.settle(_ids(id));
        vm.clearMockedCalls();
        assertFalse(hybrid.terminal(id));
        assertEq(hybrid.pocketCount(), 0);
        assertEq(hybrid.performingPrincipal() + hybrid.overduePrincipal(), 1000e6);
        assertEq(hybrid.borrowerPrincipal(borrower), 1000e6);
        assertEq(nvda.balanceOf(address(hybrid)), 0);
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.pocketCount(), 1);
    }

    function testUSDGPausedHarvestDefersCashButAllowsCollateralSettlement() public {
        vm.prank(curator);
        hybrid.setFee(0);
        _deposit(lender, 2000e6);
        uint256 repaid = _fundLoan(1000e6);
        uint256 defaulted = _fundLoan(1000e6);
        _repay(repaid);
        vm.warp(_defaultAt(defaulted));
        usdg.setPaused(true);
        hybrid.harvestCash();
        hybrid.settle(_two(repaid, defaulted));
        assertFalse(hybrid.terminal(repaid));
        assertTrue(hybrid.terminal(defaulted));
        assertEq(hybrid.harvestedCash(), 0);
        assertEq(hybrid.pocketCount(), 1);
        assertEq(hybrid.performingPrincipal(), 1000e6, "the uncollected repayment is still carried at principal");
        usdg.setPaused(false);
        hybrid.settle(_ids(repaid));
        assertTrue(hybrid.terminal(repaid));
        assertEq(hybrid.cash(), 1050e6);
        assertEq(hybrid.performingPrincipal(), 0);
        _assertConserved();
    }

    function testBlockedCollateralDoesNotBlockIndependentCashSettlement() public {
        _deposit(lender, 2000e6);
        uint256 defaulted = _fundLoan(1000e6);
        uint256 repaid = _repaid(1000e6);
        vm.warp(_defaultAt(defaulted));
        nvda.setPaused(true);
        hybrid.settle(_two(defaulted, repaid));
        assertTrue(hybrid.terminal(repaid));
        assertFalse(hybrid.terminal(defaulted));
        assertEq(uint256(_state(defaulted)), uint256(V2State.DEFAULTED));
        assertEq(hybrid.pocketCount(), 0);
        assertEq(hybrid.cash(), 1050e6);
        assertEq(hybrid.feeAccrued(), 0, "the premium remains below the pre-loss high-water mark");
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.overduePrincipal(), 1000e6);
        nvda.setPaused(false);
        hybrid.settle(_ids(defaulted));
        assertTrue(hybrid.terminal(defaulted));
        assertEq(hybrid.pocketCount(), 1);
        assertEq(nvda.balanceOf(address(hybrid)), 100e18);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.overduePrincipal(), 0);
    }

    function testBlockedRecipientsKeepTheirEntitlements() public {
        uint256 shares = _deposit(lender, 2000e6);
        uint256 defaulted = _fundLoan(1000e6);
        uint256 repaid = _fundLoan(1000e6);
        vm.prank(lender);
        hybrid.requestRedeem(shares / 4);
        _repay(repaid);
        vm.warp(_defaultAt(defaulted));
        hybrid.settle(_two(defaulted, repaid));
        hybrid.harvestRewards(_ids(repaid));
        hybrid.serveRequests(1, MAX);
        uint256 claimable = hybrid.claimable(lender);
        uint256 pocket = hybrid.pocketClaimable(1, lender);
        uint256 reward = hybrid.rewardClaimable(lender);
        assertGt(claimable, 0);
        assertGt(pocket, 0);
        assertGt(reward, 0);
        usdg.setBlocked(lender, true);
        nvda.setBlocked(lender, true);
        sgage.setBlocked(lender, true);
        vm.startPrank(lender);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, lender));
        hybrid.claim();
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, lender));
        hybrid.claimPocket(1);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, lender));
        hybrid.claimRewards();
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, lender));
        hybrid.redeem(1e18, 0);
        vm.stopPrank();
        assertEq(hybrid.claimable(lender), claimable);
        assertEq(hybrid.pocketClaimable(1, lender), pocket);
        assertEq(hybrid.rewardClaimable(lender), reward);
        assertEq(hybrid.balanceOf(lender), shares - shares / 4);
        usdg.setBlocked(lender, false);
        nvda.setBlocked(lender, false);
        sgage.setBlocked(lender, false);
        vm.startPrank(lender);
        assertEq(hybrid.claim(), claimable);
        assertEq(hybrid.claimPocket(1), pocket);
        assertEq(hybrid.claimRewards(), reward);
        vm.stopPrank();
        _assertConserved();
    }

    function testTwoCoreRepaymentsAreAttributedOnceEvenIfSettledSeparately() public {
        _deposit(lender, 2000e6);
        uint256 first = _fundLoan(1000e6);
        uint256 second = _list(other, address(nvda), 100e18, 1000e6, 1050e6, T7);
        _approve(second);
        hybrid.fund(second, MAX);
        _repay(first);
        _repay(second);
        assertEq(vault.cashCredit(address(hybrid)), 2100e6);
        hybrid.settle(_ids(second));
        assertEq(hybrid.harvestedCash(), 2100e6);
        assertEq(hybrid.assignedCash(), 2100e6);
        assertEq(hybrid.cash(), 2090e6);
        assertTrue(hybrid.terminal(first));
        assertTrue(hybrid.terminal(second));
        hybrid.settle(_ids(first));
        hybrid.settle(_two(first, second));
        assertEq(hybrid.assignedCash(), 2100e6);
        assertEq(hybrid.cash(), 2090e6);
        assertEq(hybrid.feeAccrued(), 10e6);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.borrowerPrincipal(borrower) + hybrid.borrowerPrincipal(other), 0);
        _assertConserved();
    }

    function testRewardDependencyFailureDoesNotBlockCashSettlement() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.mockCallRevert(
            address(coreRewards), abi.encodeWithSelector(coreRewards.claimable.selector), "reward failure"
        );
        hybrid.harvestRewards(_ids(id));
        _repay(id);
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.cash(), 1045e6);
        vm.clearMockedCalls();
        vm.prank(lender);
        assertEq(hybrid.redeem(1000e18, 1000e6), 1000e6);
    }

    function testHarvestCreditsOnlyRewardsThatActuallyArrived() public {
        _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7);
        uint256 due = coreRewards.claimable(id, address(hybrid));
        assertGt(due, 0);
        vm.mockCall(address(coreRewards), abi.encodeWithSelector(coreRewards.claim.selector), bytes(""));
        hybrid.harvestRewards(_ids(id));
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        assertEq(sgage.balanceOf(address(hybrid)), 0, "the entitlement is recorded before delivery succeeds");
        vm.prank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimRewards();
        vm.clearMockedCalls();
        hybrid.harvestRewards(_ids(id));
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        vm.prank(lender);
        assertApproxEqAbs(hybrid.claimRewards(), due, 1000);
    }

    // ---------------------------------------------------------------- pooled share mechanics

    function testFirstDepositorInflationIsNeutralisedByVirtualShares() public {
        _deposit(other, 1e6);
        assertEq(hybrid.totalSupply(), 1e18);
        hybrid.investReserve(1e6, 1);
        // The attacker inflates the reserve position fifty-thousandfold before the victim arrives.
        usdg.mint(address(this), 50_000e6);
        usdg.approve(address(reserve), 50_000e6);
        reserve.donate(50_000e6);
        assertApproxEqAbs(hybrid.totalAssets(), 50_001e6, 1e5);
        uint256 victim = _deposit(lender, 1000e6);
        assertGt(victim, 1e15, "the victim still receives a meaningful number of shares");
        uint256 value = hybrid.convertToAssets(victim);
        assertLe(value, 1000e6);
        assertGe(value, 1000e6 - 1, "rounding costs the victim at most one unit");
        uint256 before_ = usdg.balanceOf(lender);
        vm.prank(lender);
        hybrid.redeem(victim, 1000e6 - 1);
        assertGe(usdg.balanceOf(lender) - before_, 1000e6 - 1);
        assertLe(hybrid.convertToAssets(hybrid.balanceOf(other)), 50_001e6, "the attacker never gets more back");
        // The smallest allowed deposit is equally safe.
        uint256 tiny = _deposit(lender2, 1e6);
        assertGt(tiny, 0);
        assertGe(hybrid.convertToAssets(tiny), 1e6 - 1);
    }

    function testDirectDonationsOfUSDGOrReserveSharesNeverMoveThePrice() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(500e6, 1);
        uint256 assetsBefore = hybrid.totalAssets();
        uint256 quote = hybrid.convertToShares(1000e6);
        usdg.mint(address(hybrid), 5000e6);
        usdg.mint(address(this), 1000e6);
        usdg.approve(address(reserve), 1000e6);
        reserve.deposit(1000e6, address(this));
        reserve.transfer(address(hybrid), reserve.balanceOf(address(this)));
        assertEq(hybrid.totalAssets(), assetsBefore);
        assertEq(hybrid.convertToShares(1000e6), quote);
        assertEq(hybrid.reserveShares(), 500e18);
        assertEq(_deposit(lender2, 1000e6), 1000e18);
        vm.prank(lender);
        assertEq(hybrid.redeem(1000e18, 0), 1000e6);
        vm.prank(lender2);
        assertEq(hybrid.redeem(1000e18, 0), 1000e6);
        assertEq(hybrid.totalSupply(), 0);
        assertEq(hybrid.totalAssets(), 0);
    }

    function testDepositingDuringTheUnlockPaysForProfitAndCannotExitAtPar() public {
        _deposit(lender, 1000e6);
        uint256 id = _repaid(1000e6);
        hybrid.settle(_ids(id));
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK() / 2);
        uint256 mid = hybrid.totalAssets();
        assertApproxEqAbs(mid, 1_022_500_000, 1);
        uint256 shares = _deposit(lender2, 1000e6);
        assertEq(hybrid.totalAssets(), mid + 1000e6);
        vm.prank(lender2);
        uint256 back = hybrid.redeem(shares, 0);
        assertLt(back, 1000e6, "an immediate exit gives up the still-locked part of the purchased profit");
        assertGt(back, 980e6);
        assertApproxEqAbs(hybrid.totalAssets(), mid + 1000e6 - back, 2);
        _unlock();
        assertApproxEqAbs(hybrid.convertToAssets(hybrid.balanceOf(lender)), 1045e6 + 1000e6 - back, 2);
    }

    function testLeavingAfterWriteDownKeepsRecoveryAndEntrantCannotCaptureIt() public {
        uint256 first = _deposit(lender, 1000e6);
        uint256 second = _deposit(lender2, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_ids(id));
        assertEq(hybrid.totalAssets(), 1000e6);
        vm.prank(lender2);
        assertEq(hybrid.redeem(second, 0), 500e6, "sold at the impaired price");
        uint256 entrant = _deposit(other, 500e6);
        assertApproxEqRel(entrant, 1000e18, 1e10, "bought at the impaired price");
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
        (,,, uint256 supply,) = hybrid.pockets(1);
        assertEq(supply, first + second);
        assertEq(hybrid.balanceOfAt(lender2, 1), second);
        assertApproxEqRel(hybrid.pocketClaimable(1, lender2), 50e18, 1e10);
        assertEq(hybrid.balanceOfAt(other, 1), 0);
        assertEq(hybrid.pocketClaimable(1, other), 0);
        vm.prank(other);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimPocket(1);
        assertApproxEqRel(hybrid.pocketClaimable(1, lender), 50e18, 1e10);
        vm.prank(lender2);
        assertApproxEqRel(hybrid.claimPocket(1), 50e18, 1e10);
        assertGt(entrant, 0);
        assertEq(hybrid.totalAssets(), 1000e6, "the 500 sold plus the 500 bought; collateral is never priced");
        _assertConserved();
    }

    function testTheFeeUsesTheRateSnapshottedAtFundingNotAtApprovalOrSettlement() public {
        _deposit(lender, 2000e6);
        uint256 id = _listed(1000e6);
        _approve(id);
        vm.prank(curator);
        hybrid.setFee(2000);
        hybrid.fund(id, MAX);
        assertEq(hybrid.loanFeeBps(id), 2000);
        vm.prank(curator);
        hybrid.setFee(5000);
        _repay(id);
        hybrid.settle(_ids(id));
        assertEq(hybrid.feeAccrued(), 10e6, "20% of the 50 premium");
        assertEq(hybrid.cash(), 2040e6);
        // A written-down loan repaid in grace is a recovery for the write-down holders, not strategy profit.
        uint256 late = _fundLoan(1000e6);
        assertEq(hybrid.loanFeeBps(late), 5000);
        vm.prank(curator);
        hybrid.setFee(0);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_ids(late));
        _repay(late);
        hybrid.settle(_ids(late));
        assertEq(hybrid.feeAccrued(), 10e6);
        assertEq(hybrid.cash(), 1040e6);
        assertEq(hybrid.overduePrincipal(), 0);
        assertEq(hybrid.pocketCount(), 1);
        (uint256 dealId, address token, uint256 amount, uint256 supply, uint256 claimed) = hybrid.pockets(1);
        assertEq(dealId, late);
        assertEq(token, address(usdg));
        assertEq(amount, 1050e6);
        assertEq(supply, hybrid.totalSupply());
        assertEq(claimed, 0);
    }

    /// @dev Intended mark semantics (SHARE-VAULT-STUDY 4.6): a loss is recovered before any fee is charged, whether or
    /// not a fee was ever charged before it.
    function testALossBeforeAnyFeeIsCarriedForwardToTheMark() public {
        _deposit(lender, 2000e6);
        _defaulted(1000e6);
        assertEq(hybrid.totalAssets(), 1000e6, "half the initial price");
        uint256 recovered = _repaid(1000e6);
        hybrid.settle(_ids(recovered));
        assertEq(hybrid.feeAccrued(), 0, "recovering to 1050 of 2000 is below the initial price: no fee");
        assertEq(hybrid.fullAssets(), 1050e6);
        _unlock();
        uint256 crossing = _bigPremium();
        _repay(crossing);
        hybrid.settle(_ids(crossing));
        // Full assets 2050 against the 2000 the holders paid: only the 50 above it pays the 10% fee.
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(hybrid.fullAssets(), 2045e6);
    }

    /// @dev Intended mark semantics: the mark follows every new high, so a profit earned at a zero rate cannot be
    /// treated as a new high again by a later non-zero rate after a loss.
    function testAZeroRateProfitStillRaisesTheMark() public {
        _deposit(lender, 3000e6);
        uint256 a = _repaid(1000e6);
        hybrid.settle(_ids(a));
        // One unit of tolerance throughout: the mark is a truncated price, so a fee on the excess can round down.
        assertApproxEqAbs(hybrid.feeAccrued(), 5e6, 1);
        _unlock();
        vm.prank(curator);
        hybrid.setFee(0);
        uint256 b = _bigPremium();
        _repay(b);
        hybrid.settle(_ids(b));
        assertApproxEqAbs(hybrid.feeAccrued(), 5e6, 1);
        assertApproxEqAbs(hybrid.fullAssets(), 4045e6, 1);
        _unlock();
        vm.prank(curator);
        hybrid.setFee(1000);
        _defaulted(1000e6);
        assertApproxEqAbs(hybrid.fullAssets(), 3045e6, 1, "back to the price of the last fee");
        uint256 d = _repaid(1000e6);
        hybrid.settle(_ids(d));
        assertApproxEqAbs(
            hybrid.feeAccrued(), 5e6, 1, "3095 is below the 4045 high: nothing is charged until it is recovered"
        );
        assertApproxEqAbs(hybrid.fullAssets(), 3095e6, 1);
    }

    function testLockedProfitAbsorbsALossBeforeThePriceMoves() public {
        _deposit(lender, 2000e6);
        uint256 small = _fundLoan(30e6);
        uint256 big = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7 - 1);
        _repay(big);
        hybrid.settle(_ids(big));
        vm.warp(block.timestamp + 1);
        uint256 locked = hybrid.lockedProfitNow();
        uint256 priced = hybrid.totalAssets();
        assertApproxEqAbs(locked, 15e6, 100, "the pending loss is already netted from the displayed lock");
        vm.expectEmit(true, false, false, true);
        emit HybridVault.LossReported(small, 30e6, 30e6);
        hybrid.markOverdue(_ids(small));
        assertEq(hybrid.lockedProfitNow(), locked);
        assertEq(hybrid.fullAssets(), 2015e6);
        assertEq(hybrid.totalAssets(), priced, "recording the already-priced loss does not move the price");
        // A repayment after write-down, still inside the core's grace, is recovery for the holders of record,
        // never strategy profit. The core closes repayment at the end of that window (D106).
        vm.warp(_defaultAt(small) - 1);
        _repay(small);
        hybrid.settle(_ids(small));
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(hybrid.fullAssets(), 2015e6);
        _unlock();
        assertEq(hybrid.totalAssets(), 2015e6);
        (uint256 dealId, address token, uint256 amount,,) = hybrid.pockets(1);
        assertEq(dealId, small);
        assertEq(token, address(usdg));
        assertEq(amount, 31.5e6);
    }

    function testADefaultNeverMarkedOverdueIsWrittenDownAtSettlementAgainstLockedProfit() public {
        _deposit(lender, 2000e6);
        uint256 small = _fundLoan(30e6);
        uint256 big = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7 - 1);
        _repay(big);
        hybrid.settle(_ids(big));
        vm.warp(_defaultAt(small));
        uint256 locked = hybrid.lockedProfitNow();
        uint256 rawLock = uint256(45e6) * (5 days - 1) / 7 days;
        assertApproxEqAbs(locked, rawLock - 30e6, 1, "the pending default is already netted from the lock");
        uint256 priced = hybrid.totalAssets();
        vm.expectEmit(true, false, false, true);
        emit HybridVault.LossReported(small, 30e6, 30e6);
        hybrid.settle(_ids(small));
        assertTrue(hybrid.overdue(small));
        assertTrue(hybrid.terminal(small));
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.overduePrincipal(), 0);
        assertEq(hybrid.lockedProfitNow(), locked);
        assertEq(hybrid.totalAssets(), priced);
        assertEq(hybrid.pocketCount(), 1);
    }

    function testServeRequestsRespectsMaxRequestsAndMaxAssetsAndSkipsCancelled() public {
        uint256 a = _deposit(lender, 100e6);
        uint256 b = _deposit(lender2, 100e6);
        uint256 c = _deposit(other, 100e6);
        vm.prank(lender);
        uint256 ra = hybrid.requestRedeem(a);
        vm.prank(lender2);
        uint256 rb = hybrid.requestRedeem(b);
        vm.prank(other);
        uint256 rc = hybrid.requestRedeem(c);
        vm.prank(lender2);
        hybrid.cancelRequest(rb);
        hybrid.serveRequests(0, MAX);
        assertEq(hybrid.requestHead(), ra);
        hybrid.serveRequests(1, MAX);
        assertEq(hybrid.claimable(lender), 100e6);
        assertEq(hybrid.requestHead(), rb);
        hybrid.serveRequests(10, 40e6);
        assertEq(hybrid.claimable(other), 40e6, "the cancelled request is skipped and the next one is served in part");
        assertEq(hybrid.requestHead(), rc, "a partial fill stays at the head");
        (, uint256 remaining) = hybrid.requests(rc);
        assertEq(remaining, 60e18);
        assertEq(hybrid.lockedShares(other), 60e18);
        assertEq(hybrid.pendingShares(), 60e18);
        hybrid.serveRequests(10, 0);
        assertEq(hybrid.claimable(other), 40e6);
        hybrid.serveRequests(10, MAX);
        assertEq(hybrid.claimable(other), 100e6);
        assertEq(hybrid.requestHead(), rc + 1);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.claimableTotal(), 200e6);
        assertEq(hybrid.cash(), 100e6);
        assertEq(hybrid.balanceOf(lender2), b);
        vm.prank(other);
        assertEq(hybrid.claim(), 100e6);
        vm.prank(other);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claim();
        _assertConserved();
    }

    function testRequestsAreServedAtTheServicePriceNotTheRequestPrice() public {
        vm.prank(curator);
        hybrid.setFee(0);
        _deposit(lender, 1000e6);
        uint256 second = _deposit(lender2, 1000e6);
        uint256 id = _fundLoan(1500e6);
        vm.prank(lender2);
        hybrid.requestRedeem(second);
        assertEq(hybrid.pendingRequestAssets(), 1000e6);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_ids(id));
        assertEq(hybrid.pendingRequestAssets(), 250e6);
        hybrid.serveRequests(1, MAX);
        assertEq(hybrid.claimable(lender2), 250e6, "served whole at the impaired price");
        assertEq(hybrid.balanceOf(lender2), 0);
        assertEq(hybrid.pendingShares(), 0);
        _repay(id);
        hybrid.settle(_ids(id));
        _unlock();
        // The remaining shares keep the 250 of priced cash. The late 1575 repayment belongs equally to the
        // two holders snapshotted at write-down, including the requester whose shares were served afterward.
        assertApproxEqAbs(hybrid.convertToAssets(hybrid.balanceOf(lender)), 250e6, 5);
        assertEq(hybrid.pocketClaimable(1, lender), 787_500_000);
        assertEq(hybrid.pocketClaimable(1, lender2), 787_500_000);
        vm.prank(lender);
        hybrid.claimPocket(1);
        vm.prank(lender2);
        hybrid.claimPocket(1);
        _assertConserved();
    }

    /// @dev A request worth nothing at today's price must not stall everyone behind it: it is handed back unserved.
    function testDustRequestAtTheHeadCannotBlockTheQueue() public {
        _deposit(other, 1e6);
        vm.prank(other);
        uint256 dust = hybrid.requestRedeem(1);
        uint256 shares = _deposit(lender, 1000e6);
        vm.prank(lender);
        uint256 real = hybrid.requestRedeem(shares);
        assertEq(hybrid.pendingRequestAssets(), 1000e6);
        vm.expectEmit(true, true, false, true);
        emit HybridVault.RequestCancelled(dust, other, 1);
        hybrid.serveRequests(10, MAX);
        assertEq(hybrid.claimable(lender), 1000e6, "a worthless request ahead must not block a fundable one");
        assertEq(hybrid.requestHead(), real + 1);
        assertEq(hybrid.lockedShares(other), 0);
        assertEq(hybrid.balanceOf(other), 1e18, "the dust shares stay owned");
        assertEq(hybrid.pendingShares(), 0);
        (, uint256 remaining) = hybrid.requests(dust);
        assertEq(remaining, 0);
        _assertConserved();
    }

    function testFundRevertsRequestsPendingOnlyWhenTheRemainingLiquidityIsShort() public {
        _deposit(lender, 1000e6);
        _deposit(lender2, 1000e6);
        _fundLoan(1000e6);
        vm.prank(lender2);
        hybrid.requestRedeem(500e18);
        assertEq(hybrid.pendingRequestAssets(), 500e6);
        uint256 fits = _listed(500e6);
        _approve(fits);
        hybrid.fund(fits, MAX);
        assertEq(hybrid.cash(), 500e6, "exactly the pending amount remains");
        uint256 over = _listed(1e6);
        _approve(over);
        vm.expectRevert(HybridVault.RequestsPending.selector);
        hybrid.fund(over, MAX);
        hybrid.serveRequests(1, MAX);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.cash(), 0, "serving the request consumed the liquidity it was promised");
        vm.prank(lender2);
        hybrid.claim();
        _assertConserved();
    }

    function testPocketClaimsFollowTheHoldersOfRecordAndLeaveRoundingDust() public {
        uint256 first = _deposit(lender, 1000e6);
        uint256 second = _deposit(lender2, 1000e6);
        _deposit(other, 1000e6);
        _defaulted(1000e6);
        uint256 each = uint256(100e18) / 3;
        assertEq(hybrid.pocketClaimable(1, lender), each);
        // Leaving after the pocket keeps the claim; arriving after it earns none.
        vm.prank(lender2);
        hybrid.redeem(second, 0);
        uint256 late = _deposit(borrower, 1000e6);
        assertEq(hybrid.balanceOfAt(lender2, 1), second);
        assertEq(hybrid.balanceOfAt(borrower, 1), 0);
        assertEq(hybrid.balanceOfAt(lender, 1), first);
        vm.prank(lender2);
        assertEq(hybrid.claimPocket(1), each);
        vm.prank(lender2);
        vm.expectRevert(HybridVault.AlreadyClaimed.selector);
        hybrid.claimPocket(1);
        assertEq(hybrid.pocketClaimable(1, lender2), 0);
        vm.prank(borrower);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimPocket(1);
        assertFalse(hybrid.pocketClaimed(1, borrower), "a reverted claim records nothing");
        vm.expectRevert(HybridVault.UnknownDeal.selector);
        hybrid.claimPocket(2);
        vm.prank(lender);
        assertEq(hybrid.claimPocket(1), each);
        vm.prank(other);
        assertEq(hybrid.claimPocket(1), each);
        (,,,, uint256 claimed) = hybrid.pockets(1);
        assertEq(claimed, 3 * each);
        assertEq(nvda.balanceOf(address(hybrid)), 1, "rounding dust stays in the vault");
        assertEq(hybrid.balanceOf(borrower), late);
    }

    function testBalanceOfAtAcrossStaggeredPocketsAndBalanceChanges() public {
        uint256 start = block.timestamp;
        uint256 first = _deposit(lender, 1000e6);
        uint256 a = _fundLoan(300e6);
        vm.warp(start + 3 days);
        uint256 b = _fundLoan(200e6);
        vm.warp(start + 6 days);
        uint256 c = _fundLoan(100e6);
        vm.warp(_defaultAt(a));
        hybrid.settle(_ids(a));
        uint256 joined = _deposit(lender2, 500e6);
        vm.warp(_defaultAt(b));
        hybrid.settle(_ids(b));
        vm.prank(lender);
        hybrid.redeem(100e18, 0);
        vm.warp(_defaultAt(c));
        hybrid.settle(_ids(c));
        _deposit(lender, 100e6);
        assertEq(hybrid.pocketCount(), 3);
        assertEq(hybrid.balanceOfAt(lender, 1), first);
        assertEq(hybrid.balanceOfAt(lender, 2), first);
        assertEq(hybrid.balanceOfAt(lender, 3), first - 100e18);
        assertEq(hybrid.balanceOfAt(lender, 4), hybrid.balanceOf(lender), "an unknown pocket reads the live balance");
        assertEq(hybrid.balanceOfAt(lender2, 1), 0);
        assertEq(hybrid.balanceOfAt(lender2, 2), joined);
        assertEq(hybrid.balanceOfAt(lender2, 3), joined);
        (,,, uint256 supply2,) = hybrid.pockets(2);
        (,,, uint256 supply3,) = hybrid.pockets(3);
        assertEq(supply2, first + joined);
        assertEq(supply3, first - 100e18 + joined);
        assertEq(hybrid.pocketClaimable(1, lender), 100e18);
        assertEq(hybrid.pocketClaimable(1, lender2), 0);
        for (uint256 pk = 2; pk <= 3; ++pk) {
            assertApproxEqAbs(hybrid.pocketClaimable(pk, lender) + hybrid.pocketClaimable(pk, lender2), 100e18, 2);
        }
        assertGt(hybrid.pocketClaimable(3, lender2), hybrid.pocketClaimable(2, lender2));
        vm.startPrank(lender);
        hybrid.claimPocket(1);
        hybrid.claimPocket(2);
        hybrid.claimPocket(3);
        vm.stopPrank();
        vm.startPrank(lender2);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimPocket(1);
        hybrid.claimPocket(2);
        hybrid.claimPocket(3);
        vm.stopPrank();
        assertLe(nvda.balanceOf(address(hybrid)), 4);
    }

    function testRewardsAccruedBeforeExitStayWithTheIncumbentWhenSupplyDropsToZero() public {
        uint256 shares = _deposit(lender, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7 / 2);
        _repay(id);
        uint256 due = coreRewards.claimable(id, address(hybrid));
        assertGt(due, 0);
        hybrid.settle(_ids(id));
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        vm.prank(lender);
        hybrid.redeem(shares, 0);
        assertEq(hybrid.totalSupply(), 0);
        hybrid.harvestRewards(_ids(id));
        assertEq(hybrid.rewardRemainder(), 0);
        assertApproxEqAbs(hybrid.rewardClaimable(lender), due, 1000);
        uint256 next = _deposit(lender2, 1000e6);
        hybrid.harvestRewards(_ids(id));
        assertEq(hybrid.rewardRemainder(), 0);
        assertGt(next, 0);
        assertEq(hybrid.rewardClaimable(lender2), 0, "a later holder cannot capture an incumbent's reward");
        vm.prank(lender);
        uint256 paid = hybrid.claimRewards();
        assertEq(sgage.balanceOf(lender), paid);
        assertApproxEqAbs(paid, due, 1000);
    }

    function testRewardsAccruedBeforeAFullRedemptionRemainClaimable() public {
        uint256 first = _deposit(lender, 1000e6);
        _deposit(lender2, 1000e6);
        uint256 id = _fundLoan(1000e6);
        vm.warp(block.timestamp + T7);
        _repay(id);
        hybrid.settle(_ids(id));
        hybrid.harvestRewards(_ids(id));
        uint256 owed = hybrid.rewardClaimable(lender);
        assertGt(owed, 0);
        vm.prank(lender);
        hybrid.redeem(first, 0);
        assertEq(hybrid.balanceOf(lender), 0);
        assertEq(hybrid.rewardClaimable(lender), owed);
        vm.prank(lender);
        assertEq(hybrid.claimRewards(), owed);
        assertEq(sgage.balanceOf(lender), owed);
        vm.prank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimRewards();
        assertEq(hybrid.rewardClaimable(lender2), owed);
        hybrid.harvestRewards(_ids(id));
        assertEq(hybrid.rewardClaimable(lender2), owed, "nothing new to release");
    }

    function testFinalBurnParksOnlyUnallocatedRewardDust() public {
        uint256 first = _deposit(lender, 123_456_789);
        sgage.mint(address(hybrid), 124);
        uint256 second = _deposit(lender2, 100_000_003);
        sgage.mint(address(hybrid), 447);

        vm.prank(lender);
        hybrid.redeem(first, 0);
        assertEq(hybrid.rewardClaimable(lender), 370);
        vm.prank(lender2);
        hybrid.redeem(second, 0);
        assertEq(hybrid.rewardRemainder(), 0);
        assertEq(hybrid.rewardClaimable(lender2), 200);
        assertEq(hybrid.rewardClaimable(lender) + hybrid.rewardClaimable(lender2), 570);

        vm.prank(lender);
        assertEq(hybrid.claimRewards(), 370);
        vm.prank(lender2);
        assertEq(hybrid.claimRewards(), 200);
        assertEq(sgage.balanceOf(address(hybrid)), 1);
    }

    function testWithdrawAndRedeemAreBoundedByLockedShares() public {
        uint256 shares = _deposit(lender, 1000e6);
        vm.startPrank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.requestRedeem(0);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.requestRedeem(shares + 1);
        uint256 id = hybrid.requestRedeem(600e18);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.requestRedeem(400e18 + 1);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.redeem(400e18 + 1, 0);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.withdraw(400e6 + 1, MAX);
        assertEq(hybrid.redeem(200e18, 200e6), 200e6);
        assertEq(hybrid.withdraw(200e6, 200e18), 200e18);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.redeem(1, 0);
        hybrid.cancelRequest(id);
        assertEq(hybrid.redeem(600e18, 600e6), 600e6);
        vm.stopPrank();
        assertEq(hybrid.balanceOf(lender), 0);
        assertEq(hybrid.totalSupply(), 0);
    }

    function testRedeemAndWithdrawAmountAndSlippageBounds() public {
        _deposit(lender, 1000e6);
        vm.startPrank(lender);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.redeem(0, 0);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.withdraw(0, MAX);
        vm.expectRevert(HybridVault.Slippage.selector);
        hybrid.redeem(100e18, 100e6 + 1);
        vm.expectRevert(HybridVault.Slippage.selector);
        hybrid.withdraw(100e6, 100e18 - 1);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.withdraw(1000e6 + 1, MAX);
        vm.stopPrank();
        assertEq(hybrid.balanceOf(lender), 1000e18);
        // An exact withdrawal rounds the shares burned up, never down.
        uint256 id = _repaid(500e6);
        hybrid.settle(_ids(id));
        _unlock();
        uint256 quoted = hybrid.previewWithdraw(1e6);
        assertGe(quoted, hybrid.convertToShares(1e6));
        uint256 value = hybrid.convertToAssets(quoted);
        assertGe(value + 1, 1e6);
        vm.prank(lender);
        assertEq(hybrid.withdraw(1e6, MAX), quoted);
    }

    function testMaxViewsFollowTheReserveLimitsAndLockedShares() public {
        uint256 shares = _deposit(lender, 1000e6);
        _deposit(lender2, 1000e6);
        hybrid.investReserve(1200e6, 1);
        // The fixture reserve reports zero limits, like the live Morpho vault: that is not a limit of zero.
        assertEq(hybrid.maxWithdraw(lender), 1000e6);
        assertEq(hybrid.maxRedeem(lender), shares);
        assertEq(hybrid.freeLiquidity(), 2000e6);
        reserve.setReportZeroMax(false);
        assertEq(hybrid.maxWithdraw(lender), 1000e6);
        assertEq(hybrid.maxRedeem(lender), shares);
        reserve.setLimits(MAX, 100e6, MAX);
        assertEq(hybrid.maxWithdraw(lender), 900e6);
        assertEq(hybrid.maxRedeem(lender), 900e18);
        vm.prank(lender);
        hybrid.requestRedeem(800e18);
        assertEq(hybrid.maxRedeem(lender), 200e18);
        assertEq(hybrid.maxWithdraw(lender), 200e6);
        vm.prank(lender);
        assertEq(hybrid.withdraw(200e6, 200e18), 200e18);
        assertEq(hybrid.maxWithdraw(lender), 0);
        assertEq(hybrid.maxRedeem(lender), 0);
        assertEq(hybrid.maxWithdraw(lender2), 700e6);
        assertEq(hybrid.maxRedeem(lender2), 700e18);
    }

    function testInsufficientLiquidityIsRaisedBeforeAnyReserveCall() public {
        _deposit(lender, 1000e6);
        hybrid.investReserve(1000e6, 1);
        _fundLoan(600e6);
        assertEq(hybrid.cash(), 0);
        assertApproxEqAbs(reserve.convertToAssets(hybrid.reserveShares()), 400e6, 1);
        vm.mockCallRevert(address(reserve), abi.encodeWithSelector(reserve.withdraw.selector), "reserve down");
        vm.prank(lender);
        vm.expectRevert(HybridVault.InsufficientLiquidity.selector);
        hybrid.redeem(500e18, 0);
        vm.prank(lender);
        vm.expectRevert(HybridVault.InsufficientLiquidity.selector);
        hybrid.withdraw(400e6 + 1, MAX);
        vm.prank(lender);
        vm.expectRevert(bytes("reserve down"));
        hybrid.redeem(100e18, 0);
        vm.clearMockedCalls();
        vm.prank(lender);
        assertEq(hybrid.redeem(100e18, 100e6 - 1), 100e6);
    }

    function testAnyoneMayInvestTheReserveButOnlyTheCuratorDivests() public {
        _deposit(lender, 1000e6);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.investReserve(0, 0);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.investReserve(1000e6 + 1, 0);
        vm.expectRevert(HybridVault.Slippage.selector);
        hybrid.investReserve(100e6, 100e18 + 1);
        reserve.setLimits(0, MAX, MAX);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(hybrid), 100e6, 0));
        hybrid.investReserve(100e6, 0);
        reserve.setLimits(MAX, MAX, MAX);
        vm.prank(other);
        uint256 shares = hybrid.investReserve(600e6, 600e18);
        assertEq(shares, 600e18);
        assertEq(hybrid.cash(), 400e6);
        assertEq(hybrid.reserveShares(), shares);
        assertEq(hybrid.totalAssets(), 1000e6);
        vm.prank(other);
        vm.expectRevert(HybridVault.NotCurator.selector);
        hybrid.divestReserve(shares, 0);
        vm.startPrank(curator);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.divestReserve(0, 0);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.divestReserve(shares + 1, 0);
        vm.expectRevert(HybridVault.Slippage.selector);
        hybrid.divestReserve(shares, 600e6 + 1);
        vm.stopPrank();
        // A reserve that refuses withdrawals leaves the queue as the exit path; the curator can still divest later.
        reserve.setLimits(MAX, 0, 0);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, address(hybrid), 200e6, 0));
        hybrid.redeem(600e18, 0);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, address(hybrid), shares, 0));
        hybrid.divestReserve(shares, 0);
        reserve.setLimits(MAX, MAX, MAX);
        vm.prank(curator);
        assertEq(hybrid.divestReserve(shares, 600e6), 600e6);
        assertEq(hybrid.cash(), 1000e6);
        assertEq(hybrid.reserveShares(), 0);
        _assertConserved();
    }

    function testMarkOverdueIsIdempotentAndIgnoresLoansThatAreNotActive() public {
        _deposit(lender, 2000e6);
        uint256 active = _fundLoan(1000e6);
        uint256 open = _listed(400e6);
        _approve(open, 1);
        hybrid.fund(open, MAX);
        vm.warp(block.timestamp + T7);
        hybrid.markOverdue(_two(active, open));
        hybrid.markOverdue(_two(open, active));
        assertTrue(hybrid.overdue(active));
        assertFalse(hybrid.overdue(open));
        assertEq(hybrid.overduePrincipal(), 1000e6);
        assertEq(hybrid.performingPrincipal(), 100e6);
        _repay(active);
        hybrid.settle(_ids(active));
        assertTrue(hybrid.terminal(active));
        hybrid.markOverdue(_ids(active));
        assertEq(hybrid.overduePrincipal(), 0);
        assertEq(hybrid.performingPrincipal(), 100e6);
    }

    function testSettleIgnoresLoansThatAreNotTerminalOrAlreadySettled() public {
        _deposit(lender, 2000e6);
        uint256 active = _fundLoan(1000e6);
        uint256 open = _listed(400e6);
        _approve(open, 1);
        hybrid.fund(open, MAX);
        hybrid.settle(_two(active, open));
        assertFalse(hybrid.terminal(active));
        assertFalse(hybrid.terminal(open));
        assertEq(hybrid.cash(), 900e6);
        vm.warp(block.timestamp + T7);
        hybrid.settle(_ids(active));
        assertFalse(hybrid.terminal(active), "past term but inside grace: still open");
        _repay(active);
        hybrid.settle(_ids(active));
        uint256 cash = hybrid.cash();
        uint256 fee = hybrid.feeAccrued();
        hybrid.settle(_two(active, active));
        assertEq(hybrid.cash(), cash);
        assertEq(hybrid.feeAccrued(), fee);
        assertEq(hybrid.assignedCash(), 1050e6);
        assertEq(hybrid.pocketCount(), 1, "duplicate settlement cannot duplicate a recovery pocket");
        _assertConserved();
    }

    function testPartialRequestCancelReleasesOnlyTheRemainder() public {
        uint256 shares = _deposit(lender, 1000e6);
        vm.prank(lender);
        uint256 id = hybrid.requestRedeem(shares);
        hybrid.serveRequests(1, 400e6);
        assertEq(hybrid.claimable(lender), 400e6);
        assertEq(hybrid.lockedShares(lender), 600e18);
        vm.prank(lender);
        hybrid.cancelRequest(id);
        assertEq(hybrid.lockedShares(lender), 0);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.balanceOf(lender), 600e18);
        assertEq(hybrid.claimable(lender), 400e6);
        hybrid.serveRequests(10, MAX);
        assertEq(hybrid.requestHead(), id + 1);
        vm.prank(lender);
        assertEq(hybrid.redeem(600e18, 600e6), 600e6);
        vm.prank(lender);
        assertEq(hybrid.claim(), 400e6);
        _assertConserved();
    }

    function testCashConservationAcrossAFullLifecycle() public {
        _deposit(lender, 3000e6);
        uint256 second = _deposit(lender2, 1000e6);
        _assertConserved();
        hybrid.investReserve(1500e6, 1);
        _assertConserved();
        uint256 repaid = _fundLoan(2000e6);
        uint256 defaulted = _fundLoan(1000e6);
        _assertConserved();
        vm.prank(lender2);
        hybrid.requestRedeem(second / 2);
        hybrid.serveRequests(1, MAX);
        _assertConserved();
        _repay(repaid);
        hybrid.harvestCash();
        _assertConserved();
        hybrid.settle(_ids(repaid));
        assertGt(hybrid.feeAccrued(), 0);
        _assertConserved();
        vm.warp(_defaultAt(defaulted));
        hybrid.settle(_two(repaid, defaulted));
        _assertConserved();
        hybrid.serveRequests(1, MAX);
        assertEq(hybrid.pendingShares(), 0);
        _assertConserved();
        vm.prank(lender2);
        hybrid.claim();
        _assertConserved();
        hybrid.claimFees();
        _assertConserved();
        uint256 reserveShares = hybrid.reserveShares();
        vm.prank(curator);
        hybrid.divestReserve(reserveShares, 0);
        _assertConserved();
        vm.prank(lender);
        hybrid.claimPocket(1);
        _unlock();
        uint256 rest = hybrid.balanceOf(lender2);
        vm.prank(lender2);
        hybrid.redeem(rest, 0);
        uint256 all = hybrid.balanceOf(lender);
        vm.prank(lender);
        hybrid.redeem(all, 0);
        _assertConserved();
        assertEq(hybrid.totalSupply(), 0);
        assertLe(hybrid.cash(), 2, "only conversion dust remains");
        assertEq(usdg.balanceOf(address(hybrid)), hybrid.cash());
    }
}

/// @notice A deliberately faulty external reserve used only to exercise the strategy's defensive accounting.
contract HybridReserveFaultProbe is ERC4626 {
    HybridVault private _hybrid;
    uint256 private _mode;

    constructor(IERC20 asset_) ERC20("Fault probe", "FAULT") ERC4626(asset_) {}

    /// @notice Choose the dependency failure exercised by a test; zero behaves.
    function configure(HybridVault hybrid_, uint256 mode_) external {
        _hybrid = hybrid_;
        _mode = mode_;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (_mode == 1) _hybrid.investReserve(1, 0);
        shares = super.deposit(assets, receiver);
        if (_mode == 3) shares += 1;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner);
        if (_mode == 4) assets += 1;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        if (_mode == 6) return super.withdraw(assets - 1, receiver, owner);
        if (_mode == 7) _hybrid.serveRequests(1, 1);
        shares = super.withdraw(assets, receiver, owner);
        if (_mode == 5) shares += 1;
        if (_mode == 2) {
            _burn(owner, 1);
            shares += 1;
        }
    }
}
