// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IntentMainnetForkBase} from "./IntentMainnetForkBase.sol";
import {IntentVault, IntentCategory, IReserveLens} from "../../src/intent/IntentVault.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentFeeBreakdown} from "../intent/IntentFeeBreakdown.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentPreflight} from "../intent/IntentPreflight.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @notice S8-A2 / R6-A2, R6-A9: the whole V1 money lifecycle on a LOCAL fork of Robinhood Chain mainnet (4663) at one
/// pinned block. The Intent stack (factory with the Morpho reserve lens, a grade registry the test publishes, quote
/// verifier, fill router, two partner vaults) is deployed inside the fork VM against the LIVE zero-grace core, the
/// LIVE Morpho reserve and the LIVE fee route, with the protocol's recipient and the keeper-filler's payout both the
/// live `DealFeeRouter`. Nothing is ever sent to the chain; every balance handed out is a `deal` storage edit.
/// @dev Each scenario is its own test on the shared `setUp`, and `testTheWholeLifecycleWritesItsEvidence` runs them
/// all again, one after another from that same starting state, to write one evidence file (tests of one contract run
/// in parallel, so they cannot share a file). Mandates, grades, the modeled cost, the 2,000 bps ceiling and the
/// 2,500 bps keeper share are fixture values, not launch values. The fork and the clip helpers are S7's. A cold run
/// fetches state for about ninety seconds; `-j 3` keeps it under the public node's rate limit.
contract IntentLifecycleForkTest is IntentMainnetForkBase {
    using PoolIdLibrary for PoolKey;

    string internal constant EVIDENCE = "../docs/intent-v1/evidence/s8-mainnet-fork-lifecycle.json";
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint16 internal constant CAP_BPS = 2000;
    uint32 internal constant COST_BPS = 1000;
    /// @dev Rate grade B: a purchase keeps at least 90% of the modeled cost after its execution fee.
    uint8 internal constant RATE_GRADE_B = 3;
    uint16 internal constant LOW_FEE_BPS = 500;
    uint16 internal constant HIGH_FEE_BPS = 1500;
    uint256 internal constant MAX = type(uint256).max;
    /// @dev Share price with twelve more digits than a raw USDG unit, so steps smaller than a unit still show.
    uint256 internal constant PRICE_SHARES = 1e30;
    /// @dev What a second holder of the 15% vault deposits in the withdrawal scenario: less than the 4,000 USDG lent
    /// there, so the first holder's claim still exceeds what is liquid.
    uint256 internal constant SECOND_HOLDER = 1000e6;

    IntentFactory internal factory;
    IntentQuoteVerifier internal verifier;
    IntentFillRouter internal fills;
    GradeRegistry internal grades;
    IReserveLens internal lens;
    Vm.Wallet internal signer;
    /// @dev The 5% and the 15% vault, and the same two in address order, as a plan needs them.
    IntentVault internal low;
    IntentVault internal high;
    IntentVault internal first;
    IntentVault internal second;
    address internal collateral;
    uint256 internal collateralAmount;

    address internal partner = makeAddr("s8-fork-partner");
    address internal partnerFees = makeAddr("s8-fork-partner-fee-recipient");
    address internal outsider = makeAddr("s8-fork-not-admitted");
    address internal filler = makeAddr("s8-fork-keeper-filler");
    address internal borrower = makeAddr("s8-fork-borrower");
    address internal alice = makeAddr("s8-fork-alice");
    address internal bob = makeAddr("s8-fork-bob");
    address internal carol = makeAddr("s8-fork-carol");
    address internal dave = makeAddr("s8-fork-dave");

    function setUp() public {
        if (!_fork()) return;
        _liveCoreAndReserve();
        _standIntent();
    }

    // ---------------------------------------------------------------- the stack, in the fork VM only

    function _mandate(uint16 feeBps, address[] memory assets) internal view returns (IntentVault.Mandate memory) {
        return IntentVault.Mandate({
            curator: partner,
            categoryWeights: [uint16(10_000), 0, 0, 0],
            assets: assets,
            maxLoanTerm: T21,
            feeBps: feeBps,
            minGrade: 5,
            minRateGrade: RATE_GRADE_B,
            maxLoanPrincipal: 5000e6,
            maxAssetBps: 10_000,
            bufferBps: 0,
            executionCapBps: CAP_BPS
        });
    }

    /// @dev Configured as the published testnet factory is (scripts/intent-s4-partners.mjs): the live core, the live
    /// reserve measured through a `MorphoV2ReserveLens`, a grade registry of its own; then opened as S5 opens it.
    function _standIntent() internal {
        signer = vm.createWallet("s8-fork-quote-signer");
        grades = new GradeRegistry(address(this), address(this));
        lens = new MorphoV2ReserveLens();
        IntentVaultCode store_ = new IntentVaultCode();
        factory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: reserve,
                reserveLens: address(lens),
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
        factory.setCreator(partner, true);
        factory.setFiller(filler, true);
        // D49: the filler's share is locked at zero; the whole execution fee is the processor's.

        ICollateralRegistry.ERC20Config memory config;
        (collateral, config) = _admittedStock();
        // The collateral's value is never read in the deal path; ten times the registry's minimum, or the minimum.
        collateralAmount = config.minAmount * 10 <= config.maxDealRaw ? config.minAmount * 10 : config.minAmount;
        factory.assignCategory(collateral, IntentCategory.STOCK);
        address[] memory tokens = new address[](1);
        uint8[] memory ranks = new uint8[](1);
        uint32[] memory terms = new uint32[](1);
        uint32[] memory costs = new uint32[](1);
        (tokens[0], ranks[0], terms[0], costs[0]) = (collateral, 7, T21, COST_BPS);
        grades.setGrades(tokens, ranks);
        grades.setModeledCosts(tokens, terms, costs);

        vm.startPrank(partner);
        low = IntentVault(factory.create(_mandate(LOW_FEE_BPS, tokens), false, 0, "Test vault"));
        high = IntentVault(factory.create(_mandate(HIGH_FEE_BPS, tokens), false, 0, "Test vault"));
        low.setFeeRecipient(partnerFees);
        high.setFeeRecipient(partnerFees);
        vm.stopPrank();
        (first, second) = address(low) < address(high) ? (low, high) : (high, low);
        vm.label(address(low), "IntentVault-5pct");
        vm.label(address(high), "IntentVault-15pct");

        // Local fork balances only.
        _deposit(low, alice, 5000e6);
        _deposit(low, bob, 5000e6);
        _deposit(high, carol, 30_000e6);
    }

    function _deposit(IntentVault vault, address who, uint256 assets) internal returns (uint256 shares) {
        deal(address(usdg), who, usdg.balanceOf(who) + assets);
        vm.startPrank(who);
        usdg.approve(address(vault), assets);
        shares = vault.deposit(assets, 0);
        vm.stopPrank();
    }

    function _redeem(IntentVault vault, address who, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = vault.redeem(shares, 0);
    }

    function _list(uint128 principal, uint128 cap) internal returns (uint256 id) {
        deal(collateral, borrower, collateralAmount);
        vm.startPrank(borrower);
        IERC20(collateral).approve(address(core), collateralAmount);
        id = core.list(
            Collateral(Kind.ERC20, collateral, collateralAmount),
            principal,
            cap,
            T21,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.stopPrank();
    }

    function _repay(uint256 id) internal {
        uint256 cap = core.getLoan(id).cap;
        deal(address(usdg), borrower, cap);
        vm.startPrank(borrower);
        usdg.approve(address(core), cap);
        core.reclaim(id, borrower);
        vm.stopPrank();
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _maturity(uint256 id) internal view returns (uint256) {
        V2Loan memory l = core.getLoan(id);
        return uint256(l.fundedAt) + l.term;
    }

    // ---------------------------------------------------------------- quotes and allocation

    /// @dev The fee the shared arithmetic gives `units` equal quarters of a listing in a vault at rate grade B.
    function _feeFor(V2Loan memory l, uint8 units) internal pure returns (uint256 fee) {
        if (units == 0) return 0;
        uint256 principal = uint256(l.principal) * units / UNITS;
        uint256 interest = uint256(l.cap - l.principal) * units / UNITS;
        uint256 minimum = IntentFeeMath.minimumInterest(principal, COST_BPS, RATE_GRADE_B);
        (, fee) = IntentFeeMath.executionFee(interest, minimum, CAP_BPS);
    }

    /// @dev S5's allocation rule, as far as chain state decides it, for a listing whose quarters are equal: units go
    /// one at a time to the vault that pays the most for that next unit, then to the lower loan utilization counting
    /// the units already given, then to the lower address. The rule itself is the keeper's
    /// (services/keeper, docs/intent-v1/S5-FILLER-POLICY.md); the chain only ever checks the plan that results.
    function _allocate(uint256 id) internal view returns (uint8 toFirst, uint8 toSecond) {
        V2Loan memory l = core.getLoan(id);
        uint256 unit = l.principal / UNITS;
        for (uint8 u; u < UNITS; ++u) {
            uint256 feeA = _feeFor(l, toFirst + 1) - _feeFor(l, toFirst);
            uint256 feeB = _feeFor(l, toSecond + 1) - _feeFor(l, toSecond);
            bool pickFirst;
            if (feeA != feeB) {
                pickFirst = feeA > feeB;
            } else {
                // (lent + given) / assets, compared exactly by cross-multiplication.
                uint256 a = (first.performingPrincipal() + unit * toFirst) * second.totalAssets();
                uint256 b = (second.performingPrincipal() + unit * toSecond) * first.totalAssets();
                pickFirst = a <= b;
            }
            if (pickFirst) ++toFirst;
            else ++toSecond;
        }
    }

    /// @dev The exact quote an honest signer would produce now: live terms, live empty units, the reference fee.
    function _plan(uint256 id, IntentVault[] memory vaults, uint8[] memory counts)
        internal
        view
        returns (IntentQuoteVerifier.Plan memory p)
    {
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
        p.evidence = keccak256("s8 mainnet fork fixture");
        p.allocations = new IntentQuoteVerifier.Allocation[](vaults.length);
        address[4] memory lenders = core.lenders(id);
        uint8 next;
        for (uint256 i; i < vaults.length; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            a.vault = address(vaults[i]);
            a.units = counts[i];
            uint256 owed;
            for (uint8 left = counts[i]; next < UNITS && left != 0; ++next) {
                if (lenders[next] != address(0)) continue;
                a.principal += uint128(l.principal / UNITS + (next < l.principal % UNITS ? 1 : 0));
                owed += l.cap / UNITS + (next < l.cap % UNITS ? 1 : 0);
                --left;
            }
            a.interest = uint128(owed - a.principal);
            a.minRateGrade = vaults[i].minRateGrade();
            a.capBps = vaults[i].executionCapBps();
            a.managerBps = vaults[i].feeBps();
            a.minimum = uint128(IntentFeeMath.minimumInterest(a.principal, p.costBps, a.minRateGrade));
            (, uint256 fee) = IntentFeeMath.executionFee(a.interest, a.minimum, a.capBps);
            a.executionFee = uint128(fee);
            a.maxReserveShares = uint128(vaults[i].RESERVE().previewWithdraw(uint256(a.principal) + fee));
        }
    }

    function _both(uint8 a, uint8 b) internal view returns (IntentVault[] memory vaults, uint8[] memory counts) {
        vaults = new IntentVault[](2);
        counts = new uint8[](2);
        (vaults[0], vaults[1]) = (first, second);
        (counts[0], counts[1]) = (a, b);
    }

    function _only(IntentVault vault) internal pure returns (IntentVault[] memory vaults, uint8[] memory counts) {
        vaults = new IntentVault[](1);
        counts = new uint8[](1);
        (vaults[0], counts[0]) = (vault, UNITS);
    }

    function _sign(IntentQuoteVerifier.Plan memory p) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, verifier.planHash(p));
        return abi.encodePacked(r, s, v);
    }

    function _limits(uint256 count) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            limits[i] = MAX;
        }
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal {
        bytes memory signature = _sign(p);
        vm.prank(filler);
        fills.fill(p, signature, _limits(p.allocations.length));
    }

    /// @dev A listing activated by both vaults on the allocation rule; returns its plan.
    function _activateBoth(uint128 principal, uint128 cap)
        internal
        returns (uint256 id, IntentQuoteVerifier.Plan memory p)
    {
        id = _list(principal, cap);
        (uint8 a, uint8 b) = _allocate(id);
        (IntentVault[] memory vaults, uint8[] memory counts) = _both(a, b);
        p = _plan(id, vaults, counts);
        _fill(p);
    }

    /// @dev A listing activated by one vault alone.
    function _activateOne(IntentVault vault, uint128 principal, uint128 cap)
        internal
        returns (uint256 id, IntentQuoteVerifier.Plan memory p)
    {
        id = _list(principal, cap);
        (IntentVault[] memory vaults, uint8[] memory counts) = _only(vault);
        p = _plan(id, vaults, counts);
        _fill(p);
    }

    // ---------------------------------------------------------------- what a vault holds, and the policy's identities

    struct Held {
        bool settled;
        bool recovered;
        bool repaid;
        uint64 snapshotId;
        uint128 principal;
        uint128 interest;
        uint128 rate;
        uint128 executionFee;
        bool executionEarned;
    }

    function _held(IntentVault vault, uint256 id) internal view returns (Held memory h) {
        (
            ,,,,,
            h.settled,
            h.recovered,
            h.repaid,
            h.snapshotId,
            h.principal,,
            h.interest,
            h.rate,,
            h.executionFee,
            h.executionEarned
        ) = vault.loans(id);
    }

    function _price(IntentVault vault) internal view returns (uint256) {
        return vault.convertToAssets(PRICE_SHARES);
    }

    function _reserveValue(IntentVault vault) internal view returns (uint256) {
        return IERC4626(reserve).convertToAssets(vault.reserveShares());
    }

    /// @dev The identities of the policy note as D51 left them, at whatever step they are called: priced assets are
    /// cash + reserve + lent principal + accrued interest; the USDG held is exactly the ledgers, earnings claims
    /// included; free liquidity is cash plus what the reserve can pay now; the reserve shares booked are the ones held.
    function _assertIdentities(IntentVault vault) internal view {
        uint256 value = _reserveValue(vault);
        assertEq(
            vault.totalAssets(),
            vault.cash() + value + vault.performingPrincipal() + vault.accruedInterest(),
            "totalAssets = cash + reserve + lent principal + accrued interest"
        );
        assertEq(
            usdg.balanceOf(address(vault)),
            vault.cash() + vault.curatorFees() + vault.protocolFees() + vault.executionPending() + vault.executionFees()
                + vault.unassignedCash() + vault.pocketLiability(address(usdg)),
            "USDG held = the ledgers"
        );
        uint256 liquid = vault.cash() + Math.min(value, lens.withdrawable(reserve, address(vault)));
        assertEq(vault.freeLiquidity(), liquid, "free liquidity is cash and what the reserve can pay");
        assertEq(IERC20(reserve).balanceOf(address(vault)), vault.reserveShares(), "reserve shares held = booked");
    }

    // ---------------------------------------------------------------- 1. partner creation and deposits

    function testAnAdmittedPartnerCreatesTwoVaultsDepositorsEnterAtParAndIdleCashGoesToTheLiveReserve() public {
        _scenarioCreationAndDeposits();
    }

    function _scenarioCreationAndDeposits() internal {
        // Only an admitted partner creates, and only for itself.
        address[] memory tokens = new address[](1);
        tokens[0] = collateral;
        vm.prank(outsider);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        factory.create(_mandate(LOW_FEE_BPS, tokens), false, 0, "Test vault");
        IntentVault.Mandate memory spoof = _mandate(LOW_FEE_BPS, tokens);
        spoof.curator = outsider;
        vm.prank(partner);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        factory.create(spoof, false, 0, "Test vault");

        assertEq(factory.count(), 2);
        assertTrue(factory.isVault(address(low)) && factory.isVault(address(high)));
        assertEq(low.feeBps(), LOW_FEE_BPS);
        assertEq(high.feeBps(), HIGH_FEE_BPS);
        IntentVault[2] memory both = [low, high];
        for (uint256 i; i < 2; ++i) {
            IntentVault v = both[i];
            assertEq(v.CURATOR(), partner);
            assertEq(v.minRateGrade(), RATE_GRADE_B, "B rate floor");
            assertEq(v.executionCapBps(), CAP_BPS, "the ceiling its manager chose");
            assertEq(address(v.RESERVE()), reserve, "the live Morpho reserve");
            assertEq(address(v.RESERVE_LENS()), address(lens), "measured through the lens");
            assertEq(v.CATEGORY_MASK(), 1, "tokenized stocks only");
            // Deposits entered at par: one raw USDG unit is 1e12 shares.
            assertEq(v.totalSupply(), v.totalAssets() * 1e12, "par");
            assertEq(_price(v), 1e18, "share price starts at par");
            _assertIdentities(v);
        }
        assertEq(low.balanceOf(alice), 5000e6 * 1e12);
        assertEq(low.balanceOf(bob), 5000e6 * 1e12);
        assertEq(high.balanceOf(carol), 30_000e6 * 1e12);
        // Deposits have no cap: a further deposit always goes in.
        deal(address(usdg), carol, 1e6);
        vm.startPrank(carol);
        usdg.approve(address(low), 1e6);
        low.deposit(1e6, 0);
        vm.stopPrank();

        // Idle cash reaches the reserve only through the fill router, for an admitted filler; nobody else, not even
        // the partner, can push it there. The live reserve's own max views say zero and it still takes the deposit.
        vm.prank(partner);
        vm.expectRevert(IntentVault.NotCurator.selector);
        high.investReserve(20_000e6, 0);
        vm.prank(outsider);
        vm.expectRevert(IntentFillRouter.NotFiller.selector);
        fills.investReserve(address(high), 20_000e6, 0);
        assertEq(IERC4626(reserve).maxDeposit(address(high)), 0, "zero by design");
        uint256 assetsBefore = high.totalAssets();
        vm.prank(filler);
        uint256 shares = fills.investReserve(address(high), 20_000e6, 0);
        assertEq(high.reserveShares(), shares);
        assertEq(high.cash(), 10_000e6);
        assertApproxEqAbs(high.totalAssets(), assetsBefore, 2, "the reserve is priced at its own conversion");
        assertLe(high.totalAssets(), assetsBefore, "rounded against the vault, never for it");
        assertEq(IERC4626(reserve).maxWithdraw(address(high)), 0, "zero by design");
        assertGe(lens.withdrawable(reserve, address(high)), 20_000e6 - 2, "the lens measures what it can pay");
        assertApproxEqAbs(high.freeLiquidity(), 30_000e6, 2);
        _assertIdentities(high);

        string memory o = "s1";
        vm.serializeAddress(o, "vault5pct", address(low));
        vm.serializeAddress(o, "vault15pct", address(high));
        vm.serializeString(o, "notAdmittedCreator", "CreationClosed()");
        vm.serializeString(o, "curatorSpoof", "CreationClosed()");
        _n(o, "rateGradeFloor", RATE_GRADE_B);
        _n(o, "executionCapBps", CAP_BPS);
        _n(o, "deposits5pct", 10_000e6);
        _n(o, "deposits15pct", 30_000e6);
        _n(o, "sharePriceAtEntry1e18", 1e18);
        vm.serializeString(
            o,
            "investReserve",
            "only IntentFillRouter.investReserve by an admitted filler; partner: NotCurator(), outsider: NotFiller()"
        );
        _n(o, "investedIntoLiveReserve", 20_000e6);
        _n(o, "reserveSharesReceived", shares);
        _n(o, "totalAssetsBeforeInvest", assetsBefore);
        _n(o, "totalAssetsAfterInvest", high.totalAssets());
        _n(o, "lensWithdrawable", lens.withdrawable(reserve, address(high)));
        _n(o, "freeLiquidityAfterInvest", high.freeLiquidity());
        _n(o, "sharePriceAfterInvest1e18", _price(high));
    }

    // ---------------------------------------------------------------- 2. quote, allocation, atomic activation, rollback

    function testBothVaultsActivateOneListingAtomicallyAndAFailedFillRollsEverythingBack() public {
        _scenarioAtomicFillAndRollback();
    }

    function _vaultsSnapshot(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                core.getLoan(id).filled,
                core.getLoan(id).state,
                core.lenders(id),
                first.totalAssets(),
                first.cash(),
                first.performingPrincipal(),
                first.executionPending(),
                first.executionFees(),
                usdg.balanceOf(address(first)),
                second.totalAssets(),
                second.cash(),
                second.performingPrincipal(),
                second.executionPending(),
                second.executionFees(),
                usdg.balanceOf(address(second)),
                usdg.balanceOf(address(fills)),
                fills.totalOwed(),
                fills.owed(address(processor))
            )
        );
    }

    function _scenarioAtomicFillAndRollback() internal {
        uint256 id = _list(1000e6, 1100e6);
        (uint8 a, uint8 b) = _allocate(id);
        assertEq(a + b, UNITS);
        // Equal floors and ceilings pay the same per unit whatever the manager's fee, so utilization decides: the
        // vault with 30,000 USDG takes three quarters, the one with 10,000 takes one.
        assertEq(address(first) == address(low) ? a : b, 1, "the smaller vault's share");
        (IntentVault[] memory vaults, uint8[] memory counts) = _both(a, b);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        IntentQuoteVerifier.Refusal reason = IntentPreflight.reason(verifier, p, _sign(p), filler);
        assertEq(uint8(reason), uint8(IntentQuoteVerifier.Refusal.NONE), "the exact quote is accepted");

        uint256[2] memory assetsBefore = [first.totalAssets(), second.totalAssets()];
        uint256 creditBefore = core.cashCredit(borrower);
        _fill(p);
        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active on the live core");
        assertEq(l.fundedAt, block.timestamp, "in this transaction");
        assertEq(core.cashCredit(borrower) - creditBefore, l.principal - l.originationFee, "the borrower's credit");
        uint256 fee;
        string memory o = "s2";
        for (uint256 i; i < 2; ++i) {
            IntentQuoteVerifier.Allocation memory q = p.allocations[i];
            Held memory h = _held(vaults[i], id);
            assertEq(core.unitsOf(id, address(vaults[i])), q.units, "lender units on the core");
            assertEq(vaults[i].performingPrincipal(), q.principal, "principal out");
            assertEq(h.principal, q.principal);
            assertEq(h.executionFee, q.executionFee);
            assertTrue(h.executionEarned, "earned at the common activation");
            assertGt(h.rate, 0, "accruing from the activation");
            assertEq(vaults[i].executionPending() + vaults[i].executionFees(), 0, "handed to the router");
            assertEq(assetsBefore[i] - vaults[i].totalAssets(), q.executionFee, "expensed once, at the purchase");
            // What the loan earns = execution fee + performance fee + the depositors' part, to the unit.
            (bool ok, IntentFeeBreakdown.Breakdown memory d) =
                IntentFeeBreakdown.breakdown(q.interest, q.minimum, q.capBps, q.managerBps);
            assertTrue(ok);
            assertEq(d.executionFee, q.executionFee);
            assertEq(d.executionFee + d.performanceFee + d.depositorInterest, q.interest, "fee identity");
            assertEq(h.interest, q.interest - d.performanceFee, "the vault accrues the cost less the manager fee");
            assertGe(q.interest - q.executionFee, q.minimum, "the B floor survives the execution fee");
            fee += q.executionFee;
            _assertIdentities(vaults[i]);
            string memory v = i == 0 ? "s2first" : "s2second";
            vm.serializeAddress(v, "vault", q.vault);
            _n(v, "managerFeeBps", q.managerBps);
            _n(v, "units", q.units);
            _n(v, "principal", q.principal);
            _n(v, "interest", q.interest);
            _n(v, "minimumKept", q.minimum);
            _n(v, "executionFee", d.executionFee);
            _n(v, "performanceFee", d.performanceFee);
            _n(v, "protocolShareOfPerformanceFee", d.protocolPerformanceFee);
            _n(v, "depositorInterest", d.depositorInterest);
            _n(v, "totalAssetsBefore", assetsBefore[i]);
            vm.serializeString(
                o, i == 0 ? "firstVault" : "secondVault", _n(v, "totalAssetsAfter", vaults[i].totalAssets())
            );
        }
        assertEq(
            p.allocations[0].executionFee * p.allocations[1].units,
            p.allocations[1].executionFee * p.allocations[0].units
        );
        assertEq(fills.owed(address(processor)), fee, "owed per the plan, both of Gage's portions");
        assertEq(usdg.balanceOf(address(fills)), fee);
        assertTrue(verifier.consumed(verifier.planHash(p)));
        _n(o, "listingId", id);
        _n(o, "principal", l.principal);
        _n(o, "cap", l.cap);
        _n(o, "coreOriginationFee", l.originationFee);
        _n(o, "executionFeeOwedToDealFeeRouter", fee);

        // The rollback: the same kind of fill with the last vault paused, then short of liquidity.
        uint256 again = _list(1000e6, 1100e6);
        (a, b) = _allocate(again);
        (vaults, counts) = _both(a, b);
        IntentQuoteVerifier.Plan memory r = _plan(again, vaults, counts);
        bytes memory signature = _sign(r);
        bytes32 digest = verifier.planHash(r);
        bytes32 before_ = _vaultsSnapshot(again);
        vm.prank(partner);
        second.setPaused(true);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.BUYER_UNAVAILABLE)
        );
        fills.fill(r, signature, _limits(2));
        vm.prank(partner);
        second.setPaused(false);
        assertEq(_vaultsSnapshot(again), before_, "paused: nothing kept");
        assertFalse(verifier.consumed(digest), "the plan is not used up");
        // Its partner now keeps 99% of assets liquid, so it cannot pay for its units: the first vault's purchase,
        // already made in the same call, is rolled back with it.
        uint256 state = vm.snapshotState();
        IntentLimits.setLimits(second, 5000e6, 10_000, 9900);
        vm.prank(filler);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        fills.fill(r, signature, _limits(2));
        assertEq(_vaultsSnapshot(again), before_, "illiquid: nothing kept");
        assertFalse(verifier.consumed(digest));
        assertEq(_held(first, again).principal, 0, "no vault holds part of a listing that did not activate");
        assertEq(uint8(core.getLoan(again).state), uint8(V2State.FUNDING));
        // The very same signed plan completes once the vault can pay, and only once. Lowering the buffer again would
        // wait three hours (D53), past the plan's life: the state before raising it is restored.
        vm.revertToState(state);
        vm.prank(filler);
        fills.fill(r, signature, _limits(2));
        assertEq(uint8(core.getLoan(again).state), uint8(V2State.ACTIVE));
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.CONSUMED)
        );
        fills.fill(r, signature, _limits(2));
        vm.serializeString(
            o,
            "rollbackPaused",
            "Refused(BUYER_UNAVAILABLE): both vaults, the listing, the router and the plan's single-use flag unchanged"
        );
        vm.serializeString(
            o,
            "rollbackIlliquid",
            "InsufficientLiquidity(): the first vault's purchase made in the same call was rolled back"
        );
        vm.serializeString(o, "samePlanAfterwards", "filled once; a replay is Refused(CONSUMED)");
    }

    // ---------------------------------------------------------------- 3. early repayment and D29

    function testAnEarlyRepaymentKeepsItsScheduleHoldsUnearnedCashAndPaysTheHoldersWhoStay() public {
        _scenarioEarlyRepayment();
    }

    uint256 internal _lastPrice;

    /// @dev Identities hold and the share price has not fallen since the last step.
    function _step(IntentVault vault) internal {
        _assertIdentities(vault);
        uint256 price = _price(vault);
        assertGe(price, _lastPrice, "share price never falls");
        _lastPrice = price;
    }

    function _scenarioEarlyRepayment() internal {
        string memory o = "s3";
        uint256 parPrice = _price(low);
        (uint256 id, IntentQuoteVerifier.Plan memory p) = _activateOne(low, 1000e6, 1100e6);
        uint256 start = core.getLoan(id).fundedAt;
        uint256 fee = p.allocations[0].executionFee;
        uint256 performance = IntentFeeMath.performanceFee(100e6, fee, LOW_FEE_BPS);
        uint256 net = 100e6 - performance;
        // The one documented step down: the execution fee is an expense of the purchase (policy note, section 9).
        assertEq(low.totalAssets(), 10_000e6 - fee);
        assertLt(_price(low), parPrice, "the execution fee leaves priced assets at the purchase, once");
        _n(o, "sharePriceAtPar1e18", parPrice);
        _n(o, "sharePriceAfterFill1e18", _price(low));
        _lastPrice = _price(low);
        _step(low);

        // Day 3: the borrower repays on the live core. Nothing is booked yet; the loan's clock runs on in the price.
        vm.warp(start + 3 days);
        _step(low);
        uint256 earned = low.accruedInterest();
        assertEq(earned, net * 3 days / T21, "three days of the net interest");
        _repay(id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID));
        _step(low);
        uint256 assetsBefore = low.totalAssets();
        low.settle(_ids(id));
        assertLe(assetsBefore - low.totalAssets(), 1, "the booking moves priced assets by at most a unit, down");
        _step(low);
        Held memory h = _held(low, id);
        assertTrue(h.repaid && h.settled, "booked, settled, and its earnings claim opened (D51)");
        assertEq(low.performingPrincipal(), 0, "the principal is no longer lent");
        uint256 claim = low.pocketLiability(address(usdg));
        assertEq(claim, net - earned, "what the clock had not counted is the claim");
        assertEq(low.curatorFees() + low.protocolFees(), performance, "the manager fee is charged once, at the booking");
        assertEq(low.cash(), 10_000e6 - fee - 1000e6 + 1100e6 - performance - claim);
        assertEq(low.freeLiquidity(), low.cash(), "the claim is outside cash, and everything priced stays liquid");
        assertEq(low.earliestMaturity(), type(uint40).max, "no pause waits at the original maturity");
        _n(o, "listingId", id);
        _n(o, "executionFee", fee);
        _n(o, "performanceFee", performance);
        _n(o, "netInterest", net);
        _n(o, "earnedAtRepaymentDay3", earned);
        _n(o, "earningsClaim", claim);
        _n(o, "totalAssetsBeforeBooking", assetsBefore);
        _n(o, "totalAssetsAfterBooking", low.totalAssets());
        _n(o, "cashAfterBooking", low.cash());
        _n(o, "freeLiquidityAfterBooking", low.freeLiquidity());
        _n(o, "sharePriceAtBooking1e18", _price(low));

        // The claim is not cash: a fill that would need it is refused.
        uint256 big = _list(5000e6, 5500e6);
        uint256 state = vm.snapshotState();
        IntentLimits.setLimits(low, 5000e6, 10_000, 9000);
        (IntentVault[] memory vaults, uint8[] memory counts) = _only(low);
        IntentQuoteVerifier.Plan memory q = _plan(big, vaults, counts);
        bytes memory signature = _sign(q);
        vm.prank(filler);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        fills.fill(q, signature, _limits(1));
        // Lowering the buffer again would wait three hours (D53): the state before raising it is restored.
        vm.revertToState(state);

        // Bob leaves on day 3 and keeps his half of the loan's whole return: the price part now, the claim when he
        // likes (D51, in place of D29's forfeit).
        uint256 bobOut = _redeem(low, bob, low.balanceOf(bob));
        assertApproxEqAbs(bobOut, 5000e6 - fee / 2 + earned / 2, 1, "half of what the price had counted");
        vm.prank(bob);
        bobOut += low.claimPocket(1);
        assertApproxEqAbs(bobOut, 5000e6 - fee / 2 + net / 2, 2, "half of the loan's whole return");
        assertEq(low.pocketLiability(address(usdg)), claim - (bobOut - (5000e6 - fee / 2 + earned / 2)));
        _step(low);
        _n(o, "leaverOutDay3", bobOut);
        uint256 afterBob = vm.snapshotState();

        // A. The stayer holds to the end of the term: no pause there, and she leaves with exactly the leaver's share.
        vm.warp(start + T21);
        low.settle(_ids(id));
        _step(low);
        _n(o, "sharePriceAtTermEnd1e18", _price(low));
        uint256 aliceOut = _redeem(low, alice, low.balanceOf(alice));
        vm.prank(alice);
        aliceOut += low.claimPocket(1);
        assertApproxEqAbs(aliceOut + bobOut + performance + fee, 10_000e6 + 100e6, 3, "nothing is lost between them");
        assertApproxEqAbs(aliceOut, bobOut, 3, "staying and leaving after the repayment are worth the same");
        assertEq(low.totalSupply(), 0);
        _n(o, "stayerOutAtTermEnd", aliceOut);

        // B. The last holder leaves on day 10 instead: her claim stays hers, and the next depositor finds nothing.
        vm.revertToState(afterBob);
        vm.warp(start + 10 days);
        _lastPrice = _price(low);
        uint256 lastOut = _redeem(low, alice, low.balanceOf(alice));
        assertEq(low.totalSupply(), 0);
        assertTrue(_held(low, id).settled);
        vm.prank(alice);
        lastOut += low.claimPocket(1);
        assertApproxEqAbs(lastOut + bobOut + performance + fee, 10_000e6 + 100e6, 3);
        assertLe(low.totalAssets(), 2, "only rounding is left behind");
        uint256 carolShares = _deposit(low, carol, 1000e6);
        assertLe(_redeem(low, carol, carolShares), 1000e6, "no windfall for the next depositor");
        assertEq(low.pocketClaimable(1, carol), 0);
        _assertIdentities(low);
        _n(o, "lastHolderOutDay10", lastOut);
        _n(o, "leftBehindAfterLastHolder", low.totalAssets());
    }

    // ---------------------------------------------------------------- 4. on-time repayment and the fee split

    function testARepaymentJustBeforeMaturityPaysBothVaultsAndTheProtocolShareReachesTheLiveProcessor() public {
        _scenarioOnTimeRepayment();
    }

    function _scenarioOnTimeRepayment() internal {
        string memory o = "s4";
        (uint256 id, IntentQuoteVerifier.Plan memory p) = _activateBoth(1000e6, 1100e6);
        uint256 end = _maturity(id);
        vm.warp(end - 1 hours);
        _repay(id);
        // Nobody settles before the term ends: from that second pricing pauses until the outcome is booked.
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        low.redeem(1e18, 0);
        uint256 curatorTotal;
        uint256 protocolTotal;
        IntentVault[2] memory vaults = [first, second];
        for (uint256 i; i < 2; ++i) {
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            IntentVault v = vaults[i];
            uint256 deposits = v == low ? 10_000e6 : 30_000e6;
            v.settle(_ids(id));
            Held memory h = _held(v, id);
            assertTrue(h.settled && !h.repaid, "a repayment booked after the term is recognized at once");
            uint256 performance = IntentFeeMath.performanceFee(a.interest, a.executionFee, a.managerBps);
            uint256 protocolPart = performance * IntentFeeMath.PROTOCOL_SHARE_BPS / IntentFeeMath.BPS;
            assertEq(v.protocolFees(), protocolPart, "10% of the manager fee");
            assertEq(v.curatorFees(), performance - protocolPart);
            // R3's identity, to the unit: deposits + what the loan earned = assets + execution fee + manager fee.
            assertEq(v.totalAssets() + a.executionFee + performance, deposits + a.interest, "value identity");
            assertEq(v.pocketLiability(address(usdg)) + v.performingPrincipal(), 0);
            _assertIdentities(v);
            curatorTotal += performance - protocolPart;
            protocolTotal += protocolPart;
            string memory k = i == 0 ? "s4first" : "s4second";
            vm.serializeAddress(k, "vault", address(v));
            _n(k, "interestReceived", a.interest);
            _n(k, "executionFee", a.executionFee);
            _n(k, "performanceFee", performance);
            _n(k, "managerPart", performance - protocolPart);
            _n(k, "protocolPart", protocolPart);
            _n(k, "totalAssetsAfter", v.totalAssets());
            vm.serializeString(o, i == 0 ? "firstVault" : "secondVault", _n(k, "sharePriceAfter1e18", _price(v)));
        }
        // Anyone claims: the manager's part to its recipient, the protocol's part, in USDG, to the live processor.
        uint256 available = processor.availableUSDG();
        uint256 held = usdg.balanceOf(address(processor));
        vm.startPrank(anyone);
        first.claimFees();
        second.claimFees();
        vm.stopPrank();
        assertEq(usdg.balanceOf(partnerFees), curatorTotal, "the manager's part");
        assertEq(usdg.balanceOf(address(processor)) - held, protocolTotal, "the protocol's part, as plain USDG");
        assertEq(processor.availableUSDG() - available, protocolTotal, "availableUSDG rose by exactly that");
        assertEq(first.protocolFees() + first.curatorFees() + second.protocolFees() + second.curatorFees(), 0);
        _n(o, "listingId", id);
        _n(o, "repaidSecondsBeforeMaturity", 1 hours);
        _n(o, "managerFeesPaid", curatorTotal);
        _n(o, "protocolFeesToDealFeeRouter", protocolTotal);
        _n(o, "availableUSDGBeforeClaimFees", available);
        _n(o, "availableUSDGAfterClaimFees", processor.availableUSDG());
    }

    // ---------------------------------------------------------------- 5. default and recovery

    function testADefaultIsWrittenOffAtTermEndAndTheCollateralGoesInKindToTheHoldersOfRecord() public {
        _scenarioDefaultAndRecovery();
    }

    function _scenarioDefaultAndRecovery() internal {
        string memory o = "s5";
        (uint256 id, IntentQuoteVerifier.Plan memory p) = _activateBoth(1000e6, 1100e6);
        uint256 end = _maturity(id);
        // The zero-grace core: the second the term ends repayment is closed and the default can be finalized.
        vm.warp(end);
        deal(address(usdg), borrower, 1100e6);
        vm.startPrank(borrower);
        usdg.approve(address(core), 1100e6);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        core.reclaim(id, borrower);
        vm.stopPrank();

        IntentVault[2] memory vaults = [first, second];
        uint256 recoveredTotal;
        for (uint256 i; i < 2; ++i) {
            IntentVault v = vaults[i];
            IntentQuoteVerifier.Allocation memory a = p.allocations[i];
            address holder = v == low ? alice : carol;
            // Pricing is paused only while the past-term loan is unsettled, and only in the vault that holds it.
            vm.prank(holder);
            vm.expectRevert(IntentVault.SettlementDue.selector);
            v.redeem(1e18, 0);
            // `settle` finalizes the default on the live core itself (the first vault to arrive does) and writes the
            // loan off in full: its principal and every unit of interest it had accrued. The execution fee stays an
            // incurred cost, and no manager fee is made from a return that never arrived.
            uint256 accrued = v.accruedInterest();
            uint256 atEnd = v.totalAssets();
            // The per-second rate rounds down, so a whole term accrues the net interest less at most one raw unit.
            assertApproxEqAbs(accrued, _held(v, id).interest, 1, "the net interest had accrued by the end of the term");
            assertLe(accrued, _held(v, id).interest);
            v.settle(_ids(id));
            assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED));
            Held memory h = _held(v, id);
            assertTrue(h.settled && h.snapshotId != 0, "written off, holders of record snapshotted");
            assertEq(v.totalAssets(), atEnd - a.principal - accrued, "principal and accrued interest, in full");
            assertEq(v.curatorFees() + v.protocolFees(), 0, "no manager fee on a loss");
            assertEq(v.performingPrincipal(), 0);
            assertEq(v.earliestMaturity(), type(uint40).max, "pricing resumes once it is booked");
            _assertIdentities(v);

            // `recover` takes this vault's part of the collateral IN KIND from the live core into a side pocket for
            // the holders of record at the write-off. Nothing is sold and nothing returns to priced assets.
            uint256 assets = v.totalAssets();
            vm.prank(anyone);
            v.recover(id);
            uint256 part = _collateralShare(id, address(v));
            (uint256 loanId, address token, uint256 amount, uint256 supply,,) = v.pockets(1);
            assertEq(loanId, id);
            assertEq(token, collateral);
            assertEq(amount, part, "its lender units' share of the collateral");
            assertEq(supply, v.totalSupply(), "the supply of record");
            assertEq(IERC20(collateral).balanceOf(address(v)), part);
            assertEq(v.totalAssets(), assets, "recovered collateral is not priced");
            vm.expectRevert(IntentVault.NothingToRecover.selector);
            v.recover(id);
            recoveredTotal += part;
            string memory k = i == 0 ? "s5first" : "s5second";
            vm.serializeAddress(k, "vault", address(v));
            _n(k, "units", a.units);
            _n(k, "principalWrittenOff", a.principal);
            _n(k, "accruedInterestWrittenOff", accrued);
            _n(k, "executionFeeKeptAsCost", a.executionFee);
            _n(k, "totalAssetsAtTermEnd", atEnd);
            _n(k, "totalAssetsAfterWriteOff", assets);
            _n(k, "sharePriceAfterWriteOff1e18", _price(v));
            vm.serializeString(o, i == 0 ? "firstVault" : "secondVault", _n(k, "collateralRecoveredInKind", part));
        }
        assertEq(recoveredTotal, collateralAmount, "every unit of collateral reached a vault");

        // Holders of record claim the collateral token itself; a later entrant has no part in it.
        uint256 lateShares = _deposit(low, carol, 1000e6);
        assertEq(low.pocketClaimable(1, carol), 0, "not a holder of record");
        uint256 lowPart = _collateralShare(id, address(low));
        vm.prank(alice);
        uint256 aliceGot = low.claimPocket(1);
        vm.prank(bob);
        uint256 bobGot = low.claimPocket(1);
        assertEq(aliceGot, bobGot, "equal holders of record");
        assertApproxEqAbs(aliceGot + bobGot, lowPart, 1);
        assertEq(IERC20(collateral).balanceOf(alice), aliceGot, "paid in the collateral token");
        vm.prank(carol);
        uint256 carolGot = high.claimPocket(1);
        assertEq(carolGot, collateralAmount - lowPart, "the sole holder of record takes the whole pocket");
        // Redemptions after the default pay the written-down price, in USDG.
        uint256 aliceOut = _redeem(low, alice, low.balanceOf(alice));
        uint256 bobOut = _redeem(low, bob, low.balanceOf(bob));
        uint256 lowFee = (first == low ? p.allocations[0] : p.allocations[1]).executionFee;
        uint256 lowPrincipal = (first == low ? p.allocations[0] : p.allocations[1]).principal;
        assertApproxEqAbs(aliceOut + bobOut, 10_000e6 - lowPrincipal - lowFee, 2, "deposits less the loss and the fee");
        assertLe(_redeem(low, carol, lateShares), 1000e6);
        _n(o, "listingId", id);
        _n(o, "collateralAmount", collateralAmount);
        _n(o, "collateralClaimedByHolder5pctEach", aliceGot);
        _n(o, "collateralClaimedByHolder15pct", carolGot);
        _n(o, "usdgRedeemedAfterDefault5pct", aliceOut + bobOut);
        vm.serializeString(
            o,
            "whatTheVaultDoes",
            "settle() at or after term end calls the core's finalizeDefault (zero grace) and writes off the vault's principal plus all accrued interest at once; the execution fee stays a paid cost and no manager fee is charged. recover() calls the core's recoverDefault and withdrawRecovery for the vault's lender units and holds the collateral token itself in a side pocket; holders of record at the write-off claim it pro rata with claimPocket(). The vault never sells collateral and recovered collateral never re-enters totalAssets. Deposits and redemptions revert SettlementDue() from term end until the vault's own settle()."
        );
    }

    /// @dev The core's own split of recovered collateral: a quarter per lender unit, the first units taking the
    /// remainder one raw unit each.
    function _collateralShare(uint256 id, address lender) internal view returns (uint256 amount) {
        address[4] memory lenders = core.lenders(id);
        for (uint8 i; i < UNITS; ++i) {
            if (lenders[i] == lender) amount += collateralAmount / UNITS + (i < collateralAmount % UNITS ? 1 : 0);
        }
    }

    // ---------------------------------------------------------------- 6. withdrawals

    function testARedemptionIsPaidFromCashThenTheLiveReserveUpToFreeLiquidityAndNeverQueued() public {
        _scenarioWithdrawals();
    }

    function _scenarioWithdrawals() internal {
        string memory o = "s6";
        vm.prank(filler);
        fills.investReserve(address(high), 20_000e6, 0);
        (uint256 id,) = _activateOne(high, 4000e6, 4400e6);
        _assertIdentities(high);
        uint256 shares = high.balanceOf(carol);
        // The last holder cannot burn the whole supply while a loan is still lent out, whatever is liquid: that
        // check comes before the liquidity check (S2 policy note, rule 8; IntentVault.sol:622).
        assertEq(shares, high.totalSupply(), "she is the vault's only holder");
        vm.prank(carol);
        vm.expectRevert(IntentVault.OutstandingLoans.selector);
        high.redeem(shares, 0);
        assertEq(high.balanceOf(carol), shares);
        // A second holder enters, so her whole balance is no longer the whole supply and liquidity alone decides.
        uint256 daveShares = _deposit(high, dave, SECOND_HOLDER);
        assertLt(shares, high.totalSupply());
        uint256 free = high.freeLiquidity();
        uint256 claim = high.convertToAssets(shares);
        assertGt(claim, free, "her claim is larger than what is liquid: 4,000 USDG is lent out");
        // No queue and no partial payment: a request above free liquidity reverts, and the shares stay hers.
        vm.prank(carol);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        high.redeem(shares, 0);
        uint256 tooMany = high.convertToShares(free + 1e6);
        vm.prank(carol);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        high.redeem(tooMany, 0);
        assertEq(high.balanceOf(carol), shares);

        // A request inside free liquidity is paid at once: all the cash, then a withdrawal from the live reserve.
        uint256 part = high.convertToShares(free - 1e6);
        uint256 expected = high.convertToAssets(part);
        uint256 cash = high.cash();
        assertGt(expected, cash, "more than the cash: the reserve must pay the rest");
        vm.prank(carol);
        vm.expectRevert(IntentVault.Slippage.selector);
        high.redeem(part, expected + 1);
        uint256 reserveShares = high.reserveShares();
        uint256 reserveHeld = usdg.balanceOf(reserve);
        uint256 balance = usdg.balanceOf(carol);
        uint256 price = _price(high);
        vm.prank(carol);
        uint256 out = high.redeem(part, expected);
        assertEq(out, expected, "exactly the quoted amount");
        assertEq(usdg.balanceOf(carol) - balance, out);
        assertEq(high.cash(), 0, "cash first");
        assertLt(high.reserveShares(), reserveShares, "then the reserve");
        assertGe(_price(high), price, "an exit never lowers the price for those who stay");
        _assertIdentities(high);
        // What is left liquid is about one USDG; the loan's share of her claim stays as shares until it is repaid.
        assertApproxEqAbs(high.freeLiquidity(), 1e6, 3);
        uint256 rest = high.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        high.redeem(rest, 0);
        assertEq(high.balanceOf(carol), rest);
        assertEq(high.balanceOf(dave), daveShares, "the second holder's shares are untouched");
        // A deposit's slippage bound is honoured the same way.
        deal(address(usdg), bob, 100e6);
        vm.startPrank(bob);
        usdg.approve(address(high), 100e6);
        uint256 quoted = high.convertToShares(100e6);
        vm.expectRevert(IntentVault.Slippage.selector);
        high.deposit(100e6, quoted + 1);
        vm.stopPrank();
        _n(o, "listingId", id);
        _n(o, "lentOut", 4000e6);
        vm.serializeString(
            o,
            "lastHolderWholeSupply",
            "OutstandingLoans(): the only holder cannot burn the whole supply while a loan is lent out; shares kept"
        );
        _n(o, "secondHolderDeposit", SECOND_HOLDER);
        _n(o, "holderClaim", claim);
        _n(o, "freeLiquidityBefore", free);
        vm.serializeString(
            o, "aboveFreeLiquidity", "InsufficientLiquidity(): no queue, no partial payment, shares kept"
        );
        vm.serializeString(o, "minAssetsAboveQuote", "Slippage()");
        _n(o, "redeemedAtOnce", out);
        _n(o, "paidFromCash", cash);
        _n(o, "paidFromLiveReserve", out - cash);
        _n(o, "reserveSharesBurned", reserveShares - high.reserveShares());
        _n(
            o,
            "reserveUSDGBalanceChange",
            reserveHeld > usdg.balanceOf(reserve) ? reserveHeld - usdg.balanceOf(reserve) : 0
        );
        _n(o, "freeLiquidityAfter", high.freeLiquidity());
        _n(o, "sharePriceBefore1e18", price);
        _n(o, "sharePriceAfter1e18", _price(high));
    }

    // ---------------------------------------------------------------- 7. LP-backed investment is refused (R6-A9)

    function testAPositionBackedListingIsRefusedAtTheVerifierAtTheRouterAndAtTheVault() public {
        _scenarioPositionRefused();
    }

    /// @dev A real Uniswap v4 position in a pool the live registry admits, minted in the fork VM from the stock token
    /// alone (a range wholly under the price holds only currency1), then listed on the live core. External so the
    /// scenario can fall back, and say so, if the live pool's hook or the registry refuses it.
    function listRealPosition() external returns (uint256 id, uint256 tokenId, bytes32 poolId) {
        require(msg.sender == address(this));
        PoolKey memory key;
        bool found;
        for (uint256 i; vm.keyExistsJson(manifest, string.concat(".nativeV2.pools[", vm.toString(i), "]")); ++i) {
            string memory at = string.concat(".nativeV2.pools[", vm.toString(i), "]");
            key = PoolKey({
                currency0: Currency.wrap(vm.parseJsonAddress(manifest, string.concat(at, ".currency0"))),
                currency1: Currency.wrap(vm.parseJsonAddress(manifest, string.concat(at, ".currency1"))),
                fee: uint24(vm.parseJsonUint(manifest, string.concat(at, ".fee"))),
                tickSpacing: int24(int256(vm.parseJsonUint(manifest, string.concat(at, ".tickSpacing")))),
                hooks: IHooks(vm.parseJsonAddress(manifest, string.concat(at, ".hooks")))
            });
            poolId = PoolId.unwrap(key.toId());
            ICollateralRegistry registry = ICollateralRegistry(address(core.REGISTRY()));
            if (
                registry.getPoolConfig(poolId).allowed
                    && registry.getERC20Config(Currency.unwrap(key.currency1)).allowed
            ) {
                found = true;
                break;
            }
        }
        require(found, "no admitted pool with an admitted currency1");
        address token = Currency.unwrap(key.currency1);
        (uint160 sqrtPrice, int24 tick,,) = StateLibrary.getSlot0(IPoolManager(poolManager), key.toId());
        require(sqrtPrice != 0, "pool not initialized");
        int24 upper = tick / key.tickSpacing * key.tickSpacing;
        if (upper > tick) upper -= key.tickSpacing;
        int24 lower = upper - 100 * key.tickSpacing;
        uint256 amount = ICollateralRegistry(address(core.REGISTRY())).getERC20Config(token).minAmount;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount
        );
        deal(token, borrower, amount);
        tokenId = posm.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, borrower, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.startPrank(borrower);
        IERC20(token).approve(PERMIT2, amount);
        IAllowanceTransfer(PERMIT2).approve(token, address(posm), type(uint160).max, type(uint48).max);
        posm.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
        IERC721(address(posm)).approve(address(core), tokenId);
        id = core.list(
            Collateral(Kind.UNIV4_POSITION, address(posm), tokenId),
            1000e6,
            1100e6,
            T21,
            uint40(block.timestamp + 1 days),
            false
        );
        vm.stopPrank();
    }

    function _scenarioPositionRefused() internal {
        string memory o = "s7";
        uint256 id;
        bool real;
        try this.listRealPosition() returns (uint256 listed, uint256 tokenId, bytes32 poolId) {
            (id, real) = (listed, true);
            assertEq(uint8(core.getLoan(id).kind), uint8(Kind.UNIV4_POSITION), "a real position-backed listing");
            assertEq(core.getLoan(id).token, address(posm));
            _n(o, "positionTokenId", tokenId);
            vm.serializeBytes32(o, "positionPoolId", poolId);
            vm.serializeString(
                o, "listing", "a real Uniswap v4 position minted in the fork VM and listed on the live core"
            );
        } catch (bytes memory reason) {
            // The live pool or registry refused the fixture position: the same listing, with the core's own answer
            // about its kind replaced, is the closest state that can be built. Recorded as such.
            vm.stopPrank();
            id = _list(1000e6, 1100e6);
            V2Loan memory l = core.getLoan(id);
            l.kind = Kind.UNIV4_POSITION;
            vm.mockCall(address(core), abi.encodeWithSelector(core.getLoan.selector, id), abi.encode(l));
            vm.serializeBytes(o, "realPositionListingFailedWith", reason);
            vm.serializeString(
                o, "listing", "MOCKED: a real ERC-20 listing whose getLoan kind is reported as UNIV4_POSITION"
            );
        }
        (IntentVault[] memory vaults, uint8[] memory counts) = _only(low);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(p.kind, uint8(Kind.UNIV4_POSITION));
        bytes memory signature = _sign(p);
        bytes32 before_ = _vaultsSnapshot(id);
        // The plan is honestly signed and describes the listing exactly, kind included, so the verifier passes it:
        // the kind is the core's, and the vault refuses a position by itself.
        IntentQuoteVerifier.Refusal reason_ = IntentPreflight.reason(verifier, p, signature, filler);
        assertEq(uint8(reason_), uint8(IntentQuoteVerifier.Refusal.NONE));
        // So the router cannot fund it: the vault's purchase reverts, and the plan's use with it.
        vm.prank(filler);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        fills.fill(p, signature, _limits(1));
        // And the vault refuses it by itself, even when its own router asks, whoever signed what.
        vm.prank(address(fills));
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        low.purchase(id, UNITS, 0, MAX, 0);
        // Nobody else reaches `fund` at all: not the partner, not the filler, not the signer.
        address[3] memory others = [partner, filler, signer.addr];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(IntentVault.NotCurator.selector);
            low.purchase(id, UNITS, 0, MAX, 0);
        }
        // The position cannot be picked into a mandate either: it is not an admitted token of any category.
        vm.prank(partner);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        low.setAsset(address(posm), true);
        assertEq(_vaultsSnapshot(id), before_, "nothing moved");
        if (!real) vm.clearMockedCalls();
        // Token lending is untouched by any of it.
        (uint256 token,) = _activateOne(low, 1000e6, 1100e6);
        assertEq(uint8(core.getLoan(token).state), uint8(V2State.ACTIVE));
        vm.serializeBool(o, "realPositionListing", real);
        _n(o, "listingId", id);
        vm.serializeString(
            o, "atTheVerifier", "consume() preflight from the router = NONE: the plan names the core's kind truthfully"
        );
        vm.serializeString(o, "atTheRouter", "IntentFillRouter.fill reverts IneligibleDeal() from the vault's purchase");
        vm.serializeString(
            o,
            "atTheVault",
            "IntentVault.purchase called by its own router reverts IneligibleDeal(); by anyone else NotCurator()"
        );
        vm.serializeString(o, "inTheMandate", "setAsset(PositionManager) reverts InvalidConfiguration()");
    }

    // ---------------------------------------------------------------- 8. revenue into the live route

    function testTheFillsExecutionFeeIsClaimedIntoTheLiveProcessorAndOneClipReachesTheFloor() public {
        _scenarioRevenue();
    }

    function _scenarioRevenue() internal {
        string memory o = "s8";
        Readback memory live = _readback();
        (uint256 id, IntentQuoteVerifier.Plan memory p) = _activateBoth(1000e6, 1100e6);
        uint256 fee = uint256(p.allocations[0].executionFee) + p.allocations[1].executionFee;
        uint256 afterFill = processor.availableUSDG();
        assertEq(
            afterFill - live.available, core.getLoan(id).originationFee, "only the core's own fee came with the fill"
        );
        vm.prank(anyone);
        assertEq(fills.claim(address(processor)), fee);
        assertEq(processor.availableUSDG() - afterFill, fee, "availableUSDG rose by exactly the claim");
        assertEq(fills.totalOwed(), 0);
        // S7's helpers: the largest clip the live pools take inside the router's 1% bound, then one reconciled clip.
        Search memory found = _search(processor.availableUSDG(), live.threshold);
        Route memory a = _route();
        Clip memory c = _processReconciled(a, found.largestPassing);
        _n(o, "executionFeeClaimed", fee);
        _n(o, "coreOriginationFeeAtActivation", core.getLoan(id).originationFee);
        _n(o, "availableUSDGAtPin", live.available);
        _n(o, "threshold", live.threshold);
        _n(o, "standInUSDG", found.standIn);
        _n(o, "largestPassingClip", found.largestPassing);
        _n(o, "smallestFailingClip", found.smallestFailing);
        _n(o, "clipUSDGIn", c.usdgIn);
        _n(o, "clipETHOut", c.ethOut);
        _n(o, "clipGAGEBought", c.gageBought);
        _n(o, "clipGAGEAdded", c.gageAdded);
        _n(o, "bandTokenId", c.tokenId);
        _n(o, "bandLiquidityBefore", c.bandLiquidityBefore);
        _n(o, "bandLiquidityAfter", c.bandLiquidity);
    }

    // ---------------------------------------------------------------- evidence

    function testTheWholeLifecycleWritesItsEvidence() public {
        uint256 start = vm.snapshotState();
        _scenarioCreationAndDeposits();
        vm.revertToState(start);
        start = vm.snapshotState();
        _scenarioAtomicFillAndRollback();
        vm.revertToState(start);
        start = vm.snapshotState();
        _scenarioEarlyRepayment();
        vm.revertToState(start);
        start = vm.snapshotState();
        _scenarioOnTimeRepayment();
        vm.revertToState(start);
        start = vm.snapshotState();
        _scenarioDefaultAndRecovery();
        vm.revertToState(start);
        start = vm.snapshotState();
        _scenarioWithdrawals();
        vm.revertToState(start);
        start = vm.snapshotState();
        _scenarioPositionRefused();
        vm.revertToState(start);
        _scenarioRevenue();
        _write();
    }

    function _write() internal {
        string memory o = "s8addresses";
        vm.serializeAddress(o, "zeroGraceCore", address(core));
        vm.serializeAddress(o, "coreRegistry", address(core.REGISTRY()));
        vm.serializeAddress(o, "morphoReserve", reserve);
        vm.serializeAddress(o, "collateralToken", collateral);
        vm.serializeAddress(o, "USDG", address(usdg));
        vm.serializeAddress(o, "GAGE", address(gage));
        vm.serializeAddress(o, "DealFeeRouter", address(processor));
        vm.serializeAddress(o, "FeeFloor", address(feeFloor));
        vm.serializeAddress(o, "FeeSink", address(feeSink));
        vm.serializeAddress(o, "DealVault", address(feeSink.vault()));
        vm.serializeAddress(o, "PoolManager", poolManager);
        vm.serializeAddress(o, "PositionManager", address(posm));
        string memory addresses = vm.serializeAddress(o, "Permit2", PERMIT2);

        o = "s8fixture";
        vm.serializeString(
            o,
            "scope",
            "Deployed in the fork VM only: IntentFactory (live core, live Morpho reserve, MorphoV2ReserveLens), a GradeRegistry the test published, IntentQuoteVerifier, IntentFillRouter and two partner vaults. protocolRecipient is the live DealFeeRouter, owed every execution fee (no filler payout, D49). USDG and the collateral token were handed out with deal (fork VM storage edits)."
        );
        vm.serializeAddress(o, "protocolRecipient", factory.protocolRecipient());
        _n(o, "managerFeeBpsLow", LOW_FEE_BPS);
        _n(o, "managerFeeBpsHigh", HIGH_FEE_BPS);
        _n(o, "minRateGrade", RATE_GRADE_B);
        _n(o, "minGrade", 5);
        _n(o, "publishedGrade", 7);
        _n(o, "modeledCostBps", COST_BPS);
        _n(o, "executionCapBps", CAP_BPS);
        _n(o, "fillerShareBps", 0); // V1's router has no filler share (D49)
        _n(o, "collateralAmount", collateralAmount);
        string memory fixture = _n(o, "term", T21);

        o = "s8-mainnet-fork-lifecycle";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "acceptance", "S8-A2 / R6-A2, R6-A9");
        _n(o, "blockNumber", pinnedBlock);
        vm.serializeBytes32(o, "blockHash", pinnedHash);
        _n(o, "blockTimestamp", pinnedTime);
        _n(o, "checkedAtUnixMs", vm.unixTime());
        vm.serializeString(o, "manifest", "launch/live/4663.json");
        vm.serializeString(o, "test", "contracts/test/fork/IntentLifecycle.fork.t.sol");
        vm.serializeString(
            o,
            "amounts",
            "raw six-decimal USDG units unless named otherwise; share prices are convertToAssets(1e30), so par is 1e18"
        );
        vm.serializeBool(o, "mainnetMutations", false);
        vm.serializeBool(o, "localForkOnly", true);
        vm.serializeString(o, "scenariosMovedToTheLocalFixture", "none");
        vm.serializeString(
            o,
            "pin",
            "The public node serves historical state for minutes only (it answered at head - 5,000 blocks and refused at head - 10,000, at about ten blocks a second). A re-run at this pin is served by Foundry's RPC cache (~/.foundry/cache/rpc/4663/<block>), not by the node; without that cache, leave INTENT_MAINNET_FORK_BLOCK unset and the suite pins a fresh block. S7's pin 67980026 was already pruned when this suite was first run, so the two suites have different pins."
        );
        vm.serializeString(o, "addresses", addresses);
        vm.serializeString(o, "fixture", fixture);
        vm.serializeString(o, "s1CreationAndDeposits", vm.serializeBool("s1", "ran", true));
        vm.serializeString(o, "s2AtomicFillAndRollback", vm.serializeBool("s2", "ran", true));
        vm.serializeString(o, "s3EarlyRepaymentD29", vm.serializeBool("s3", "ran", true));
        vm.serializeString(o, "s4OnTimeRepayment", vm.serializeBool("s4", "ran", true));
        vm.serializeString(o, "s5DefaultAndRecovery", vm.serializeBool("s5", "ran", true));
        vm.serializeString(o, "s6Withdrawals", vm.serializeBool("s6", "ran", true));
        vm.serializeString(o, "s7PositionBackedRefused", vm.serializeBool("s7", "ran", true));
        vm.writeJson(vm.serializeString(o, "s8Revenue", vm.serializeBool("s8", "ran", true)), EVIDENCE);
    }
}
