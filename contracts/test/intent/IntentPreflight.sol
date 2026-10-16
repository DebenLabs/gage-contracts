// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";

/// @notice The preflight an off-chain caller runs on a signed plan: an `eth_call` of `consume` or `consumeSecondary`
/// from the factory's current fill router (address(0) while fills are closed). Success is `Refusal.NONE`; otherwise
/// the verifier reverts `Refused(reason)`. The state is restored afterwards, so a plan that passes stays unused.
library IntentPreflight {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev What `consume` answers for `plan`, signed as `signature` and submitted by `filler`, in this block.
    function reason(
        IntentQuoteVerifier verifier,
        IntentQuoteVerifier.Plan memory plan,
        bytes memory signature,
        address filler
    ) internal returns (IntentQuoteVerifier.Refusal refusal) {
        uint256 snapshot = VM.snapshotState();
        VM.prank(verifier.FACTORY().fillRouter());
        try verifier.consume(plan, signature, filler) {}
        catch (bytes memory failure) {
            refusal = _refusal(failure);
        }
        VM.revertToStateAndDelete(snapshot);
    }

    /// @dev What `consumeSecondary` answers for `plan`, signed as `signature` and submitted by `filler`, in this block.
    function secondaryReason(
        IntentQuoteVerifier verifier,
        IntentQuoteVerifier.SecondaryPlan memory plan,
        bytes memory signature,
        address filler
    ) internal returns (IntentQuoteVerifier.Refusal refusal) {
        uint256 snapshot = VM.snapshotState();
        VM.prank(verifier.FACTORY().fillRouter());
        try verifier.consumeSecondary(plan, signature, filler) {}
        catch (bytes memory failure) {
            refusal = _refusal(failure);
        }
        VM.revertToStateAndDelete(snapshot);
    }

    /// @dev The reason a `Refused` revert carries; any other failure is re-raised as it came.
    function _refusal(bytes memory failure) private pure returns (IntentQuoteVerifier.Refusal) {
        if (failure.length != 36 || bytes4(failure) != IntentQuoteVerifier.Refused.selector) {
            assembly ("memory-safe") {
                revert(add(failure, 32), mload(failure))
            }
        }
        uint256 code;
        assembly ("memory-safe") {
            code := mload(add(failure, 36))
        }
        return IntentQuoteVerifier.Refusal(code);
    }
}
