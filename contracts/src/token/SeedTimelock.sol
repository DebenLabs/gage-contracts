// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {ISeedTimelock} from "../interfaces/token/ISeedTimelock.sol";

/// @title SeedTimelock
/// @notice Holds the seed GAGE/sGAGE position NFT for 365 days. Anyone may send its swap fees to the treasury at any
///         time; after the lock the NFT itself goes to the treasury. LPRewards scores the seed at zero.
contract SeedTimelock is ISeedTimelock, IERC721Receiver {
    uint40 public constant LOCK_LENGTH = 365 days;
    address public immutable TREASURY;
    IPositionManager public immutable POSM;

    uint256 public tokenId;
    uint40 public releaseAt;

    error UnexpectedERC721(address operator, address from, uint256 tokenId);

    constructor(IPositionManager posm, address treasury) {
        if (address(posm) == address(0) || treasury == address(0)) revert ZeroAddress();
        POSM = posm;
        TREASURY = treasury;
    }

    /// @inheritdoc ISeedTimelock
    function lock(uint256 tokenId_) external {
        if (tokenId != 0) revert AlreadyLocked();
        tokenId = tokenId_;
        releaseAt = uint40(block.timestamp) + LOCK_LENGTH;
        IERC721(address(POSM)).safeTransferFrom(msg.sender, address(this), tokenId_);
        emit Locked(tokenId_, releaseAt);
    }

    /// @inheritdoc ISeedTimelock
    function collectFees() external returns (uint256 amount0, uint256 amount1) {
        if (tokenId == 0) revert NotLocked();
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(tokenId);
        uint256 before0 = _balance(key.currency0, TREASURY);
        uint256 before1 = _balance(key.currency1, TREASURY);
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, TREASURY);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        amount0 = _balance(key.currency0, TREASURY) - before0;
        amount1 = _balance(key.currency1, TREASURY) - before1;
        emit FeesCollected(amount0, amount1);
    }

    /// @inheritdoc ISeedTimelock
    function release() external {
        if (tokenId == 0) revert NotLocked();
        if (block.timestamp < releaseAt) revert StillLocked(releaseAt);
        uint256 id = tokenId;
        IERC721(address(POSM)).safeTransferFrom(address(this), TREASURY, id);
        emit Released(id, TREASURY);
    }

    function onERC721Received(address operator, address from, uint256 id, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(POSM) || id != tokenId) revert UnexpectedERC721(operator, from, id);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _balance(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }
}
