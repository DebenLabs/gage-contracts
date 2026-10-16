// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @dev The router Pashov's L-02, L-03 and L-05 describe: named by the factory's owner in place of the generation's
/// own, it calls the vaults directly, with no signed plan, no verifier and no sale.
contract ReplacementRouter {
    function purchase(IntentVault vault, uint256 id, uint8 units, uint256 price) external {
        vault.purchase(id, units, price, type(uint256).max, 0);
    }
}

/// @notice Pashov's final findings on the fill path, each attack shape as the report draws it.
contract IntentPashovFinalRouterTest is IntentSecondaryBaseTest {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), about 1,067 after the 1% trade fee and the seller's manager fee, as the secondary suites price it.
    uint128 internal constant PRICE = 1070e6 + 3;

    // ---------------------------------------------------------------- L-02, L-03, L-05: the factory binds its router

    /// @dev The release's two router operations still work on a bound factory: activation names the generation's
    /// own router (the first naming binds it), the emergency batch closes every fill with zero, and the same router
    /// reopens them. No other router can ever be named, before or after a close, nor by a later owner.
    function test_theFirstRouterNamedIsBoundForGood() public {
        IntentFactory fresh = _factory(address(0));
        IntentQuoteVerifier quotes = new IntentQuoteVerifier(fresh);
        IntentFillRouter own = new IntentFillRouter(quotes, IERC20(address(usdg)));
        IntentFillRouter other = new IntentFillRouter(quotes, IERC20(address(usdg)));
        address noCode = makeAddr("no code");
        assertEq(fresh.boundFillRouter(), address(0));
        // Neither a closing nor a router without code binds anything.
        fresh.setFillRouter(address(0));
        vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
        fresh.setFillRouter(noCode);
        assertEq(fresh.boundFillRouter(), address(0));

        vm.expectEmit(address(fresh));
        emit IntentFactory.FillRouterSet(address(own));
        fresh.setFillRouter(address(own));
        assertEq(fresh.boundFillRouter(), address(own));
        assertEq(fresh.fillRouter(), address(own));
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        fresh.setFillRouter(address(other));
        vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
        fresh.setFillRouter(noCode);

        // The emergency close, then the same router again.
        vm.expectEmit(address(fresh));
        emit IntentFactory.FillRouterSet(address(0));
        fresh.setFillRouter(address(0));
        assertEq(fresh.fillRouter(), address(0));
        assertEq(fresh.boundFillRouter(), address(own));
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        fresh.setFillRouter(address(other));
        fresh.setFillRouter(address(own));
        fresh.setFillRouter(address(own));
        assertEq(fresh.fillRouter(), address(own));

        // Only the owner names or closes, and a new owner inherits the binding.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        fresh.setFillRouter(address(0));
        fresh.transferOwnership(bob);
        vm.prank(bob);
        fresh.acceptOwnership();
        vm.prank(bob);
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        fresh.setFillRouter(address(other));
        vm.prank(bob);
        fresh.setFillRouter(address(0));
        assertEq(fresh.boundFillRouter(), address(own));
    }

    /// @dev The fixture's factory named its generation's router first and is bound to it: closed, nothing fills, the
    /// signed plan included; reopened with that router, the same plan fills.
    function test_closingAndReopeningFillsKeepsTheBoundRouter() public {
        assertEq(partnerFactory.boundFillRouter(), address(fills));
        uint256 id = _listing();
        (IntentVault[] memory vaults, uint8[] memory counts) = _one(first, UNITS);
        IntentQuoteVerifier.Plan memory p = _plan(id, vaults, counts);
        bytes memory signature = _sign(p);
        address rogue = address(new ReplacementRouter());
        partnerFactory.setFillRouter(address(0));
        vm.prank(p.filler);
        vm.expectRevert(IntentQuoteVerifier.NotRouter.selector);
        fills.fill(p, signature, _shares(1));
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        partnerFactory.setFillRouter(rogue);
        partnerFactory.setFillRouter(address(fills));
        vm.prank(p.filler);
        fills.fill(p, signature, _shares(1));
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
    }

    /// @dev L-03: a replacement router funds a listing the pricing service never signed. The factory names its
    /// generation's own router already, so it names no other: the vault refuses the replacement's purchase.
    function test_L03_aReplacementRouterCannotFundAListingWithoutASignedPlan() public {
        uint256 id = _listing();
        ReplacementRouter rogue = new ReplacementRouter();
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        partnerFactory.setFillRouter(address(rogue));
        assertEq(partnerFactory.fillRouter(), address(fills));

        vm.expectRevert(IntentVault.NotCurator.selector);
        rogue.purchase(first, id, UNITS, 0);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.FUNDING));
        assertEq(core.getLoan(id).filled, 0);
        assertEq(_loanOf(first, id).principal, 0);
    }

    /// @dev L-02, L-05: a replacement router takes a buyer vault's secondary price with no signed pricing and no sale:
    /// the vault books quarters it never receives and pays their price to the router. Bound, the factory names no
    /// replacement, and the vault refuses its purchase.
    function test_L02_L05_aReplacementRouterCannotTakeASecondaryPriceWithoutASale() public {
        uint256 id = _onSale(PRICE);
        uint256 price = verifier.quarterPrice(PRICE, 15, 0) + verifier.quarterPrice(PRICE, 15, 2);
        ReplacementRouter rogue = new ReplacementRouter();
        vm.expectRevert(IntentFactory.FillRouterBound.selector);
        partnerFactory.setFillRouter(address(rogue));
        assertEq(partnerFactory.fillRouter(), address(fills));

        uint256 assets = buyerA.totalAssets();
        uint256 held = usdg.balanceOf(address(buyerA));
        vm.expectRevert(IntentVault.NotCurator.selector);
        rogue.purchase(buyerA, id, 5, price);
        assertEq(usdg.balanceOf(address(rogue)), 0);
        assertEq(usdg.balanceOf(address(buyerA)), held);
        assertEq(buyerA.totalAssets(), assets);
        assertEq(_loanOf(buyerA, id).principal, 0);
        address[4] memory owners = core.lenders(id);
        for (uint256 q; q < 4; ++q) {
            assertEq(owners[q], address(seller), "the seller keeps every quarter");
        }
        // The honest path still buys the listing, through the bound router and a signed plan.
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        _buy(p);
        assertEq(core.lenders(id)[0], address(buyerA));
    }

    // ---------------------------------------------------------------- L-01: no sale to the seller's own curator

    function _whole(IntentVault vault) internal pure returns (IntentVault[] memory vaults, uint8[] memory masks) {
        vaults = new IntentVault[](1);
        masks = new uint8[](1);
        (vaults[0], masks[0]) = (vault, 15);
    }

    /// @dev L-01: a curator sells its depositors' position at book to a second vault it runs. The verifier refuses
    /// a buyer vault run by the seller's curator as it refuses the seller itself, at the preflight and at execution,
    /// alone or beside an independent buyer; nothing moves and the listing stays for sale.
    function test_L01_aVaultRunByTheSellersCuratorCannotBuyItsListing() public {
        uint256 id = _onSale(PRICE);
        // The seller itself, refused as before.
        (IntentVault[] memory vaults, uint8[] memory masks) = _whole(seller);
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.SELLER_IS_BUYER);

        IntentVault own = _buyerRunBy(seller.CURATOR(), 2000e6);
        assertTrue(address(own) != address(seller));
        (vaults, masks) = _whole(own);
        p = _marketPlan(id, vaults, masks);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.SELLER_IS_BUYER);

        IntentVault outside = _buyerRunBy(makeAddr("independent curator"), 2000e6);
        vaults = new IntentVault[](2);
        masks = new uint8[](2);
        (vaults[0], masks[0]) = (own, 1);
        (vaults[1], masks[1]) = (outside, 14);
        p = _marketPlan(id, vaults, masks);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.SELLER_IS_BUYER);
        assertEq(_loanOf(own, id).principal, 0);
        assertEq(_loanOf(outside, id).principal, 0);
        address[4] memory owners = core.lenders(id);
        for (uint256 q; q < 4; ++q) {
            assertEq(owners[q], address(seller), "the seller keeps every quarter");
        }
        (uint128 listed,,,,) = sellerMarket.asks(id);
        assertEq(listed, PRICE, "still listed");
    }

    /// @dev A vault run by another curator still buys the same listing whole.
    function test_L01_aVaultRunByAnotherCuratorStillBuys() public {
        uint256 id = _onSale(PRICE);
        IntentVault outside = _buyerRunBy(makeAddr("independent curator"), 2000e6);
        assertTrue(outside.CURATOR() != seller.CURATOR());
        (IntentVault[] memory vaults, uint8[] memory masks) = _whole(outside);
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        assertEq(uint8(_secondaryReason(p)), uint8(IntentQuoteVerifier.Refusal.NONE));
        _buy(p);
        address[4] memory owners = core.lenders(id);
        for (uint256 q; q < 4; ++q) {
            assertEq(owners[q], address(outside));
        }
        assertEq(_loanOf(outside, id).principal, PRICE);
    }
}
