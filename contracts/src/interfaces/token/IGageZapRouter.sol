// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IReinvestRouter} from "./IReinvestRouter.sol";

/// @notice Single-asset entry into the existing GAGE/sGAGE pool.
interface IGageZapRouter is IReinvestRouter {
    event GageZapped(
        address indexed owner,
        uint256 indexed tokenId,
        uint256 gageIn,
        uint256 gageSwapped,
        uint256 sgageBought,
        uint256 liquidity
    );

    struct FundedLimits {
        uint256 minEthOut;
        uint256 minGageOut;
        uint256 gageToSwap;
        uint256 minSgageOut;
        uint128 minLiquidity;
    }

    event FundedZapped(
        address indexed owner,
        uint256 indexed tokenId,
        PayAsset inputAsset,
        uint256 amountIn,
        uint256 gageBought,
        uint256 liquidity
    );

    error InvalidNativeValue();

    /// @notice Buy GAGE with ETH or USDG, swap part for sGAGE, and mint a position. Refund all leftovers.
    function zapFunded(
        PayAsset inputAsset,
        uint256 amount,
        Range calldata range,
        FundedLimits calldata limits,
        uint256 deadline
    ) external payable returns (uint256 tokenId, uint128 liquidity);

    /// @notice The same funded route, adding to a caller-owned position in this pool.
    function increaseFundedZap(
        uint256 tokenId,
        PayAsset inputAsset,
        uint256 amount,
        FundedLimits calldata limits,
        uint256 deadline
    ) external payable returns (uint128 liquidity);

    error InvalidZapLimits();
    error AmountTooLarge();

    /// @notice Swap part of GAGE for sGAGE in GAGE/sGAGE, then mint an LP NFT to the caller; refund leftovers.
    function zapGage(
        uint256 amountGage,
        uint256 swapAmount,
        Range calldata range,
        uint256 minSgageOut,
        uint128 minLiquidity,
        uint256 deadline
    ) external returns (uint256 tokenId, uint128 liquidity);

    /// @notice Same route, increasing an existing GAGE/sGAGE NFT owned by the caller.
    function increaseGageZap(
        uint256 tokenId,
        uint256 amountGage,
        uint256 swapAmount,
        uint256 minSgageOut,
        uint128 minLiquidity,
        uint256 deadline
    ) external returns (uint128 liquidity);
}
