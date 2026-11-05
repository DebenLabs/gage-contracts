// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILPSwapExecutor} from "../interfaces/ILPSwapExecutor.sol";
import {IUniV3Pool} from "../interfaces/IConcentratedLiquidity.sol";

/// @title UniV3TwoHopSwapExecutor
/// @notice Sells a token that has no USDG pool (RAM on chain 4663) for USDG through two Uniswap-v3-style pools: the
/// token for a middle token in the first, the middle token for USDG in the second. Either pool may be Uniswap v3 or
/// Ramses V3. It holds tokens only inside the call that sold them; the caller (a vault) enforces its own minimum on
/// what arrives and measures what it actually sold.
contract UniV3TwoHopSwapExecutor is ILPSwapExecutor {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    /// @notice The pool selling `TOKEN_IN` for `MID`.
    IUniV3Pool public immutable FIRST;
    /// @notice The pool selling `MID` for USDG.
    IUniV3Pool public immutable SECOND;
    address public immutable USDG;
    address public immutable MID;
    address public immutable TOKEN_IN;

    error WrongToken(address token);
    error NotPool(address caller);
    error AmountTooLarge();
    error SecondHopIncomplete(uint256 left);

    constructor(IUniV3Pool first, IUniV3Pool second, address usdg) {
        address s0 = second.token0();
        address s1 = second.token1();
        if (s0 != usdg && s1 != usdg) revert WrongToken(usdg);
        address mid = s0 == usdg ? s1 : s0;
        address f0 = first.token0();
        address f1 = first.token1();
        if (f0 != mid && f1 != mid) revert WrongToken(mid);
        address tokenIn = f0 == mid ? f1 : f0;
        if (tokenIn == usdg) revert WrongToken(tokenIn);
        FIRST = first;
        SECOND = second;
        USDG = usdg;
        MID = mid;
        TOKEN_IN = tokenIn;
    }

    /// @inheritdoc ILPSwapExecutor
    /// @dev Whatever the first pool does not take goes back to the recipient; the second pool must take every middle
    /// token the first paid, or the sale fails, so the vault never receives a token it did not book. A dust sale whose
    /// first hop pays nothing skips the second (its pool refuses a zero swap) and returns no USDG: the vault's own
    /// minimum decides whether that is acceptable, so a lot too small to sell can still be cleared.
    function swap(address tokenIn, uint256 amountIn, address recipient) external returns (uint256 amountOut) {
        if (tokenIn != TOKEN_IN) revert WrongToken(tokenIn);
        if (amountIn > uint256(type(int256).max)) revert AmountTooLarge();
        uint256 midBefore = IERC20(MID).balanceOf(address(this));

        bool firstZeroForOne = TOKEN_IN == FIRST.token0();
        (int256 f0, int256 f1) = FIRST.swap(
            address(this),
            firstZeroForOne,
            int256(amountIn),
            firstZeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            ""
        );
        uint256 mid = uint256(-(firstZeroForOne ? f1 : f0));

        if (mid != 0) {
            bool secondZeroForOne = MID == SECOND.token0();
            (int256 s0, int256 s1) = SECOND.swap(
                recipient,
                secondZeroForOne,
                int256(mid),
                secondZeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                ""
            );
            amountOut = uint256(-(secondZeroForOne ? s1 : s0));
        }

        uint256 midAfter = IERC20(MID).balanceOf(address(this));
        if (midAfter > midBefore) revert SecondHopIncomplete(midAfter - midBefore);
        uint256 left = IERC20(TOKEN_IN).balanceOf(address(this));
        if (left != 0) IERC20(TOKEN_IN).safeTransfer(recipient, left);
    }

    /// @notice Pays either pool what its swap owes it. Uniswap v3 and Ramses V3 pools both call back under this name:
    /// Ramses V3's pools on chain 4663 call `uniswapV3SwapCallback`.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(amount0Delta, amount1Delta);
    }

    /// @notice The same payment under another name. No pool on chain 4663 calls it: Ramses V3's pools there call back
    /// `uniswapV3SwapCallback`. It answers `FIRST` and `SECOND` alone, as that callback does.
    function ramsesV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _pay(amount0Delta, amount1Delta);
    }

    function _pay(int256 amount0Delta, int256 amount1Delta) internal {
        if (msg.sender != address(FIRST) && msg.sender != address(SECOND)) revert NotPool(msg.sender);
        IUniV3Pool pool = IUniV3Pool(msg.sender);
        if (amount0Delta > 0) IERC20(pool.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
