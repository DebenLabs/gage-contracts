// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HybridVault, EarnLane} from "../../src/HybridVault.sol";
import {HybridFees} from "../../src/HybridFees.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {ICollateralRegistry, Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

interface IMorphoV2Probe is IERC4626 {
    function receiveSharesGate() external view returns (address);
    function sendSharesGate() external view returns (address);
    function receiveAssetsGate() external view returns (address);
    function sendAssetsGate() external view returns (address);
    function performanceFee() external view returns (uint96);
    function managementFee() external view returns (uint96);
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
    function curator() external view returns (address);
    function timelock(bytes4 selector) external view returns (uint256);
    function abdicated(bytes4 selector) external view returns (bool);
    function submit(bytes calldata data) external;
    function setSendAssetsGate(address gate) external;
}

contract RejectSendingAssetsGate {
    function canSendAssets(address) external pure returns (bool) {
        return false;
    }
}

/// @dev A pinned real-contract fork proof, not a production configuration approval.
///      Uses only Foundry's isolated state. Funding test actors via deal() is a local storage edit.
abstract contract MorphoForkBase is Test {
    // The first round block after the lender-sale release activated (readyBlock 60,452,747 in
    // docs/launch-evidence/lender-sales-2026-09-11/deployment.json). Earlier pins sit inside that sequence, where the
    // new registry still paused new deals and the live-core suites skipped. Fill the header hash on an RPC run.
    uint256 internal constant PINNED_BLOCK = 60_453_000;
    bytes32 internal constant PINNED_BLOCK_HASH = bytes32(0);
    address internal constant LIVE_STOCK = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    // Observed against the pinned Morpho bytecode when its send-assets gate rejects an account.
    bytes4 internal constant MORPHO_SEND_ASSETS_GATE_REJECTION = 0x515b7cd9;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant MORPHO_VAULT = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address internal constant LIQUIDITY_ADAPTER = 0x44ABc1d6cCFF2696d98890B92E2157AF242179c2;
    address internal constant MORPHO_CORE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    bytes32 internal constant VAULT_CODE_HASH = 0x3492098028b641c5949beebf8c56898f1ed846f42b59978ed7c75249603c1f6e;
    bytes32 internal constant USDG_CODE_HASH = 0x864cc9ad53b338b82da1f7cab85ab0b3d5c8861acb422b6fec63cf36234f36a6;

    IMorphoV2Probe internal reserve = IMorphoV2Probe(MORPHO_VAULT);
    address internal alice = makeAddr("hybrid-fork-alice");
    address internal bob = makeAddr("hybrid-fork-bob");
    /// @dev False when no RPC is configured: derived fixtures stop after the base skip.
    bool internal forked;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PINNED_BLOCK);
        forked = true;
        assertEq(block.chainid, 4663);
        if (PINNED_BLOCK_HASH != bytes32(0)) {
            // BLOCKHASH exposes the pinned header when the local block number advances by one.
            vm.roll(PINNED_BLOCK + 1);
            assertEq(blockhash(PINNED_BLOCK), PINNED_BLOCK_HASH);
            vm.roll(PINNED_BLOCK);
        }
        assertEq(MORPHO_VAULT.codehash, VAULT_CODE_HASH);
        assertEq(USDG.codehash, USDG_CODE_HASH);
        deal(USDG, alice, 10_000e6);
        vm.prank(alice);
        IERC20(USDG).approve(MORPHO_VAULT, type(uint256).max);
    }

    /// @dev The live lender-sale V2 engine recorded in the published deployment.
    function _liveCore() internal view returns (GageV2Vault core) {
        string memory deployment = vm.readFile("../launch/live/4663.json");
        core = GageV2Vault(vm.parseJsonAddress(deployment, ".nativeV2.engines[1].engine"));
        assertEq(address(core.REGISTRY()), vm.parseJsonAddress(deployment, ".nativeV2.engines[1].registry"));
        assertEq(address(core.REWARDS()), vm.parseJsonAddress(deployment, ".nativeV2.engines[1].rewards"));
        assertEq(core.GRACE(), uint32(vm.parseJsonUint(deployment, ".nativeV2.engines[1].grace")));
        assertEq(address(core.USDG()), USDG);
    }
}

contract DirectMorphoForkTest is MorphoForkBase {
    function testPinnedIdentityGatesAndFees() public view {
        assertEq(reserve.asset(), USDG);
        assertEq(reserve.decimals(), 18);
        assertEq(reserve.receiveSharesGate(), address(0));
        assertEq(reserve.sendSharesGate(), address(0));
        assertEq(reserve.receiveAssetsGate(), address(0));
        assertEq(reserve.sendAssetsGate(), address(0));
        assertEq(reserve.performanceFee(), 0);
        assertEq(reserve.managementFee(), 0);
        assertEq(reserve.liquidityAdapter(), LIQUIDITY_ADAPTER);
        assertEq(keccak256(reserve.liquidityData()), 0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6);
    }

    function testZeroMaxFunctionsDoNotPreventRealDepositAndExactWithdrawal() public {
        assertEq(reserve.maxDeposit(alice), 0);
        assertEq(reserve.maxMint(alice), 0);
        assertEq(reserve.maxWithdraw(alice), 0);
        assertEq(reserve.maxRedeem(alice), 0);
        vm.prank(alice);
        uint256 minted = reserve.deposit(1000e6, alice);
        assertGt(minted, 0);
        assertEq(reserve.balanceOf(alice), minted);
        assertEq(IERC20(USDG).balanceOf(alice), 9000e6);
        // Deposits actually enter the configured liquidity adapter; they do not remain idle cash.
        assertEq(IERC20(USDG).balanceOf(MORPHO_VAULT), 0);
        vm.prank(alice);
        uint256 burned = reserve.withdraw(300e6, alice, alice);
        assertGt(burned, 0);
        assertEq(reserve.balanceOf(alice), minted - burned);
        assertEq(IERC20(USDG).balanceOf(alice), 9300e6);
    }

    function testFullReceiptExitCanTransferThenRedeemAtPinnedGates() public {
        vm.startPrank(alice);
        uint256 minted = reserve.deposit(1000e6, alice);
        reserve.transfer(bob, minted);
        vm.stopPrank();
        assertEq(reserve.balanceOf(alice), 0);
        assertEq(reserve.balanceOf(bob), minted);
        vm.prank(bob);
        uint256 received = reserve.redeem(minted, bob, bob);
        assertEq(reserve.balanceOf(bob), 0);
        assertEq(IERC20(USDG).balanceOf(bob), received);
        assertApproxEqAbs(received, 1000e6, 1);
    }

    function testLostUnderlyingLiquidityRevertsWithoutBurningOwnersShares() public {
        vm.prank(alice);
        uint256 minted = reserve.deposit(1000e6, alice);
        // Deliberate local stress, not an observed mainnet condition: remove the underlying
        // lending contract's token liquidity without altering the investor's receipt balance.
        deal(USDG, MORPHO_CORE, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "transfer reverted"));
        reserve.withdraw(300e6, alice, alice);
        assertEq(reserve.balanceOf(alice), minted);
        assertEq(IERC20(USDG).balanceOf(alice), 9000e6);
    }

    function testSupportedFutureDepositGateBlocksEntryButPreservesExit() public {
        vm.prank(alice);
        uint256 minted = reserve.deposit(1000e6, alice);
        RejectSendingAssetsGate gate = new RejectSendingAssetsGate();
        bytes memory change = abi.encodeCall(IMorphoV2Probe.setSendAssetsGate, (address(gate)));
        assertFalse(reserve.abdicated(IMorphoV2Probe.setSendAssetsGate.selector));
        uint256 delay = reserve.timelock(IMorphoV2Probe.setSendAssetsGate.selector);
        // Impersonation and time travel occur only inside the local fork.
        address curator = reserve.curator();
        vm.prank(curator);
        reserve.submit(change);
        vm.warp(block.timestamp + delay);
        reserve.setSendAssetsGate(address(gate));
        vm.prank(alice);
        vm.expectRevert(MORPHO_SEND_ASSETS_GATE_REJECTION);
        reserve.deposit(100e6, alice);
        assertEq(reserve.balanceOf(alice), minted);
        vm.prank(alice);
        reserve.withdraw(300e6, alice, alice);
        assertEq(IERC20(USDG).balanceOf(alice), 9300e6);
    }
}

/// @dev Lifecycle coverage of the pooled share vault on the live V2 engine, the real Morpho reserve and a live
///      stock token, inside this isolated fork.
contract HybridMorphoLiveCoreForkTest is MorphoForkBase {
    error InjectedCoreFailure();

    HybridVault internal hybrid;
    HybridFees internal hybridFees;
    GageV2Vault internal core;
    IERC20 internal collateral;
    uint256 internal collateralAmount;
    address internal borrower = makeAddr("hybrid-fork-borrower");
    address internal filler = makeAddr("hybrid-fork-filler");

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        core = _liveCore();
        collateral = IERC20(LIVE_STOCK);
        ICollateralRegistry registry = ICollateralRegistry(address(core.REGISTRY()));
        ICollateralRegistry.ERC20Config memory cfg = registry.getERC20Config(LIVE_STOCK);
        if (!cfg.allowed || registry.newDealsPaused()) {
            emit log("Live V2 registry does not currently admit this stock token; lifecycle skipped.");
            vm.skip(true);
            return;
        }
        assertEq(uint256(cfg.lane), uint256(Lane.STOCK));
        collateralAmount = Math.min(Math.max(cfg.minAmount, 10e18), cfg.maxDealRaw);
        HybridVault.Params memory p = HybridVault.Params({
            core: address(core),
            reserve: MORPHO_VAULT,
            laneWeights: [uint16(10_000), 0, 0],
            curator: address(this),
            maxLoanTerm: 7 days,
            minReturnBps: 300,
            maxGageExposureBps: 4000,
            minDeposit: 1e6,
            maxTotalDeposits: 100_000e6
        });
        hybrid = new HybridVault(p);
        hybrid.setTokenCeiling(address(collateral), 70e6);
        hybridFees = new HybridFees(address(hybrid), 0, address(0), address(this));
        hybrid.setFees(address(hybridFees));
        assertLe(address(hybrid).code.length, 24_576);
        deal(USDG, bob, 10_000e6);
        deal(USDG, borrower, 10_000e6);
        deal(USDG, filler, 10_000e6);
        deal(address(collateral), borrower, 10 * collateralAmount);
        vm.startPrank(borrower);
        collateral.approve(address(core), type(uint256).max);
        IERC20(USDG).approve(address(core), type(uint256).max);
        vm.stopPrank();
        vm.prank(filler);
        IERC20(USDG).approve(address(core), type(uint256).max);
        vm.prank(alice);
        IERC20(USDG).approve(address(hybrid), type(uint256).max);
        vm.prank(bob);
        IERC20(USDG).approve(address(hybrid), type(uint256).max);
    }

    /// @dev Deposit 1000 USDG for shares and move every idle unit into the real reserve.
    function _deposit(address who) internal returns (uint256 shares) {
        vm.prank(who);
        shares = hybrid.deposit(1000e6, 1);
        hybrid.investReserve(hybrid.cash(), 1);
    }

    function _loan(uint8 units) internal returns (uint256 id) {
        vm.prank(borrower);
        id = core.list(
            Collateral(Kind.ERC20, address(collateral), collateralAmount),
            300e6,
            315e6,
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        hybrid.approveLoan(id, uint40(block.timestamp + 1 hours), units);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _defaultAt(uint256 id) internal view returns (uint256) {
        V2Loan memory l = core.getLoan(id);
        return uint256(l.fundedAt) + l.term + core.GRACE();
    }

    function testRealMorphoToGageRepaymentServedRequestAndCompleteExit() public {
        uint256 aliceShares = _deposit(alice);
        uint256 originalReserve = hybrid.reserveShares();
        assertEq(reserve.balanceOf(address(hybrid)), originalReserve);
        assertEq(hybrid.cash(), 0);
        uint256 id = _loan(4);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.cash(), 0);
        assertEq(hybrid.performingPrincipal(), 300e6);
        assertLt(hybrid.reserveShares(), originalReserve);
        assertEq(reserve.balanceOf(address(hybrid)), hybrid.reserveShares());
        assertEq(core.unitsOf(id, address(hybrid)), 4);
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(IERC20(USDG).balanceOf(address(hybrid)), 0);
        assertApproxEqAbs(hybrid.totalAssets(), 1000e6, 2, "a loan at principal does not move the price");

        // A newcomer buys at the current price; the repayment premium unlocks over the window for whoever holds.
        uint256 bobShares = _deposit(bob);
        assertApproxEqRel(bobShares, aliceShares, 1e14);
        vm.prank(borrower);
        core.reclaim(id, borrower);
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.cash(), 315e6);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.lockedProfit(), 15e6, "no fee is configured: the whole premium is locked");
        assertApproxEqAbs(hybrid.totalAssets(), 2000e6, 4, "locked profit is not priced yet");

        // Alice queues everything and is served at once from cash and the real reserve.
        vm.prank(alice);
        uint256 requestId = hybrid.requestRedeem(aliceShares);
        assertEq(hybrid.pendingShares(), aliceShares);
        hybrid.serveRequests(10, type(uint256).max);
        (, uint256 remaining) = hybrid.requests(requestId);
        assertEq(remaining, 0);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.balanceOf(alice), 0);
        assertApproxEqAbs(hybrid.claimable(alice), 1000e6, 4, "served before the premium unlocks");
        vm.prank(alice);
        uint256 claimed = hybrid.claim();
        assertApproxEqAbs(IERC20(USDG).balanceOf(alice), 10_000e6, 4);
        assertEq(hybrid.claimableTotal(), 0);
        assertEq(claimed, IERC20(USDG).balanceOf(alice) - 9000e6);

        // Bob holds through the window and leaves with the premium, synchronously through the reserve.
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK());
        assertEq(hybrid.lockedProfitNow(), 0);
        assertApproxEqAbs(hybrid.convertToAssets(bobShares), 1015e6, 4);
        vm.prank(bob);
        uint256 paid = hybrid.redeem(bobShares, 1015e6 - 10);
        assertApproxEqAbs(paid, 1015e6, 10);
        assertEq(hybrid.totalSupply(), 0);
        assertEq(hybrid.cash(), 0);
        assertLe(hybrid.reserveShares(), 4e12, "only conversion dust can remain in the reserve");
        assertEq(reserve.balanceOf(address(hybrid)), hybrid.reserveShares());
        assertEq(IERC20(USDG).allowance(address(hybrid), MORPHO_VAULT), 0);
        assertEq(IERC20(USDG).allowance(address(hybrid), address(core)), 0);
    }

    function testPartialUnitsWithLiveFillerAndCancellationRefund() public {
        _deposit(alice);
        uint256 id = _loan(2);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.positionPrincipal(id), 150e6);
        assertEq(hybrid.performingPrincipal(), 150e6);
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.FUNDING));
        vm.prank(borrower);
        core.cancelFunding(id);
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.cash(), 150e6, "a refund settles as cash at principal");
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.lockedProfit(), 0);

        uint256 next = _loan(2);
        hybrid.fund(next, type(uint256).max);
        assertEq(hybrid.cash(), 0, "cash funds before the reserve");
        vm.prank(filler);
        core.fund(next, 2);
        assertEq(uint256(core.getLoan(next).state), uint256(V2State.ACTIVE));
        vm.prank(borrower);
        core.reclaim(next, borrower);
        hybrid.settle(_ids(next));
        assertEq(hybrid.cash(), 157_500_000);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.lockedProfit(), 7_500_000);
    }

    function testRealReserveLiquidityFailureCannotPartiallyFundGage() public {
        _deposit(alice);
        uint256 shares = hybrid.reserveShares();
        uint256 id = _loan(4);
        deal(USDG, MORPHO_CORE, 0);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "transfer reverted"));
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.reserveShares(), shares);
        assertEq(reserve.balanceOf(address(hybrid)), shares);
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.positionPrincipal(id), 0);
        assertFalse(hybrid.funded(id));
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.FUNDING));
    }

    function testReserveExitFailureLeavesTheRequestPendingAndCancellable() public {
        uint256 shares = _deposit(alice);
        // Half is queued; the other half stays free, so a direct redeem reaches the reserve instead of the
        // locked-share check (a fully queued holder gets InvalidAmount before any reserve call).
        uint256 queued = shares / 2;
        vm.prank(alice);
        uint256 requestId = hybrid.requestRedeem(queued);
        deal(USDG, MORPHO_CORE, 0);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "transfer reverted"));
        hybrid.serveRequests(10, type(uint256).max);
        // A single 18-decimal share is worth less than one USDG unit and never reaches the reserve; redeem a real
        // slice of the free half so the payout has to come out of the drained reserve.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "transfer reverted"));
        hybrid.redeem(queued / 2, 0);
        assertEq(hybrid.pendingShares(), queued, "the request survives a reserve failure");
        assertEq(hybrid.lockedShares(alice), queued);
        assertEq(hybrid.balanceOf(alice), shares);
        assertEq(hybrid.claimable(alice), 0);
        vm.prank(alice);
        hybrid.cancelRequest(requestId);
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.lockedShares(alice), 0);
        assertEq(hybrid.balanceOf(alice), shares, "shares stay owned until the reserve pays again");
    }

    function testCoreFundingFailureRollsBackCompletedReserveRedemption() public {
        _deposit(alice);
        uint256 shares = hybrid.reserveShares();
        uint256 id = _loan(4);
        // The failure is injected at the later core call, after the real reserve withdrawal.
        vm.mockCallRevert(
            address(core),
            abi.encodeCall(GageV2Vault.fund, (id, 4)),
            abi.encodeWithSelector(InjectedCoreFailure.selector)
        );
        vm.expectRevert(InjectedCoreFailure.selector);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.reserveShares(), shares);
        assertEq(reserve.balanceOf(address(hybrid)), shares);
        assertEq(IERC20(USDG).balanceOf(address(hybrid)), 0);
        assertEq(hybrid.cash(), 0);
        assertEq(hybrid.performingPrincipal(), 0);
        assertFalse(hybrid.funded(id));
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.FUNDING));
    }

    function testPendingRequestsHavePriorityOverNewGageFunding() public {
        uint256 aliceShares = _deposit(alice);
        uint256 bobShares = _deposit(bob);
        vm.prank(alice);
        hybrid.requestRedeem(aliceShares);
        vm.prank(bob);
        hybrid.requestRedeem(bobShares * 3 / 4);
        uint256 id = _loan(4);
        // Funding refuses only when what remains would not cover the queue: 2000 less 300 is short of the 1750 owed.
        vm.expectRevert(HybridVault.RequestsPending.selector);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.performingPrincipal(), 0);
        hybrid.serveRequests(10, type(uint256).max);
        assertEq(hybrid.pendingShares(), 0);
        assertApproxEqAbs(hybrid.claimable(alice), 1000e6, 4);
        assertApproxEqAbs(hybrid.claimable(bob), 750e6, 4);
        // Fresh money after the queue is served funds the same approval.
        _deposit(bob);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.performingPrincipal(), 300e6);
        assertEq(hybrid.balanceOf(alice), 0);
        assertApproxEqAbs(hybrid.convertToAssets(hybrid.balanceOf(bob)), 1250e6, 4);
    }

    function testCollateralOutcomeOpensASidePocketForTheHoldersOfRecord() public {
        uint256 aliceShares = _deposit(alice);
        uint256 id = _loan(4);
        hybrid.fund(id, type(uint256).max);
        uint256 reserveAfterFunding = hybrid.reserveShares();
        uint256 bobShares = _deposit(bob);
        vm.warp(_defaultAt(id));
        hybrid.settle(_ids(id));
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.DEFAULTED));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.performingPrincipal(), 0);
        assertEq(hybrid.cash(), 0);
        assertEq(hybrid.pocketCount(), 1);
        (uint256 dealId, address token, uint256 amount, uint256 supply, uint256 claimed) = hybrid.pockets(1);
        assertEq(dealId, id);
        assertEq(token, address(collateral));
        assertEq(amount, collateralAmount);
        assertEq(supply, aliceShares + bobShares);
        assertEq(claimed, 0);
        assertEq(collateral.balanceOf(address(hybrid)), collateralAmount);
        assertGe(hybrid.reserveShares(), reserveAfterFunding, "the reserve is untouched by a default");
        assertApproxEqAbs(hybrid.totalAssets(), 1700e6, 4, "collateral is never priced; the principal is gone");
        // Both holders of record share the pocket; a later entrant gets nothing.
        uint256 aliceCut = Math.mulDiv(collateralAmount, aliceShares, supply);
        assertEq(hybrid.pocketClaimable(1, alice), aliceCut);
        vm.prank(alice);
        assertEq(hybrid.claimPocket(1), aliceCut);
        assertEq(collateral.balanceOf(alice), aliceCut);
        vm.prank(bob);
        uint256 bobCut = hybrid.claimPocket(1);
        assertEq(collateral.balanceOf(bob), bobCut);
        assertLe(collateralAmount - aliceCut - bobCut, 1);
        assertEq(hybrid.balanceOfAt(alice, 1), aliceShares);
        vm.prank(alice);
        vm.expectRevert(HybridVault.AlreadyClaimed.selector);
        hybrid.claimPocket(1);
    }

    function testLiveCoreLaneLimitAndFeeSnapshot() public {
        _deposit(alice);
        hybrid.setLaneWeight(EarnLane.STOCK, 4000);
        hybridFees.setCuratorRecipient(bob);
        hybrid.setFee(1000);
        uint256 id = _loan(4);
        hybrid.fund(id, type(uint256).max);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 300e6);
        hybrid.setFee(5000);
        hybrid.setLaneWeight(EarnLane.STOCK, 1000);
        vm.prank(borrower);
        uint256 next = core.list(
            Collateral(Kind.ERC20, LIVE_STOCK, collateralAmount),
            300e6,
            315e6,
            7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.expectRevert(abi.encodeWithSelector(HybridVault.IneligibleDeal.selector, next));
        hybrid.approveLoan(next, uint40(block.timestamp + 1 hours), 4);
        vm.prank(borrower);
        core.reclaim(id, borrower);
        hybrid.settle(_ids(id));
        // The first profit above a zero mark pays the funding-time rate on the whole premium. The live reserve
        // values the idle allocation with its own share rounding, so the lift above the mark, and the fee on it,
        // may sit one raw USDG unit under the exact premium at a given pinned block.
        assertEq(hybrid.loanFeeBps(id), 1000);
        uint256 fee = hybrid.feeAccrued();
        assertApproxEqAbs(fee, 1_500_000, 1);
        assertEq(hybrid.cash(), 315_000_000 - fee);
        assertEq(hybrid.lockedProfit(), 15_000_000 - fee);
        assertGt(hybrid.highWaterPrice(), 0);
        assertEq(hybrid.lanePrincipal(EarnLane.STOCK), 0);
        uint256 before_ = IERC20(USDG).balanceOf(bob);
        hybrid.claimFees();
        hybridFees.claimCurator();
        assertEq(IERC20(USDG).balanceOf(bob) - before_, fee, "no protocol share is configured on the fork");
        assertEq(hybrid.feeAccrued(), 0);
    }

    function testReserveEntryGateCannotUndoSettledRepaymentCash() public {
        uint256 shares = _deposit(alice);
        uint256 id = _loan(4);
        hybrid.fund(id, type(uint256).max);
        vm.prank(borrower);
        core.reclaim(id, borrower);
        RejectSendingAssetsGate gate = new RejectSendingAssetsGate();
        bytes memory change = abi.encodeCall(IMorphoV2Probe.setSendAssetsGate, (address(gate)));
        address curator = reserve.curator();
        vm.prank(curator);
        reserve.submit(change);
        vm.warp(block.timestamp + reserve.timelock(IMorphoV2Probe.setSendAssetsGate.selector));
        reserve.setSendAssetsGate(address(gate));
        hybrid.settle(_ids(id));
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.cash(), 315e6);
        assertEq(IERC20(USDG).balanceOf(address(hybrid)), 315e6);
        vm.expectRevert(MORPHO_SEND_ASSETS_GATE_REJECTION);
        hybrid.investReserve(315e6, 1);
        assertEq(hybrid.cash(), 315e6, "the gate blocks reinvestment, never the settled cash");
        // Leaving still works: cash first, then the reserve, whose exit gate is untouched.
        vm.warp(block.timestamp + hybrid.PROFIT_UNLOCK());
        vm.prank(alice);
        uint256 paid = hybrid.redeem(shares, 1015e6 - 10);
        assertApproxEqAbs(paid, 1015e6, 10);
        assertEq(hybrid.cash(), 0);
        assertApproxEqAbs(IERC20(USDG).balanceOf(alice), 10_015e6, 10);
    }
}

/// @notice The live-admission gate: the V2 engine's registry must admit a stock token for Earn to lend on mainnet.
contract HybridLiveCoreAdmissionForkTest is MorphoForkBase {
    function testLiveCoreStockAdmissionGate() public {
        GageV2Vault liveCore = _liveCore();
        ICollateralRegistry.ERC20Config memory cfg =
            ICollateralRegistry(address(liveCore.REGISTRY())).getERC20Config(LIVE_STOCK);
        if (!cfg.allowed) {
            emit log("BLOCKED: the live V2 registry does not admit this stock token.");
            vm.skip(true);
        }
        assertEq(uint256(cfg.lane), uint256(Lane.STOCK));
        assertGt(cfg.minAmount, 0);
    }
}
