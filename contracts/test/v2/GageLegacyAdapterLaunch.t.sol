// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "../Base.t.sol";
import {MockLPRewards} from "../mocks/MockLPRewards.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";
import {Drip} from "../../src/token/Drip.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {IEmissions} from "../../src/interfaces/token/IEmissions.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @notice The adapter over a fresh legacy token stack whose Emissions each test launches itself (Pashov M-11, M-12,
/// M-13). Before `launchAt` no bridged loan activates: the fourth unit reverts in the legacy registration. From
/// `launchAt` on, the adapter, both legacy Drips and the V2 ledger start in the same second and a mid-term claim is
/// paid in full. After the schedule ends a bridged loan still activates, with zero rewards.
contract GageLegacyAdapterLaunchTest is BaseTest {
    uint128 internal constant PRINCIPAL = 1000e6;

    Emissions internal emissions;
    SGAGE internal sgage;
    Drip internal drip;
    DealRewards internal dealRewards;
    GageLegacyAdapter internal bridge;
    GageV2Vault internal v2;
    GageV2Rewards internal ledger;

    function setUp() public override {
        super.setUp();
        emissions = new Emissions(safe, address(this));
        sgage = new SGAGE(address(emissions), treasury);
        drip = new Drip(sgage, address(this));
        MockLPRewards lpMock = new MockLPRewards(sgage);
        dealRewards = new DealRewards(vault, emissions, drip, sgage, 6, safe);
        // Wired, not launched: each test launches at its own time.
        emissions.wire(sgage, ILPRewards(address(lpMock)), address(dealRewards));
        drip.setGrantors(address(dealRewards), address(lpMock));
        bridge = new GageLegacyAdapter(address(this), vault, dealRewards, usdg);
        vm.startPrank(safe);
        registry.setFee(100);
        registry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        vm.stopPrank();
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        GageV2TokenRegistry cfg = new GageV2TokenRegistry(address(this), terms, address(this));
        cfg.setERC20Allowed(address(nvda), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        v2 = new GageV2Vault(cfg, IERC20(address(usdg)), IERC20(address(sgage)), treasury, 0, bridge);
        bridge.setEngine(address(v2));
        ledger = v2.REWARDS();
        ledger.bindFunderGate(new MockOpenFunderGate());
        vm.prank(borrower);
        nvda.approve(address(v2), type(uint256).max);
        vm.prank(lender);
        usdg.approve(address(v2), type(uint256).max);
    }

    /// @dev Pashov M-13, and the future-`launchAt` path of M-11 and M-12. With `launchAt` a day ahead, the fourth unit
    /// reverts `EpochNotStarted(0)` in the legacy registration, so no bridged loan opens before `launchAt` and the
    /// claimed gap between its opening and its Drip start cannot arise. The same listing activates at `launchAt` with
    /// every clock starting in that second, and an hour later, the claim time in M-13's path, both parties' claims
    /// are paid in full.
    function test_noBridgedLoanOpensBeforeLaunchAtAndClocksStartTogether() public {
        uint40 at = uint40(block.timestamp + 1 days);
        _launch(at);
        uint256 id = _listBridged(T7, at + 1 days, true);
        _fundBridged(id, 3);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(IEmissions.EpochNotStarted.selector, 0));
        v2.fund(id, 1);
        assertEq(uint256(v2.getLoan(id).state), uint256(V2State.FUNDING));
        assertEq(bridge.loanCount(), 0);

        vm.warp(at);
        _fundBridged(id, 1);
        V2Loan memory l = v2.getLoan(id);
        assertEq(uint256(l.state), uint256(V2State.ACTIVE));
        assertGt(l.borrowerReward, 0);
        assertGt(l.lenderReward, 0);
        _assertClocksStartAt(id, at);

        vm.warp(uint256(at) + 1 hours);
        uint256 paid = _claimInFull(id, borrower) + _claimInFull(id, lender);
        assertEq(bridge.loan(bridge.adapterId(address(v2), id)).paid, paid);
    }

    /// @dev Pashov M-13. Launch may name a `launchAt` up to one epoch in the past (D37). A loan activated after it has
    /// the Drip start `max(fundedAt, launchAt) = fundedAt`, the second the adapter and the ledger record, and ten days
    /// into a 21-day term both parties' claims are paid in full.
    function test_pastLaunchAtClocksStartTogetherAndMidTermClaimsArePaidInFull() public {
        uint40 at = uint40(block.timestamp - 6 days);
        _launch(at);
        uint256 id = _listBridged(T21, uint40(block.timestamp + 1 days), true);
        _fundBridged(id, 4);
        uint40 opened = uint40(block.timestamp);
        assertGt(opened, at);
        V2Loan memory l = v2.getLoan(id);
        assertEq(uint256(l.state), uint256(V2State.ACTIVE));
        assertGt(l.borrowerReward, 0);
        assertGt(l.lenderReward, 0);
        _assertClocksStartAt(id, opened);

        vm.warp(uint256(opened) + 10 days);
        uint256 paid = _claimInFull(id, borrower) + _claimInFull(id, lender);
        assertEq(bridge.loan(bridge.adapterId(address(v2), id)).paid, paid);
    }

    /// @dev Pashov M-11, M-12. The legacy start makes `register` revert only before `launchAt`: `NotLaunched` while
    /// Emissions has never launched, `EpochNotStarted(0)` while `launchAt` is still ahead. Launch is one-time, so once
    /// `launchAt` has passed neither state returns, and no later state brings the revert back: once the 52-week
    /// schedule has ended, `register` skips `release` and records a zero reward, and bridged listings, with rewards or
    /// without, activate with zero rewards and pay the borrower its proceeds.
    function test_bridgedActivationAfterScheduleEndsSucceedsWithZeroRewards() public {
        _launch(uint40(block.timestamp));
        vm.warp(emissions.epochStart(emissions.WEEKS()));
        assertTrue(emissions.scheduleOver());
        vm.prank(safe);
        vm.expectRevert(IEmissions.AlreadyLaunched.selector);
        emissions.launch(uint40(block.timestamp));

        uint40 deadline = uint40(block.timestamp + 1 days);
        uint256 optOut = _listBridged(T7, deadline, false);
        uint256 optIn = _listBridged(T21, deadline, true);
        uint256 credit = v2.cashCredit(borrower);
        _fundBridged(optOut, 4);
        _fundBridged(optIn, 4);
        uint256 fees;
        for (uint256 i; i < 2; ++i) {
            uint256 id = i == 0 ? optOut : optIn;
            V2Loan memory l = v2.getLoan(id);
            assertEq(uint256(l.state), uint256(V2State.ACTIVE));
            assertEq(uint256(l.borrowerReward) + l.lenderReward, 0);
            GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
            assertTrue(dealRewards.registered(a.legacyId));
            (uint128 total,,) = dealRewards.rewardOf(a.legacyId);
            assertEq(total, 0);
            assertEq(ledger.allocation(id).start, block.timestamp);
            fees += l.originationFee;
        }
        assertEq(v2.cashCredit(borrower) - credit, 2 * uint256(PRINCIPAL) - fees);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Launch as the owner, with epoch-0 rates posted as `TokenBaseTest` posts them.
    function _launch(uint40 at) internal {
        vm.startPrank(safe);
        emissions.launch(at);
        dealRewards.setEpochRates(0, 50e18, 100e18, 1e4, 5000);
        vm.stopPrank();
    }

    function _listBridged(uint32 term, uint40 deadline, bool withRewards) internal returns (uint256 id) {
        vm.prank(borrower);
        id = v2.list(
            Collateral(Kind.ERC20, address(nvda), 1e18),
            PRINCIPAL,
            PRINCIPAL + PRINCIPAL / 10,
            term,
            deadline,
            withRewards
        );
    }

    function _fundBridged(uint256 id, uint8 units) internal {
        vm.prank(lender);
        v2.fund(id, units);
    }

    /// @dev The start of every clock behind a bridged loan: the adapter's `_earned`, the Drips of both legacy clones
    /// (a missing Drip reads start 0), the V2 ledger's allocation, the core's activation and the legacy deal.
    function _assertClocksStartAt(uint256 id, uint40 at) internal view {
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        assertEq(a.start, at, "adapter");
        assertEq(drip.getDrip(a.borrower, dealRewards.dripIdOf(a.legacyId, a.borrower)).start, at, "borrower Drip");
        assertEq(drip.getDrip(a.lender, dealRewards.dripIdOf(a.legacyId, a.lender)).start, at, "lender Drip");
        assertEq(ledger.allocation(id).start, at, "ledger");
        assertEq(v2.getLoan(id).fundedAt, at, "core");
        assertEq(vault.getDeal(a.legacyId).fundedAt, at, "legacy deal");
    }

    /// @dev Claim everything the ledger shows for `account` and require it paid in full, leaving nothing outstanding.
    function _claimInFull(uint256 id, address account) internal returns (uint256 owed) {
        owed = ledger.claimable(id, account);
        assertGt(owed, 0);
        uint256 before = sgage.balanceOf(account);
        vm.prank(account);
        ledger.claim(id, account);
        assertEq(sgage.balanceOf(account) - before, owed);
        assertEq(ledger.claimable(id, account), 0);
    }
}
