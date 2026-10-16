// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HybridVault, EarnLane} from "../../src/HybridVault.sol";
import {HybridFees} from "../../src/HybridFees.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {ICollateralRegistry, Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";

/// @dev Only valid calls reach the contracts: fail_on_revert must remain true. Every ghost ledger is built from
/// call inputs, return values, token balance deltas, reserve previews, emitted per-action events and independent
/// models of the queue, the fee and the pockets; none is copied from the vault's own totals.
contract HybridHandler is Test {
    uint256 public constant ACTOR_COUNT = 6;
    uint8 internal constant UNITS = 4;
    uint256 internal constant PRICE_PRECISION = 1e36;
    uint256 internal constant REWARD_PRECISION = 1e18;
    uint256 internal constant HYBRID_MAX_FEE_BPS = 5000;
    uint256 internal constant MAX_OPEN_LOANS = 32;
    uint256 internal constant MAX_APPROVALS = 64;
    uint256 internal constant BATCH = 8;
    bytes32 internal constant REQUEST_SERVED = keccak256("RequestServed(uint256,address,uint256,uint256,uint256)");
    bytes32 internal constant REQUEST_CANCELLED = keccak256("RequestCancelled(uint256,address,uint256)");
    bytes32 internal constant PROFIT_REPORTED = keccak256("ProfitReported(uint256,uint256,uint256,uint256,uint64)");
    HybridVault public immutable HYBRID;
    GageV2Vault public immutable CORE;
    GageV2Rewards public immutable CORE_REWARDS;
    MockERC20 public immutable CASH;
    MockERC20 public immutable REWARD;
    HybridReserveMock public immutable RESERVE;
    uint256 public immutable VIRTUAL_SHARES;
    HybridVault.Params internal _params;
    address[6] public actors;
    address[6] public borrowers;
    address[3] public fillers;
    MockERC20[2] public tokens;
    uint256[] public approvedIds;
    uint256[] public fundedIds;
    mapping(bytes4 => uint256) public calls;
    bool public liquid = true;
    // Shares, requests and claims.
    mapping(address => uint256) public ghostShares;
    mapping(address => uint256) public ghostLocked;
    mapping(address => uint256) public ghostClaimable;
    uint256 public ghostSupply;
    uint256 public ghostPending;
    uint256 public ghostClaimableTotal;
    uint256 public ghostRequestCount;
    uint256 public ghostQueueHead = 1;
    mapping(uint256 => address) public ghostRequestOwner;
    mapping(uint256 => uint256) public ghostRequestShares;
    // USDG flows.
    uint256 public ghostDeposits;
    uint256 public ghostPaidOut;
    uint256 public ghostClaimed;
    uint256 public ghostPocketPaidUSDG;
    uint256 public ghostFeesPaid;
    uint256 public ghostFeesModeled;
    uint256 public ghostFeesReported;
    uint256 public ghostNetProfitReported;
    uint256 public ghostReserveDeposits;
    uint256 public ghostReserveRedemptions;
    uint256 public ghostReserveSharesMinted;
    uint256 public ghostReserveSharesBurned;
    uint256 public ghostReserveGains;
    uint256 public ghostReserveLosses;
    uint256 public ghostLossAgainstLock;
    uint256 public ghostFundedPrincipal;
    uint256 public ghostCoreReturns;
    uint256 public ghostHarvestedCash;
    uint256 public ghostAssignedCash;
    uint256 public highWaterSeen;
    // Loans.
    uint256 public ghostPerforming;
    uint256 public ghostOverdue;
    mapping(EarnLane => uint256) public ghostLanePrincipal;
    mapping(address => uint256) public ghostBorrowerPrincipal;
    mapping(uint256 => uint8) public ghostSlots;
    mapping(uint256 => uint256) public ghostPositionPrincipal;
    mapping(uint256 => EarnLane) public ghostLoanLane;
    mapping(uint256 => uint16) public ghostLoanFee;
    mapping(uint256 => address) public ghostBorrower;
    mapping(uint256 => bool) public ghostWithdrawn;
    mapping(uint256 => bool) public ghostTerminal;
    mapping(uint256 => bool) public ghostOverdueFlag;
    mapping(uint256 => uint256) public ghostLoanSnapshotSupply;
    mapping(uint256 => mapping(address => uint256)) public ghostLoanBalanceAt;
    // Pockets.
    uint256 public ghostPocketCount;
    mapping(uint256 => address) public ghostPocketToken;
    mapping(uint256 => uint256) public ghostPocketAmount;
    mapping(uint256 => uint256) public ghostPocketSupply;
    mapping(uint256 => uint256) public ghostPocketClaimedTotal;
    mapping(uint256 => mapping(address => uint256)) public ghostBalanceAt;
    mapping(uint256 => mapping(address => bool)) public ghostPocketClaimed;
    // Rewards.
    uint256 public ghostRewardsHarvested;
    uint256 public ghostRewardsAccrued;
    uint256 public ghostRewardsPaid;
    uint256 public ghostRewardRemainder;
    uint256 public ghostRewardOrphan;
    uint256 public ghostRewardDust;
    mapping(address => uint256) public ghostRewardsPaidTo;

    struct Checkpoint {
        uint256 full;
        uint256 rawLocked;
        uint256 storedLocked;
        uint256 mark;
        uint256 fees;
        uint256 netProfit;
    }

    constructor(
        HybridVault hybrid,
        GageV2Vault core,
        MockERC20 cash,
        HybridReserveMock reserve,
        MockERC20[2] memory ts
    ) {
        HYBRID = hybrid;
        CORE = core;
        CORE_REWARDS = core.REWARDS();
        CASH = cash;
        REWARD = MockERC20(address(core.SGAGE()));
        RESERVE = reserve;
        VIRTUAL_SHARES = hybrid.VIRTUAL_SHARES();
        _params = hybrid.params();
        tokens = ts;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address who = address(uint160(0x1100 + i));
            actors[i] = who;
            borrowers[i] = address(uint160(0x2200 + i));
            cash.mint(who, 10_000_000e6);
            cash.mint(borrowers[i], 10_000_000e6);
            vm.prank(who);
            cash.approve(address(hybrid), type(uint256).max);
            vm.prank(borrowers[i]);
            cash.approve(address(core), type(uint256).max);
            for (uint256 t; t < 2; ++t) {
                ts[t].mint(borrowers[i], 1_000_000e18);
                vm.prank(borrowers[i]);
                ts[t].approve(address(core), type(uint256).max);
            }
            _deposit(who, 2000e6);
        }
        for (uint256 i; i < fillers.length; ++i) {
            fillers[i] = address(uint160(0x5500 + i));
            cash.mint(fillers[i], 100_000_000e6);
            vm.prank(fillers[i]);
            cash.approve(address(core), type(uint256).max);
        }
        cash.approve(address(reserve), type(uint256).max);
        highWaterSeen = hybrid.highWaterPrice();
    }

    /// @dev The vault mark can only move up; checked around every action.
    modifier monotone() {
        assertGe(HYBRID.highWaterPrice(), highWaterSeen, "the high-water price fell");
        _;
        assertGe(HYBRID.highWaterPrice(), highWaterSeen, "the high-water price fell");
        highWaterSeen = HYBRID.highWaterPrice();
    }

    function fundedCount() external view returns (uint256) {
        return fundedIds.length;
    }

    function approvedCount() external view returns (uint256) {
        return approvedIds.length;
    }

    // ---------------------------------------------------------------- depositors

    /// @notice Deposit owned USDG for shares at the quoted price.
    function deposit(uint256 actorSeed, uint256 amountSeed) external monotone {
        address who = actors[actorSeed % ACTOR_COUNT];
        if (HYBRID.paused()) return;
        _syncCheckpoint();
        uint256 full = HYBRID.fullAssets();
        if (full >= _params.maxTotalDeposits) return;
        uint256 maximum = Math.min(_params.maxTotalDeposits - full, 5000e6);
        if (maximum < _params.minDeposit) return;
        _deposit(who, bound(amountSeed, _params.minDeposit, maximum));
        ++calls[this.deposit.selector];
    }

    function _deposit(address who, uint256 assets) internal {
        uint256 expected = HYBRID.convertToShares(assets);
        if (expected == 0) return;
        uint256 before_ = CASH.balanceOf(who);
        vm.prank(who);
        uint256 shares = HYBRID.deposit(assets, expected);
        assertEq(shares, expected, "deposit must mint its quote");
        assertEq(before_ - CASH.balanceOf(who), assets, "deposit must pull exactly its amount");
        _balanceChanged(who);
        ghostShares[who] += shares;
        ghostSupply += shares;
        ghostDeposits += assets;
    }

    /// @notice Burn free shares for USDG at once, within cash plus reserve liquidity.
    function redeem(uint256 actorSeed, uint256 sharesSeed) external monotone {
        address who = actors[actorSeed % ACTOR_COUNT];
        _syncCheckpoint();
        uint256 free = ghostShares[who] - ghostLocked[who];
        if (free == 0) return;
        uint256 shares = bound(sharesSeed, 1, free);
        uint256 assets = HYBRID.convertToAssets(shares);
        if (assets == 0 || assets > _freeLiquidity()) return;
        uint256 need = _reserveNeed(assets);
        uint256 burned = need == 0 ? 0 : RESERVE.previewWithdraw(need);
        uint256 before_ = CASH.balanceOf(who);
        uint256 reserveBefore = RESERVE.balanceOf(address(HYBRID));
        vm.prank(who);
        uint256 paid = HYBRID.redeem(shares, assets);
        assertEq(paid, assets, "redeem must pay its quote");
        assertEq(CASH.balanceOf(who) - before_, assets, "redeem must deliver its amount");
        assertEq(reserveBefore - RESERVE.balanceOf(address(HYBRID)), burned, "redeem burned unexpected reserve shares");
        _paidOut(who, shares, assets, need, burned);
        ++calls[this.redeem.selector];
    }

    /// @notice Take exact USDG at once, burning the rounded-up share amount.
    function withdraw(uint256 actorSeed, uint256 amountSeed) external monotone {
        address who = actors[actorSeed % ACTOR_COUNT];
        _syncCheckpoint();
        uint256 free = ghostShares[who] - ghostLocked[who];
        uint256 available = Math.min(HYBRID.convertToAssets(free), _freeLiquidity());
        if (free == 0 || available == 0) return;
        uint256 assets = bound(amountSeed, 1, available);
        uint256 shares = HYBRID.previewWithdraw(assets);
        if (shares == 0 || shares > free) return;
        uint256 need = _reserveNeed(assets);
        uint256 burned = need == 0 ? 0 : RESERVE.previewWithdraw(need);
        uint256 before_ = CASH.balanceOf(who);
        uint256 reserveBefore = RESERVE.balanceOf(address(HYBRID));
        vm.prank(who);
        uint256 used = HYBRID.withdraw(assets, shares);
        assertEq(used, shares, "withdraw must burn its quote");
        assertEq(CASH.balanceOf(who) - before_, assets, "withdraw must deliver its amount");
        assertEq(reserveBefore - RESERVE.balanceOf(address(HYBRID)), burned, "withdraw burned unexpected shares");
        _paidOut(who, shares, assets, need, burned);
        ++calls[this.withdraw.selector];
    }

    function _paidOut(address who, uint256 shares, uint256 assets, uint256 need, uint256 burned) internal {
        _balanceChanged(who);
        if (shares == ghostSupply) ghostRewardRemainder = 0;
        ghostShares[who] -= shares;
        ghostSupply -= shares;
        ghostPaidOut += assets;
        ghostReserveRedemptions += need;
        ghostReserveSharesBurned += burned;
    }

    /// @notice Queue free shares for redemption; they stay owned and priced until served.
    function requestRedeem(uint256 actorSeed, uint256 sharesSeed) external monotone {
        address who = actors[actorSeed % ACTOR_COUNT];
        uint256 free = ghostShares[who] - ghostLocked[who];
        if (free == 0) return;
        uint256 shares = bound(sharesSeed, 1, free);
        vm.prank(who);
        uint256 id = HYBRID.requestRedeem(shares);
        assertEq(id, ++ghostRequestCount, "request ids are sequential");
        ghostRequestOwner[id] = who;
        ghostRequestShares[id] = shares;
        ghostLocked[who] += shares;
        ghostPending += shares;
        ++calls[this.requestRedeem.selector];
    }

    /// @notice The owner withdraws an unserved request.
    function cancelRequest(uint256 idSeed) external monotone {
        if (ghostRequestCount == 0) return;
        uint256 id = 1 + idSeed % ghostRequestCount;
        uint256 shares = ghostRequestShares[id];
        if (shares == 0) return;
        address who = ghostRequestOwner[id];
        vm.prank(who);
        HYBRID.cancelRequest(id);
        ghostRequestShares[id] = 0;
        ghostLocked[who] -= shares;
        ghostPending -= shares;
        ++calls[this.cancelRequest.selector];
    }

    /// @notice Serve the queue oldest first; the served chunks are checked against an independent FIFO model.
    function serveRequests(uint256 countSeed, uint256 assetsSeed) external monotone {
        _syncCheckpoint();
        uint256 cash = HYBRID.cash();
        uint256 ceiling = liquid ? cash + RESERVE.convertToAssets(HYBRID.reserveShares()) : cash;
        uint256 maxAssets = bound(assetsSeed, 0, ceiling + ceiling / 2);
        if (!liquid) maxAssets = Math.min(maxAssets, cash);
        _serve(bound(countSeed, 1, BATCH), maxAssets);
        ++calls[this.serveRequests.selector];
    }

    struct Service {
        uint256 maxRequests;
        uint256 maxAssets;
        uint256 cash;
        uint256 supply;
        uint256 assets;
        uint256 reserveShares;
        uint256 reserveCash;
        uint256 served;
        uint256 count;
    }

    function _serve(uint256 maxRequests, uint256 maxAssets) internal {
        Service memory s;
        s.maxRequests = maxRequests;
        s.maxAssets = maxAssets;
        s.cash = HYBRID.cash();
        s.supply = HYBRID.totalSupply();
        s.assets = HYBRID.totalAssets();
        s.reserveShares = RESERVE.balanceOf(address(HYBRID));
        s.reserveCash = CASH.balanceOf(address(RESERVE));
        vm.recordLogs();
        HYBRID.serveRequests(s.maxRequests, s.maxAssets);
        _replayService(s);
        _reconcileService(s);
    }

    function _replayService(Service memory s) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(HYBRID)) continue;
            if (logs[i].topics[0] == REQUEST_CANCELLED) {
                _returnedDust(logs[i]);
            } else if (logs[i].topics[0] == REQUEST_SERVED) {
                s.served += _servedChunk(logs[i], s.supply, s.assets, s.count++);
            }
        }
    }

    function _reconcileService(Service memory s) internal {
        assertLe(s.served, s.maxAssets, "served beyond the caller's budget");
        assertLe(s.count, s.maxRequests, "served beyond the caller's count");
        uint256 need = s.served > s.cash ? s.served - s.cash : 0;
        assertEq(s.reserveCash - CASH.balanceOf(address(RESERVE)), need, "reserve paid an unexpected amount");
        ghostReserveRedemptions += need;
        ghostReserveSharesBurned += s.reserveShares - RESERVE.balanceOf(address(HYBRID));
    }

    /// @dev A request worth less than one USDG unit is handed back by `serveRequests` instead of stalling the queue.
    function _returnedDust(Vm.Log memory entry) internal {
        uint256 id = uint256(entry.topics[1]);
        address who = address(uint160(uint256(entry.topics[2])));
        uint256 shares = abi.decode(entry.data, (uint256));
        while (ghostQueueHead < id && ghostRequestShares[ghostQueueHead] == 0) {
            ++ghostQueueHead;
        }
        assertEq(id, ghostQueueHead, "dust is returned in queue order");
        assertEq(who, ghostRequestOwner[id], "returned dust goes back to its owner");
        assertEq(shares, ghostRequestShares[id], "the whole dust request is returned");
        assertEq(HYBRID.convertToAssets(shares), 0, "only a request worth nothing is returned");
        ghostRequestShares[id] = 0;
        ghostLocked[who] -= shares;
        ghostPending -= shares;
    }

    function _servedChunk(Vm.Log memory entry, uint256 supply, uint256 assetsBefore, uint256 index)
        internal
        returns (uint256 assets)
    {
        uint256 id = uint256(entry.topics[1]);
        address who = address(uint160(uint256(entry.topics[2])));
        uint256 shares;
        uint256 remaining;
        (shares, assets, remaining) = abi.decode(entry.data, (uint256, uint256, uint256));
        while (ghostQueueHead < id && ghostRequestShares[ghostQueueHead] == 0) {
            ++ghostQueueHead;
        }
        assertEq(id, ghostQueueHead, "requests must be served oldest first");
        assertEq(who, ghostRequestOwner[id], "a served request must credit its owner");
        assertGt(shares, 0, "a served chunk burns shares");
        assertLe(shares, ghostRequestShares[id], "a request cannot serve more than it holds");
        uint256 quote = Math.mulDiv(shares, assetsBefore + 1, supply + VIRTUAL_SHARES);
        assertApproxEqAbs(assets, quote, index + 1, "a served chunk is priced at the moment it is served");
        ghostRequestShares[id] -= shares;
        assertEq(remaining, ghostRequestShares[id], "remaining shares differ from the model");
        _balanceChanged(who);
        if (shares == ghostSupply) ghostRewardRemainder = 0;
        ghostShares[who] -= shares;
        ghostLocked[who] -= shares;
        ghostPending -= shares;
        ghostSupply -= shares;
        ghostClaimable[who] += assets;
        ghostClaimableTotal += assets;
    }

    /// @notice Withdraw USDG credited by served requests.
    function claim(uint256 actorSeed) external monotone {
        address who = actors[actorSeed % ACTOR_COUNT];
        uint256 expected = ghostClaimable[who];
        if (expected == 0) return;
        uint256 before_ = CASH.balanceOf(who);
        vm.prank(who);
        uint256 assets = HYBRID.claim();
        assertEq(assets, expected, "claim must pay exactly what was served");
        assertEq(CASH.balanceOf(who) - before_, assets, "claim must deliver its amount");
        ghostClaimable[who] = 0;
        ghostClaimableTotal -= assets;
        ghostClaimed += assets;
        ++calls[this.claim.selector];
    }

    /// @notice Pull one holder's part of one side pocket, sized by the independent balance-of-record model.
    function claimPocket(uint256 actorSeed, uint256 pocketSeed) external monotone {
        if (ghostPocketCount == 0) return;
        _claimPocket(actors[actorSeed % ACTOR_COUNT], 1 + pocketSeed % ghostPocketCount);
        ++calls[this.claimPocket.selector];
    }

    function _claimPocket(address who, uint256 pocketId) internal {
        if (ghostPocketClaimed[pocketId][who]) return;
        uint256 expected =
            Math.mulDiv(ghostPocketAmount[pocketId], ghostBalanceAt[pocketId][who], ghostPocketSupply[pocketId]);
        if (expected == 0) return;
        MockERC20 token = MockERC20(ghostPocketToken[pocketId]);
        uint256 before_ = token.balanceOf(who);
        vm.prank(who);
        uint256 amount = HYBRID.claimPocket(pocketId);
        assertEq(amount, expected, "pocket claim differs from the balance-of-record model");
        assertEq(token.balanceOf(who) - before_, amount, "pocket claim must deliver its amount");
        ghostPocketClaimed[pocketId][who] = true;
        ghostPocketClaimedTotal[pocketId] += amount;
        if (address(token) == address(CASH)) ghostPocketPaidUSDG += amount;
    }

    /// @notice Withdraw one holder's accrued sGAGE.
    function claimRewards(uint256 actorSeed) external monotone {
        _syncCheckpoint();
        _claimRewards(actors[actorSeed % ACTOR_COUNT]);
        ++calls[this.claimRewards.selector];
    }

    function _claimRewards(address who) internal {
        uint256 expected = HYBRID.rewardClaimable(who);
        if (expected == 0) return;
        uint256 before_ = REWARD.balanceOf(who);
        vm.prank(who);
        uint256 amount = HYBRID.claimRewards();
        assertEq(amount, expected, "reward claim must pay its preview");
        assertEq(REWARD.balanceOf(who) - before_, amount, "reward claim must deliver its amount");
        ghostRewardsPaid += amount;
        ghostRewardsPaidTo[who] += amount;
    }

    // ---------------------------------------------------------------- reserve

    /// @notice Anyone moves idle cash into the reserve while not paused.
    function investReserve(uint256 actorSeed, uint256 amountSeed) external monotone {
        if (HYBRID.paused()) return;
        uint256 cash = HYBRID.cash();
        if (cash == 0) return;
        uint256 assets = bound(amountSeed, 1, cash);
        uint256 shares = RESERVE.previewDeposit(assets);
        if (shares == 0) return;
        vm.prank(actors[actorSeed % ACTOR_COUNT]);
        uint256 minted = HYBRID.investReserve(assets, shares);
        assertEq(minted, shares, "reserve investment must mint its preview");
        ghostReserveDeposits += assets;
        ghostReserveSharesMinted += shares;
        ++calls[this.investReserve.selector];
    }

    /// @notice The curator brings reserve shares back to cash.
    function divestReserve(uint256 sharesSeed) external monotone {
        if (!liquid) return;
        uint256 held = HYBRID.reserveShares();
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);
        uint256 assets = RESERVE.previewRedeem(shares);
        vm.prank(_params.curator);
        uint256 received = HYBRID.divestReserve(shares, assets);
        assertEq(received, assets, "reserve divestment must pay its preview");
        ghostReserveRedemptions += assets;
        ghostReserveSharesBurned += shares;
        ++calls[this.divestReserve.selector];
    }

    /// @notice Add reserve assets without minting shares.
    function reserveGain(uint256 amountSeed) external monotone {
        if (RESERVE.totalSupply() == 0) return;
        uint256 amount = bound(amountSeed, 1, 1000e6);
        CASH.mint(address(this), amount);
        RESERVE.donate(amount);
        ghostReserveGains += amount;
        ++calls[this.reserveGain.selector];
    }

    /// @notice Remove reserve assets without burning shares.
    function reserveLoss(uint256 amountSeed) external monotone {
        uint256 assets = RESERVE.totalAssets();
        if (assets < 2) return;
        uint256 amount = bound(amountSeed, 1, assets / 2);
        if (HYBRID.lockedProfitNow() == 0) ghostLossAgainstLock = 0;
        RESERVE.simulateLoss(amount, address(0x3300));
        ghostReserveLosses += amount;
        ghostLossAgainstLock += amount;
        ++calls[this.reserveLoss.selector];
    }

    /// @notice Enable or disable reserve redemption.
    function reserveLiquidity(bool enabled) external monotone {
        liquid = enabled;
        RESERVE.setLimits(type(uint256).max, enabled ? type(uint256).max : 0, enabled ? type(uint256).max : 0);
        ++calls[this.reserveLiquidity.selector];
    }

    // ---------------------------------------------------------------- loans

    /// @notice List and approve a mandate-compliant loan in either admitted token, for one to four units.
    function approveLoan(uint256 borrowerSeed, uint256 tokenSeed, uint256 amountSeed, uint256 unitSeed)
        external
        monotone
    {
        if (HYBRID.paused() || approvedIds.length >= MAX_APPROVALS) return;
        MockERC20 token = tokens[tokenSeed % 2];
        uint256 collateralAmount = tokenSeed % 2 == 0 ? 10e18 : 1000e18;
        uint8 units = uint8(1 + unitSeed % UNITS);
        uint256 maximum = _approvalMaximum(address(token), collateralAmount, units);
        if (maximum < 10e6) return;
        // Our cost for `units` slots is units * ceil(principal / 4): keep the whole listing inside the mandate.
        uint256 share = bound(amountSeed, 10e6, maximum);
        uint128 principal = uint128((share / units) * UNITS);
        uint128 cap = principal + uint128(Math.mulDiv(principal, 500, 10_000, Math.Rounding.Ceil));
        vm.prank(borrowers[borrowerSeed % ACTOR_COUNT]);
        uint256 id = CORE.list(
            Collateral({kind: Kind.ERC20, token: address(token), amountOrTokenId: collateralAmount}),
            principal,
            cap,
            unitSeed % 3 == 0 ? 21 days : 7 days,
            uint40(block.timestamp + 1 days),
            true
        );
        vm.prank(_params.curator);
        HYBRID.approveLoan(id, uint40(block.timestamp + 1 hours), units);
        approvedIds.push(id);
        ++calls[this.approveLoan.selector];
    }

    /// @dev The largest strategy share of a new listing under every cap the vault checks at approval.
    function _approvalMaximum(address token, uint256 collateralAmount, uint8 units)
        internal
        view
        returns (uint256 maximum)
    {
        ICollateralRegistry.ERC20Config memory cfg = HYBRID.REGISTRY().getERC20Config(token);
        uint256 ceiling = HYBRID.tokenCeiling(token);
        bytes32 key = keccak256(abi.encode(Kind.ERC20, token));
        if (!cfg.allowed || ceiling == 0 || CORE.openExposure(key) + collateralAmount > cfg.maxOpenRaw) return 0;
        maximum = Math.mulDiv(collateralAmount, ceiling, 1e18) * units / UNITS;
        uint256 full = HYBRID.fullAssets();
        uint256 laneCap = Math.mulDiv(HYBRID.laneWeightBps(_earnLane(cfg.lane)), full, 10_000);
        uint256 used = HYBRID.lanePrincipal(_earnLane(cfg.lane));
        if (laneCap <= used) return 0;
        maximum = Math.min(maximum, laneCap - used);
        uint256 exposureCap = Math.mulDiv(_params.maxGageExposureBps, full, 10_000);
        uint256 outstanding = HYBRID.performingPrincipal() + HYBRID.overduePrincipal();
        if (exposureCap <= outstanding) return 0;
        maximum = Math.min(maximum, exposureCap - outstanding);
        uint256 committed = HYBRID.approvedPrincipal() + outstanding;
        if (committed >= _params.maxTotalDeposits) return 0;
        maximum = Math.min(maximum, _params.maxTotalDeposits - committed);
    }

    /// @notice Revoke a known approval through the curator path.
    function revokeLoan(uint256 idSeed) external monotone {
        if (approvedIds.length == 0) return;
        vm.prank(_params.curator);
        HYBRID.revokeLoan(approvedIds[idSeed % approvedIds.length]);
        ++calls[this.revokeLoan.selector];
    }

    struct Funding {
        uint8 slots;
        uint256 cost;
        uint256 need;
        uint256 burned;
        EarnLane lane;
        uint16 rate;
        uint256 reserveShares;
        uint256 value;
    }

    /// @notice Execute a still-valid approval from pooled liquidity when the mandate and the queue allow it.
    function fund(uint256 idSeed) external monotone {
        if (HYBRID.paused() || approvedIds.length == 0) return;
        _syncCheckpoint();
        if (_openCount() >= MAX_OPEN_LOANS) return;
        uint256 id = approvedIds[idSeed % approvedIds.length];
        (bool valid, uint8 units) = _validApproval(id);
        if (!valid) return;
        V2Loan memory l = CORE.getLoan(id);
        Funding memory f;
        bool eligible;
        (eligible, f.slots, f.cost) = _eligibleDeal(id, l, units);
        if (!eligible) return;
        f.need = _reserveNeed(f.cost);
        if (f.need != 0 && !liquid) return;
        f.burned = f.need == 0 ? 0 : RESERVE.previewWithdraw(f.need);
        f.lane = _earnLane(HYBRID.REGISTRY().getERC20Config(l.token).lane);
        f.rate = HYBRID.feeBps();
        f.reserveShares = RESERVE.balanceOf(address(HYBRID));
        f.value = HYBRID.totalAssets();
        HYBRID.fund(id, type(uint256).max);
        assertEq(f.reserveShares - RESERVE.balanceOf(address(HYBRID)), f.burned, "funding burned unexpected shares");
        assertApproxEqAbs(HYBRID.totalAssets(), f.value, 2, "funding at principal must not move the price");
        assertEq(HYBRID.loanSlots(id), f.slots, "funded quarters differ from the core's fill order");
        assertEq(HYBRID.positionPrincipal(id), f.cost, "committed principal differs from the quarter prices");
        ghostSlots[id] = f.slots;
        ghostPositionPrincipal[id] = f.cost;
        ghostLoanLane[id] = f.lane;
        ghostLoanFee[id] = f.rate;
        ghostBorrower[id] = l.originator;
        ghostPerforming += f.cost;
        ghostLanePrincipal[f.lane] += f.cost;
        ghostBorrowerPrincipal[l.originator] += f.cost;
        ghostFundedPrincipal += f.cost;
        ghostReserveRedemptions += f.need;
        ghostReserveSharesBurned += f.burned;
        fundedIds.push(id);
        ++calls[this.fund.selector];
    }

    function _validApproval(uint256 id) internal view returns (bool, uint8 units) {
        (uint40 validUntil, uint128 approved, uint64 epoch, uint8 approvedUnits) = HYBRID.approvals(id);
        return (approved != 0 && epoch == HYBRID.approvalEpoch() && block.timestamp <= validUntil, approvedUnits);
    }

    /// @dev The vault's funding-time eligibility, restated from the mandate.
    function _eligibleDeal(uint256 id, V2Loan memory l, uint8 units)
        internal
        view
        returns (bool, uint8 slots, uint256 cost)
    {
        if (HYBRID.funded(id) || l.state != V2State.FUNDING || units > UNITS - l.filled) return (false, 0, 0);
        if (block.timestamp >= l.fundingDeadline) return (false, 0, 0);
        (slots, cost) = _selectSlots(id, l.principal, units);
        (, uint128 approved,,) = HYBRID.approvals(id);
        if (cost == 0 || cost > approved) return (false, 0, 0);
        ICollateralRegistry.ERC20Config memory cfg = HYBRID.REGISTRY().getERC20Config(l.token);
        uint256 ceiling = HYBRID.tokenCeiling(l.token);
        if (!cfg.allowed || ceiling == 0 || l.principal > Math.mulDiv(l.collateral, ceiling, 1e18)) {
            return (false, 0, 0);
        }
        uint256 full = HYBRID.fullAssets();
        if (
            HYBRID.lanePrincipal(_earnLane(cfg.lane)) + cost
                > Math.mulDiv(HYBRID.laneWeightBps(_earnLane(cfg.lane)), full, 10_000)
        ) {
            return (false, 0, 0);
        }
        uint256 outstanding = HYBRID.performingPrincipal() + HYBRID.overduePrincipal();
        if (outstanding + cost > Math.mulDiv(_params.maxGageExposureBps, full, 10_000)) return (false, 0, 0);
        uint256 liquidity = HYBRID.cash() + RESERVE.convertToAssets(HYBRID.reserveShares());
        if (cost > liquidity || liquidity - cost < HYBRID.pendingRequestAssets()) return (false, 0, 0);
        return (true, slots, cost);
    }

    function _earnLane(Lane lane) internal pure returns (EarnLane) {
        return lane == Lane.MEME ? EarnLane.MEME : EarnLane.STOCK;
    }

    function _selectSlots(uint256 id, uint256 principal, uint8 units)
        internal
        view
        returns (uint8 slots, uint256 cost)
    {
        address[4] memory lenders = CORE.lenders(id);
        uint8 remaining = units;
        for (uint8 i; i < UNITS && remaining != 0; ++i) {
            if (lenders[i] == address(0)) {
                slots |= uint8(1 << i);
                cost += _slice(principal, i);
                --remaining;
            }
        }
    }

    function _slice(uint256 total, uint8 i) internal pure returns (uint256) {
        return total / UNITS + (i < total % UNITS ? 1 : 0);
    }

    function _sliceSum(uint256 total, uint8 slots) internal pure returns (uint256 sum) {
        for (uint8 i; i < UNITS; ++i) {
            if (slots & (1 << i) != 0) sum += _slice(total, i);
        }
    }

    /// @notice External lenders buy every remaining unit of a listing the strategy joined, activating it.
    function fillLoan(uint256 idSeed) external monotone {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[idSeed % fundedIds.length];
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.FUNDING || block.timestamp >= l.fundingDeadline || ghostWithdrawn[id]) return;
        if (HYBRID.REGISTRY().newDealsPaused()) return;
        uint256 free = CORE_REWARDS.freeBudget();
        if (free < uint256(l.borrowerReward) + l.lenderReward) return;
        address[4] memory lenders = CORE.lenders(id);
        uint256 filler;
        for (uint8 i; i < UNITS; ++i) {
            if (lenders[i] != address(0)) continue;
            vm.prank(fillers[filler++ % fillers.length]);
            CORE.fund(id, 1);
        }
        ++calls[this.fillLoan.selector];
    }

    /// @notice The borrower cancels a listing the strategy has joined but that has not activated.
    function cancelFunding(uint256 idSeed) external monotone {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[idSeed % fundedIds.length];
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.FUNDING) return;
        vm.prank(l.originator);
        CORE.cancelFunding(id);
        if (!ghostWithdrawn[id]) ghostCoreReturns += ghostPositionPrincipal[id];
        ++calls[this.cancelFunding.selector];
    }

    /// @notice The curator releases the strategy's units from a listing that has not activated.
    function withdrawCommitment(uint256 idSeed) external monotone {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[idSeed % fundedIds.length];
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.FUNDING || ghostWithdrawn[id] || ghostTerminal[id]) return;
        vm.prank(_params.curator);
        HYBRID.withdrawCommitment(id);
        ghostWithdrawn[id] = true;
        ghostCoreReturns += ghostPositionPrincipal[id];
        ++calls[this.withdrawCommitment.selector];
    }

    /// @notice Repay an active loan at any point before its deadline, including inside the core's grace window.
    function borrowerReclaim(uint256 idSeed) external monotone {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[idSeed % fundedIds.length];
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE || block.timestamp >= _deadline(id)) return;
        vm.prank(l.originator);
        CORE.reclaim(id, l.originator);
        if (!ghostWithdrawn[id]) ghostCoreReturns += _sliceSum(l.cap, ghostSlots[id]);
        ++calls[this.borrowerReclaim.selector];
    }

    /// @notice Advance time by up to two days: approvals lapse, terms end, profit unlocks.
    function warp(uint256 secondsSeed) external monotone {
        vm.warp(block.timestamp + bound(secondsSeed, 1 minutes, 2 days));
        ++calls[this.warp.selector];
    }

    /// @notice Advance to an existing loan's collateral-recovery deadline or later.
    function warpPastGrace(uint256 idSeed, uint256 extraSeed) external monotone {
        if (fundedIds.length == 0) return;
        uint256 id = fundedIds[idSeed % fundedIds.length];
        uint256 next = _deadline(id) + bound(extraSeed, 0, 1 days);
        vm.warp(Math.max(block.timestamp, next));
        ++calls[this.warpPastGrace.selector];
    }

    function _deadline(uint256 id) internal view returns (uint256) {
        V2Loan memory l = CORE.getLoan(id);
        if (l.state == V2State.FUNDING) return l.fundingDeadline;
        return uint256(l.fundedAt) + l.term + CORE.GRACE();
    }

    /// @notice Write down a batch of loans past their term; the model decides which ones qualify.
    function markOverdue(uint256 offsetSeed) external monotone {
        uint256[] memory ids = _batch(offsetSeed);
        if (ids.length == 0) return;
        Checkpoint memory c = Checkpoint({
            full: HYBRID.fullAssets(),
            rawLocked: _rawLockedNow(),
            storedLocked: HYBRID.lockedProfit(),
            mark: HYBRID.highWaterPrice(),
            fees: 0,
            netProfit: 0
        });
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (ghostTerminal[id] || ghostOverdueFlag[id]) continue;
            V2Loan memory l = CORE.getLoan(id);
            if (l.state == V2State.REPAID || !_isImpaired(l)) continue;
            _modelWriteDown(id, c);
        }
        HYBRID.markOverdue(ids);
        assertEq(HYBRID.lockedProfit(), c.storedLocked, "an overdue writedown must absorb raw locked profit first");
        ++calls[this.markOverdue.selector];
    }

    function _batch(uint256 offsetSeed) internal view returns (uint256[] memory ids) {
        uint256 count = fundedIds.length;
        if (count == 0) return ids;
        uint256 length = Math.min(BATCH, count);
        uint256 offset = offsetSeed % count;
        ids = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            ids[i] = fundedIds[(offset + i) % count];
        }
    }

    /// @notice Use one known loan as the bounded key for a canonical settlement pass over every live position.
    function settle(uint256 idSeed) external monotone {
        if (fundedIds.length == 0) return;
        // Any funded id is a bounded compatibility key; the vault checkpoints every live loan in funding order.
        assertTrue(HYBRID.funded(fundedIds[idSeed % fundedIds.length]), "the settlement key must be funded");
        _syncCheckpoint();
        ++calls[this.settle.selector];
    }

    /// @dev Model and execute the vault's canonical checkpoint. Any funded id invokes the same bounded live-set pass.
    function _syncCheckpoint() internal {
        if (fundedIds.length == 0) return;
        uint256 credit = CORE.cashCredit(address(HYBRID));
        ghostHarvestedCash += credit;
        uint256 rewardBefore = REWARD.balanceOf(address(HYBRID));
        uint256 expectedRewards;
        if (HYBRID.lockedProfitNow() == 0) ghostLossAgainstLock = 0;
        Checkpoint memory c = Checkpoint({
            full: HYBRID.fullAssets(),
            rawLocked: _rawLockedNow(),
            storedLocked: HYBRID.lockedProfit(),
            mark: HYBRID.highWaterPrice(),
            fees: 0,
            netProfit: 0
        });
        for (uint256 i; i < fundedIds.length; ++i) {
            uint256 id = fundedIds[i];
            if (ghostTerminal[id]) continue;
            V2Loan memory l = CORE.getLoan(id);
            if (!ghostOverdueFlag[id] && _isImpaired(l)) _modelWriteDown(id, c);
            _modelSettlement(id, l, c);
            expectedRewards += _modelReward(id);
        }
        uint256 feeBefore = HYBRID.feeAccrued();
        vm.recordLogs();
        HYBRID.settle(_one(fundedIds[0]));
        uint256 reportedFee = _reportedFees(vm.getRecordedLogs());
        uint256 receivedRewards = REWARD.balanceOf(address(HYBRID)) - rewardBefore;
        ghostRewardsHarvested += receivedRewards;
        ghostFeesReported += reportedFee;
        assertEq(reportedFee, c.fees, "canonical settlement reported an unexpected fee");
        assertEq(HYBRID.feeAccrued() - feeBefore, c.fees, "canonical settlement accrued an unexpected fee");
        assertEq(HYBRID.lockedProfit(), c.storedLocked, "canonical settlement produced an unexpected profit lock");
        assertEq(HYBRID.highWaterPrice(), c.mark, "canonical settlement produced an unexpected high-water mark");
        assertEq(HYBRID.fullAssets(), c.full, "canonical settlement produced an unexpected full-asset value");
        assertEq(CORE.cashCredit(address(HYBRID)), 0, "canonical settlement leaves no transferable core cash");
        assertEq(receivedRewards, expectedRewards, "canonical checkpoint delivered unexpected rewards");
        assertEq(HYBRID.harvestedCash(), ghostHarvestedCash, "canonical checkpoint harvest differs from the model");
        assertEq(HYBRID.assignedCash(), ghostAssignedCash, "canonical checkpoint assignment differs from the model");
        assertEq(HYBRID.rewardRemainder(), ghostRewardRemainder, "canonical reward remainder differs from the model");
    }

    function _modelSettlement(uint256 id, V2Loan memory l, Checkpoint memory c) internal {
        bool refund = ghostWithdrawn[id] || l.state == V2State.CANCELLED;
        bool repaid = !refund && l.state == V2State.REPAID;
        bool defaulting =
            !refund && l.state == V2State.ACTIVE && block.timestamp >= uint256(l.fundedAt) + l.term + CORE.GRACE();
        bool collateral = !refund && (l.state == V2State.DEFAULTED || defaulting);
        if (!(refund || repaid || collateral)) return;
        uint256 principal = ghostPositionPrincipal[id];
        uint256 payout = refund ? principal : repaid ? _sliceSum(l.cap, ghostSlots[id]) : 0;
        if (payout != 0 && ghostAssignedCash + payout > ghostHarvestedCash) return;
        ghostTerminal[id] = true;
        ghostAssignedCash += payout;
        ghostBorrowerPrincipal[ghostBorrower[id]] -= principal;
        ghostLanePrincipal[ghostLoanLane[id]] -= principal;
        bool writtenDown = ghostOverdueFlag[id];
        if (writtenDown) ghostOverdue -= principal;
        else ghostPerforming -= principal;
        if (writtenDown) {
            if (payout != 0) _openPocket(id, address(CASH), payout);
            else if (collateral) _openPocket(id, l.token, _sliceSum(l.collateral, ghostSlots[id]));
            return;
        }
        if (payout > principal) {
            _modelProfit(id, payout - principal, c);
        } else if (payout < principal) {
            uint256 loss = principal - payout;
            c.full -= loss;
            _modelLoss(loss, c);
        }
        if (collateral) _openPocket(id, l.token, _sliceSum(l.collateral, ghostSlots[id]));
    }

    /// @dev A write-down removes principal from price before any later balance movement and fixes recovery owners.
    function _modelWriteDown(uint256 id, Checkpoint memory c) internal {
        uint256 principal = ghostPositionPrincipal[id];
        ghostOverdueFlag[id] = true;
        ghostPerforming -= principal;
        ghostOverdue += principal;
        ghostLoanSnapshotSupply[id] = ghostSupply;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            ghostLoanBalanceAt[id][actors[i]] = ghostShares[actors[i]];
        }
        _modelLoss(principal, c);
    }

    function _modelProfit(uint256 id, uint256 profit, Checkpoint memory c) internal {
        c.full += profit;
        uint256 fee;
        if (ghostSupply != 0) {
            uint256 price = Math.mulDiv(c.full, PRICE_PRECISION, ghostSupply);
            if (price > c.mark) {
                uint16 rate = ghostLoanFee[id];
                if (rate != 0) {
                    uint256 excess = Math.min(profit, Math.mulDiv(price - c.mark, ghostSupply, PRICE_PRECISION));
                    fee = Math.mulDiv(excess, rate, 10_000);
                    c.full -= fee;
                }
                c.mark = Math.mulDiv(c.full, PRICE_PRECISION, ghostSupply);
            }
        }
        c.rawLocked += profit - fee;
        c.storedLocked = c.rawLocked;
        c.fees += fee;
        c.netProfit += profit - fee;
        ghostFeesModeled += fee;
        ghostNetProfitReported += profit - fee;
    }

    function _modelLoss(uint256 loss, Checkpoint memory c) internal pure {
        c.rawLocked -= Math.min(c.rawLocked, loss);
        c.storedLocked = c.rawLocked;
    }

    function _isImpaired(V2Loan memory l) internal view returns (bool) {
        if (l.state == V2State.DEFAULTED) return true;
        uint256 maturity = uint256(l.fundedAt) + l.term;
        if (l.state == V2State.REPAID) return l.fundedAt != 0 && l.closedAt >= maturity;
        return l.state == V2State.ACTIVE && block.timestamp >= maturity;
    }

    function _rawLockedNow() internal view returns (uint256) {
        uint256 end = HYBRID.unlockEnd();
        if (block.timestamp >= end) return 0;
        uint256 start = HYBRID.unlockStart();
        return Math.mulDiv(HYBRID.lockedProfit(), end - block.timestamp, end - start);
    }

    function _reportedFees(Vm.Log[] memory logs) internal view returns (uint256 total) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(HYBRID) || logs[i].topics[0] != PROFIT_REPORTED) continue;
            (, uint256 fee,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint64));
            total += fee;
        }
    }

    /// @dev Record the holders of record from the ghost balances, then check the vault's snapshot agrees.
    function _openPocket(uint256 id, address token, uint256 recovered) internal {
        uint256 pocketId = ++ghostPocketCount;
        ghostPocketToken[pocketId] = token;
        ghostPocketAmount[pocketId] = recovered;
        ghostPocketSupply[pocketId] = ghostLoanSnapshotSupply[id];
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            ghostBalanceAt[pocketId][actors[i]] = ghostLoanBalanceAt[id][actors[i]];
        }
    }

    /// @notice Collect all available core credits without assigning any loan.
    function harvestCash() external monotone {
        ghostHarvestedCash += CORE.cashCredit(address(HYBRID));
        HYBRID.harvestCash();
        ++calls[this.harvestCash.selector];
    }

    /// @notice Pull released lender rewards of a batch of funded loans and spread them over every share.
    function harvestRewards(uint256 offsetSeed) external monotone {
        uint256[] memory ids = _batch(offsetSeed);
        if (ids.length == 0) return;
        _harvestRewards(ids);
        ++calls[this.harvestRewards.selector];
    }

    function _harvestRewards(uint256[] memory ids) internal {
        uint256 before_ = REWARD.balanceOf(address(HYBRID));
        uint256 expected;
        for (uint256 i; i < ids.length; ++i) {
            expected += _modelReward(ids[i]);
        }
        HYBRID.harvestRewards(ids);
        uint256 amount = REWARD.balanceOf(address(HYBRID)) - before_;
        ghostRewardsHarvested += amount;
        assertEq(amount, expected, "explicit harvest delivered unexpected rewards");
        assertEq(HYBRID.rewardRemainder(), ghostRewardRemainder, "the reward remainder differs from the model");
    }

    /// @dev Rewards are assigned when they become claimable, before the core token transfer is attempted.
    function _modelReward(uint256 id) internal returns (uint256 amount) {
        amount = CORE_REWARDS.claimable(id, address(HYBRID));
        if (amount == 0) return 0;
        ghostRewardsAccrued += amount;
        if (ghostSupply == 0) {
            ghostRewardOrphan += amount;
            return amount;
        }
        ghostRewardDust += ghostSupply / REWARD_PRECISION + 1;
    }

    /// @notice Pull only independently modeled performance fees through the companion to both recipients.
    function claimFees() public monotone {
        uint256 accrued = ghostFeesModeled - ghostFeesPaid;
        if (accrued == 0) return;
        HybridFees fees = HybridFees(HYBRID.fees());
        address recipient = fees.curatorRecipient();
        address floor = fees.PROTOCOL_RECIPIENT();
        uint256 curatorBefore = CASH.balanceOf(recipient);
        uint256 floorBefore = CASH.balanceOf(floor);
        HYBRID.claimFees();
        fees.claimCurator();
        uint256 protocolShare = Math.mulDiv(accrued, fees.PROTOCOL_SHARE_BPS(), 10_000);
        if (protocolShare != 0) fees.claimProtocol();
        assertEq(CASH.balanceOf(recipient) - curatorBefore, accrued - protocolShare, "curator share of the fee");
        assertEq(CASH.balanceOf(floor) - floorBefore, protocolShare, "protocol share of the fee");
        assertEq(CASH.balanceOf(address(fees)), 0, "the companion holds nothing after both claims");
        ghostFeesPaid += accrued;
        ++calls[this.claimFees.selector];
    }

    // ---------------------------------------------------------------- curator settings

    /// @notice Change one lane cap within the aggregate compile-time bound.
    function setLaneWeight(uint256 laneSeed, uint256 weightSeed) external monotone {
        EarnLane lane = EarnLane(laneSeed % 3);
        uint256 otherWeights;
        for (uint256 i; i < 3; ++i) {
            if (EarnLane(i) != lane) otherWeights += HYBRID.laneWeightBps(EarnLane(i));
        }
        uint16 bps = uint16(bound(weightSeed, 0, 10_000 - otherWeights));
        vm.prank(_params.curator);
        HYBRID.setLaneWeight(lane, bps);
        assertEq(HYBRID.laneWeightBps(lane), bps);
        ++calls[this.setLaneWeight.selector];
    }

    /// @notice Admit, tighten or remove one collateral token's price ceiling.
    function setTokenCeiling(uint256 tokenSeed, uint256 ceilingSeed) external monotone {
        address token = address(tokens[tokenSeed % 2]);
        uint256 ceiling = bound(ceilingSeed, 0, 10_000e6);
        vm.prank(_params.curator);
        HYBRID.setTokenCeiling(token, ceiling);
        assertEq(HYBRID.tokenCeiling(token), ceiling);
        ++calls[this.setTokenCeiling.selector];
    }

    /// @notice Change the fee for future loans, optionally choosing a new nonzero recipient.
    function setFee(uint256 bpsSeed, bool changeRecipient) external monotone {
        uint16 bps = uint16(bound(bpsSeed, 0, HYBRID_MAX_FEE_BPS));
        vm.startPrank(_params.curator);
        if (changeRecipient) HybridFees(HYBRID.fees()).setCuratorRecipient(address(uint160(0x4400 + bps)));
        HYBRID.setFee(bps);
        vm.stopPrank();
        assertEq(HYBRID.feeBps(), bps);
        ++calls[this.setFee.selector];
    }

    /// @notice Pause or resume new strategy activity and invalidate outstanding approvals.
    function setPaused(bool enabled) external monotone {
        vm.prank(_params.curator);
        HYBRID.setPaused(enabled);
        assertEq(HYBRID.approvedPrincipal(), 0, "pausing or resuming clears every approval");
        ++calls[this.setPaused.selector];
    }

    // ---------------------------------------------------------------- unwinding

    /// @dev Every random prefix unwinds without curator help beyond the pause: loans finish at their deadlines,
    /// profit unlocks, the queue is served, every holder leaves and every pocket, reward and fee is collected.
    function finish() external {
        vm.prank(_params.curator);
        HYBRID.setPaused(true);
        liquid = true;
        RESERVE.setLimits(type(uint256).max, type(uint256).max, type(uint256).max);
        uint256 lastDeadline = block.timestamp;
        for (uint256 i; i < fundedIds.length; ++i) {
            lastDeadline = Math.max(lastDeadline, _deadline(fundedIds[i]));
        }
        vm.warp(lastDeadline + HYBRID.PROFIT_UNLOCK());
        for (uint256 i; i < fundedIds.length; ++i) {
            uint256 id = fundedIds[i];
            if (CORE.getLoan(id).state == V2State.FUNDING) {
                // Expired listings are released permissionlessly; the strategy's units come back as cash.
                CORE.cancelFunding(id);
                if (!ghostWithdrawn[id]) ghostCoreReturns += ghostPositionPrincipal[id];
            }
        }
        _syncCheckpoint();
        for (uint256 i; i < fundedIds.length; ++i) {
            uint256 id = fundedIds[i];
            assertTrue(ghostTerminal[id], "every loan resolves after its deadline");
        }
        vm.warp(block.timestamp + HYBRID.PROFIT_UNLOCK());
        assertEq(HYBRID.lockedProfitNow(), 0, "profit is fully unlocked after the window");
        for (uint256 start; start < fundedIds.length; start += 32) {
            uint256 length = Math.min(32, fundedIds.length - start);
            uint256[] memory ids = new uint256[](length);
            for (uint256 i; i < length; ++i) {
                ids[i] = fundedIds[start + i];
            }
            _harvestRewards(ids);
        }
        _serveAll();
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address who = actors[i];
            _leave(who);
            for (uint256 pocketId = 1; pocketId <= ghostPocketCount; ++pocketId) {
                _claimPocket(who, pocketId);
            }
            _claimRewards(who);
            assertEq(ghostShares[who], 0, "every holder can leave after any valid prefix");
            assertEq(HYBRID.rewardClaimable(who), 0, "every reward is collectible");
        }
        claimFees();
    }

    /// @dev Every request of value is served once everything is liquid; dust requests are handed back by the vault.
    function _serveAll() internal {
        _serve(type(uint256).max, type(uint256).max);
        assertEq(ghostPending, 0, "every request of value is served once everything is liquid again");
    }

    function _leave(address who) internal {
        uint256 shares = ghostShares[who];
        if (shares != 0) {
            uint256 assets = HYBRID.convertToAssets(shares);
            uint256 need = _reserveNeed(assets);
            uint256 burned = need == 0 ? 0 : RESERVE.previewWithdraw(need);
            uint256 before_ = CASH.balanceOf(who);
            vm.prank(who);
            uint256 paid = HYBRID.redeem(shares, assets);
            assertEq(paid, assets, "leaving pays the quoted value");
            assertEq(CASH.balanceOf(who) - before_, assets, "leaving delivers its amount");
            _paidOut(who, shares, assets, need, burned);
        }
        uint256 claimable = ghostClaimable[who];
        if (claimable != 0) {
            vm.prank(who);
            assertEq(HYBRID.claim(), claimable, "claiming pays the served amount");
            ghostClaimable[who] = 0;
            ghostClaimableTotal -= claimable;
            ghostClaimed += claimable;
        }
    }

    // ---------------------------------------------------------------- helpers

    function pendingLoss() external view returns (uint256 loss) {
        for (uint256 i; i < fundedIds.length; ++i) {
            uint256 id = fundedIds[i];
            if (!ghostTerminal[id] && !ghostOverdueFlag[id] && _isImpaired(CORE.getLoan(id))) {
                loss += ghostPositionPrincipal[id];
            }
        }
    }

    function ghostUSDGPocketLiability() external view returns (uint256 liability) {
        for (uint256 id = 1; id <= ghostPocketCount; ++id) {
            if (ghostPocketToken[id] == address(CASH)) {
                liability += ghostPocketAmount[id] - ghostPocketClaimedTotal[id];
            }
        }
    }

    function _openCount() internal view returns (uint256 count) {
        for (uint256 i; i < fundedIds.length; ++i) {
            if (!ghostTerminal[fundedIds[i]]) ++count;
        }
    }

    function _freeLiquidity() internal view returns (uint256) {
        uint256 cash = HYBRID.cash();
        return liquid ? cash + RESERVE.convertToAssets(HYBRID.reserveShares()) : cash;
    }

    function _reserveNeed(uint256 assets) internal view returns (uint256) {
        uint256 cash = HYBRID.cash();
        return assets > cash ? assets - cash : 0;
    }

    /// @dev Every balance change rounds one reward unit against the holder.
    function _balanceChanged(address) internal {
        ++ghostRewardDust;
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}
