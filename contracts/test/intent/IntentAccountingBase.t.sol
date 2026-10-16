// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {MockFeeProcessor} from "../mocks/MockFeeProcessor.sol";
import {EarnV3BaseTest} from "../earn/EarnV3Base.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {ReserveLensMock} from "../mocks/ReserveLensMock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @dev Test-only stand-in for the S3/S4 router: it authenticates the filler and forwards the purchase with the
/// execution fee the test names. No quote, no cap, no floor, no atomic completion.
contract IntentAccountingRouter {
    IntentFactory internal immutable FACTORY;

    constructor(IntentFactory factory) {
        FACTORY = factory;
    }

    function fund(IntentVault vault, uint256 id, uint8 units, uint256 executionFee) external {
        require(FACTORY.isFiller(msg.sender), "filler denied");
        vault.purchase(id, units, 0, type(uint256).max, executionFee);
    }

    function investReserve(IntentVault vault, uint256 assets) external {
        require(FACTORY.isFiller(msg.sender), "filler denied");
        vault.investReserve(assets, 0);
    }
}

/// @notice S2 fixture: one partner vault at a 10% fee, the documented review loan, and a test-only router.
/// @dev The router fixture only authenticates the filler; it is not the S3 quote or S4 atomic execution router.
abstract contract IntentAccountingBaseTest is EarnV3BaseTest {
    using stdStorage for StdStorage;

    /// @dev Where the protocol's USDG goes: a stand-in for `DealFeeRouter`, the only kind of address the factory accepts.
    address internal feeProcessor;
    uint256 internal constant REVIEW_PRINCIPAL = 1000e6;
    uint256 internal constant REVIEW_CAP = 1100e6;
    /// @dev 100 gross less the 10% fee.
    uint256 internal constant REVIEW_NET = 90e6;

    IntentFactory internal partnerFactory;
    IntentVault internal partner;
    IntentVault.Mandate internal mandate;
    IntentAccountingRouter internal router;
    /// @dev A commodity token: the stock lane on the core, its own Intent category beside stocks (D41).
    MockERC20 internal gold;

    function setUp() public virtual override {
        super.setUp();
        // Deployed from its own address so this contract's nonce, and every fixture address after it, is unchanged:
        // plans list vaults in address order, and the suites' expected fees follow that order.
        vm.prank(makeAddr("commodity issuer"));
        gold = new MockERC20("Gold", "GLDx", 18);
        vm.prank(safe);
        registry.setERC20Allowed(address(gold), true, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        _vaultCode();
        feeProcessor = address(new MockFeeProcessor(address(usdg)));
        // The local reserve reports zero max views the way Morpho Vault V2 does, so its factory names a lens.
        _stand(address(new ReserveLensMock()));
    }

    /// @dev A factory that measures the reserve through `lens` (zero reads the reserve's own max views), with its
    /// categories, one creator, one vault, a router and a filler.
    function _stand(address lens) internal {
        partnerFactory = _factory(lens);
        partnerFactory.assignCategory(address(nvda), IntentCategory.STOCK);
        partnerFactory.assignCategory(address(meme), IntentCategory.MEME);
        partnerFactory.assignCategory(address(gold), IntentCategory.COMMODITY);
        partnerFactory.setCreator(curator, true);
        _configure();
    }

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

    function _factory(address lens) internal returns (IntentFactory) {
        return new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: address(reserve),
                reserveLens: lens,
                grades: address(grades),
                protocolRecipient: feeProcessor,
                initialOwner: address(this),
                codeA: _codeA(),
                codeB: _codeB()
            })
        );
    }

    /// @dev One vault, a router and a filler on `partnerFactory`.
    function _configure() internal {
        // Fixture values are not protocol launch defaults.
        mandate = IntentVault.Mandate({
            curator: curator,
            categoryWeights: [uint16(10_000), 0, 0, 10_000],
            assets: new address[](2),
            maxLoanTerm: T21,
            feeBps: 1000,
            minGrade: 0,
            minRateGrade: 0,
            maxLoanPrincipal: uint128(1_000_000e6 * _cashScale()),
            maxAssetBps: 10_000,
            bufferBps: 0,
            // The widest ceiling the code allows, so the accounting suites can name any fee under it. Not a launch value.
            executionCapBps: IntentFeeMath.MAX_EXECUTION_CAP_BPS
        });
        mandate.assets[0] = address(nvda);
        mandate.assets[1] = address(gold);
        vm.prank(curator);
        partner = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
        address[3] memory depositors = [alice, bob, carol];
        for (uint256 i; i < depositors.length; ++i) {
            vm.prank(depositors[i]);
            usdg.approve(address(partner), MAX);
        }
        router = new IntentAccountingRouter(partnerFactory);
        if (_namesStandInRouter()) partnerFactory.setFillRouter(address(router));
        partnerFactory.setQuoteSigner(address(0x5151));
        partnerFactory.setFiller(fillers[0], true);
    }

    /// @dev Whether `_configure` names the stand-in router. A suite with a router of its own names that one first
    /// instead, as a release names its generation's: the factory binds the first router it names (L-02, L-03, L-05).
    function _namesStandInRouter() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Test-only: name `next` on `partnerFactory` as though no router had been named before. A factory binds its
    /// first router for good and no account can lift that; the suites that put the stand-in beside the real router, or
    /// a router over another verifier, clear the binding in storage here.
    function _rebindFillRouter(address next) internal {
        stdstore.target(address(partnerFactory)).sig(partnerFactory.boundFillRouter.selector).checked_write(address(0));
        partnerFactory.setFillRouter(next);
    }

    function _enter(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = partner.deposit(assets, 0);
    }

    function _exit(address who, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = partner.redeem(shares, 0);
    }

    function _exitAll(address who) internal returns (uint256 assets) {
        uint256 shares = partner.balanceOf(who);
        assets = _exit(who, shares);
    }

    function _route(uint256 id, uint8 units) internal {
        _route(id, units, 0);
    }

    function _route(uint256 id, uint8 units, uint256 executionFee) internal {
        vm.prank(fillers[0]);
        router.fund(partner, id, units, executionFee);
    }

    function _invest(uint256 assets) internal {
        vm.prank(fillers[0]);
        router.investReserve(partner, assets);
    }

    function _book(uint256 id) internal {
        partner.settle(_ids(id));
    }

    function _claimOf(address who) internal view returns (uint256) {
        return partner.convertToAssets(partner.balanceOf(who));
    }

    /// @dev Every claim `who` can make now, over every side pocket (D51 earnings and recovered collateral alike).
    function _claimable(address who) internal view returns (uint256 total) {
        uint256 n = partner.pocketCount();
        for (uint256 i = 1; i <= n; ++i) {
            total += partner.pocketClaimable(i, who);
        }
    }

    /// @dev Claim every side pocket `who` has a part of; returns what was paid.
    function _claimAll(address who) internal returns (uint256 total) {
        uint256 n = partner.pocketCount();
        for (uint256 i = 1; i <= n; ++i) {
            if (partner.pocketClaimable(i, who) == 0) continue;
            vm.prank(who);
            total += partner.claimPocket(i);
        }
    }

    /// @dev What `who` leaves with: its shares redeemed in full and every claim collected.
    function _leave(address who) internal returns (uint256) {
        return _exitAll(who) + _claimAll(who);
    }

    struct LoanView {
        bool settled;
        bool repaid;
        uint40 maturity;
        uint128 principal;
        uint128 interest;
        uint128 rate;
        uint128 executionFee;
        bool executionEarned;
    }

    function _ln(uint256 id) internal view returns (LoanView memory v) {
        (,,, v.maturity,, v.settled,, v.repaid,, v.principal,, v.interest, v.rate,, v.executionFee, v.executionEarned) =
            partner.loans(id);
    }

    /// @dev When the loan activated, read from the core. Tests anchor every warp here: under the IR pipeline a local
    /// copy of `block.timestamp` is re-read after a warp, so it cannot hold a starting time.
    function _startOf(uint256 id) internal view returns (uint256) {
        return core.getLoan(id).fundedAt;
    }

    /// @dev Net interest a loan has earned after `elapsed` seconds of a `term`-second schedule, rounded down.
    function _scheduled(uint256 interest, uint256 elapsed, uint256 term) internal pure returns (uint256) {
        return interest * elapsed / term;
    }

    /// @dev The review loan: 1,000 USDG for 21 days at a 100 USDG fixed cost, fully funded by the vault.
    function _reviewLoan() internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 100e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21);
        _route(id, UNITS);
    }
}
