// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IV3PositionManager, IV3Factory, IV3Pool} from "../interfaces/IV3PositionManager.sol";
import {ICollateralRegistry, PairAsset, Lane} from "../interfaces/ICollateralRegistry.sol";

/// @notice Canonical v3 MEME/WETH NFTs. Compiled into DealVaultV3; never delegates custody to an external adapter.
/// @dev Pool IDs are zero-padded v3 pool addresses in this vault's separate registry.
///      Escrow has no collect, decrease-liquidity, approval or arbitrary-call entry point. Fees follow the NFT.
library UniV3PositionAdapter {
    error NotPositionOwner(uint256 tokenId, address owner, address from);
    error PoolNotAllowed(bytes32 poolId);
    error PairNotAllowed(address token0, address token1);
    error LiquidityBelowMinimum(uint256 tokenId, uint128 liquidity, uint128 minLiquidity);
    error OutOfRange(uint256 tokenId, int24 tick, int24 tickLower, int24 tickUpper);

    function validate(IV3PositionManager posm, ICollateralRegistry registry, address from, uint256 tokenId)
        internal
        view
        returns (address pool)
    {
        address owner = posm.ownerOf(tokenId);
        if (owner != from) revert NotPositionOwner(tokenId, owner, from);
        IV3PositionManager.Position memory p = posm.positions(tokenId);
        pool = IV3Factory(posm.factory()).getPool(p.token0, p.token1, p.fee);
        bytes32 poolId = bytes32(uint256(uint160(pool)));
        ICollateralRegistry.PoolConfig memory cfg = registry.getPoolConfig(poolId);
        if (pool == address(0) || !cfg.allowed) revert PoolNotAllowed(poolId);
        address weth = posm.WETH9();
        if (p.token0 != weth && p.token1 != weth) revert PairNotAllowed(p.token0, p.token1);
        address asset = p.token0 == weth ? p.token1 : p.token0;
        ICollateralRegistry.ERC20Config memory a = registry.getERC20Config(asset);
        ICollateralRegistry.ERC20Config memory w = registry.getERC20Config(weth);
        if (
            !a.allowed || a.lane != Lane.MEME || !w.allowed || w.lane != Lane.ETH
                || !registry.isMemePairAllowed(PairAsset.ETH)
        ) revert PairNotAllowed(p.token0, p.token1);
        if (p.liquidity == 0 || p.liquidity <= cfg.minLiquidity) {
            revert LiquidityBelowMinimum(tokenId, p.liquidity, cfg.minLiquidity);
        }
        if (registry.inRangeRequired()) {
            (, int24 tick,,,,,) = IV3Pool(pool).slot0();
            if (tick < p.tickLower || tick >= p.tickUpper) {
                revert OutOfRange(tokenId, tick, p.tickLower, p.tickUpper);
            }
        }
    }

    function pull(IV3PositionManager posm, ICollateralRegistry registry, address from, uint256 tokenId) internal {
        validate(posm, registry, from, tokenId);
        posm.safeTransferFrom(from, address(this), tokenId);
    }
}
