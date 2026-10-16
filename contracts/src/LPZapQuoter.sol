// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LPZapRouter} from "./LPZapRouter.sol";

/// @notice Simulates complete v4 routes and the LP split, including hooks and initialized-tick crossings.
/// @dev Every pool mutation is reverted before a result returns. No approvals, payments or custody.
contract LPZapQuoter is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;
    uint256 public constant SPLIT_ITERATIONS = 18;

    struct Params {
        address inputCurrency;
        uint128 amountIn;
        PoolKey pool;
        address baseToken;
        int24 tickLower;
        int24 tickUpper;
        uint16 slippageBps;
        PoolKey[] route;
    }

    struct Split {
        uint128 sell;
        uint128 output;
        uint160 sqrtPriceAfterX96;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }

    struct Result {
        LPZapRouter.Swap[] swaps;
        Split split;
        uint128 baseAmount;
    }

    error InvalidQuote();
    error NotSelf();
    error NotPoolManager();
    error QuoteFailed(bytes reason);
    error QuoteResult(bytes result);
    error SwapResult(bytes result);

    constructor(IPoolManager manager) {
        if (address(manager).code.length == 0) revert InvalidQuote();
        POOL_MANAGER = manager;
    }

    /// @notice Use eth_call. Even a transaction cannot settle swaps or move assets through this quoter.
    function quote(Params calldata p) external returns (Result memory result) {
        if (
            p.amountIn < 2 || p.route.length > 3 || p.slippageBps == 0 || p.slippageBps > 500
                || p.tickLower >= p.tickUpper || p.tickLower < TickMath.MIN_TICK || p.tickUpper > TickMath.MAX_TICK
                || p.pool.tickSpacing <= 0 || p.tickLower % p.pool.tickSpacing != 0
                || p.tickUpper % p.pool.tickSpacing != 0
                || (p.baseToken != Currency.unwrap(p.pool.currency0)
                    && p.baseToken != Currency.unwrap(p.pool.currency1))
        ) revert InvalidQuote();
        try POOL_MANAGER.unlock(abi.encode(p)) {
            revert InvalidQuote();
        } catch (bytes memory reason) {
            result = abi.decode(_decode(reason, QuoteResult.selector), (Result));
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        Params memory p = abi.decode(data, (Params));
        Result memory r;
        r.swaps = new LPZapRouter.Swap[](p.route.length + 1);
        address currency = p.inputCurrency;
        uint128 available = p.amountIn;
        for (uint256 i; i < p.route.length; ++i) {
            PoolKey memory key = p.route[i];
            if (PoolId.unwrap(key.toId()) == PoolId.unwrap(p.pool.toId())) revert InvalidQuote();
            bool zeroForOne = currency == Currency.unwrap(key.currency0);
            if (!zeroForOne && currency != Currency.unwrap(key.currency1)) revert InvalidQuote();
            (uint128 out,) = _swap(key, zeroForOne, available);
            uint128 minOut = uint128(uint256(out) * (10_000 - p.slippageBps) / 10_000);
            if (minOut == 0) revert InvalidQuote();
            r.swaps[i] = LPZapRouter.Swap(key, zeroForOne, available, minOut);
            available = minOut;
            currency = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
        }
        if (currency != p.baseToken || available < 2) revert InvalidQuote();
        r.baseAmount = available;
        bool direction = p.baseToken == Currency.unwrap(p.pool.currency0);
        r.split = _solve(p, direction, available);
        uint128 targetMin = uint128(uint256(r.split.output) * (10_000 - p.slippageBps) / 10_000);
        if (r.split.liquidity == 0 || targetMin == 0) revert InvalidQuote();
        r.swaps[p.route.length] = LPZapRouter.Swap(p.pool, direction, r.split.sell, targetMin);
        revert QuoteResult(abi.encode(r));
    }

    function _solve(Params memory p, bool direction, uint128 available) private returns (Split memory best) {
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(p.tickUpper);
        uint128 lo;
        uint128 hi = available;
        for (uint256 i; i < SPLIT_ITERATIONS && hi - lo > 1; ++i) {
            uint128 sell = lo + (hi - lo) / 2;
            (uint128 output, uint160 sqrtP) = _sample(p.pool, direction, sell);
            if (sqrtP <= sqrtL || sqrtP >= sqrtU) {
                hi = sell;
                continue;
            }
            uint256 a0 = direction ? available - sell : output;
            uint256 a1 = direction ? output : available - sell;
            uint128 l0 = LiquidityAmounts.getLiquidityForAmount0(sqrtP, sqrtU, a0);
            uint128 l1 = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtP, a1);
            uint128 liquidity = l0 < l1 ? l0 : l1;
            if (liquidity > best.liquidity) best = Split(sell, output, sqrtP, liquidity, a0, a1);
            if (direction ? l0 > l1 : l1 > l0) lo = sell;
            else hi = sell;
        }
    }

    /// @dev An external self-call provides a rollback boundary for each target split candidate.
    function sample(PoolKey calldata pool, bool direction, uint128 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        (uint128 output, uint160 sqrtP) = _swap(pool, direction, amount);
        revert SwapResult(abi.encode(output, sqrtP));
    }

    function _sample(PoolKey memory pool, bool direction, uint128 amount) private returns (uint128, uint160) {
        try this.sample(pool, direction, amount) {
            revert InvalidQuote();
        } catch (bytes memory reason) {
            return abi.decode(_decode(reason, SwapResult.selector), (uint128, uint160));
        }
    }

    function _swap(PoolKey memory pool, bool direction, uint128 amount)
        private
        returns (uint128 output, uint160 sqrtP)
    {
        BalanceDelta delta = POOL_MANAGER.swap(
            pool,
            SwapParams(
                direction,
                -int256(uint256(amount)),
                direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 paid = direction ? delta.amount0() : delta.amount1();
        int128 got = direction ? delta.amount1() : delta.amount0();
        if (paid >= 0 || got <= 0 || uint256(-int256(paid)) != amount) revert InvalidQuote();
        output = uint128(got);
        (sqrtP,,,) = POOL_MANAGER.getSlot0(pool.toId());
    }

    function _decode(bytes memory reason, bytes4 expected) private pure returns (bytes memory) {
        if (reason.length < 4) revert QuoteFailed(reason);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
        }
        if (selector != expected) revert QuoteFailed(reason);
        bytes memory payload = new bytes(reason.length - 4);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = reason[i + 4];
        }
        return abi.decode(payload, (bytes));
    }
}
