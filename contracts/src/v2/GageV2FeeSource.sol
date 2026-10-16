// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2Vault} from "./GageV2Vault.sol";

/// @notice Bind a new FeeSink/DealFeeRouter deployment to V2's pull-credit interface.
/// @dev Collection always pays the immutable vault fee recipient. There is no configurable destination or custody.
contract GageV2FeeSource {
    GageV2Vault public immutable VAULT;
    address public immutable SINK;

    constructor(GageV2Vault vault, address sink) {
        VAULT = vault;
        SINK = sink;
    }
    /// @notice Present native V2 fee credits through the legacy fee collector's read interface.

    function balanceUSDG(address account) external view returns (uint256) {
        return account == SINK ? VAULT.cashCredit(VAULT.FEE_RECIPIENT()) : 0;
    }
    /// @notice Deliver the complete fee credit directly to its fixed processor, regardless of caller.

    function withdrawUSDG() external {
        VAULT.withdrawUSDGFor(VAULT.FEE_RECIPIENT());
    }
}
