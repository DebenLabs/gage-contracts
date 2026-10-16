// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The V4 route getter of the cash-out routers already deployed on mainnet (0x38E37cC0..., 0x895285fd...),
///         which predate the PoolId-keyed `v4Allowed(bytes32)` mapping of the current source.
interface ILegacyCashoutRoutes {
    /// @notice Whether a V4 route is currently enabled, by its full pool key.
    function v4Allowed(PoolKey calldata key) external view returns (bool);
}
