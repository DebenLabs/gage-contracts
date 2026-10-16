// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Kind, Collateral} from "../types/Types.sol";

// The legacy V1 deal and bid records and their states, declared here beside the interface that returns them.

/// @notice Deal states. NONE is the zero value of an unused id.
enum DealState {
    NONE,
    LISTED,
    FUNDED,
    RECLAIMED,
    CLAIMED,
    CANCELLED
}

struct Deal {
    address borrower;
    Kind kind;
    DealState state;
    uint32 term;
    uint40 listingExpiry;
    address token;
    uint40 fundedAt;
    uint40 expiry;
    uint256 amountOrTokenId;
    uint128 cap;
    uint128 minPrice;
    address lender;
    uint128 price;
    /// @dev Protocol fee deducted at accept. Recorded so DealRewards pays on the fee actually paid.
    uint128 fee;
}

/// @notice Bid states. Exactly one bid per deal ever becomes ACCEPTED.
enum BidState {
    NONE,
    OPEN,
    WITHDRAWN,
    ACCEPTED
}

struct Bid {
    uint256 dealId;
    address lender;
    uint128 price;
    uint40 expiry;
    BidState state;
}

/// @notice The legacy vault's own USDG view, which `GageLegacyAdapter` checks at construction. Moved verbatim from
/// `GageLegacyAdapter.sol` (X-dup-07); not part of `IDealVault`, whose `DealVault` declares `USDG` as `IERC20`.
interface IGageLegacyCashIdentity {
    function USDG() external view returns (address);
}

/// @title IDealVault
/// @notice External surface of the immutable core. Every asset owed to a user is credited to an
///         internal balance and pulled by that user; nothing is ever pushed (spec 8).
interface IDealVault {
    // ----------------------------------------------------------------- events (the indexer rebuilds every table from these)

    event Listed(
        uint256 indexed dealId,
        address indexed borrower,
        Kind kind,
        address token,
        uint256 amountOrTokenId,
        uint128 cap,
        uint32 term,
        uint40 listingExpiry,
        uint128 minPrice
    );
    event BidPlaced(
        uint256 indexed bidId, uint256 indexed dealId, address indexed lender, uint128 price, uint40 expiry
    );
    event BidWithdrawn(uint256 indexed bidId);
    event Funded(
        uint256 indexed dealId,
        uint256 indexed bidId,
        address indexed lender,
        uint128 price,
        uint128 fee,
        uint40 fundedAt,
        uint40 expiry
    );
    event Reclaimed(uint256 indexed dealId);
    event Claimed(uint256 indexed dealId);
    event Cancelled(uint256 indexed dealId);
    /// @param asset USDG, an ERC-20 collateral token, or the PositionManager (then `amount` is the tokenId).
    event Withdrawn(address indexed account, address indexed asset, uint256 amount);

    // ----------------------------------------------------------------- errors

    error ZeroAddress();
    error GraceBelowMinimum(uint48 grace, uint48 min);
    error NewDealsPaused();
    error InvalidCap();
    error InvalidMinPrice();
    error TermNotAllowed(uint32 term);
    error InvalidListingExpiry();
    error InvalidBidExpiry();
    error UnsupportedKind();
    error DealNotListed(uint256 dealId);
    error DealNotFunded(uint256 dealId);
    error ListingExpired(uint256 dealId);
    error BidNotOpen(uint256 bidId);
    error BidExpired(uint256 bidId);
    error BidDealMismatch(uint256 bidId, uint256 dealId);
    error ZeroPrice();
    error PriceAboveCap(uint128 price, uint128 cap);
    error PriceBelowMin(uint128 price, uint128 minPrice);
    error UnauthorizedLender(address caller, address lender);
    error NotBorrower();
    error NotLender();
    error GraceNotOver(uint40 claimableAt);
    error NothingToWithdraw();
    error TransferAmountMismatch(uint256 expected, uint256 received);
    error UnexpectedERC721(address operator, address from, uint256 tokenId);
    error NoAskingPrice(uint256 dealId);

    // ----------------------------------------------------------------- deal lifecycle (spec 5)

    /// @param listingExpiry When the listing stops taking funding; zero for a listing that stays open until it is
    ///        funded or cancelled (D43).
    /// @param minPrice The borrower's asking price. `fund` pays exactly this; an offer (`bid`) may not go below it.
    function list(Collateral calldata c, uint128 cap, uint32 term, uint40 listingExpiry, uint128 minPrice)
        external
        returns (uint256 dealId);
    function cancel(uint256 dealId) external;
    /// @notice Fund a listing at its asking price in one step: the lender's USDG is pulled, the deal is FUNDED and
    ///         the borrower is credited, exactly as if a bid at `minPrice` had been placed and accepted (D43).
    ///         Records a synthetic, already-accepted bid so every deal still has exactly one accepted bid (I8).
    /// @param lender Recorded as the deal's lender. Must be `msg.sender` unless `msg.sender` is a registry router.
    function fund(uint256 dealId, address lender) external returns (uint256 bidId);
    /// @param lender Account credited if the bid is withdrawn and recorded as lender if it is accepted.
    ///        Must be `msg.sender` unless `msg.sender` is a registry-allowlisted router.
    function bid(uint256 dealId, uint128 price, uint40 bidExpiry, address lender) external returns (uint256 bidId);
    function withdrawBid(uint256 bidId) external;
    function accept(uint256 dealId, uint256 bidId) external;
    function reclaim(uint256 dealId) external;
    function claim(uint256 dealId) external;

    // ----------------------------------------------------------------- withdrawals (pull, never push)

    function withdrawUSDG() external;
    function withdrawERC20(address token) external;
    function withdrawPosition(uint256 tokenId) external;
    /// @notice Convenience for the Deal surface: withdraws whatever the caller is owed of this deal's collateral kind.
    function withdrawCollateral(uint256 dealId) external;

    // ----------------------------------------------------------------- views

    function getDeal(uint256 dealId) external view returns (Deal memory);
    function getBid(uint256 bidId) external view returns (Bid memory);
    function claimableAt(uint256 dealId) external view returns (uint40);
    function balanceUSDG(address account) external view returns (uint256);
    function balanceERC20(address account, address token) external view returns (uint256);
    function owedNFT(address account, uint256 tokenId) external view returns (bool);
    function openRaw(address token) external view returns (uint256);
    function dealCount() external view returns (uint256);
    function bidCount() external view returns (uint256);
    function GRACE() external view returns (uint48);
}
