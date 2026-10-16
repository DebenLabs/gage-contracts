// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {MockFeeProcessor, MockTokenOnlyRecipient} from "../mocks/MockFeeProcessor.sol";
import {EarnV3BaseTest} from "../earn/EarnV3Base.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Authorization fixture only, not the S3 quote/S4 atomic execution router.
contract IntentRouterFixture {
    IntentFactory immutable factory;

    constructor(IntentFactory f) {
        factory = f;
    }

    function fund(IntentVault v, uint256 id, uint8 units) external {
        require(factory.isFiller(msg.sender), "filler denied");
        v.purchase(id, units, 0, type(uint256).max, 0);
    }
}

contract IntentPartnersTest is EarnV3BaseTest {
    IntentFactory internal partnerFactory;
    IntentVault internal partner;
    IntentVault.Mandate internal mandate;
    IntentRouterFixture internal router;
    address internal feeProcessor;
    /// @dev A commodity token: the same core lane as a stock, its own Intent category (D41).
    MockERC20 internal gold;

    function setUp() public virtual override {
        super.setUp();
        feeProcessor = address(new MockFeeProcessor(address(usdg)));
        partnerFactory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: address(reserve),
                reserveLens: address(0),
                grades: address(grades),
                protocolRecipient: feeProcessor,
                initialOwner: address(this),
                codeA: _codeA(),
                codeB: _codeB()
            })
        );
        gold = new MockERC20("Gold", "GLDx", 18);
        vm.prank(safe);
        registry.setERC20Allowed(address(gold), true, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        partnerFactory.assignCategory(address(nvda), IntentCategory.STOCK);
        partnerFactory.assignCategory(address(meme), IntentCategory.MEME);
        partnerFactory.assignCategory(address(gold), IntentCategory.COMMODITY);
        partnerFactory.setCreator(curator, true);
        // Fixture values are not protocol launch defaults.
        mandate = IntentVault.Mandate({
            curator: curator,
            categoryWeights: [uint16(6000), 0, 0, 3000],
            assets: new address[](2),
            maxLoanTerm: T21,
            feeBps: 1500,
            minGrade: 0,
            minRateGrade: 0,
            maxLoanPrincipal: 1500e6,
            maxAssetBps: 6000,
            bufferBps: 0,
            executionCapBps: 0
        });
        mandate.assets[0] = address(nvda);
        mandate.assets[1] = address(gold);
        partner = _create();
        vm.prank(alice);
        usdg.approve(address(partner), MAX);
        router = new IntentRouterFixture(partnerFactory);
    }

    function _create() internal returns (IntentVault v) {
        vm.prank(curator);
        v = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
    }

    function _depositPartner() internal {
        vm.prank(alice);
        partner.deposit(10_000e6, 0);
    }

    function _enableFixture() internal {
        partnerFactory.setFillRouter(address(router));
        partnerFactory.setQuoteSigner(address(0x5151));
        partnerFactory.setFiller(bob, true);
    }

    function _route(uint256 id, uint8 units) internal {
        vm.prank(bob);
        router.fund(partner, id, units);
    }

    /// @dev S7 finding: the floor took a USDG recipient's place for four sprints and nothing on chain objected.
    /// @dev One store of the strategy code per test, created outside any expected revert; its two chunks are what a
    /// factory is given, read once here so that no call to the store sits between an expected revert and its target.
    address private _codeStore;
    address private _chunkA;
    address private _chunkB;

    function _vaultCode() internal returns (address) {
        if (_codeStore == address(0)) {
            IntentVaultCode store = new IntentVaultCode();
            _codeStore = address(store);
            _chunkA = store.CHUNK_A();
            _chunkB = store.CHUNK_B();
        }
        return _codeStore;
    }

    function _codeA() internal returns (address) {
        _vaultCode();
        return _chunkA;
    }

    function _codeB() internal returns (address) {
        _vaultCode();
        return _chunkB;
    }

    function _factoryWith(address recipient) internal returns (IntentFactory) {
        return _factoryWith(recipient, _codeA(), _codeB());
    }

    function _factoryWith(address recipient, address codeA, address codeB) internal returns (IntentFactory) {
        return new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: address(reserve),
                reserveLens: address(0),
                grades: address(grades),
                protocolRecipient: recipient,
                initialOwner: address(this),
                codeA: codeA,
                codeB: codeB
            })
        );
    }

    /// @dev Each of the two data contracts must hold code past its leading STOP. Zero, a wallet and a lone STOP are
    /// refused in either place before the factory reads them (an empty part would otherwise underflow in `_read`).
    function testTheFactoryRefusesStrategyCodeHoldersWithoutData() public {
        (address codeA, address codeB) = (_codeA(), _codeB());
        address stopOnly = makeAddr("a data contract holding only its STOP");
        vm.etch(stopOnly, hex"00");
        address[3] memory empty = [address(0), makeAddr("a wallet"), stopOnly];
        for (uint256 i; i < empty.length; ++i) {
            vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
            _factoryWith(feeProcessor, empty[i], codeB);
            vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
            _factoryWith(feeProcessor, codeA, empty[i]);
        }
        // Control: the same parameters with both parts accepted.
        assertEq(_factoryWith(feeProcessor, codeA, codeB).VAULT_INIT_HASH(), keccak256(type(IntentVault).creationCode));
    }

    function testTheProtocolRecipientMustBeAFeeProcessorForThisUSDGAtDeploymentAndEverAfter() public {
        address wallet = makeAddr("a wallet");
        address tokenOnly = address(new MockTokenOnlyRecipient(address(usdg)));
        address otherToken = address(new MockFeeProcessor(address(nvda)));
        address processor = address(new MockFeeProcessor(address(usdg)));
        // A wallet, a contract that cannot answer (the stand-in floor is a plain token), one that names the token but
        // cannot process a balance, and a processor of another token: none may ever be paid the protocol's USDG.
        address[5] memory refused = [address(0), wallet, floor, tokenOnly, otherToken];
        // Code-less addresses and a processor of another token revert NotAFeeProcessor; a contract missing a view
        // reverts from that call itself, with no data.
        bytes memory notAProcessor = abi.encodeWithSelector(IntentFactory.NotAFeeProcessor.selector);
        bytes[5] memory reasons = [notAProcessor, notAProcessor, bytes(""), bytes(""), notAProcessor];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(reasons[i]);
            _factoryWith(refused[i]);
            vm.expectRevert(reasons[i]);
            partnerFactory.setProtocolRecipient(refused[i]);
        }
        assertEq(_factoryWith(processor).protocolRecipient(), processor);
        vm.expectEmit(true, false, false, false, address(partnerFactory));
        emit IntentFactory.ProtocolRecipientSet(processor);
        partnerFactory.setProtocolRecipient(processor);
        assertEq(partnerFactory.protocolRecipient(), processor);
        // Only the owner, as before.
        vm.prank(curator);
        vm.expectRevert();
        partnerFactory.setProtocolRecipient(processor);
    }

    function testRuntimeAndFactoryCodeIdentityFitDeploymentLimits() public view {
        assertLe(address(partner).code.length, 24_576, "IntentVault exceeds EIP-170");
        assertLe(address(partnerFactory).code.length, 24_576, "IntentFactory exceeds EIP-170");
        assertLt(type(IntentFactory).creationCode.length, 49_152, "factory initcode exceeds EIP-3860");
        // The data contracts, written the way the deployment script writes them, hold exactly this build's vault.
        assertEq(partnerFactory.VAULT_INIT_HASH(), keccak256(type(IntentVault).creationCode));
        assertEq(partnerFactory.MANDATE_VERSION(), partner.MANDATE_VERSION());
    }

    function testAdmissionRevocationStopsNewFillsButNotServicing() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(1000e6);
        _route(id, 4);
        uint256 id2 = _listed(1000e6);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id2, 4);
        // D51: a repayment in the second the loan was funded is booked from the next second.
        vm.warp(vm.getBlockTimestamp() + 1);
        _repay(id);
        partner.settle(_ids(id));
        assertEq(partner.performingPrincipal(), 0);
    }

    function testPartnerOnlyCreationNoOwnerOrCuratorSpoofBypass() public {
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        mandate.curator = bob;
        vm.prank(curator);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        assertFalse(partnerFactory.isFiller(curator));
        assertTrue(partnerFactory.isVault(address(partner)));
        assertEq(partner.CURATOR(), curator);
        assertEq(partnerFactory.vaults(0), address(partner));
        assertEq(partner.MANDATE_VERSION(), 12);
    }

    function testRemovalPreservesDiscoveryAndExit() public {
        _depositPartner();
        partnerFactory.setCreator(curator, false);
        vm.prank(curator);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        assertTrue(partnerFactory.isVault(address(partner)));
        assertEq(partnerFactory.count(), 1);
        uint256 shares = partner.balanceOf(alice);
        vm.prank(alice);
        assertEq(partner.redeem(shares, 0), 10_000e6);
    }

    /// @dev Permissionless creation: the owner opens creation to every address and can close it again. Open or
    /// closed, a vault's manager is always the address that creates it, and admitted creators keep creating.
    function testOpenCreationLetsAnyAddressCreateItsOwnVault() public {
        address stranger = makeAddr("any manager");
        mandate.curator = stranger;
        vm.prank(stranger);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");

        vm.expectEmit(address(partnerFactory));
        emit IntentFactory.OpenCreationSet(true);
        partnerFactory.setOpenCreation(true);
        assertTrue(partnerFactory.openCreation());
        vm.prank(stranger);
        IntentVault opened = IntentVault(partnerFactory.create(mandate, true, 100, "Test vault"));
        assertTrue(partnerFactory.isVault(address(opened)));
        assertEq(opened.CURATOR(), stranger);

        mandate.curator = bob;
        vm.prank(stranger);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");

        vm.expectEmit(address(partnerFactory));
        emit IntentFactory.OpenCreationSet(false);
        partnerFactory.setOpenCreation(false);
        mandate.curator = stranger;
        vm.prank(stranger);
        vm.expectRevert(IntentFactory.CreationClosed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        assertTrue(partnerFactory.isVault(address(opened)), "closing again keeps the vaults created while open");
        mandate.curator = curator;
        _create();
    }

    function testOnlyTheOwnerOpensCreation() public {
        vm.prank(curator);
        vm.expectRevert();
        partnerFactory.setOpenCreation(true);
        assertFalse(partnerFactory.openCreation());
    }

    /// @dev Vaults take deposits without a cap, and no manager can set one.
    function testDepositsHaveNoCapAndNoManagerCanSetOne() public {
        usdg.mint(alice, 5_000_000e6);
        vm.prank(alice);
        partner.deposit(2_000_000e6, 0);
        assertEq(partner.totalAssets(), 2_000_000e6);
        vm.prank(curator);
        (bool set,) = address(partner).call(abi.encodeWithSignature("setMaxTotalDeposits(uint128)", uint128(1)));
        assertFalse(set, "no deposit cap setter");
        (bool read,) = address(partner).staticcall(abi.encodeWithSignature("maxTotalDeposits()"));
        assertFalse(read, "no deposit cap");
        vm.prank(alice);
        partner.deposit(1_000_000e6, 0);
        assertEq(partner.totalAssets(), 3_000_000e6);
    }

    function testFeeBoundariesAndMissingMutationSelector() public {
        mandate.feeBps = 500;
        assertEq(_create().feeBps(), 500);
        mandate.feeBps = 1500;
        assertEq(_create().feeBps(), 1500);
        mandate.feeBps = 499;
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        mandate.feeBps = 1501;
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        vm.prank(curator);
        (bool changed,) = address(partner).call(abi.encodeWithSignature("setFee(uint16)", 500));
        assertFalse(changed);
        assertEq(partner.feeBps(), 1500);
        // The factory's published share is the one every vault's fee split applies.
        assertEq(IntentFeeMath.PROTOCOL_SHARE_BPS, 1000);
        assertEq(partnerFactory.PROTOCOL_SHARE_BPS(), IntentFeeMath.PROTOCOL_SHARE_BPS);
    }

    /// @dev The universe is fixed at creation (D41); inside it a category's weight is a risk limit like any other,
    /// lowered at once and raised after three hours, past its creation weight too (D53, IntentLimitTimelock.t.sol).
    function testCategoryLocksAndClassificationCannotBeRewritten() public {
        vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
        partnerFactory.assignCategory(address(nvda), IntentCategory.MEME);
        vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
        partnerFactory.assignCategory(address(router), IntentCategory.MEME);
        IntentAssetPolicy policy = partner.ASSET_POLICY();
        vm.startPrank(curator);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.setLimit(IntentLimits.category(IntentCategory.RH_ECOSYSTEM), 1);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.setLimit(IntentLimits.category(IntentCategory.MEME), 1);
        policy.setLimit(IntentLimits.category(IntentCategory.STOCK), 1000);
        policy.setLimit(IntentLimits.category(IntentCategory.COMMODITY), 1000);
        policy.setLimit(IntentLimits.category(IntentCategory.STOCK), 6001);
        vm.stopPrank();
        assertEq(partner.CATEGORY_MASK(), 9);
        assertEq(partner.categoryWeightBps(IntentCategory.STOCK), 1000, "the raise waits");
        assertEq(partner.categoryWeightBps(IntentCategory.COMMODITY), 1000);
        assertEq(partner.categoryWeightBps(IntentCategory.MEME), 0);
    }

    /// @dev D41: a vault lends against one universe, RWA (stocks, commodities) or RH ECO (memes, utility coins).
    function testAVaultLendsAgainstOneUniverseOnly() public {
        mandate.assets = new address[](0);
        uint16[4][5] memory mixed = [
            [uint16(10_000), 10_000, 0, 0],
            [uint16(10_000), 0, 10_000, 0],
            [uint16(0), 10_000, 0, 10_000],
            [uint16(0), 0, 10_000, 10_000],
            [uint16(10_000), 10_000, 10_000, 10_000]
        ];
        for (uint256 i; i < mixed.length; ++i) {
            mandate.categoryWeights = mixed[i];
            vm.prank(curator);
            vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
            partnerFactory.create(mandate, false, 0, "Test vault");
        }
        uint16[4][6] memory single = [
            [uint16(10_000), 0, 0, 0],
            [uint16(0), 0, 0, 10_000],
            [uint16(10_000), 0, 0, 10_000],
            [uint16(0), 10_000, 0, 0],
            [uint16(0), 0, 10_000, 0],
            [uint16(0), 10_000, 10_000, 0]
        ];
        uint8[6] memory masks = [1, 8, 9, 2, 4, 6];
        for (uint256 i; i < single.length; ++i) {
            mandate.categoryWeights = single[i];
            assertEq(_create().CATEGORY_MASK(), masks[i]);
        }
    }

    /// @dev D41: a commodity is lent under its own category and cap, beside the vault's stocks.
    function testACommodityLoanCountsAgainstTheCommodityCategory() public {
        assertEq(partnerFactory.eligibleCategory(address(gold), 9), 3);
        assertEq(partnerFactory.eligibleCategory(address(gold), 1), type(uint8).max);
        _depositPartner();
        _enableFixture();
        gold.mint(borrower, 100e18);
        vm.prank(borrower);
        gold.approve(address(core), MAX);
        // 10,000 USDG in the vault: 1,000 of commodities fits the 30% category; once the manager narrows it to 20%,
        // another 1,400 (2,400 in all) does not, while a stock loan still fits its own 60%.
        uint256 over = _list(borrower, address(gold), 10e18, 1400e6, 1470e6, T7);
        uint256 id = _list(borrower, address(gold), 10e18, 1000e6, 1050e6, T7);
        _route(id, 4);
        assertEq(partner.categoryPrincipal(IntentCategory.COMMODITY), 1000e6);
        assertEq(partner.categoryPrincipal(IntentCategory.STOCK), 0);
        IntentLimits.setCategoryWeight(partner, IntentCategory.COMMODITY, 2000);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, over, 4);
        uint256 stock = _listed(1400e6);
        _route(stock, 4);
        assertEq(partner.categoryPrincipal(IntentCategory.STOCK), 1400e6);
    }

    /// @dev D41: a stocks-only vault never takes a commodity, even through the asset picker.
    function testAStocksOnlyVaultCannotPickACommodity() public {
        mandate.categoryWeights = [uint16(10_000), 0, 0, 0];
        mandate.assets = new address[](1);
        mandate.assets[0] = address(nvda);
        IntentVault stocks = _create();
        vm.prank(curator);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        stocks.setAsset(address(gold), true);
        mandate.assets[0] = address(gold);
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
    }

    /// @dev The retired collateral grade (D132) keeps its creation floor. The risk limits have none: they tighten at
    /// once and loosen after three hours (D53, IntentLimitTimelock.t.sol).
    function testTheCollateralGradeKeepsItsCreationFloor() public {
        mandate.minGrade = 2;
        partner = _create();
        vm.startPrank(curator);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.setMinGrade(1);
        partner.setMinGrade(3);
        partner.setMinGrade(2);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(IntentVault.NotCurator.selector);
        partner.setMinGrade(3);
    }

    function testFundingStartsDisabledAndCuratorNeverBypassesRouter() public {
        _depositPartner();
        uint256 id = _listed(1000e6);
        vm.prank(curator);
        vm.expectRevert(IntentVault.NotCurator.selector);
        partner.purchase(id, 4, 0, MAX, 0);
        partnerFactory.setFiller(curator, true);
        vm.prank(curator);
        vm.expectRevert(IntentVault.NotCurator.selector);
        partner.purchase(id, 4, 0, MAX, 0);
        partnerFactory.setFillRouter(address(router));
        vm.prank(curator);
        vm.expectRevert(IntentVault.NotCurator.selector);
        router.fund(partner, id, 4);
        assertEq(partner.performingPrincipal(), 0);
        uint256 shares = partner.balanceOf(alice);
        vm.prank(alice);
        partner.redeem(shares, 0);
    }

    function testSecondFillerRevocationAndPayoutRoutingAreIndependent() public {
        _depositPartner();
        _enableFixture();
        partnerFactory.setFiller(carol, true);
        uint256 id = _listed(1000e6);
        vm.prank(carol);
        router.fund(partner, id, 4);
        partnerFactory.setFiller(carol, false);
        uint256 id2 = _listed(1000e6);
        vm.prank(carol);
        vm.expectRevert("filler denied");
        router.fund(partner, id2, 4);
        vm.warp(vm.getBlockTimestamp() + 1);
        _repay(id);
        partner.settle(_ids(id));
        assertEq(partner.performingPrincipal(), 0);
        assertEq(partner.curatorFees(), 6.75e6);
        assertEq(partner.protocolFees(), 0.75e6);
        assertFalse(partnerFactory.isCreator(carol));
    }

    function testContributionCapDoesNotRejectLargerBorrowAndCannotBeSplitByTopups() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(3000e6);
        _route(id, 2);
        assertEq(partner.performingPrincipal(), 1500e6);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, 1);
        vm.prank(curator);
        partner.withdrawCommitment(id);
        partner.settle(_ids(id));
        assertEq(partner.performingPrincipal(), 0);
        assertEq(partner.totalAssets(), 10_000e6);
    }

    function testZeroCapsCloseAndTighteningDoesNotTouchExistingPosition() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(1000e6);
        _route(id, 4);
        IntentLimits.setLimits(partner, 0, 0, 0);
        uint256 id2 = _listed(1000e6);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id2, 1);
        _repay(id);
        partner.settle(_ids(id));
        assertEq(partner.performingPrincipal(), 1000e6, "a repayment in the fill second waits for the next second");
        vm.warp(vm.getBlockTimestamp() + 1);
        partner.settle(_ids(id));
        assertEq(partner.performingPrincipal(), 0);
        // D51: the second the loan ran is in the price; the rest of its 42.5 net is its holders' claim.
        uint256 claim = partner.pocketLiability(address(usdg));
        assertApproxEqAbs(partner.totalAssets() + claim, 10_042.5e6, 1);
        vm.warp(_maturity(id));
        partner.settle(_ids(id));
        assertEq(partner.pocketLiability(address(usdg)), claim);
        assertApproxEqAbs(partner.totalAssets() + claim, 10_042.5e6, 1);
    }

    function testLpKindsRejectedEvenByAuthorizedRouter() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(1000e6);
        V2Loan memory loan = core.getLoan(id);
        for (uint8 kind = 1; kind <= 2; ++kind) {
            loan.kind = Kind(kind);
            vm.mockCall(address(core), abi.encodeWithSelector(core.getLoan.selector, id), abi.encode(loan));
            vm.prank(bob);
            vm.expectRevert(IntentVault.IneligibleDeal.selector);
            router.fund(partner, id, 4);
        }
        vm.clearMockedCalls();
        assertEq(partner.cash(), 10_000e6);
        assertEq(partner.performingPrincipal(), 0);
    }

    function testRhEcosystemNotMemeAndAssetPickerCannotBroadenMask() public {
        MockERC20 rh = new MockERC20("PONS", "PONS", 18);
        vm.prank(safe);
        registry.setERC20Allowed(address(rh), true, Lane.MEME, 1e18, 1000e18, 100_000e18);
        partnerFactory.assignCategory(address(rh), IntentCategory.RH_ECOSYSTEM);
        vm.prank(curator);
        vm.expectRevert(IntentVault.InvalidConfiguration.selector);
        partner.setAsset(address(rh), true);
        mandate.assets = new address[](1);
        mandate.assets[0] = address(rh);
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(mandate, false, 0, "Test vault");
        _depositPartner();
        _enableFixture();
        rh.mint(borrower, 100e18);
        vm.prank(borrower);
        rh.approve(address(core), MAX);
        uint256 id = _list(borrower, address(rh), 100e18, 1000e6, 1050e6, T7);
        vm.prank(bob);
        vm.expectRevert(IntentVault.IneligibleDeal.selector);
        router.fund(partner, id, 4);
    }

    function testPauseAndRoleRemovalPreserveTokenDefaultRecoveryAndExit() public {
        _depositPartner();
        _enableFixture();
        uint256 id = _listed(1000e6);
        _route(id, 4);
        partnerFactory.setFiller(bob, false);
        partnerFactory.setCreator(curator, false);
        partnerFactory.setFillRouter(address(0));
        partnerFactory.setQuoteSigner(address(0));
        vm.prank(curator);
        partner.setPaused(true);
        vm.warp(_maturity(id));
        partner.settle(_ids(id));
        partner.recover(id);
        assertEq(partner.pocketCount(), 1);
        vm.prank(alice);
        partner.claimPocket(1);
        assertEq(nvda.balanceOf(alice), 100e18);
        uint256 shares = partner.balanceOf(alice);
        vm.prank(alice);
        partner.redeem(shares, 0);
        assertEq(partner.totalSupply(), 0);
    }
}
