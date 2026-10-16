// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnBaseTest} from "./EarnBase.t.sol";
import {HybridVault} from "../src/HybridVault.sol";

/// @notice Gas of the pooled vault's hot paths does not grow with the number of holders: one purchase, one
/// settlement, one snapshot per balance change, one pocket per default. Only the request queue is linear, in the
/// requests actually served. Measurements start from cold storage like a fresh transaction would.
contract HybridVaultGasTest is EarnBaseTest {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant FEW = 2;
    uint256 internal constant MANY = 100;
    uint256 internal constant EACH = 1000e6;

    function setUp() public override {
        super.setUp();
        curator = address(this);
        p.curator = address(this);
        p.maxTotalDeposits = 1_000_000e6;
        _deploy();
        hybrid.setFee(1000);
    }

    // ---------------------------------------------------------------- fixture

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// @dev Holders `from` (inclusive) to `to` (exclusive) each deposit `EACH`.
    function _addHolders(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            address who = _holder(i);
            usdg.mint(who, EACH);
            vm.startPrank(who);
            usdg.approve(address(hybrid), EACH);
            hybrid.deposit(EACH, 0);
            vm.stopPrank();
        }
    }

    function _approved(uint128 principal) internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 100e18, principal, principal * 105 / 100, T7);
        hybrid.approveLoan(id, uint40(block.timestamp + 1 hours), UNITS);
    }

    function _funded(uint128 principal) internal returns (uint256 id) {
        id = _approved(principal);
        hybrid.fund(id, MAX);
    }

    function _cool() internal {
        vm.cool(address(hybrid));
        vm.cool(address(reserve));
        vm.cool(address(vault));
        vm.cool(address(coreRewards));
        vm.cool(address(registry));
        vm.cool(address(validator));
        vm.cool(address(usdg));
        vm.cool(address(nvda));
        vm.cool(address(sgage));
    }

    function _fundGas() internal returns (uint256 used) {
        uint256 id = _approved(1000e6);
        _cool();
        uint256 start = gasleft();
        hybrid.fund(id, MAX);
        used = start - gasleft();
        assertTrue(hybrid.funded(id));
    }

    function _repaidSettleGas() internal returns (uint256 used) {
        uint256 id = _funded(1000e6);
        _repay(id);
        uint256[] memory ids = _ids(id);
        _cool();
        uint256 start = gasleft();
        hybrid.settle(ids);
        used = start - gasleft();
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.feeAccrued(), 5e6);
    }

    function _defaultSettleGas() internal returns (uint256 used) {
        uint256 id = _funded(1000e6);
        vm.warp(_defaultAt(id));
        uint256[] memory ids = _ids(id);
        _cool();
        uint256 start = gasleft();
        hybrid.settle(ids);
        used = start - gasleft();
        assertTrue(hybrid.terminal(id));
        assertEq(hybrid.pocketCount(), 1);
    }

    function _markOverdueGas() internal returns (uint256 used) {
        uint256 id = _funded(1000e6);
        vm.warp(block.timestamp + T7);
        uint256[] memory ids = _ids(id);
        _cool();
        uint256 start = gasleft();
        hybrid.markOverdue(ids);
        used = start - gasleft();
        assertTrue(hybrid.overdue(id));
    }

    /// @dev Measure with two holders, roll back, measure again with a hundred: the two numbers must agree.
    function _independentOfHolders(function() internal returns (uint256) measure, string memory label)
        internal
        returns (uint256 few, uint256 many)
    {
        _addHolders(0, FEW);
        uint256 snapshot = vm.snapshotState();
        few = measure();
        vm.revertToState(snapshot);
        _addHolders(FEW, MANY);
        many = measure();
        emit log_named_uint(string.concat(label, " gas, 2 holders"), few);
        emit log_named_uint(string.concat(label, " gas, 100 holders"), many);
        assertApproxEqAbs(many, few, 500, "holder count must not change the cost");
    }

    // ---------------------------------------------------------------- loans

    function testFundGasIsIndependentOfHolderCount() public {
        (, uint256 many) = _independentOfHolders(_fundGas, "fund");
        assertLt(many, 800_000);
    }

    function testRepaidSettlementGasIsIndependentOfHolderCount() public {
        (, uint256 many) = _independentOfHolders(_repaidSettleGas, "repaid settle");
        assertLt(many, 400_000);
    }

    function testCollateralSettlementGasIsIndependentOfHolderCount() public {
        (, uint256 many) = _independentOfHolders(_defaultSettleGas, "collateral settle (pocket)");
        assertLt(many, 1_000_000);
    }

    function testMarkOverdueGasIsIndependentOfHolderCount() public {
        (, uint256 many) = _independentOfHolders(_markOverdueGas, "mark overdue");
        assertLt(many, 220_000);
    }

    function testBatchSettlementOfThirtyTwoRepaidLoansFitsComfortably() public {
        _addHolders(0, MANY);
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            ids[i] = _funded(1000e6);
        }
        for (uint256 i; i < 32; ++i) {
            _repay(ids[i]);
        }
        _cool();
        uint256 start = gasleft();
        hybrid.settle(ids);
        uint256 used = start - gasleft();
        emit log_named_uint("settle gas, 32 repaid loans, 100 holders", used);
        emit log_named_uint("settle gas per loan", used / 32);
        assertLt(used, 8_000_000);
        assertLt(used / 32, 240_000, "settlement remains linear in the bounded live-loan set");
        assertEq(hybrid.feeAccrued(), 32 * 5e6);
    }

    function testLiveLoanCapReleasesASlotAfterTerminalCompaction() public {
        _addHolders(0, MANY);
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            ids[i] = _funded(1000e6);
        }

        uint256 waiting = _approved(1000e6);
        vm.expectRevert(HybridVault.LimitExceeded.selector);
        hybrid.fund(waiting, MAX);

        _repay(ids[0]);
        hybrid.settle(_ids(ids[0]));
        assertTrue(hybrid.terminal(ids[0]));

        hybrid.fund(waiting, MAX);
        assertTrue(hybrid.funded(waiting));
        assertFalse(hybrid.terminal(waiting));
    }

    // ---------------------------------------------------------------- requests

    function _requestAll(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            address who = _holder(i);
            uint256 shares = hybrid.balanceOf(who);
            vm.prank(who);
            hybrid.requestRedeem(shares);
        }
    }

    function testServeRequestsCostsScaleOnlyWithRequestsServed() public {
        _addHolders(0, MANY);
        _requestAll(0, MANY);
        uint256 snapshot = vm.snapshotState();
        _cool();
        uint256 start = gasleft();
        hybrid.serveRequests(1, MAX);
        uint256 one = start - gasleft();
        assertEq(hybrid.claimable(_holder(0)), EACH);
        vm.revertToState(snapshot);
        _cool();
        start = gasleft();
        hybrid.serveRequests(10, MAX);
        uint256 ten = start - gasleft();
        assertEq(hybrid.requestHead(), 11);
        vm.revertToState(snapshot);
        _cool();
        start = gasleft();
        hybrid.serveRequests(MANY, MAX);
        uint256 all = start - gasleft();
        assertEq(hybrid.pendingShares(), 0);
        assertEq(hybrid.claimableTotal(), MANY * EACH);
        emit log_named_uint("serveRequests gas, 1 of 100 pending", one);
        emit log_named_uint("serveRequests gas, 10 of 100 pending", ten);
        emit log_named_uint("serveRequests gas, 100 of 100 pending", all);
        emit log_named_uint("serveRequests gas per request", (all - one) / (MANY - 1));
        uint256 perRequest = (all - one) / (MANY - 1);
        assertLt(perRequest, 60_000, "each served request is a bounded constant");
        assertLt(one, 200_000);
        assertApproxEqAbs(ten, one + 9 * perRequest, 9 * 5000, "linear in requests served");
        assertLt(all, 6_000_000);
    }

    function testServeRequestsCountsCancelledRowsWithinTheCallerBound() public {
        _addHolders(0, MANY);
        _requestAll(0, MANY);
        for (uint256 i; i < MANY - 1; ++i) {
            vm.prank(_holder(i));
            hybrid.cancelRequest(i + 1);
        }
        _cool();
        uint256 start = gasleft();
        hybrid.serveRequests(MANY - 1, MAX);
        uint256 cancelled = start - gasleft();
        assertEq(hybrid.claimable(_holder(MANY - 1)), 0);
        assertEq(hybrid.requestHead(), MANY);
        _cool();
        start = gasleft();
        hybrid.serveRequests(1, MAX);
        uint256 served = start - gasleft();
        assertEq(hybrid.claimable(_holder(MANY - 1)), EACH);
        assertEq(hybrid.requestHead(), MANY + 1);
        emit log_named_uint("serveRequests gas, 99 cancelled rows", cancelled);
        emit log_named_uint("serveRequests gas, final live row", served);
        emit log_named_uint("serveRequests gas per cancelled row", cancelled / (MANY - 1));
        assertLt(cancelled / (MANY - 1), 10_000, "cancelled rows are cheap but each consumes caller work");
        assertLt(cancelled, 1_000_000);
        assertLt(served, 200_000);
    }

    // ---------------------------------------------------------------- pockets and snapshots

    /// @dev Open `n` pockets, each in its own block, with holder 0 changing balance between them.
    function _openPockets(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            uint256 id = _funded(100e6);
            vm.warp(_defaultAt(id));
            hybrid.settle(_ids(id));
            address who = _holder(0);
            usdg.mint(who, 1e6);
            vm.startPrank(who);
            usdg.approve(address(hybrid), 1e6);
            hybrid.deposit(1e6, 0);
            vm.stopPrank();
        }
        assertEq(hybrid.pocketCount(), n);
    }

    function testClaimPocketGasIsIndependentOfHolderCountAndBoundedInSnapshots() public {
        _addHolders(0, MANY);
        _openPockets(5);
        // Holder 0 carries one snapshot per pocket; holder 1 has none since the pockets and reads the live balance.
        uint256 middle = hybrid.pocketClaimable(3, _holder(0));
        uint256 plain = hybrid.pocketClaimable(3, _holder(1));
        assertGt(middle, 0);
        assertGt(plain, 0);
        vm.prank(_holder(0));
        _cool();
        uint256 start = gasleft();
        hybrid.claimPocket(3);
        uint256 searched = start - gasleft();
        vm.prank(_holder(1));
        _cool();
        start = gasleft();
        hybrid.claimPocket(3);
        uint256 direct = start - gasleft();
        emit log_named_uint("claimPocket gas, holder with 5 snapshots", searched);
        emit log_named_uint("claimPocket gas, holder with no snapshots", direct);
        assertLt(searched, 120_000);
        assertLt(direct, 120_000);
        assertLt(searched - direct, 30_000, "the binary search over five snapshots costs a few cold reads");
        (,,,, uint256 claimed) = hybrid.pockets(3);
        assertEq(claimed, middle + plain);
    }

    function testDepositAndRedeemWriteAtMostOneSnapshotPerPocketEra() public {
        _addHolders(0, MANY);
        address who = _holder(1);
        usdg.mint(who, 3e6);
        vm.prank(who);
        usdg.approve(address(hybrid), 3e6);
        vm.prank(who);
        _cool();
        uint256 start = gasleft();
        hybrid.deposit(1e6, 0);
        uint256 noPocket = start - gasleft();
        _openPockets(5);
        vm.prank(who);
        _cool();
        start = gasleft();
        hybrid.deposit(1e6, 0);
        uint256 firstAfterPockets = start - gasleft();
        vm.prank(who);
        _cool();
        start = gasleft();
        hybrid.deposit(1e6, 0);
        uint256 secondAfterPockets = start - gasleft();
        vm.prank(who);
        _cool();
        start = gasleft();
        hybrid.redeem(1e18, 0);
        uint256 redeemAfterPockets = start - gasleft();
        emit log_named_uint("deposit gas, no pockets", noPocket);
        emit log_named_uint("deposit gas, first change after 5 pockets", firstAfterPockets);
        emit log_named_uint("deposit gas, second change in the same era", secondAfterPockets);
        emit log_named_uint("redeem gas, same era", redeemAfterPockets);
        assertLt(firstAfterPockets - noPocket, 120_000, "one full-width snapshot push, whatever the number of pockets");
        assertLt(secondAfterPockets, noPocket + 10_000, "no snapshot when the era has not changed");
        assertLt(redeemAfterPockets, 200_000);
        assertLt(noPocket, 200_000);
    }
}
