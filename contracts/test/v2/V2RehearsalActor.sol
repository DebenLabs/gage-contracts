// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice TESTNET FIXTURE ONLY: independent participant addresses controlled by the rehearsal signer.
contract V2RehearsalActor is IERC721Receiver {
    address public immutable CONTROLLER;

    error NotController();
    error WrongChain();

    constructor() {
        if (block.chainid != 46_630 && block.chainid != 31_337) revert WrongChain();
        CONTROLLER = msg.sender;
    }

    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != CONTROLLER) revert NotController();
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
