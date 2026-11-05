// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILPSwapExecutor} from "../interfaces/ILPSwapExecutor.sol";
import {IUniV3Pool} from "../interfaces/IConcentratedLiquidity.sol";

/// @title UniV3SwapExecutor
/// @notice Sells the non-USDG token of one Uniswap v3 (or Ramses V3) USDG pool for USDG. It holds tokens only inside
/// the call that sold them; the caller (a vault) enforces its own minimum on what arrives.
contract UniV3SwapExecutor is ILPSwapExecutor {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    IUniV3Pool public immutable POOL;
    address public immutable USDG;
    address public immutable OTHER;

    error WrongToken(address token);
    error NotPool(address caller);
    error AmountTooLarge();

    constructor(IUniV3Pool pool, address usdg) {
        POOL = pool;
        USDG = usdg;
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (t0 != usdg && t1 != usdg) revert WrongToken(usdg);
        OTHER = t0 == usdg ? t1 : t0;
    }

    /// @inheritdoc ILPSwapExecutor
    function swap(address tokenIn, uint256 amountIn, address recipient) external returns (uint256 amountOut) {
        if (tokenIn != OTHER) revert WrongToken(tokenIn);
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        bool zeroForOne = tokenIn == POOL.token0();
        (int256 amount0, int256 amount1) = POOL.swap(
            recipient, zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE, ""
        );
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        // Anything the pool did not take (a price limit reached) goes back to the recipient.
        uint256 left = IERC20(tokenIn).balanceOf(address(this));
        if (left != 0) IERC20(tokenIn).safeTransfer(recipient, left);
    }

    /// @notice Pays the pool what the swap owes it, from the tokens the caller sent. Uniswap v3 and Ramses V3 pools
    /// both call back under this name: Ramses V3's pools on chain 4663 call `uniswapV3SwapCallback`.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(amount0Delta, amount1Delta);
    }

    /// @notice The same payment under another name. No pool on chain 4663 calls it: Ramses V3's pools there call back
    /// `uniswapV3SwapCallback`. It answers `POOL` alone, as that callback does.
    function ramsesV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(amount0Delta, amount1Delta);
    }

    function _pay(int256 amount0Delta, int256 amount1Delta) internal {
        if (msg.sender != address(POOL)) revert NotPool(msg.sender);
        if (amount0Delta > 0) IERC20(POOL.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(POOL.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
