// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2VaultTest} from "./GageV2Vault.t.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";
import {remainingLenderReward} from "../helpers/RemainingReward.sol";

using {unitsOf} for GageV2Vault;
using {remainingLenderReward} for GageV2Rewards;

/// @notice S9-02: one lender ask delivered to several recipients in one purchase. One nonce, one trade fee on the
/// whole price, each quarter straight to its final owner with its repayment, recovery and future rewards.
contract GageV2LenderSplitTest is GageV2VaultTest {
    address internal a = makeAddr("vault-a");
    address internal b = makeAddr("vault-b");
    address internal c = makeAddr("vault-c");

    /// @dev The split recipients hold credits too.
    function _extraCashHolders() internal view override returns (address[] memory holders) {
        holders = new address[](3);
        (holders[0], holders[1], holders[2]) = (a, b, c);
    }

    /// @dev lender[0] holds every quarter of an active loan with odd raw amounts.
    function _held() internal returns (uint256 id) {
        id = _list(1000e6 + 3, 1100e6 + 1, 100e18 + 3);
        vm.prank(lender[0]);
        vault.fund(id, 4);
    }

    function _post(uint256 id, address seller, uint8 slots, uint128 price) internal returns (V2LenderSplit memory p) {
        vm.prank(seller);
        vault.setLenderAsk(id, slots, price, uint40(block.timestamp + 1 days), 100);
        V2LenderAsk memory ask = vault.getLenderAsk(id, seller);
        p.seller = seller;
        p.slots = slots;
        p.price = ask.price;
        p.maxFeeBps = ask.feeBps;
        p.nonce = ask.nonce;
    }

    /// @dev Two nonadjacent quarters to A, one each to B and C.
    function _twoOneOne(V2LenderSplit memory p) internal view {
        p.recipients = [a, b, a, c];
    }

    function _buy(uint256 id, V2LenderSplit memory p) internal {
        vm.prank(buyer);
        vault.buyLenderSplit(id, p);
    }

    function test_twoOneOneSplitConsumesOneAskAndChargesOneFee() public {
        uint256 id = _held();
        vm.warp(block.timestamp + 2 days);
        uint128 price = 1060e6 + 7;
        V2LenderSplit memory p = _post(id, lender[0], 15, price);
        _twoOneOne(p);
        uint256 cash = usdg.balanceOf(buyer);
        uint256 origination = vault.cashCredit(fees);
        uint256 fee = uint256(price) * 100 / 10_000;
        vm.expectEmit(address(vault));
        emit GageV2Vault.LenderSplitSold(id, lender[0], buyer, 15, price, fee, p.nonce, p.recipients);
        _buy(id, p);
        assertEq(usdg.balanceOf(buyer), cash - price, "payer pays the whole price once");
        assertEq(vault.cashCredit(lender[0]), price - fee, "seller nets one fee");
        assertEq(vault.cashCredit(fees) - origination, fee, "one trade fee on the whole price");
        assertEq(vault.unitsOf(id, a), 2);
        assertEq(vault.unitsOf(id, b), 1);
        assertEq(vault.unitsOf(id, c), 1);
        assertEq(vault.unitsOf(id, lender[0]), 0);
        address[4] memory owners = vault.lenders(id);
        assertEq(owners[0], a);
        assertEq(owners[1], b);
        assertEq(owners[2], a);
        assertEq(owners[3], c);
        assertEq(vault.getLenderAsk(id, lender[0]).price, 0, "ask consumed");
        _post(id, b, 2, 1);
        _assertCash();
    }

    function test_proceedsAndFeeDoNotDependOnRecipientCount() public {
        uint128 price = 1060e6 + 3;
        uint256 id = _held();
        uint256 other = _held();
        uint256 feesBefore = vault.cashCredit(fees);
        V2LenderSplit memory p = _post(id, lender[0], 15, price);
        _twoOneOne(p);
        _buy(id, p);
        uint256 splitCredit = vault.cashCredit(lender[0]);
        uint256 splitFee = vault.cashCredit(fees) - feesBefore;

        V2LenderSplit memory q = _post(other, lender[0], 15, price);
        q.recipients = [a, a, a, a];
        _buy(other, q);
        assertEq(vault.cashCredit(lender[0]) - splitCredit, splitCredit, "same net proceeds");
        assertEq(vault.cashCredit(fees) - feesBefore - splitFee, splitFee, "same fee");
        assertEq(vault.unitsOf(other, a), 4, "one recipient may take the whole bundle");
    }

    function test_nonadjacentSubsetOfAHoldingSplitsExactly() public {
        uint256 id = _list(1000e6 + 3, 1100e6 + 1, 100e18 + 3);
        vm.prank(lender[0]);
        vault.fund(id, 1);
        vm.prank(lender[1]);
        vault.fund(id, 1);
        vm.prank(lender[0]);
        vault.fund(id, 2);
        // lender[0] holds quarters 0, 2 and 3 and sells only 0 and 3.
        V2LenderSplit memory p = _post(id, lender[0], 9, 300e6 + 1);
        // Entries outside the ask are ignored, whatever they name.
        p.recipients = [a, c, c, b];
        _buy(id, p);
        address[4] memory owners = vault.lenders(id);
        assertEq(owners[0], a);
        assertEq(owners[1], lender[1]);
        assertEq(owners[2], lender[0]);
        assertEq(owners[3], b);
    }

    function test_repaymentPaysEachQuarterToItsOwnerAndBorrowerTermsStay() public {
        uint256 id = _held();
        V2Loan memory beforeLoan = vault.getLoan(id);
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        _buy(id, p);
        V2Loan memory afterLoan = vault.getLoan(id);
        assertEq(afterLoan.cap, beforeLoan.cap);
        assertEq(afterLoan.fundedAt, beforeLoan.fundedAt);
        assertEq(afterLoan.term, beforeLoan.term);
        assertEq(afterLoan.collateral, beforeLoan.collateral);
        assertEq(vault.ownerOf(id), borrower);
        uint256 sellerCredit = vault.cashCredit(lender[0]);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        uint256 cap = beforeLoan.cap;
        // Quarter i repays cap / 4 plus one raw unit for the first cap % 4 quarters.
        assertEq(vault.cashCredit(a), _slice(cap, 0) + _slice(cap, 2));
        assertEq(vault.cashCredit(b), _slice(cap, 1));
        assertEq(vault.cashCredit(c), _slice(cap, 3));
        assertEq(vault.cashCredit(a) + vault.cashCredit(b) + vault.cashCredit(c), cap);
        assertEq(vault.cashCredit(lender[0]), sellerCredit, "the seller receives nothing after its sale");
        _assertCash();
    }

    function test_defaultRecoveryIsSplitByExactQuarter() public {
        uint256 id = _held();
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        _buy(id, p);
        vm.warp(block.timestamp + TERM + GRACE);
        vault.finalizeDefault(id);
        vm.prank(b);
        vault.recoverDefault(id, 0, 0, block.timestamp);
        uint256 amount = 100e18 + 3;
        assertEq(vault.claimableRecovery(id, 0, a), _slice(amount, 0) + _slice(amount, 2));
        assertEq(vault.claimableRecovery(id, 0, b), _slice(amount, 1));
        assertEq(vault.claimableRecovery(id, 0, c), _slice(amount, 3));
        assertEq(vault.claimableRecovery(id, 0, lender[0]), 0);
        address[3] memory owners = [a, b, c];
        for (uint256 i; i < 3; ++i) {
            vm.prank(owners[i]);
            vault.withdrawRecovery(id, 0, owners[i]);
        }
        assertEq(stock.balanceOf(a) + stock.balanceOf(b) + stock.balanceOf(c), amount);
    }

    function test_sellerKeepsEarnedRewardsAndBuyersSplitOnlyFutureOnes() public {
        uint256 id = _held();
        vm.warp(block.timestamp + TERM / 3);
        uint256 earned = rewards.claimable(id, lender[0]);
        uint256 future = rewards.remainingLenderReward(id, 15);
        uint256 futureA = rewards.remainingLenderReward(id, 5);
        uint256 futureB = rewards.remainingLenderReward(id, 2);
        uint256 futureC = rewards.remainingLenderReward(id, 8);
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        _buy(id, p);
        assertEq(rewards.claimable(id, lender[0]), earned, "earned stays with the seller");
        assertEq(rewards.claimable(id, a) + rewards.claimable(id, b) + rewards.claimable(id, c), 0, "no restart");
        vm.warp(vault.getLoan(id).fundedAt + TERM);
        uint256 buyers = rewards.claimable(id, a) + rewards.claimable(id, b) + rewards.claimable(id, c);
        assertEq(buyers, future, "buyers take exactly the remaining curve");
        assertEq(earned + buyers, vault.getLoan(id).lenderReward, "no reward is duplicated");
        assertEq(rewards.claimable(id, a), futureA, "A takes exactly quarters 0 and 2");
        assertEq(rewards.claimable(id, b), futureB, "B takes exactly quarter 1");
        assertEq(rewards.claimable(id, c), futureC, "C takes exactly quarter 3");
        _assertRewards();
    }

    function test_perQuarterRewardMinimumsBindEachRecipient() public {
        uint256 id = _held();
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        p.minRewards[1] = uint128(rewards.remainingLenderReward(id, 2));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        _buy(id, p);
        p.minRewards[1] = uint128(rewards.remainingLenderReward(id, 2));
        _buy(id, p);
        assertEq(vault.unitsOf(id, b), 1);
    }

    function test_malformedRecipientsFailWithoutMovingAnything() public {
        uint256 id = _held();
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        address[4][4] memory bad = [
            [a, address(0), a, c], // an empty listed quarter
            [a, b, lender[0], c], // the seller buying from itself
            [a, b, address(vault), c], // the core as owner
            [a, b, a, c] // valid, for the final purchase
        ];
        for (uint256 i; i < 3; ++i) {
            p.recipients = bad[i];
            vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
            _buy(id, p);
            assertEq(vault.unitsOf(id, lender[0]), 4);
            assertEq(vault.getLenderAsk(id, lender[0]).nonce, p.nonce);
            assertEq(vault.cashCredit(lender[0]), 0);
        }
        p.recipients = bad[3];
        _buy(id, p);
    }

    function test_staleRepricedOrExpiredAsksFail() public {
        uint256 id = _held();
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        // Posting again is the only way to replace an ask (there is no cancellation): the earlier nonce is stale.
        V2LenderSplit memory fresh = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(fresh);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(id, p);
        fresh.price += 1;
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(id, fresh);
        fresh.price -= 1;
        fresh.slots = 7;
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(id, fresh);
        fresh.slots = 15;
        fresh.maxFeeBps = 99;
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(id, fresh);
        fresh.maxFeeBps = 100;
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(id, fresh);
    }

    function test_racingPurchasesYieldOneOwnerPerQuarter() public {
        uint256 id = _held();
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        V2LenderSplit memory rival = _post(id, lender[0], 15, 1000e6);
        p = _post(id, lender[0], 15, 1000e6);
        rival.nonce = p.nonce;
        _twoOneOne(p);
        rival.recipients = [c, c, b, b];
        _buy(id, p);
        uint256 fee = vault.cashCredit(fees);
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(id, rival);
        assertEq(vault.unitsOf(id, a), 2);
        assertEq(vault.cashCredit(fees), fee, "no second fee");
    }

    function test_repaymentOrDefaultBeforeThePurchaseWins() public {
        uint256 id = _held();
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        vm.expectRevert(GageV2Rewards.InvalidTransfer.selector);
        _buy(id, p);

        uint256 other = _held();
        V2LenderSplit memory q = _post(other, lender[0], 15, 1000e6);
        _twoOneOne(q);
        vm.warp(block.timestamp + TERM + GRACE);
        vault.finalizeDefault(other);
        // The core leaves the state check to the ledger; here the ask has already expired with the window.
        vm.expectRevert(GageV2Vault.StaleAsk.selector);
        _buy(other, q);
    }

    function test_failedPaymentRollsBackEveryRecipient() public {
        uint256 id = _held();
        vm.warp(block.timestamp + 1 days);
        uint256 earned = rewards.claimable(id, lender[0]);
        uint256 origination = vault.cashCredit(fees);
        V2LenderSplit memory p = _post(id, lender[0], 15, 1000e6);
        _twoOneOne(p);
        vm.prank(buyer);
        usdg.approve(address(vault), 1000e6 - 1);
        vm.expectRevert();
        _buy(id, p);
        assertEq(vault.unitsOf(id, lender[0]), 4);
        assertEq(rewards.claimable(id, lender[0]), earned);
        assertEq(vault.getLenderAsk(id, lender[0]).nonce, p.nonce);
        assertEq(vault.cashCredit(fees), origination);
        _assertCash();
        _assertRewards();
    }

    function testFuzz_splitConservesCashOwnershipAndRewards(uint128 price, uint8 mask, uint8 pattern, uint32 wait)
        public
    {
        price = uint128(bound(price, 1, 10_000e6));
        mask = uint8(bound(mask, 1, 15));
        wait = uint32(bound(wait, 0, TERM - 1));
        uint256 id = _held();
        vm.warp(block.timestamp + wait);
        uint256 earned = rewards.claimable(id, lender[0]);
        uint256 origination = vault.cashCredit(fees);
        V2LenderSplit memory p = _post(id, lender[0], mask, price);
        address[3] memory pool = [a, b, c];
        for (uint8 i; i < 4; ++i) {
            p.recipients[i] = pool[(pattern >> (2 * i)) % 3];
        }
        _buy(id, p);
        uint256 fee = uint256(price) * 100 / 10_000;
        assertEq(vault.cashCredit(lender[0]) + vault.cashCredit(fees) - origination, price);
        assertEq(vault.cashCredit(fees) - origination, fee);
        address[4] memory owners = vault.lenders(id);
        for (uint8 i; i < 4; ++i) {
            assertEq(owners[i], mask & (1 << i) == 0 ? lender[0] : p.recipients[i]);
        }
        assertEq(rewards.claimable(id, lender[0]), earned);
        vm.warp(vault.getLoan(id).fundedAt + TERM);
        uint256 total = rewards.claimable(id, lender[0]);
        for (uint256 i; i < 3; ++i) {
            total += rewards.claimable(id, pool[i]);
        }
        assertEq(total, vault.getLoan(id).lenderReward);
        _assertCash();
    }

    function _slice(uint256 total, uint8 i) internal pure returns (uint256) {
        return total / 4 + (i < total % 4 ? 1 : 0);
    }
}
