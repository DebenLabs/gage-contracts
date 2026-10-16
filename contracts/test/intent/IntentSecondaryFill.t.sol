// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentLimits} from "../helpers/IntentLimits.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @dev A seller vault's market with one delivery bug: each listed quarter goes to the recipient named for the next
/// quarter. Its storage layout is `IntentLenderMarket`'s, so it stands in for the seller's own market with `vm.etch`;
/// the rest (one ask, one payment, the seller's own booking of the sale) is as the real market does it.
contract MisdeliveringMarket {
    using SafeERC20 for IERC20;

    mapping(uint256 => IntentLenderMarket.Ask) public asks;
    mapping(uint256 => uint64) public nonces;
    address[4] internal _recipients;
    uint128[4] internal _minRewards;
    IntentVault internal immutable SELLER;
    GageV2Vault internal immutable CORE;

    constructor(GageV2Vault core) {
        SELLER = IntentVault(msg.sender);
        CORE = core;
    }

    function buySplit(uint256 id, uint64, uint128 price, address[4] calldata recipients, uint128[4] calldata minRewards)
        external
        returns (uint256)
    {
        IntentLenderMarket.Ask memory ask = asks[id];
        for (uint8 i; i < 4; ++i) {
            _recipients[i] = recipients[(i + 1) % 4];
            _minRewards[i] = minRewards[i];
        }
        delete asks[id];
        ++nonces[id];
        CORE.USDG().safeTransferFrom(msg.sender, address(this), price);
        CORE.USDG().forceApprove(address(CORE), price);
        return SELLER.executeLenderSale(id, ask.slots, price, ask.deadline, ask.maxFeeBps);
    }

    function complete(uint256 id) external returns (uint256, address, uint40) {
        V2Loan memory loan = CORE.getLoan(id);
        V2LenderAsk memory ask = CORE.getLenderAsk(id, msg.sender);
        CORE.buyLenderSplit(
            id, V2LenderSplit(msg.sender, ask.slots, ask.price, ask.feeBps, ask.nonce, _recipients, _minRewards)
        );
        CORE.withdrawUSDGFor(msg.sender);
        uint256 proceeds = uint256(ask.price) - uint256(ask.price) * ask.feeBps / 10_000;
        return (proceeds, loan.token, uint40(uint256(loan.fundedAt) + loan.term));
    }
}

/// @notice S9-05, the first executable milestone: one listed lender bundle bought by several vaults in one
/// transaction, and every failure rolling back every participant, the plan's use included.
contract IntentSecondaryFillTest is IntentSecondaryBaseTest {
    /// @dev Three days into the review loan a vault sells at no less than book value plus half the interest still to
    /// come (Pashov L-01), an asking price of about 1,067 after the 1% trade fee and the seller's manager fee; the odd
    /// units exercise the per-quarter remainder rule.
    uint128 internal constant PRICE = 1070e6 + 3;

    // ---------------------------------------------------------------- success

    function test_aDirectBuyerCannotAssignQuartersToAVaultFromAnotherFactory() public {
        uint256 id = _onSale(PRICE);
        IntentFactory other = _factory(address(0));
        other.assignCategory(address(nvda), IntentCategory.STOCK);
        other.assignCategory(address(gold), IntentCategory.COMMODITY);
        other.setCreator(curator, true);
        vm.prank(curator);
        IntentVault stranger = IntentVault(other.create(mandate, false, 0, "Test vault"));
        assertFalse(partnerFactory.isVault(address(stranger)));

        (,,,, uint64 nonce) = sellerMarket.asks(id);
        uint128[4] memory none;
        vm.prank(alice);
        usdg.approve(address(sellerMarket), MAX);
        vm.prank(alice);
        vm.expectRevert(IntentLenderMarket.UnbookedRecipient.selector);
        sellerMarket.buySplit(
            id, nonce, PRICE, [address(stranger), address(stranger), address(stranger), address(stranger)], none
        );
        assertEq(core.unitsOf(id, address(seller)), 4);
        assertEq(core.unitsOf(id, address(stranger)), 0);
        assertEq(_loanOf(stranger, id).principal, 0);
    }

    function test_twoOneOneBundleNoSingleVaultCouldAffordSucceeds() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        // No buyer alone can pay for the listing.
        assertLt(buyerA.freeLiquidity(), PRICE);
        assertLt(buyerB.freeLiquidity(), PRICE);
        assertLt(buyerC.freeLiquidity(), PRICE);
        uint256[3] memory assetsBefore = [buyerA.totalAssets(), buyerB.totalAssets(), buyerC.totalAssets()];
        uint256 sellerAssets = seller.totalAssets();
        uint256 sellerCash = seller.cash();
        uint256 treasuryCredit = core.cashCredit(treasury);
        uint64 nonce = sellerMarket.nonces(id);
        uint256 owedBefore = fills.totalOwed();
        uint256 sharesBefore = fills.owed(payout) + fills.owed(feeProcessor);

        bytes32 digest = _buy(p);

        // Every quarter went straight to the vault its allocation named.
        address[4] memory owners = core.lenders(id);
        assertEq(owners[0], address(buyerA));
        assertEq(owners[1], address(buyerB));
        assertEq(owners[2], address(buyerA));
        assertEq(owners[3], address(buyerC));
        // One ask, one trade fee on the whole price, one payment to the seller.
        uint256 tradeFee = uint256(PRICE) * 100 / 10_000;
        assertEq(core.cashCredit(treasury) - treasuryCredit, tradeFee, "one trade fee");
        assertEq(sellerMarket.nonces(id), nonce + 1);
        assertEq(core.getLenderAsk(id, address(seller)).price, 0);
        assertEq(seller.lenderSaleSlots(id), 0);
        assertLe(sellerAssets - seller.totalAssets(), 1, "the sale gain is a claim, not a jump (D51)");
        uint256 proceeds = PRICE - tradeFee;
        uint256 profit = proceeds - REVIEW_PRINCIPAL;
        uint256 sellerFee = IntentFeeMath.performanceFee(profit, _loanOf(seller, id).executionFee, seller.feeBps());
        assertEq(
            seller.cash() - sellerCash + seller.pocketLiability(address(usdg)),
            proceeds - sellerFee,
            "seller booked its net proceeds, the gain above book as its holders' claim"
        );
        // Each buyer: its own price and fee, its own position at cost, only its fee out of priced assets.
        uint256 totalFee;
        for (uint256 i; i < p.allocations.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            IntentVault v = IntentVault(a.vault);
            LoanView memory ln = _loanOf(v, id);
            assertEq(ln.principal, a.price, "basis is the price");
            assertEq(ln.executionFee, a.executionFee);
            assertTrue(ln.executionEarned);
            assertEq(ln.maturity, p.maturity, "the loan's own maturity");
            uint256 gross = a.repayment - a.price;
            assertEq(ln.interest, gross - IntentFeeMath.performanceFee(gross, a.executionFee, 1000));
            assertEq(v.performingPrincipal(), a.price);
            assertEq(v.executionFees(), 0, "collected by the router");
            assertEq(v.lenderSaleSlots(id), a.slots);
            uint256 before_ = a.vault == address(buyerA)
                ? assetsBefore[0]
                : a.vault == address(buyerB) ? assetsBefore[1] : assetsBefore[2];
            assertEq(v.totalAssets(), before_ - a.executionFee, "no discount windfall");
            assertGe(gross - a.executionFee, a.minimum, "each keeps its own minimum");
            totalFee += a.executionFee;
        }
        assertGt(totalFee, 0);
        // The fee is credited once, under the split standing now.
        assertEq(fills.totalOwed() - owedBefore, totalFee);
        assertEq(fills.owed(payout) + fills.owed(feeProcessor) - sharesBefore, totalFee);
        assertTrue(verifier.consumed(digest));
        assertEq(usdg.balanceOf(address(fills)), fills.totalOwed(), "the router holds only earned fees");
        assertEq(usdg.balanceOf(address(sellerMarket)), 0);
        assertEq(usdg.allowance(address(fills), address(sellerMarket)), 0);
        assertEq(usdg.allowance(address(sellerMarket), address(core)), 0);
    }

    /// @dev The router's events are the only log of a secondary plan's use (the verifier logs only revocations): each
    /// vault's `SecondaryContribution`, in plan order, then one `SecondaryFilled` naming the digest, the listing, its
    /// seller and market, and the whole execution fee credited to the protocol recipient of the moment.
    function test_theRouterLogsTheUseOfASecondaryPlan() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        bytes32 digest = verifier.secondaryPlanHash(p);
        address protocol = partnerFactory.protocolRecipient();
        uint256 owedBefore = fills.owed(protocol);
        uint256 fee;
        for (uint256 i; i < p.allocations.length; ++i) {
            fee += p.allocations[i].executionFee;
        }
        assertGt(fee, 0);
        for (uint256 i; i < p.allocations.length; ++i) {
            IntentQuoteVerifier.SecondaryAllocation memory a = p.allocations[i];
            vm.expectEmit(address(fills));
            emit IntentFillRouter.SecondaryContribution(digest, a.vault, a.slots, a.price, a.repayment, a.executionFee);
        }
        vm.expectEmit(address(fills));
        emit IntentFillRouter.SecondaryFilled(
            digest, id, p.filler, address(seller), address(sellerMarket), p.slots, p.price, fee, protocol
        );
        assertEq(_buy(p), digest);
        assertEq(fills.owed(protocol) - owedBefore, fee);
    }

    function test_oneVaultMayTakeTheWholeBundle() public {
        IntentVault big = _buyer(2000e6);
        uint256 id = _onSale(PRICE);
        IntentVault[] memory vaults = new IntentVault[](1);
        uint8[] memory masks = new uint8[](1);
        (vaults[0], masks[0]) = (big, 15);
        _buy(_marketPlan(id, vaults, masks));
        assertEq(core.unitsOf(id, address(big)), 4);
        assertEq(_loanOf(big, id).principal, PRICE);
    }

    /// @dev A seller is one of the factory's vaults, selling through its own market. On the vault-only core (D47) no
    /// wallet holds a quarter; this fixture's open gate lets one, and its standing core ask is still no listing the
    /// verifier accepts: the plan (market 0) is refused before any vault pays, and the router has no core-ask path.
    function test_aWalletCoreAskIsNotASellableListing() public {
        uint256 id = _listing();
        address wallet = fillers[1];
        vm.prank(wallet);
        core.fund(id, 4);
        vm.warp(_startOf(id) + 2 days);
        uint40 deadline = uint40(_maturity(id));
        vm.prank(wallet);
        core.setLenderAsk(id, 15, PRICE, deadline, 100);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _askPlan(id, wallet, vaults, masks);
        assertEq(p.market, address(0));
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MARKET_MISMATCH);
        // Naming a vault's market does not make the wallet's ask sellable either.
        p.market = address(sellerMarket);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.MARKET_MISMATCH);
        assertEq(core.unitsOf(id, wallet), 4);
        assertEq(core.getLenderAsk(id, wallet).price, PRICE, "the ask stands untouched");
    }

    function test_sortingKeepsEveryQuotedSlotAndRemainder() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint256 sum;
        for (uint256 i; i < p.allocations.length; ++i) {
            sum += p.allocations[i].price;
            if (i != 0) assertLt(uint160(p.allocations[i - 1].vault), uint160(p.allocations[i].vault));
        }
        assertEq(sum, PRICE, "prices sum to the listing whatever the order");
        // Quarter 0 carries the remainder's first raw unit whoever holds it.
        assertEq(verifier.quarterPrice(PRICE, 15, 0), PRICE / 4 + 1);
        assertEq(verifier.quarterPrice(PRICE, 15, 3), PRICE / 4);
        // Two listed quarters: the lower one takes the odd raw unit.
        assertEq(verifier.quarterPrice(PRICE, 10, 1), PRICE / 2 + 1);
        assertEq(verifier.quarterPrice(PRICE, 10, 3), PRICE / 2);
        assertEq(verifier.quarterPrice(PRICE, 1, 0), PRICE, "a single listed quarter takes the whole price");
    }

    /// @dev Pashov L-24, L-25: the public helper answers only for a listed quarter of a four-quarter mask. An empty
    /// mask no longer divides by zero, and a quarter outside the mask or past the fourth, or a mask with a bit above
    /// the four quarters, is refused rather than priced.
    function test_quarterPriceRefusesInputsOutsideItsDomain() public {
        uint8[2][7] memory invalid = [
            [uint8(0), 0], // an empty mask (L-25)
            [uint8(0x10), 0], // only a bit above the four quarters
            [uint8(0x11), 0], // a listed quarter, with a bit above the four
            [uint8(1), 2], // a quarter that is not listed (L-24)
            [uint8(1), 7], // a quarter past the fourth
            [uint8(15), 4],
            [uint8(15), 255]
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(IntentQuoteVerifier.InvalidQuarter.selector);
            verifier.quarterPrice(PRICE, invalid[i][0], invalid[i][1]);
        }
    }

    // ---------------------------------------------------------------- rollback

    /// @dev Everything a failed purchase could have touched, across every participant.
    function _fingerprint(uint256 id, bytes32 digest) internal view returns (bytes32 state) {
        IntentVault[4] memory vaults = [seller, buyerA, buyerB, buyerC];
        for (uint256 i; i < 4; ++i) {
            state = keccak256(abi.encode(state, _vaultPrint(vaults[i], id)));
        }
        (uint128 price,,,, uint64 nonce) = sellerMarket.asks(id);
        state = keccak256(
            abi.encode(
                state,
                core.lenders(id),
                core.cashCredit(address(seller)),
                core.cashCredit(treasury),
                usdg.balanceOf(address(core)),
                price,
                nonce,
                sellerMarket.nonces(id)
            )
        );
        return keccak256(
            abi.encode(
                state,
                fills.totalOwed(),
                fills.owed(payout),
                fills.owed(feeProcessor),
                usdg.balanceOf(address(fills)),
                verifier.consumed(digest)
            )
        );
    }

    function _vaultPrint(IntentVault v, uint256 id) internal view returns (bytes32) {
        LoanView memory ln = _loanOf(v, id);
        bytes32 books = keccak256(
            abi.encode(
                v.cash(),
                v.reserveShares(),
                v.performingPrincipal(),
                v.totalAssets(),
                v.executionFees(),
                v.executionPending(),
                v.curatorFees(),
                v.protocolFees()
            )
        );
        return keccak256(
            abi.encode(
                books,
                v.pocketCount(),
                v.pocketLiability(address(usdg)),
                ln.rate,
                ln.principal,
                ln.settled,
                ln.repaid,
                v.rewardClaimable(alice) + v.rewardClaimable(carol),
                coreRewards.claimable(id, address(v))
            )
        );
    }

    function _assertRolledBack(IntentQuoteVerifier.SecondaryPlan memory p, bytes memory reason) internal {
        bytes32 digest = verifier.secondaryPlanHash(p);
        bytes32 before_ = _fingerprint(p.loanId, digest);
        bytes memory signature = _signSecondary(p);
        vm.prank(p.filler);
        if (reason.length == 0) vm.expectRevert();
        else vm.expectRevert(reason);
        fills.fillSecondary(p, signature);
        assertEq(_fingerprint(p.loanId, digest), before_, "every participant as it was");
        assertFalse(verifier.consumed(digest), "the plan is still usable");
    }

    function test_finalBuyerFailureRollsBackEarlierContributionsAndThePlanStaysUsable() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        IntentVault last = IntentVault(p.allocations[p.allocations.length - 1].vault);
        // The last buyer in execution order closes its per-loan cap after the plan was signed: only its own check
        // at execution can see that, after the earlier buyers have paid.
        uint256 state = vm.snapshotState();
        IntentLimits.setLimits(last, 0, 10_000, 0);
        _assertRolledBack(p, abi.encodeWithSelector(IntentAssetPolicy.IneligibleDeal.selector));
        // Reopening the cap would wait three hours (D53), past the plan's life: the state before closing it returns.
        vm.revertToState(state);
        _buy(p);
        assertEq(core.unitsOf(id, address(last)), last == buyerA ? 2 : 1);
    }

    function test_firstBuyerFailureRollsBack() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        IntentVault firstBuyer = IntentVault(p.allocations[0].vault);
        // Its curator closes its per-loan cap after signing: a purchase-time limit the verifier does not mirror, so
        // the plan passes preflight and the fill reverts inside this first purchase, its consumption with it.
        // (Dropping the token from its picked assets is now refused before any purchase, M-72.)
        IntentLimits.setLimits(firstBuyer, 0, 10_000, 0);
        _assertRolledBack(p, abi.encodeWithSelector(IntentAssetPolicy.IneligibleDeal.selector));
    }

    function test_middleBuyerFailureRollsBack() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        IntentVault middle = IntentVault(p.allocations[1].vault);
        // A depositor leaves after signing, so its category cap on its smaller assets refuses its share.
        uint256 shares = middle.balanceOf(carol);
        vm.prank(carol);
        middle.redeem(shares * 9 / 10, 0);
        _assertRolledBack(p, abi.encodeWithSelector(IntentAssetPolicy.IneligibleDeal.selector));
    }

    function test_middleBuyerReserveIlliquidityRollsBack() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        IntentVault middle = IntentVault(p.allocations[1].vault);
        // Its cash sits in the reserve, which stops paying out after the plan was signed.
        uint256 idle = middle.cash() - 10e6;
        vm.prank(fillers[0]);
        fills.investReserve(address(middle), idle, 0);
        reserve.setLimits(type(uint256).max, 0, 0);
        _assertRolledBack(p, abi.encodeWithSelector(IntentVault.InsufficientLiquidity.selector));
        reserve.setLimits(type(uint256).max, type(uint256).max, type(uint256).max);
        // The same plan, re-signed against the reserve's live share price, now succeeds.
        p = _marketPlan(id, vaults, masks);
        _buy(p);
        assertEq(core.lenders(id)[1] == address(middle) || core.lenders(id)[3] == address(middle), true);
    }

    function test_sellerRewardCheckpointFailureRollsBackEveryBuyer() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        // The seller must checkpoint its holders' rewards before its quarters move; a stuck reward token stops it.
        sgage.setPaused(true);
        _assertRolledBack(p, abi.encodeWithSelector(IntentVault.RewardsPending.selector));
        sgage.setPaused(false);
        _buy(p);
    }

    /// @dev Question 41: each vault books its quarters and pays for them before they move, so the router checks after
    /// the sale that every quarter each vault paid for is now that vault's on the core. A market that hands each
    /// quarter to the vault named for the next one completes the sale, every buyer having paid and booked; the check
    /// reverts all of it, and the plan stays usable.
    function test_aQuarterDeliveredToAnotherVaultRollsBackThePurchase() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        bytes memory honest = address(sellerMarket).code;
        vm.prank(address(seller));
        MisdeliveringMarket faulty = new MisdeliveringMarket(core);
        vm.etch(address(sellerMarket), address(faulty).code);
        _assertRolledBack(p, abi.encodeWithSelector(IntentFillRouter.RightsMismatch.selector));
        // With the seller's own market back, the same plan delivers every quarter where it was booked.
        vm.etch(address(sellerMarket), honest);
        _buy(p);
        address[4] memory owners = core.lenders(id);
        assertEq(owners[0], address(buyerA));
        assertEq(owners[1], address(buyerB));
        assertEq(owners[2], address(buyerA));
        assertEq(owners[3], address(buyerC));
    }

    function test_listingChangeAfterSigningRefusesWithoutMovement() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        uint40 deadline = uint40(_maturity(id));
        vm.prank(curator);
        sellerMarket.list(id, PRICE, deadline, 100);
        _assertRolledBack(
            p, abi.encodeWithSelector(IntentQuoteVerifier.Refused.selector, IntentQuoteVerifier.Refusal.ASK_CHANGED)
        );
    }

    function test_racingPlansSellOnceWithOneSetOfFees() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        masks[0] = 10;
        masks[1] = 1;
        masks[2] = 4;
        IntentQuoteVerifier.SecondaryPlan memory rival = _marketPlan(id, vaults, masks);
        _buy(p);
        uint256 owed = fills.totalOwed();
        _assertSecondaryRefused(rival, IntentQuoteVerifier.Refusal.ASK_CHANGED);
        assertEq(fills.totalOwed(), owed, "no second fee");
        assertEq(core.unitsOf(id, address(buyerA)), 2);
    }

    function test_theSamePlanCannotBeUsedTwice() public {
        uint256 id = _onSale(PRICE);
        (IntentVault[] memory vaults, uint8[] memory masks) = _twoOneOne();
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        _buy(p);
        _assertSecondaryRefused(p, IntentQuoteVerifier.Refusal.CONSUMED);
    }
}
