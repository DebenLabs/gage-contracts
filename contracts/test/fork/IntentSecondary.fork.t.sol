// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IntentMainnetForkBase} from "./IntentMainnetForkBase.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentPreflight} from "../intent/IntentPreflight.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {IGageV2LegacyCore} from "../../src/interfaces/IGageV2LegacyCore.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

using {remainingLenderReward} for GageV2Rewards;

/// @dev The split-sale capability marker the S9 ledger published before X-dup-17 removed it; engines deployed before
/// S9 never had it. Probed here on the manifest's live engines only.
interface ILenderSplitLedger {
    function LENDER_SPLIT_VERSION() external view returns (uint8);
}

using {unitsOf} for GageV2Vault;

/// @notice S9-09 / SEC-21: a secondary purchase of one listed lender position by three Intent vaults on a LOCAL fork of
/// Robinhood Chain mainnet (4663) at one pinned block, against the live dependencies. No deployed core can split a
/// sale (every deployed engine predates `buyLenderSplit`), so the S9 core is deployed inside the fork VM on the LIVE
/// shared collateral validator (and so the live registry, USDG and sGAGE) with the live core's fee recipient; the S9
/// Intent stack stands on it with the LIVE Morpho reserve and the LIVE fee route as the protocol's recipient. Nothing is
/// ever sent to the chain; every balance handed out is a `deal` storage edit.
/// @dev Skipped unless INTENT_MAINNET_FORK_URL is set (S7's base). Each scenario is its own test on the shared `setUp`;
/// `testTheSecondaryPurchaseWritesItsEvidence` runs them one after another from that starting state and writes the
/// evidence file. Model rate, extra return, ceilings, limits and deposits are fixture values, not launch values.
contract IntentSecondaryForkTest is IntentMainnetForkBase {
    string internal constant EVIDENCE = "../docs/intent-v1/evidence/s9-mainnet-fork-secondary.json";
    uint16 internal constant CAP_BPS = 2000;
    uint32 internal constant COST_BPS = 1000;
    uint8 internal constant RATE_GRADE_B = 3;
    uint32 internal constant MODEL_BPS = 1000;
    uint16 internal constant EXTRA_BPS = 300;
    uint128 internal constant PRINCIPAL = 1000e6;
    uint128 internal constant CAP = 1100e6;
    /// @dev An odd listing price, so the per-quarter remainder rule is exercised on the live tokens too, above the
    /// seller's floor three days in: book value plus half the interest still to come (Pashov L-01).
    uint128 internal constant PRICE = 1070e6 + 3;

    GageV2Vault internal liveCore;
    GageV2Rewards internal coreRewards;
    IntentFactory internal factory;
    IntentQuoteVerifier internal verifier;
    IntentFillRouter internal fills;
    GradeRegistry internal grades;
    Vm.Wallet internal signer;
    IntentVault internal seller;
    IntentLenderMarket internal market;
    IntentVault internal buyerA;
    IntentVault internal buyerB;
    IntentVault internal buyerC;
    address internal collateral;
    uint256 internal collateralAmount;
    address internal vaultCode;

    address internal curator = makeAddr("s9-fork-curator");
    /// @dev Runs the buyers: never the seller's curator, whose own vaults the verifier refuses as buyers (L-01).
    address internal buyerCurator = makeAddr("s9-fork-buyer-curator");
    address internal filler = makeAddr("s9-fork-keeper-filler");
    address internal borrower = makeAddr("s9-fork-borrower");
    address internal depositor = makeAddr("s9-fork-depositor");

    function setUp() public {
        if (!_fork()) return;
        _liveCoreAndReserve();
        liveCore = core;
        // The S9 core: the live registry, USDG and sGAGE and the live core's fee recipient, zero grace.
        core = new GageV2Vault(
            GageV2TokenRegistry(address(liveCore.REGISTRY())),
            liveCore.USDG(),
            liveCore.SGAGE(),
            liveCore.FEE_RECIPIENT(),
            0,
            GageLegacyAdapter(address(0))
        );
        coreRewards = GageV2Rewards(address(core.REWARDS()));
        // An engine lends to no one until a funder gate is bound (D47); these accounts stand in for vaults.
        address registryOwner = core.REGISTRY().owner();
        vm.startPrank(registryOwner);
        coreRewards.bindFunderGate(new MockOpenFunderGate());
        vm.stopPrank();
        IERC20 sgage = IERC20(address(core.SGAGE()));
        deal(address(sgage), address(this), 1_000_000e18);
        sgage.approve(address(coreRewards), type(uint256).max);
        coreRewards.fund(1_000_000e18);
        vm.label(address(core), "S9-GageV2Vault");
        _standIntent();
    }

    // ---------------------------------------------------------------- the stack, in the fork VM only

    function _mandate(uint16 feeBps, uint8 minRateGrade, uint128 maxLoanPrincipal, address[] memory assets)
        internal
        view
        returns (IntentVault.Mandate memory)
    {
        return IntentVault.Mandate({
            curator: curator,
            categoryWeights: [uint16(10_000), 0, 0, 0],
            assets: assets,
            maxLoanTerm: T21,
            feeBps: feeBps,
            minGrade: 5,
            minRateGrade: minRateGrade,
            maxLoanPrincipal: maxLoanPrincipal,
            maxAssetBps: 10_000,
            bufferBps: 0,
            executionCapBps: CAP_BPS
        });
    }

    /// @dev A buyer's mandate, run by `buyerCurator`.
    function _buyerMandate(uint128 maxLoanPrincipal, address[] memory assets)
        internal
        view
        returns (IntentVault.Mandate memory m)
    {
        m = _mandate(1000, 0, maxLoanPrincipal, assets);
        m.curator = buyerCurator;
    }

    function _standIntent() internal {
        signer = vm.createWallet("s9-fork-quote-signer");
        grades = new GradeRegistry(address(this), address(this));
        vaultCode = address(new IntentVaultCode());
        factory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: reserve,
                reserveLens: address(new MorphoV2ReserveLens()),
                grades: address(grades),
                protocolRecipient: address(processor),
                initialOwner: address(this),
                codeA: IntentVaultCode(vaultCode).CHUNK_A(),
                codeB: IntentVaultCode(vaultCode).CHUNK_B()
            })
        );
        verifier = new IntentQuoteVerifier(factory);
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), usdg);
        factory.setFillRouter(address(fills));
        factory.setQuoteSigner(signer.addr);
        factory.setCreator(curator, true);
        factory.setCreator(buyerCurator, true);
        factory.setFiller(filler, true);

        ICollateralRegistry.ERC20Config memory config;
        (collateral, config) = _admittedStock();
        collateralAmount = config.minAmount * 10 <= config.maxDealRaw ? config.minAmount * 10 : config.minAmount;
        factory.assignCategory(collateral, IntentCategory.STOCK);
        address[] memory tokens = new address[](1);
        uint8[] memory ranks = new uint8[](1);
        uint32[] memory terms = new uint32[](1);
        uint32[] memory costs = new uint32[](1);
        (tokens[0], ranks[0], terms[0], costs[0]) = (collateral, 7, T21, COST_BPS);
        grades.setGrades(tokens, ranks);
        grades.setModeledCosts(tokens, terms, costs);

        vm.prank(curator);
        seller = IntentVault(factory.create(_mandate(1500, RATE_GRADE_B, 5000e6, tokens), false, 0, "Test vault"));
        // Each buyer is capped below the listing: no one of them could buy it alone.
        vm.startPrank(buyerCurator);
        buyerA = IntentVault(factory.create(_buyerMandate(600e6, tokens), true, EXTRA_BPS, "Test vault"));
        buyerB = IntentVault(factory.create(_buyerMandate(300e6, tokens), true, EXTRA_BPS, "Test vault"));
        buyerC = IntentVault(factory.create(_buyerMandate(300e6, tokens), true, EXTRA_BPS, "Test vault"));
        vm.stopPrank();
        market = seller.LENDER_MARKET();
        vm.label(address(seller), "IntentVault-seller");
        vm.label(address(buyerA), "IntentVault-buyerA");
        vm.label(address(buyerB), "IntentVault-buyerB");
        vm.label(address(buyerC), "IntentVault-buyerC");
        _deposit(seller, 5000e6);
        _deposit(buyerA, 5000e6);
        _deposit(buyerB, 5000e6);
        _deposit(buyerC, 5000e6);
    }

    function _deposit(IntentVault vault, uint256 assets) internal {
        deal(address(usdg), depositor, usdg.balanceOf(depositor) + assets);
        vm.startPrank(depositor);
        usdg.approve(address(vault), assets);
        vault.deposit(assets, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the loan the seller holds, and its listing

    /// @dev A 21-day loan listed on the S9 core, funded whole by the seller vault through a signed primary plan, three
    /// days into its term and listed for `PRICE` on the seller's own market.
    function _onSale() internal returns (uint256 id) {
        deal(collateral, borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(collateral).approve(address(core), collateralAmount);
        id = core.list(
            Collateral(Kind.ERC20, collateral, collateralAmount),
            PRINCIPAL,
            CAP,
            T21,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.stopPrank();
        IntentQuoteVerifier.Plan memory p = _primaryPlan(id);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, verifier.planHash(p));
        uint256[] memory limits = new uint256[](1);
        limits[0] = type(uint256).max;
        vm.prank(filler);
        fills.fill(p, abi.encodePacked(r, s, v), limits);
        assertEq(core.unitsOf(id, address(seller)), 4, "the seller holds the whole loan");
        vm.warp(block.timestamp + 3 days);
        // Read before the prank: a view call would take it.
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        market.list(id, PRICE, deadline, 100);
    }

    function _maturity(uint256 id) internal view returns (uint256) {
        V2Loan memory l = core.getLoan(id);
        return uint256(l.fundedAt) + l.term;
    }

    /// @dev What vault `v`'s schedule for loan `id` has earned until now, as its share price counts it.
    function _accrued(IntentVault v, uint256 id) internal view returns (uint256) {
        (,,, uint40 maturity,,,,,,,,, uint128 rate, uint64 clockStart,,) = v.loans(id);
        uint256 end = block.timestamp < maturity ? block.timestamp : maturity;
        // The vault's rate precision: interest per second scaled by 1e18.
        return uint256(rate) * (end - clockStart) / 1e18;
    }

    function _primaryPlan(uint256 id) internal view returns (IntentQuoteVerifier.Plan memory p) {
        V2Loan memory l = core.getLoan(id);
        p.engine = address(core);
        p.listingId = id;
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
        p.evidence = keccak256("s9 mainnet fork seller origination");
        p.allocations = new IntentQuoteVerifier.Allocation[](1);
        IntentQuoteVerifier.Allocation memory a = p.allocations[0];
        a.vault = address(seller);
        a.units = 4;
        a.principal = l.principal;
        a.interest = l.cap - l.principal;
        a.minRateGrade = seller.minRateGrade();
        a.capBps = seller.executionCapBps();
        a.managerBps = seller.feeBps();
        a.minimum = uint128(IntentFeeMath.minimumInterest(a.principal, COST_BPS, a.minRateGrade));
        (, uint256 fee) = IntentFeeMath.executionFee(a.interest, a.minimum, a.capBps);
        a.executionFee = uint128(fee);
        a.maxReserveShares = uint128(seller.RESERVE().previewWithdraw(uint256(a.principal) + fee));
    }

    // ---------------------------------------------------------------- the secondary plan an honest signer would sign

    function _vaults() internal view returns (IntentVault[] memory vaults, uint8[] memory masks) {
        vaults = new IntentVault[](3);
        masks = new uint8[](3);
        // Two nonadjacent quarters to A, one each to B and C: 2/1/1.
        (vaults[0], masks[0]) = (buyerA, 5);
        (vaults[1], masks[1]) = (buyerB, 2);
        (vaults[2], masks[2]) = (buyerC, 8);
        for (uint256 i = 1; i < 3; ++i) {
            for (uint256 j = i; j > 0 && address(vaults[j]) < address(vaults[j - 1]); --j) {
                (vaults[j], vaults[j - 1]) = (vaults[j - 1], vaults[j]);
                (masks[j], masks[j - 1]) = (masks[j - 1], masks[j]);
            }
        }
    }

    function _secondaryPlan(uint256 id) internal view returns (IntentQuoteVerifier.SecondaryPlan memory p) {
        (uint128 price,,, uint8 slots, uint64 nonce) = market.asks(id);
        V2Loan memory l = core.getLoan(id);
        p.engine = address(core);
        p.loanId = id;
        p.seller = address(seller);
        p.market = address(market);
        p.slots = slots;
        p.price = price;
        p.nonce = nonce;
        p.maxFeeBps = 100;
        p.filler = filler;
        p.token = l.token;
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.maturity = uint40(_maturity(id));
        p.modelAnnualBps = MODEL_BPS;
        p.policyVersion = verifier.SECONDARY_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.valuedAt = uint40(block.timestamp);
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("s9 mainnet fork secondary fixture");
        for (uint8 q; q < 4; ++q) {
            if (p.slots & (1 << q) != 0) {
                p.minRewards[q] = uint128(coreRewards.remainingLenderReward(id, uint8(1 << q)));
            }
        }
        (IntentVault[] memory vaults, uint8[] memory masks) = _vaults();
        p.allocations = new IntentQuoteVerifier.SecondaryAllocation[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            a.vault = address(vaults[i]);
            a.slots = masks[i];
            for (uint8 q; q < 4; ++q) {
                if (masks[i] & (1 << q) == 0) continue;
                a.price += uint128(verifier.quarterPrice(p.price, p.slots, q));
                a.repayment += uint128(p.cap / 4 + (q < p.cap % 4 ? 1 : 0));
            }
            IntentAssetPolicy policy = vaults[i].ASSET_POLICY();
            a.policyRevision = policy.secondaryRevision();
            a.extraBps = policy.minExtraAnnualReturnBps();
            a.capBps = vaults[i].executionCapBps();
            a.managerBps = vaults[i].feeBps();
            a.minimum = uint128(
                IntentFeeMath.secondaryMinimum(a.price, uint256(p.modelAnnualBps) + a.extraBps, p.maturity - p.issuedAt)
            );
            (, uint256 fee) = IntentFeeMath.executionFee(a.repayment - a.price, a.minimum, a.capBps);
            a.executionFee = uint128(fee);
            // The live Morpho reserve's own rate, with half a percent of room: finite, and within the verifier's 1%.
            a.maxReserveShares =
                uint128(IERC4626(address(vaults[i].RESERVE())).previewWithdraw(a.price + fee) * 10_050 / 10_000);
        }
    }

    function _signed(IntentQuoteVerifier.SecondaryPlan memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, verifier.secondaryPlanHash(p));
        return abi.encodePacked(r, s, v);
    }

    function _buy(IntentQuoteVerifier.SecondaryPlan memory p) internal returns (bytes32 digest) {
        bytes memory signature = _signed(p);
        vm.prank(filler);
        digest = fills.fillSecondary(p, signature);
    }

    function _fee(IntentQuoteVerifier.SecondaryPlan memory p) internal pure returns (uint256 fee) {
        for (uint256 i; i < p.allocations.length; ++i) {
            fee += p.allocations[i].executionFee;
        }
    }

    /// @dev Everything a failed purchase must leave as it was.
    function _fingerprint(uint256 id, bytes32 digest) internal view returns (bytes32) {
        address[4] memory owners = core.lenders(id);
        bytes memory books;
        IntentVault[4] memory all = [seller, buyerA, buyerB, buyerC];
        for (uint256 i; i < 4; ++i) {
            books = abi.encode(
                books, all[i].cash(), all[i].reserveShares(), all[i].performingPrincipal(), all[i].totalAssets()
            );
        }
        (uint128 price,,,, uint64 nonce) = market.asks(id);
        return keccak256(
            abi.encode(
                owners,
                books,
                price,
                nonce,
                fills.totalOwed(),
                usdg.balanceOf(address(fills)),
                usdg.balanceOf(reserve),
                verifier.consumed(digest)
            )
        );
    }

    // ---------------------------------------------------------------- scenarios

    struct Bought {
        uint256 id;
        bytes32 digest;
        uint256 fee;
        uint256 sellerCashGain;
        /// @dev The seller's gain above book value, its holders' earnings claim (D51).
        uint256 sellerEarningsClaim;
        uint256 price;
    }

    function testThreeVaultsBuyAListingNoneCouldTakeAloneAgainstTheLiveDependencies() public {
        _scenarioPurchase();
    }

    function _scenarioPurchase() internal returns (Bought memory b) {
        b.id = _onSale();
        IntentQuoteVerifier.SecondaryPlan memory p = _secondaryPlan(b.id);
        // No buyer alone: each vault's own cap refuses the whole listing.
        for (uint256 i; i < 3; ++i) {
            assertLt(IntentVault(p.allocations[i].vault).maxLoanPrincipal(), p.price, "no buyer could take it alone");
        }
        IntentQuoteVerifier.Refusal before_ = IntentPreflight.secondaryReason(verifier, p, _signed(p), filler);
        assertEq(uint8(before_), 0, "an executable plan");
        uint256 sellerCash = seller.cash();
        uint256 sellerAssets = seller.totalAssets();
        uint256 sellerPockets = seller.pocketCount();
        uint256 sellerLiability = seller.pocketLiability(address(usdg));
        (,,,,,,,,,,,,,, uint128 sellerExecutionFee,) = seller.loans(b.id);
        // The seller's book value of the position (D48): what it paid plus what its schedule has earned until now.
        uint256 book = PRINCIPAL + _accrued(seller, b.id);
        uint256 owedBefore = fills.owed(address(processor));
        b.digest = _buy(p);
        b.fee = _fee(p);
        b.price = p.price;
        b.sellerCashGain = seller.cash() - sellerCash;

        // Every listed quarter reached exactly its buyer; one ask consumed, one trade fee charged on the whole price.
        address[4] memory owners = core.lenders(b.id);
        for (uint256 i; i < p.allocations.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            for (uint8 q; q < 4; ++q) {
                if (a.slots & (1 << q) != 0) assertEq(owners[q], a.vault, "quarter owner");
            }
            (,,,,,,,,, uint128 principal,, uint128 interest,,, uint128 executionFee,) = IntentVault(a.vault).loans(b.id);
            assertEq(principal, a.price, "booked at its price");
            assertEq(executionFee, a.executionFee, "its own fee");
            assertGe(a.repayment - a.price - a.executionFee, a.minimum, "its own floor");
            assertGt(interest, 0);
        }
        // The seller is paid once, net of one trade fee on the whole price and of its manager's fee on the gain. Under
        // D51 it books its book value in cash, so the share price does not move, and the gain above book is one USDG
        // earnings claim for the shares exposed to the position since its purchase.
        uint256 proceeds = p.price - uint256(p.price) * core.REGISTRY().tradeFeeBps() / 10_000;
        uint256 sellerFee = IntentFeeMath.performanceFee(proceeds - PRINCIPAL, sellerExecutionFee, seller.feeBps());
        uint256 net = proceeds - sellerFee;
        assertGt(net, book, "a sale above book value");
        assertEq(b.sellerCashGain, book, "the seller's cash gains its book value");
        assertEq(seller.totalAssets(), sellerAssets, "the sale does not move the seller's share price");
        assertEq(seller.pocketCount(), sellerPockets + 1, "one earnings claim");
        uint256 pocket = seller.pocketCount();
        (uint256 pocketLoan, address pocketToken, uint256 gain,, uint256 claimed, uint64 snapshotId) =
            seller.pockets(pocket);
        assertEq(pocketLoan, b.id);
        assertEq(pocketToken, address(usdg));
        assertEq(gain, net - book, "the gain above book");
        assertEq(claimed, 0);
        assertEq(snapshotId, 0, "an earnings claim, weighed by exposure");
        assertEq(seller.pocketLiability(address(usdg)) - sellerLiability, gain);
        assertEq(b.sellerCashGain + gain, net, "the seller's net proceeds");
        // The depositor held every seller share since the purchase: it claims the gain whole, once.
        uint256 claim = seller.pocketClaimable(pocket, depositor);
        assertApproxEqAbs(claim, gain, 1, "the seller's holder claims the gain");
        uint256 wallet = usdg.balanceOf(depositor);
        vm.prank(depositor);
        assertEq(seller.claimPocket(pocket), claim);
        assertEq(usdg.balanceOf(depositor) - wallet, claim);
        assertEq(seller.pocketLiability(address(usdg)), sellerLiability + gain - claim);
        assertEq(seller.pocketClaimable(pocket, depositor), 0, "a claim pays once");
        b.sellerEarningsClaim = gain;
        (uint128 left,,,,) = market.asks(b.id);
        assertEq(left, 0, "the ask is consumed");
        assertEq(fills.owed(address(processor)) - owedBefore, b.fee, "the whole fee owed to the live processor");
        assertTrue(verifier.consumed(b.digest));
        V2Loan memory l = core.getLoan(b.id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE));
        assertEq(l.cap, CAP, "the borrower's debt is unchanged");
        assertEq(l.originator, borrower, "the borrower is unchanged");
    }

    function testAFailingFinalBuyerRollsEveryParticipantBackOnTheFork() public {
        _scenarioRollback();
    }

    function _scenarioRollback() internal returns (uint256 id) {
        id = _onSale();
        IntentQuoteVerifier.SecondaryPlan memory p = _secondaryPlan(id);
        IntentVault last = IntentVault(p.allocations[p.allocations.length - 1].vault);
        bytes32 digest = verifier.secondaryPlanHash(p);
        bytes memory signature = _signed(p);
        // The last buyer's cap closes after signing: only its own check, after the earlier buyers paid, can see it.
        uint256 state = vm.snapshotState();
        IntentLimits.setLimits(last, 0, 10_000, 0);
        bytes32 before_ = _fingerprint(id, digest);
        vm.prank(filler);
        vm.expectRevert(IntentAssetPolicy.IneligibleDeal.selector);
        fills.fillSecondary(p, signature);
        assertEq(_fingerprint(id, digest), before_, "every participant, the live reserve and the ledger as they were");
        assertFalse(verifier.consumed(digest), "the plan is still usable");
        // Reopening the cap would wait three hours (D53), past the plan's life: the state before closing it returns.
        vm.revertToState(state);
        vm.prank(filler);
        fills.fillSecondary(p, signature);
        assertEq(core.unitsOf(id, address(last)), last == buyerA ? 2 : 1);
    }

    function testRepaymentPaysTheBuyersByTheirQuartersAndTheSellerNothingMore() public {
        _scenarioRepayment();
    }

    function _scenarioRepayment() internal returns (uint256 id, uint256[4] memory paid, uint256[4] memory claims) {
        Bought memory b = _scenarioPurchase();
        id = b.id;
        IntentVault[4] memory all = [seller, buyerA, buyerB, buyerC];
        uint256[4] memory before_;
        for (uint256 i; i < 4; ++i) {
            before_[i] = all[i].cash();
        }
        vm.warp(_maturity(id) - 1 hours);
        deal(address(usdg), borrower, CAP);
        vm.startPrank(borrower);
        usdg.approve(address(core), CAP);
        core.reclaim(id, borrower);
        vm.stopPrank();
        paid[0] = seller.cash() - before_[0];
        assertEq(paid[0], 0, "the seller sold its quarters and is owed nothing more");
        uint256 total;
        address[4] memory owners = core.lenders(id);
        for (uint256 i = 1; i < 4; ++i) {
            uint256 owed;
            for (uint8 q; q < 4; ++q) {
                if (owners[q] == address(all[i])) owed += CAP / 4 + (q < CAP % 4 ? 1 : 0);
            }
            uint256 managerFee;
            (paid[i], claims[i], managerFee) = _bookRepayment(all[i], id, owed, before_[i]);
            total += paid[i] + claims[i] + managerFee;
        }
        assertEq(total, CAP, "the whole repayment, once");
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID));
        // The borrower's side never saw the resale: the whole collateral is theirs to withdraw.
        vm.prank(borrower);
        core.withdrawCollateral(id, borrower);
        assertEq(IERC20(collateral).balanceOf(borrower), collateralAmount, "the borrower's collateral back");
    }

    /// @dev Book in buyer `v` its quarters' repayment `owed`, received an hour before maturity. The buyer is paid its
    /// quarters' repayment less its manager's fee on the gain over what it paid. Under D51 this early booking puts the
    /// position's book value in cash (what it paid plus what its schedule has earned until now), so its share price does
    /// not move, and the rest is one USDG earnings claim for the shares exposed since the purchase, which the buyer's
    /// sole holder claims whole. Returns the cash, the claim and the manager's fee.
    function _bookRepayment(IntentVault v, uint256 id, uint256 owed, uint256 cashBefore)
        internal
        returns (uint256 paid, uint256 gain, uint256 managerFee)
    {
        (,,,,,,,,, uint128 cost,,,,, uint128 executionFee,) = v.loans(id);
        managerFee = IntentFeeMath.performanceFee(owed - cost, executionFee, v.feeBps());
        uint256 book = cost + _accrued(v, id);
        uint256 assets = v.totalAssets();
        uint256 pocket = v.pocketCount() + 1;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        v.settle(ids);
        paid = v.cash() - cashBefore;
        assertEq(paid, book, "each buyer's cash gains its book value");
        assertEq(v.totalAssets(), assets, "the booking does not move the buyer's share price");
        assertEq(v.pocketCount(), pocket, "one earnings claim");
        uint256 loanId;
        address token;
        uint256 claimed;
        uint64 snapshotId;
        (loanId, token, gain,, claimed, snapshotId) = v.pockets(pocket);
        assertEq(loanId, id);
        assertEq(token, address(usdg));
        assertEq(claimed, 0);
        assertEq(snapshotId, 0, "an earnings claim, weighed by exposure");
        assertEq(gain, owed - managerFee - book, "the rest of the repayment is the buyer's holders' claim");
        assertEq(paid + gain, owed - managerFee, "each buyer is paid exactly its quarters' repayment, net of its fee");
        uint256 claim = v.pocketClaimable(pocket, depositor);
        assertApproxEqAbs(claim, gain, 1, "the buyer's holder claims the rest");
        uint256 wallet = usdg.balanceOf(depositor);
        vm.prank(depositor);
        assertEq(v.claimPocket(pocket), claim);
        assertEq(usdg.balanceOf(depositor) - wallet, claim);
        assertEq(v.pocketClaimable(pocket, depositor), 0, "a claim pays once");
    }

    function testTheSecondaryFeeIsClaimedIntoTheLiveProcessorAndOneClipReachesTheFloor() public {
        _scenarioRevenue();
    }

    function _scenarioRevenue() internal returns (uint256 fee, Search memory found, Clip memory c) {
        Readback memory live = _readback();
        Bought memory b = _scenarioPurchase();
        uint256 owed = fills.owed(address(processor));
        uint256 available = processor.availableUSDG();
        vm.prank(anyone);
        assertEq(fills.claim(address(processor)), owed);
        assertEq(processor.availableUSDG() - available, owed, "availableUSDG rose by exactly the claim");
        assertEq(fills.totalOwed(), 0);
        fee = b.fee;
        found = _search(processor.availableUSDG(), live.threshold);
        Route memory a = _route();
        c = _processReconciled(a, found.largestPassing);
    }

    function testEveryDeployedEngineIsIdentifiedAsUnableToSplitASale() public {
        _scenarioEngines();
    }

    /// @dev Every engine the live manifest names, read at the pin: its rewards ledger has no split-sale version, so it
    /// has no split sale either. The verifier no longer reads that marker: its constructor probes the core's split
    /// sale itself (`LENDER_SPLIT`) and refuses every secondary plan `UNSUPPORTED_ENGINE` over a core without one.
    /// This fixture's verifier serves its factory's S9 core.
    function _scenarioEngines() internal returns (string memory json) {
        string memory o = "s9engines";
        uint256 count;
        for (uint256 i; vm.keyExistsJson(manifest, string.concat(".nativeV2.engines[", vm.toString(i), "]")); ++i) {
            address engine =
                vm.parseJsonAddress(manifest, string.concat(".nativeV2.engines[", vm.toString(i), "].engine"));
            address rewards = address(GageV2Vault(engine).REWARDS());
            bool split;
            try ILenderSplitLedger(rewards).LENDER_SPLIT_VERSION() returns (uint8 version) {
                split = version == 1;
            } catch {}
            assertFalse(split, "a deployed engine cannot split a sale");
            json = vm.serializeBool(o, vm.toString(engine), split);
            ++count;
        }
        assertEq(count, 3, "the manifest's three engines");
        assertTrue(verifier.LENDER_SPLIT());
    }

    // ---------------------------------------------------------------- evidence

    function testTheSecondaryPurchaseWritesItsEvidence() public {
        string memory o = "s9purchase";
        uint256 start = vm.snapshotState();
        Bought memory b = _scenarioPurchase();
        _n(o, "loanId", b.id);
        _n(o, "price", b.price);
        _n(o, "executionFee", b.fee);
        _n(o, "sellerCashGain", b.sellerCashGain);
        _n(o, "sellerEarningsClaim", b.sellerEarningsClaim);
        vm.serializeBytes32(o, "digest", b.digest);
        address[4] memory owners = core.lenders(b.id);
        vm.serializeAddress(o, "quarter0", owners[0]);
        vm.serializeAddress(o, "quarter1", owners[1]);
        vm.serializeAddress(o, "quarter2", owners[2]);
        string memory purchase = vm.serializeAddress(o, "quarter3", owners[3]);
        vm.revertToState(start);

        start = vm.snapshotState();
        uint256 rolled = _scenarioRollback();
        string memory rollback = _n("s9rollback", "loanId", rolled);
        vm.revertToState(start);

        start = vm.snapshotState();
        (uint256 repaidId, uint256[4] memory paid, uint256[4] memory claims) = _scenarioRepayment();
        o = "s9repayment";
        _n(o, "loanId", repaidId);
        _n(o, "sellerPaid", paid[0]);
        _n(o, "buyerAPaid", paid[1]);
        _n(o, "buyerBPaid", paid[2]);
        _n(o, "buyerCPaid", paid[3]);
        _n(o, "buyerAEarningsClaim", claims[1]);
        _n(o, "buyerBEarningsClaim", claims[2]);
        string memory repayment = _n(o, "buyerCEarningsClaim", claims[3]);
        vm.revertToState(start);

        start = vm.snapshotState();
        string memory engines = _scenarioEngines();
        vm.revertToState(start);

        (uint256 fee, Search memory found, Clip memory c) = _scenarioRevenue();
        o = "s9revenue";
        _n(o, "executionFee", fee);
        _n(o, "standInUSDG", found.standIn);
        _n(o, "largestPassingClip", found.largestPassing);
        _n(o, "smallestFailingClip", found.smallestFailing);
        _n(o, "clipUSDGIn", c.usdgIn);
        _n(o, "clipGAGEAdded", c.gageAdded);
        _n(o, "bandTokenId", c.tokenId);
        _n(o, "bandLiquidityBefore", c.bandLiquidityBefore);
        string memory revenue = _n(o, "bandLiquidityAfter", c.bandLiquidity);

        o = "s9addresses";
        vm.serializeAddress(o, "liveZeroGraceCore", address(liveCore));
        vm.serializeAddress(o, "liveValidator", address(IGageV2LegacyCore(address(liveCore)).VALIDATOR()));
        vm.serializeAddress(o, "liveRegistry", address(core.REGISTRY()));
        vm.serializeAddress(o, "liveFeeRecipient", core.FEE_RECIPIENT());
        vm.serializeAddress(o, "morphoReserve", reserve);
        vm.serializeAddress(o, "collateralToken", collateral);
        vm.serializeAddress(o, "USDG", address(usdg));
        vm.serializeAddress(o, "DealFeeRouter", address(processor));
        string memory addresses = vm.serializeAddress(o, "FeeFloor", address(feeFloor));

        o = "s9fixture";
        vm.serializeString(
            o,
            "scope",
            "Deployed in the fork VM only: the S9 GageV2Vault on the live shared validator with the live core's fee recipient (every deployed engine predates buyLenderSplit), its rewards funded with dealt sGAGE, IntentFactory (live Morpho reserve, MorphoV2ReserveLens), a GradeRegistry the test published, IntentQuoteVerifier, IntentFillRouter, a seller vault and three buyer vaults. protocolRecipient and the filler's payout are the live DealFeeRouter. USDG, sGAGE and the collateral token were handed out with deal."
        );
        _n(o, "modelAnnualBps", MODEL_BPS);
        _n(o, "extraAnnualBps", EXTRA_BPS);
        _n(o, "executionCapBps", CAP_BPS);
        _n(o, "principal", PRINCIPAL);
        _n(o, "cap", CAP);
        _n(o, "buyerAMaxLoanPrincipal", 600e6);
        _n(o, "buyerBMaxLoanPrincipal", 300e6);
        string memory fixture = _n(o, "buyerCMaxLoanPrincipal", 300e6);

        o = "s9-mainnet-fork-secondary";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "acceptance", "S9-09 / SEC-21 (pinned fork)");
        _n(o, "blockNumber", pinnedBlock);
        vm.serializeBytes32(o, "blockHash", pinnedHash);
        _n(o, "blockTimestamp", pinnedTime);
        _n(o, "checkedAtUnixMs", vm.unixTime());
        vm.serializeString(o, "manifest", "launch/live/4663.json");
        vm.serializeString(o, "test", "contracts/test/fork/IntentSecondary.fork.t.sol");
        vm.serializeBool(o, "mainnetMutations", false);
        vm.serializeBool(o, "localForkOnly", true);
        vm.serializeString(
            o,
            "pin",
            "Read through the public node (INTENT_MAINNET_FORK_URL, no key), which serves historical state for minutes only: a re-run at this pin is served by Foundry's RPC cache (~/.foundry/cache/rpc/4663/<block>); without it, leave INTENT_MAINNET_FORK_BLOCK unset and the suite pins a fresh block."
        );
        vm.serializeString(
            o,
            "scenarios",
            "purchase: a 2/1/1 purchase no buyer could make alone; rollback: the last buyer's own cap closes after signing and every participant, the live reserve and the fee ledger are unchanged, then the same plan succeeds; repayment: a repayment an hour before maturity pays each buyer its quarters net of its manager fee (its book value in cash, the rest as its holders' earnings claim, D51), the seller nothing, the borrower's collateral back; revenue: the fee claimed into the live DealFeeRouter and one reconciled clip into a live GAGE/sGAGE floor band"
        );
        vm.serializeString(
            o,
            "notProvenHere",
            "default and recovery of a bought position, buyer resale and depositor reward claims: local suites (IntentSecondaryLifecycle.t.sol) only"
        );
        vm.serializeString(o, "addresses", addresses);
        vm.serializeString(o, "fixture", fixture);
        vm.serializeString(o, "purchase", purchase);
        vm.serializeString(o, "rollback", rollback);
        vm.serializeString(o, "repayment", repayment);
        vm.serializeString(o, "deployedEnginesSplitSupport", engines);
        vm.writeJson(vm.serializeString(o, "revenue", revenue), EVIDENCE);
    }
}
