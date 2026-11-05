// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {ILPSwapExecutor} from "../interfaces/ILPSwapExecutor.sol";

/// @title UniV4SwapExecutor
/// @notice Sells the other token of one hookless Uniswap v4 pool that pairs an ERC-20 with USDG (a stock token whose
/// deepest USDG pool is on v4, say) for USDG, through the PoolManager. It holds tokens only inside the call that sold
/// them; the caller (a vault) enforces its own minimum on what arrives.
contract UniV4SwapExecutor is ILPSwapExecutor, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable USDG;
    /// @notice The token this executor sells: the pool's other currency.
    address public immutable OTHER;
    address internal immutable CURRENCY0;
    address internal immutable CURRENCY1;
    uint24 internal immutable FEE;
    int24 internal immutable TICK_SPACING;

    error WrongToken(address token);
    error HookedPool(address hooks);
    error NotPoolManager(address caller);
    error AmountTooLarge();

    constructor(IPoolManager poolManager, PoolKey memory key, address usdg) {
        if (address(key.hooks) != address(0)) revert HookedPool(address(key.hooks));
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != usdg && c1 != usdg) revert WrongToken(usdg);
        address other = c0 == usdg ? c1 : c0;
        // Native ETH is not sold here: a native pool's ETH reaches a vault as WETH, sold by a WETH executor.
        if (other == address(0)) revert WrongToken(other);
        POOL_MANAGER = poolManager;
        USDG = usdg;
        OTHER = other;
        CURRENCY0 = c0;
        CURRENCY1 = c1;
        FEE = key.fee;
        TICK_SPACING = key.tickSpacing;
    }

    /// @notice The pool this executor sells into.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(CURRENCY0), Currency.wrap(CURRENCY1), FEE, TICK_SPACING, IHooks(address(0)));
    }

    /// @inheritdoc ILPSwapExecutor
    function swap(address tokenIn, uint256 amountIn, address recipient) external returns (uint256 amountOut) {
        if (tokenIn != OTHER) revert WrongToken(tokenIn);
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        amountOut = abi.decode(POOL_MANAGER.unlock(abi.encode(amountIn, recipient)), (uint256));
        // Anything the pool did not take (its liquidity ran out) goes back to the recipient.
        uint256 left = IERC20(OTHER).balanceOf(address(this));
        if (left != 0) IERC20(OTHER).safeTransfer(recipient, left);
    }

    /// @notice Swaps exactly the input given inside the PoolManager's lock, pays what the pool took, and takes the
    /// USDG it owes straight to the recipient.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);
        (uint256 amountIn, address recipient) = abi.decode(data, (uint256, address));
        bool zeroForOne = OTHER == CURRENCY0;
        BalanceDelta delta = POOL_MANAGER.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 paid = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 out = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        POOL_MANAGER.sync(Currency.wrap(OTHER));
        IERC20(OTHER).safeTransfer(address(POOL_MANAGER), paid);
        POOL_MANAGER.settle();
        if (out != 0) POOL_MANAGER.take(Currency.wrap(USDG), recipient, out);
        return abi.encode(out);
    }
}
