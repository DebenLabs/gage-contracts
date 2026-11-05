// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PositionFacts} from "../LPTypes.sol";

/// @notice One liquidity format (a DEX's position manager) behind the LP lane. An adapter is stateless, answers only
/// its core, and operates a position as the operator its escrow approved.
interface ILPAdapter {
    /// @notice The ERC-721 position manager whose positions this adapter reads and operates.
    function positionManager() external view returns (address);

    /// @notice The only core allowed to operate positions through this adapter.
    function core() external view returns (address);

    /// @notice The pool, tokens, range and liquidity of `tokenId`.
    function facts(uint256 tokenId) external view returns (PositionFacts memory);

    /// @notice Tokens the DEX pays a position's owner as rewards, including any it claims when liquidity changes.
    function rewardTokens() external view returns (address[] memory);

    /// @notice Collects only what `tokenId` is owed (its fees) to `recipient`; its liquidity is untouched.
    function collectFees(uint256 tokenId, address recipient) external returns (uint256 amount0, uint256 amount1);

    /// @notice Claims the DEX's own rewards for `tokenId`; the DEX pays them to the position's owner.
    function claimRewards(uint256 tokenId) external;

    /// @notice Removes all liquidity of `tokenId` within the minimums and collects everything to `recipient`.
    function unwind(uint256 tokenId, address recipient, uint256 min0, uint256 min1, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1);
}
