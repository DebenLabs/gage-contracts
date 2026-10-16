// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGageZapRouter} from "../interfaces/token/IGageZapRouter.sol";
import {ReinvestRouter} from "./ReinvestRouter.sol";

/// @notice Adds GAGE input to the stateless reinvest router. Existing sGAGE entry points remain compatible.
///         GAGE zaps swap exclusively in GAGE/sGAGE, then mint/increase with the same pool and hook.
contract GageZapRouter is ReinvestRouter, IGageZapRouter {
    using SafeERC20 for IERC20;

    constructor(Params memory p) ReinvestRouter(p) {}

    /// @inheritdoc IGageZapRouter
    function zapGage(
        uint256 amountGage,
        uint256 swapAmount,
        Range calldata range,
        uint256 minSgageOut,
        uint128 minLiquidity,
        uint256 deadline
    ) external nonReentrant returns (uint256 tokenId, uint128 liquidity) {
        _checkDeadline(deadline);
        uint256 sgageBought = _pullGageAndSwap(amountGage, swapAmount, minSgageOut, minLiquidity);
        tokenId = POSM.nextTokenId();
        liquidity = _mint(range.tickLower, range.tickUpper, minLiquidity);
        _refundAll();
        emit GageZapped(msg.sender, tokenId, amountGage, swapAmount, sgageBought, liquidity);
    }

    /// @inheritdoc IGageZapRouter
    function increaseGageZap(
        uint256 tokenId,
        uint256 amountGage,
        uint256 swapAmount,
        uint256 minSgageOut,
        uint128 minLiquidity,
        uint256 deadline
    ) external nonReentrant returns (uint128 liquidity) {
        _checkDeadline(deadline);
        (int24 lower, int24 upper) = _ownedRange(tokenId);
        uint256 sgageBought = _pullGageAndSwap(amountGage, swapAmount, minSgageOut, minLiquidity);
        liquidity = _increase(tokenId, lower, upper, minLiquidity);
        _refundAll();
        emit GageZapped(msg.sender, tokenId, amountGage, swapAmount, sgageBought, liquidity);
    }

    function zapFunded(
        PayAsset inputAsset,
        uint256 amount,
        Range calldata range,
        FundedLimits calldata limits,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 tokenId, uint128 liquidity) {
        _checkDeadline(deadline);
        uint256 bought = _fundAndSwap(inputAsset, amount, limits);
        tokenId = POSM.nextTokenId();
        liquidity = _mint(range.tickLower, range.tickUpper, limits.minLiquidity);
        _refundAll();
        emit FundedZapped(msg.sender, tokenId, inputAsset, amount, bought, liquidity);
    }

    function increaseFundedZap(
        uint256 tokenId,
        PayAsset inputAsset,
        uint256 amount,
        FundedLimits calldata limits,
        uint256 deadline
    ) external payable nonReentrant returns (uint128 liquidity) {
        _checkDeadline(deadline);
        (int24 lower, int24 upper) = _ownedRange(tokenId);
        uint256 bought = _fundAndSwap(inputAsset, amount, limits);
        liquidity = _increase(tokenId, lower, upper, limits.minLiquidity);
        _refundAll();
        emit FundedZapped(msg.sender, tokenId, inputAsset, amount, bought, liquidity);
    }

    function _fundAndSwap(PayAsset inputAsset, uint256 amount, FundedLimits calldata limits)
        internal
        returns (uint256 bought)
    {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint128).max) revert AmountTooLarge();
        if (
            limits.gageToSwap == 0 || limits.minGageOut <= limits.gageToSwap || limits.minSgageOut == 0
                || limits.minLiquidity == 0
        ) revert InvalidZapLimits();
        uint256 ethIn;
        if (inputAsset == PayAsset.ETH) {
            if (msg.value != amount) revert InvalidNativeValue();
            ethIn = amount;
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            if (limits.minEthOut == 0) revert InvalidZapLimits();
            USDG.safeTransferFrom(msg.sender, address(this), amount);
            ethIn = _swapExactIn(_usdgEth, false, amount, limits.minEthOut);
        }
        bought = _swapExactIn(_gageEth, true, ethIn, limits.minGageOut);
        if (bought > type(uint128).max) revert AmountTooLarge();
        _swapExactIn(_gageSgage, !SGAGE_IS_CURRENCY0, limits.gageToSwap, limits.minSgageOut);
        (uint256 amount0, uint256 amount1) = _held();
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert AmountTooLarge();
    }

    function _pullGageAndSwap(uint256 amount, uint256 swapAmount, uint256 minOut, uint128 minLiquidity)
        internal
        returns (uint256 bought)
    {
        if (amount == 0) revert ZeroAmount();
        if (swapAmount == 0 || swapAmount >= amount || minOut == 0 || minLiquidity == 0) revert InvalidZapLimits();
        if (amount > type(uint128).max) revert AmountTooLarge();
        GAGE.safeTransferFrom(msg.sender, address(this), amount);
        bought = _swapExactIn(_gageSgage, !SGAGE_IS_CURRENCY0, swapAmount, minOut);
        (uint256 amount0, uint256 amount1) = _held();
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert AmountTooLarge();
    }
}
