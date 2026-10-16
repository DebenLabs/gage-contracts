// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentVault} from "../../src/intent/IntentVault.sol";

/// @notice Test helper: writes the Intent strategy's creation code as the two data contracts an `IntentFactory` is
/// given (`Params.codeA`, `Params.codeB`), exactly as the deployment script does: split in half, each part behind a
/// leading STOP (SSTORE2). It is never deployed on chain; the factory reads the chunks and publishes their hash.
/// @dev Moved from src/intent, where it was S9-01's on-chain code store; its code is unchanged.
contract IntentVaultCode {
    /// @notice keccak256 of the stored creation code.
    bytes32 public immutable INIT_HASH;
    address public immutable CHUNK_A;
    address public immutable CHUNK_B;
    uint256 public immutable SPLIT;

    error StoreFailed();

    constructor() {
        bytes memory code = type(IntentVault).creationCode;
        INIT_HASH = keccak256(code);
        uint256 split = code.length / 2;
        SPLIT = split;
        CHUNK_A = _store(code, 0, split);
        CHUNK_B = _store(code, split, code.length - split);
    }

    /// @dev Store one chunk as the runtime of a data contract behind a leading STOP, the SSTORE2 pattern.
    function _store(bytes memory code, uint256 offset, uint256 length) internal returns (address pointer) {
        bytes memory init = new bytes(12 + length);
        assembly ("memory-safe") {
            // PUSH1 0x0B, MSIZE, DUP2, CODESIZE, SUB, DUP1, SWAP3, MSIZE, CODECOPY, RETURN, then STOP + data.
            mstore(add(init, 0x20), 0x600b5981380380925939f3000000000000000000000000000000000000000000)
            mcopy(add(init, 0x2c), add(add(code, 0x20), offset), length)
            pointer := create(0, add(init, 0x20), mload(init))
        }
        if (pointer == address(0)) revert StoreFailed();
    }
}
