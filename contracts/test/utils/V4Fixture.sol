// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice A real Uniswap v4 deployment inside a Foundry test: PoolManager built with v4-core's own settings,
///         PositionManager and StateView built with v4-periphery's, Permit2 etched at its canonical address.
///         The same artifacts are what DeployV4Testnet.s.sol puts on the testnet.
abstract contract V4Fixture is Test {
    using PoolIdLibrary for PoolKey;

    string internal constant POOL_MANAGER_ARTIFACT =
        "lib/v4-periphery/lib/v4-core/out/PoolManager.sol/PoolManager.json";
    string internal constant POSITION_MANAGER_ARTIFACT =
        "lib/v4-periphery/foundry-out/PositionManager.sol/PositionManager.json";
    string internal constant STATE_VIEW_ARTIFACT = "lib/v4-periphery/foundry-out/StateView.sol/StateView.json";
    string internal constant PERMIT2_ARTIFACT = "lib/v4-periphery/lib/permit2/out/Permit2.sol/Permit2.json";
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    int24 internal constant TICK_SPACING = 60;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;

    IPoolManager internal poolManager;
    IPositionManager internal posm;
    address internal stateView;
    IAllowanceTransfer internal permit2;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    function _deployV4() internal {
        poolManager = IPoolManager(deployCode(POOL_MANAGER_ARTIFACT, abi.encode(address(this))));
        if (PERMIT2.code.length == 0) deployCodeTo(PERMIT2_ARTIFACT, PERMIT2);
        permit2 = IAllowanceTransfer(PERMIT2);
        posm = IPositionManager(
            deployCode(
                POSITION_MANAGER_ARTIFACT,
                abi.encode(address(poolManager), PERMIT2, uint256(300_000), address(0), address(0))
            )
        );
        stateView = deployCode(STATE_VIEW_ARTIFACT, abi.encode(address(poolManager)));
        swapRouter = new PoolSwapTest(poolManager);
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(posm), "PositionManager");
        vm.label(stateView, "StateView");
        vm.label(PERMIT2, "Permit2");
    }

    // ----------------------------------------------------------------- pools

    function _sorted(address a, address b) internal pure returns (Currency, Currency) {
        return a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
    }

    /// @dev sqrtPriceX96 such that `amount1` raw units of currency1 trade for `amount0` raw units of currency0.
    function _sqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
    }

    function _initPool(address tokenA, address tokenB, uint24 fee, int24 spacing, address hooks, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory key)
    {
        (Currency c0, Currency c1) = _sorted(tokenA, tokenB);
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: spacing, hooks: IHooks(hooks)});
        poolManager.initialize(key, sqrtPriceX96);
    }

    /// @dev A pool where `amount1Per` raw units of `tokenB` buy `amount0Per` raw units of `tokenA`, whichever sorts first.
    function _initPoolAtPrice(address tokenA, uint256 amountA, address tokenB, uint256 amountB, address hooks)
        internal
        returns (PoolKey memory key)
    {
        return _initPoolAtPriceWithFee(tokenA, amountA, tokenB, amountB, hooks, 3000);
    }

    function _initPoolAtPriceWithFee(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 amountB,
        address hooks,
        uint24 fee
    ) internal returns (PoolKey memory key) {
        (Currency c0,) = _sorted(tokenA, tokenB);
        bool aIsZero = Currency.unwrap(c0) == tokenA;
        uint160 sqrtPrice = aIsZero ? _sqrtPriceX96(amountB, amountA) : _sqrtPriceX96(amountA, amountB);
        key = _initPool(tokenA, tokenB, fee, TICK_SPACING, hooks, sqrtPrice);
    }

    function _poolId(PoolKey memory key) internal pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    // ----------------------------------------------------------------- positions

    /// @dev `payer` must call this once per token before minting.
    function _approvePosm(address payer, address token) internal {
        vm.startPrank(payer);
        IERC20(token).approve(PERMIT2, type(uint256).max);
        permit2.approve(token, address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _mint(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address recipient,
        address payer
    ) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), type(uint128).max, type(uint128).max, recipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.prank(payer);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    function _mintFullRange(PoolKey memory key, uint128 liquidity, address recipient, address payer)
        internal
        returns (uint256)
    {
        return _mint(key, FULL_LOWER, FULL_UPPER, liquidity, recipient, payer);
    }

    /// @dev Remove `liquidity` from `tokenId` and send the tokens to `recipient`.
    function _decrease(PoolKey memory key, uint256 tokenId, uint128 liquidity, address recipient, address owner)
        internal
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        vm.prank(owner);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /// @dev Liquidity added by something other than the PositionManager (no tokenId, no rewards).
    function _addRawLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity, address payer)
        internal
    {
        vm.startPrank(payer);
        IERC20(Currency.unwrap(key.currency0)).approve(address(lpRouter), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Liquidity in a native-ETH pool through the test router; `value` must cover the ETH side.
    function _addRawLiquidityNative(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity,
        address payer,
        uint256 value
    ) internal {
        vm.startPrank(payer);
        IERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: value}(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: 0}),
            ""
        );
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- swaps

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, address payer) internal {
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        vm.startPrank(payer);
        IERC20(tokenIn).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Exact-input swap paying native ETH (currency0).
    function _swapNativeIn(PoolKey memory key, uint256 amountIn, address payer) internal {
        vm.prank(payer);
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _currentTick(PoolKey memory key) internal view returns (int24 tick) {
        (, bytes memory data) =
            stateView.staticcall(abi.encodeWithSignature("getSlot0(bytes32)", PoolId.unwrap(key.toId())));
        (, tick,,) = abi.decode(data, (uint160, int24, uint24, uint24));
    }
}
