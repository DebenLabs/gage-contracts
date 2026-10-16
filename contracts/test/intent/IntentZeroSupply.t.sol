// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";

/// @notice S8 finding, closed: `IntentVault` lends nothing while nobody holds a share: `fund` reverts `NoHolders()`
/// whoever asks and whatever is still priced. Every view is as it was, so an empty vault still reports the dust it
/// holds as free liquidity; a quote service should refuse a vault whose supply is zero before it asks. Before the
/// guard these two cases booked an early repayment nobody was there to earn, which the next depositor took in one
/// block, and recovered a default's collateral into a pocket nobody could ever claim
/// (docs/intent-v1/evidence/s8-zero-supply-finding.json; S2 policy note, rule 8).
/// @dev After the last holder leaves, redemption rounding can keep a raw USDG unit priced with zero supply. A donation
/// to a reserve the vault is the only holder of, which is what the invariant handler does, turns that unit into an
/// amount worth lending. On the live Morpho reserve a donation is shared with every other holder.
contract IntentZeroSupplyTest is IntentAccountingBaseTest {
    /// @dev The last holder leaves, the dust is invested, the reserve gains: assets priced, and owned by nobody.
    function _ownerlessAssets() internal {
        _enter(alice, 10_000e6);
        // A redemption rounds down against the redeemer, so an uneven partial exit leaves a unit behind for good.
        _exit(alice, 3_333_333_333_333_333_333_333);
        _exitAll(alice);
        assertEq(partner.totalSupply(), 0, "nobody holds a share");
        assertEq(partner.cash(), 1, "one raw unit of redemption rounding stays priced");
        _invest(1);
        usdg.mint(address(this), 500e6);
        usdg.approve(address(reserve), 500e6);
        reserve.donate(500e6);
        // The mock reserve's own virtual shares keep half of a donation made while the vault's unit is all it holds.
        assertGt(partner.totalAssets(), 200e6, "assets no share owns");
    }

    function _refused(uint256 id, uint8 units) internal {
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.NoHolders.selector);
        router.fund(partner, id, units, 0);
    }

    function testNothingIsLentWhileNobodyHoldsAShareSoNoClaimOpensWithoutAHolder() public {
        _ownerlessAssets();
        assertGt(partner.freeLiquidity(), 200e6, "the views are unchanged: priced and liquid, and still not lendable");
        uint256 id = _list(borrower, address(nvda), 100e18, 200e6, 220e6, T21);
        _refused(id, UNITS);
        _refused(id, 1);
        assertEq(partner.performingPrincipal() + partner.pocketCount() + partner.executionPending(), 0);

        // A holder arrives: the vault lends again, and an early repayment now has someone to earn it.
        uint256 shares = _enter(bob, 10_000e6);
        assertGt(partner.freeLiquidity(), 10_000e6, "liquid again, the ownerless part included");
        _route(id, UNITS);
        vm.warp(_startOf(id) + 3 days);
        _repay(id);
        _book(id);
        assertGt(partner.pocketLiability(address(usdg)), 0);
        assertGt(partner.pocketClaimable(1, bob), 0, "an earnings claim opens only with a holder to own it");
        // A same-block round trip by anybody else takes none of it.
        uint256 entered = _enter(carol, 10_000e6);
        vm.prank(carol);
        assertLe(partner.redeem(entered, 0), 10_000e6, "no windfall");
        assertEq(partner.pocketClaimable(1, carol), 0);
        // The last holder leaves with its price part and keeps its claim; the vault is closed to fills again.
        _exit(bob, shares);
        assertEq(partner.totalSupply(), 0);
        assertGt(_claimAll(bob), 0, "the last holder's claim");
        uint256 closed = _list(borrower, address(nvda), 100e18, 200e6, 220e6, T21);
        _refused(closed, UNITS);
    }

    function testNoDefaultCanBeBookedForASupplyOfRecordOfZero() public {
        _ownerlessAssets();
        uint256 id = _list(borrower, address(nvda), 100e18, 200e6, 220e6, T21);
        _refused(id, UNITS);
        // Other lenders take the listing and it defaults: the vault holds no part of it, so there is nothing to
        // write off, no pocket to open and no collateral to strand.
        _fill(id);
        vm.warp(_maturity(id));
        vm.expectRevert(IntentVault.UnknownDeal.selector);
        partner.settle(_ids(id));
        vm.expectRevert(IntentVault.NothingToRecover.selector);
        partner.recover(id);
        assertEq(partner.pocketCount(), 0);
        assertEq(nvda.balanceOf(address(partner)), 0);

        // With a holder the same default is written off for holders of record who exist, and they are paid in kind.
        _enter(bob, 10_000e6);
        uint256 next = _list(borrower, address(nvda), 100e18, 200e6, 220e6, T21);
        _route(next, UNITS);
        vm.warp(_maturity(next));
        _book(next);
        partner.recover(next);
        (,, uint256 amount, uint256 supply,,) = partner.pockets(1);
        assertEq(amount, 100e18);
        assertEq(supply, partner.totalSupply(), "a supply of record that exists");
        vm.prank(bob);
        assertEq(partner.claimPocket(1), 100e18);
    }
}
