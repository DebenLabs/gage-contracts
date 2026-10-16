// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IFunderGate} from "../../src/interfaces/IFunderGate.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @notice Vaults-only lending on the real Intent contracts: the core's ledger is bound to the partner factory, so the
/// factory's vaults fund listings and buy listed positions as before, and a wallet can do neither.
contract IntentVaultsOnlyTest is IntentSecondaryBaseTest {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), an asking price of about 1,067 after the 1% trade fee and the seller's manager fee; the odd
    /// units exercise the per-quarter remainder rule.
    uint128 internal constant PRICE = 1070e6 + 3;
    GageV2Rewards internal ledger;

    function _opensCoreToEveryone() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        ledger = core.REWARDS();
        vm.prank(safe);
        ledger.bindFunderGate(IFunderGate(address(partnerFactory)));
    }

    function test_theCoreIsBoundToThePartnerFactory() public view {
        assertEq(address(ledger.funderGate()), address(partnerFactory));
        ledger.requireFunder(address(seller));
    }

    function test_partnerVaultsStillFundAListingWhole() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(seller, 4);
        _fill(_plan(id, vaults, counts));
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
        assertEq(core.unitsOf(id, address(seller)), 4);
    }

    function test_aWalletCannotFundAListing() public {
        uint256 id = _listing();
        vm.prank(alice);
        usdg.approve(address(core), MAX);
        vm.prank(alice);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        core.fund(id, 1);
        assertEq(core.getLoan(id).filled, 0);
    }

    function test_partnerVaultsStillBuyAListedPositionSplit() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        _buy(_marketPlan(id, vaults, masks));
        assertEq(core.unitsOf(id, address(buyerA)), 2);
        assertEq(core.unitsOf(id, address(buyerB)), 1);
        assertEq(core.unitsOf(id, address(buyerC)), 1);
        assertEq(core.unitsOf(id, address(seller)), 0);
    }

    function test_aWalletCannotBuyAVaultsListedPosition() public {
        uint256 id = _onSale(PRICE);
        (,,,, uint64 nonce) = sellerMarket.asks(id);
        vm.prank(alice);
        usdg.approve(address(sellerMarket), MAX);
        uint128[4] memory none;
        vm.prank(alice);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        sellerMarket.buySplit(id, nonce, PRICE, [alice, alice, alice, alice], none);
        assertEq(core.unitsOf(id, address(seller)), 4, "the listing stays with the seller");
    }

    function test_aWalletCannotAssignUnbookedQuartersToAnotherFactoryVault() public {
        uint256 id = _onSale(PRICE);
        (,,,, uint64 nonce) = sellerMarket.asks(id);
        uint256 payerBalance = usdg.balanceOf(alice);
        uint256 buyerAssets = buyerA.totalAssets();
        vm.prank(alice);
        usdg.approve(address(sellerMarket), MAX);
        uint128[4] memory none;
        vm.prank(alice);
        vm.expectRevert(IntentLenderMarket.UnbookedRecipient.selector);
        sellerMarket.buySplit(
            id, nonce, PRICE, [address(buyerA), address(buyerA), address(buyerA), address(buyerA)], none
        );
        assertEq(sellerMarket.nonces(id), nonce, "failed sale did not consume the ask");
        assertEq(usdg.balanceOf(alice), payerBalance, "payer did not spend");
        assertEq(buyerA.totalAssets(), buyerAssets, "recipient accounting stayed unchanged");
        assertEq(_loanOf(buyerA, id).principal, 0, "recipient has no loan record");
        assertEq(core.unitsOf(id, address(seller)), 4, "seller kept the position");
        assertEq(core.unitsOf(id, address(buyerA)), 0, "recipient received no quarters");
    }

    function test_oneFactoryVaultInASplitAlsoBlocksADirectBuyer() public {
        uint256 id = _onSale(PRICE);
        (,,,, uint64 nonce) = sellerMarket.asks(id);
        vm.prank(alice);
        usdg.approve(address(sellerMarket), MAX);
        uint128[4] memory none;
        vm.prank(alice);
        vm.expectRevert(IntentLenderMarket.UnbookedRecipient.selector);
        sellerMarket.buySplit(id, nonce, PRICE, [alice, address(buyerA), alice, alice], none);
        assertEq(core.unitsOf(id, address(seller)), 4);
    }

    /// @dev A direct buyer cannot substitute any other recipient, even one the core would reject independently.
    function test_marketRefusesRecipientSubstitutionBeforeCoreTransfer() public {
        uint256 id = _onSale(PRICE);
        (,,,, uint64 nonce) = sellerMarket.asks(id);
        vm.prank(alice);
        usdg.approve(address(sellerMarket), MAX);
        _refusedRecipient(id, nonce, address(sellerMarket));
        _refusedRecipient(id, nonce, address(seller));
        _refusedRecipient(id, nonce, address(0));
        _refusedRecipient(id, nonce, address(core));
    }

    function _refusedRecipient(uint256 id, uint64 nonce, address recipient) internal {
        uint128[4] memory none;
        vm.prank(alice);
        vm.expectRevert(IntentLenderMarket.UnbookedRecipient.selector);
        sellerMarket.buySplit(id, nonce, PRICE, [recipient, recipient, recipient, recipient], none);
        address[4] memory lenders = core.lenders(id);
        for (uint8 i; i < 4; ++i) {
            assertEq(lenders[i], address(seller), "the listing stays with the seller");
        }
    }

    function test_aVaultOfAnotherFactoryCannotLend() public {
        IntentFactory other = _factory(address(0));
        other.assignCategory(address(nvda), IntentCategory.STOCK);
        other.assignCategory(address(gold), IntentCategory.COMMODITY);
        other.setCreator(curator, true);
        vm.prank(curator);
        IntentVault stranger = IntentVault(other.create(mandate, false, 0, "Test vault"));
        assertFalse(partnerFactory.isVault(address(stranger)));
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        ledger.requireFunder(address(stranger));
    }

    function test_openCreationStillLendsOnlyThroughTheFactory() public {
        address anyone = makeAddr("any manager");
        partnerFactory.setOpenCreation(true);
        mandate.curator = anyone;
        vm.prank(anyone);
        IntentVault opened = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
        ledger.requireFunder(address(opened));
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        ledger.requireFunder(anyone);
    }

    /// @dev Keeps the refusal list honest: a bound core adds no verifier reason, it only refuses at the core.
    function test_boundCoreAddsNoPlanRefusal() public {
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(seller, 4);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        assertEq(uint8(_reason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
    }
}
