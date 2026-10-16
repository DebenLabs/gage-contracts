// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IV3PositionManager} from "./interfaces/IV3PositionManager.sol";

import {IDealVault, DealState, Deal, BidState, Bid} from "./interfaces/IDealVault.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {UniV3PositionAdapter} from "./libraries/UniV3PositionAdapter.sol";
import {Kind, Collateral} from "./types/Types.sol";

/// @title DealVaultV3
/// @notice gage's immutable core: deals, bids, escrow, the state machine, internal balances and fee accounting.
///         LP-only extension; ERC20 collateral remains in V1. Holds all collateral and all USDG. No owner, no admin path to user funds, no oracle, no upgrade.
/// @dev Rules that bind this contract (engineering brief 0):
///        - The registry can stop new deals. Nothing can move collateral or USDG that belongs to a user,
///          delay a reclaim, or accelerate a claim.
///        - Pull, never push. Every asset owed to a user is credited to an internal balance and withdrawn
///          by that user. Fees are credited to FeeSink's balance the same way and pulled by FeeSink.
///        - Admission may check the pool tick; repayment and default depend only on the agreed terms.
///      Timestamps only: `block.number` on this stack is an L1 estimate.
///      A deadline `t` is exclusive: a listing or bid is expired once `block.timestamp >= t`, and a deal is
///      claimable once `block.timestamp >= expiry + GRACE`.
contract DealVaultV3 is IDealVault, IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ----------------------------------------------------------------- compile-time bounds (spec 13)

    /// @notice Lower bound on the grace window, sized so a sequencer outage cannot cost a borrower their collateral.
    uint48 public constant MIN_GRACE = 24 hours;
    /// @notice A listing with an expiry may stay open at most this long; a zero expiry never expires (D43).
    uint48 public constant MAX_LISTING_EXPIRY = 7 days;
    /// @notice The vault never charges more than this even if the registry says otherwise.
    uint16 public constant MAX_FEE_BPS = 200;
    uint16 internal constant BPS = 10_000;

    // ----------------------------------------------------------------- immutables

    IERC20 public immutable USDG;
    ICollateralRegistry public immutable REGISTRY;
    address public immutable FEE_SINK;
    /// @notice Canonical Uniswap v3 NonfungiblePositionManager. Required for this LP-only deployment.
    address public immutable POSITION_MANAGER;
    /// @notice Time after expiry during which only the borrower can act. Immutable per deployment.
    uint48 public immutable GRACE;

    // ----------------------------------------------------------------- storage

    uint256 public dealCount;
    uint256 public bidCount;
    mapping(uint256 dealId => Deal) internal _deals;
    mapping(uint256 bidId => Bid) internal _bids;

    mapping(address account => uint256) public balanceUSDG;
    mapping(address account => mapping(address token => uint256)) public balanceERC20;
    mapping(address account => mapping(uint256 tokenId => bool)) public owedNFT;
    /// @notice Raw units of each ERC-20 held in LISTED and FUNDED deals. Enforces the per-asset open cap.
    mapping(address token => uint256) public openRaw;

    /// @dev Set only for the duration of a `list` that pulls a position NFT (spec I10).
    bool private transient _expectingNFT;
    uint256 private transient _expectedTokenId;

    constructor(IERC20 usdg, ICollateralRegistry registry, address feeSink, address positionManager, uint48 grace) {
        if (address(usdg) == address(0) || address(registry) == address(0) || feeSink == address(0)) {
            revert ZeroAddress();
        }
        if (grace < MIN_GRACE) revert GraceBelowMinimum(grace, MIN_GRACE);
        USDG = usdg;
        REGISTRY = registry;
        FEE_SINK = feeSink;
        POSITION_MANAGER = positionManager;
        GRACE = grace;
    }

    // ----------------------------------------------------------------- borrower: list, cancel, accept, reclaim (and fund, the lender's one-step path)

    /// @inheritdoc IDealVault
    function list(Collateral calldata c, uint128 cap, uint32 term, uint40 listingExpiry, uint128 minPrice)
        external
        nonReentrant
        returns (uint256 dealId)
    {
        if (REGISTRY.newDealsPaused()) revert NewDealsPaused();
        if (cap == 0) revert InvalidCap();
        if (minPrice > cap) revert InvalidMinPrice();
        if (!REGISTRY.isTermAllowed(term)) revert TermNotAllowed(term);
        if (
            listingExpiry != 0
                && (listingExpiry <= block.timestamp || listingExpiry > block.timestamp + MAX_LISTING_EXPIRY)
        ) {
            revert InvalidListingExpiry();
        }

        dealId = ++dealCount;
        Deal storage d = _deals[dealId];
        d.borrower = msg.sender;
        d.kind = c.kind;
        d.state = DealState.LISTED;
        d.term = term;
        d.listingExpiry = listingExpiry;
        d.token = c.token;
        d.amountOrTokenId = c.amountOrTokenId;
        d.cap = cap;
        d.minPrice = minPrice;

        _pullCollateral(c);

        emit Listed(dealId, msg.sender, c.kind, c.token, c.amountOrTokenId, cap, term, listingExpiry, minPrice);
    }

    /// @inheritdoc IDealVault
    function cancel(uint256 dealId) external {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.LISTED) revert DealNotListed(dealId);
        if (msg.sender != d.borrower) revert NotBorrower();

        d.state = DealState.CANCELLED;
        _creditCollateral(d, d.borrower);
        emit Cancelled(dealId);
    }

    /// @inheritdoc IDealVault
    /// @dev The offer path, kept for a later version: the app does not surface it in v1 (D43).
    function accept(uint256 dealId, uint256 bidId) external {
        if (REGISTRY.newDealsPaused()) revert NewDealsPaused();
        Deal storage d = _deals[dealId];
        if (d.state != DealState.LISTED) revert DealNotListed(dealId);
        if (msg.sender != d.borrower) revert NotBorrower();
        Bid storage b = _bids[bidId];
        if (b.dealId != dealId) revert BidDealMismatch(bidId, dealId);
        if (b.state != BidState.OPEN) revert BidNotOpen(bidId);
        if (block.timestamp >= b.expiry) revert BidExpired(bidId);

        b.state = BidState.ACCEPTED;
        _settle(d, dealId, bidId, b.lender, b.price);
    }

    /// @inheritdoc IDealVault
    /// @dev The v1 path (D43): no offer, no acceptance, no waiting. Pulls exactly the asking price from the caller and
    ///      settles like `accept`. Pausable like `bid` and `accept`.
    function fund(uint256 dealId, address lender) external nonReentrant returns (uint256 bidId) {
        if (lender != msg.sender && !REGISTRY.isRouter(msg.sender)) revert UnauthorizedLender(msg.sender, lender);
        if (lender == address(0)) revert ZeroAddress();
        if (REGISTRY.newDealsPaused()) revert NewDealsPaused();
        Deal storage d = _deals[dealId];
        if (d.state != DealState.LISTED) revert DealNotListed(dealId);
        if (d.listingExpiry != 0 && block.timestamp >= d.listingExpiry) revert ListingExpired(dealId);
        uint128 price = d.minPrice;
        if (price == 0) revert NoAskingPrice(dealId);

        bidId = ++bidCount;
        uint40 now_ = uint40(block.timestamp);
        _bids[bidId] = Bid({dealId: dealId, lender: lender, price: price, expiry: now_, state: BidState.ACCEPTED});
        _pullUSDGExact(msg.sender, price);
        emit BidPlaced(bidId, dealId, lender, price, now_);

        _settle(d, dealId, bidId, lender, price);
    }

    /// @dev Atomic (spec I4): escrowed USDG becomes borrower balance plus fee, state becomes FUNDED, expiry is set.
    function _settle(Deal storage d, uint256 dealId, uint256 bidId, address lender, uint128 price) internal {
        uint128 fee = _fee(price);
        uint40 fundedAt = uint40(block.timestamp);
        uint40 expiry = fundedAt + d.term;

        d.state = DealState.FUNDED;
        d.lender = lender;
        d.price = price;
        d.fee = fee;
        d.fundedAt = fundedAt;
        d.expiry = expiry;

        balanceUSDG[FEE_SINK] += fee;
        balanceUSDG[d.borrower] += price - fee;

        emit Funded(dealId, bidId, lender, price, fee, fundedAt, expiry);
    }

    /// @inheritdoc IDealVault
    /// @dev Allowed at the full cap from the moment of funding until a claim executes (spec 5, open decision 3).
    ///      Requires exactly `cap` and credits exactly `cap` to the lender (spec I6).
    function reclaim(uint256 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.FUNDED) revert DealNotFunded(dealId);
        if (msg.sender != d.borrower) revert NotBorrower();

        d.state = DealState.RECLAIMED;
        balanceUSDG[d.lender] += d.cap;
        _creditCollateral(d, d.borrower);
        _pullUSDGExact(msg.sender, d.cap);

        emit Reclaimed(dealId);
    }

    // ----------------------------------------------------------------- lender: bid, withdrawBid, claim

    /// @inheritdoc IDealVault
    function bid(uint256 dealId, uint128 price, uint40 bidExpiry, address lender)
        external
        nonReentrant
        returns (uint256 bidId)
    {
        if (lender != msg.sender && !REGISTRY.isRouter(msg.sender)) {
            revert UnauthorizedLender(msg.sender, lender);
        }
        if (lender == address(0)) revert ZeroAddress();
        if (REGISTRY.newDealsPaused()) revert NewDealsPaused();
        Deal storage d = _deals[dealId];
        if (d.state != DealState.LISTED) revert DealNotListed(dealId);
        if (d.listingExpiry != 0 && block.timestamp >= d.listingExpiry) revert ListingExpired(dealId);
        if (price == 0) revert ZeroPrice();
        if (price > d.cap) revert PriceAboveCap(price, d.cap);
        if (price < d.minPrice) revert PriceBelowMin(price, d.minPrice);
        // an offer on an open-ended listing may stand at most MAX_LISTING_EXPIRY; it stays withdrawable regardless
        uint40 latest = d.listingExpiry != 0 ? d.listingExpiry : uint40(block.timestamp + MAX_LISTING_EXPIRY);
        if (bidExpiry <= block.timestamp || bidExpiry > latest) revert InvalidBidExpiry();

        bidId = ++bidCount;
        _bids[bidId] = Bid({dealId: dealId, lender: lender, price: price, expiry: bidExpiry, state: BidState.OPEN});
        _pullUSDGExact(msg.sender, price);

        emit BidPlaced(bidId, dealId, lender, price, bidExpiry);
    }

    /// @inheritdoc IDealVault
    /// @dev Every non-accepted bid stays withdrawable forever, whatever the deal's state. Never pausable (spec I3).
    function withdrawBid(uint256 bidId) external {
        Bid storage b = _bids[bidId];
        if (b.state != BidState.OPEN) revert BidNotOpen(bidId);
        if (msg.sender != b.lender) revert NotLender();

        b.state = BidState.WITHDRAWN;
        balanceUSDG[b.lender] += b.price;
        emit BidWithdrawn(bidId);
    }

    /// @inheritdoc IDealVault
    /// @dev Reverts before `expiry + GRACE`. A reclaim that lands first wins (spec I7).
    function claim(uint256 dealId) external {
        Deal storage d = _deals[dealId];
        if (d.state != DealState.FUNDED) revert DealNotFunded(dealId);
        if (msg.sender != d.lender) revert NotLender();
        uint40 at = _claimableAt(d);
        if (block.timestamp < at) revert GraceNotOver(at);

        d.state = DealState.CLAIMED;
        _creditCollateral(d, d.lender);
        emit Claimed(dealId);
    }

    // ----------------------------------------------------------------- withdrawals

    /// @inheritdoc IDealVault
    function withdrawUSDG() external nonReentrant {
        uint256 amount = balanceUSDG[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        balanceUSDG[msg.sender] = 0;
        USDG.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, address(USDG), amount);
    }

    /// @inheritdoc IDealVault
    function withdrawERC20(address token) external nonReentrant {
        _withdrawERC20(token);
    }

    /// @inheritdoc IDealVault
    function withdrawPosition(uint256 tokenId) external nonReentrant {
        _withdrawPosition(tokenId);
    }

    /// @inheritdoc IDealVault
    function withdrawCollateral(uint256 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.kind == Kind.ERC20) _withdrawERC20(d.token);
        else _withdrawPosition(d.amountOrTokenId);
    }

    // ----------------------------------------------------------------- ERC-721 receiver (spec I10)

    /// @notice Accepts a position NFT only from the PositionManager, only when this contract is the operator,
    ///         and only for the tokenId an in-flight `list` is expecting. The expectation is consumed on receipt.
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (
            msg.sender != POSITION_MANAGER || operator != address(this) || !_expectingNFT || tokenId != _expectedTokenId
        ) {
            revert UnexpectedERC721(operator, from, tokenId);
        }
        _expectingNFT = false;
        _expectedTokenId = 0;
        return IERC721Receiver.onERC721Received.selector;
    }

    // ----------------------------------------------------------------- views

    function getDeal(uint256 dealId) external view returns (Deal memory) {
        return _deals[dealId];
    }

    function getBid(uint256 bidId) external view returns (Bid memory) {
        return _bids[bidId];
    }

    /// @notice First timestamp at which the lender may claim. Zero for a deal that was never funded.
    function claimableAt(uint256 dealId) external view returns (uint40) {
        Deal storage d = _deals[dealId];
        if (d.fundedAt == 0) return 0;
        return _claimableAt(d);
    }

    // ----------------------------------------------------------------- internal

    function _pullCollateral(Collateral calldata c) internal {
        if (c.kind != Kind.UNIV3_POSITION) {
            revert UnsupportedKind();
        } else {
            if (POSITION_MANAGER == address(0) || c.token != POSITION_MANAGER) revert UnsupportedKind();
            // The adapter validates the position and pulls it with safeTransferFrom. onERC721Received consumes
            // the expectation, so exactly one NFT, the expected one, can arrive during this call.
            _expectingNFT = true;
            _expectedTokenId = c.amountOrTokenId;
            UniV3PositionAdapter.pull(IV3PositionManager(POSITION_MANAGER), REGISTRY, msg.sender, c.amountOrTokenId);
            // safeTransferFrom must have hit onERC721Received, which consumes the expectation.
            if (_expectingNFT) revert UnexpectedERC721(address(this), msg.sender, c.amountOrTokenId);
        }
    }

    /// @dev The only three callers are cancel, reclaim and claim (spec I1).
    function _creditCollateral(Deal storage d, address to) internal {
        if (d.kind == Kind.ERC20) {
            openRaw[d.token] -= d.amountOrTokenId;
            balanceERC20[to][d.token] += d.amountOrTokenId;
        } else {
            owedNFT[to][d.amountOrTokenId] = true;
        }
    }

    function _withdrawERC20(address token) internal {
        uint256 amount = balanceERC20[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        balanceERC20[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    function _withdrawPosition(uint256 tokenId) internal {
        if (!owedNFT[msg.sender][tokenId]) revert NothingToWithdraw();
        owedNFT[msg.sender][tokenId] = false;
        IERC721(POSITION_MANAGER).safeTransferFrom(address(this), msg.sender, tokenId);
        emit Withdrawn(msg.sender, POSITION_MANAGER, tokenId);
    }

    function _pullUSDGExact(address from, uint256 amount) internal {
        uint256 before = USDG.balanceOf(address(this));
        USDG.safeTransferFrom(from, address(this), amount);
        uint256 received = USDG.balanceOf(address(this)) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
    }

    /// @dev One place for the fee computation so open decision 2 (fee placement) is a local change.
    function _fee(uint128 price) internal view returns (uint128) {
        uint16 bps = REGISTRY.feeBps();
        if (bps > MAX_FEE_BPS) bps = MAX_FEE_BPS;
        return uint128((uint256(price) * bps) / BPS);
    }

    function _claimableAt(Deal storage d) internal view returns (uint40) {
        return uint40(uint256(d.expiry) + GRACE);
    }
}
