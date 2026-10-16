// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentRevenueTest} from "./IntentRevenue.t.sol";
import {IntentPlanBaseTest} from "./IntentPlanBase.t.sol";
import {IntentSecondaryPlanner} from "./IntentSecondaryBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @notice S9-08: a secondary purchase's execution fees join the one owed ledger of the fill router, reach the existing
/// processor whole when Gage fills, are claimed once, and become GAGE/sGAGE floor liquidity in a later batch; an
/// external filler keeps its configured share. The processor, floor and pools are the real contracts of the S7
/// fixture; the split is a fixture value, not a launch value.
contract IntentSecondaryRevenueTest is IntentRevenueTest, IntentSecondaryPlanner {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), an asking price of about 1,067 after the 1% trade fee and the seller's manager fee; the odd
    /// units exercise the per-quarter remainder rule.
    uint128 internal constant PRICE = 1070e6 + 3;

    function setUp() public override(IntentRevenueTest, IntentPlanBaseTest) {
        IntentRevenueTest.setUp();
        _standSecondary();
    }

    function _deployRouter() internal override(IntentRevenueTest, IntentPlanBaseTest) returns (address) {
        return IntentRevenueTest._deployRouter();
    }

    function _fill(IntentQuoteVerifier.Plan memory p) internal override(IntentRevenueTest, IntentPlanBaseTest) {
        IntentRevenueTest._fill(p);
    }

    function _assertRefused(IntentQuoteVerifier.Plan memory p, IntentQuoteVerifier.Refusal expected)
        internal
        override(IntentRevenueTest, IntentPlanBaseTest)
    {
        IntentRevenueTest._assertRefused(p, expected);
    }

    function _secondaryRouter() internal view override returns (IntentFillRouter) {
        return fills;
    }

    /// @dev One 2/1/1 secondary purchase by `filler`; returns the execution fee it earned and what it credited to
    /// the processor and to the external payout.
    function _secondaryEarn(address filler) internal returns (uint256 fee, uint256 toProcessor, uint256 toExternal) {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        p.filler = filler;
        for (uint256 i; i < p.allocations.length; ++i) {
            fee += p.allocations[i].executionFee;
        }
        uint256 processorBefore = fills.owed(address(processor));
        uint256 externalBefore = fills.owed(externalPayout);
        _buy(p);
        toProcessor = fills.owed(address(processor)) - processorBefore;
        toExternal = fills.owed(externalPayout) - externalBefore;
    }

    function test_gageSecondaryFeeIsOwedWholeToTheProcessorAndClaimedOnce() public {
        (uint256 fee, uint256 toProcessor, uint256 toExternal) = _secondaryEarn(fillers[0]);
        assertGt(fee, 0);
        // Both of Gage's portions sit in the processor's one entry.
        assertEq(toProcessor, fee, "the whole fee, filler part included");
        assertEq(toExternal, 0);
        assertEq(fills.totalOwed(), fills.owed(address(processor)));
        uint256 available = processor.availableUSDG();
        uint256 owed = fills.owed(address(processor));
        assertEq(fills.claim(address(processor)), owed);
        assertEq(processor.availableUSDG() - available, owed, "a plain transfer the processor counts");
        assertEq(fills.totalOwed(), 0);
        assertEq(usdg.balanceOf(address(fills)), 0);
        vm.expectRevert(IntentFillRouter.NothingOwed.selector);
        fills.claim(address(processor));
    }

    /// @dev D49: there is no filler share, so even an admitted outside filler's secondary fee goes whole to the
    /// protocol recipient, the processor.
    function test_anOutsideFillerEarnsNoShareOfASecondaryFee() public {
        (uint256 fee, uint256 toProcessor, uint256 toExternal) = _secondaryEarn(fillers[1]);
        assertGt(fee, 0);
        assertEq(toExternal, 0, "no filler share");
        assertEq(toProcessor, fee, "the protocol recipient takes the whole fee");
    }

    function test_primaryAndSecondaryFeesShareOneLedgerWithoutDuplication() public {
        uint256 primary = _earn(fillers[0], 1000e6);
        (uint256 secondary,,) = _secondaryEarn(fillers[0]);
        assertEq(fills.totalOwed(), fills.owed(address(processor)));
        assertEq(usdg.balanceOf(address(fills)), fills.totalOwed(), "held exactly what is owed");
        // The secondary fixture's seller funding was itself a primary fill; everything is one sum, counted once.
        assertGe(fills.totalOwed(), primary + secondary);
        uint256 all = fills.totalOwed();
        assertEq(fills.claim(address(processor)), all);
        assertEq(fills.totalOwed(), 0);
    }

    function test_secondaryFeesJoinALaterBatchAndBecomeFloorLiquidity() public {
        (uint256 fee,,) = _secondaryEarn(fillers[0]);
        uint256 claimed = fills.claim(address(processor));
        assertGe(claimed, fee);
        // Below the threshold the fee waits; a failed processing call moves nothing and the sale stands.
        uint256 pot = processor.availableUSDG();
        if (pot < THRESHOLD) {
            vm.expectRevert(abi.encodeWithSelector(DealFeeRouter.BelowThreshold.selector, pot, THRESHOLD));
            processor.process(pot);
            assertEq(processor.availableUSDG(), pot, "still held");
            assertEq(core.unitsOf(1, address(buyerA)) + core.unitsOf(2, address(buyerA)), 2, "the purchase stands");
            // Other protocol fees lift the pot; the processor mixes sources, the router's receipts stay separate.
            _dealFee();
            pot = processor.availableUSDG();
        }
        assertGe(pot, THRESHOLD);
        Route memory a = _route();
        ClipReceipt memory r = _process(stranger, pot);
        Route memory b = _route();
        _assertReconciled(a, b, r, pot);
        assertEq(b.floorCount, 1, "a GAGE/sGAGE floor band holds the processed fees");
        assertGt(r.bandLiquidity, 0);
    }

    /// A swap that cannot meet its minimum reverts inside the processor and moves nothing; the bought quarters stay
    /// with their buyers, the claimed fee stays in the processor, and a smaller clip of the same pot goes through.
    function test_aFailedFloorSwapAfterASecondaryFeeIsRetriedAndThePurchaseStands() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        _buy(_marketPlan(id, vaults, masks));
        address[4] memory owners = core.lenders(id);
        uint256 claimed = fills.claim(address(processor));
        _dealFee();
        uint256 pot = processor.availableUSDG();
        // Other fees make a pot of 5,000 USDG, about 2 ETH: more than the GAGE/ETH pool takes inside a 1% impact.
        usdg.mint(address(feeSink), 5000e6 - pot);
        pot = processor.availableUSDG();
        assertEq(pot, 5000e6);
        assertGe(pot, claimed);

        Route memory a = _route();
        vm.expectPartialRevert(IV4SwapperErrors.TooLittleOut.selector);
        processor.process(pot);
        assertTrue(_same(a, _route()), "nothing moved: balances, batch, counters, upstream sources");
        address[4] memory after_ = core.lenders(id);
        for (uint256 q; q < 4; ++q) {
            assertEq(after_[q], owners[q], "the purchase stands");
        }
        assertEq(fills.totalOwed(), 0, "the claim is not undone and cannot be repeated");

        ClipReceipt memory r = _process(stranger, 500e6);
        Route memory b = _route();
        _assertReconciled(a, b, r, 500e6);
        assertEq(b.batchRemaining, pot - 500e6, "the rest waits in the open batch");
        assertGt(r.bandLiquidity, 0);
    }
}
