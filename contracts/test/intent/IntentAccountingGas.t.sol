// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";

/// @notice S2-A5 measurements at a full book of 64 open loans, the cap since Pashov I-03 (it was 128). Local EVM gas,
/// not an on-chain receipt: the numbers size the design (bounded entry/exit checkpoints and settlement batches). New
/// measurements need testnet confirmation.
contract IntentAccountingGasTest is IntentAccountingBaseTest {
    uint256 internal constant FULL_BOOK = 64;
    uint256 internal constant BATCH = 32;
    /// @dev Robinhood Chain is an Arbitrum Orbit chain; 32,000,000 is the Orbit default per-block limit and the
    /// budget these measurements are held to until the testnet demo reads the chain's own value.
    uint256 internal constant GAS_BUDGET = 32_000_000;
    /// @dev Mirror of shared/tx-gas.mjs TX_GAS.recordClaimGas: the gas the client rule adds per open reward record on
    /// top of the estimate (chaos finding 1, 26 September 2026). The web test reads this line to keep the two equal.
    uint256 internal constant RECORD_CLAIM_GAS = 250_000;
    /// @dev Mirror of TX_GAS.recordSlack: records the rule allows beyond the count it read, for loans opened between
    /// the read and the block the transaction lands in.
    uint256 internal constant RECORD_SLACK = 2;
    /// @dev What a purchase needs on top of a full-book checkpoint (the at-cap and secondary-sale paths run both).
    uint256 internal constant PURCHASE_ROOM = 2_500_000;
    /// @dev A book of this size already reproduced the gap live (at most 8 records) and on the fork.
    uint256 internal constant GAP_BOOK = 16;

    function _open(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _list(borrower, address(nvda), 1e18, 100e6, 110e6, T21);
            _route(ids[i], UNITS);
        }
    }

    function _batch(uint256[] memory ids, uint256 from) internal pure returns (uint256[] memory batch) {
        batch = new uint256[](BATCH);
        for (uint256 i; i < BATCH; ++i) {
            batch[i] = ids[from + i];
        }
    }

    function _measuredDeposit(address who, uint256 assets) internal returns (uint256 gas) {
        vm.prank(who);
        partner.deposit(assets, 0);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    function _measuredRedeem(address who, uint256 shares) internal returns (uint256 gas) {
        vm.prank(who);
        partner.redeem(shares, 0);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    function _measuredSettle(uint256[] memory ids) internal returns (uint256 gas) {
        partner.settle(ids);
        gas = vm.lastCallGas().gasTotalUsed;
    }

    /// @dev Complete reward checkpoints and per-loan accrual read a bounded book before share changes.
    function testEntryAndExitAtFullBookFitTheGasBudget() public {
        _enter(alice, 100_000e6);
        // A first deposit writes fresh storage and a first exit reads the reserve and its lens cold; measure like
        // for like, with the entrant's records already there and those reads already warm.
        _enter(bob, 2000e6);
        _exit(bob, partner.balanceOf(bob) / 2);
        uint256 depositEmpty = _measuredDeposit(bob, 1000e6);
        uint256 redeemEmpty = _measuredRedeem(bob, partner.balanceOf(bob) / 2);

        uint256[] memory ids = _open(FULL_BOOK);
        vm.warp(_startOf(ids[0]) + 3 days);
        uint256 depositFull = _measuredDeposit(bob, 1000e6);
        uint256 redeemFull = _measuredRedeem(bob, partner.balanceOf(bob) / 2);

        for (uint256 i; i < FULL_BOOK; ++i) {
            _repay(ids[i]);
        }
        for (uint256 from; from < FULL_BOOK; from += BATCH) {
            partner.settle(_batch(ids, from));
        }
        assertEq(partner.pocketCount(), FULL_BOOK, "every early booking opened its earnings claim");
        assertEq(partner.performingPrincipal(), 0);
        uint256 depositRunning = _measuredDeposit(bob, 1000e6);
        uint256 redeemRunning = _measuredRedeem(bob, partner.balanceOf(bob) / 2);

        emit log_named_uint("deposit, no open loan", depositEmpty);
        emit log_named_uint("deposit, 64 loans in term", depositFull);
        emit log_named_uint("deposit, after 64 early bookings", depositRunning);
        emit log_named_uint("redeem, no open loan", redeemEmpty);
        emit log_named_uint("redeem, 64 loans in term", redeemFull);
        emit log_named_uint("redeem, after 64 early bookings", redeemRunning);
        assertLt(depositFull, GAS_BUDGET);
        assertLt(depositRunning, GAS_BUDGET);
        assertLt(redeemFull, GAS_BUDGET);
        assertLt(redeemRunning, GAS_BUDGET);
    }

    /// @dev Settlement in batches of 32: a first look that finds nothing due (the read a completeness check would
    /// add to every entry and exit under candidate A, four times over at a full book), the booking of 32 early
    /// repayments with their earnings claims (D51), and a settle of the same 32 at the original term end, which finds
    /// them booked.
    function testSettlementBatchesFitTheGasBudget() public {
        _enter(alice, 100_000e6);
        uint256[] memory ids = _open(FULL_BOOK);
        vm.warp(_startOf(ids[0]) + 3 days);
        uint256 nothingDue = _measuredSettle(_batch(ids, 0));
        for (uint256 i; i < FULL_BOOK; ++i) {
            _repay(ids[i]);
        }
        uint256 booking = _measuredSettle(_batch(ids, 0));
        for (uint256 from = BATCH; from < FULL_BOOK; from += BATCH) {
            partner.settle(_batch(ids, from));
        }
        vm.warp(_maturity(ids[0]));
        uint256 release = _measuredSettle(_batch(ids, 0));
        emit log_named_uint("settle 32, nothing due (read only)", nothingDue);
        emit log_named_uint("candidate A, added to every entry and exit at a full book", nothingDue * 4);
        emit log_named_uint("settle 32, booking early repayments and their claims", booking);
        emit log_named_uint("settle 32, at the original term end after booking", release);
        assertLt(nothingDue * 4, GAS_BUDGET);
        assertLt(booking, GAS_BUDGET);
        assertLt(release, GAS_BUDGET);
    }

    /// @dev The last holder leaves after 64 early bookings, then collects 32 earnings claims in one call (D51).
    function testLastHolderExitAtAFullBookFitsTheGasBudget() public {
        _enter(alice, 100_000e6);
        uint256[] memory ids = _open(FULL_BOOK);
        vm.warp(_startOf(ids[0]) + 3 days);
        for (uint256 i; i < FULL_BOOK; ++i) {
            _repay(ids[i]);
        }
        for (uint256 from; from < FULL_BOOK; from += BATCH) {
            partner.settle(_batch(ids, from));
        }
        uint256 gas = _measuredRedeem(alice, partner.balanceOf(alice));
        uint256[] memory claims = new uint256[](BATCH);
        for (uint256 i; i < BATCH; ++i) {
            claims[i] = i + 1;
        }
        vm.prank(alice);
        partner.claimPockets(claims);
        uint256 claimGas = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("last holder exit, after 64 early bookings", gas);
        emit log_named_uint("claim 32 earnings pockets in one call", claimGas);
        assertEq(partner.totalSupply(), 0);
        assertLt(gas, GAS_BUDGET);
        assertLt(claimGas, GAS_BUDGET);
    }

    /// @dev The least gas `who`'s call succeeds with, to within 1,000: the limit a transaction must carry, with the
    /// 63/64 rule applied at every inner call and a starved claim caught by the try/catch and turned into
    /// `RewardsPending`. State is restored after every probe. The tests using it run isolated, so each probe starts
    /// with cold storage as a transaction on chain does, and the figure includes the intrinsic cost.
    function _minGas(address who, bytes memory data) internal returns (uint256) {
        uint256 lo = 21_000;
        uint256 hi = 31_000_000;
        require(_succeeds(who, data, hi), "the call fails even at the ceiling");
        while (hi - lo > 1000) {
            uint256 mid = (lo + hi) / 2;
            if (_succeeds(who, data, mid)) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function _succeeds(address who, bytes memory data, uint256 gas) internal returns (bool ok) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(who);
        (ok,) = address(partner).call{gas: gas}(data);
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev Chaos finding 1: an estimate taken while every record's claimable is 0 (in the second of a checkpoint)
    /// prices the read path; mined a second later, the same deposit or redeem takes the claim
    /// path. The shared client rule (estimate plus RECORD_CLAIM_GAS per record and slack) must cover the increase.
    /// This fixture is unbridged with a mock sGAGE, so its claims are far cheaper than the bridged core's (about 174k
    /// gas used per record on the r2 testnet core): the numbers are lower bounds. M-01 adds core reads to both paths,
    /// so their ratio no longer establishes that the historical 1.5x rule is insufficient on this mock fixture.
    /// forge-config: default.isolate = true
    function testCheckpointGapSameSecondVsNextSecond() public {
        _enter(alice, 100_000e6);
        _enter(bob, 2000e6);
        uint256[] memory ids = _open(GAP_BOOK);
        uint256 t = _startOf(ids[0]);
        vm.warp(t + 1);
        _enter(carol, 1000e6);
        bytes memory deposit = abi.encodeCall(partner.deposit, (1000e6, 0));
        bytes memory redeem = abi.encodeCall(partner.redeem, (partner.balanceOf(bob) / 2, 0));

        // After a checkpoint, nothing is claimable yet, so an estimate sees the read path.
        uint256 depositRead = _minGas(bob, deposit);
        uint256 redeemRead = _minGas(bob, redeem);
        vm.warp(t + 2);
        uint256 depositClaim = _minGas(bob, deposit);
        uint256 redeemClaim = _minGas(bob, redeem);
        emit log_named_uint("deposit, 16 records, checkpoint second (read path)", depositRead);
        emit log_named_uint("deposit, 16 records, next second (claim path)", depositClaim);
        emit log_named_uint("redeem, 16 records, checkpoint second (read path)", redeemRead);
        emit log_named_uint("redeem, 16 records, next second (claim path)", redeemClaim);
        assertGt(depositClaim, depositRead, "the next second's deposit still claims rewards");
        assertGt(redeemClaim, redeemRead, "the next second's redemption still claims rewards");
        assertLe(depositClaim, depositRead + (GAP_BOOK + RECORD_SLACK) * RECORD_CLAIM_GAS, "the shared floor is short");
        assertLe(redeemClaim, redeemRead + (GAP_BOOK + RECORD_SLACK) * RECORD_CLAIM_GAS, "the shared floor is short");

        // In the second of another holder's checkpoint (the keeper's harvest is one): every claim was just collected.
        vm.warp(t + 1 hours);
        _enter(carol, 1000e6);
        depositRead = _minGas(bob, deposit);
        vm.warp(t + 1 hours + 1);
        depositClaim = _minGas(bob, deposit);
        emit log_named_uint("deposit, 16 records, checkpoint's second (read path)", depositRead);
        emit log_named_uint("deposit, 16 records, a second later (claim path)", depositClaim);
        assertGt(depositClaim, depositRead, "a second later the checkpoint claims again");
        assertLe(depositClaim, depositRead + (GAP_BOOK + RECORD_SLACK) * RECORD_CLAIM_GAS, "the shared floor is short");
    }

    /// @dev The claim path at the 64-record cap fits under the chain's 32M per-transaction cap with room left for a
    /// purchase, so the at-cap purchase and the secondary sale (which run a full checkpoint) stay possible.
    /// forge-config: default.isolate = true
    function testCheckpointMinimumGasAtFullBook() public {
        _enter(alice, 100_000e6);
        _enter(bob, 2000e6);
        uint256[] memory ids = _open(FULL_BOOK);
        vm.warp(_startOf(ids[0]) + 1 hours);
        uint256 deposit = _minGas(bob, abi.encodeCall(partner.deposit, (1000e6, 0)));
        uint256 redeem = _minGas(bob, abi.encodeCall(partner.redeem, (partner.balanceOf(bob) / 2, 0)));
        emit log_named_uint("deposit, 64 records, claim path", deposit);
        emit log_named_uint("redeem, 64 records, claim path", redeem);
        assertLt(deposit, GAS_BUDGET - PURCHASE_ROOM);
        assertLt(redeem, GAS_BUDGET - PURCHASE_ROOM);
    }
}
