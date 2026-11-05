// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {ILPAdapter} from "../interfaces/ILPAdapter.sol";
import {LPAdapterBase} from "./LPAdapterBase.sol";
import {IFablesLedger} from "../interfaces/IFablesLedger.sol";
import {FablesPositionWrapper} from "../fables/FablesPositionWrapper.sol";
import {PositionFacts} from "../LPTypes.sol";

/// @title FablesPositionAdapter
/// @notice Fables positions, wrapped as NFTs by `FablesPositionWrapper` (Fables LPs hold receipts of a hook-owned
/// Uniswap v4 position, not position NFTs). Like the v4 adapter, a pool is named by its id's low 160 bits and a native
/// pool's ETH is read, collected and unwound as WETH. A position's liquidity is its receipts (minted 1:1 with liquidity).
/// Stateless; only its core may call it, and it acts as the operator the loan's escrow approved for that one position.
/// @dev The hook's pause stops claims and transfers but never withdrawals, so a paused hook still unwinds a defaulted
/// position; its fees then stay owed to the position until a claim is possible. Staking (Fables' emissions) is not
/// served: a wrapped position's receipts are unstaked and earn its swap fees.
contract FablesPositionAdapter is LPAdapterBase {
    using SafeERC20 for IERC20;

    /// @dev The adapter accepts whatever claim fee the hook charges: the vault takes the fees the position earned.
    uint16 internal constant ANY_CLAIM_FEE = type(uint16).max;

    FablesPositionWrapper public immutable WRAPPER;
    IFablesLedger public immutable HOOK;
    address public immutable POOL_MANAGER;
    IWETH9 public immutable WETH;

    error NotPoolManager(address sender);
    error MinimumTooLarge();

    constructor(FablesPositionWrapper wrapper, IWETH9 weth, address core_) LPAdapterBase(core_) {
        if (address(wrapper) == address(0) || address(weth) == address(0)) revert ZeroAddress();
        IFablesLedger hook = wrapper.HOOK();
        address poolManager = hook.poolManager();
        if (poolManager == address(0)) revert ZeroAddress();
        WRAPPER = wrapper;
        HOOK = hook;
        POOL_MANAGER = poolManager;
        WETH = weth;
    }

    /// @notice Only the PoolManager pays this adapter native ETH (the hook's payouts, wrapped before they leave).
    receive() external payable {
        if (msg.sender != POOL_MANAGER) revert NotPoolManager(msg.sender);
    }

    /// @inheritdoc ILPAdapter
    function positionManager() external view returns (address) {
        return address(WRAPPER);
    }

    /// @notice The lane's name for a v4 pool: the low 160 bits of its pool id.
    function poolAddress(PoolKey memory key) public pure returns (address) {
        return address(uint160(uint256(PoolId.unwrap(key.toId()))));
    }

    /// @inheritdoc ILPAdapter
    /// @dev A native pool's currency 0 reads as WETH.
    function facts(uint256 tokenId) external view returns (PositionFacts memory f) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 shares,,) = WRAPPER.position(tokenId);
        f = PositionFacts({
            pool: poolAddress(key),
            token0: key.currency0.isAddressZero() ? address(WETH) : Currency.unwrap(key.currency0),
            token1: Currency.unwrap(key.currency1),
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: shares
        });
    }

    /// @inheritdoc ILPAdapter
    function collectFees(uint256 tokenId, address recipient)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        (PoolKey memory key,,,,,) = WRAPPER.position(tokenId);
        (uint256 before0, uint256 before1) = (key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());
        WRAPPER.collectFees(tokenId, address(this), ANY_CLAIM_FEE);
        (amount0, amount1) = _forward(key, before0, before1, recipient);
    }

    /// @inheritdoc ILPAdapter
    /// @dev The minimums bind the liquidity's own amounts. The fees are claimed after the withdrawal, never blocking it.
    function unwind(uint256 tokenId, address recipient, uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyCore
        returns (uint256 amount0, uint256 amount1)
    {
        if (min0 > type(uint128).max || min1 > type(uint128).max) revert MinimumTooLarge();
        (PoolKey memory key,,, uint128 shares,,) = WRAPPER.position(tokenId);
        (uint256 before0, uint256 before1) = (key.currency0.balanceOfSelf(), key.currency1.balanceOfSelf());
        if (shares != 0) WRAPPER.withdraw(tokenId, shares, address(this), uint128(min0), uint128(min1), deadline);
        try WRAPPER.collectFees(tokenId, address(this), ANY_CLAIM_FEE) {} catch {}
        (amount0, amount1) = _forward(key, before0, before1, recipient);
    }

    /// @dev Pays `recipient` exactly what this call received, a native currency 0 wrapped as WETH.
    function _forward(PoolKey memory key, uint256 before0, uint256 before1, address recipient)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
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
