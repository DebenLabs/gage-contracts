// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
/// Read-only eth_call probe using a code override. Never deployed; every simulated change reverts.

contract MemeDepthProbe {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    error Depth(uint256 output);

    function quote(bool zeroForOne, uint256 amount, uint160 limit) external returns (uint256 output) {
        try PM.unlock(abi.encode(zeroForOne, amount, limit)) {
            revert("unexpected success");
        } catch (bytes memory result) {
            require(result.length == 36 && bytes4(result) == Depth.selector, "unexpected quote error");
            assembly {
                output := mload(add(result, 36))
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM));
        (bool zeroForOne, uint256 amount, uint160 limit) = abi.decode(data, (bool, uint256, uint160));
        PoolKey memory key = PoolKey(
            Currency.wrap(address(bytes20(hex"385f4f8ae47651ce5f58f5265395a669f8281e18"))),
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            6999,
            70,
            IHooks(address(0))
        );
        BalanceDelta delta = PM.swap(key, SwapParams(zeroForOne, -int256(amount), limit), "");
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        require(out >= 0);
        revert Depth(uint256(uint128(out)));
    }
}
