// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {IntentLaunchAcceptanceForkTest} from "./IntentLaunchAcceptanceFork.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentCategory} from "../../src/intent/IntentVaultState.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {IFunderGate} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan} from "../../src/v2/V2Types.sol";
import {IDealVault} from "../../src/interfaces/IDealVault.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

using {unitsOf} for GageV2Vault;
using {remainingLenderReward} for GageV2Rewards;

/// Local fork acceptance: deploy production registry/core/adapter/factory; retain the real reserve and reward source.
/// Only fixture capital, quote signing, receipt admission and time advancement are controlled. No sGAGE is minted.
contract IntentBridgedAcceptanceForkTest is IntentLaunchAcceptanceForkTest {
    GageLegacyAdapter bridge;
    CollateralRegistry constant legacyRegistry = CollateralRegistry(0x3289a3B6D5a22799cE1443125d629BB78d356181);
    DealRewards constant source = DealRewards(0x93beBb95F24D0Aa971B1dcd8A9FCB26fb8Bc8A51);
    IERC20 constant sgage = IERC20(0xbbdA5456CD50eab033d243b8C49D2aBAb436b0da);

    function _configureDeployment() internal override {
        IntentFactory old = factory;
        GageV2Registry oldRegistry = GageV2Registry(address(core.REGISTRY()));
        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        GageV2TokenRegistry registry = new GageV2TokenRegistry(address(this), terms, oldRegistry.V3_FACTORY());
        registry.setFee(legacyRegistry.feeBps());
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        bridge =
            new GageLegacyAdapter(address(this), IDealVault(0xa76C5974485D09d58e8b904D764caFdF8B9655Ba), source, usdg);
        vm.prank(legacyRegistry.owner());
        legacyRegistry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        core = new GageV2Vault(
            registry, IERC20(address(usdg)), IERC20(address(sgage)), old.protocolRecipient(), 0, bridge
        );
        bridge.setEngine(address(core));
        IntentVaultCode store_ = new IntentVaultCode();
        factory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: old.RESERVE(),
                reserveLens: old.RESERVE_LENS(),
                grades: old.GRADES(),
                protocolRecipient: old.protocolRecipient(),
                initialOwner: address(this),
                codeA: store_.CHUNK_A(),
                codeB: store_.CHUNK_B()
            })
        );
        core.REWARDS().bindFunderGate(IFunderGate(address(factory)));
        factory.assignCategory(address(nvda), IntentCategory.STOCK);
        verifier = new IntentQuoteVerifier(factory);
        router = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), usdg);
        factory.setFillRouter(address(router));
    }

    /// @dev The factory above is built from this source: it admits fillers without a payout (D49).
    function _admitFiller() internal override {
        factory.setFiller(filler, true);
    }

    /// @dev The factory above is built from this source: one `create` takes the secondary policy.
    function _open(IntentVault.Mandate memory m) internal override returns (address) {
        return factory.create(m, true, 300, "Test vault");
    }

    /// @dev The factory above is built from this source, which reports mandate version 11 (D51 on the candidate's
    /// interface).
    function _mandateVersion() internal pure override returns (uint256) {
        return 11;
    }

    /// @dev D51, the rule of this source, in place of D29's release. The booking keeps in the price what it counted
    /// for the loan's day out, so the share price does not move; the rest of the net return becomes one USDG earnings
    /// claim for the shares exposed over the loan's window, and nothing more accrues until the original end. The sole
    /// holder over the window claims it whole: the price part and the claim together are D29's value at the end.
    function test_earlyRepaymentReturnsCollateralAndAccruesToOriginalEnd() public override {
        uint256 id = _list(7 days);
        _fill(id, false);
        vm.warp(block.timestamp + 1 days);
        uint256 assets = a.totalAssets();
        uint256 counted = _accrued(a, id);
        assertGt(counted, 0);
        // Principal and the day's accrual on the net return; the 20 USDG execution fee left priced assets at the fill.
        assertEq(assets, 10_000e6 - 20e6 + counted, "the price counts the accrued part");
        uint256 fee = uint256(80e6) * a.feeBps() / 10_000;
        uint256 rest = 1100e6 - fee - (1000e6 + counted);
        _repay(id);
        a.settle(_ids(id));
        assertEq(a.totalAssets(), assets, "the booking keeps what the price counted");
        assertEq(nvda.balanceOf(borrower), 100e18);
        assertEq(a.performingPrincipal(), 0);
        assertEq(a.curatorFees() + a.protocolFees(), fee, "the performance fee on the whole return, once");
        assertEq(a.pocketCount(), 1);
        (uint256 loanId, address token, uint256 amount, uint256 supply, uint256 claimed, uint64 snapshotId) =
            a.pockets(1);
        assertEq(loanId, id);
        assertEq(token, address(usdg));
        assertEq(amount, rest, "the rest of the net return is the earnings claim");
        assertEq(claimed, 0);
        assertEq(snapshotId, 0, "an earnings claim, weighed by exposure");
        // One reading of the clock over the day: its seconds, less the clock's virtual shares' part.
        uint256 moved = 1 days * 1e33 / (a.totalSupply() + 1e12);
        assertEq(supply, 1 days * 1e33 - 1e12 * moved, "the window is the loan's day");
        assertEq(a.pocketLiability(address(usdg)), rest);
        vm.warp(_maturity(id));
        a.settle(_ids(id));
        assertEq(a.totalAssets(), assets, "nothing more accrues on a repaid loan");
        uint256 claim = a.pocketClaimable(1, alice);
        assertApproxEqAbs(claim, rest, 1, "the sole holder over the window owns the whole claim");
        uint256 wallet = usdg.balanceOf(alice);
        vm.prank(alice);
        assertEq(a.claimPocket(1), claim);
        assertEq(usdg.balanceOf(alice) - wallet, claim);
        assertEq(a.pocketLiability(address(usdg)), rest - claim);
        assertEq(a.pocketClaimable(1, alice), 0, "a claim pays once");
        assertApproxEqAbs(a.totalAssets() + claim, 10_000e6 + 80e6 - fee, 1, "the loan's whole net return");
    }

    /// @dev D51: a repayment in the second the loan's window opened is booked from the next second. In the fill second
    /// the booking waits and nothing moves; one second later the manager and the protocol are paid their fee exactly
    /// once, and the net return beyond the one second the price counted is the holders' earnings claim.
    function test_performanceFeesPayManagerAndProtocolExactlyOnce() public override {
        uint256 id = _list(7 days);
        _fill(id, false);
        _repay(id);
        uint256 assets = a.totalAssets();
        a.settle(_ids(id));
        assertFalse(_settled(a, id), "a repayment in the fill second waits for the next second");
        assertEq(a.curatorFees() + a.protocolFees(), 0);
        assertEq(a.pocketCount(), 0);
        assertEq(a.performingPrincipal(), 1000e6);
        assertEq(a.totalAssets(), assets);
        vm.warp(block.timestamp + 1);
        uint256 counted = _accrued(a, id);
        a.settle(_ids(id));
        assertTrue(_settled(a, id));
        uint256 managerFee = a.curatorFees();
        uint256 protocolFee = a.protocolFees();
        assertGt(managerFee, 0);
        assertEq(managerFee + protocolFee, uint256(80e6) * a.feeBps() / 10_000);
        assertEq(a.totalAssets(), 10_000e6 - 20e6 + counted, "the booking keeps what the price counted");
        assertEq(a.pocketCount(), 1);
        (,, uint256 rest,,,) = a.pockets(1);
        assertEq(rest, 1100e6 - managerFee - protocolFee - (1000e6 + counted), "the rest is the holders' claim");
        assertApproxEqAbs(a.pocketClaimable(1, alice), rest, 1, "the sole holder over the window owns it");
        uint256 m0 = usdg.balanceOf(manager);
        uint256 p0 = usdg.balanceOf(factory.protocolRecipient());
        a.claimFees();
        assertEq(usdg.balanceOf(manager) - m0, managerFee);
        assertEq(usdg.balanceOf(factory.protocolRecipient()) - p0, protocolFee);
        a.claimFees();
        assertEq(usdg.balanceOf(manager) - m0, managerFee);
    }

    /// @dev What the share price has counted for vault `v`'s record of loan `id` now: its schedule's interest so far.
    function _accrued(IntentVault v, uint256 id) internal view returns (uint256) {
        (,,, uint40 maturity,,,,,,,,, uint128 rate, uint64 clockStart,,) = v.loans(id);
        uint256 end = block.timestamp < maturity ? block.timestamp : maturity;
        // The vault's rate precision: interest per second scaled by 1e18.
        return uint256(rate) * (end - clockStart) / 1e18;
    }

    function _settled(IntentVault v, uint256 id) internal view returns (bool settled) {
        (,,,,, settled,,,,,,,,,,) = v.loans(id);
    }

    function test_fiveMinuteTestnetTermRepays() public override {
        vm.expectRevert();
        this.listUnsupported(300);
    }

    function test_twentyMinuteTestnetTermDefaults() public override {
        vm.expectRevert();
        this.listUnsupported(1200);
    }

    function listUnsupported(uint32 term) external {
        _list(term);
    }

    function _invest(uint256 assets) internal {
        uint256 shares = IERC4626(factory.RESERVE()).previewDeposit(assets);
        vm.prank(filler);
        router.investReserve(address(a), assets, shares);
        assertGt(a.reserveShares(), 0);
        assertEq(usdg.allowance(address(a), factory.RESERVE()), 0);
    }

    function test_realReserveFundsLoanThenPaysDepositorExit() public {
        _invest(10_000e6);
        assertEq(a.cash(), 0);
        uint256 id = _list(7 days);
        uint256 reserveBefore = a.reserveShares();
        _fill(id, false);
        assertLt(a.reserveShares(), reserveBefore);
        assertEq(a.performingPrincipal(), 1000e6);
        uint256 wallet = usdg.balanceOf(alice);
        uint256 shares = a.convertToShares(100e6);
        vm.prank(alice);
        a.redeem(shares, 99e6);
        assertGe(usdg.balanceOf(alice) - wallet, 99e6);
    }

    function test_realBridgeDeliversBorrowerAndDepositorRewardsOnce() public {
        uint256 id = _list(7 days);
        _fill(id, false);
        V2Loan memory loan = core.getLoan(id);
        assertGt(loan.borrowerReward, 0);
        assertGt(loan.lenderReward, 0);
        vm.warp(uint256(loan.fundedAt) + 3 days);
        uint256 b0 = sgage.balanceOf(borrower);
        uint256 a0 = sgage.balanceOf(alice);
        GageV2Rewards coreRewards = core.REWARDS();
        vm.prank(borrower);
        coreRewards.claim(id, borrower);
        a.harvestRewards(_ids(id));
        vm.prank(alice);
        uint256 paid = a.claimRewards();
        assertGt(sgage.balanceOf(borrower) - b0, 0);
        assertGt(paid, 0);
        assertEq(sgage.balanceOf(alice) - a0, paid);
        uint256 afterBorrower = sgage.balanceOf(borrower);
        address rewards = address(core.REWARDS());
        vm.prank(borrower);
        vm.expectRevert();
        GageV2Rewards(rewards).claim(id, borrower);
        assertEq(sgage.balanceOf(borrower), afterBorrower);
        a.harvestRewards(_ids(id));
        vm.prank(alice);
        vm.expectRevert();
        a.claimRewards();
        _repay(id);
        a.settle(_ids(id));
        vm.warp(_maturity(id));
        a.settle(_ids(id));
        assertEq(sgage.balanceOf(address(core.REWARDS())), 0);
    }

    function test_realBridgeFullTermDepositorAllocationAndLegacyDefaultSettlement() public {
        uint256 id = _list(21 days);
        _fill(id, true);
        V2Loan memory loan = core.getLoan(id);
        uint256 receipt = bridge.adapterId(address(core), id);
        vm.warp(_maturity(id));
        a.settle(_ids(id));
        b.settle(_ids(id));
        a.recover(id);
        b.recover(id);
        GageV2Rewards coreRewards = core.REWARDS();
        vm.prank(borrower);
        coreRewards.claim(id, borrower);
        a.harvestRewards(_ids(id));
        b.harvestRewards(_ids(id));
        vm.prank(alice);
        uint256 pa = a.claimRewards();
        vm.prank(alice);
        uint256 pb = b.claimRewards();
        assertEq(pa + pb, loan.lenderReward);
        assertEq(sgage.balanceOf(borrower), loan.borrowerReward);
        assertEq(a.pocketClaimable(1, alice) + b.pocketClaimable(1, alice), 10e18);
        vm.warp(block.timestamp + 2 days);
        bridge.settleLegacy(receipt);
        assertEq(bridge.totalSupply(), 0);
        bridge.recycle(receipt);
        assertEq(sgage.balanceOf(address(core.REWARDS())), 0);
    }

    function test_realBridgeSecondarySalePreservesEarnedAndFutureRewards() public {
        // D48 and Pashov L-01 (IntentVault.executeLenderSale): a vault sells only at or above book value plus half the
        // interest still to come, which after the 1% trade fee is above the principal. A buyer holds a bought position
        // at its price (IntentAssetPolicy.quote), so it needs a per-loan limit above the fixture's 1000e6; the
        // listing's cap is the most a buyer can pay and still earn. Another manager's vault: the verifier refuses a
        // buyer run by the seller's own manager (L-01).
        address buyerManager = makeAddr("acceptance buyer manager");
        factory.setCreator(buyerManager, true);
        IntentVault buyer = _createBy(buyerManager, 1500, 1100e6);
        _deposit(buyer, alice, 10_000e6);
        uint256 id = _list(7 days);
        _fill(id, false);
        V2Loan memory loan = core.getLoan(id);
        vm.warp(uint256(loan.fundedAt) + 3 days);
        uint256 earned = core.REWARDS().claimable(id, address(a));
        uint256 assets = a.totalAssets();
        uint128 price = _floorPrice(a, id);
        // One unit below the floor the whole fill reverts and nothing moves.
        _listHolding(id, price - 1);
        (IntentQuoteVerifier.SecondaryPlan memory p, bytes memory signature) = _secondaryPlan(id, buyer);
        vm.prank(filler);
        vm.expectRevert(IntentVault.SaleBelowBook.selector);
        router.fillSecondary(p, signature);
        assertEq(core.unitsOf(id, address(a)), 4);
        assertEq(a.totalAssets(), assets);
        _listHolding(id, price);
        (p, signature) = _secondaryPlan(id, buyer);
        vm.prank(filler);
        router.fillSecondary(p, signature);
        assertEq(core.unitsOf(id, address(a)), 0);
        assertEq(core.unitsOf(id, address(buyer)), 4);
        assertEq(a.totalAssets(), assets, "a sale at the floor never lowers the share price");
        assertApproxEqAbs(a.rewardClaimable(alice), earned, 10_000);
        assertEq(core.REWARDS().claimable(id, address(buyer)), 0);
        vm.warp(_maturity(id));
        buyer.settle(_ids(id));
        buyer.harvestRewards(_ids(id));
        assertApproxEqAbs(a.rewardClaimable(alice) + buyer.rewardClaimable(alice), loan.lenderReward, 10_000);
    }

    /// @dev Vault `a`'s curator lists its whole holding at `price` until the loan's maturity.
    function _listHolding(uint256 id, uint128 price) internal {
        IntentLenderMarket market = a.LENDER_MARKET();
        uint40 deadline = uint40(_maturity(id));
        vm.prank(manager);
        market.list(id, price, deadline, 100);
    }

    /// @dev The lowest price for a vault's whole holding that `executeLenderSale` books at or above its floor now: the
    /// position's book value, its principal plus the interest its schedule has earned (D48), plus half of the interest
    /// still to come (Pashov L-01), against the proceeds after the core's trade fee less the performance fee
    /// `_bookPayout` charges on the profit above the execution fee. What is booked never falls as the price rises, so
    /// one unit less is below the floor.
    function _floorPrice(IntentVault v, uint256 id) internal view returns (uint128) {
        (
            ,,
            uint16 feeBps,
            uint40 maturity,,,,,,
            uint128 principal,,
            uint128 interest,
            uint128 rate,
            uint64 clockStart,
            uint128 execution,
        ) = v.loans(id);
        uint256 end = block.timestamp < maturity ? block.timestamp : maturity;
        // The vault's rate precision: interest per second scaled by 1e18.
        uint256 earned = uint256(rate) * (end - clockStart) / 1e18;
        uint256 floor = principal + earned + (interest > earned ? interest - earned : 0) / 2;
        uint256 tradeFeeBps = core.REGISTRY().tradeFeeBps();
        uint256 below;
        uint256 at = 2 * floor;
        assertGe(_booked(at, tradeFeeBps, principal, execution, feeBps), floor);
        while (below + 1 < at) {
            uint256 mid = (below + at) / 2;
            if (_booked(mid, tradeFeeBps, principal, execution, feeBps) >= floor) at = mid;
            else below = mid;
        }
        return uint128(at);
    }

    /// @dev What a sale at `price` books: the market's proceeds less the performance fee on the realised profit.
    function _booked(uint256 price, uint256 tradeFeeBps, uint256 principal, uint256 execution, uint256 feeBps)
        internal
        pure
        returns (uint256 net)
    {
        net = price - price * tradeFeeBps / 10_000;
        if (net > principal && net - principal > execution) {
            net -= IntentFeeMath.performanceFee(net - principal, execution, feeBps);
        }
    }

    /// @dev A plan, signed by the local quote signer, for `buyer` to take vault `a`'s current ask whole.
    function _secondaryPlan(uint256 id, IntentVault buyer)
        internal
        view
        returns (IntentQuoteVerifier.SecondaryPlan memory p, bytes memory signature)
    {
        V2Loan memory loan = core.getLoan(id);
        (uint128 price,,, uint8 slots, uint64 nonce) = a.LENDER_MARKET().asks(id);
        p.engine = address(core);
        p.loanId = id;
        p.seller = address(a);
        p.market = address(a.LENDER_MARKET());
        p.slots = slots;
        p.price = price;
        p.nonce = nonce;
        p.maxFeeBps = 100;
        p.filler = filler;
        p.token = loan.token;
        p.collateral = loan.collateral;
        p.principal = loan.principal;
        p.cap = loan.cap;
        p.maturity = uint40(_maturity(id));
        p.modelAnnualBps = 1000;
        p.policyVersion = verifier.SECONDARY_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.valuedAt = uint40(block.timestamp);
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("bridged ordinary secondary sale");
        for (uint8 q; q < 4; q++) {
            p.minRewards[q] = uint128(core.REWARDS().remainingLenderReward(id, uint8(1 << q)));
        }
        p.allocations = new IntentQuoteVerifier.SecondaryAllocation[](1);
        uint128 minimum = uint128(IntentFeeMath.secondaryMinimum(price, 1300, p.maturity - p.issuedAt));
        (, uint256 fee) = IntentFeeMath.executionFee(loan.cap - price, minimum, buyer.executionCapBps());
        p.allocations[0] = IntentQuoteVerifier.SecondaryAllocation({
            vault: address(buyer),
            slots: 15,
            price: price,
            repayment: loan.cap,
            minimum: minimum,
            executionFee: uint128(fee),
            maxReserveShares: uint128(IERC4626(factory.RESERVE()).previewWithdraw(price + fee)),
            policyRevision: buyer.ASSET_POLICY().secondaryRevision(),
            extraBps: 300,
            capBps: buyer.executionCapBps(),
            managerBps: buyer.feeBps()
        });
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(KEY, verifier.secondaryPlanHash(p));
        signature = abi.encodePacked(r, sig, v);
    }
}
