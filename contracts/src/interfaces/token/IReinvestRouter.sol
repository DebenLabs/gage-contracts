// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IV4SwapperErrors} from "./IV4SwapperErrors.sol";

/// @title IReinvestRouter
/// @notice Stateless. Turns unlocked sGAGE into a GAGE/sGAGE position in the caller's wallet in one transaction.
///         Match buys the GAGE needed with ETH or USDG from the wallet; zap sells part of the sGAGE. Both refund dust
///         and end with the router holding nothing (T8).
interface IReinvestRouter is IV4SwapperErrors {
    enum PayAsset {
        ETH,
        USDG
    }

    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    event Reinvested(
        address indexed owner,
        uint256 indexed tokenId,
        bool zap,
        uint256 sgageIn,
        uint256 sgageSold,
        uint256 gageBought,
        uint256 liquidity
    );

    error SlippageExceeded(uint256 got, uint256 limit);
    error NothingToRefund();
    error ZeroAmount();
    error NotPositionOwner(uint256 tokenId);

    /// @notice Buy exactly the GAGE needed for `range` at the pool price, paying with `payAsset` (ETH sent as value,
    ///         or USDG pulled), then mint a position to the caller.
    function reinvestMatch(
        uint256 amountSGAGE,
        Range calldata range,
        PayAsset payAsset,
        uint256 maxPay,
        uint128 minLiquidity,
        uint256 deadline
    ) external payable returns (uint256 tokenId, uint128 liquidity);

    /// @notice Sell `sellAmount` of the sGAGE for GAGE so the remainder pairs for `range`, then mint to the caller.
    function reinvestZap(
        uint256 amountSGAGE,
        uint256 sellAmount,
        Range calldata range,
        uint256 maxSold,
        uint128 minLiquidity,
        uint256 deadline
    ) external returns (uint256 tokenId, uint128 liquidity);

    /// @notice Same as reinvestMatch but adds to `tokenId`, which the caller must own. Keeps its score history.
    function increaseMatch(
        uint256 tokenId,
        uint256 amountSGAGE,
        PayAsset payAsset,
        uint256 maxPay,
        uint128 minLiquidity,
        uint256 deadline
    ) external payable returns (uint128 liquidity);

    function increaseZap(
        uint256 tokenId,
        uint256 amountSGAGE,
        uint256 sellAmount,
        uint256 maxSold,
        uint128 minLiquidity,
        uint256 deadline
    ) external returns (uint128 liquidity);
}
