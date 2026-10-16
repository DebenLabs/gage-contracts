// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IntentMainnetForkBase} from "./IntentMainnetForkBase.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";

/// @notice S7-A5 / R5-A1, R5-A2: a LOCAL fork of Robinhood Chain mainnet (4663) at one pinned block. It reads the live
/// fee route back, then deploys the Intent stack inside the fork VM against the live zero-grace core and the live
/// Morpho reserve, earns an execution fee from a real fill, claims it to the live `DealFeeRouter` and processes a clip
/// through the live USDG/ETH and GAGE/ETH pools into the live `FeeFloor`. Nothing is ever sent to the chain: no key
/// signs a transaction, no broadcast happens, and every balance handed out is a `deal` storage edit of the fork VM.
/// @dev The fork, the route readback and the clip helpers are `IntentMainnetForkBase`'s, shared with the S8 lifecycle
/// suite. Addresses come from launch/live/4663.json. The mandate, the grade, the modeled cost, the fee ceiling and
/// the split are fixture values, not launch values.
contract IntentRevenueForkTest is IntentMainnetForkBase {
    string internal constant EVIDENCE = "../docs/intent-v1/evidence/s7-mainnet-fork.json";
    uint16 internal constant CAP_BPS = 2000;
    uint32 internal constant COST_BPS = 1000;
    uint128 internal constant PRINCIPAL = 1000e6;
    uint128 internal constant CAP = 1100e6;

    address internal collateral;

    IntentFactory internal factory;
    IntentQuoteVerifier internal verifier;
    IntentFillRouter internal fills;
    IntentVault internal vault;
    GradeRegistry internal grades;
    Vm.Wallet internal signer;

    address internal curator = makeAddr("s7-fork-curator");
    address internal filler = makeAddr("s7-fork-keeper-filler");
    address internal borrower = makeAddr("s7-fork-borrower");
    address internal depositor = makeAddr("s7-fork-depositor");

    function setUp() public {
        _fork();
    }

    function testTheLiveRouteReadsBackAtThePinnedBlock() public {
        Readback memory r = _readback();
        emit log_named_uint("pinned block", pinnedBlock);
        emit log_named_bytes32("pinned block hash", pinnedHash);
        emit log_named_uint("threshold, USDG raw", r.threshold);
        emit log_named_uint("availableUSDG, raw", r.available);
        emit log_named_uint("batchRemaining, raw", r.batchRemaining);
        emit log_named_uint("totalUSDGProcessed, raw", r.processed);
        emit log_named_uint("totalGAGEAdded, raw", r.gageAdded);
    }

    // ---------------------------------------------------------------- the Intent stack, deployed in the fork VM only

    function _standIntent() internal {
        _liveCoreAndReserve();
        signer = vm.createWallet("s7-fork-quote-signer");
        grades = new GradeRegistry(address(this), address(this));
        address lens_ = address(new MorphoV2ReserveLens());
        IntentVaultCode store_ = new IntentVaultCode();
        factory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: reserve,
                reserveLens: lens_,
                grades: address(grades),
                protocolRecipient: address(processor),
                initialOwner: address(this),
                codeA: store_.CHUNK_A(),
                codeB: store_.CHUNK_B()
            })
        );
        verifier = new IntentQuoteVerifier(factory);
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), usdg);
        factory.setFillRouter(address(fills));
        factory.setQuoteSigner(signer.addr);
        factory.setCreator(curator, true);
        // Both of Gage's portions are owed to the live fee processor.
        factory.setFiller(filler, true);
        // D49: the filler's share is locked at zero; the whole execution fee is the processor's.

        ICollateralRegistry.ERC20Config memory config;
        (collateral, config) = _admittedStock();
        factory.assignCategory(collateral, IntentCategory.STOCK);
        address[] memory tokens = new address[](1);
        uint8[] memory ranks = new uint8[](1);
        uint32[] memory terms = new uint32[](1);
        uint32[] memory costs = new uint32[](1);
        (tokens[0], ranks[0], terms[0], costs[0]) = (collateral, 7, T21, COST_BPS);
        grades.setGrades(tokens, ranks);
        grades.setModeledCosts(tokens, terms, costs);

        vm.prank(curator);
        vault = IntentVault(
            factory.create(
                IntentVault.Mandate({
                    curator: curator,
                    categoryWeights: [uint16(10_000), 0, 0, 0],
                    assets: tokens,
                    maxLoanTerm: T21,
                    feeBps: 1000,
                    minGrade: 5,
                    minRateGrade: 2,
                    maxLoanPrincipal: 5000e6,
                    maxAssetBps: 10_000,
                    bufferBps: 0,
                    executionCapBps: CAP_BPS
                }),
                false,
                0,
                "Test vault"
            )
        );
        // Local fork balances only.
        deal(address(usdg), depositor, 10_000e6);
        vm.startPrank(depositor);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, 0);
        vm.stopPrank();

        // The collateral's value is never read in the deal path; ten times the registry's minimum, or the minimum.
        uint256 amount = config.minAmount * 10 <= config.maxDealRaw ? config.minAmount * 10 : config.minAmount;
        deal(collateral, borrower, amount);
        vm.startPrank(borrower);
        IERC20(collateral).approve(address(core), amount);
        listingId = core.list(
            Collateral(Kind.ERC20, collateral, amount), PRINCIPAL, CAP, T21, uint40(block.timestamp + 1 days), false
        );
        vm.stopPrank();
        collateralAmount = amount;
    }

    uint256 internal listingId;
    uint256 internal collateralAmount;

    /// @dev The plan an honest signer would produce for the whole listing, one vault, the reference fee.
    function _plan() internal view returns (IntentQuoteVerifier.Plan memory p) {
        V2Loan memory l = core.getLoan(listingId);
        p.engine = address(core);
        p.listingId = listingId;
        p.filler = filler;
        p.token = l.token;
        p.kind = uint8(l.kind);
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.term = l.term;
        p.costBps = COST_BPS;
        p.feePolicy = verifier.FEE_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("s7 mainnet fork fixture");
        p.allocations = new IntentQuoteVerifier.Allocation[](1);
        IntentQuoteVerifier.Allocation memory a = p.allocations[0];
        a.vault = address(vault);
        a.units = UNITS;
        a.principal = l.principal;
        a.interest = l.cap - l.principal;
        a.minRateGrade = vault.minRateGrade();
        a.capBps = vault.executionCapBps();
        a.managerBps = vault.feeBps();
        a.minimum = uint128(IntentFeeMath.minimumInterest(a.principal, p.costBps, a.minRateGrade));
        (, uint256 fee) = IntentFeeMath.executionFee(a.interest, a.minimum, a.capBps);
        a.executionFee = uint128(fee);
        a.maxReserveShares = uint128(vault.RESERVE().previewWithdraw(uint256(a.principal) + fee));
    }

    // ---------------------------------------------------------------- R5-A2: fee -> claim -> clip -> band

    function testIntentRevenueFollowsTheLiveRouteIntoTheFloorAtThePinnedBlock() public {
        Readback memory live = _readback();
        uint256 liveCredit = feeSink.vault().balanceUSDG(address(feeSink));
        uint256 liveHeld = usdg.balanceOf(address(processor));
        _standIntent();

        // A real fill on the live core: the listing activates and the fee is owed to the live processor.
        IntentQuoteVerifier.Plan memory p = _plan();
        uint256 fee = p.allocations[0].executionFee;
        assertGt(fee, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, verifier.planHash(p));
        uint256[] memory limits = new uint256[](1);
        limits[0] = type(uint256).max;
        vm.prank(filler);
        fills.fill(p, abi.encodePacked(r, s, v), limits);
        V2Loan memory l = core.getLoan(listingId);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "the loan is active on the live core");
        assertEq(l.fundedAt, block.timestamp);
        assertEq(fills.owed(address(processor)), fee, "both of Gage's portions, one entry");
        assertEq(fills.totalOwed(), fee);
        assertEq(usdg.balanceOf(address(fills)), fee);
        // The execution fee is earned, not yet received. What the activation itself sent down the route is another
        // source: the live core's own origination fee, charged to the borrower and credited to the fee sink in the
        // first-generation vault, which `availableUSDG()` counts. The two must never be told apart by timing.
        uint256 afterFill = processor.availableUSDG();
        assertEq(afterFill - live.available, l.originationFee, "only the core's origination fee arrived with the fill");
        assertEq(feeSink.vault().balanceUSDG(address(feeSink)) - liveCredit, l.originationFee, "as deal-vault credit");
        assertEq(usdg.balanceOf(address(processor)), liveHeld, "nothing was paid to the router yet");

        // Anyone claims; the live processor's pot rises by exactly the claim.
        vm.prank(anyone);
        assertEq(fills.claim(address(processor)), fee);
        uint256 afterClaim = processor.availableUSDG();
        assertEq(afterClaim - afterFill, fee, "availableUSDG rose by exactly the claim");
        assertEq(usdg.balanceOf(address(processor)) - liveHeld, fee, "a plain USDG transfer to the router");
        assertEq(fills.totalOwed(), 0);
        assertEq(usdg.balanceOf(address(fills)), 0);

        // The liquidity assumption: the largest clip the live pools take inside the router's own 1% bound.
        Search memory found = _search(afterClaim, live.threshold);
        assertEq(processor.availableUSDG(), found.pot, "the pot: live fees, the Intent fee and the stand-in");
        Route memory a = _route();

        // A clip the pools cannot take reverts and moves nothing.
        uint256 tooLarge = found.smallestFailing != 0 ? found.smallestFailing : found.pot + CENT;
        vm.prank(anyone);
        if (found.smallestFailing != 0) vm.expectPartialRevert(bytes4(found.failure));
        else vm.expectPartialRevert(DealFeeRouter.ClipTooLarge.selector);
        processor.process(tooLarge);
        assertEq(keccak256(abi.encode(_route())), keccak256(abi.encode(a)), "a failed clip leaves every balance");

        // One clip, by an arbitrary caller, reconciled.
        Clip memory c = _processReconciled(a, found.largestPassing);
        _write(live, Earned(fee, l.originationFee, afterFill, afterClaim), found, a, c);
    }

    // ---------------------------------------------------------------- evidence

    struct Earned {
        uint256 fee;
        uint256 originationFee;
        uint256 afterFill;
        uint256 afterClaim;
    }

    function _write(Readback memory live, Earned memory e, Search memory found, Route memory a, Clip memory c)
        internal
    {
        string memory o = "addresses";
        vm.serializeAddress(o, "DealFeeRouter", address(processor));
        vm.serializeAddress(o, "FeeFloor", address(feeFloor));
        vm.serializeAddress(o, "FeeSink", address(feeSink));
        vm.serializeAddress(o, "DealVault", address(feeSink.vault()));
        vm.serializeAddress(o, "USDG", address(usdg));
        vm.serializeAddress(o, "GAGE", address(gage));
        vm.serializeAddress(o, "sGAGE", address(feeFloor.SGAGE()));
        vm.serializeAddress(o, "PoolManager", poolManager);
        vm.serializeAddress(o, "PositionManager", address(posm));
        vm.serializeAddress(o, "PonsCurve", address(processor.PONS_CURVE()));
        vm.serializeAddress(o, "opsWallet", feeFloor.OPS_WALLET());
        vm.serializeAddress(o, "zeroGraceCore", address(core));
        vm.serializeAddress(o, "coreRegistry", address(core.REGISTRY()));
        vm.serializeAddress(o, "morphoReserve", reserve);
        string memory addresses = vm.serializeAddress(o, "collateralToken", collateral);

        o = "route";
        vm.serializeString(o, "feeSinkRoute", "BUYBACK");
        vm.serializeAddress(o, "feeSinkBuyback", feeSink.buyback());
        vm.serializeAddress(o, "routerFLOOR", address(processor.FLOOR()));
        vm.serializeAddress(o, "routerGAGE", address(processor.GAGE()));
        vm.serializeBytes32(o, "routerCodeHash", address(processor).codehash);
        vm.serializeBytes32(o, "floorCodeHash", address(feeFloor).codehash);
        vm.serializeBytes32(o, "sinkCodeHash", address(feeSink).codehash);
        vm.serializeBytes32(o, "gageCodeHash", address(gage).codehash);
        vm.serializeBytes32(o, "usdgEthPoolId", vm.parseJsonBytes32(manifest, ".pools.usdgEth.poolId"));
        vm.serializeBytes32(o, "gageEthPoolId", vm.parseJsonBytes32(manifest, ".pools.gageEth.poolId"));
        vm.serializeBool(o, "ponsCurveGraduated", live.graduated);
        _n(o, "maxImpactBps", processor.MAX_IMPACT_BPS());
        _n(o, "launchPoolFeePips", processor.LAUNCH_POOL_FEE_PIPS());
        _n(o, "threshold", live.threshold);
        _n(o, "availableUSDG", live.available);
        _n(o, "batchRemaining", live.batchRemaining);
        _n(o, "totalUSDGProcessed", live.processed);
        _n(o, "totalGAGEAdded", live.gageAdded);
        _n(o, "floorCount", live.floorCount);
        vm.serializeInt(o, "bandNowTickLower", live.bandLower);
        string memory route = vm.serializeInt(o, "bandNowTickUpper", live.bandUpper);

        o = "intent";
        vm.serializeString(
            o,
            "scope",
            "Deployed in the fork VM only: IntentFactory, MorphoV2ReserveLens, a GradeRegistry the test published, IntentQuoteVerifier, IntentFillRouter and one vault, against the live zero-grace core and the live Morpho reserve. Mandate, grade, modeled cost, 2000 bps ceiling and 2500 bps keeper share are fixture values."
        );
        vm.serializeAddress(o, "protocolRecipient", factory.protocolRecipient());
        _n(o, "fillerShareBps", 0); // V1's router has no filler share (D49)
        _n(o, "listingId", listingId);
        _n(o, "collateralAmount", collateralAmount);
        _n(o, "principal", PRINCIPAL);
        _n(o, "cap", CAP);
        _n(o, "term", T21);
        vm.serializeString(o, "loanState", "ACTIVE");
        vm.serializeString(o, "fundedWith", "deal (fork VM storage edit) for USDG and the collateral token");
        _n(o, "executionFee", e.fee);
        _n(o, "owedToDealFeeRouter", e.fee);
        _n(o, "claimed", e.fee);
        vm.serializeString(
            o,
            "otherSourceAtActivation",
            "The live core charged the borrower its own origination fee at activation and credited it to the fee sink in the first-generation vault, which availableUSDG() counts. It is not Intent revenue and arrives in the fill transaction itself, so receipts must be attributed from Claimed events, never from pot deltas or timing."
        );
        _n(o, "coreOriginationFee", e.originationFee);
        _n(o, "availableBeforeFill", live.available);
        _n(o, "availableAfterFill", e.afterFill);
        _n(o, "availableAfterClaim", e.afterClaim);
        string memory intent = _n(o, "availableDeltaFromClaim", e.afterClaim - e.afterFill);

        o = "liquidity";
        vm.serializeString(
            o,
            "method",
            "Stand-in USDG (deal) was added to the router until a whole-pot clip no longer fit its 1% impact bound; the boundary was then bisected to the cent with state restored after every trial. The router commingles sources by design, so the stand-in represents other protocol fees."
        );
        _n(o, "standInUSDG", found.standIn);
        _n(o, "pot", found.pot);
        _n(o, "largestPassingClip", found.largestPassing);
        _n(o, "smallestFailingClip", found.smallestFailing);
        vm.serializeString(o, "failureReason", _reasonName(found.failure));
        vm.serializeBytes(o, "failureData", found.failure);
        if (found.failure.length == 68 && bytes4(found.failure) == IV4SwapperErrors.TooLittleOut.selector) {
            // The amounts name the leg that ran out of depth: ETH-sized for USDG/ETH, GAGE-sized for GAGE/ETH.
            (uint256 got, uint256 minOut) = abi.decode(_tail(found.failure), (uint256, uint256));
            _n(o, "failureGot", got);
            _n(o, "failureMinOut", minOut);
        }
        string memory liquidity = _n(o, "trials", found.trials);

        o = "clip";
        vm.serializeAddress(o, "caller", c.caller);
        _n(o, "usdgIn", c.usdgIn);
        _n(o, "ethOut", c.ethOut);
        _n(o, "gageBought", c.gageBought);
        _n(o, "gageReceivedByFloor", c.received);
        _n(o, "gageAdded", c.gageAdded);
        vm.serializeString(
            o,
            "gageDust",
            "gageBought + router GAGE held before = received; floor GAGE before + received = floor GAGE after + gageAdded. The floor adds what it holds, earlier remainders included, and keeps the band's liquidity rounding."
        );
        _n(o, "routerGAGEBefore", a.processorGAGE);
        _n(o, "floorGAGEBefore", a.floorGAGE);
        _n(o, "floorGAGEAfter", gage.balanceOf(address(feeFloor)));
        _n(o, "bandTokenId", c.tokenId);
        vm.serializeInt(o, "bandTickLower", c.tickLower);
        vm.serializeInt(o, "bandTickUpper", c.tickUpper);
        vm.serializeBool(o, "newBand", c.newBand);
        _n(o, "bandLiquidityBefore", c.bandLiquidityBefore);
        _n(o, "bandLiquidityAfter", c.bandLiquidity);
        _n(o, "totalUSDGProcessedAfter", processor.totalUSDGProcessed());
        _n(o, "totalGAGEAddedAfter", processor.totalGAGEAdded());
        _n(o, "batchRemainingAfter", processor.batchRemaining());
        _n(o, "routerUSDGAfter", usdg.balanceOf(address(processor)));
        string memory clip = _n(o, "availableUSDGAfter", processor.availableUSDG());

        o = "s7-mainnet-fork";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "acceptance", "S7-A5 / R5-A1, R5-A2");
        _n(o, "blockNumber", pinnedBlock);
        vm.serializeBytes32(o, "blockHash", pinnedHash);
        _n(o, "blockTimestamp", pinnedTime);
        _n(o, "checkedAtUnixMs", vm.unixTime());
        vm.serializeString(o, "manifest", "launch/live/4663.json");
        vm.serializeString(o, "test", "contracts/test/fork/IntentRevenue.fork.t.sol");
        vm.serializeBool(o, "mainnetMutations", false);
        vm.serializeBool(o, "localForkOnly", true);
        vm.serializeString(o, "addresses", addresses);
        vm.serializeString(o, "route", route);
        vm.serializeString(o, "intent", intent);
        vm.serializeString(o, "liquidity", liquidity);
        vm.writeJson(vm.serializeString(o, "clip", clip), EVIDENCE);
    }
}
