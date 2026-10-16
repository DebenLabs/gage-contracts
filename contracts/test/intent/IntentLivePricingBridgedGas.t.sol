// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentBridgedBaseTest} from "./IntentBridgedBase.t.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";

/// @notice Full-book capacity after batched initial harvesting, using the real local legacy reward contracts.
/// @dev USDG, collateral and the reserve are local mocks. This measures current-source EVM execution, including
/// nested-call gas requirements; it does not measure deployed legacy bytecode or Nitro's L1 data charge.
contract IntentLivePricingBridgedGasTest is IntentBridgedBaseTest {
    uint256 internal constant FULL_BOOK = 64;
    uint256 internal constant CALL_BUDGET = 32_000_000;

    uint256[] internal loanIds;
    address[] internal parties;

    /// @dev Isolation resets transaction-original storage for every external call; cooling additionally makes each
    /// gas probe independent of fixture inspections. Snapshots preserve all 64 pending claims for every probe.
    /// forge-config: default.isolate = true
    function testBridgedFullBookShareOperationsAfterBatchedHarvestFitCallBudget() public {
        _openFullBook();
        uint256 start = core.getLoan(loanIds[0]).fundedAt;
        vm.warp(start + 1 days);
        _initializeClaimHistory();
        vm.warp(start + 3 days);
        _assertFullBook(V2State.ACTIVE);
        _measureShareOperations("ACTIVE");
        uint256 assetsAtRepayment = partner.totalAssets();

        for (uint256 i; i < loanIds.length; ++i) {
            vm.prank(borrower);
            core.reclaim(loanIds[i], borrower);
        }
        vm.warp(start + 10 days);
        _assertFullBook(V2State.REPAID);
        assertEq(partner.totalAssets(), assetsAtRepayment, "unbooked repayments preserve the closing price");
        _measureShareOperations("REPAID, not booked");
        _assertFullBook(V2State.REPAID);
        assertEq(partner.pocketCount(), 0, "no repayment was booked during a gas probe");
    }

    /// @dev First-ever claims write new reward accounting slots. A 128-record first checkpoint already exceeds
    /// 32M on the staging base without M-01. Exercise the existing permissionless batch harvest before measuring
    /// recurring checkpoints, keeping fresh rewards pending on all records at every measured call.
    function _initializeClaimHistory() internal {
        uint256[] memory batch = new uint256[](32);
        for (uint256 from; from < FULL_BOOK; from += batch.length) {
            for (uint256 i; i < batch.length; ++i) {
                batch[i] = loanIds[from + i];
            }
            _coolAccounts();
            (bool ok,) = address(partner).call{gas: CALL_BUDGET}(abi.encodeCall(partner.harvestRewards, (batch)));
            assertTrue(ok, "initial harvest batch fits the call budget");
            for (uint256 i; i < batch.length; ++i) {
                assertEq(coreRewards.claimable(batch[i], address(partner)), 0, "initial harvest completed");
            }
        }
    }

    function _openFullBook() internal {
        for (uint256 i; i < FULL_BOOK; ++i) {
            vm.prank(borrower);
            uint256 id = core.list(
                Collateral(Kind.ERC20, address(nvda), 1e18), 100e6, 110e6, T21, uint40(block.timestamp + 1 days), false
            );
            intentRouter.fund(partner, id, 4, 0);
            loanIds.push(id);
            GageLegacyAdapter.Loan memory source = bridge.loan(bridge.adapterId(address(core), id));
            assertGt(source.borrowerReward, 0, "the borrower clone has a real drip");
            assertGt(source.lenderReward, 0, "the lender clone has a real drip");
            parties.push(source.borrower);
            parties.push(source.lender);
        }
    }

    function _assertFullBook(V2State expectedState) internal view {
        assertEq(loanIds.length, FULL_BOOK);
        assertEq(bridge.loanCount(), FULL_BOOK);
        assertEq(partner.performingPrincipal(), FULL_BOOK * 100e6);
        for (uint256 i; i < loanIds.length; ++i) {
            uint256 id = loanIds[i];
            V2Loan memory loan = core.getLoan(id);
            assertEq(uint256(loan.state), uint256(expectedState));
            (,,,,, bool settled,,,,,,,,,,) = partner.loans(id);
            assertFalse(settled);
            assertGt(coreRewards.claimable(id, address(partner)), 0, "every record takes the bridge claim path");
        }
    }

    function _measureShareOperations(string memory stateLabel) internal {
        bytes memory deposit = abi.encodeCall(partner.deposit, (1000e6, partner.convertToShares(1000e6)));
        uint256 shares = partner.balanceOf(lender2) / 2;
        bytes memory redeem = abi.encodeCall(partner.redeem, (shares, partner.convertToAssets(shares)));
        (bool depositOk, uint256 depositUsed) = _probe(deposit, CALL_BUDGET);
        (bool redeemOk, uint256 redeemUsed) = _probe(redeem, CALL_BUDGET);
        assertTrue(depositOk, "a legitimate full-book deposit fits the call budget");
        assertTrue(redeemOk, "a legitimate full-book redeem fits the call budget");
        emit log_named_uint(string.concat("bridged deposit gas used, 64 ", stateLabel), depositUsed);
        emit log_named_uint(string.concat("bridged redeem gas used, 64 ", stateLabel), redeemUsed);
    }

    function _probe(bytes memory data, uint256 gasLimit) internal returns (bool ok, uint256 gasUsed) {
        uint256 snapshot = vm.snapshotState();
        uint256 rewardsBefore = sgage.balanceOf(address(partner));
        uint256 sharesBefore = partner.balanceOf(lender2);
        uint256 walletBefore = usdg.balanceOf(lender2);
        _coolAccounts();
        vm.prank(lender2);
        bytes memory result;
        (ok, result) = address(partner).call{gas: gasLimit}(data);
        gasUsed = vm.lastCallGas().gasTotalUsed;
        if (ok) {
            uint256 returned = abi.decode(result, (uint256));
            assertGt(returned, 0);
            if (bytes4(data) == partner.deposit.selector) {
                assertEq(partner.balanceOf(lender2), sharesBefore + returned);
                assertEq(usdg.balanceOf(lender2), walletBefore - 1000e6);
            } else {
                assertEq(partner.balanceOf(lender2), sharesBefore - sharesBefore / 2);
                assertEq(usdg.balanceOf(lender2), walletBefore + returned);
            }
            assertGt(sgage.balanceOf(address(partner)), rewardsBefore, "the real bridge delivered rewards");
            for (uint256 i; i < loanIds.length; ++i) {
                assertEq(coreRewards.claimable(loanIds[i], address(partner)), 0, "every reward claim completed");
            }
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _coolAccounts() internal {
        for (uint256 i; i < parties.length; ++i) {
            vm.cool(parties[i]);
        }
        vm.cool(bridge.PARTY_IMPLEMENTATION());
        vm.cool(address(partner));
        vm.cool(address(core));
        vm.cool(address(coreRewards));
        vm.cool(address(bridge));
        vm.cool(address(vault));
        vm.cool(address(dealRewards));
        vm.cool(address(drip));
        vm.cool(address(sgage));
        vm.cool(address(usdg));
        vm.cool(address(reserve));
        vm.cool(address(reserveLens));
    }
}
