// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {MockFeeProcessor} from "../mocks/MockFeeProcessor.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealVault} from "../../src/DealVault.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";
import {Drip} from "../../src/token/Drip.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {LPHook} from "../../src/token/LPHook.sol";
import {LPRewards} from "../../src/token/LPRewards.sol";
import {FeeFloor} from "../../src/token/FeeFloor.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {ICreatorFeeSplitter} from "../../src/interfaces/token/ICreatorFeeSplitter.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";

/// @notice S7 / R5: execution fees earned by the Intent fill router reach the existing fee processor, buy GAGE and
/// become a band of the GAGE/sGAGE floor. One fixture holds both halves: the Intent stack of `IntentPlanBaseTest`
/// (factory, verifier, signer, two vaults, the real `IntentFillRouter`) and the token layer of `FeeFloor.t.sol`
/// (a real Uniswap v4 deployment, USDG/ETH and GAGE/ETH pools, the hooked GAGE/sGAGE pool, the real `FeeSink`,
/// `DealFeeRouter` and `FeeFloor`). Both halves use the same USDG token.
/// @dev Pool depths, the threshold and the split are fixture values, not launch values. The GAGE/ETH pool holds about
/// 100 ETH, so a clip worth more than about 1 ETH (2,500 USDG) breaks the processor's 1% impact bound.
contract IntentRevenueTest is IntentPlanBaseTest, V4Fixture {
    uint160 internal constant HOOK_FLAGS = Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
    uint256 internal constant THRESHOLD = 100e6;

    IntentFillRouter internal fills;

    MockERC20 internal gage;
    SGAGE internal poolSgage;
    LPRewards internal lpRewards;
    PoolKey internal usdgEth;
    PoolKey internal gageEth;
    PoolKey internal gageSgage;
    CollateralRegistry internal dealRegistry;
    DealVault internal dealVault;
    FeeSink internal feeSink;
    FeeFloor internal feeFloor;
    DealFeeRouter internal processor;

    address internal ops = makeAddr("ops-wallet");
    address internal dealLender = makeAddr("deal-lender");
    address internal stranger = makeAddr("stranger");
    /// @dev The Gage keeper-filler is `fillers[0]`; the external participant is `fillers[1]`. `externalPayout` is an
    /// address such a participant might name: nothing is ever owed to it (D49).
    address internal externalPayout = makeAddr("external-payout");

    function _deployRouter() internal virtual override returns (address) {
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(usdg)));
        return address(fills);
    }

    function setUp() public virtual override {
        super.setUp();
        // The token layer's swap base accepts a market with no Pons curve only on the testnet's chain id.
        vm.chainId(46_630);
        _deployV4();
        _standTokenLayer();
        _standFeeRoute();
        // S7's configuration: every execution fee is owed to the fee processor, the protocol recipient (D49).
        partnerFactory.setProtocolRecipient(address(processor));
        partnerFactory.setFiller(fillers[0], true);
        partnerFactory.setFiller(fillers[1], true);
    }

    // ---------------------------------------------------------------- fixture

    /// @dev GAGE, the real sGAGE with its emissions, the mined LP hook and the seeded GAGE/sGAGE pool, as
    /// `TokenLayerFixture` builds them.
    function _standTokenLayer() internal {
        Emissions emissions = new Emissions(safe, address(this));
        poolSgage = new SGAGE(address(emissions), treasury);
        Drip drip = new Drip(poolSgage, address(this));
        gage = new MockERC20("GAGE", "GAGE", 18);
        (address mined, bytes32 salt) = HookMiner.find(
            address(this), HOOK_FLAGS, type(LPHook).creationCode, abi.encode(poolManager, address(posm), address(this))
        );
        LPHook hook = new LPHook{salt: salt}(poolManager, address(posm), address(this));
        assertEq(address(hook), mined, "mined address");
        // 1 GAGE = 1,000 sGAGE.
        gageSgage = _initPoolAtPriceWithFee(address(gage), 1e18, address(poolSgage), 1000e18, address(hook), 30_000);
        lpRewards = new LPRewards(poolSgage, drip, emissions, posm, address(hook), gageSgage, address(this));
        hook.setLPRewards(lpRewards);
        emissions.wire(poolSgage, lpRewards, makeAddr("deal-rewards"));
        drip.setGrantors(makeAddr("deal-rewards"), address(lpRewards));
        gage.mint(treasury, 1_000_000_000e18);
        _approvePosm(treasury, address(gage));
        _approvePosm(treasury, address(poolSgage));
        lpRewards.setSeed(_mintFullRange(gageSgage, 2e24, treasury, treasury));
        vm.prank(safe);
        emissions.launch(uint40(block.timestamp));
    }

    /// @dev The first-generation deal vault and its fee sink (the other sources the processor commingles), the two
    /// swap pools, the floor and the processor, routed the way the live deployment is: FeeSink -> BUYBACK -> processor.
    function _standFeeRoute() internal {
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        dealRegistry = new CollateralRegistry(safe, terms, 100);
        feeSink = new FeeSink(IERC20(address(usdg)), safe, treasury);
        dealVault = new DealVault(IERC20(address(usdg)), dealRegistry, address(feeSink), address(0), 48 hours);

        vm.deal(treasury, 10_000 ether);
        usdg.mint(treasury, 10_000_000e6);
        usdgEth = _initPoolAtPrice(address(0), 1 ether, address(usdg), 2500e6, address(0));
        gageEth = _initPoolAtPrice(address(0), 1 ether, address(gage), 1_000_000e18, address(0));
        // About 2,000 ETH against 5M USDG, and about 100 ETH against 100M GAGE.
        _addRawLiquidityNative(usdgEth, FULL_LOWER, FULL_UPPER, 1e17, treasury, 3000 ether);
        _addRawLiquidityNative(gageEth, FULL_LOWER, FULL_UPPER, 1e23, treasury, 101 ether);

        feeFloor = new FeeFloor(
            FeeFloor.Params({
                poolManager: poolManager,
                positionManager: posm,
                permit2: permit2,
                opsWallet: ops,
                sgage: poolSgage,
                gage: address(gage),
                usdgEth: usdgEth,
                gageEth: gageEth,
                gageSgage: gageSgage,
                launchPoolFeePips: 0,
                ponsClaimTarget: address(this),
                ponsClaimCalldata: "",
                threshold: THRESHOLD,
                initialOwner: address(this)
            }),
            address(0)
        );
        processor = new DealFeeRouter(
            DealFeeRouter.Params({
                poolManager: poolManager,
                usdg: IERC20(address(usdg)),
                gage: IERC20(address(gage)),
                feeSink: feeSink,
                floor: feeFloor,
                usdgEth: usdgEth,
                gageEth: gageEth,
                launchPoolFeePips: 0,
                threshold: THRESHOLD,
                initialOwner: address(this)
            }),
            address(0)
        );
        lpRewards.setFloor(address(feeFloor));
        vm.startPrank(safe);
        feeSink.setVault(dealVault);
        feeSink.setBuyback(address(processor));
        feeSink.setRoute(FeeSink.Route.BUYBACK);
        dealRegistry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 1000e18, 5000e18);
        vm.stopPrank();
        usdg.mint(dealLender, 1_000_000e6);
        vm.prank(dealLender);
        usdg.approve(address(dealVault), MAX);
        vm.prank(borrower);
        nvda.approve(address(dealVault), MAX);
        vm.label(address(fills), "IntentFillRouter");
        vm.label(address(processor), "DealFeeRouter");
        vm.label(address(feeFloor), "FeeFloor");
        vm.label(address(feeSink), "FeeSink");
    }

    function _shares(uint256 count) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            limits[i] = type(uint256).max;
        }
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal virtual override {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(p.allocations.length));
    }

    function _assertRefused(IntentQuoteVerifier.Plan memory p, IntentQuoteVerifier.Refusal expected)
        internal
        virtual
        override
    {
        bytes memory signature = _sign(p);
        vm.prank(p.filler);
        vm.expectRevert(abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, expected));
        fills.fill(p, signature, _shares(p.allocations.length));
    }

    /// @dev The plan for a fresh listing of `principal` at a 10% fixed cost, split one unit to three across the two
    /// vaults, filled by `filler`.
    function _planFor(address filler, uint128 principal)
        internal
        returns (IntentQuoteVerifier.Plan memory p, uint256 id, uint256 fee)
    {
        id = _list(borrower, address(nvda), 100e18, principal, principal + principal / 10, T21);
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(1, 3);
        p = _plan(id, vaults, counts);
        p.filler = filler;
        fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
    }

    /// @dev One activated fill; returns the execution fee it earned.
    function _earn(address filler, uint128 principal) internal returns (uint256 fee) {
        IntentQuoteVerifier.Plan memory p;
        uint256 id;
        (p, id, fee) = _planFor(filler, principal);
        _fill(p);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE), "activated");
        assertGt(fee, 0, "the fixture loan earns an execution fee");
    }

    /// @dev A first-generation deal at 7,960 USDG: its 1% fee (79.60 USDG) becomes the fee sink's credit in the deal
    /// vault, the processor's oldest source.
    function _dealFee() internal returns (uint256 credited) {
        uint256 before_ = dealVault.balanceUSDG(address(feeSink));
        vm.prank(borrower);
        uint256 dealId = dealVault.list(
            Collateral(Kind.ERC20, address(nvda), 100e18), 8000e6, T7, uint40(block.timestamp + 3 days), 0
        );
        vm.prank(dealLender);
        uint256 bidId = dealVault.bid(dealId, 7960e6, uint40(block.timestamp + 1 days), dealLender);
        vm.prank(borrower);
        dealVault.accept(dealId, bidId);
        credited = dealVault.balanceUSDG(address(feeSink)) - before_;
        assertEq(credited, 79_600_000);
    }

    struct Route {
        uint256 processorUSDG;
        uint256 sinkUSDG;
        uint256 vaultCredit;
        uint256 available;
        uint256 batchRemaining;
        uint256 processed;
        uint256 gageAdded;
        uint256 poolUSDG;
        uint256 poolGAGE;
        uint256 poolETH;
        uint256 floorGAGE;
        uint256 floorUSDG;
        uint256 floorCount;
        uint256 processorGAGE;
        uint256 processorETH;
        uint256 opsETH;
        uint256 fillsUSDG;
        uint256 totalOwed;
    }

    /// @dev Every balance and counter a processing step may touch.
    function _route() internal view returns (Route memory r) {
        r.processorUSDG = usdg.balanceOf(address(processor));
        r.sinkUSDG = usdg.balanceOf(address(feeSink));
        r.vaultCredit = dealVault.balanceUSDG(address(feeSink));
        r.available = processor.availableUSDG();
        r.batchRemaining = processor.batchRemaining();
        r.processed = processor.totalUSDGProcessed();
        r.gageAdded = processor.totalGAGEAdded();
        r.poolUSDG = usdg.balanceOf(address(poolManager));
        r.poolGAGE = gage.balanceOf(address(poolManager));
        r.poolETH = address(poolManager).balance;
        r.floorGAGE = gage.balanceOf(address(feeFloor));
        r.floorUSDG = usdg.balanceOf(address(feeFloor));
        r.floorCount = feeFloor.floorCount();
        r.processorGAGE = gage.balanceOf(address(processor));
        r.processorETH = address(processor).balance;
        r.opsETH = ops.balance;
        r.fillsUSDG = usdg.balanceOf(address(fills));
        r.totalOwed = fills.totalOwed();
    }

    function _same(Route memory a, Route memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    struct ClipReceipt {
        address caller;
        uint256 usdgIn;
        uint256 ethOut;
        uint256 gageBought;
        uint256 gageAdded;
        uint256 received;
        uint256 tokenId;
        uint128 bandLiquidity;
    }

    /// @dev One clip by `caller`, read back from the three events it must emit.
    function _process(address caller, uint256 clip) internal returns (ClipReceipt memory r) {
        vm.recordLogs();
        vm.prank(caller);
        uint256 added = processor.process(clip);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(processor) && topic == DealFeeRouter.FloorFunded.selector) {
                r.caller = address(uint160(uint256(logs[i].topics[1])));
                (r.usdgIn, r.ethOut, r.gageBought, r.gageAdded) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                ++seen;
            } else if (logs[i].emitter == address(feeFloor) && topic == FeeFloor.GAGEDeposited.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(processor), "deposited by the processor");
                (r.received,) = abi.decode(logs[i].data, (uint256, uint256));
                ++seen;
            } else if (logs[i].emitter == address(feeFloor) && topic == ICreatorFeeSplitter.FloorAdded.selector) {
                r.tokenId = uint256(logs[i].topics[1]);
                (,,, r.bandLiquidity) = abi.decode(logs[i].data, (int24, int24, uint256, uint128));
                ++seen;
            }
        }
        assertEq(seen, 3, "FloorFunded, GAGEDeposited and FloorAdded");
        assertEq(r.gageAdded, added, "the event carries what process returned");
    }

    /// @dev A clip reconciled to the unit: USDG leaves the processor for the pool, the GAGE bought is the GAGE handed
    /// to the floor, and what the band did not take (liquidity rounding) waits in the floor for the next deposit.
    function _assertReconciled(Route memory a, Route memory b, ClipReceipt memory r, uint256 clip) internal view {
        assertEq(r.usdgIn, clip, "usdgIn");
        assertEq(a.available - b.available, clip, "USDG out of the processor's pot");
        assertEq(b.poolUSDG - a.poolUSDG, clip, "USDG into the pool, exactly");
        assertEq(b.sinkUSDG + b.vaultCredit, 0, "upstream sources were pulled in");
        assertEq(b.processorUSDG, b.available, "everything left is held by the processor");
        assertEq(b.processed - a.processed, clip, "totalUSDGProcessed");
        assertEq(b.gageAdded - a.gageAdded, r.gageAdded, "totalGAGEAdded");
        assertEq(r.received, r.gageBought, "every GAGE bought reached the floor");
        assertEq(b.floorGAGE + r.gageAdded, a.floorGAGE + r.gageBought, "bought = added + dust waiting in the floor");
        assertLe(r.gageBought - r.gageAdded, 1e6, "dust only");
        assertEq(a.poolGAGE - b.poolGAGE, r.gageBought - r.gageAdded, "GAGE left the swap pool and entered the band");
        assertEq(a.poolETH, b.poolETH, "the ETH leg nets to zero inside the pool manager");
        assertEq(b.processorGAGE, 0, "no GAGE left in the processor");
        assertEq(b.processorETH, 0, "no ETH left in the processor");
        assertEq(gage.allowance(address(processor), address(feeFloor)), 0, "allowance cleared");
        assertEq(b.opsETH, a.opsETH, "no operations deduction on this path");
        assertEq(b.floorUSDG, a.floorUSDG, "the floor never touches USDG");
        (,, uint128 liquidity,) = feeFloor.bands(r.tokenId);
        assertEq(liquidity, r.bandLiquidity, "the band's recorded liquidity");
        assertEq(posm.getPositionLiquidity(r.tokenId), liquidity, "is the position's real liquidity");
    }

    // ---------------------------------------------------------------- 1. claim -> processor receipt

    function testAClaimedExecutionFeeRaisesTheProcessorsAvailableUSDGByExactlyThatAmount() public {
        uint256 fee = _earn(fillers[0], 1000e6);
        assertEq(fills.owed(address(processor)), fee);
        Route memory a = _route();
        // Anyone may trigger the payment; it only ever goes to the recorded recipient.
        vm.expectEmit(address(fills));
        emit IntentFillRouter.Claimed(address(processor), fee);
        vm.prank(stranger);
        assertEq(fills.claim(address(processor)), fee);
        Route memory b = _route();
        assertEq(b.available - a.available, fee, "availableUSDG");
        assertEq(b.processorUSDG - a.processorUSDG, fee, "a plain transfer to the processor");
        assertEq(a.fillsUSDG - b.fillsUSDG, fee, "out of the fill router");
        assertEq(fills.owed(address(processor)), 0);
        assertEq(b.totalOwed, 0);
        assertEq(b.fillsUSDG, 0);
        assertEq(usdg.balanceOf(stranger), 0, "nothing for the caller");
    }

    // ---------------------------------------------------------------- 2. below the threshold the funds wait

    function testClaimedFundsBelowTheThresholdWaitAndAreProcessedOnceOtherFeesLiftThePot() public {
        uint256 fee = _earn(fillers[0], 1000e6);
        assertLt(fee, THRESHOLD, "the fixture fee is under the threshold");
        fills.claim(address(processor));
        vm.expectRevert(abi.encodeWithSelector(DealFeeRouter.BelowThreshold.selector, fee, THRESHOLD));
        processor.process(fee);
        assertEq(usdg.balanceOf(address(processor)), fee, "still held");
        assertEq(processor.batchRemaining(), 0);
        assertEq(feeFloor.floorCount(), 0);

        // Other protocol fees arrive through the processor's other two sources: deal-vault credit and the sink. The
        // sink's 10 USDG lifts the pot over the threshold whichever fixture vault fills first (vault addresses follow
        // the factory's nonce).
        uint256 credited = _dealFee();
        usdg.mint(address(feeSink), 10e6);
        uint256 pot = fee + credited + 10e6;
        assertEq(processor.availableUSDG(), pot);
        assertGe(pot, THRESHOLD);

        Route memory a = _route();
        vm.expectEmit(address(processor));
        emit DealFeeRouter.BatchOpened(pot);
        ClipReceipt memory first_ = _process(stranger, 60e6);
        Route memory b = _route();
        assertEq(first_.caller, stranger, "permissionless");
        _assertReconciled(a, b, first_, 60e6);
        assertEq(b.batchRemaining, pot - 60e6, "the rest of the batch stays open");
        assertEq(b.floorCount, 1, "a band exists");
        assertGt(first_.bandLiquidity, 0);

        // The remainder is under the threshold, yet it belongs to the open batch and finishes.
        assertLt(b.available, THRESHOLD);
        ClipReceipt memory second_ = _process(stranger, pot - 60e6);
        Route memory c = _route();
        _assertReconciled(b, c, second_, pot - 60e6);
        assertEq(second_.tokenId, first_.tokenId, "the same band");
        assertGt(second_.bandLiquidity, first_.bandLiquidity, "the band grew");
        assertEq(c.processed, pot, "every unit of the pot was spent, the Intent fee included");
        assertEq(c.available, 0);
        assertEq(c.batchRemaining, 0);
        (uint256 backing,) = feeFloor.floorBacking();
        assertApproxEqAbs(backing, c.gageAdded, 2, "the floor holds the GAGE that was added");
    }

    // ---------------------------------------------------------------- 3. a failed swap preserves everything

    function testASwapThatCannotMeetItsMinimumRevertsAndLeavesEveryBalanceAndCounterUnchanged() public {
        uint256 fee = _earn(fillers[0], 1000e6);
        fills.claim(address(processor));
        // Other fees make a pot of 5,000 USDG, about 2 ETH: twice what the GAGE/ETH pool takes inside a 1% impact.
        _dealFee();
        usdg.mint(address(feeSink), 5000e6 - fee - 79_600_000);
        assertEq(processor.availableUSDG(), 5000e6);

        Route memory a = _route();
        vm.expectPartialRevert(IV4SwapperErrors.TooLittleOut.selector);
        processor.process(5000e6);
        assertTrue(_same(a, _route()), "nothing moved: balances, batch, counters, upstream sources");
        assertEq(a.batchRemaining, 0, "the batch the failed call opened was rolled back with it");

        // The same pot in a smaller clip goes through, and the rest stays in the open batch.
        ClipReceipt memory r = _process(stranger, 500e6);
        Route memory b = _route();
        _assertReconciled(a, b, r, 500e6);
        assertEq(b.batchRemaining, 4500e6);
        assertEq(b.processorUSDG, 4500e6);

        // A clip above what is left is refused before any swap.
        vm.expectRevert(abi.encodeWithSelector(DealFeeRouter.ClipTooLarge.selector, 4500e6 + 1, 4500e6));
        processor.process(4500e6 + 1);
        assertTrue(_same(b, _route()));
    }

    // ---------------------------------------------------------------- 4. no revenue without an activation, no replay

    function testARefusedPlanOrAFailedActivationCreditsNothingAndAClaimCannotBeReplayed() public {
        Route memory a = _route();
        // A refused plan: the quote expired before the fill.
        (IntentQuoteVerifier.Plan memory stale,,) = _planFor(fillers[0], 1000e6);
        vm.warp(block.timestamp + 91);
        _assertRefused(stale, IntentQuoteVerifier.Refusal.EXPIRED);
        // A failed activation: the last vault cannot pay once its manager keeps every asset liquid, so the first
        // vault's purchase, already made in the same call, is rolled back with it.
        (IntentQuoteVerifier.Plan memory p, uint256 id,) = _planFor(fillers[0], 1000e6);
        bytes memory signature = _sign(p);
        (uint128 cap, uint16 asset, uint16 buffer) =
            (second.maxLoanPrincipal(), second.maxAssetBps(), second.bufferBps());
        uint256 state = vm.snapshotState();
        IntentLimits.setLimits(second, cap, asset, 10_000);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        fills.fill(p, signature, _shares(2));
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.FUNDING));
        assertEq(fills.owed(address(processor)), 0, "nothing owed for a fill that did not happen");
        assertTrue(_same(a, _route()), "zero revenue anywhere");
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(address(processor));

        // The same plan, once it can activate, earns its fee once. Lowering the buffer again would wait three hours
        // (D53), past the plan's life, so the state before the tightening is restored instead.
        vm.revertToState(state);
        assertEq(second.bufferBps(), buffer);
        vm.prank(fillers[0]);
        fills.fill(p, signature, _shares(2));
        uint256 fee = fills.owed(address(processor));
        assertGt(fee, 0);
        assertEq(fills.claim(address(processor)), fee);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(address(processor));
        vm.prank(stranger);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(address(processor));
        assertEq(usdg.balanceOf(address(processor)), fee, "paid once");
        assertEq(processor.availableUSDG(), fee);
        assertEq(usdg.balanceOf(address(fills)), 0);
        // A used plan cannot earn again either.
        _assertRefused(p, IntentQuoteVerifier.Refusal.CONSUMED);
        assertEq(fills.totalOwed(), 0);
    }

    // ---------------------------------------------------------------- 5. one address for both of Gage's portions

    function testTheWholeFeeIsOwedToTheProcessorAndPaidByOneClaim() public {
        assertEq(partnerFactory.protocolRecipient(), address(processor));
        (IntentQuoteVerifier.Plan memory p, uint256 id, uint256 fee) = _planFor(fillers[0], 1_000_000_003);
        vm.expectEmit(address(fills));
        emit IntentFillRouter.Filled(
            verifier.planHash(p), id, fillers[0], uint40(block.timestamp), 1_000_000_003, fee, address(processor)
        );
        _fill(p);
        assertEq(fills.owed(address(processor)), fee, "one entry holds the whole fee");
        assertEq(fills.totalOwed(), fee, "counted once");
        assertEq(usdg.balanceOf(address(fills)), fee);
        assertEq(fills.claim(address(processor)), fee);
        assertEq(usdg.balanceOf(address(processor)), fee, "nothing lost");
        assertEq(fills.totalOwed(), 0);
        assertEq(usdg.balanceOf(address(fills)), 0, "nothing left behind");
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(address(processor));
    }

    // ---------------------------------------------------------------- 6. an external participant keeps its share

    /// @dev D49: an admitted outside filler earns no share in V1; the whole fee is the protocol recipient's, and what is
    /// earned stays with the recipient of the day it was earned.
    function testAnOutsideFillerEarnsNothingAndTheWholeFeeStaysWithTheRecipientOfTheDay() public {
        uint256 fee = _earn(fillers[1], 1_000_000_003);
        assertEq(fills.owed(externalPayout), 0, "no filler share");
        assertEq(fills.owed(address(processor)), fee, "the protocol recipient takes the whole fee");

        // Every later setting: a new protocol recipient.
        address newProtocol = address(new MockFeeProcessor(address(usdg)));
        partnerFactory.setProtocolRecipient(newProtocol);
        assertEq(fills.owed(address(processor)), fee, "unchanged");
        assertEq(fills.owed(newProtocol), 0, "nothing moved to the new address");

        // The old recipient is still paid, by anyone, and only it.
        vm.prank(stranger);
        assertEq(fills.claim(address(processor)), fee);
        assertEq(usdg.balanceOf(address(processor)), fee);
        assertEq(processor.availableUSDG(), fee);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(externalPayout);
        assertEq(fills.totalOwed(), 0);

        // A fill under the new settings is earned under them: nothing for the filler, all of it to the new recipient.
        uint256 next = _earn(fillers[1], 1000e6);
        assertEq(fills.owed(newProtocol), next);
        assertEq(fills.owed(externalPayout) + fills.owed(address(processor)), 0);
    }

    // ---------------------------------------------------------------- 7. a pause of lending does not stop revenue

    function testWithEveryVaultPausedAndNoRouterNamedEarnedFeesAreStillClaimedAndProcessed() public {
        uint256 fee = _earn(fillers[0], 1000e6);
        (IntentQuoteVerifier.Plan memory blocked,,) = _planFor(fillers[0], 1000e6);
        vm.startPrank(curator);
        first.setPaused(true);
        second.setPaused(true);
        vm.stopPrank();
        vm.prank(safe);
        dealRegistry.pauseNewDeals(true);
        // New lending is stopped: by every vault's pause, and then by a factory that names no router or signer.
        bytes memory signature = _sign(blocked);
        vm.prank(fillers[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE)
        );
        fills.fill(blocked, signature, _shares(2));
        partnerFactory.setFillRouter(address(0));
        partnerFactory.setQuoteSigner(address(0));
        vm.prank(fillers[0]);
        vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
        fills.fill(blocked, signature, _shares(2));

        // Revenue is not: the claim, and the processing of it with the other fees already in the pot.
        vm.prank(stranger);
        assertEq(fills.claim(address(processor)), fee);
        usdg.mint(address(feeSink), THRESHOLD);
        Route memory a = _route();
        ClipReceipt memory r = _process(stranger, THRESHOLD + fee);
        _assertReconciled(a, _route(), r, THRESHOLD + fee);
        assertEq(processor.availableUSDG(), 0);
    }

    // ---------------------------------------------------------------- 8. the floor is refused as recipient

    /// @dev `FeeFloor` is where the GAGE ends up, so it is the address a hurried configuration names: every publication
    /// script did, from S1 to S4. It has no USDG path at all: no function of it reads, approves, swaps or sends USDG,
    /// and `DealFeeRouter.availableUSDG()` does not count its balance. Since the S7 guard the factory refuses it, and
    /// everything else that is not a processor of this USDG, as protocol recipient. A filler's payout stays the
    /// filler's own choice, but since D49 a filler's share is zero, so a filler paid to the floor receives nothing and
    /// nothing is stranded there.
    function testTheFactoryRefusesTheFloorAsProtocolRecipientAndAFillerPaidThereReceivesNothing() public {
        address[3] memory refused = [address(feeFloor), address(feeSink), stranger];
        // The floor has no `USDG()` and the sink no `availableUSDG()`: each call reverts with no data. A wallet is
        // refused with NotAFeeProcessor.
        bytes[3] memory reasons =
            [bytes(""), bytes(""), abi.encodeWithSelector(IntentFactory.NotAFeeProcessor.selector)];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(reasons[i]);
            partnerFactory.setProtocolRecipient(refused[i]);
        }
        partnerFactory.setProtocolRecipient(address(processor));
        // D49: with no filler share or payout, nothing a filler earns can be stranded at the floor; the whole fee
        // reaches the processor.
        uint256 available = processor.availableUSDG();
        uint256 fee = _earn(fillers[0], 1000e6);
        assertEq(fills.owed(address(feeFloor)), 0, "nothing owed to the floor");
        assertEq(fills.owed(address(processor)), fee);
        assertEq(fills.claim(address(processor)), fee);
        assertEq(usdg.balanceOf(address(feeFloor)), 0, "no USDG stranded at the floor");
        assertEq(processor.availableUSDG() - available, fee, "the processor counts all of it");
    }

    // ---------------------------------------------------------------- fuzz: every unit owed is held

    /// @dev `owed` has three possible holders here: the processor, the external payout and nobody else.
    function _assertHeld() internal view {
        uint256 sum = fills.owed(address(processor)) + fills.owed(externalPayout);
        assertEq(sum, fills.totalOwed(), "sum(owed) == totalOwed");
        assertEq(usdg.balanceOf(address(fills)), fills.totalOwed(), "the router holds exactly what it owes");
    }

    function testFuzz_EveryUnitOwedIsHeldAndAllOfItReachesTheProcessor(
        uint128 principal,
        uint128 principal2,
        uint8 claims
    ) public {
        principal = uint128(bound(principal, 100e6, 3000e6));
        principal2 = uint128(bound(principal2, 100e6, 3000e6));
        uint256 available = processor.availableUSDG();

        // The Gage keeper's fill, then an outside filler's: under D49 both fees are the processor's whole.
        uint256 fee = _earn(fillers[0], principal + 3);
        _assertHeld();
        uint256 paidToProcessor;
        if (claims & 1 != 0) paidToProcessor += fills.claim(address(processor));
        _assertHeld();
        uint256 fee2 = _earn(fillers[1], principal2 + 1);
        _assertHeld();
        assertEq(fills.owed(externalPayout), 0);
        assertEq(fills.owed(address(processor)) + paidToProcessor, fee + fee2);

        if (claims & 2 != 0 && fills.owed(address(processor)) != 0) paidToProcessor += fills.claim(address(processor));
        _assertHeld();

        assertEq(processor.availableUSDG() - available, paidToProcessor, "only claimed fees arrive");
        assertEq(usdg.balanceOf(externalPayout), 0);
        assertEq(paidToProcessor + fills.totalOwed(), fee + fee2, "every unit is paid or still owed");
    }
}
