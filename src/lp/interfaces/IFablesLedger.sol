// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice The part of a Fables hook's LP ledger the lane uses. A Fables LP holds ERC-6909 receipts ("shares"), minted
/// 1:1 with the liquidity it deposited into one range of one pool; the hook owns the v4 position. `withdraw` and
/// `claimFees` act for the caller's own receipts only. Transfers and claims pause with the ledger; withdrawals never do.
interface IFablesLedger {
    function poolManager() external view returns (address);

    function rangeId(PoolId poolId, int24 tickLower, int24 tickUpper) external pure returns (uint256);

    /// @dev `set` is false for a range never deposited into.
    function rangeKey(uint256 id) external view returns (PoolKey memory key, int24 tickLower, int24 tickUpper, bool set);

    function balanceOf(address owner, uint256 id) external view returns (uint256);

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);

    /// @dev Burns `liquidity` of the caller's receipts (unstaking first if it must) and pays the principal to `to`.
    function withdraw(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external;

    /// @dev Pays the caller's accrued fees to `to`; refused while the claim fee in force is above `maxFeeBps`.
    function claimFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, address to, uint16 maxFeeBps) external;
}
