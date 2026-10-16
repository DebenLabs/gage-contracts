// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

contract IndexerV4PositionMock is ERC721Enumerable {
    PoolKey internal key;

    constructor(address a, address b) ERC721("Local v4", "V4") {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function getPoolAndPositionInfo(uint256) external view returns (PoolKey memory, PositionInfo) {
        return (key, PositionInfoLibrary.initialize(key, -600, 600));
    }

    function getPositionLiquidity(uint256) external pure returns (uint128) {
        return 1e15;
    }

    function subscriber(uint256) external pure returns (address) {
        return address(0);
    }
}

