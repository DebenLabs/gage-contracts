// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IUniV3Factory} from "../interfaces/IUniV3.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @title TestnetV3Factory
/// @notice The Uniswap v3 factory a labeled gage testnet stands in for. Robinhood testnet has no canonical v3
///         deployment, and the V2 engine's registry, validator and cash-out router all check pool identity
///         against one factory address, so the testnet publishes its own.
/// @dev NEVER deploy this on chain 4663, which uses the canonical factory. The only pool registered here is the
///      cash-out financing source; no v3 pool is ever admitted as collateral on testnet.
contract TestnetV3Factory is IUniV3Factory, TestnetOnly {
    /// @notice Marks this as a testnet stand-in, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: not Uniswap";

    /// @notice Whoever may register a pool. Set once at deployment.
    address public immutable ADMIN;

    mapping(address token0 => mapping(address token1 => mapping(uint24 fee => address))) private _pools;

    error NotAdmin();
    error InvalidPool();

    event PoolRegistered(address indexed token0, address indexed token1, uint24 fee, address pool);

    constructor(address admin) {
        ADMIN = admin;
    }

    /// @notice The registered pool for a pair and fee, in either token order, or the zero address.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pools[token0][token1][fee];
    }

    /// @notice Register a pool so the engine's identity checks resolve it. Testnet only.
    function register(address tokenA, address tokenB, uint24 fee, address pool) external {
        if (msg.sender != ADMIN) revert NotAdmin();
        if (pool.code.length == 0 || tokenA == tokenB) revert InvalidPool();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _pools[token0][token1][fee] = pool;
        emit PoolRegistered(token0, token1, fee, pool);
    }
}
