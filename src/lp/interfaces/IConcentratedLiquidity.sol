// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice The parameter structs Uniswap v3's position manager and its forks share.
interface IPositionManagerParams {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
}

/// @notice Uniswap v3's NonfungiblePositionManager (and forks that keep its 12-field `positions`).
interface IUniV3PositionManager is IPositionManagerParams {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

/// @notice Uniswap v3's factory: pools keyed by fee.
interface IUniV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice Ramses V3's position manager: a 10-field `positions` keyed by tick spacing, plus gauge rewards.
interface IRamsesV3PositionManager is IPositionManagerParams {
    function positions(uint256 tokenId)
        external
        view
        returns (
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @dev Pays the position's owner; callable by the owner or an approved operator.
    function getReward(uint256 tokenId, address[] calldata tokens) external payable;

    /// @dev When the position's liquidity last changed (a unix timestamp).
    function positionLastModified(uint256 tokenId) external view returns (uint256);
}

/// @notice Ramses V3's factory: pools keyed by tick spacing.
interface IRamsesV3Factory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @notice The swap surface of a Uniswap v3 pool (and its forks).
interface IUniV3Pool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
