// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ILPRewards
/// @notice Emissions to GAGE/sGAGE liquidity by LP score: a Synthetix-style accumulator over variable weights, where
///         a position's weight is its value in GAGE at the last checkpoint and zero while out of range. Rewards
///         accrue to the tokenId; the current owner collects. Nothing here ever holds a user's position NFT (T5).
interface ILPRewards {
    struct PositionState {
        uint256 weight;
        uint256 emissionsPerWeightPaid;
        uint256 lumpPerWeightPaid;
        uint256 emissionsEarned;
        uint256 lumpEarned;
        uint40 lastCheckpoint;
        uint32 collectNonce;
    }

    event Checkpointed(uint256 indexed tokenId, uint256 weight, uint256 totalWeight, bool inRange);
    event EmissionsNotified(uint256 indexed epoch, uint256 amount);
    event LumpNotified(address indexed from, uint256 amount, uint256 totalWeight);
    event Collected(
        uint256 indexed tokenId, address indexed owner, uint256 emissions, bytes32 dripId, uint256 creatorFee
    );
    event SeedSet(uint256 indexed tokenId);
    event FloorSet(address indexed floor);

    error NotHook();
    error NotEmissions();
    error NotOwner(uint256 tokenId, address caller);
    error WrongPool(uint256 tokenId);
    error SeedAlreadySet();
    error FloorAlreadySet();
    error NotSeedTimelock();
    error NothingToCollect(uint256 tokenId);
    error ZeroAddress();

    function LP_DRIP_LENGTH() external view returns (uint32);

    function checkpoint(uint256 tokenId) external;
    function checkpointMany(uint256[] calldata tokenIds) external;
    /// @notice LPHook only, on every add and remove through the PositionManager.
    function onLiquidityChange(uint256 tokenId) external;
    /// @notice Emissions only: `amount` sGAGE has arrived for `epoch`; it streams over that epoch's week.
    function notifyEmissions(uint256 epoch, uint256 amount) external;
    /// @notice Pulls `amount` sGAGE from the caller and distributes it to current weights at once (creator fees,
    ///         rollover).
    function notifyLump(uint256 amount) external;
    /// @notice By the NFT's current owner: emissions into a new 7-day drip, creator-fee sGAGE transferred at once.
    function collect(uint256 tokenId) external returns (uint256 emissions, uint256 creatorFee);

    function earned(uint256 tokenId) external view returns (uint256 emissions, uint256 creatorFee);
    function positionState(uint256 tokenId) external view returns (PositionState memory);
    function valueInGAGE(uint256 tokenId) external view returns (uint256 value, bool inRange);
    function totalWeight() external view returns (uint256);
    function poolKey() external view returns (PoolKey memory);
    function seedTokenId() external view returns (uint256);
    /// @notice SeedTimelock only, once: the seed position scores zero forever.
    function setSeed(uint256 tokenId) external;
    /// @notice The CreatorFeeSplitter, whose floor bands carry no weight. Deployer, once.
    function setFloor(address floor_) external;
    function floor() external view returns (address);
    function dripIdOf(uint256 tokenId, uint32 collectNonce) external pure returns (bytes32);
}
