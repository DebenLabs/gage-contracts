// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {Handler} from "./Handler.sol";
import {DealState, Deal, BidState, Bid} from "../../src/interfaces/IDealVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Spec 9 invariants I1, I3, I4, I5, I6, I7, I8 and I12 as stateful properties over random call sequences.
///         I2 (no admin path to user funds) and I11 (no oracle) are structural and reviewed by reading the code:
///         the vault has no owner and reads no price. I9 and I10's NFT branch arrive with M2.
contract DealVaultInvariants is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();

        MockERC20[] memory tokens = new MockERC20[](2);
        tokens[0] = nvda;
        tokens[1] = aapl;
        address[] memory actors = new address[](4);
        actors[0] = borrower;
        actors[1] = lender;
        actors[2] = lender2;
        actors[3] = other;

        handler = new Handler(vault, registry, feeSink, usdg, tokens, actors);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = Handler.list.selector;
        selectors[1] = Handler.bid.selector;
        selectors[2] = Handler.withdrawBid.selector;
        selectors[3] = Handler.accept.selector;
        selectors[4] = Handler.reclaim.selector;
        selectors[5] = Handler.claim.selector;
        selectors[6] = Handler.cancel.selector;
        selectors[7] = Handler.withdrawUSDG.selector;
        selectors[8] = Handler.withdrawERC20.selector;
        selectors[9] = Handler.collectFees.selector;
        selectors[10] = Handler.warp.selector;
        selectors[11] = Handler.bid.selector; // weight bids a little higher so deals get funded
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev I5: vault USDG >= open bid escrows + every internal balance. With the mock there is no other inflow,
    ///      so the two sides are equal.
    function invariant_I5_solvency() public view {
        uint256 owed = handler.ghost_openBidEscrow() + handler.ghost_sumBalanceUSDG();
        assertGe(usdg.balanceOf(address(vault)), owed, "I5: insolvent");
        assertEq(usdg.balanceOf(address(vault)), owed, "USDG appeared or vanished");
    }

    /// @dev I1: collateral is escrowed in LISTED/FUNDED deals or credited to a balance, and nowhere else.
    ///      openRaw tracks exactly what is in open deals and never exceeds the registry cap (I12).
    function invariant_I1_collateralConserved() public view {
        MockERC20[] memory tokens = handler.tokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = address(tokens[i]);
            uint256 escrowed = handler.ghost_escrowed(t);
            assertEq(tokens[i].balanceOf(address(vault)), escrowed + handler.ghost_sumBalanceERC20(t), "I1: leak");
            assertEq(vault.openRaw(t), escrowed, "openRaw drift");
            assertLe(vault.openRaw(t), registry.getERC20Config(t).maxOpenRaw, "open cap breached");
        }
    }

    /// @dev I6, I7: a claim never lands before expiry + grace; a deal that settled has one lender, one price,
    ///      and one funding time; RECLAIMED and CLAIMED are mutually exclusive because state is single-valued.
    function invariant_I7_settlementRules() public view {
        uint256 n = handler.dealIdsLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.dealIds(i);
            Deal memory d = vault.getDeal(id);
            assertTrue(d.state != DealState.NONE, "deal vanished");
            if (d.state == DealState.LISTED || d.state == DealState.CANCELLED) {
                assertEq(d.fundedAt, 0);
                assertEq(d.lender, address(0));
                assertEq(d.price, 0);
            } else {
                assertGt(d.fundedAt, 0);
                assertTrue(d.lender != address(0));
                assertGt(d.price, 0);
                assertLe(d.price, d.cap, "price above cap");
                assertEq(d.expiry, d.fundedAt + d.term, "expiry drift");
                assertEq(vault.claimableAt(id), uint256(d.expiry) + GRACE);
            }
            if (d.state == DealState.CLAIMED) {
                assertGe(handler.ghost_claimedAt(id), vault.claimableAt(id), "I7: claimed inside grace");
            }
        }
    }

    /// @dev I4, I8: exactly one ACCEPTED bid per funded deal, matching the deal's lender and price; none otherwise.
    function invariant_I8_oneAcceptedBidPerFundedDeal() public view {
        uint256 nDeals = handler.dealIdsLength();
        uint256 nBids = handler.bidIdsLength();
        for (uint256 i = 0; i < nDeals; ++i) {
            uint256 dealId = handler.dealIds(i);
            Deal memory d = vault.getDeal(dealId);
            uint256 accepted;
            for (uint256 j = 0; j < nBids; ++j) {
                Bid memory b = vault.getBid(handler.bidIds(j));
                if (b.dealId != dealId) continue;
                assertTrue(b.state != BidState.NONE, "bid vanished");
                assertLe(b.price, d.cap, "I8: bid above cap");
                if (b.state == BidState.ACCEPTED) {
                    accepted++;
                    assertEq(b.lender, d.lender, "accepted bid lender mismatch");
                    assertEq(b.price, d.price, "accepted bid price mismatch");
                    assertEq(handler.ghost_acceptedBidOf(dealId), handler.bidIds(j));
                }
            }
            bool funded = d.state == DealState.FUNDED || d.state == DealState.RECLAIMED || d.state == DealState.CLAIMED;
            assertEq(accepted, funded ? 1 : 0, "accepted bid count");
        }
    }

    /// @dev Fees credited at accept are either still in the FeeSink's vault balance or have been collected.
    function invariant_feesAccounted() public view {
        assertEq(
            vault.balanceUSDG(address(feeSink)) + handler.ghost_feesCollected(),
            handler.ghost_feesCredited(),
            "fee accounting"
        );
    }

    /// @dev Counters are the same on both sides of the boundary: no id is ever skipped or reused.
    function invariant_counters() public view {
        assertEq(vault.dealCount(), handler.dealIdsLength());
        assertEq(vault.bidCount(), handler.bidIdsLength());
    }
}
