// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {CollateralRegistry} from "./CollateralRegistry.sol";
import {IUniV3Factory, IUniV3Pool} from "./interfaces/IUniV3.sol";

/// @notice Admission limits for a separate immutable v3 market. No authority over escrowed collateral.
contract V3CollateralRegistry is CollateralRegistry {
    struct V3PoolConfig {
        bool allowed;
        uint128 minLiquidity;
        uint128 maxDealLiquidity;
        uint128 maxOpenLiquidity;
    }

    address public immutable V3_FACTORY;
    mapping(address pool => V3PoolConfig) private _v3Pools;

    error InvalidV3Pool();
    error InvalidV3Limits();

    event V3PoolSet(
        address indexed pool, bool allowed, uint128 minLiquidity, uint128 maxDealLiquidity, uint128 maxOpenLiquidity
    );

    constructor(address initialOwner, uint32[] memory terms, uint16 feeBps_, address factory)
        CollateralRegistry(initialOwner, terms, feeBps_)
    {
        if (factory.code.length == 0) revert InvalidV3Pool();
        V3_FACTORY = factory;
    }

    function setV3PoolAllowed(address pool, bool allowed, uint128 minimum, uint128 perDeal, uint128 aggregate)
        external
        onlyOwner
    {
        if (allowed) {
            if (pool.code.length == 0) revert InvalidV3Pool();
            IUniV3Pool p = IUniV3Pool(pool);
            if (p.factory() != V3_FACTORY || IUniV3Factory(V3_FACTORY).getPool(p.token0(), p.token1(), p.fee()) != pool)
            {
                revert InvalidV3Pool();
            }
            if (minimum == 0 || perDeal < minimum || aggregate < perDeal) revert InvalidV3Limits();
        }
        _v3Pools[pool] = V3PoolConfig(allowed, minimum, perDeal, aggregate);
        emit V3PoolSet(pool, allowed, minimum, perDeal, aggregate);
    }

    function getV3PoolConfig(address pool) external view returns (V3PoolConfig memory) {
        return _v3Pools[pool];
    }
}
