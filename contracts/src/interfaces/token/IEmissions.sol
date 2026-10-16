// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title IEmissions
/// @notice Holds the 4.0B sGAGE reserve and enforces the 52-week schedule on-chain (T2). Nobody, the Safe included,
///         can emit faster than the table or after week 52.
interface IEmissions {
    event Launched(uint40 launchAt);
    event SharesSet(uint256 indexed epoch, uint16 dealShareBps, uint16 term21ShareBps);
    event Released(uint256 indexed epoch, uint256 liquidity, uint256 deals7, uint256 deals21);
    event Reserved(uint256 indexed epoch, uint32 term, uint256 amount, address to);
    event RolledOver(uint256 indexed epoch, uint256 amount);
    event Finalized(uint256 burned);

    error AlreadyLaunched();
    error NotLaunched();
    error LaunchInPast();
    error EpochNotStarted(uint256 epoch);
    error EpochNotEnded(uint256 epoch);
    error EpochOutOfRange(uint256 epoch);
    error EpochAlreadyReleased(uint256 epoch);
    error EpochNotReleased(uint256 epoch);
    error EpochAlreadyRolledOver(uint256 epoch);
    error SharesOutOfBounds();
    error EpochAlreadyStarted(uint256 epoch);
    error NotDealRewards();
    error BudgetExceeded(uint256 epoch, uint32 term, uint256 remaining, uint256 requested);
    error ScheduleNotOver();
    error TermNotRewarded(uint32 term);
    error ZeroAddress();

    function WEEKS() external view returns (uint256);
    function EPOCH() external view returns (uint256);
    function RESERVE() external view returns (uint256);
    function weekly(uint256 epoch) external view returns (uint256);
    /// @notice Sum of `weekly` for epochs 0..epoch inclusive. The on-chain ceiling on cumulative emission.
    function prefixSum(uint256 epoch) external view returns (uint256);
    function totalOut() external view returns (uint256);

    function launchAt() external view returns (uint40);
    function currentEpoch() external view returns (uint256);
    function epochStart(uint256 epoch) external view returns (uint40);
    function epochOf(uint40 timestamp) external view returns (uint256);
    function scheduleOver() external view returns (bool);

    function dealShareBps(uint256 epoch) external view returns (uint16);
    function term21ShareBps(uint256 epoch) external view returns (uint16);
    function liquidityBudget(uint256 epoch) external view returns (uint256);
    function dealBudget(uint256 epoch, uint32 term) external view returns (uint256);
    function reserved(uint256 epoch, uint32 term) external view returns (uint256);
    function remaining(uint256 epoch, uint32 term) external view returns (uint256);
    function released(uint256 epoch) external view returns (bool);
    function rolledOver(uint256 epoch) external view returns (bool);

    /// @notice Owner, once. Starts epoch 0 at `at`, which may be up to one epoch in the past.
    function launch(uint40 at) external;
    /// @notice Owner, within bounds, only for epochs that have not started.
    function setShares(uint256 epoch, uint16 dealShareBps_, uint16 term21ShareBps_) external;
    /// @notice Permissionless once the epoch has started: streams the liquidity budget to LPRewards.
    function release(uint256 epoch) external;
    /// @notice DealRewards only: moves `amount` of the epoch's term budget to `to`.
    function reserve(uint256 epoch, uint32 term, uint256 amount, address to) external;
    /// @notice Permissionless after the epoch ends plus the registration grace: unreserved deal budget → LPRewards lump.
    function rollover(uint256 epoch) external;
    /// @notice Permissionless after week 52: burns whatever is left.
    function finalize() external;
}
