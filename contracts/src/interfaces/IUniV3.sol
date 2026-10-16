// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

interface IUniV3Factory {
    function getPool(address token0, address token1, uint24 fee) external view returns (address);
}

interface IUniV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @dev The V3 pool calls `GageV2CashoutRouter` makes on its flash pool and route pools; moved verbatim from that file
/// (X-dup-07).
interface IV2FlashPool is IUniV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IUniV3PositionManager {
    struct Position {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function positions(uint256 tokenId) external view returns (Position memory);
}
