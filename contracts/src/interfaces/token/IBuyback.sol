// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IV4SwapperErrors} from "./IV4SwapperErrors.sol";

/// @title IBuyback
/// @notice FeeSink's BUYBACK route. Converts USDG → ETH → GAGE → sGAGE in clips bounded by MAX_IMPACT_BPS and burns
///         the sGAGE (T6). Permissionless above `threshold`, bounty to the caller.
interface IBuyback is IV4SwapperErrors {
    event Clip(
        address indexed caller, uint256 usdgIn, uint256 ethOut, uint256 gageOut, uint256 sgageBurned, uint256 bounty
    );
    event ThresholdSet(uint256 threshold);
    event BountySet(uint16 bountyBps);

    error BelowThreshold(uint256 balance, uint256 threshold);
    error ClipTooLarge(uint256 clip, uint256 maxClip);
    error BountyOutOfBounds();
    error ZeroAddress();

    function MAX_IMPACT_BPS() external view returns (uint16);
    function MAX_BOUNTY_BPS() external view returns (uint16);
    function threshold() external view returns (uint256);
    function bountyBps() external view returns (uint16);
    function totalBurned() external view returns (uint256);
    /// @notice Buy and burn `clipUSDG` of the USDG held here.
    function buyback(uint256 clipUSDG) external returns (uint256 burned);
    function setThreshold(uint256 threshold_) external;
    function setBounty(uint16 bountyBps_) external;
}
