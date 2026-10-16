// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2Registry} from "../v2/GageV2Registry.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @notice Testnet-only V2 registry: the owner may allow loan terms below the mainnet minimum, so a listing can run
/// through funding, maturity and settlement in minutes. Never deployable on mainnet.
contract TestnetV2Registry is GageV2Registry, TestnetOnly {
    constructor(address admin, uint32[] memory terms, address factory) GageV2Registry(admin, terms, factory) {}

    /// @notice Replace the allowed terms without the mainnet bounds; the count bound and uniqueness still hold.
    function setTestnetTerms(uint32[] calldata terms) external onlyOwner {
        if (terms.length == 0) revert NoTerms();
        if (terms.length > MAX_TERMS) revert TooManyTerms(terms.length, MAX_TERMS);
        for (uint256 i = 0; i < _terms.length; ++i) {
            _termAllowed[_terms[i]] = false;
        }
        delete _terms;
        for (uint256 i = 0; i < terms.length; ++i) {
            if (terms[i] == 0) revert TermOutOfBounds(terms[i]);
            if (_termAllowed[terms[i]]) revert DuplicateTerm(terms[i]);
            _termAllowed[terms[i]] = true;
            _terms.push(terms[i]);
        }
        emit TermsSet(terms);
    }
}
