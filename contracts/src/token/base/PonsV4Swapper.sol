// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IPonsCurve} from "../../interfaces/token/IPonsCurve.sol";
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

/// @title PonsV4Swapper
/// @notice Single-pool swaps straight through the PoolManager for the token layer's own contracts, so nothing here
///         depends on the Universal Router's calldata format. Exact-input and exact-output, with a spot-price quote
///         for the impact bound.
abstract contract PonsV4Swapper is IUnlockCallback, IV4SwapperErrors {
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
    error InvalidPonsMarket();
    error CurveAllocationExceeded();
    error PartialCurveFill();

    IPonsCurve public immutable PONS_CURVE;
    uint24 public immutable PONS_HOOK_FEE_PIPS;
    bytes32 internal immutable _PONS_POOL_ID;
    address internal immutable _PONS_TOKEN;

    constructor(IPoolManager poolManager, address curve_, PoolKey memory launchPool, uint24 hookFeePips_) {
        IPonsCurve curve = IPonsCurve(curve_);
        // A zero curve is reserved for the public Robinhood testnet's v4 launch fixture.
        // Production always binds the actual Pons curve and its immutable launch options.
        if (curve_ == address(0)) {
            if (block.chainid != 46_630 || address(launchPool.hooks) != address(0) || hookFeePips_ != 0) {
                revert InvalidPonsMarket();
            }
        } else if (
            curve.pairToken() != address(0) || !launchPool.currency0.isAddressZero()
                || curve.token() != Currency.unwrap(launchPool.currency1) || hookFeePips_ >= 1_000_000
                || curve.creatorTaxBps() != 0 || curve.buybackEnabled()
        ) {
            revert InvalidPonsMarket();
        }
        POOL_MANAGER = poolManager;
        PONS_CURVE = curve;
        PONS_HOOK_FEE_PIPS = hookFeePips_;
        _PONS_TOKEN = Currency.unwrap(launchPool.currency1);
        _PONS_POOL_ID = keccak256(abi.encode(launchPool));
    }

    function _isPons(PoolKey memory key) internal view returns (bool) {
        return address(PONS_CURVE) != address(0) && keccak256(abi.encode(key)) == _PONS_POOL_ID;
    }

    function _curveBuy(uint256 ethIn, uint256 minGage) internal returns (uint256 out) {
        uint256 beforeEth = address(this).balance;
        uint256 beforeGage = IERC20(_PONS_TOKEN).balanceOf(address(this));
        PONS_CURVE.buy{value: ethIn}(ethIn, minGage, address(this));
        // Do not silently treat a clamped, partially refunded purchase as a full clip.
        if (address(this).balance != beforeEth - ethIn) revert PartialCurveFill();
        out = IERC20(_PONS_TOKEN).balanceOf(address(this)) - beforeGage;
        if (out < minGage) revert TooLittleOut(out, minGage);
    }

    function _curveEthForGage(uint256 out) internal view returns (uint256 amount) {
        (uint256 quoteReserve, uint256 tokenReserve) = PONS_CURVE.getReserves();
        if (out >= tokenReserve || out > PONS_CURVE.sellableTokens()) revert CurveAllocationExceeded();
        uint256 curveFee = PONS_CURVE.feeBps() + PONS_CURVE.creatorTaxBps();
        if (curveFee >= 10_000) revert InvalidPonsMarket();
        uint256 net = Math.mulDiv(quoteReserve, out, tokenReserve - out, Math.Rounding.Ceil);
        amount = Math.mulDiv(net, 10_000, 10_000 - curveFee, Math.Rounding.Ceil) + 1;
    }

    /// @dev Swap exactly `amountIn`; revert unless at least `minOut` comes back.
    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        if (_isPons(key) && !PONS_CURVE.graduated()) {
            if (zeroForOne) return _curveBuy(amountIn, minOut);
            IERC20(_PONS_TOKEN).forceApprove(address(PONS_CURVE), amountIn);
            uint256 beforeEth = address(this).balance;
            PONS_CURVE.sell(amountIn, minOut, address(this));
            IERC20(_PONS_TOKEN).forceApprove(address(PONS_CURVE), 0);
            amountOut = address(this).balance - beforeEth;
            if (amountOut < minOut) revert TooLittleOut(amountOut, minOut);
            return amountOut;
        }
        bytes memory r = POOL_MANAGER.unlock(abi.encode(SwapCall(key, zeroForOne, false, amountIn, minOut)));
        amountOut = abi.decode(r, (uint256));
    }

    /// @dev Receive exactly `amountOut`; revert if more than `maxIn` is needed.
    function _swapExactOut(PoolKey memory key, bool zeroForOne, uint256 amountOut, uint256 maxIn)
        internal
        returns (uint256 amountIn)
    {
        if (_isPons(key) && !PONS_CURVE.graduated()) {
            if (!zeroForOne) revert InvalidPonsMarket();
            amountIn = _curveEthForGage(amountOut);
            if (amountIn > maxIn) revert TooMuchIn(amountIn, maxIn);
            _curveBuy(amountIn, amountOut);
            return amountIn;
        }
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
        if (_isPons(key) && !PONS_CURVE.graduated()) {
            (uint256 q, uint256 t) = PONS_CURVE.getReserves();
            uint256 curveFee = PONS_CURVE.feeBps() + PONS_CURVE.creatorTaxBps();
            if (curveFee >= 10_000) revert InvalidPonsMarket();
            uint256 spot = zeroForOne ? Math.mulDiv(amountIn, t, q) : Math.mulDiv(amountIn, q, t);
            return Math.mulDiv(Math.mulDiv(spot, 10_000 - curveFee, 10_000), 10_000 - impactBps, 10_000);
        }
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint256 out;
        if (zeroForOne) {
            out = Math.mulDiv(Math.mulDiv(amountIn, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
        } else {
            out = Math.mulDiv(Math.mulDiv(amountIn, FixedPoint96.Q96, sqrtP), FixedPoint96.Q96, sqrtP);
        }
        uint24 fee = LPFeeLibrary.isDynamicFee(key.fee) ? feeOverridePips : key.fee;
        out = (out * (LPFeeLibrary.MAX_LP_FEE - fee)) / LPFeeLibrary.MAX_LP_FEE;
        if (_isPons(key)) out = Math.mulDiv(out, 1_000_000 - PONS_HOOK_FEE_PIPS, 1_000_000);
        minOut = (out * (10_000 - impactBps)) / 10_000;
    }

    function _isCurrency0(PoolKey memory key, address token) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == token;
    }

    receive() external payable {}
}
