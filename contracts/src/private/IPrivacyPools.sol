// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @title IPrivacyPool
/// @notice The part of 0xbow's Privacy Pools v1.3.0 (commit c312dcd58f) pool that the private lane's router calls.
/// @dev The two structs repeat `IPrivacyPool.Withdrawal` and `ProofLib.WithdrawProof` member for member, so the ABI
///      encoding and the `withdraw` selector are the pool's own.
interface IPrivacyPool {
    struct Withdrawal {
        address processooor;
        bytes data;
    }

    struct WithdrawProof {
        uint256[2] pA;
        uint256[2][2] pB;
        uint256[2] pC;
        /// @dev newCommitmentHash, existingNullifierHash, withdrawnValue, stateRoot, stateTreeDepth, ASPRoot,
        /// ASPTreeDepth, context.
        uint256[8] pubSignals;
    }

    /// @notice Spend a note and push `withdrawnValue` of the pool's asset to the processooor, who must be the caller.
    function withdraw(Withdrawal memory withdrawal, WithdrawProof memory proof) external;
}

/// @title IPrivacyPoolsEntrypoint
/// @notice The part of the Privacy Pools v1.3.0 Entrypoint that the private lane's router reads.
interface IPrivacyPoolsEntrypoint {
    /// @notice The one pool registered for `asset`, and its deposit and relay settings.
    function assetConfig(address asset)
        external
        view
        returns (address pool, uint256 minimumDepositAmount, uint256 vettingFeeBPS, uint256 maxRelayFeeBPS);

    /// @notice The association-set root every withdrawal proof must be made against.
    function latestRoot() external view returns (uint256);
}
