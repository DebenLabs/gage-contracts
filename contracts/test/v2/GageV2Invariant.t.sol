// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {TokenBaseTest} from "../token/TokenBase.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2CollateralAccount} from "../../src/v2/GageV2CollateralAccount.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {IDealVault, DealState} from "../../src/interfaces/IDealVault.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State, V2Ask, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";
import {cashOwed} from "../helpers/CoreCash.sol";

using {unitsOf, cashOwed} for GageV2Vault;

contract V2Handler is Test {
    GageV2Vault public immutable VAULT;
    GageV2Rewards public immutable REWARDS;
    GageLegacyAdapter public immutable BRIDGE;
    IDealVault public immutable LEGACY;
    MockERC20 public immutable USDG;
    MockERC20 public immutable COLLATERAL;
    address[5] public actors;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public legacyFees;
    mapping(bytes32 => uint256) public calls;
    mapping(uint256 => mapping(address => bool)) public recovered;

    constructor(GageV2Vault vault, MockERC20 usdg, MockERC20 collateral) {
        VAULT = vault;
        USDG = usdg;
        COLLATERAL = collateral;
        REWARDS = vault.REWARDS();
        BRIDGE = vault.BRIDGE();
        LEGACY = BRIDGE.VAULT();
        for (uint256 i; i < 5; ++i) {
            actors[i] = address(uint160(0x1100 + i));
            vm.startPrank(actors[i]);
            usdg.approve(address(vault), type(uint256).max);
            collateral.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function list(uint8 who, uint128 raw, bool longTerm) external {
        if (VAULT.loanCount() >= 24) return;
        address actor = actors[who % 5];
        uint128 principal = uint128(bound(raw, 4, 1_000_000e6));
        COLLATERAL.mint(actor, 1e18);
        vm.prank(actor);
        VAULT.list(
            Collateral(Kind.ERC20, address(COLLATERAL), 1e18),
            principal,
            principal + principal / 10,
            longTerm ? 21 days : 7 days,
            uint40(block.timestamp + 1 days),
            false
        );
        calls["list"]++;
    }

    function fund(uint256 seed, uint8 who, uint8 unitsSeed) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.FUNDING || block.timestamp >= l.fundingDeadline) return;
        uint8 units = uint8(bound(unitsSeed, 1, 4 - l.filled));
        address actor = actors[who % 5];
        USDG.mint(actor, l.principal);
        uint256 beforeBalance = USDG.balanceOf(actor);
        vm.prank(actor);
        VAULT.fund(id, units);
        deposited += beforeBalance - USDG.balanceOf(actor);
        if (l.filled + units == 4) legacyFees += l.originationFee;
        calls["fund"]++;
    }

    function refund(uint256 seed, uint8 who) external {
        uint256 id = _id(seed);
        address actor = actors[who % 5];
        if (VAULT.getLoan(id).state != V2State.FUNDING || VAULT.unitsOf(id, actor) == 0) return;
        vm.prank(actor);
        VAULT.withdrawCommitment(id);
        calls["refund"]++;
    }

    function cancel(uint256 seed) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.FUNDING) return;
        vm.prank(l.originator);
        VAULT.cancelFunding(id);
        calls["cancel"]++;
    }

    function sell(uint256 seed, uint8 who, uint128 raw) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.ACTIVE || block.timestamp + 1 hours >= uint256(l.fundedAt) + l.term + VAULT.GRACE()) {
            return;
        }
        address seller = VAULT.ownerOf(id);
        address buyer = actors[who % 5];
        uint128 price = uint128(bound(raw, 1, 100_000e6));
        vm.prank(seller);
        VAULT.setAskWithMaxFee(id, price, uint40(block.timestamp + 1 hours), type(uint16).max);
        V2Ask memory ask = VAULT.getAsk(id);
        USDG.mint(buyer, price);
        vm.prank(buyer);
        VAULT.buy(id, seller, ask.nonce, price, 100, buyer);
        deposited += price;
        calls["sale"]++;
    }

    function repay(uint256 seed) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.ACTIVE || block.timestamp >= uint256(l.fundedAt) + l.term + VAULT.GRACE()) return;
        address actor = VAULT.ownerOf(id);
        USDG.mint(actor, l.cap);
        vm.prank(actor);
        VAULT.reclaim(id, actor);
        deposited += l.cap;
        calls["repay"]++;
    }

    function sellLender(uint256 seed, uint8 slotSeed, uint8 who, uint128 raw) external {
        uint256 id = _id(seed);
        if (VAULT.getLoan(id).state != V2State.ACTIVE) return;
        uint8 slot = slotSeed % 4;
        address seller = VAULT.lenders(id)[slot];
        address buyer = actors[who % 5];
        if (seller == buyer) return;
        uint128 price = uint128(bound(raw, 1, 100_000e6));
        uint8 mask = uint8(1 << slot);
        uint40 deadline = _askDeadline(id);
        vm.prank(seller);
        VAULT.setLenderAsk(id, mask, price, deadline, 100);
        V2LenderAsk memory ask = VAULT.getLenderAsk(id, seller);
        USDG.mint(buyer, price);
        // One recipient for the whole bundle, the payer itself; no reward bound.
        address[4] memory to = [buyer, buyer, buyer, buyer];
        uint128[4] memory none;
        vm.prank(buyer);
        VAULT.buyLenderSplit(id, V2LenderSplit(seller, mask, price, 100, ask.nonce, to, none));
        deposited += price;
        calls["lenderSale"]++;
    }

    /// @dev S9: one seller's ask over the quarters it holds, bought once and delivered to several recipients.
    function splitLender(uint256 seed, uint8 maskSeed, uint256 recipientSeed, uint8 payer, uint128 raw) external {
        uint256 id = _id(seed);
        if (VAULT.getLoan(id).state != V2State.ACTIVE) return;
        address[4] memory owners = VAULT.lenders(id);
        address seller = owners[maskSeed % 4];
        uint8 mask;
        for (uint8 i; i < 4; ++i) {
            if (owners[i] == seller && (maskSeed >> (i + 2)) & 1 == 1) mask |= uint8(1 << i);
        }
        if (mask == 0) mask = uint8(1 << (maskSeed % 4));
        V2LenderSplit memory p;
        p.seller = seller;
        p.slots = mask;
        p.price = uint128(bound(raw, 1, 100_000e6));
        p.maxFeeBps = 100;
        for (uint8 i; i < 4; ++i) {
            address r = actors[(recipientSeed >> (8 * i)) % 5];
            if (r == seller) r = actors[(uint256(uint160(seller)) + 1) % 5] == seller ? actors[0] : actors[4];
            if (r == seller) return;
            p.recipients[i] = r;
        }
        uint40 deadline = _askDeadline(id);
        vm.prank(seller);
        VAULT.setLenderAsk(id, mask, p.price, deadline, 100);
        p.nonce = VAULT.getLenderAsk(id, seller).nonce;
        address buyer = actors[payer % 5];
        USDG.mint(buyer, p.price);
        vm.prank(buyer);
        VAULT.buyLenderSplit(id, p);
        deposited += p.price;
        calls["lenderSplit"]++;
    }

    function finalizeDefault(uint256 seed) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.ACTIVE || block.timestamp < uint256(l.fundedAt) + l.term + VAULT.GRACE()) return;
        VAULT.finalizeDefault(id);
        calls["default"]++;
    }

    function withdrawCollateral(uint256 seed) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.REPAID && l.state != V2State.CANCELLED) return;
        if (GageV2CollateralAccount(payable(l.account)).released()) return;
        vm.prank(l.collateralBeneficiary);
        VAULT.withdrawCollateral(id, l.collateralBeneficiary);
        calls["collateral"]++;
    }

    function recover(uint256 seed, uint8 who) external {
        uint256 id = _id(seed);
        V2Loan memory l = VAULT.getLoan(id);
        address actor = actors[who % 5];
        if (l.state != V2State.DEFAULTED || VAULT.unitsOf(id, actor) == 0 || recovered[id][actor]) return;
        bool ready = GageV2CollateralAccount(payable(l.account)).recovered();
        vm.startPrank(actor);
        if (!ready) VAULT.recoverDefault(id, 0, 0, block.timestamp);
        VAULT.withdrawRecovery(id, 0, actor);
        vm.stopPrank();
        recovered[id][actor] = true;
        calls["recovery"]++;
    }

    function claim(uint256 seed, uint8 who) external {
        uint256 id = _id(seed);
        address actor = actors[who % 5];
        // Claim at the current timestamp; repeated actions also exercise source/ledger rounding boundaries.
        if (REWARDS.claimable(id, actor) == 0) return;
        vm.prank(actor);
        REWARDS.claim(id, actor);
        calls["reward"]++;
    }

    function recycle(uint256 seed) external {
        uint256 id = BRIDGE.adapterId(address(VAULT), _id(seed));
        if (id == 0 || BRIDGE.loan(id).closedAt == 0) return;
        BRIDGE.recycle(id);
        calls["recycle"]++;
    }

    /// @notice Anyone claims the receipt of a defaulted loan's legacy deal once the legacy grace has passed.
    function settleLegacy(uint256 seed) external {
        uint256 id = BRIDGE.adapterId(address(VAULT), _id(seed));
        if (id == 0) return;
        GageLegacyAdapter.Loan memory l = BRIDGE.loan(id);
        if (l.closedAt == 0 || LEGACY.getDeal(l.legacyId).state != DealState.FUNDED) return;
        if (block.timestamp < LEGACY.claimableAt(l.legacyId)) return;
        BRIDGE.settleLegacy(id);
        calls["legacy"]++;
    }

    function withdrawCash(uint8 who) external {
        address actor = who % 6 == 5 ? VAULT.FEE_RECIPIENT() : actors[who % 5];
        uint256 amount = VAULT.cashCredit(actor);
        if (amount == 0) return;
        VAULT.withdrawUSDGFor(actor);
        withdrawn += amount;
        calls["cash"]++;
    }

    function advance(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 10 days));
    }

    /// @dev An hour out, but an ask posted while the loan can be repaid ends with that window (D162).
    function _askDeadline(uint256 id) private view returns (uint40) {
        V2Loan memory l = VAULT.getLoan(id);
        uint256 windowEnd = uint256(l.fundedAt) + l.term + VAULT.GRACE();
        uint256 deadline = block.timestamp + 1 hours;
        return uint40(block.timestamp < windowEnd && deadline > windowEnd ? windowEnd : deadline);
    }

    function _id(uint256 seed) private view returns (uint256) {
        uint256 count = VAULT.loanCount();
        return count == 0 ? 0 : 1 + seed % count;
    }
}

contract GageV2InvariantTest is TokenBaseTest {
    GageV2Vault internal v2;
    GageLegacyAdapter internal bridge;
    V2Handler internal handler;

    function setUp() public override {
        super.setUp();
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
        // Release shape (D44): the token-only registry (token admission checked inside the core), and no grace window on the engine while the legacy
        // vault behind the bridge keeps its 48 hours.
        v2 = new GageV2Vault(cfg, IERC20(address(usdg)), IERC20(address(sgage)), treasury, 0, bridge);
        bridge.setEngine(address(v2));
        // An engine lends to no one until a funder gate is bound (D47); the handler's accounts stand in for vaults.
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        v2.REWARDS().bindFunderGate(openGate);
        handler = new V2Handler(v2, usdg, nvda);
        // Seed an active and a partially funded loan so all transitions are reachable from the first run.
        handler.list(0, 1000e6, false);
        handler.fund(0, 1, 2);
        handler.fund(0, 2, 2);
        handler.list(1, 999_999_999, true);
        handler.fund(1, 0, 1);
        targetContract(address(handler));
    }

    function invariant_cashEqualsDepositsLessWithdrawalsAndExactlyOneOriginationFee() public view {
        uint256 cash = usdg.balanceOf(address(v2));
        assertEq(cash, handler.deposited() - handler.withdrawn() - handler.legacyFees());
        // The same cash is exactly what the core owes: every account's credit plus unactivated contributions.
        address[] memory holders = new address[](6);
        for (uint256 i; i < 5; ++i) {
            holders[i] = handler.actors(i);
        }
        holders[5] = v2.FEE_RECIPIENT();
        assertEq(cash, v2.cashOwed(holders));
        assertEq(usdg.balanceOf(address(bridge)), 0);
    }

    function invariant_everyLiquidSourceTokenIsAllocatedOrFreeAndEveryReceiptBacksOneUnsettledLegacyDeal() public view {
        uint256 liquid = bridge.recycledFree();
        uint256 receipts;
        for (uint256 id = 1; id <= bridge.loanCount(); ++id) {
            GageLegacyAdapter.Loan memory l = bridge.loan(id);
            liquid += l.liquid;
            // One receipt sits in the legacy vault for every open loan and every default not yet settled there.
            if (l.closedAt == 0 || vault.getDeal(l.legacyId).state == DealState.FUNDED) ++receipts;
            assertEq(l.engine, address(v2));
            assertEq(l.ledger, address(v2.REWARDS()));
            assertLe(l.paid, uint256(l.borrowerReward) + l.lenderReward);
        }
        assertEq(sgage.balanceOf(address(bridge)), liquid);
        assertEq(bridge.totalSupply(), receipts);
        assertEq(sgage.balanceOf(address(v2.REWARDS())), 0);
    }

    function invariant_legacyDealsFollowTheEngineAndNeverRepayAfterADefault() public view {
        // Walk the engine's loans; together they must reach every adapter loan (all of them are v2's).
        uint256 seen;
        for (uint256 engineId = 1; engineId <= v2.loanCount(); ++engineId) {
            uint256 id = bridge.adapterId(address(v2), engineId);
            if (id == 0) continue;
            ++seen;
            GageLegacyAdapter.Loan memory l = bridge.loan(id);
            V2Loan memory engineLoan = v2.getLoan(engineId);
            DealState legacy = vault.getDeal(l.legacyId).state;
            if (engineLoan.state == V2State.ACTIVE) {
                // Past maturity the loan may still read ACTIVE until anyone finalizes it; it can no longer be repaid.
                assertEq(l.closedAt, 0, "an active loan is open on the adapter");
                assertEq(uint256(legacy), uint256(DealState.FUNDED), "an active loan is funded on V1");
            } else if (engineLoan.state == V2State.REPAID) {
                assertLt(uint256(engineLoan.closedAt), uint256(engineLoan.fundedAt) + engineLoan.term, "on time");
                assertEq(l.closedAt, engineLoan.closedAt);
                assertEq(uint256(legacy), uint256(DealState.RECLAIMED), "a repayment reclaims the V1 deal");
            } else {
                assertEq(uint256(engineLoan.state), uint256(V2State.DEFAULTED));
                assertEq(l.closedAt, engineLoan.closedAt);
                assertGe(uint256(l.closedAt), uint256(engineLoan.fundedAt) + engineLoan.term, "default at maturity");
                assertTrue(legacy == DealState.FUNDED || legacy == DealState.CLAIMED, "never repaid after a default");
                if (legacy == DealState.CLAIMED) assertEq(bridge.balanceOf(l.lender), 0);
            }
        }
        assertEq(seen, bridge.loanCount());
    }

    function invariant_rewardLedgerPreservesEarnedClaimsAndOnlyActiveFutureAllocations() public view {
        uint256 liability;
        GageV2Rewards r = v2.REWARDS();
        for (uint256 id = 1; id <= v2.loanCount(); ++id) {
            V2Loan memory l = v2.getLoan(id);
            for (uint256 i; i < 5; ++i) {
                liability += r.claimable(id, handler.actors(i));
            }
            GageV2Rewards.Allocation memory a = r.allocation(id);
            if (a.start != 0) {
                // The ledger does not re-read the adapter: the core's call order keeps both records identical.
                GageLegacyAdapter.Loan memory s = bridge.loan(bridge.adapterId(address(v2), id));
                assertEq(s.ledger, address(r));
                assertEq(s.engine, address(v2));
                assertEq(s.start, a.start);
                assertEq(s.closedAt, a.end);
                assertEq(s.borrowerReward, a.borrowerTotal);
                assertEq(s.lenderReward, a.lenderTotal);
            }
            if (l.state == V2State.ACTIVE) {
                uint256 elapsed = block.timestamp - l.fundedAt;
                if (elapsed > l.term) elapsed = l.term;
                liability += uint256(l.borrowerReward) - uint256(l.borrowerReward) * elapsed * elapsed
                / (uint256(l.term) * l.term);
                liability += uint256(l.lenderReward) - uint256(l.lenderReward) * elapsed * elapsed
                / (uint256(l.term) * l.term);
            }
        }
        // The ledger keeps no liability counter of its own; the adapter's records must owe exactly the same: each
        // loan's allocation while open, its earned part once closed, less what it has paid to the ledger.
        uint256 owed;
        for (uint256 id = 1; id <= bridge.loanCount(); ++id) {
            GageLegacyAdapter.Loan memory s = bridge.loan(id);
            if (s.start == 0) continue;
            if (s.closedAt == 0) {
                owed += uint256(s.borrowerReward) + s.lenderReward - s.paid;
            } else {
                uint256 elapsed = s.closedAt - s.start;
                if (elapsed > s.term) elapsed = s.term;
                uint256 square = elapsed * elapsed;
                uint256 denominator = uint256(s.term) * s.term;
                owed += Math.mulDiv(s.borrowerReward, square, denominator)
                + Math.mulDiv(s.lenderReward, square, denominator) - s.paid;
            }
        }
        assertEq(owed, liability);
    }
}
