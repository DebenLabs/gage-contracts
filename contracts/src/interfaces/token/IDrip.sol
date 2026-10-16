// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title IDrip
/// @notice Locked sGAGE balances that unlock on the quadratic curve `unlocked(t) = total * min(t - start, length)^2 / length^2`.
///         Nothing releases a drip early or slows it (T3). Grantors: DealRewards and LPRewards only.
interface IDrip {
    struct DripAccount {
        uint128 total;
        uint128 claimed;
        uint40 start;
        uint32 length;
    }

    event Granted(
        address indexed account, bytes32 indexed dripId, uint128 total, uint40 start, uint32 length, address grantor
    );
    event Claimed(address indexed account, bytes32 indexed dripId, uint128 amount);
    event GrantorsSet(address dealRewards, address lpRewards);

    error NotGrantor(address caller);
    error DripExists(address account, bytes32 dripId);
    error NoDrip(address account, bytes32 dripId);
    error ZeroLength();
    error ZeroAmount();
    error NothingClaimable();
    error GrantorsAlreadySet();
    error ZeroAddress();

    /// @notice Pulls `total` sGAGE from the grantor and opens a drip for `account`. One drip per (account, dripId).
    function grant(address account, bytes32 dripId, uint128 total, uint40 start, uint32 length) external;
    /// @notice Transfers `unlocked - claimed` of the caller's drip to the caller.
    function claim(bytes32 dripId) external returns (uint128 amount);
    function claimMany(bytes32[] calldata dripIds) external returns (uint128 amount);

    function unlocked(address account, bytes32 dripId) external view returns (uint128);
    function claimable(address account, bytes32 dripId) external view returns (uint128);
    function getDrip(address account, bytes32 dripId) external view returns (DripAccount memory);
    function isGrantor(address account) external view returns (bool);
    /// @notice Sum of every open drip's `total - claimed`. Always equals this contract's sGAGE balance.
    function totalLocked() external view returns (uint256);
}
