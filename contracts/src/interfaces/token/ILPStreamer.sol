// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IDrip} from "./IDrip.sol";

/// @title ILPStreamer
/// @notice A second sGAGE stream for GAGE/sGAGE liquidity that pays by liquidity held over time, on the existing
///         pool, without a hook (D64). It mirrors LPRewards: what a position accrues from the emission stream in an
///         epoch is the exact measure of the weight it held over that epoch, kept by the hook on every add and
///         remove. Anyone may deposit; each epoch's pot is fixed at the epoch's start from everything deposited
///         during the epoch before, and a position is paid pot × (its accrual in the epoch / the epoch's liquidity
///         budget). Rewards accrue to the tokenId; the current owner collects into a 7-day drip. Never holds a position NFT.
interface ILPStreamer {
    struct Position {
        /// @dev The LPRewards emission accrual last read for the position.
        uint256 accrualSeen;
        /// @dev The LPRewards collect nonce last read; a change means LPRewards.collect reset the accrual.
        uint32 collectNonceSeen;
        /// @dev The epoch of the last checkpoint here.
        uint256 epochSeen;
        uint256 earned;
        bool seen;
        uint32 collectNonce;
    }

    event Deposited(address indexed from, uint256 amount, uint256 indexed forEpoch);
    event PotFixed(uint256 indexed epoch, uint256 pot, uint256 rate);
    event Checkpointed(uint256 indexed tokenId, uint256 accrual, uint256 credit, uint256 epoch);
    event Collected(uint256 indexed tokenId, address indexed owner, uint256 amount, bytes32 dripId);

    error ZeroAddress();
    error NotOwner(uint256 tokenId, address caller);
    error NothingToCollect(uint256 tokenId);
    error ScheduleOver();

    /// @notice Pulls `amount` sGAGE from the caller into the pot of the next epoch. Anyone.
    function deposit(uint256 amount) external;
    /// @notice Credits a position for its LPRewards accrual since the last checkpoint here. Permissionless.
    function checkpoint(uint256 tokenId) external;
    function checkpointMany(uint256[] calldata tokenIds) external;
    /// @notice By the NFT's current owner: everything earned into a new 7-day drip on `DRIP`. Call it before
    ///         LPRewards.collect.
    function collect(uint256 tokenId) external returns (uint256 amount);
    /// @notice The streamer's own Drip (the live one only takes grants from its launch grantors); same quadratic curve.
    function DRIP() external view returns (IDrip);
    function DRIP_LENGTH() external view returns (uint32);
    function dripIdOf(uint256 tokenId, uint32 collectNonce) external pure returns (bytes32);

    function earned(uint256 tokenId) external view returns (uint256);
    function positionState(uint256 tokenId) external view returns (Position memory);
    /// @notice Deposits waiting for the next epoch's pot.
    function pending() external view returns (uint256);
    function pot(uint256 epoch) external view returns (uint256);
    /// @notice sGAGE paid per sGAGE of LPRewards accrual in `epoch`, scaled by 1e27.
    function rate(uint256 epoch) external view returns (uint256);
    /// @notice The last epoch whose pot is fixed.
    function assignedThrough() external view returns (uint256);
}
