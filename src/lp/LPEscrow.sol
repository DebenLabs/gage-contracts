// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title LPEscrow
/// @notice One loan's custody: an EIP-1167 clone that holds one position and does only what its core says. The core
/// deploys the implementation and is written into its code, so every clone answers to that core from its first byte,
/// with nothing to set up and nothing anyone else could claim.
/// @dev No ERC-721 receiver: the core moves positions with plain transfers, and a safe transfer from anyone else is
/// refused rather than stranded here.
contract LPEscrow {
    using SafeERC20 for IERC20;

    /// @notice The core this escrow answers to: the deployer of the implementation every clone runs.
    address public immutable CORE;

    error NotCore(address caller);

    constructor() {
        CORE = msg.sender;
    }

    modifier onlyCore() {
        if (msg.sender != CORE) revert NotCore(msg.sender);
        _;
    }

    /// @notice Lets `operator` (the loan's adapter) operate position `tokenId`.
    function approveOperator(address nft, address operator, uint256 tokenId) external onlyCore {
        IERC721(nft).approve(operator, tokenId);
    }

    /// @notice Sends position `tokenId` to `to`. A plain transfer: no receiver callback runs.
    function sendPosition(address nft, address to, uint256 tokenId) external onlyCore {
        IERC721(nft).transferFrom(address(this), to, tokenId);
    }

    /// @notice Sends this escrow's whole balance of `token` to `to` and returns it.
    function sweep(address token, address to) external onlyCore returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }
}
