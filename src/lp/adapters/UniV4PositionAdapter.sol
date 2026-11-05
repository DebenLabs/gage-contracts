// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {LPAdapterBase} from "./LPAdapterBase.sol";
import {PositionFacts} from "../LPTypes.sol";

/// @title UniV4PositionAdapter
/// @notice Uniswap v4 positions held by its PositionManager. A v4 pool has no address of its own: the lane names it by
/// the low 160 bits of its pool id (`poolAddress`), the key the registry's caps and the core's books use. A native-ETH
/// pool's currency 0 is reported, collected and unwound as WETH, so the vault books and sells WETH as for every other
/// format. Stateless; only its core may call it, and it acts as the operator the loan's escrow approved for that one
/// position.
/// @dev Hookless pools only: the registry admits pools one by one and the release admits hookless ones, and `facts`
/// refuses a hooked pool's position as well. A position moved into an escrow loses its subscriber (the
/// PositionManager unsubscribes it on transfer).
contract UniV4PositionAdapter is LPAdapterBase {
    using SafeERC20 for IERC20;

    IPositionManager public immutable POSM;
    address public immutable POOL_MANAGER;
    IWETH9 public immutable WETH;

    error NotPoolManager(address sender);
    error MinimumTooLarge();
    error HookedPool(address hooks);

    constructor(IPositionManager posm, IWETH9 weth, address core_) LPAdapterBase(core_) {
        if (address(posm) == address(0) || address(weth) == address(0)) revert ZeroAddress();
        address poolManager = address(posm.poolManager());
        if (poolManager == address(0)) revert ZeroAddress();
        POSM = posm;
        POOL_MANAGER = poolManager;
        WETH = weth;
    }

    /// @notice Only the PoolManager pays this adapter native ETH (a native pool's currency 0, wrapped before it leaves).
    receive() external payable {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager(msg.sender);
    }

    /// @inheritdoc ILPAdapter
    function positionManager() external view returns (address) {
        return address(POSM);
    }

    /// @notice The lane's name for a v4 pool: the low 160 bits of its pool id.
    function poolAddress(PoolKey memory key) public pure returns (address) {
        return address(uint160(uint256(PoolId.unwrap(key.toId()))));
    }

    /// @inheritdoc ILPAdapter
    /// @dev A native pool's currency 0 reads as WETH. A hooked pool's position reverts, so no loan opens on one.
    function facts(uint256 tokenId) external view returns (PositionFacts memory f) {
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        if (address(key.hooks) != address(0)) revert HookedPool(address(key.hooks));
        f = PositionFacts({
            pool: poolAddress(key),
            token0: key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0),
            token1: Currency.unwrap(key.currency1),
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            liquidity: POSM.getPositionLiquidity(tokenId)
        });
    }

    /// @inheritdoc ILPAdapter
    /// @dev A v4 decrease of zero liquidity pays out the position's fees and nothing else.
    function collectFees(uint256 tokenId, address recipient)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _decrease(tokenId, 0, 0, 0, recipient, block.timestamp);
    }

    /// @inheritdoc ILPAdapter
    /// @dev The minimums bind the liquidity's own amounts; the fees come on top. An empty position pays nothing (v4
    /// refuses to touch a position with no liquidity, and its fees were paid out when its liquidity left).
    function unwind(uint256 tokenId, address recipient, uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        if (min0 > type(uint128).max || min1 > type(uint128).max) revert MinimumTooLarge();
        uint128 liquidity = POSM.getPositionLiquidity(tokenId);
        if (liquidity == 0) return (0, 0);
        (amount0, amount1) = _decrease(tokenId, liquidity, uint128(min0), uint128(min1), recipient, deadline);
    }

    /// @dev Removes `liquidity` (zero collects the fees only), takes both currencies here, wraps native ETH, and pays
    /// `recipient` exactly what this call received.
    function _decrease(
        uint256 tokenId,
        uint256 liquidity,
        uint128 min0,
        uint128 min1,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1) {
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(tokenId);
        uint256 before0 = key.currency0.balanceOfSelf();
        uint256 before1 = key.currency1.balanceOfSelf();

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, min0, min1, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params), deadline
        );

        amount0 = key.currency0.balanceOfSelf() - before0;
        amount1 = key.currency1.balanceOfSelf() - before1;
        if (amount0 != 0) {
            if (key.currency0.isAddressZero()) {
                WETH.deposit{value: amount0}();
                IERC20(address(WETH)).safeTransfer(recipient, amount0);
            } else {
                IERC20(Currency.unwrap(key.currency0)).safeTransfer(recipient, amount0);
            }
        }
        if (amount1 != 0) IERC20(Currency.unwrap(key.currency1)).safeTransfer(recipient, amount1);
    }
}
