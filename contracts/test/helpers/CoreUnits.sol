// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";

/// @dev Test-only stand-in for the core's former `unitsOf` view (removed by CORE-a-08): the number of lender quarters
/// `account` holds on loan `id`, counted from `lenders(id)`, and zero for the zero address. It makes exactly one
/// external call, as the view did, so `vm.prank` sequencing around it is unchanged. It also reads engines already
/// deployed with the view. Attach it with `using {unitsOf} for GageV2Vault;`.
function unitsOf(GageV2Vault core, uint256 id, address account) view returns (uint8 count) {
    address[4] memory slots = core.lenders(id);
    if (account == address(0)) return 0;
    for (uint8 i; i < 4; ++i) {
        if (slots[i] == account) ++count;
    }
}
