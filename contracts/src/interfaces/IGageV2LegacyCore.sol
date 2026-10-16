// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2Registry} from "../v2/GageV2Registry.sol";
import {GageV2CollateralValidator} from "../v2/GageV2CollateralValidator.sol";

/// @notice The views of a position-capable V2 core that legacy code (Earn, Hybrid, the zap router) reads with their
/// legacy types. A token-only core built from the current source types its registry as `GageV2TokenRegistry`, which
/// has no pool settings, and has no validator: it admits collateral with its own private `_validate`.
interface IGageV2LegacyCore {
    /// @notice The core's admission validator.
    function VALIDATOR() external view returns (GageV2CollateralValidator);
    /// @notice The core's registry.
    function REGISTRY() external view returns (GageV2Registry);
}
