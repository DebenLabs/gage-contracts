// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TestnetOnly} from "./TestnetOnly.sol";
import {IntentVault} from "../intent/IntentVault.sol";
import {IntentQuoteVerifier} from "../intent/IntentQuoteVerifier.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2State} from "../v2/V2Types.sol";

/// @title IntentDemoPlanRouter
/// @notice Testnet fixture for the S3 quote demonstration: it consumes a signed funding plan through the quote
///         verifier and funds each purchase the plan names, and the listing must be active afterwards.
/// @dev This is NOT the Intent fill router. It records no execution-fee payable, splits nothing and snapshots no
///      recipient (S4); the fee stays on the vault's own ledger. It exists only so a signed plan can be shown verified,
///      used once and refused on a test chain before S4, and it refuses to exist on Robinhood Chain mainnet.
contract IntentDemoPlanRouter is TestnetOnly {
    IntentQuoteVerifier public immutable VERIFIER;
    GageV2Vault public immutable CORE;

    error Incomplete();

    constructor(IntentQuoteVerifier verifier) {
        VERIFIER = verifier;
        CORE = verifier.CORE();
    }

    /// @notice Use `plan` once for the caller and fund every purchase in it; all of it or none of it.
    function fill(IntentQuoteVerifier.Plan calldata plan, bytes calldata signature) external {
        VERIFIER.consume(plan, signature, msg.sender);
        for (uint256 i; i < plan.allocations.length; ++i) {
            IntentQuoteVerifier.Allocation calldata a = plan.allocations[i];
            IntentVault(payable(a.vault)).purchase(plan.listingId, a.units, 0, a.maxReserveShares, a.executionFee);
        }
        if (CORE.getLoan(plan.listingId).state != V2State.ACTIVE) revert Incomplete();
    }
}
