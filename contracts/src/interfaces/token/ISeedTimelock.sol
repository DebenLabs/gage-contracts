// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title ISeedTimelock
/// @notice Holds the seed GAGE/sGAGE position NFT for LOCK_LENGTH, collecting swap fees to the treasury; then releases
///         the NFT to the treasury. LPRewards forces the seed's weight to zero.
interface ISeedTimelock {
    event Locked(uint256 indexed tokenId, uint40 releaseAt);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event Released(uint256 indexed tokenId, address to);

    error AlreadyLocked();
    error NotLocked();
    error StillLocked(uint40 releaseAt);
    error ZeroAddress();

    function LOCK_LENGTH() external view returns (uint40);
    function TREASURY() external view returns (address);
    function tokenId() external view returns (uint256);
    function releaseAt() external view returns (uint40);
    /// @notice Transfer the NFT in; must be called by its owner who has approved this contract. Starts the clock.
    function lock(uint256 tokenId_) external;
    function collectFees() external returns (uint256 amount0, uint256 amount1);
    function release() external;
}
