// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Local web-fixture implementation of the Multicall3 methods used by viem.
/// @dev Test only. Installed at the canonical multicall address on a fresh Anvil.
contract MockMulticall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory results) {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (results[i].success, results[i].returnData) = calls[i].target.call(calls[i].callData);
            require(calls[i].allowFailure || results[i].success, "Multicall3: call failed");
        }
    }

    function getEthBalance(address account) external view returns (uint256) {
        return account.balance;
    }

    /// @notice Returns the block number shared by every call in the aggregate.
    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    /// @notice Returns the timestamp shared by every call in the aggregate.
    function getCurrentBlockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    /// @notice Returns the executing chain's identity without a separate RPC request.
    function getChainId() external view returns (uint256) {
        return block.chainid;
    }
}
