// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Swapper} from "./base/V4Swapper.sol";
import {IReinvestRouter} from "../interfaces/token/IReinvestRouter.sol";

/// @title ReinvestRouter
/// @notice Stateless. Unlocked sGAGE → a GAGE/sGAGE position in the caller's wallet in one transaction. Match buys
///         the GAGE the range needs with ETH or USDG from the caller; zap sells part of the sGAGE. Both mint (or
///         increase) through the PositionManager with the caller as recipient, refund every leftover, and end with
///         the router holding nothing (T8). The front end quotes; this contract enforces the limits it is given.
contract ReinvestRouter is IReinvestRouter, V4Swapper, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    IERC20 public immutable SGAGE;
    IERC20 public immutable GAGE;
    IERC20 public immutable USDG;
    bool public immutable SGAGE_IS_CURRENCY0;

    PoolKey internal _gageSgage;
    PoolKey internal _gageEth;
    PoolKey internal _usdgEth;

    error Expired();
    error PoolMismatch();
    error RangeHoldsNoSGAGE();
    error SellExceedsAmount();

    struct Params {
        IPoolManager poolManager;
        IPositionManager posm;
        IAllowanceTransfer permit2;
        IERC20 sgage;
        IERC20 gage;
        IERC20 usdg;
        PoolKey gageSgage;
        PoolKey gageEth;
        PoolKey usdgEth;
    }

    constructor(Params memory p) V4Swapper(p.poolManager) {
        address c0 = Currency.unwrap(p.gageSgage.currency0);
        address c1 = Currency.unwrap(p.gageSgage.currency1);
        if (c0 == address(p.sgage) && c1 == address(p.gage)) SGAGE_IS_CURRENCY0 = true;
        else if (c1 == address(p.sgage) && c0 == address(p.gage)) SGAGE_IS_CURRENCY0 = false;
        else revert PoolMismatch();
        if (!p.gageEth.currency0.isAddressZero() || Currency.unwrap(p.gageEth.currency1) != address(p.gage)) {
            revert PoolMismatch();
        }
        if (!p.usdgEth.currency0.isAddressZero() || Currency.unwrap(p.usdgEth.currency1) != address(p.usdg)) {
            revert PoolMismatch();
        }
        POSM = p.posm;
        PERMIT2 = p.permit2;
        SGAGE = p.sgage;
        GAGE = p.gage;
        USDG = p.usdg;
        _gageSgage = p.gageSgage;
        _gageEth = p.gageEth;
        _usdgEth = p.usdgEth;
        // The PositionManager pulls from this contract through Permit2.
        p.sgage.forceApprove(address(p.permit2), type(uint256).max);
        p.gage.forceApprove(address(p.permit2), type(uint256).max);
        p.permit2.approve(address(p.sgage), address(p.posm), type(uint160).max, type(uint48).max);
        p.permit2.approve(address(p.gage), address(p.posm), type(uint160).max, type(uint48).max);
    }

    // ----------------------------------------------------------------- match

    /// @inheritdoc IReinvestRouter
    function reinvestMatch(
        uint256 amountSGAGE,
        Range calldata range,
        PayAsset payAsset,
        uint256 maxPay,
        uint128 minLiquidity,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 tokenId, uint128 liquidity) {
        _checkDeadline(deadline);
        if (amountSGAGE == 0) revert ZeroAmount();
        SGAGE.safeTransferFrom(msg.sender, address(this), amountSGAGE);
        uint256 gageBought = _buyGageToPair(amountSGAGE, range.tickLower, range.tickUpper, payAsset, maxPay);
        tokenId = POSM.nextTokenId();
        liquidity = _mint(range.tickLower, range.tickUpper, minLiquidity);
        _refundAll();
        emit Reinvested(msg.sender, tokenId, false, amountSGAGE, 0, gageBought, liquidity);
    }

    /// @inheritdoc IReinvestRouter
    function increaseMatch(
        uint256 tokenId,
        uint256 amountSGAGE,
        PayAsset payAsset,
        uint256 maxPay,
        uint128 minLiquidity,
        uint256 deadline
    ) external payable nonReentrant returns (uint128 liquidity) {
        _checkDeadline(deadline);
        if (amountSGAGE == 0) revert ZeroAmount();
        (int24 lower, int24 upper) = _ownedRange(tokenId);
        SGAGE.safeTransferFrom(msg.sender, address(this), amountSGAGE);
        uint256 gageBought = _buyGageToPair(amountSGAGE, lower, upper, payAsset, maxPay);
        liquidity = _increase(tokenId, lower, upper, minLiquidity);
        _refundAll();
        emit Reinvested(msg.sender, tokenId, false, amountSGAGE, 0, gageBought, liquidity);
    }

    // ----------------------------------------------------------------- zap

    /// @inheritdoc IReinvestRouter
    function reinvestZap(
        uint256 amountSGAGE,
        uint256 sellAmount,
        Range calldata range,
        uint256 maxSold,
        uint128 minLiquidity,
        uint256 deadline
    ) external nonReentrant returns (uint256 tokenId, uint128 liquidity) {
        _checkDeadline(deadline);
        uint256 gageBought = _pullAndSell(amountSGAGE, sellAmount, maxSold);
        tokenId = POSM.nextTokenId();
        liquidity = _mint(range.tickLower, range.tickUpper, minLiquidity);
        _refundAll();
        emit Reinvested(msg.sender, tokenId, true, amountSGAGE, sellAmount, gageBought, liquidity);
    }

    /// @inheritdoc IReinvestRouter
    function increaseZap(
        uint256 tokenId,
        uint256 amountSGAGE,
        uint256 sellAmount,
        uint256 maxSold,
        uint128 minLiquidity,
        uint256 deadline
    ) external nonReentrant returns (uint128 liquidity) {
        _checkDeadline(deadline);
        (int24 lower, int24 upper) = _ownedRange(tokenId);
        uint256 gageBought = _pullAndSell(amountSGAGE, sellAmount, maxSold);
        liquidity = _increase(tokenId, lower, upper, minLiquidity);
        _refundAll();
        emit Reinvested(msg.sender, tokenId, true, amountSGAGE, sellAmount, gageBought, liquidity);
    }

    // ----------------------------------------------------------------- internals

    /// @dev Buy exactly the GAGE that pairs `amountSGAGE` for the range at the current price, with `payAsset`.
    function _buyGageToPair(uint256 amountSGAGE, int24 lower, int24 upper, PayAsset payAsset, uint256 maxPay)
        internal
        returns (uint256 gageNeeded)
    {
        gageNeeded = _gageToPair(amountSGAGE, lower, upper);
        if (gageNeeded == 0) return 0;
        if (payAsset == PayAsset.ETH) {
            if (msg.value < maxPay) revert SlippageExceeded(msg.value, maxPay);
            _swapExactOut(_gageEth, true, gageNeeded, maxPay);
        } else {
            USDG.safeTransferFrom(msg.sender, address(this), maxPay);
            // GAGE needed → ETH needed (exact out on the launch pool) → USDG paid (exact out on the USDG pool)
            uint256 ethNeeded = _ethForGage(gageNeeded);
            uint256 usdgPaid = _swapExactOut(_usdgEth, false, ethNeeded, maxPay);
            _swapExactOut(_gageEth, true, gageNeeded, ethNeeded);
            if (usdgPaid > maxPay) revert SlippageExceeded(usdgPaid, maxPay);
        }
    }

    function _pullAndSell(uint256 amountSGAGE, uint256 sellAmount, uint256 maxSold)
        internal
        returns (uint256 gageBought)
    {
        if (amountSGAGE == 0) revert ZeroAmount();
        if (sellAmount > amountSGAGE) revert SellExceedsAmount();
        if (sellAmount > maxSold) revert SlippageExceeded(sellAmount, maxSold);
        SGAGE.safeTransferFrom(msg.sender, address(this), amountSGAGE);
        if (sellAmount > 0) gageBought = _swapExactIn(_gageSgage, SGAGE_IS_CURRENCY0, sellAmount, 0);
    }

    /// @dev Liquidity that pairs everything the router holds; mint it to the caller.
    function _mint(int24 lower, int24 upper, uint128 minLiquidity) internal returns (uint128 liquidity) {
        (uint256 amount0, uint256 amount1) = _held();
        liquidity = _liquidityFor(lower, upper, amount0, amount1);
        if (liquidity < minLiquidity) revert SlippageExceeded(liquidity, minLiquidity);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _gageSgage, lower, upper, uint256(liquidity), uint128(amount0), uint128(amount1), msg.sender, bytes("")
        );
        params[1] = abi.encode(_gageSgage.currency0, _gageSgage.currency1);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _increase(uint256 tokenId, int24 lower, int24 upper, uint128 minLiquidity)
        internal
        returns (uint128 liquidity)
    {
        (uint256 amount0, uint256 amount1) = _held();
        liquidity = _liquidityFor(lower, upper, amount0, amount1);
        if (liquidity < minLiquidity) revert SlippageExceeded(liquidity, minLiquidity);
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(amount0), uint128(amount1), bytes(""));
        params[1] = abi.encode(_gageSgage.currency0, _gageSgage.currency1);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _held() internal view returns (uint256 amount0, uint256 amount1) {
        uint256 s = SGAGE.balanceOf(address(this));
        uint256 g = GAGE.balanceOf(address(this));
        return SGAGE_IS_CURRENCY0 ? (s, g) : (g, s);
    }

    function _liquidityFor(int24 lower, int24 upper, uint256 amount0, uint256 amount1) internal view returns (uint128) {
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(_gageSgage.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
    }

    /// @dev GAGE that pairs `amountSGAGE` for the range at the current price, plus one wei for rounding.
    function _gageToPair(uint256 amountSGAGE, int24 lower, int24 upper) internal view returns (uint256) {
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(_gageSgage.toId());
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity;
        if (SGAGE_IS_CURRENCY0) {
            // currency0 is held only while the price is below the upper bound
            if (sqrtP < sqrtU) {
                liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtP > sqrtL ? sqrtP : sqrtL, sqrtU, amountSGAGE);
            }
        } else {
            // currency1 is held only while the price is above the lower bound
            if (sqrtP > sqrtL) {
                liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtP < sqrtU ? sqrtP : sqrtU, amountSGAGE);
            }
        }
        if (liquidity == 0) revert RangeHoldsNoSGAGE();
        // amounts for that liquidity, rounded up as the PositionManager will
        uint256 g;
        if (SGAGE_IS_CURRENCY0) {
            g = sqrtP <= sqrtL ? 0 : _amount1(sqrtL, sqrtP < sqrtU ? sqrtP : sqrtU, liquidity);
        } else {
            g = sqrtP >= sqrtU ? 0 : _amount0(sqrtP > sqrtL ? sqrtP : sqrtL, sqrtU, liquidity);
        }
        return g == 0 ? 0 : g + 1;
    }

    function _ethForGage(uint256 gageOut) internal view returns (uint256 ethIn) {
        // spot quote plus the fee and a 2% cushion; the exact-out swap itself enforces the true amount.
        uint256 spot = _quoteAtSpot(_gageEth, false, gageOut, 0, 0);
        ethIn = (spot * 10_200) / 10_000;
    }

    function _ownedRange(uint256 tokenId) internal view returns (int24 lower, int24 upper) {
        if (IERC721(address(POSM)).ownerOf(tokenId) != msg.sender) revert NotPositionOwner(tokenId);
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_gageSgage.toId())) revert PoolMismatch();
        return (info.tickLower(), info.tickUpper());
    }

    function _refundAll() internal {
        uint256 s = SGAGE.balanceOf(address(this));
        if (s > 0) SGAGE.safeTransfer(msg.sender, s);
        uint256 g = GAGE.balanceOf(address(this));
        if (g > 0) GAGE.safeTransfer(msg.sender, g);
        uint256 u = USDG.balanceOf(address(this));
        if (u > 0) USDG.safeTransfer(msg.sender, u);
        uint256 e = address(this).balance;
        if (e > 0) {
            (bool ok,) = msg.sender.call{value: e}("");
            if (!ok) revert NothingToRefund();
        }
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
    }

    // amounts the PositionManager will charge for `liquidity` between two sqrt prices, rounded up
    function _amount0(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        return SqrtPriceMathLib.amount0RoundUp(sqrtA, sqrtB, liquidity);
    }

    function _amount1(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        return SqrtPriceMathLib.amount1RoundUp(sqrtA, sqrtB, liquidity);
    }
}

import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

library SqrtPriceMathLib {
    function amount0RoundUp(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(a, b, l, true);
    }

    function amount1RoundUp(uint160 a, uint160 b, uint128 l) internal pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(a, b, l, true);
    }
}
