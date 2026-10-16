// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLimit} from "../../src/intent/IntentVaultState.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan, V2State, V2LenderAsk, V2LenderSplit} from "../../src/v2/V2Types.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";

/// @dev Test-only stand-in for the S3/S4 router: it authenticates the filler and forwards. No quote, no atomicity.
contract IntentInvariantRouter {
    IntentFactory internal immutable FACTORY;

    constructor(IntentFactory factory) {
        FACTORY = factory;
    }

    function fund(IntentVault vault, uint256 id, uint8 units, uint256 executionFee) external {
        require(FACTORY.isFiller(msg.sender), "filler denied");
        vault.purchase(id, units, 0, type(uint256).max, executionFee);
    }

    function investReserve(IntentVault vault, uint256 assets) external {
        require(FACTORY.isFiller(msg.sender), "filler denied");
        vault.investReserve(assets, 0);
    }

    /// @dev S9: the vault buys a wallet's whole lender ask. The price goes through this router to the core in the same
    /// call; the vault's own checks decide. No quote and no split among vaults here: those are the unit suites'.
    function acquire(
        IntentVault vault,
        GageV2Vault core,
        uint256 id,
        address seller,
        uint8 slots,
        uint128 price,
        uint16 feeBps,
        uint256 nonce,
        uint256 executionFee
    ) external {
        require(FACTORY.isFiller(msg.sender), "filler denied");
        MockERC20 usdg = MockERC20(address(vault.USDG()));
        uint256 held = usdg.balanceOf(address(this));
        vault.purchase(id, slots, price, type(uint256).max, executionFee);
        require(usdg.balanceOf(address(this)) - held == price, "the vault paid the price");
        usdg.approve(address(core), price);
        address v = address(vault);
        uint128[4] memory none;
        core.buyLenderSplit(id, V2LenderSplit(seller, slots, price, feeBps, nonce, [v, v, v, v], none));
        require(usdg.balanceOf(address(this)) == held, "the price was spent exactly");
        for (uint8 i; i < 4; ++i) {
            if (slots & (1 << i) != 0) require(core.lenders(id)[i] == v, "quarter arrived");
        }
    }

    /// @dev S4: the router takes the earned execution fees; here it simply keeps them.
    function collect(IntentVault vault) external returns (uint256) {
        require(FACTORY.isFiller(msg.sender), "filler denied");
        return vault.collectExecutionFees();
    }
}

/// @notice Random but valid call sequences against a partner vault, with the D51 transitions: a repayment booked
/// before the end of its term and its earnings claim, top-ups, sales and the exit of the last holder. Every action
/// checks the vault's own preconditions first, so with `fail_on_revert = true` a revert is a real finding, and the
/// properties that concern one step (no same-block profit, a price-neutral settlement) are asserted in that step.
contract IntentHandler is Test {
    uint8 internal constant UNITS = 4;
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;
    uint256 internal constant MIN_DEPOSIT = 1e6;
    /// @dev The vault's share ceiling, which keeps its exposure clock's rounding under a millionth (D51).
    uint256 internal constant MAX_SUPPLY = 1e27;
    uint256 internal constant MAX_OPEN_LOANS = 64;
    uint256 internal constant BPS = 10_000;

    IntentVault public immutable VAULT;
    IntentInvariantRouter public immutable ROUTER;
    GageV2Vault public immutable CORE;
    MockERC20 public immutable USDG;
    HybridReserveMock public immutable RESERVE;
    MockERC20[2] internal _tokens;
    address public immutable CURATOR;
    address public immutable BORROWER;
    address public immutable FILLER;
    address[3] public actors;
    address[3] internal _fillers;

    uint256[] public loanIds;
    // Ghosts.
    uint256 public ghostPushedUnharvested;
    uint256 public ghostReserveGains;
    uint256 public ghostReserveLosses;
    uint256 public ghostRecapitalized;
    uint256 public ghostRewardsPaid;
    uint256 public ghostDeposited;
    uint256 public ghostRedeemed;
    uint256 public ghostEarnedLost;
    uint256 public ghostFeesPaid;
    uint256 public ghostProfit;
    uint256 public ghostFees;
    uint256 public ghostLosses;
    // Coverage of the S2 transitions, so a green run is known to have walked them.
    uint256 public ghostEarlySettlements;
    uint256 public ghostLastHolderExits;
    // D51: earnings claims opened (their USDG leaves `cash` for the pocket) and paid out.
    uint256 public ghostEarningsPockets;
    uint256 public ghostEarningsOpened;
    uint256 public ghostEarningsClaimed;
    uint256 public ghostRoundTrips;
    uint256 public ghostTopUps;
    // Execution fees: booked at a purchase, then either earned when the loan is seen active or reversed at a refund.
    uint256 public ghostExecutionBooked;
    uint256 public ghostExecutionEarned;
    uint256 public ghostExecutionReversed;
    uint256 public ghostExecutionCollected;
    // S9: bought positions and vault sales, so a green run is known to have walked them.
    uint256 public ghostAcquisitions;
    uint256 public ghostSales;
    /// @dev Sales refused because their price was below the position's book value (D48).
    uint256 public ghostRefusedSales;
    /// @dev A new position freezes share changes for the rest of its purchase second.
    uint256 public ghostNewPurchaseAt = type(uint256).max;

    constructor(
        IntentVault vault,
        IntentInvariantRouter router,
        GageV2Vault core,
        MockERC20 usdg,
        HybridReserveMock reserve,
        MockERC20[2] memory tokens,
        address borrower,
        address filler
    ) {
        VAULT = vault;
        ROUTER = router;
        CORE = core;
        USDG = usdg;
        RESERVE = reserve;
        _tokens = tokens;
        CURATOR = vault.CURATOR();
        BORROWER = borrower;
        FILLER = filler;
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("intent-actor", i)));
            usdg.mint(actors[i], 100_000_000e6);
            vm.prank(actors[i]);
            usdg.approve(address(vault), type(uint256).max);
            _fillers[i] = makeAddr(string(abi.encodePacked("intent-lender", i)));
            usdg.mint(_fillers[i], 100_000_000e6);
            vm.prank(_fillers[i]);
            usdg.approve(address(core), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers

    struct LoanView {
        IntentCategory lane;
        uint40 maturity;
        bool withdrawn;
        bool settled;
        bool recovered;
        bool repaid;
        uint64 snapshotId;
        uint128 principal;
        uint128 interest;
        uint128 rate;
    }

    /// @dev Read in two passes: the loan record is wider than one stack frame can unpack under the IR pipeline.
    function loanView(uint256 id) public view returns (LoanView memory v) {
        (v.lane, v.maturity, v.withdrawn, v.settled, v.recovered, v.repaid) = _flags(id);
        (v.snapshotId, v.principal, v.interest, v.rate) = _amounts(id);
    }

    function _flags(uint256 id)
        internal
        view
        returns (IntentCategory lane, uint40 maturity, bool withdrawn, bool settled, bool recovered, bool repaid)
    {
        (, lane,, maturity, withdrawn, settled, recovered, repaid,,,,,,,,) = VAULT.loans(id);
    }

    function _amounts(uint256 id)
        internal
        view
        returns (uint64 snapshotId, uint128 principal, uint128 interest, uint128 rate)
    {
        (,,,,,,,, snapshotId, principal,, interest, rate,,,) = VAULT.loans(id);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _due() internal view returns (bool) {
        return block.timestamp >= VAULT.earliestMaturity();
    }

    /// @dev The vault's `Impaired` guard: shares outstanding and priced equity at zero.
    function _impaired() internal view returns (bool) {
        return VAULT.totalSupply() != 0 && VAULT.totalAssets() == 0;
    }

    function _shareChangeBlocked() internal view returns (bool) {
        return block.timestamp == ghostNewPurchaseAt;
    }

    function _openCount() internal view returns (uint256 open) {
        for (uint256 i; i < loanIds.length; ++i) {
            if (!loanView(loanIds[i]).settled) ++open;
        }
    }

    function _pick(uint256 seed) internal view returns (uint256 id, bool ok) {
        if (loanIds.length == 0) return (0, false);
        return (loanIds[seed % loanIds.length], true);
    }

    /// @dev The mandate's checks on one more purchase, exactly as the vault applies them.
    function _fits(IntentCategory lane, address token, uint256 held, uint256 cost, uint256 executionFee)
        internal
        view
        returns (bool)
    {
        // Nothing is lent while nobody holds a share, whatever is still priced.
        if (VAULT.totalSupply() == 0 || _impaired()) return false;
        uint256 assets = VAULT.totalAssets();
        // The caps are measured on the assets left after the purchase's own execution fee (Pashov M-24).
        if (executionFee > assets) return false;
        uint256 left = assets - executionFee;
        if (VAULT.categoryPrincipal(lane) + cost > Math.mulDiv(VAULT.categoryWeightBps(lane), left, BPS)) return false;
        if (held + cost > VAULT.maxLoanPrincipal()) return false;
        if (VAULT.assetPrincipal(token) + cost > Math.mulDiv(VAULT.maxAssetBps(), left, BPS)) return false;
        return cost + executionFee + Math.mulDiv(VAULT.bufferBps(), assets, BPS) <= VAULT.freeLiquidity();
    }

    function _slice(uint256 total, uint8 i) internal pure returns (uint256) {
        return total / UNITS + (i < total % UNITS ? 1 : 0);
    }

    /// @dev Any execution fee the vault accepts: nothing, its whole ceiling, or anything under it.
    function _executionFee(uint256 seed, uint256 gross) internal view returns (uint256) {
        uint256 ceiling = gross * VAULT.executionCapBps() / BPS;
        if (seed % 5 == 0) return 0;
        if (seed % 17 == 0) return ceiling;
        return seed % (ceiling + 1);
    }

    // ---------------------------------------------------------------- depositors

    function deposit(uint256 seed, uint256 amount) external {
        if (VAULT.paused() || _due() || _impaired() || _shareChangeBlocked()) return;
        amount = bound(amount, MIN_DEPOSIT, 50_000e6);
        uint256 shares = VAULT.convertToShares(amount);
        if (shares == 0 || VAULT.totalSupply() + shares > MAX_SUPPLY) return;
        vm.prank(_actor(seed));
        VAULT.deposit(amount, 0);
        ghostDeposited += amount;
    }

    function redeem(uint256 seed, uint256 shareSeed) external {
        if (_due() || _impaired() || _shareChangeBlocked()) return;
        address who = _actor(seed);
        uint256 held = VAULT.balanceOf(who);
        if (held == 0) return;
        uint256 shares = bound(shareSeed, 1, held);
        if (shares == VAULT.totalSupply() && VAULT.performingPrincipal() != 0) return;
        if (VAULT.convertToAssets(shares) > VAULT.freeLiquidity()) return;
        _redeem(who, shares);
    }

    /// @dev Weighted toward the exit of the last holder; its earnings claims stay open to it afterwards.
    function redeemAll(uint256 seed) external {
        if (_due() || _impaired() || _shareChangeBlocked()) return;
        address who = _actor(seed);
        uint256 shares = VAULT.balanceOf(who);
        if (shares == 0) return;
        if (shares == VAULT.totalSupply()) {
            if (VAULT.performingPrincipal() != 0) return;
        } else if (VAULT.convertToAssets(shares) > VAULT.freeLiquidity()) {
            return;
        }
        _redeem(who, shares);
    }

    function _redeem(address who, uint256 shares) internal {
        bool last = shares == VAULT.totalSupply();
        vm.prank(who);
        ghostRedeemed += VAULT.redeem(shares, 0);
        if (last && VAULT.pocketLiability(address(USDG)) != 0) ++ghostLastHolderExits;
    }

    /// @dev S2-A1 as a step: entering and leaving in one block never returns more than went in, whatever is unbooked.
    function roundTrip(uint256 seed, uint256 amount) external {
        if (VAULT.paused() || _due() || _impaired() || _shareChangeBlocked()) return;
        amount = bound(amount, MIN_DEPOSIT, 5_000_000e6);
        uint256 assets = VAULT.totalAssets();
        uint256 shares = VAULT.convertToShares(amount);
        if (shares == 0 || VAULT.totalSupply() + shares > MAX_SUPPLY) return;
        {
            // A reserve loss can leave liquid cash below priced assets while loans keep priced equity positive.
            // Project the exit after this deposit: its cash first covers that existing liquidity gap.
            uint256 value = RESERVE.convertToAssets(VAULT.reserveShares());
            uint256 limit = address(VAULT.RESERVE_LENS()) == address(0)
                ? RESERVE.maxWithdraw(address(VAULT))
                : VAULT.RESERVE_LENS().withdrawable(address(RESERVE), address(VAULT));
            uint256 available = VAULT.cash() + Math.min(value, limit) + amount;
            // Match the vault's fixed virtual shares and rounding so even a rounding-covered gap is exercised.
            uint256 projectedOut = Math.mulDiv(shares, assets + amount + 1, VAULT.totalSupply() + shares + 1e12);
            if (projectedOut > available) return;
        }
        address who = _actor(seed);
        vm.startPrank(who);
        VAULT.deposit(amount, 0);
        uint256 out = VAULT.redeem(shares, 0);
        vm.stopPrank();
        assertLe(out, amount, "a same-block round trip returned more than it put in");
        ghostDeposited += amount;
        ghostRedeemed += out;
        ++ghostRoundTrips;
    }

    /// @dev A claim pays exactly what the vault's view showed: the view and the claim agree (D51).
    function claimPocket(uint256 seed, uint256 pocketSeed) external {
        uint256 count = VAULT.pocketCount();
        if (count == 0) return;
        uint256 pocketId = pocketSeed % count + 1;
        address who = _actor(seed);
        uint256 shown = VAULT.pocketClaimable(pocketId, who);
        if (shown == 0) return;
        vm.prank(who);
        uint256 paid = VAULT.claimPocket(pocketId);
        assertEq(paid, shown, "a claim paid other than what its view showed");
        _countClaim(pocketId, paid);
    }

    /// @dev One holder collects every earnings claim it has, in one call.
    function claimPockets(uint256 seed) external {
        address who = _actor(seed);
        uint256 count = VAULT.pocketCount();
        uint256[] memory ids = new uint256[](count > 32 ? 32 : count);
        uint256[] memory shown = new uint256[](ids.length);
        uint256 n;
        for (uint256 pocketId = count; pocketId != 0 && n < ids.length; --pocketId) {
            uint256 amount = VAULT.pocketClaimable(pocketId, who);
            if (amount == 0) continue;
            ids[n] = pocketId;
            shown[n++] = amount;
        }
        if (n == 0) return;
        assembly {
            mstore(ids, n)
        }
        vm.prank(who);
        VAULT.claimPockets(ids);
        for (uint256 i; i < n; ++i) {
            assertEq(VAULT.pocketClaimable(ids[i], who), 0, "a batch claim left a part unpaid");
            _countClaim(ids[i], shown[i]);
        }
    }

    function _countClaim(uint256 pocketId, uint256 paid) internal {
        (, address token,,,, uint64 snapshotId) = VAULT.pockets(pocketId);
        if (token == address(USDG) && snapshotId == 0) ghostEarningsClaimed += paid;
    }

    // ---------------------------------------------------------------- reserve

    function investReserve(uint256 amount) external {
        // D51: an earnings claim is never in `cash`, so all of `cash` may move into the reserve.
        uint256 cash = VAULT.cash();
        if (VAULT.paused() || cash == 0 || _impaired()) return;
        amount = bound(amount, 1, cash);
        vm.prank(FILLER);
        ROUTER.investReserve(VAULT, amount);
    }

    function divestReserve(uint256 shares) external {
        uint256 held = VAULT.reserveShares();
        if (held == 0) return;
        shares = bound(shares, 1, held);
        vm.prank(CURATOR);
        VAULT.divestReserve(shares, 0);
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
        if (held == 0) return;
        amount = bound(amount, 1, held);
        RESERVE.simulateLoss(amount, address(0xDEAD));
        ghostReserveLosses += amount;
    }

    /// @dev Backing lands only while the curator has paused the vault (Pashov I-01): the curator pauses if it has not,
    /// and opens the vault again afterwards, all in one step.
    function recapitalize(uint256 amount) external {
        if (VAULT.totalSupply() == 0) return;
        amount = bound(amount, 1, 1000e6);
        USDG.mint(address(this), amount);
        USDG.approve(address(VAULT), amount);
        bool open = !VAULT.paused();
        if (open) {
            vm.prank(CURATOR);
            VAULT.setPaused(true);
        }
        VAULT.recapitalize(amount);
        if (open) {
            vm.prank(CURATOR);
            VAULT.setPaused(false);
        }
        ghostRecapitalized += amount;
    }

    function harvestRewards(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        VAULT.harvestRewards(ids);
    }

    function deliverRewards(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        GageV2Rewards rewards = CORE.REWARDS();
        if (!ok || rewards.claimable(id, address(VAULT)) == 0) return;
        vm.prank(address(VAULT));
        rewards.claim(id, address(VAULT));
    }

    function claimRewards(uint256 seed) external {
        address who = _actor(seed);
        if (VAULT.rewardClaimable(who) == 0) return;
        vm.prank(who);
        ghostRewardsPaid += VAULT.claimRewards();
    }

    // ---------------------------------------------------------------- loans

    function fillerFunds(uint256 tokenSeed, uint256 principalSeed, uint256 premiumSeed, uint8 units) external {
        if (VAULT.paused() || !VAULT.fillersOpen() || _due()) return;
        if (_openCount() >= MAX_OPEN_LOANS) return;
        MockERC20 token = _tokens[tokenSeed % 2];
        IntentCategory lane = tokenSeed % 2 == 0 ? IntentCategory.STOCK : IntentCategory.COMMODITY;
        uint128 principal = uint128(bound(principalSeed, 100e6, 5000e6));
        uint128 cap = principal + uint128(Math.mulDiv(principal, bound(premiumSeed, 100, 1000), BPS));
        units = uint8(bound(units, 1, UNITS));
        uint256 cost;
        uint256 repaid;
        for (uint8 i; i < units; ++i) {
            cost += _slice(principal, i);
            repaid += _slice(cap, i);
        }
        uint256 executionFee = _executionFee(premiumSeed, repaid - cost);
        if (!_fits(lane, address(token), 0, cost, executionFee)) return;
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
        vm.recordLogs();
        vm.prank(FILLER);
        ROUTER.fund(VAULT, id, units, executionFee);
        ghostNewPurchaseAt = block.timestamp;
        ghostExecutionBooked += executionFee;
        _readExecutionLogs(vm.getRecordedLogs());
        loanIds.push(id);
    }

    /// @dev Buy one more quarter of a listing the vault already holds while it is still funding.
    function topUp(uint256 seed) external {
        if (VAULT.paused() || !VAULT.fillersOpen() || _due()) return;
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        LoanView memory v = loanView(id);
        if (v.settled || v.withdrawn) return;
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.FUNDING || block.timestamp >= l.fundingDeadline || l.filled >= UNITS) return;
        address[4] memory lenders = CORE.lenders(id);
        uint256 cost;
        uint256 gross;
        for (uint8 i; i < UNITS; ++i) {
            if (lenders[i] == address(0)) {
                cost = _slice(l.principal, i);
                gross = _slice(l.cap, i) - cost;
                break;
            }
        }
        uint256 executionFee = _executionFee(seed, gross);
        if (!_fits(v.lane, l.token, v.principal, cost, executionFee)) return;
        vm.recordLogs();
        vm.prank(FILLER);
        ROUTER.fund(VAULT, id, 1, executionFee);
        ghostExecutionBooked += executionFee;
        _readExecutionLogs(vm.getRecordedLogs());
        ++ghostTopUps;
    }

    /// @dev S9: a wallet lends a whole new loan, then offers some of its quarters; the vault buys the offer.
    function vaultBuysAsk(uint256 tokenSeed, uint256 principalSeed, uint256 priceSeed, uint8 maskSeed) external {
        if (VAULT.paused() || !VAULT.fillersOpen() || _due()) return;
        if (_openCount() >= MAX_OPEN_LOANS || !VAULT.ASSET_POLICY().secondaryEnabled()) return;
        MockERC20 token = _tokens[tokenSeed % 2];
        IntentCategory lane = tokenSeed % 2 == 0 ? IntentCategory.STOCK : IntentCategory.COMMODITY;
        uint128 principal = uint128(bound(principalSeed, 100e6, 5000e6));
        uint128 cap = principal + uint128(Math.mulDiv(principal, bound(priceSeed, 100, 1000), BPS));
        uint8 mask = uint8(bound(maskSeed, 1, 15));
        uint256 owed;
        uint256 represented;
        for (uint8 i; i < UNITS; ++i) {
            if (mask & (1 << i) == 0) continue;
            owed += _slice(cap, i);
            represented += _slice(principal, i);
        }
        uint128 price = uint128(bound(priceSeed, represented * 9 / 10, owed - 1));
        uint256 executionFee = _executionFee(priceSeed, owed - price);
        // The vault measures its caps on the larger of price and represented principal (proposed D38).
        if (!_fits(lane, address(token), 0, Math.max(price, represented), executionFee)) return;
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
        address wallet = _fillers[tokenSeed % 3];
        vm.prank(wallet);
        CORE.fund(id, UNITS);
        V2Loan memory l = CORE.getLoan(id);
        uint40 deadline = uint40(uint256(l.fundedAt) + l.term);
        vm.prank(wallet);
        CORE.setLenderAsk(id, mask, price, deadline, 100);
        V2LenderAsk memory ask = CORE.getLenderAsk(id, wallet);
        vm.recordLogs();
        vm.prank(FILLER);
        ROUTER.acquire(VAULT, CORE, id, wallet, mask, price, ask.feeBps, ask.nonce, executionFee);
        ghostNewPurchaseAt = block.timestamp;
        ghostExecutionBooked += executionFee;
        _readExecutionLogs(vm.getRecordedLogs());
        loanIds.push(id);
        ++ghostAcquisitions;
    }

    /// @dev S9 seller: the curator lists the vault's whole holding of an active loan and a wallet buys it.
    function vaultSells(uint256 seed, uint256 priceSeed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok || VAULT.paused() || _due()) return;
        uint8 slots = VAULT.lenderSaleSlots(id);
        if (slots == 0) return;
        V2Loan memory l = CORE.getLoan(id);
        uint256 maturity = uint256(l.fundedAt) + l.term;
        if (l.state != V2State.ACTIVE || block.timestamp >= maturity) return;
        LoanView memory v = loanView(id);
        uint128 price = uint128(bound(priceSeed, v.principal / 2 + 1, uint256(v.principal) * 2));
        IntentLenderMarket market = VAULT.LENDER_MARKET();
        vm.prank(CURATOR);
        market.list(id, price, uint40(maturity), 100);
        uint64 nonce = market.nonces(id);
        address buyer = _fillers[seed % 3];
        vm.prank(buyer);
        USDG.approve(address(market), type(uint256).max);
        vm.recordLogs();
        vm.prank(buyer);
        try market.buySplit(id, nonce, price, [buyer, buyer, buyer, buyer], _none()) {}
        catch (bytes memory reason) {
            // D48: a sale below the position's book value is refused whole, and D51 refuses a gain in the second of
            // the purchase; anything else is a finding.
            if (
                bytes4(reason) != IntentVault.SaleBelowBook.selector
                    && bytes4(reason) != IntentVault.SaleTooSoon.selector
            ) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
            vm.getRecordedLogs();
            ++ghostRefusedSales;
            return;
        }
        // The sale harvests like a settlement: every pushed credit is now booked as unassigned cash.
        ghostPushedUnharvested = 0;
        _readBookLogs(vm.getRecordedLogs());
        ++ghostSales;
    }

    /// @dev No per-quarter reward bound: a buyer of the whole listing through `buySplit`.
    function _none() internal pure returns (uint128[4] memory none) {}

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

    /// @dev S4: the router collects whatever execution fees are earned, at any moment of the vault's life.
    function routerCollects() external {
        uint256 earned = VAULT.executionFees();
        uint256 held = USDG.balanceOf(address(ROUTER));
        vm.prank(FILLER);
        uint256 amount = ROUTER.collect(VAULT);
        require(amount == earned && USDG.balanceOf(address(ROUTER)) - held == amount, "collected what was earned");
        ghostExecutionCollected += amount;
    }

    function borrowerRepays(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE) return;
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

    function thirdPartyFinalizesDefault(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE || block.timestamp < uint256(l.fundedAt) + l.term) return;
        vm.prank(_fillers[0]);
        CORE.finalizeDefault(id);
    }

    function withdrawCommitment(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        LoanView memory v = loanView(id);
        if (v.withdrawn || v.settled || CORE.getLoan(id).state != V2State.FUNDING) return;
        vm.prank(CURATOR);
        VAULT.withdrawCommitment(id);
    }

    function pushCoreCredit() external {
        uint256 credit = CORE.cashCredit(address(VAULT));
        if (credit == 0) return;
        CORE.withdrawUSDGFor(address(VAULT));
        ghostPushedUnharvested += credit;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 3 days));
    }

    function warpPastMaturity() external {
        uint40 end = VAULT.earliestMaturity();
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
        _settle(ids);
    }

    /// @dev S2-A2 as a step: booking one repayment the core recorded before the end of its term leaves priced assets
    /// where they were, but for the unit of fee rounding each earlier purchase of that loan can carry, and opens its
    /// earnings claim. However late the booking, it is price-neutral: live pricing already stopped counting the loan
    /// at the core's `closedAt` (M-01), so the booking has nothing counted after the repayment to take back.
    function settleOneRepaidEarly(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        LoanView memory v = loanView(id);
        V2Loan memory l = CORE.getLoan(id);
        if (v.settled || v.repaid || v.withdrawn || l.state != V2State.REPAID) return;
        if (l.closedAt >= uint256(l.fundedAt) + l.term) return;
        uint256 before_ = VAULT.totalAssets();
        uint256 supply = VAULT.totalSupply();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        _settle(ids);
        v = loanView(id);
        if (!v.repaid) return;
        uint256 after_ = VAULT.totalAssets();
        assertLe(after_, before_, "an early repayment lifted priced assets at settlement");
        assertLe(before_ - after_, 3, "an early repayment moved priced assets beyond purchase rounding");
        assertEq(VAULT.totalSupply(), supply);
        ++ghostEarlySettlements;
    }

    function _settle(uint256[] memory ids) internal {
        vm.recordLogs();
        VAULT.settle(ids);
        ghostPushedUnharvested = 0;
        _readBookLogs(vm.getRecordedLogs());
    }

    /// @dev What a settlement or a sale booked: profit and its fee, loss, earnings claims and execution fees.
    function _readBookLogs(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(VAULT)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("ProfitReported(uint256,uint256,uint256)")) {
                (uint256 profit, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
                ghostProfit += profit;
                ghostFees += fee;
            } else if (topic == keccak256("LossReported(uint256,uint256,uint256)")) {
                (uint256 principalLost, uint256 earned) = abi.decode(logs[i].data, (uint256, uint256));
                ghostLosses += principalLost + earned;
                ghostEarnedLost += earned;
            } else if (topic == keccak256("PocketCreated(uint256,uint256,address,uint256,uint256)")) {
                // Only a booking or a sale opens a pocket here; `recover` opens recovery pockets outside these logs.
                if (address(uint160(uint256(logs[i].topics[3]))) == address(USDG)) {
                    (uint256 amount,) = abi.decode(logs[i].data, (uint256, uint256));
                    ghostEarningsOpened += amount;
                    ++ghostEarningsPockets;
                }
            }
        }
        _readExecutionLogs(logs);
    }

    function _readExecutionLogs(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(VAULT)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == keccak256("ExecutionFeeEarned(uint256,uint256)")) {
                ghostExecutionEarned += abi.decode(logs[i].data, (uint256));
            } else if (topic == keccak256("ExecutionFeeReversed(uint256,uint256)")) {
                ghostExecutionReversed += abi.decode(logs[i].data, (uint256));
            }
        }
    }

    function recover(uint256 seed) external {
        (uint256 id, bool ok) = _pick(seed);
        if (!ok) return;
        LoanView memory v = loanView(id);
        if (v.snapshotId == 0 || v.recovered) return;
        if (CORE.getLoan(id).state != V2State.DEFAULTED) return;
        VAULT.recover(id);
    }

    function claimFees() external {
        ghostFeesPaid += VAULT.curatorFees() + VAULT.protocolFees();
        VAULT.claimFees();
    }

    // ---------------------------------------------------------------- curator

    /// @dev D53: the manager moves one risk limit; a tightening applies at once, a loosening queues for three hours.
    /// The Loan grade floor is left out: a floor needs a modeled cost the fixture's fills do not publish.
    function setLimit(uint8 limitSeed, uint128 value) external {
        IntentLimit limit = _limit(limitSeed);
        // Read first: a prank binds to the very next external call, a view read included.
        IntentAssetPolicy policy = VAULT.ASSET_POLICY();
        uint8 mask = VAULT.CATEGORY_MASK();
        if (limit == IntentLimit.MAX_LOAN_PRINCIPAL) {
            value = uint128(bound(value, 0, 1_000_000e6));
        } else if (limit == IntentLimit.BUFFER_BPS) {
            value = uint128(bound(value, 0, 2000));
        } else if (
            limit >= IntentLimit.CATEGORY_STOCK
                && mask & uint8(1 << (uint8(limit) - uint8(IntentLimit.CATEGORY_STOCK))) == 0
        ) {
            value = 0;
        } else {
            value = uint128(bound(value, 0, 10_000));
        }
        vm.prank(CURATOR);
        policy.setLimit(limit, value);
    }

    /// @dev Anyone applies a queued loosening once its three hours have passed.
    function activateLimit(uint8 limitSeed) external {
        IntentLimit limit = _limit(limitSeed);
        IntentAssetPolicy policy = VAULT.ASSET_POLICY();
        (, uint64 readyAt) = policy.pendingLimit(limit);
        if (readyAt == 0 || block.timestamp < readyAt) return;
        policy.activateLimit(limit);
    }

    /// @dev The manager drops a queued loosening.
    function cancelLimit(uint8 limitSeed) external {
        IntentLimit limit = _limit(limitSeed);
        IntentAssetPolicy policy = VAULT.ASSET_POLICY();
        (, uint64 readyAt) = policy.pendingLimit(limit);
        if (readyAt == 0) return;
        vm.prank(CURATOR);
        policy.cancelLimit(limit);
    }

    /// @dev Every limit but the Loan grade floor.
    function _limit(uint8 seed) internal pure returns (IntentLimit limit) {
        limit = IntentLimit(seed % 7);
        if (limit >= IntentLimit.MIN_RATE_GRADE) limit = IntentLimit(uint8(limit) + 1);
    }

    /// @dev The manager moves the execution-fee ceiling either way; the fees the handler asks for follow it.
    function setExecutionCap(uint16 bps) external {
        bps = uint16(bound(bps, 0, IntentFeeMath.MAX_EXECUTION_CAP_BPS));
        vm.prank(CURATOR);
        VAULT.setExecutionCap(bps);
    }

    function setPaused(bool enabled) external {
        vm.prank(CURATOR);
        VAULT.setPaused(enabled);
    }

    // ---------------------------------------------------------------- views for the invariants

    function loanCount() external view returns (uint256) {
        return loanIds.length;
    }

    function executionOf(uint256 id) external view returns (uint128 fee, bool earned) {
        (,,,,,,,,,,,,,, fee, earned) = VAULT.loans(id);
    }
}
