// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IV3PositionManager} from "../../src/interfaces/IV3PositionManager.sol";

contract IndexerV3PositionMock is ERC721Enumerable {
    address public immutable WETH9;
    address internal asset;

    constructor(address a, address weth) ERC721("Local v3", "V3") {
        asset = a;
        WETH9 = weth;
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function getPool(address, address, uint24) external view returns (address) {
        return address(this);
    }

    function positions(uint256) external view returns (IV3PositionManager.Position memory p) {
        (p.token0, p.token1) = asset < WETH9 ? (asset, WETH9) : (WETH9, asset);
        p.fee = 3000;
        p.tickLower = -600;
        p.tickUpper = 600;
        p.liquidity = 1e15;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1 << 96), 0, 0, 0, 0, 0, true);
    }
}
