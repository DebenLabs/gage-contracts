// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";

/// @notice Random but valid call sequences against the third Earn design. Every action checks the vault's own
/// preconditions first, so with `fail_on_revert = true` a revert is a real finding.
contract EarnHandler is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint8 internal constant UNITS = 4;
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;

    EarnVault public immutable EARN;
    GageV2Vault public immutable CORE;
    GageV2Rewards public immutable REWARDS;
    MockERC20 public immutable USDG;
    MockERC20 public immutable SGAGE;
    HybridReserveMock public immutable RESERVE;
    MockERC20[2] internal _tokens;
    address public immutable CURATOR;
    address public immutable BORROWER;
    address[3] public actors;
    address[3] internal _fillers;

    uint256[] public loanIds;
    mapping(uint256 => bool) public listed;
    // Ghosts.
    uint256 public ghostPushedUnharvested;
    uint256 public ghostReserveGains;
    uint256 public ghostReserveLosses;
    // Value conservation: USDG in and out of the strategy, and the outcomes it booked, from its own events.
    uint256 public ghostDeposited;
    uint256 public ghostRedeemed;
    uint256 public ghostEarnedLost;
    uint256 public ghostFeesPaid;
    uint256 public ghostProfit;
    uint256 public ghostFees;
    uint256 public ghostLosses;

    constructor(
        EarnVault earn,
        GageV2Vault core,
        MockERC20 usdg,
        MockERC20 sgage,
        HybridReserveMock reserve,
        MockERC20[2] memory tokens,
        address borrower
    ) {
        EARN = earn;
        CORE = core;
        REWARDS = core.REWARDS();
        USDG = usdg;
        SGAGE = sgage;
        RESERVE = reserve;
        _tokens = tokens;
        CURATOR = earn.CURATOR();
        BORROWER = borrower;
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("earn-actor", i)));
            usdg.mint(actors[i], 100_000_000e6);
            vm.prank(actors[i]);
            usdg.approve(address(earn), MAX);
            _fillers[i] = makeAddr(string(abi.encodePacked("earn-filler", i)));
            usdg.mint(_fillers[i], 100_000_000e6);
            vm.prank(_fillers[i]);
            usdg.approve(address(core), MAX);
        }
    }

    // ---------------------------------------------------------------- helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _due() internal view returns (bool) {
        return block.timestamp >= EARN.earliestMaturity();
    }

    function _loan(uint256 id) internal view returns (EarnVault.Loan memory ln) {
        (
            ln.slots,
            ln.lane,
            ln.feeBps,
            ln.maturity,
            ln.withdrawn,
            ln.settled,
            ln.recovered,
            ln.snapshotId,
            ln.principal,
            ln.snapshotSupply,
            ln.interest,
            ln.rate,
            ln.clockStart
        ) = EARN.loans(id);
    }

    function _openCount() internal view returns (uint256 open) {
        for (uint256 i; i < loanIds.length; ++i) {
            if (!_loan(loanIds[i]).settled) ++open;
        }
    }

    function _pick(uint256 seed) internal view returns (uint256 id, bool ok) {
        if (loanIds.length == 0) return (0, false);
        return (loanIds[seed % loanIds.length], true);
    }

    // ---------------------------------------------------------------- depositors

    function deposit(uint256 seed, uint256 amount) external {
        if (EARN.paused() || _due()) return;
        amount = bound(amount, EARN.MIN_DEPOSIT(), 50_000e6);
        if (EARN.totalAssets() + amount > EARN.maxTotalDeposits()) return;
        if (EARN.convertToShares(amount) == 0) return;
        vm.prank(_actor(seed));
        EARN.deposit(amount, 0);
        ghostDeposited += amount;
    }

    function redeem(uint256 seed, uint256 shareSeed) external {
        if (_due()) return;
        address who = _actor(seed);
        uint256 held = EARN.balanceOf(who);
        if (held == 0) return;
        uint256 shares = bound(shareSeed, 1, held);
        uint256 assets = EARN.convertToAssets(shares);
        if (assets > EARN.freeLiquidity()) return;
        vm.prank(who);
        ghostRedeemed += EARN.redeem(shares, 0);
    }

    function claimPocket(uint256 seed, uint256 pocketSeed) external {
        uint256 count = EARN.pocketCount();
        if (count == 0) return;
        uint256 pocketId = pocketSeed % count + 1;
        address who = _actor(seed);
        if (EARN.pocketClaimable(pocketId, who) == 0) return;
        (, address token,,,,) = EARN.pockets(pocketId);
        if (token != address(0) && MockERC20(token).blocked(who)) return;
        vm.prank(who);
        EARN.claimPocket(pocketId);
    }

    function claimRewards(uint256 seed) external {
        address who = _actor(seed);
        if (EARN.rewardClaimable(who) == 0) return;
        vm.prank(who);
        EARN.claimRewards();
    }

    // ---------------------------------------------------------------- reserve

    function investReserve(uint256 amount) external {
        uint256 held = EARN.cash();
        if (EARN.paused() || held == 0) return;
        amount = bound(amount, 1, held);
        vm.prank(CURATOR);
        EARN.investReserve(amount, 0);
    }

    function divestReserve(uint256 shares) external {
        uint256 held = EARN.reserveShares();
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(CURATOR);
        EARN.divestReserve(shares, 0);
    }

    function reserveGain(uint256 amount) external {
        if (RESERVE.totalSupply() == 0) return;
        amount = bound(amount, 1, 1000e6);
        USDG.mint(address(this), amount);
        USDG.approve(address(RESERVE), amount);
        RESERVE.donate(amount);
        ghostReserveGains += amount;
    }

    function reserveLoss(uint256 amount) external {
        uint256 held = USDG.balanceOf(address(RESERVE));
        if (held < 2) return;
        amount = bound(amount, 1, held / 2);
        RESERVE.simulateLoss(amount, address(0xdead));
        ghostReserveLosses += amount;
    }

    // ---------------------------------------------------------------- loans

    function curatorFunds(uint256 tokenSeed, uint256 principalSeed, uint256 premiumSeed, uint8 units) external {
        if (EARN.paused() || _due()) return;
        if (_openCount() >= EARN.MAX_OPEN_LOANS()) return;
        MockERC20 token = _tokens[tokenSeed % 2];
        EarnLane lane = tokenSeed % 2 == 0 ? EarnLane.STOCK : EarnLane.MEME;
        uint128 principal = uint128(bound(principalSeed, 100e6, 5000e6));
        uint128 cap = principal + uint128(Math.mulDiv(principal, bound(premiumSeed, 100, 1000), 10_000));
        units = uint8(bound(units, 1, UNITS));
        uint256 cost;
        for (uint8 i; i < units; ++i) {
            cost += principal / UNITS + (i < principal % UNITS ? 1 : 0);
        }
        uint256 assets = EARN.totalAssets();
        if (EARN.lanePrincipal(lane) + cost > Math.mulDiv(EARN.laneWeightBps(lane), assets, 10_000)) return;
        // The curator's bounds (D153): cap per listing, cap per token, the buffer a fill must leave liquid.
        uint256 loanCap = EARN.maxLoanPrincipal();
        if (loanCap != 0 && cost > loanCap) return;
        uint256 assetCap = EARN.maxAssetBps();
        if (assetCap != 0 && EARN.assetPrincipal(address(token)) + cost > Math.mulDiv(assetCap, assets, 10_000)) {
            return;
        }
        if (cost + Math.mulDiv(EARN.bufferBps(), assets, 10_000) > EARN.freeLiquidity()) return;
        token.mint(BORROWER, 10e18);
        vm.startPrank(BORROWER);
        token.approve(address(CORE), 10e18);
        uint256 id = CORE.list(
            Collateral(Kind.ERC20, address(token), 10e18),
            principal,
            cap,
            tokenSeed % 3 == 0 ? T21 : T7,
            uint40(block.timestamp + 1 days),
            true
        );
        vm.stopPrank();
        vm.prank(CURATOR);
        EARN.fund(id, units, MAX);
        loanIds.push(id);
        listed[id] = true;
    }

    function fillLoan(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.FUNDING || block.timestamp >= l.fundingDeadline) return;
        address[4] memory lenders = CORE.lenders(id);
        for (uint8 i; i < UNITS; ++i) {
            if (lenders[i] != address(0)) continue;
            vm.prank(_fillers[i % 3]);
            CORE.fund(id, 1);
        }
    }

    function borrowerRepays(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE) return;
        // No grace window: the core closes repayment the second the term ends.
        if (block.timestamp >= uint256(l.fundedAt) + l.term) return;
        vm.prank(BORROWER);
        CORE.reclaim(id, BORROWER);
    }

    function borrowerCancels(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        if (CORE.getLoan(id).state != V2State.FUNDING) return;
        vm.prank(BORROWER);
        CORE.cancelFunding(id);
    }

    /// @dev Anyone may finalize a default on the core once the term ends; the strategy must then read DEFAULTED.
    function thirdPartyFinalizesDefault(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE || block.timestamp < uint256(l.fundedAt) + l.term) return;
        vm.prank(_fillers[0]);
        CORE.finalizeDefault(id);
    }

    /// @dev Someone else delivers the vault's core credit; the vault must reconcile it at the next harvest.
    function withdrawCommitment(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        EarnVault.Loan memory ln = _loan(id);
        if (ln.withdrawn || ln.settled || CORE.getLoan(id).state != V2State.FUNDING) return;
        vm.prank(CURATOR);
        EARN.withdrawCommitment(id);
    }

    function pushCoreCredit() external {
        uint256 credit = CORE.cashCredit(address(EARN));
        if (credit == 0) return;
        CORE.withdrawUSDGFor(address(EARN));
        ghostPushedUnharvested += credit;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 3 days));
    }

    function warpPastMaturity() external {
        uint40 end = EARN.earliestMaturity();
        if (end == type(uint40).max || block.timestamp >= end) return;
        vm.warp(end);
    }

    function settle(uint256 seed) external {
        uint256 length = loanIds.length;
        uint256 start = length == 0 ? 0 : seed % length;
        uint256 n = length - start > 32 ? 32 : length - start;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = loanIds[start + i];
        }
        vm.recordLogs();
        EARN.settle(ids);
        ghostPushedUnharvested = 0;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(EARN)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("ProfitReported(uint256,uint256,uint256)")) {
                (uint256 profit, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
                ghostProfit += profit;
                ghostFees += fee;
            } else if (topic == keccak256("LossReported(uint256,uint256,uint256)")) {
                // A write-off loses the principal and the interest the loan had already earned into the price.
                (uint256 principalLost, uint256 earned) = abi.decode(logs[i].data, (uint256, uint256));
                ghostLosses += principalLost + earned;
                ghostEarnedLost += earned;
            }
        }
    }

    function recover(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        EarnVault.Loan memory ln = _loan(id);
        if (ln.snapshotId == 0 || ln.recovered) return;
        if (CORE.getLoan(id).state != V2State.DEFAULTED) return;
        EARN.recover(id);
    }

    function harvestRewards(uint256 seed) external {
        uint256 length = loanIds.length;
        if (length == 0) return;
        uint256 start = seed % length;
        uint256 n = length - start > 32 ? 32 : length - start;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = loanIds[start + i];
        }
        EARN.harvestRewards(ids);
    }

    function claimFees() external {
        ghostFeesPaid += EARN.curatorFees() + EARN.protocolFees();
        EARN.claimFees();
    }

    // ---------------------------------------------------------------- curator

    function setLaneWeight(uint256 laneSeed, uint16 bps) external {
        EarnLane lane = EarnLane(laneSeed % 3);
        bps = uint16(bound(bps, 0, 10_000));
        vm.prank(CURATOR);
        EARN.setLaneWeight(lane, bps);
    }

    function setFee(uint16 bps) external {
        vm.prank(CURATOR);
        EARN.setFee(uint16(bound(bps, 0, 5000)));
    }

    function setLimits(uint128 loanCap, uint16 assetBps, uint16 bufferBps) external {
        vm.prank(CURATOR);
        EARN.setLimits(
            uint128(bound(loanCap, 0, 10_000e6)),
            uint16(bound(assetBps, 0, 10_000)),
            uint16(bound(bufferBps, 0, 10_000))
        );
    }

    function setMaxTotalDeposits(uint128 cap) external {
        vm.prank(CURATOR);
        EARN.setMaxTotalDeposits(uint128(bound(cap, 0, 10_000_000e6)));
    }

    function setPaused(bool enabled) external {
        vm.prank(CURATOR);
        EARN.setPaused(enabled);
    }

    // ---------------------------------------------------------------- views for the invariants

    function loanCount() external view returns (uint256) {
        return loanIds.length;
    }
}
