// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";

/// @notice Pashov M-02: recovered collateral goes to the balances of record at the write-off, never to a holder that
/// arrived after it. `_beforeBalanceChange` stores the balance a holder carried into its first change after a snapshot,
/// under the latest snapshot id, and `balanceOfAt` reads the first entry at or after the id asked for, else the live
/// balance (the ERC20Snapshot pattern). A first deposit after snapshot N stores (N, 0) before the mint.
/// @dev No case here books an early repayment, so pocket N is snapshot N.
contract IntentSnapshotRecordTest is IntentAccountingBaseTest {
    /// @dev Each write-off lends this much against SEIZED NVDA for seven days and recovers all of it.
    uint128 internal constant LENT = 100e6;
    uint256 internal constant SEIZED = 100e18;
    uint64 internal constant ROUNDS = 6;

    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");

    /// @dev Fuzz ghost: every actor's balance when each snapshot was taken. Their sum is checked against the pocket's
    /// supply of record.
    mapping(uint64 => mapping(address => uint256)) internal ghostBalance;

    function setUp() public override {
        super.setUp();
        address[2] memory late = [dave, erin];
        for (uint256 i; i < late.length; ++i) {
            usdg.mint(late[i], 1_000_000e6);
            vm.prank(late[i]);
            usdg.approve(address(partner), MAX);
        }
    }

    // ------------------------------------------------------------ helpers

    /// @dev One loan lent whole and run to the end of its term: `settle` writes it off under the next snapshot and
    /// `recover` opens its pocket, whose snapshot and supply of record are checked against the write-off.
    function _writeOff() internal returns (uint256 pocketId) {
        uint256 id = _list(borrower, address(nvda), SEIZED, LENT, LENT * 105 / 100, T7);
        _route(id, UNITS);
        vm.warp(_maturity(id));
        _book(id);
        uint64 snapshotId = partner.snapshotCount();
        uint256 supply = partner.totalSupply();
        partner.recover(id);
        pocketId = partner.pocketCount();
        (uint256 loanId,, uint256 amount, uint256 supplyOfRecord,, uint64 recorded) = partner.pockets(pocketId);
        assertEq(loanId, id);
        assertEq(amount, SEIZED, "the vault's whole lender share");
        assertEq(recorded, snapshotId, "one snapshot per write-off");
        assertEq(pocketId, snapshotId);
        assertEq(supplyOfRecord, supply, "the supply when its own snapshot was taken");
    }

    /// @dev A holder's part of a recovery pocket at `weight`, rounded down as the vault does.
    function _part(uint256 pocketId, uint256 weight) internal view returns (uint256) {
        (,,, uint256 supply,,) = partner.pockets(pocketId);
        return Math.mulDiv(SEIZED, weight, supply);
    }

    function _claim(address who, uint256 pocketId) internal returns (uint256) {
        vm.prank(who);
        return partner.claimPocket(pocketId);
    }

    function _nothingFor(address who, uint256 pocketId) internal {
        assertEq(partner.pocketClaimable(pocketId, who), 0);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        vm.prank(who);
        partner.claimPocket(pocketId);
    }

    /// @dev Once every holder of record has claimed: never more than the pocket held, and all of it but a raw unit of
    /// rounding per holder.
    function _paidOut(uint256 pocketId, uint256 holders) internal view {
        (,, uint256 amount,, uint256 claimed,) = partner.pockets(pocketId);
        assertLe(claimed, amount, "a pocket never pays more than it holds");
        assertLe(amount - claimed, holders, "its holders of record took all of it but rounding");
    }

    // ------------------------------------------------------------ the reported path

    /// @dev A first deposit after snapshot 5, and another after snapshot 6, weigh nothing at or before the snapshot
    /// they followed and claim nothing from those pockets; the earlier holder keeps all of them.
    function testFirstDepositsAfterSnapshotsFiveAndSixHaveNoWeightThere() public {
        uint256 held = _enter(alice, 10_000e6);
        for (uint256 i; i < 4; ++i) {
            _writeOff();
        }
        uint256 fifth = _writeOff();
        assertEq(fifth, 5);
        uint256 joined = _enter(dave, 5000e6);
        for (uint64 s = 1; s <= 5; ++s) {
            assertEq(partner.balanceOfAt(dave, s), 0, "no weight at or before the snapshot it followed");
        }
        for (uint256 p = 1; p <= 5; ++p) {
            _nothingFor(dave, p);
        }
        uint256 sixth = _writeOff();
        _enter(erin, 5000e6);
        for (uint64 s = 1; s <= 6; ++s) {
            assertEq(partner.balanceOfAt(erin, s), 0);
        }
        for (uint256 p = 1; p <= 6; ++p) {
            _nothingFor(erin, p);
        }
        // Held at the sixth write-off and unchanged since: the live balance is the balance of record.
        assertEq(partner.balanceOfAt(dave, 6), joined);
        assertEq(partner.balanceOfAt(alice, 6), held);
        uint256[] memory all = new uint256[](6);
        for (uint256 p = 1; p <= 6; ++p) {
            all[p - 1] = p;
        }
        vm.prank(alice);
        partner.claimPockets(all);
        assertEq(nvda.balanceOf(alice), 5 * SEIZED + _part(sixth, held), "the only holder of the first five");
        assertEq(_claim(dave, sixth), _part(sixth, joined));
        for (uint256 p = 1; p <= 5; ++p) {
            _paidOut(p, 1);
        }
        _paidOut(sixth, 2);
        assertEq(nvda.balanceOf(erin), 0);
    }

    // ------------------------------------------------------------ exits and returns

    /// @dev An exit keeps every earlier record, claimed after leaving; a return after a snapshot starts from zero there;
    /// out and back in between two snapshots records what was carried into the first change.
    function testAnExitKeepsItsRecordsAndAReturnStartsFromZero() public {
        uint256 held = _enter(alice, 10_000e6);
        uint256 first = _enter(bob, 10_000e6);
        _writeOff();
        _exitAll(bob);
        _writeOff();
        uint256 second = _enter(bob, 4000e6);
        _writeOff();
        _exitAll(bob);
        uint256 third = _enter(bob, 1000e6);
        _writeOff();
        _exitAll(bob);
        assertEq(partner.balanceOf(bob), 0);
        assertEq(partner.balanceOfAt(bob, 1), first, "the exit kept its record");
        assertEq(partner.balanceOfAt(bob, 2), 0, "out at the second");
        assertEq(partner.balanceOfAt(bob, 3), second, "back in at the third");
        assertEq(partner.balanceOfAt(bob, 4), third, "out and back in before the fourth");
        assertEq(_claim(bob, 1), _part(1, first));
        _nothingFor(bob, 2);
        assertEq(_claim(bob, 3), _part(3, second));
        assertEq(_claim(bob, 4), _part(4, third));
        for (uint64 s = 1; s <= 4; ++s) {
            assertEq(partner.balanceOfAt(alice, s), held);
            assertEq(_claim(alice, s), _part(s, held));
        }
        assertEq(_part(2, held), SEIZED, "alone at the second");
        _paidOut(1, 2);
        _paidOut(2, 1);
        _paidOut(3, 2);
        _paidOut(4, 2);
    }

    // ------------------------------------------------------------ unchanged holders

    /// @dev Holders that do not move keep their balance through every later snapshot: one with no entry at all (in
    /// before the first) and one whose only entry is the zero it carried into joining.
    function testUnchangedHoldersKeepTheirBalanceThroughSeveralSnapshots() public {
        uint256 held = _enter(alice, 10_000e6);
        _writeOff();
        uint256 joined = _enter(carol, 10_000e6);
        for (uint256 i; i < 3; ++i) {
            _writeOff();
        }
        assertEq(partner.balanceOfAt(carol, 1), 0);
        for (uint64 s = 1; s <= 4; ++s) {
            assertEq(partner.balanceOfAt(alice, s), held, "no entry reads the live balance");
            if (s > 1) assertEq(partner.balanceOfAt(carol, s), joined, "unchanged since joining");
        }
        assertEq(_claim(alice, 1), SEIZED);
        _nothingFor(carol, 1);
        for (uint256 p = 2; p <= 4; ++p) {
            assertEq(_claim(alice, p), _part(p, held));
            assertEq(_claim(carol, p), _part(p, joined));
            _paidOut(p, 2);
        }
    }

    /// @dev Two write-offs in one `settle` take consecutive snapshots with no change between them: a holder's first
    /// change afterwards records one balance for both.
    function testTwoWriteOffsInOneSettleShareOneRecord() public {
        uint256 held = _enter(alice, 10_000e6);
        _writeOff();
        uint256 joined = _enter(carol, 10_000e6);
        uint256[] memory ids = new uint256[](2);
        ids[0] = _list(borrower, address(nvda), SEIZED, LENT, LENT * 105 / 100, T7);
        ids[1] = _list(borrower, address(nvda), SEIZED, LENT, LENT * 105 / 100, T7);
        _route(ids[0], UNITS);
        _route(ids[1], UNITS);
        vm.warp(_maturity(ids[1]));
        partner.settle(ids);
        assertEq(partner.snapshotCount(), 3);
        partner.recover(ids[0]);
        partner.recover(ids[1]);
        _exit(carol, partner.balanceOf(carol) / 2);
        for (uint64 s = 2; s <= 3; ++s) {
            assertEq(partner.balanceOfAt(carol, s), joined);
            assertEq(partner.balanceOfAt(alice, s), held);
            assertEq(_claim(carol, s), _part(s, joined));
            assertEq(_claim(alice, s), _part(s, held));
            _paidOut(s, 2);
        }
    }

    /// @dev `recover` may run long after the write-off: its pocket takes the supply recorded at the write-off, not the
    /// supply when it opens, so entries and exits in between neither dilute the holders of record nor gain a part.
    function testALateRecoveryUsesTheSupplyOfItsWriteOff() public {
        uint256 held = _enter(alice, 10_000e6);
        uint256 id = _list(borrower, address(nvda), SEIZED, LENT, LENT * 105 / 100, T7);
        _route(id, UNITS);
        vm.warp(_maturity(id));
        _book(id);
        uint256 supply = partner.totalSupply();
        _enter(dave, 50_000e6);
        _exit(alice, held / 2);
        partner.recover(id);
        (,,, uint256 supplyOfRecord,, uint64 snapshotId) = partner.pockets(1);
        assertEq(snapshotId, 1);
        assertEq(supplyOfRecord, supply, "the supply at the write-off");
        assertEq(partner.balanceOfAt(alice, 1), held);
        // Checked while the pocket is still full: once the holder of record has claimed, nothing is left to take.
        assertEq(partner.balanceOfAt(dave, 1), 0, "joined after the write-off");
        _nothingFor(dave, 1);
        assertEq(_claim(alice, 1), SEIZED, "alone at the write-off");
        _paidOut(1, 1);
    }

    // ------------------------------------------------------------ changes between two snapshots

    /// @dev Several changes between two snapshots: the earlier snapshot keeps what was carried into the first change,
    /// the later one reads the balance it found, here one that shrank. Claimed first, the shrunken holder takes only
    /// its part at the later snapshot, never its earlier, larger record.
    function testChangesBetweenTwoSnapshotsRecordTheBalanceAtEach() public {
        uint256 before_ = _enter(carol, 10_000e6);
        _writeOff();
        uint256 joined = _enter(alice, 5000e6);
        _enter(carol, 2000e6);
        _exit(carol, partner.balanceOf(carol) * 9 / 10);
        uint256 after_ = partner.balanceOf(carol);
        assertLt(after_, before_);
        _writeOff();
        assertEq(partner.balanceOfAt(carol, 1), before_);
        assertEq(partner.balanceOfAt(carol, 2), after_, "the balance it had when the second was taken");
        assertEq(partner.balanceOfAt(alice, 1), 0);
        assertEq(partner.balanceOfAt(alice, 2), joined);
        assertEq(_claim(carol, 2), _part(2, after_));
        assertEq(_claim(alice, 2), _part(2, joined));
        _paidOut(2, 2);
        // A later change leaves both records as they were.
        _enter(carol, 1000e6);
        assertEq(partner.balanceOfAt(carol, 1), before_);
        assertEq(partner.balanceOfAt(carol, 2), after_);
        assertEq(_claim(carol, 1), SEIZED, "alone at the first");
        _nothingFor(alice, 1);
    }

    // ------------------------------------------------------------ against a ghost

    /// @dev Random entries and exits around six write-offs, against a ghost of every balance when each snapshot was
    /// taken: `balanceOfAt` matches it for every holder at every snapshot, the balances of record add up to the pocket's
    /// supply, and once all have claimed each pocket paid at most what it held.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_balancesOfRecordMatchAGhostAtEverySnapshot(uint256 seed) public {
        address[4] memory who = [alice, bob, carol, dave];
        _enter(alice, 1000e6);
        for (uint64 s = 1; s <= ROUNDS; ++s) {
            for (uint256 step; step < 4; ++step) {
                uint256 r = uint256(keccak256(abi.encode(seed, s, step)));
                address actor = who[r % 4];
                uint256 balance = partner.balanceOf(actor);
                if ((r >> 8) % 3 != 0 || balance == 0) {
                    _enter(actor, 1e6 + (r >> 16) % 5000e6);
                } else {
                    // Alice never leaves, so every write-off has a holder; a third of the others' exits are whole,
                    // so returns after a full exit are common.
                    uint256 shares = actor == alice
                        ? balance / 2
                        : (r >> 24) % 3 == 0 ? balance : balance * (1 + (r >> 16) % 100) / 100;
                    if (shares != 0) _exit(actor, shares);
                }
            }
            // Exits can leave the vault holding less than the loan each round writes off, which its 100% caps then
            // refuse: Alice tops it up first, before any balance of record is taken.
            uint256 assets = partner.totalAssets();
            if (assets < LENT) _enter(alice, LENT - assets + 1e6);
            _writeOff();
            for (uint256 i; i < 4; ++i) {
                ghostBalance[s][who[i]] = partner.balanceOf(who[i]);
            }
        }
        // Movement after the last snapshot, so no read leans on the live balance by accident.
        for (uint256 i; i < 4; ++i) {
            _enter(who[i], 1e6 + uint256(keccak256(abi.encode(seed, i))) % 1000e6);
        }
        for (uint64 s = 1; s <= ROUNDS; ++s) {
            uint256 sum;
            for (uint256 i; i < 4; ++i) {
                assertEq(partner.balanceOfAt(who[i], s), ghostBalance[s][who[i]], "the balance when it was taken");
                sum += ghostBalance[s][who[i]];
            }
            (,,, uint256 supply,,) = partner.pockets(s);
            assertEq(sum, supply, "the balances of record are the supply of record");
            for (uint256 i; i < 4; ++i) {
                if (partner.pocketClaimable(s, who[i]) != 0) _claim(who[i], s);
            }
            _paidOut(s, 4);
        }
    }
}
