// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGageV2LegacyCore} from "../../src/interfaces/IGageV2LegacyCore.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";

Vm constant LEGACY_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev The Earn and Hybrid strategies (legacy, outside the release) read an admission validator from their core's
/// `VALIDATOR()`, which the deployed position-capable cores still have. A core built from this source validates its
/// token collateral itself and has no such view (CORE-b-20), so a fixture that runs those strategies over it answers
/// that one view with the validator the strategy uses. Nothing in the core reads it.
function answerLegacyValidator(address core, address validator) {
    LEGACY_VM.mockCall(core, abi.encodeWithSelector(IGageV2LegacyCore.VALIDATOR.selector), abi.encode(validator));
}

/// @dev The same answer for a fixture whose tests clear mocked calls (the Hybrid suites): this source's core plus that
/// one view, and nothing else.
contract GageV2VaultWithValidator is GageV2Vault {
    address public immutable VALIDATOR;

    constructor(
        address validator,
        GageV2TokenRegistry registry,
        IERC20 usdg,
        IERC20 sgage,
        address feeRecipient,
        uint32 grace,
        GageLegacyAdapter bridge
    ) GageV2Vault(registry, usdg, sgage, feeRecipient, grace, bridge) {
        VALIDATOR = validator;
    }
}
