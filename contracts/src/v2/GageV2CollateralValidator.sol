// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {GageV2Registry} from "./GageV2Registry.sol";
import {ICollateralRegistry, PairAsset, Lane} from "../interfaces/ICollateralRegistry.sol";
import {IUniV3Factory, IUniV3Pool, IUniV3PositionManager} from "../interfaces/IUniV3.sol";
import {UniV4PositionAdapter} from "../libraries/UniV4PositionAdapter.sol";
import {UniV4MemeUSDGAdapter} from "../libraries/UniV4MemeUSDGAdapter.sol";
import {Collateral, Kind} from "../types/Types.sol";

/// @notice Shared immutable admission checker for new V2 custody accounts.
contract GageV2CollateralValidator {
    GageV2Registry public immutable REGISTRY;
    address public immutable USDG;
    address public immutable SGAGE;
    address public immutable V3_MANAGER;
    address public immutable V4_MANAGER;
    address public immutable WETH;

    error InvalidCollateral();
    error OutOfRange();

    constructor(GageV2Registry registry, address usdg, address sgage, address v3, address v4) {
        if (usdg == address(0) || sgage == address(0) || usdg == sgage || address(registry).code.length == 0) {
            revert InvalidCollateral();
        }
        REGISTRY = registry;
        USDG = usdg;
        SGAGE = sgage;
        V3_MANAGER = v3;
        V4_MANAGER = v4;
        if (v3 != address(0)) {
            if (IUniV3PositionManager(v3).factory() != registry.V3_FACTORY()) revert InvalidCollateral();
            WETH = IUniV3PositionManager(v3).WETH9();
        }
    }

    /// @notice Validate ownership, exact market admission, range and per-loan limits.
    /// @return key Exposure bucket, raw Exposure amount, maximum Aggregate admission ceiling.
    function validate(Collateral memory c, address from)
        external
        view
        returns (bytes32 key, uint256 raw, uint256 maximum)
    {
        if (c.token == address(0) || c.token == SGAGE) revert InvalidCollateral();
        if (c.kind == Kind.ERC20) {
            ICollateralRegistry.ERC20Config memory cfg = REGISTRY.getERC20Config(c.token);
            raw = c.amountOrTokenId;
            if (!cfg.allowed || raw < cfg.minAmount || raw > cfg.maxDealRaw) revert InvalidCollateral();
            return (keccak256(abi.encode(c.kind, c.token)), raw, cfg.maxOpenRaw);
        }
        if (c.kind == Kind.UNIV4_POSITION && c.token == V4_MANAGER) {
            (PoolKey memory poolKey,) = IPositionManager(V4_MANAGER).getPoolAndPositionInfo(c.amountOrTokenId);
            if (Currency.unwrap(poolKey.currency0) == SGAGE || Currency.unwrap(poolKey.currency1) == SGAGE) {
                revert InvalidCollateral();
            }
            address quoteAsset = Currency.unwrap(poolKey.currency0) == USDG
                ? Currency.unwrap(poolKey.currency1)
                : Currency.unwrap(poolKey.currency1) == USDG ? Currency.unwrap(poolKey.currency0) : address(0);
            if (quoteAsset != address(0) && REGISTRY.getERC20Config(quoteAsset).lane == Lane.MEME) {
                UniV4MemeUSDGAdapter.Checked memory meme = UniV4MemeUSDGAdapter.validate(
                    IPositionManager(V4_MANAGER), REGISTRY, USDG, from, c.amountOrTokenId
                );
                _requireV4Range(meme.poolId, meme.tickLower, meme.tickUpper);
                return (keccak256(abi.encode(c.kind, meme.poolId)), meme.liquidity, type(uint256).max);
            }
            UniV4PositionAdapter.Checked memory checked =
                UniV4PositionAdapter.validate(IPositionManager(V4_MANAGER), REGISTRY, USDG, from, c.amountOrTokenId);
            _requireV4Range(checked.poolId, checked.tickLower, checked.tickUpper);
            return (keccak256(abi.encode(c.kind, checked.poolId)), checked.liquidity, type(uint256).max);
        }
        if (c.kind != Kind.UNIV3_POSITION || c.token != V3_MANAGER) revert InvalidCollateral();
        if (IERC721(c.token).ownerOf(c.amountOrTokenId) != from) revert InvalidCollateral();
        IUniV3PositionManager.Position memory p = IUniV3PositionManager(c.token).positions(c.amountOrTokenId);
        if (p.token0 == SGAGE || p.token1 == SGAGE) revert InvalidCollateral();
        address pool = IUniV3Factory(REGISTRY.V3_FACTORY()).getPool(p.token0, p.token1, p.fee);
        GageV2Registry.V3PoolConfig memory cfg3 = REGISTRY.getV3PoolConfig(pool);
        if (!cfg3.allowed || p.liquidity < cfg3.minLiquidity || p.liquidity > cfg3.maxDealLiquidity) {
            revert InvalidCollateral();
        }
        address other = p.token0 == WETH ? p.token1 : p.token1 == WETH ? p.token0 : address(0);
        ICollateralRegistry.ERC20Config memory otherCfg = REGISTRY.getERC20Config(other);
        ICollateralRegistry.ERC20Config memory wethCfg = REGISTRY.getERC20Config(WETH);
        if (
            other == address(0) || !otherCfg.allowed || otherCfg.lane != Lane.MEME || !wethCfg.allowed
                || wethCfg.lane != Lane.ETH || !REGISTRY.isMemePairAllowed(PairAsset.ETH)
        ) revert InvalidCollateral();
        if (REGISTRY.inRangeRequired() || REGISTRY.poolInRangeRequired(bytes32(uint256(uint160(pool))))) {
            (, int24 tick,,,,,) = IUniV3Pool(pool).slot0();
            if (tick < p.tickLower || tick >= p.tickUpper) revert OutOfRange();
        }
        return (keccak256(abi.encode(c.kind, pool)), p.liquidity, cfg3.maxOpenLiquidity);
    }

    function _requireV4Range(bytes32 pool, int24 lower, int24 upper) private view {
        if (REGISTRY.poolInRangeRequired(pool)) {
            (, int24 tick,,) = StateLibrary.getSlot0(IPositionManager(V4_MANAGER).poolManager(), PoolId.wrap(pool));
            if (tick < lower || tick >= upper) revert OutOfRange();
        }
    }
}
