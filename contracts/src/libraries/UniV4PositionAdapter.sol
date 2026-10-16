// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ISubscriber} from "@uniswap/v4-periphery/src/interfaces/ISubscriber.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {ICollateralRegistry, PairAsset, Lane} from "../interfaces/ICollateralRegistry.sol";

/// @title UniV4PositionAdapter
/// @notice Uniswap v4 PositionManager NFTs as collateral (spec 7.2). Compiled into DealVault as an internal library
///         behind `Kind.UNIV4_POSITION`. Rejects the position unless every one of the six checks passes (spec I9),
///         then pulls it with `safeTransferFrom`; DealVault's `onERC721Received` accepts it only during that call.
/// @dev Never accept positions in Pons-graduated pools: the pool allowlist is the guard, not the hook-bit check.
///      While escrowed nobody modifies liquidity or collects fees; fees stay in the position and follow the NFT.
library UniV4PositionAdapter {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using StateLibrary for IPoolManager;

    /// @dev A hook with any of these bits could block or alter removal and hand a lender a position they cannot
    ///      unwind. Bits 9, 8 and 0 in the deployed v4-core layout (verified against lib/v4-core/src/libraries/Hooks.sol).
    uint160 internal constant REMOVE_LIQUIDITY_FLAGS = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    error NotPositionOwner(uint256 tokenId, address owner, address from);
    error PoolNotAllowed(bytes32 poolId);
    error PairNotAllowed(address currency0, address currency1);
    error HookCanBlockRemoval(address hooks);
    error LiquidityBelowMinimum(uint256 tokenId, uint128 liquidity, uint128 minLiquidity);
    error OutOfRange(uint256 tokenId, int24 tick, int24 tickLower, int24 tickUpper);
    error HasSubscriber(uint256 tokenId, address subscriber);

    struct Checked {
        bytes32 poolId;
        address stockToken;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice The six checks of spec 7.2, in order. Reverts on the first failure.
    function validate(IPositionManager posm, ICollateralRegistry registry, address usdg, address from, uint256 tokenId)
        internal
        view
        returns (Checked memory c)
    {
        // 1. `from` owns the token on the configured PositionManager (the caller passes the configured manager).
        address owner = IERC721(address(posm)).ownerOf(tokenId);
        if (owner != from) revert NotPositionOwner(tokenId, owner, from);

        // 2. Exact pool allowlisted; stock/USDG or independently allowlisted meme/stock, in either order.
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
        c.poolId = PoolId.unwrap(key.toId());
        ICollateralRegistry.PoolConfig memory pool = registry.getPoolConfig(c.poolId);
        if (!pool.allowed) revert PoolNotAllowed(c.poolId);
        c.stockToken = _checkPair(registry, usdg, key);
        _checkHook(registry, c.poolId, address(key.hooks));

        // 4. Liquidity above the pool's minimum, and never zero.
        c.liquidity = posm.getPositionLiquidity(tokenId);
        if (c.liquidity == 0 || c.liquidity <= pool.minLiquidity) {
            revert LiquidityBelowMinimum(tokenId, c.liquidity, pool.minLiquidity);
        }

        // 5. In range at deposit, behind the registry flag. The only price read in the deal path.
        c.tickLower = info.tickLower();
        c.tickUpper = info.tickUpper();
        if (registry.inRangeRequired()) {
            (, int24 tick,,) = posm.poolManager().getSlot0(PoolId.wrap(c.poolId));
            if (tick < c.tickLower || tick >= c.tickUpper) revert OutOfRange(tokenId, tick, c.tickLower, c.tickUpper);
        }

        // 6. No active subscriber, so no third-party callback can interfere with custody.
        ISubscriber sub = posm.subscriber(tokenId);
        if (address(sub) != address(0)) revert HasSubscriber(tokenId, address(sub));
    }

    function _checkPair(ICollateralRegistry registry, address usdg, PoolKey memory key)
        private
        view
        returns (address stockToken)
    {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == usdg || c1 == usdg) {
            stockToken = c0 == usdg ? c1 : c0;
            ICollateralRegistry.ERC20Config memory cfg = registry.getERC20Config(stockToken);
            if (!cfg.allowed || cfg.lane != Lane.STOCK) revert PairNotAllowed(c0, c1);
        } else {
            ICollateralRegistry.ERC20Config memory cfg0 = registry.getERC20Config(c0);
            ICollateralRegistry.ERC20Config memory cfg1 = registry.getERC20Config(c1);
            if (!cfg0.allowed || !cfg1.allowed || !registry.isMemePairAllowed(PairAsset.STOCK)) {
                revert PairNotAllowed(c0, c1);
            }
            if (cfg0.lane == Lane.STOCK && cfg1.lane == Lane.MEME) stockToken = c0;
            else if (cfg1.lane == Lane.STOCK && cfg0.lane == Lane.MEME) stockToken = c1;
            else revert PairNotAllowed(c0, c1);
        }
    }

    function _checkHook(ICollateralRegistry registry, bytes32 poolId, address hook) private view {
        // 3. Removal hooks fail closed, except an exact reviewed observation-only after-remove runtime.
        uint160 removalFlags = uint160(hook) & REMOVE_LIQUIDITY_FLAGS;
        if (
            removalFlags != 0
                && (removalFlags != Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    || hook.code.length == 0
                    || registry.removalHookCodeHash(poolId) != hook.codehash)
        ) revert HookCanBlockRemoval(hook);
    }

    /// @notice Validate, then pull the NFT into the calling vault.
    function pull(IPositionManager posm, ICollateralRegistry registry, address usdg, address from, uint256 tokenId)
        internal
    {
        validate(posm, registry, usdg, from, tokenId);
        IERC721(address(posm)).safeTransferFrom(from, address(this), tokenId);
    }
}
