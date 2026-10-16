// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IV4SwapperErrors} from "./IV4SwapperErrors.sol";

/// @title ICreatorFeeSplitter
/// @notice Pons creator wallet. Half of every ETH received goes to operations; half is converted ETH → GAGE and
///         parked as protocol-owned, GAGE-only liquidity in the GAGE/sGAGE pool just under the market: the sGAGE
///         floor (D46, T7). Floor liquidity is never withdrawn. When the market falls through a band, the sGAGE the
///         band bought is burned by anyone.
interface ICreatorFeeSplitter is IV4SwapperErrors {
    event Split(address indexed caller, uint256 ethTotal, uint256 ethToOps, uint256 gageToFloor, uint256 bounty);
    /// @param gageIn GAGE that went into the band in this call; `liquidity` is the band's whole liquidity after it.
    event FloorAdded(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint256 gageIn, uint128 liquidity);
    /// @param sgageBurned sGAGE the band had bought, burned; `gageKept` GAGE fees kept for the next band.
    event FloorSwept(uint256 indexed tokenId, uint256 sgageBurned, uint256 gageKept);
    event Claimed(uint256 amount);
    event ThresholdSet(uint256 threshold);

    error BelowThreshold(uint256 balance, uint256 threshold);
    error ZeroAddress();
    error NotAFloorBand(uint256 tokenId);
    error FloorStillHolding(uint256 tokenId, int24 tick);
    error AlreadySwept(uint256 tokenId);

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        bool swept;
    }

    function OPS_WALLET() external view returns (address);
    function OPS_SHARE_BPS() external view returns (uint16);
    function BAND_TICKS() external view returns (int24);
    function GAGE_IS_CURRENCY0() external view returns (bool);
    function threshold() external view returns (uint256);
    /// @notice Pulls the creator share from Pons if Pons is pull-based. No-op where fees are pushed.
    function claim() external returns (uint256);
    /// @notice Split the balance: half to operations (less the caller's bounty), half bought as GAGE and added to
    ///         the floor band under the current price. Returns the GAGE that went into the floor.
    function split() external returns (uint256 gageToFloor);
    /// @notice Burn the sGAGE a band bought once the market has fallen through it. Permissionless.
    function sweep(uint256 tokenId) external returns (uint256 sgageBurned);
    /// @notice Collect a band's swap fees: sGAGE is burned, GAGE waits for the next band. Permissionless.
    function collect(uint256 tokenId) external returns (uint256 sgageBurned, uint256 gageKept);
    /// @notice The band the next split would add to, at the current price.
    function bandNow() external view returns (int24 tickLower, int24 tickUpper);
    function floorCount() external view returns (uint256);
    function floorTokenIds(uint256 i) external view returns (uint256);
    function bands(uint256 tokenId)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, bool swept);
    /// @notice GAGE and sGAGE held across every unswept band at the current price.
    function floorBacking() external view returns (uint256 gage, uint256 sgage);
    function setThreshold(uint256 threshold_) external;
}
