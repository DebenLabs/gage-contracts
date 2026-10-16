// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

interface IFlashCallback {
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

/// @title TestnetFlashPool
/// @notice The cash-out financing source for a labeled gage testnet: a USDG/WETH pot that lends its whole
///         balance for the length of one call and takes a fee, the way the V2 cash-out router expects a Uniswap
///         v3 pool to behave. It is a lending pot, not an AMM: `swap` always reverts and no price is quoted.
/// @dev NEVER deploy this on chain 4663, which finances cash-outs from a canonical v3 pool. Anyone may fund it
///      by transferring tokens in; on testnet the coordinator seeds it. Fees stay in the pot.
contract TestnetFlashPool is ReentrancyGuardTransient, TestnetOnly {
    using SafeERC20 for IERC20;

    /// @notice Marks this as a testnet stand-in, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: not Uniswap";

    /// @notice Hundredths of a bip, the Uniswap v3 fee unit. 500 is 0.05%.
    uint24 public constant FEE = 500;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;

    address public immutable FACTORY;
    address private immutable _TOKEN0;
    address private immutable _TOKEN1;

    error InsufficientRepayment();
    error NotAnAmm();
    error SameToken();

    event Flash(address indexed caller, address indexed recipient, uint256 amount0, uint256 amount1);

    constructor(address factory_, address tokenA, address tokenB) {
        if (tokenA == tokenB) revert SameToken();
        (_TOKEN0, _TOKEN1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        FACTORY = factory_;
    }

    /// @notice The testnet factory that registers this pool, so identity checks resolve.
    function factory() external view returns (address) {
        return FACTORY;
    }

    /// @notice The lower-sorted token of the pair.
    function token0() external view returns (address) {
        return _TOKEN0;
    }

    /// @notice The higher-sorted token of the pair.
    function token1() external view returns (address) {
        return _TOKEN1;
    }

    /// @notice The financing fee charged on a flash loan, in hundredths of a bip.
    function fee() external pure returns (uint24) {
        return FEE;
    }

    /// @notice Reported for interface parity; this pot has no ticks.
    function tickSpacing() external pure returns (int24) {
        return 10;
    }

    /// @notice How much of each token this pot can lend right now.
    function liquidity() external view returns (uint128) {
        uint256 balance0 = IERC20(_TOKEN0).balanceOf(address(this));
        uint256 balance1 = IERC20(_TOKEN1).balanceOf(address(this));
        uint256 smaller = balance0 < balance1 ? balance0 : balance1;
        return smaller > type(uint128).max ? type(uint128).max : uint128(smaller);
    }

    /// @notice Reported for interface parity; this pot quotes no price, so nothing reads these fields.
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, 0, 0, 0, true);
    }

    /// @notice Lend both amounts to `recipient` for the length of the callback, then require them back with fees.
    /// @dev Fees round up, as a v3 pool's do, so a repayment is never short by a rounding unit.
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external nonReentrant {
        uint256 fee0 = _feeOn(amount0);
        uint256 fee1 = _feeOn(amount1);
        uint256 before0 = IERC20(_TOKEN0).balanceOf(address(this));
        uint256 before1 = IERC20(_TOKEN1).balanceOf(address(this));
        if (amount0 != 0) IERC20(_TOKEN0).safeTransfer(recipient, amount0);
        if (amount1 != 0) IERC20(_TOKEN1).safeTransfer(recipient, amount1);
        IFlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);
        if (IERC20(_TOKEN0).balanceOf(address(this)) < before0 + fee0) revert InsufficientRepayment();
        if (IERC20(_TOKEN1).balanceOf(address(this)) < before1 + fee1) revert InsufficientRepayment();
        emit Flash(msg.sender, recipient, amount0, amount1);
    }

    /// @notice Always reverts: the cash-out router must never route a swap through its own financing source.
    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert NotAnAmm();
    }

    function _feeOn(uint256 amount) private pure returns (uint256) {
        return amount == 0 ? 0 : (amount * FEE + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
    }
}
