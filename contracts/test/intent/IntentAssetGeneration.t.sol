// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LocalV3} from "../helpers/LocalV3.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeProcessor} from "../mocks/MockFeeProcessor.sol";
import {IntentPreflight} from "./IntentPreflight.sol";
import {IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {IFunderGate} from "../../src/interfaces/IFunderGate.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentCategory} from "../../src/intent/IntentVaultState.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentClosedReserve} from "../../src/intent/IntentClosedReserve.sol";
import {IntentAssetFeeProcessor} from "../../src/intent/IntentAssetFeeProcessor.sol";

/// @notice A whole Intent generation lending an 18-decimal stock token (a GLD), deployed as the release deploys one:
/// the asset fee processor first, then the token registry, the core (whose fee recipient it is), the closed reserve,
/// the grade registry, the factory (reserve lens zero, the processor its protocol recipient), the quote verifier, the
/// fill router and the cash-out router; the core's funder gate bound to the factory. One partner vault lends GLD
/// against a meme paired with it (root D249). Real Uniswap v3 pools: GLD/USDG 0.05% (the processor's), GLD/WETH (the
/// cash-out flash source) and MEME/GLD (the meme's exit). The floor's USDG processor is a stand-in with
/// `DealFeeRouter`'s two views; `IntentAssetFeeProcessor.fork.t.sol` forwards into the live one.
/// @dev Time is read with `vm.getBlockTimestamp()`: under the IR pipeline a test's `block.timestamp` can be one value
/// for its whole call, warps included.
contract IntentAssetGenerationTest is LocalV3 {
    string internal constant POOL_MANAGER_ARTIFACT =
        "lib/v4-periphery/lib/v4-core/out/PoolManager.sol/PoolManager.json";
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;
    uint8 internal constant UNITS = 4;
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant SIGNER_KEY = 0xA55E75161;
    uint16 internal constant CAP_BPS = 2000;
    uint32 internal constant COST_BPS = 500;
    /// @dev The loan every case uses: 100 GLD against 100,000 SCHIFFY (about 1,000 GLD), 105 GLD back within 21 days.
    uint128 internal constant PRINCIPAL = 100e18;
    uint128 internal constant CAP = 105e18;
    uint256 internal constant COLLATERAL = 100_000e18;
    /// @dev What the vault's holders keep of the loan's 5 GLD: less the 20% execution fee and the 10% manager fee on
    /// the rest.
    uint256 internal constant HOLDERS_NET = 3.6e18;

    MockERC20 internal gld;
    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal meme;
    MockERC20 internal weth;
    address internal gldUsdg;
    address internal gldWeth;
    address internal memeGld;
    MockFeeProcessor internal floorRouter;
    IntentAssetFeeProcessor internal processor;
    IntentClosedReserve internal reserve;
    GageV2TokenRegistry internal registry;
    GageV2Vault internal core;
    GradeRegistry internal grades;
    IntentFactory internal factory;
    IntentQuoteVerifier internal verifier;
    IntentFillRouter internal fills;
    GageV2CashoutRouter internal cashout;
    IntentVault internal vault;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");
    address internal signer;

    function setUp() public {
        vm.warp(10_000);
        signer = vm.addr(SIGNER_KEY);
        gld = new MockERC20("GLD", "GLD", 18);
        usdg = new MockERC20("USDG", "USDG", 6);
        sgage = new MockERC20("sGAGE", "sGAGE", 18);
        meme = new MockERC20("SCHIFFY", "SCHIFFY", 18);
        weth = new MockERC20("WETH", "WETH", 18);
        _deployV3Factory();
        // One GLD is 400 USDG, 0.1 WETH or 100 SCHIFFY.
        gldUsdg = _v3Pool(address(gld), 100_000e18, address(usdg), 40_000_000e6, 500);
        gldWeth = _v3Pool(address(gld), 10_000e18, address(weth), 1000e18, 3000);
        memeGld = _v3Pool(address(meme), 100_000_000e18, address(gld), 1_000_000e18, 3000);

        floorRouter = new MockFeeProcessor(address(usdg));
        // First: the core fixes its fee recipient for good.
        processor = new IntentAssetFeeProcessor(
            IERC20(address(gld)), IERC20(address(usdg)), v3Factory, gldUsdg, address(floorRouter), keeper, admin
        );
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        registry = new GageV2TokenRegistry(admin, terms, v3Factory);
        vm.prank(admin);
        registry.setERC20Allowed(address(meme), true, Lane.MEME, 1e18, 1_000_000e18, 10_000_000e18);
        core = new GageV2Vault(
            registry, IERC20(address(gld)), IERC20(address(sgage)), address(processor), 0, GageLegacyAdapter(address(0))
        );
        reserve = new IntentClosedReserve(IERC20(address(gld)));
        grades = new GradeRegistry(admin, keeper);
        IntentVaultCode code = new IntentVaultCode();
        factory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: address(reserve),
                reserveLens: address(0),
                grades: address(grades),
                protocolRecipient: address(processor),
                initialOwner: admin,
                codeA: code.CHUNK_A(),
                codeB: code.CHUNK_B()
            })
        );
        verifier = new IntentQuoteVerifier(factory);
        fills = new IntentFillRouter(verifier, IERC20(address(gld)));
        cashout = new GageV2CashoutRouter(
            core,
            IV2FlashPool(gldWeth),
            IPoolManager(deployCode(POOL_MANAGER_ARTIFACT, abi.encode(admin))),
            address(weth),
            admin
        );
        vm.startPrank(admin);
        core.REWARDS().bindFunderGate(IFunderGate(address(factory)));
        factory.setFillRouter(address(fills));
        factory.setQuoteSigner(signer);
        factory.setFiller(keeper, true);
        factory.setCreator(curator, true);
        factory.assignCategory(address(meme), IntentCategory.MEME);
        cashout.setV3Route(memeGld, true);
        vm.stopPrank();

        vault = _vault();
        address[3] memory funded = [alice, bob, stranger];
        for (uint256 i; i < funded.length; ++i) {
            gld.mint(funded[i], 10_000 * ONE);
            vm.startPrank(funded[i]);
            gld.approve(address(vault), MAX);
            gld.approve(address(core), MAX);
            vm.stopPrank();
        }
        meme.mint(borrower, 1_000_000e18);
        gld.mint(borrower, 1000 * ONE);
        vm.startPrank(borrower);
        meme.approve(address(core), MAX);
        gld.approve(address(core), MAX);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the generation

    function test_theGenerationStandsOnTheClosedReserveAndTheAssetProcessor() public {
        assertEq(address(core.USDG()), address(gld), "the core lends GLD");
        assertEq(core.FEE_RECIPIENT(), address(processor));
        assertEq(factory.RESERVE(), address(reserve));
        assertEq(factory.RESERVE_LENS(), address(0), "no lens: the closed reserve's own views");
        assertEq(factory.protocolRecipient(), address(processor));
        assertEq(address(vault.USDG()), address(gld));
        assertEq(address(vault.RESERVE()), address(reserve));
        assertEq(address(vault.RESERVE_LENS()), address(0));
        assertEq(address(fills.USDG()), address(gld));
        assertEq(cashout.FEE_RECIPIENT(), address(processor));
        assertEq(address(cashout.USDG()), address(gld));
        assertEq(address(cashout.FLASH_POOL()), gldWeth);
        assertEq(processor.USDG(), address(gld));
        // A processor of USDG is refused: it would name another asset than the core's.
        vm.prank(admin);
        vm.expectRevert(IntentFactory.NotAFeeProcessor.selector);
        factory.setProtocolRecipient(address(floorRouter));
        // A reserve of another asset is refused by every vault it would serve (`IntentVault`'s `RESERVE.asset()` check).
        IntentFactory other = _factoryWith(address(new IntentClosedReserve(IERC20(address(usdg)))));
        vm.prank(admin);
        other.setCreator(curator, true);
        IntentVault.Mandate memory m = _mandate();
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        other.create(m, false, 0, "Wrong reserve");
    }

    /// @dev Intent D55 at 18 decimals: one whole GLD is the smallest deposit, 1.3 GLD is taken, and the cash stays
    /// cash: the filler cannot move it into the closed reserve.
    function test_depositsStayCashAndRedeemFromIt() public {
        vm.prank(alice);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        vault.deposit(ONE - 1, 0);
        assertEq(_deposit(alice, 13 * ONE / 10), 1.3e18, "1.3 GLD mints 1.3e18 shares");
        assertEq(_deposit(bob, 1000 * ONE), 1000e18);
        assertEq(vault.cash(), 1001.3e18);
        assertEq(vault.totalAssets(), vault.cash());
        assertEq(vault.freeLiquidity(), vault.cash());

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(vault), 500e18, 0));
        fills.investReserve(address(vault), 500e18, 0);
        assertEq(vault.cash(), 1001.3e18);
        assertEq(vault.reserveShares(), 0);
        assertEq(reserve.totalSupply(), 0);

        assertEq(_exitAll(alice), 13 * ONE / 10);
        assertEq(_exitAll(bob), 1000 * ONE);
        assertEq(gld.balanceOf(address(vault)), 0);
    }

    /// @dev The signed plan's reserve bound is the closed reserve's one-to-one conversion, whatever is sent to the
    /// reserve; a bound wider than the verifier's tolerance is refused, and a cash-only bound passes.
    function test_aPlansReserveBoundIsTheClosedReservesConversion() public {
        _deposit(bob, 200 * ONE);
        uint256 id = _list();
        IntentQuoteVerifier.Plan memory p = _plan(id);
        uint256 payment = uint256(p.allocations[0].principal) + p.allocations[0].executionFee;
        assertEq(p.allocations[0].maxReserveShares, payment);
        gld.mint(address(reserve), 1000 * ONE);
        assertEq(reserve.previewWithdraw(payment), payment, "a donation moves nothing");
        assertEq(vault.freeLiquidity(), vault.cash());
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        p.allocations[0].maxReserveShares = uint128(payment * 102 / 100);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.RESERVE_BOUND));
        p.allocations[0].maxReserveShares = 0;
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
    }

    // ---------------------------------------------------------------- loans

    /// @dev Fund through a signed plan, repay at half term, settle: the holders leave with their deposits and the 3.6
    /// GLD net, partly through the share price and partly as their D51 earnings claim.
    function test_aFilledLoanRepaidPaysTheHolders() public {
        _deposit(alice, 13 * ONE / 10);
        _deposit(bob, 1000 * ONE);
        uint256 id = _list();
        IntentQuoteVerifier.Plan memory p = _fill(id);
        assertEq(p.allocations[0].executionFee, 1e18, "20% of the 5 GLD");
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(vault.cash(), 1001.3e18 - 101e18);
        assertEq(vault.freeLiquidity(), vault.cash(), "cash only");
        assertEq(core.cashCredit(address(processor)), 1e18, "the 1% origination fee, in GLD");
        assertEq(fills.owed(address(processor)), 1e18, "the execution fee, in GLD");

        vm.warp(_startOf(id) + T21 / 2);
        vm.prank(borrower);
        core.reclaim(id, borrower);
        vault.settle(_ids(id));
        assertEq(vault.protocolFees(), 0.04e18, "10% of the 0.4 GLD manager fee");

        uint256 out = _leave(alice) + _leave(bob);
        assertApproxEqAbs(out, 1001.3e18 + HOLDERS_NET, 4e12);
        vm.prank(borrower);
        core.withdrawCollateral(id, borrower);
        assertEq(meme.balanceOf(borrower), 1_000_000e18, "the collateral is back");
    }

    /// @dev Past its term a loan is written off; its collateral is recovered for the holders of record, who claim the
    /// meme, and redeem the cash left.
    function test_aDefaultIsWrittenOffAndTheHoldersClaimItsCollateral() public {
        _deposit(alice, 13 * ONE / 10);
        _deposit(bob, 1000 * ONE);
        uint256 id = _list();
        _fill(id);
        vm.warp(_startOf(id) + T21);
        vm.prank(alice);
        vm.expectRevert(IntentVault.SettlementDue.selector);
        vault.redeem(1e18, 0);
        vm.prank(stranger);
        vault.settle(_ids(id));
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.DEFAULTED));
        vm.prank(stranger);
        vault.recover(id);
        uint256 pocketId = vault.pocketCount();
        (, address token, uint256 amount,,,) = vault.pockets(pocketId);
        assertEq(token, address(meme));
        assertEq(amount, COLLATERAL);

        vm.prank(alice);
        uint256 toAlice = vault.claimPocket(pocketId);
        vm.prank(bob);
        uint256 toBob = vault.claimPocket(pocketId);
        assertApproxEqAbs(toAlice, COLLATERAL * 13 / 10_013, 1);
        assertApproxEqAbs(toAlice + toBob, COLLATERAL, 2);
        assertEq(meme.balanceOf(alice), toAlice);

        // The principal and the execution fee left with the loan; the rest is cash and redeems.
        uint256 left = _exitAll(alice);
        // Below the first price, the last holder's whole balance converts to a little more than the cash left: the
        // conversion's virtual assets, `ASSET_SCALE` (10^12 here), are priced at the first price (Intent D55). Under
        // a millionth of a GLD; at six decimals the same excess rounds away. All but a millionth of a share redeems.
        uint256 shares = vault.balanceOf(bob);
        assertGt(vault.convertToAssets(shares), vault.cash());
        assertLt(vault.convertToAssets(shares) - vault.cash(), 1e12);
        vm.prank(bob);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        vault.redeem(shares, 0);
        vm.prank(bob);
        left += vault.redeem(shares - 1e12, 0);
        assertApproxEqAbs(left, 1001.3e18 - 101e18, 2e12);
        assertLt(vault.cash(), 1e12, "dust");
    }

    /// @dev Redemptions are paid from cash, all of it: a request beyond it reverts, one within it is paid.
    function test_redemptionsArePaidFromCash() public {
        _deposit(bob, 200 * ONE);
        _fill(_list());
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(vault.cash(), 99e18);
        assertEq(vault.freeLiquidity(), 99e18);
        uint256 shares = vault.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        vault.redeem(shares * 6 / 10, 0);
        vm.prank(bob);
        uint256 paid = vault.redeem(shares * 4 / 10, 0);
        assertApproxEqAbs(paid, 199e18 * 4 / 10, 1e13);
        assertEq(vault.cash(), 99e18 - paid);
    }

    // ---------------------------------------------------------------- fees

    /// @dev Every fee the generation makes reaches the processor in GLD: the origination and trade fees through the
    /// core's credit (`withdrawUSDGFor`), the execution fees through the fill router (`claim`), the protocol's share
    /// of the manager fees through the vault (`claimFees`), all three pulled by anyone, and the cash-out fee sent
    /// directly. The keeper converts it to USDG, which reaches the floor's processor.
    function test_everyFeeReachesTheProcessorAndConvertsToUsdgForTheFloor() public {
        _deposit(alice, 13 * ONE / 10);
        _deposit(bob, 1000 * ONE);

        // A loan whose reclaim right is sold, then repaid by its buyer.
        uint256 sold = _list();
        _fill(sold);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(borrower);
        core.setAskWithMaxFee(sold, 10e18, uint40(vm.getBlockTimestamp() + 1 hours), type(uint16).max);
        uint256 nonce = core.getAsk(sold).nonce;
        vm.prank(stranger);
        core.buy(sold, borrower, nonce, 10e18, type(uint16).max, stranger);
        vm.prank(stranger);
        core.reclaim(sold, stranger);

        // A loan cashed out through the router, selling its meme for GLD on its v3 exit.
        uint256 cashedOut = _list();
        _fill(cashedOut);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 platformFee = _cashOut(cashedOut);
        assertGt(platformFee, 4e18, "0.5% of about 890 GLD");
        assertEq(gld.balanceOf(address(processor)), platformFee, "sent directly");

        vault.settle(_ids(sold));
        vault.settle(_ids(cashedOut));
        uint256 credited = 2 * (PRINCIPAL / 100) + 10e18 / 100;
        assertEq(core.cashCredit(address(processor)), credited, "two origination fees and one trade fee");
        assertEq(fills.owed(address(processor)), 2e18, "two execution fees");
        assertEq(vault.protocolFees(), 0.08e18, "the protocol's share of two manager fees");

        vm.startPrank(stranger);
        core.withdrawUSDGFor(address(processor));
        fills.claim(address(processor));
        vault.claimFees();
        vm.stopPrank();
        uint256 fees = platformFee + credited + 2e18 + 0.08e18;
        assertEq(processor.availableUSDG(), fees);
        assertEq(gld.balanceOf(curator), 0.72e18, "the manager's 90%");

        uint256 quote = _quoteExactIn(gldUsdg, address(gld), fees);
        assertApproxEqRel(quote, fees * 400 / 1e12, 0.002e18, "about 400 USDG a GLD");
        vm.prank(keeper);
        (uint256 usdgOut, uint256 forwarded) = processor.convert(fees, quote);
        assertEq(usdgOut, quote);
        assertEq(forwarded, quote);
        assertEq(floorRouter.availableUSDG(), quote, "the floor's processor holds it");
        assertEq(processor.availableUSDG(), 0);
        assertEq(usdg.balanceOf(address(processor)), 0);
        assertEq(processor.totalConverted(), fees);
        assertEq(processor.totalForwarded(), quote);
    }

    // ---------------------------------------------------------------- helpers

    function _mandate() internal view returns (IntentVault.Mandate memory m) {
        address[] memory assets = new address[](1);
        assets[0] = address(meme);
        m = IntentVault.Mandate({
            curator: curator,
            categoryWeights: [uint16(0), 10_000, 0, 0],
            assets: assets,
            maxLoanTerm: T21,
            feeBps: 1000,
            minGrade: 0,
            minRateGrade: 0,
            maxLoanPrincipal: uint128(1_000_000 * ONE),
            maxAssetBps: 10_000,
            bufferBps: 0,
            executionCapBps: CAP_BPS
        });
    }

    function _vault() internal returns (IntentVault) {
        IntentVault.Mandate memory m = _mandate();
        vm.prank(curator);
        return IntentVault(factory.create(m, false, 0, "GLD against SCHIFFY"));
    }

    function _factoryWith(address reserve_) internal returns (IntentFactory) {
        IntentVaultCode code = new IntentVaultCode();
        return new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: reserve_,
                reserveLens: address(0),
                grades: address(grades),
                protocolRecipient: address(processor),
                initialOwner: admin,
                codeA: code.CHUNK_A(),
                codeB: code.CHUNK_B()
            })
        );
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, 0);
    }

    function _exitAll(address who) internal returns (uint256 assets) {
        uint256 shares = vault.balanceOf(who);
        vm.prank(who);
        assets = vault.redeem(shares, 0);
    }

    /// @dev What `who` leaves with: every share redeemed and every claim collected.
    function _leave(address who) internal returns (uint256 total) {
        total = _exitAll(who);
        for (uint256 i = 1; i <= vault.pocketCount(); ++i) {
            if (vault.pocketClaimable(i, who) == 0) continue;
            vm.prank(who);
            total += vault.claimPocket(i);
        }
    }

    function _list() internal returns (uint256 id) {
        vm.prank(borrower);
        id = core.list(
            Collateral(Kind.ERC20, address(meme), COLLATERAL),
            PRINCIPAL,
            CAP,
            T21,
            uint40(vm.getBlockTimestamp() + 1 days),
            false
        );
    }

    /// @dev The plan an honest signer gives for the whole listing from the one vault (`IntentPlanBase._plan`).
    function _plan(uint256 id) internal view returns (IntentQuoteVerifier.Plan memory p) {
        V2Loan memory l = core.getLoan(id);
        p.engine = address(core);
        p.listingId = id;
        p.filler = keeper;
        p.token = l.token;
        p.kind = uint8(l.kind);
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.term = l.term;
        p.costBps = COST_BPS;
        p.feePolicy = verifier.FEE_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.issuedAt = uint40(vm.getBlockTimestamp());
        p.expiry = uint40(vm.getBlockTimestamp() + 90);
        p.evidence = keccak256("GLD generation evidence");
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
        a.maxReserveShares = uint128(reserve.previewWithdraw(uint256(a.principal) + fee));
    }

    function _sign(IntentQuoteVerifier.Plan memory p) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, verifier.planHash(p));
        return abi.encodePacked(r, s, v);
    }

    function _reason(IntentQuoteVerifier.Plan memory p) internal returns (IntentQuoteVerifier.Refusal) {
        return IntentPreflight.reason(verifier, p, _sign(p), keeper);
    }

    /// @dev The keeper fills the listing through the router on a signed plan, preflighted first.
    function _fill(uint256 id) internal returns (IntentQuoteVerifier.Plan memory p) {
        p = _plan(id);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE), "preflight");
        bytes memory signature = _sign(p);
        uint256[] memory limits = new uint256[](1);
        limits[0] = MAX;
        vm.prank(keeper);
        fills.fill(p, signature, limits);
    }

    /// @dev The borrower exits in one transaction: GLD flash-borrowed from GLD/WETH, the meme sold on MEME/GLD.
    function _cashOut(uint256 id) internal returns (uint256 platformFee) {
        vm.prank(borrower);
        core.approve(address(cashout), id);
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](1);
        PoolKey memory none;
        routes[0] =
            GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, address(meme), address(gld), 3000, none, 1);
        GageV2CashoutRouter.Exit memory x = GageV2CashoutRouter.Exit({
            loanId: id,
            recipient: borrower,
            minimumNet: 1,
            maxFinanceFee: 1e18,
            minUnderlying0: 0,
            minUnderlying1: 0,
            deadline: vm.getBlockTimestamp() + 10 minutes,
            routes: routes
        });
        vm.prank(borrower);
        (,, platformFee,) = cashout.cashOutDetailed(x);
        assertEq(uint256(core.getLoan(id).state), uint256(V2State.REPAID));
    }

    function _startOf(uint256 id) internal view returns (uint256) {
        return core.getLoan(id).fundedAt;
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
