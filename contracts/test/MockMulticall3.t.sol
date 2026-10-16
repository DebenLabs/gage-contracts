// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockMulticall3} from "./mocks/MockMulticall3.sol";

contract MockMulticall3Test is Test {
    function test_metadataSharesTheAggregateSnapshot() public {
        vm.roll(12_345);
        vm.warp(1_800_000_000);
        vm.chainId(31_337);
        MockMulticall3 multicall = new MockMulticall3();
        MockMulticall3.Call3[] memory calls = new MockMulticall3.Call3[](3);
        calls[0] = MockMulticall3.Call3(address(multicall), false, abi.encodeWithSignature("getBlockNumber()"));
        calls[1] =
            MockMulticall3.Call3(address(multicall), false, abi.encodeWithSignature("getCurrentBlockTimestamp()"));
        calls[2] = MockMulticall3.Call3(address(multicall), false, abi.encodeWithSignature("getChainId()"));

        MockMulticall3.Result[] memory results = multicall.aggregate3(calls);
        assertEq(results.length, 3);
        for (uint256 i; i < results.length; ++i) {
            assertTrue(results[i].success);
        }
        assertEq(abi.decode(results[0].returnData, (uint256)), 12_345);
        assertEq(abi.decode(results[1].returnData, (uint256)), 1_800_000_000);
        assertEq(abi.decode(results[2].returnData, (uint256)), 31_337);
    }
}
