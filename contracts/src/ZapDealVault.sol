// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {DealVault} from "./DealVault.sol";
import {ICollateralRegistry} from "./interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "./types/Types.sol";
import {Deal, DealState} from "./interfaces/IDealVault.sol";

/// @title ZapDealVault
/// @notice A new immutable vault version supporting router-created position listings. Existing deployments
///         are unchanged. All settlement and withdrawal rights remain in DealVault.
contract ZapDealVault is DealVault {
    error NotListingRouter();

    event PositionWithdrawnTo(address indexed owner, address indexed recipient, uint256 indexed tokenId);

    constructor(IERC20 usdg, ICollateralRegistry registry, address feeSink, address positionManager, uint48 grace)
        DealVault(usdg, registry, feeSink, positionManager, grace)
    {}

    /// @notice Capability marker for routers and clients; absent on earlier immutable deployments.
    function zapListingVersion() external pure returns (uint256) {
        return 1;
    }

    /// @notice Withdraw your credited LP to a compatible wallet, even if your account cannot receive NFTs.
    /// @dev Only the credited owner can choose a recipient. Failed receipt restores the credit atomically.
    function withdrawPositionTo(uint256 tokenId, address recipient) external nonReentrant {
        if (recipient == address(0)) revert ZeroAddress();
        if (!owedNFT[msg.sender][tokenId]) revert NothingToWithdraw();
        owedNFT[msg.sender][tokenId] = false;
        IERC721(POSITION_MANAGER).safeTransferFrom(address(this), recipient, tokenId);
        emit Withdrawn(msg.sender, POSITION_MANAGER, tokenId);
        emit PositionWithdrawnTo(msg.sender, recipient, tokenId);
    }

    /// @dev This additional vault shares the existing admission registry but accepts LPs only.
    ///      It cannot create a second ERC20 market with a separate openRaw accounting limit.
    function _pullCollateral(Collateral calldata c) internal override {
        if (c.kind != Kind.UNIV4_POSITION) revert UnsupportedKind();
        super._pullCollateral(c);
    }

    /// @notice Escrow a router-owned position with `borrower` owning the resulting open-ended listing.
    /// @dev Only the caller's NFT is pulled. This entry point cannot spend a named borrower's approvals,
    ///      collateral or USDG, and the router acquires no rights over the resulting deal.
    function listPositionFor(Collateral calldata c, uint128 cap, uint32 term, uint128 minPrice, address borrower)
        external
        nonReentrant
        returns (uint256 dealId)
    {
        if (REGISTRY.newDealsPaused()) revert NewDealsPaused();
        if (!REGISTRY.isRouter(msg.sender)) revert NotListingRouter();
        if (borrower == address(0)) revert ZeroAddress();
        if (c.kind != Kind.UNIV4_POSITION) revert UnsupportedKind();
        if (cap == 0) revert InvalidCap();
        if (minPrice == 0 || minPrice > cap) revert InvalidMinPrice();
        if (!REGISTRY.isTermAllowed(term)) revert TermNotAllowed(term);

        dealId = ++dealCount;
        Deal storage d = _deals[dealId];
        d.borrower = borrower;
        d.kind = c.kind;
        d.state = DealState.LISTED;
        d.term = term;
        d.token = c.token;
        d.amountOrTokenId = c.amountOrTokenId;
        d.cap = cap;
        d.minPrice = minPrice;
        _pullCollateral(c);
        emit Listed(dealId, borrower, c.kind, c.token, c.amountOrTokenId, cap, term, 0, minPrice);
    }
}
