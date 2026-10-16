// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DealVault} from "../../src/DealVault.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {Kind, Collateral} from "../../src/types/Types.sol";
import {DealState, Deal, BidState, Bid} from "../../src/interfaces/IDealVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Stateful handler for the DealVault invariant suite. Every action checks its own preconditions so that
///         a revert inside the vault is a real finding (`fail_on_revert = true`), and keeps ghost totals that the
///         invariants compare against on-chain state.
contract Handler is Test {
    DealVault public immutable VAULT;
    CollateralRegistry public immutable REGISTRY;
    FeeSink public immutable FEE_SINK;
    MockERC20 public immutable USDG;

    MockERC20[] internal _tokens;
    address[] internal _actors;

    uint256[] public dealIds;
    uint256[] public bidIds;

    // ---- ghosts
    uint256 public ghost_openBidEscrow;
    /// @dev Sum of every internal USDG balance, the FeeSink's included.
    uint256 public ghost_sumBalanceUSDG;
    uint256 public ghost_feesCredited;
    uint256 public ghost_feesCollected;
    mapping(address => uint256) public ghost_escrowed;
    mapping(address => uint256) public ghost_sumBalanceERC20;
    mapping(uint256 dealId => uint256) public ghost_claimedAt;
    mapping(uint256 dealId => uint256) public ghost_acceptedBidOf;
    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    constructor(
        DealVault vault,
        CollateralRegistry registry,
        FeeSink feeSink,
        MockERC20 usdg,
        MockERC20[] memory tokens_,
        address[] memory actors_
    ) {
        VAULT = vault;
        REGISTRY = registry;
        FEE_SINK = feeSink;
        USDG = usdg;
        _tokens = tokens_;
        _actors = actors_;
    }

    // ---------------------------------------------------------------- views for the invariants

    function dealIdsLength() external view returns (uint256) {
        return dealIds.length;
    }

    function bidIdsLength() external view returns (uint256) {
        return bidIds.length;
    }

    function tokens() external view returns (MockERC20[] memory) {
        return _tokens;
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    // ---------------------------------------------------------------- actions

    function list(uint256 actorSeed, uint256 tokenSeed, uint256 amount, uint256 cap, bool term21, uint256 expiryOffset)
        external
        countCall("list")
    {
        address actor = _actor(actorSeed);
        MockERC20 token = _token(tokenSeed);
        amount = bound(amount, 1e18, 1000e18);
        uint128 cap128 = uint128(bound(cap, 1e6, 1_000_000e6));
        // 0..7 days; zero is an open-ended listing (D43). Every other listing carries an asking price below the cap.
        expiryOffset = bound(expiryOffset, 0, 7 days);
        uint128 ask = expiryOffset % 2 == 0 ? cap128 - cap128 / 100 : 0;
        if (VAULT.openRaw(address(token)) + amount > REGISTRY.getERC20Config(address(token)).maxOpenRaw) return;

        token.mint(actor, amount);
        vm.startPrank(actor);
        token.approve(address(VAULT), amount);
        uint256 id = VAULT.list(
            Collateral({kind: Kind.ERC20, token: address(token), amountOrTokenId: amount}),
            cap128,
            term21 ? 21 days : 7 days,
            expiryOffset == 0 ? 0 : uint40(block.timestamp + expiryOffset),
            ask
        );
        vm.stopPrank();

        dealIds.push(id);
        ghost_escrowed[address(token)] += amount;
    }

    function bid(uint256 actorSeed, uint256 dealSeed, uint256 price, uint256 expiryOffset) external countCall("bid") {
        if (dealIds.length == 0) return;
        uint256 dealId = dealIds[dealSeed % dealIds.length];
        Deal memory d = VAULT.getDeal(dealId);
        if (d.state != DealState.LISTED || (d.listingExpiry != 0 && block.timestamp + 1 > d.listingExpiry)) return;

        uint128 p = uint128(bound(price, d.minPrice == 0 ? 1 : d.minPrice, d.cap));
        uint40 latest = d.listingExpiry != 0 ? d.listingExpiry : uint40(block.timestamp + 7 days);
        uint40 exp = uint40(bound(expiryOffset, block.timestamp + 1, latest));
        address actor = _actor(actorSeed);

        USDG.mint(actor, p);
        vm.startPrank(actor);
        USDG.approve(address(VAULT), p);
        uint256 id = VAULT.bid(dealId, p, exp, actor);
        vm.stopPrank();

        bidIds.push(id);
        ghost_openBidEscrow += p;
    }

    /// @dev D43: one-step funding at the asking price; the synthetic bid is recorded as the deal's accepted bid.
    function fund(uint256 actorSeed, uint256 dealSeed) external countCall("fund") {
        if (dealIds.length == 0) return;
        uint256 dealId = dealIds[dealSeed % dealIds.length];
        Deal memory d = VAULT.getDeal(dealId);
        if (d.state != DealState.LISTED || d.minPrice == 0) return;
        if (d.listingExpiry != 0 && block.timestamp >= d.listingExpiry) return;
        address actor = _actor(actorSeed);
        uint128 p = d.minPrice;

        USDG.mint(actor, p);
        vm.startPrank(actor);
        USDG.approve(address(VAULT), p);
        uint256 bidId = VAULT.fund(dealId, actor);
        vm.stopPrank();

        bidIds.push(bidId);
        uint256 fee = (uint256(p) * REGISTRY.feeBps()) / 10_000;
        ghost_sumBalanceUSDG += p;
        ghost_feesCredited += fee;
        ghost_acceptedBidOf[dealId] = bidId;
    }

    function withdrawBid(uint256 bidSeed) external countCall("withdrawBid") {
        if (bidIds.length == 0) return;
        uint256 bidId = bidIds[bidSeed % bidIds.length];
        Bid memory b = VAULT.getBid(bidId);
        if (b.state != BidState.OPEN) return;

        vm.prank(b.lender);
        VAULT.withdrawBid(bidId);

        ghost_openBidEscrow -= b.price;
        ghost_sumBalanceUSDG += b.price;
    }

    function accept(uint256 bidSeed) external countCall("accept") {
        if (bidIds.length == 0) return;
        uint256 bidId = bidIds[bidSeed % bidIds.length];
        Bid memory b = VAULT.getBid(bidId);
        if (b.state != BidState.OPEN || block.timestamp >= b.expiry) return;
        Deal memory d = VAULT.getDeal(b.dealId);
        if (d.state != DealState.LISTED) return;

        uint256 fee = (uint256(b.price) * REGISTRY.feeBps()) / 10_000;
        vm.prank(d.borrower);
        VAULT.accept(b.dealId, bidId);

        ghost_openBidEscrow -= b.price;
        ghost_sumBalanceUSDG += b.price;
        ghost_feesCredited += fee;
        ghost_acceptedBidOf[b.dealId] = bidId;
    }

    function reclaim(uint256 dealSeed) external countCall("reclaim") {
        if (dealIds.length == 0) return;
        uint256 dealId = dealIds[dealSeed % dealIds.length];
        Deal memory d = VAULT.getDeal(dealId);
        if (d.state != DealState.FUNDED) return;

        USDG.mint(d.borrower, d.cap);
        vm.startPrank(d.borrower);
        USDG.approve(address(VAULT), d.cap);
        VAULT.reclaim(dealId);
        vm.stopPrank();

        ghost_sumBalanceUSDG += d.cap;
        ghost_escrowed[d.token] -= d.amountOrTokenId;
        ghost_sumBalanceERC20[d.token] += d.amountOrTokenId;
    }

    function claim(uint256 dealSeed) external countCall("claim") {
        if (dealIds.length == 0) return;
        uint256 dealId = dealIds[dealSeed % dealIds.length];
        Deal memory d = VAULT.getDeal(dealId);
        if (d.state != DealState.FUNDED || block.timestamp < VAULT.claimableAt(dealId)) return;

        vm.prank(d.lender);
        VAULT.claim(dealId);

        ghost_claimedAt[dealId] = block.timestamp;
        ghost_escrowed[d.token] -= d.amountOrTokenId;
        ghost_sumBalanceERC20[d.token] += d.amountOrTokenId;
    }

    function cancel(uint256 dealSeed) external countCall("cancel") {
        if (dealIds.length == 0) return;
        uint256 dealId = dealIds[dealSeed % dealIds.length];
        Deal memory d = VAULT.getDeal(dealId);
        if (d.state != DealState.LISTED) return;

        vm.prank(d.borrower);
        VAULT.cancel(dealId);

        ghost_escrowed[d.token] -= d.amountOrTokenId;
        ghost_sumBalanceERC20[d.token] += d.amountOrTokenId;
    }

    function withdrawUSDG(uint256 actorSeed) external countCall("withdrawUSDG") {
        address actor = _actor(actorSeed);
        uint256 amount = VAULT.balanceUSDG(actor);
        if (amount == 0) return;

        vm.prank(actor);
        VAULT.withdrawUSDG();

        ghost_sumBalanceUSDG -= amount;
    }

    function withdrawERC20(uint256 actorSeed, uint256 tokenSeed) external countCall("withdrawERC20") {
        address actor = _actor(actorSeed);
        MockERC20 token = _token(tokenSeed);
        uint256 amount = VAULT.balanceERC20(actor, address(token));
        if (amount == 0) return;

        vm.prank(actor);
        VAULT.withdrawERC20(address(token));

        ghost_sumBalanceERC20[address(token)] -= amount;
    }

    function collectFees() external countCall("collectFees") {
        uint256 amount = FEE_SINK.collect();
        ghost_sumBalanceUSDG -= amount;
        ghost_feesCollected += amount;
    }

    function warp(uint256 secs) external countCall("warp") {
        secs = bound(secs, 1 hours, 3 days);
        vm.warp(block.timestamp + secs);
    }

    // ---------------------------------------------------------------- helpers

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _token(uint256 seed) internal view returns (MockERC20) {
        return _tokens[seed % _tokens.length];
    }
}
