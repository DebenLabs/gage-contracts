// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {MorphoForkBase} from "./HybridMorphoFork.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HybridVault} from "../../src/HybridVault.sol";
import {HybridFees} from "../../src/HybridFees.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {ICollateralRegistry, Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @notice Gas diagnostics use the pinned live reserve and the live V2 engine.
/// @dev Each measured action starts after setUp, with original storage values preserved for transaction gas costs.
///      The pooled vault is one lender: funding, settlement and serving no longer scale with depositors, so the
///      thirty-two holders here only prove that.
abstract contract HybridMorphoGasForkBase is MorphoForkBase {
    uint256 internal constant HALF_TX_GAS_LIMIT = 16_000_000;
    uint256 internal constant HOLDERS = 32;
    uint256 internal constant DEPOSIT = 410e6;
    uint256 internal constant PRINCIPAL = 12_800e6;
    uint256 internal constant CAP = 13_440e6;
    HybridVault internal hybrid;
    HybridFees internal hybridFees;
    GageV2Vault internal core;
    address internal borrower = makeAddr("hybrid-gas-fork-borrower");
    uint256 internal collateralAmount;
    uint256 internal loanId;

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        core = _liveCore();
        ICollateralRegistry registry = ICollateralRegistry(address(core.REGISTRY()));
        ICollateralRegistry.ERC20Config memory cfg = registry.getERC20Config(LIVE_STOCK);
        if (!cfg.allowed || registry.newDealsPaused()) {
            emit log("Live V2 registry does not currently admit this stock token; gas diagnostics skipped.");
            vm.skip(true);
            return;
        }
        assertEq(uint256(cfg.lane), uint256(Lane.STOCK));
        // Enough live stock to price the whole principal under a 1000 USDG ceiling, within the registry cap.
        collateralAmount = Math.min(Math.max(cfg.minAmount, 50e18), cfg.maxDealRaw);
        HybridVault.Params memory params = HybridVault.Params({
            core: address(core),
            reserve: MORPHO_VAULT,
            laneWeights: [uint16(10_000), 0, 0],
            curator: address(this),
            maxLoanTerm: 7 days,
            minReturnBps: 300,
            maxGageExposureBps: 10_000,
            minDeposit: 100e6,
            maxTotalDeposits: 100_000e6
        });
        hybrid = new HybridVault(params);
        hybrid.setTokenCeiling(LIVE_STOCK, 1000e6);
        hybridFees = new HybridFees(address(hybrid), 0, address(0), address(this));
        hybrid.setFees(address(hybridFees));
        hybridFees.setCuratorRecipient(bob);
        hybrid.setFee(1000);
        for (uint256 i; i < HOLDERS; ++i) {
            _deposit(_holder(i), DEPOSIT);
        }
        // Everything idle sits in the real reserve, so every measured action pays through Morpho.
        hybrid.investReserve(hybrid.cash(), 1);
        assertEq(hybrid.cash(), 0);
        assertEq(reserve.balanceOf(address(hybrid)), hybrid.reserveShares());
        assertEq(hybrid.totalSupply(), HOLDERS * hybrid.balanceOf(_holder(0)));
        deal(USDG, borrower, CAP);
        deal(LIVE_STOCK, borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(LIVE_STOCK).approve(address(core), collateralAmount);
        IERC20(USDG).approve(address(core), type(uint256).max);
        loanId = core.list(
            Collateral(Kind.ERC20, LIVE_STOCK, collateralAmount),
            uint128(PRINCIPAL),
            uint128(CAP),
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.stopPrank();
        hybrid.approveLoan(loanId, uint40(block.timestamp + 1 hours), 4);
    }

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    function _deposit(address who, uint256 amount) internal {
        deal(USDG, who, amount);
        vm.startPrank(who);
        IERC20(USDG).approve(address(hybrid), amount);
        hybrid.deposit(amount, 1);
        vm.stopPrank();
    }

    function _ids() internal view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = loanId;
    }

    function _cool() internal {
        vm.cool(address(hybrid));
        vm.cool(address(core));
        vm.cool(address(core.REGISTRY()));
        vm.cool(address(core.REWARDS()));
        vm.cool(MORPHO_VAULT);
        vm.cool(LIQUIDITY_ADAPTER);
        vm.cool(MORPHO_CORE);
        vm.cool(USDG);
        vm.cool(LIVE_STOCK);
    }
}

contract HybridMorphoFundGasForkTest is HybridMorphoGasForkBase {
    function testGasForkFundingAWholeLoanFromTheRealReserveIsOneWithdrawal() public {
        _cool();
        uint256 beforeGas = gasleft();
        hybrid.fund(loanId, type(uint256).max);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Pinned Morpho fund: one reserve withdrawal, 32 holders, cold transaction gas", used);
        // The live engine's own `fund` opens the loan's account and lists on the vault (about 1.45M gas at the pin);
        // the strategy adds one reserve withdrawal and its reads, nothing per holder.
        assertLt(used, HALF_TX_GAS_LIMIT / 4, "funding no longer scales with depositors");
        assertEq(hybrid.performingPrincipal(), PRINCIPAL);
        assertEq(hybrid.positionPrincipal(loanId), PRINCIPAL);
        assertEq(hybrid.cash(), 0);
        assertEq(reserve.balanceOf(address(hybrid)), hybrid.reserveShares());
        assertEq(uint256(core.getLoan(loanId).state), uint256(V2State.ACTIVE));
    }
}

contract HybridMorphoRepaymentGasForkTest is HybridMorphoGasForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        hybrid.fund(loanId, type(uint256).max);
        vm.prank(borrower);
        core.reclaim(loanId, borrower);
    }

    function testGasForkRepaidSettlementWithFeeAndProfitLock() public {
        uint256[] memory ids = _ids();
        _cool();
        uint256 beforeGas = gasleft();
        hybrid.settle(ids);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Pinned core repaid settlement: one pooled lender, cold transaction gas", used);
        assertLt(used, HALF_TX_GAS_LIMIT / 8);
        assertTrue(hybrid.terminal(loanId));
        assertEq(hybrid.performingPrincipal(), 0);
        // The fee is read from the share price, which values the reserve position at Morpho's rounded-down quote.
        uint256 fee = hybrid.feeAccrued();
        assertApproxEqAbs(fee, 64e6, 1, "10% of the whole premium");
        assertEq(hybrid.cash(), CAP - fee, "the cap net of the fee");
        assertEq(hybrid.lockedProfit(), CAP - PRINCIPAL - fee);
        assertGt(hybrid.highWaterPrice(), 0);
    }
}

contract HybridMorphoDefaultGasForkTest is HybridMorphoGasForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        hybrid.fund(loanId, type(uint256).max);
        V2Loan memory l = core.getLoan(loanId);
        vm.warp(uint256(l.fundedAt) + l.term + core.GRACE());
    }

    function testGasForkCollateralSettlementOpensOnePocket() public {
        uint256[] memory ids = _ids();
        _cool();
        uint256 beforeGas = gasleft();
        hybrid.settle(ids);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Pinned core collateral settlement: one side pocket, cold transaction gas", used);
        assertLt(used, HALF_TX_GAS_LIMIT / 8);
        assertEq(hybrid.cash(), 0);
        assertEq(hybrid.feeAccrued(), 0);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.pocketCount(), 1);
        (uint256 dealId, address token, uint256 amount, uint256 supply,) = hybrid.pockets(1);
        assertEq(dealId, loanId);
        assertEq(token, LIVE_STOCK);
        assertEq(amount, collateralAmount);
        assertEq(supply, hybrid.totalSupply());
        assertEq(IERC20(LIVE_STOCK).balanceOf(address(hybrid)), collateralAmount);
        assertEq(uint256(core.getLoan(loanId).state), uint256(V2State.DEFAULTED));
        uint256 cut = Math.mulDiv(collateralAmount, hybrid.balanceOf(_holder(0)), supply);
        vm.prank(_holder(0));
        assertEq(hybrid.claimPocket(1), cut);
    }
}

/// @notice The queue: thirty-two full requests served in one call from cash and the real reserve.
contract HybridMorphoQueueGasForkTest is HybridMorphoGasForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        hybrid.fund(loanId, type(uint256).max);
        vm.prank(borrower);
        core.reclaim(loanId, borrower);
        hybrid.settle(_ids());
        // Once the premium has unlocked the queue is worth more than cash: serving must reach the reserve.
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK());
        for (uint256 i; i < HOLDERS; ++i) {
            address who = _holder(i);
            uint256 held = hybrid.balanceOf(who);
            vm.prank(who);
            hybrid.requestRedeem(held);
        }
        assertEq(hybrid.pendingShares(), hybrid.totalSupply());
    }

    function testGasForkServingThirtyTwoRequestsFromCashAndTheRealReserve() public {
        uint256 pendingAssets = hybrid.pendingRequestAssets();
        _cool();
        uint256 beforeGas = gasleft();
        hybrid.serveRequests(HOLDERS, type(uint256).max);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Pinned Morpho serve: 32 requests, cash then reserve, cold transaction gas", used);
        assertLt(used, HALF_TX_GAS_LIMIT / 2);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.totalSupply(), 0);
        assertEq(hybrid.requestHead(), HOLDERS + 1);
        assertApproxEqAbs(hybrid.claimableTotal(), pendingAssets, HOLDERS);
        assertEq(hybrid.cash(), 0, "cash is spent before the reserve");
        assertEq(
            IERC20(USDG).balanceOf(address(hybrid)),
            hybrid.claimableTotal() + hybrid.feeAccrued(),
            "served USDG and the fee are the only cash left"
        );
        address who = _holder(HOLDERS - 1);
        uint256 owed = hybrid.claimable(who);
        _cool();
        beforeGas = gasleft();
        vm.prank(who);
        hybrid.claim();
        emit log_named_uint("Pinned claim of a served request, cold transaction gas", beforeGas - gasleft());
        assertEq(IERC20(USDG).balanceOf(who), owed);
    }
}

/// @notice A synchronous exit through the real reserve while a loan is outstanding.
contract HybridMorphoRedeemGasForkTest is HybridMorphoGasForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        hybrid.fund(loanId, type(uint256).max);
    }

    function testGasForkRedeemThroughTheRealReserveBesideAnOpenLoan() public {
        address who = _holder(0);
        // The reserve keeps 320 USDG beside the 12,800 loan: half a deposit fits, a whole one does not.
        uint256 half = hybrid.balanceOf(who) / 2;
        uint256 quote = hybrid.convertToAssets(half);
        uint256 free = hybrid.freeLiquidity();
        assertApproxEqAbs(free, HOLDERS * DEPOSIT - PRINCIPAL, 2, "the reserve position is the only free liquidity");
        assertEq(hybrid.maxWithdraw(who), free, "Morpho reports no limit, so the reserve position is the view");
        assertLe(quote, free, "half a deposit fits");
        assertGt(hybrid.convertToAssets(hybrid.balanceOf(who)), free, "a whole deposit does not");
        _cool();
        uint256 beforeGas = gasleft();
        vm.prank(who);
        uint256 paid = hybrid.redeem(half, quote);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("Pinned Morpho redeem: one reserve withdrawal beside a live loan, cold gas", used);
        assertLt(used, HALF_TX_GAS_LIMIT / 8);
        assertEq(paid, quote);
        assertApproxEqAbs(paid, DEPOSIT / 2, 2, "a loan at principal keeps the price flat");
        assertEq(hybrid.balanceOf(who), half);
        assertEq(hybrid.performingPrincipal(), PRINCIPAL);
        assertEq(IERC20(USDG).balanceOf(who), paid);
    }
}
