// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IV4SwapperErrors} from "../../interfaces/token/IV4SwapperErrors.sol";

/// @title V4Swapper
/// @notice Single-pool swaps straight through the PoolManager for the token layer's own contracts, so nothing here
///         depends on the Universal Router's calldata format. Exact-input and exact-output, with a spot-price quote
///         for the impact bound.
abstract contract V4Swapper is IUnlockCallback, IV4SwapperErrors {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable POOL_MANAGER;

    struct SwapCall {
        PoolKey key;
        bool zeroForOne;
        bool exactOut;
        uint256 amount;
        uint256 limit;
    }

    error NotPoolManager();

    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
    }

    /// @dev Swap exactly `amountIn`; revert unless at least `minOut` comes back.
    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        bytes memory r = POOL_MANAGER.unlock(abi.encode(SwapCall(key, zeroForOne, false, amountIn, minOut)));
        amountOut = abi.decode(r, (uint256));
    }

    /// @dev Receive exactly `amountOut`; revert if more than `maxIn` is needed.
    function _swapExactOut(PoolKey memory key, bool zeroForOne, uint256 amountOut, uint256 maxIn)
        internal
        returns (uint256 amountIn)
    {
        bytes memory r = POOL_MANAGER.unlock(abi.encode(SwapCall(key, zeroForOne, true, amountOut, maxIn)));
        amountIn = abi.decode(r, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        SwapCall memory c = abi.decode(data, (SwapCall));
        BalanceDelta delta = POOL_MANAGER.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: c.exactOut ? int256(c.amount) : -int256(c.amount),
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency cIn, Currency cOut) =
            c.zeroForOne ? (c.key.currency0, c.key.currency1) : (c.key.currency1, c.key.currency0);
        int128 dIn = c.zeroForOne ? delta.amount0() : delta.amount1();
        int128 dOut = c.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 paid = uint256(uint128(-dIn));
        uint256 got = uint256(uint128(dOut));
        if (c.exactOut) {
            if (paid > c.limit) revert TooMuchIn(paid, c.limit);
        } else {
            if (got < c.limit) revert TooLittleOut(got, c.limit);
        }
        _settle(cIn, paid);
        POOL_MANAGER.take(cOut, address(this), got);
        return abi.encode(c.exactOut ? paid : got);
    }

    function _settle(Currency c, uint256 amount) internal {
        if (c.isAddressZero()) {
            POOL_MANAGER.settle{value: amount}();
        } else {
            POOL_MANAGER.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    /// @dev What `amountIn` buys at the current spot price, less the pool's LP fee, less `impactBps`.
    ///      For a dynamic-fee pool the caller supplies `feeOverridePips` (VERIFY the Pons hook fee).
    function _quoteAtSpot(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint16 impactBps,
        uint24 feeOverridePips
    ) internal view returns (uint256 minOut) {
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint256 out;
        if (zeroForOne) {
            out = Math.mulDiv(Math.mulDiv(amountIn, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
        } else {
            out = Math.mulDiv(Math.mulDiv(amountIn, FixedPoint96.Q96, sqrtP), FixedPoint96.Q96, sqrtP);
        }
        uint24 fee = LPFeeLibrary.isDynamicFee(key.fee) ? feeOverridePips : key.fee;
        out = (out * (LPFeeLibrary.MAX_LP_FEE - fee)) / LPFeeLibrary.MAX_LP_FEE;
        minOut = (out * (10_000 - impactBps)) / 10_000;
    }

    function _isCurrency0(PoolKey memory key, address token) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == token;
    }

    receive() external payable {}
}
