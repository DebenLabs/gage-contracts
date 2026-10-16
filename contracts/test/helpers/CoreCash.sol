// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";

/// @dev Test-only stand-in for the core's former `accountedCash` counter (removed by CORE-b-13): the USDG the core
/// owes, that is the withdrawable credit of `holders` (each account counted once) plus the contributions of every loan
/// still funding, sliced as the core slices them. When `holders` names every account with a credit, a core that
/// receives no direct transfers holds exactly this amount. Attach it with `using {cashOwed} for GageV2Vault;`.
function cashOwed(GageV2Vault core, address[] memory holders) view returns (uint256 owed) {
    for (uint256 i; i < holders.length; ++i) {
        bool counted;
        for (uint256 j; j < i; ++j) {
            if (holders[j] == holders[i]) counted = true;
        }
        if (!counted) owed += core.cashCredit(holders[i]);
    }
    for (uint256 id = 1; id <= core.loanCount(); ++id) {
        V2Loan memory l = core.getLoan(id);
        if (l.state != V2State.FUNDING) continue;
        address[4] memory slots = core.lenders(id);
        for (uint256 i; i < 4; ++i) {
            if (slots[i] != address(0)) owed += l.principal / 4 + (i < l.principal % 4 ? 1 : 0);
        }
    }
}
