// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUniV3Pool, IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The canonical v3 factory and pool calls a suite makes to build its pools.
interface ILocalV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface ILocalV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @notice Real Uniswap v3 pools inside a Foundry test: the canonical factory from the bytecode v4-core's own v3/v4
/// differential tests deploy (as `GageV2CashoutRoutes.t.sol` does), and pools of mock tokens priced and filled over
/// their full range.
abstract contract LocalV3 is Test {
    string internal constant V3_FACTORY_BYTECODE = "lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode";

    address internal v3Factory;

    function _deployV3Factory() internal {
        bytes memory code = vm.readFileBinary(V3_FACTORY_BYTECODE);
        address factory;
        assembly ("memory-safe") {
            factory := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(factory != address(0), "v3 factory");
        v3Factory = factory;
    }

    /// @dev A pool of two mock tokens holding about `amountA` of `tokenA` and `amountB` of `tokenB` over its full range:
    /// one raw unit of `tokenA` starts worth `amountB / amountA` raw units of `tokenB`.
    function _v3Pool(address tokenA, uint256 amountA, address tokenB, uint256 amountB, uint24 fee)
        internal
        returns (address pool)
    {
        pool = ILocalV3Factory(v3Factory).createPool(tokenA, tokenB, fee);
        (uint256 amount0, uint256 amount1) = tokenA < tokenB ? (amountA, amountB) : (amountB, amountA);
        ILocalV3Pool(pool).initialize(uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0))));
        int24 spacing = IUniV3Pool(pool).tickSpacing();
        int24 top = TickMath.MAX_TICK / spacing * spacing;
        ILocalV3Pool(pool).mint(address(this), -top, top, uint128(Math.sqrt(amount0 * amount1)), "");
    }

    /// @dev A mock token at a chosen address, so a suite can fix which token a pool orders first.
    function _tokenAt(address at, string memory symbol, uint8 decimals) internal returns (MockERC20) {
        MockERC20 made = new MockERC20(symbol, symbol, decimals);
        vm.etch(at, address(made).code);
        vm.copyStorage(address(made), at);
        vm.label(at, symbol);
        return MockERC20(at);
    }

    /// @dev What selling `amountIn` of `tokenIn` on `pool` returns now: the sale is made and undone.
    function _quoteExactIn(address pool, address tokenIn, uint256 amountIn) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        bool zeroForOne = IUniV3Pool(pool).token0() == tokenIn;
        (int256 amount0, int256 amount1) = IV2FlashPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                ""
            );
        out = uint256(-(zeroForOne ? amount1 : amount0));
        vm.revertToState(snapshot);
    }

    /// @notice Pays a v3 mint made by this suite: the owed mock tokens are minted to the pool.
    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        if (owed0 != 0) MockERC20(IUniV3Pool(msg.sender).token0()).mint(msg.sender, owed0);
        if (owed1 != 0) MockERC20(IUniV3Pool(msg.sender).token1()).mint(msg.sender, owed1);
    }

    /// @notice Pays a v3 swap made by this suite: the owed mock token is minted to the pool.
    function uniswapV3SwapCallback(int256 delta0, int256 delta1, bytes calldata) external {
        if (delta0 > 0) MockERC20(IUniV3Pool(msg.sender).token0()).mint(msg.sender, uint256(delta0));
        if (delta1 > 0) MockERC20(IUniV3Pool(msg.sender).token1()).mint(msg.sender, uint256(delta1));
    }
}
