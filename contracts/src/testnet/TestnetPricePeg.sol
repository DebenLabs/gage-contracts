// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

interface IOpenMint {
    function mint(address to, uint256 amount) external;
}

/// @title TestnetPricePeg
/// @notice Testnet only: moves a pool of two open-mint testnet tokens to a target price, so a testnet stock follows its
///         real market (D232: NVDAx at the real NVDA price, which the keeper reads). It swaps tokens it mints itself
///         into the pool and stops exactly at the target, then keeps what the swap paid out. Only its operator may call
///         it.
contract TestnetPricePeg is TestnetOnly, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;
    /// @notice The only account that may move a price: the keeper's wallet.
    address public immutable OPERATOR;

    error InvalidConfiguration();
    error InvalidPool();
    error InvalidTarget();
    error NotOperator();
    error NotPoolManager();

    event Pegged(
        bytes32 indexed poolId, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96, int128 amount0, int128 amount1
    );

    /// @param poolManager The testnet's Uniswap v4 PoolManager.
    /// @param operator The account allowed to move prices.
    constructor(IPoolManager poolManager, address operator) {
        if (address(poolManager).code.length == 0 || operator == address(0)) revert InvalidConfiguration();
        POOL_MANAGER = poolManager;
        OPERATOR = operator;
    }

    /// @notice Move `key`'s price to `target`, a sqrt price X96, minting and selling whichever token moves it there.
    /// @dev Operator only. The pool must be initialized, hookless and pair two open-mint ERC-20s.
    /// @param key The pool.
    /// @param target The sqrt price X96 to move it to.
    /// @return delta The swap's balance change for this contract: what it minted in (negative), what it took (positive).
    function peg(PoolKey calldata key, uint160 target) external returns (BalanceDelta delta) {
        if (msg.sender != OPERATOR) revert NotOperator();
        if (address(key.hooks) != address(0) || Currency.unwrap(key.currency0) == address(0)) revert InvalidPool();
        if (target <= TickMath.MIN_SQRT_PRICE || target >= TickMath.MAX_SQRT_PRICE) revert InvalidTarget();
        PoolId id = key.toId();
        (uint160 current,,,) = POOL_MANAGER.getSlot0(id);
        if (current == 0) revert InvalidPool();
        if (current != target) {
            delta = abi.decode(POOL_MANAGER.unlock(abi.encode(key, target, current)), (BalanceDelta));
        }
        (uint160 reached,,,) = POOL_MANAGER.getSlot0(id);
        emit Pegged(PoolId.unwrap(id), current, reached, delta.amount0(), delta.amount1());
    }

    /// @notice The PoolManager's callback inside `peg`: swap to the target, mint what is owed, take what is paid.
    /// @param data The encoded pool, target and starting price.
    /// @return The swap's balance delta, encoded.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (PoolKey memory key, uint160 target, uint160 current) = abi.decode(data, (PoolKey, uint160, uint160));
        // A lower price sells token0 for token1; a higher one buys token0. The price limit stops the swap at the target,
        // so the exact input is only a ceiling.
        bool zeroForOne = target < current;
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(type(int128).max), sqrtPriceLimitX96: target}),
            ""
        );
        _clear(key.currency0, delta.amount0());
        _clear(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    /// @dev Mint what the pool is owed straight to it, or take what it owes this contract.
    function _clear(Currency currency, int128 amount) private {
        if (amount < 0) {
            POOL_MANAGER.sync(currency);
            IOpenMint(Currency.unwrap(currency)).mint(address(POOL_MANAGER), uint256(uint128(-amount)));
            POOL_MANAGER.settle();
        } else if (amount > 0) {
            POOL_MANAGER.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
