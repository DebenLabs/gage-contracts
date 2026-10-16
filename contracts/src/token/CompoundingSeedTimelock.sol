// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Version 2 seed custody. Fees grow the same NFT; neither principal nor fees leave before one year.
/// @dev The deployment EOA runs the keeper. No arbitrary executor, swap, approval or early-withdrawal path.
contract CompoundingSeedTimelock is IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    uint40 public constant LOCK_LENGTH = 365 days;
    uint256 public constant MAX_SQRT_PRICE_DEVIATION_BPS = 25;
    uint256 public constant MAX_DEADLINE_DELAY = 120;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    address public immutable TREASURY;
    address public immutable LOCKER;
    uint256 public tokenId;
    uint40 public releaseAt;
    bool public released;

    error Unauthorized();
    error InvalidPosition();
    error Inactive();
    error StillLocked();
    error InvalidQuote();
    error PriceMoved();
    error InsufficientLiquidity();

    event Locked(uint256 indexed tokenId, uint40 releaseAt);
    event Compounded(uint256 indexed tokenId, uint128 addedLiquidity, uint256 retained0, uint256 retained1);
    event Released(uint256 indexed tokenId, address to);

    constructor(IPositionManager posm, IAllowanceTransfer permit2, address treasury, address locker) {
        require(address(posm) != address(0) && address(permit2) != address(0));
        require(treasury != address(0) && locker != address(0));
        POSM = posm;
        PERMIT2 = permit2;
        TREASURY = treasury;
        LOCKER = locker;
    }

    function lock(uint256 id) external nonReentrant {
        if (msg.sender != LOCKER) revert Unauthorized();
        if (tokenId != 0 || id == 0) revert InvalidPosition();
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(id);
        if (
            key.currency0.isAddressZero() || key.tickSpacing != 60 || info.tickLower() != -887_220
                || info.tickUpper() != 887_220 || POSM.getPositionLiquidity(id) == 0
        ) revert InvalidPosition();
        tokenId = id;
        releaseAt = uint40(block.timestamp) + LOCK_LENGTH;
        IERC721(address(POSM)).safeTransferFrom(msg.sender, address(this), id);
        emit Locked(id, releaseAt);
    }

    function previewCompound()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            uint128 existingLiquidity,
            uint128 additionalLiquidity,
            uint256 available0,
            uint256 available1
        )
    {
        _active();
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        IPoolManager manager = POSM.poolManager();
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 last0;
        uint256 last1;
        (existingLiquidity, last0, last1) =
            manager.getPositionInfo(key.toId(), address(POSM), info.tickLower(), info.tickUpper(), bytes32(tokenId));
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthInside(key.toId(), info.tickLower(), info.tickUpper());
        // v4 fee growth intentionally wraps uint256.
        unchecked {
            growth0 -= last0;
            growth1 -= last1;
        }
        available0 = _balance(key.currency0) + FullMath.mulDiv(growth0, existingLiquidity, 1 << 128);
        available1 = _balance(key.currency1) + FullMath.mulDiv(growth1, existingLiquidity, 1 << 128);
        additionalLiquidity = _liquidity(sqrtPriceX96, available0, available1);
    }

    function compound(uint160 referenceSqrtPriceX96, uint128 minLiquidity, uint256 deadline)
        external
        nonReentrant
        returns (uint128 addedLiquidity)
    {
        if (msg.sender != TREASURY) revert Unauthorized();
        _active();
        if (block.timestamp >= releaseAt) revert Inactive();
        if (
            referenceSqrtPriceX96 == 0 || minLiquidity == 0 || deadline < block.timestamp
                || deadline > block.timestamp + MAX_DEADLINE_DELAY
        ) revert InvalidQuote();
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(tokenId);
        (uint160 current,,,) = POSM.poolManager().getSlot0(key.toId());
        uint256 difference =
            current > referenceSqrtPriceX96 ? current - referenceSqrtPriceX96 : referenceSqrtPriceX96 - current;
        if (difference * 10_000 > uint256(referenceSqrtPriceX96) * MAX_SQRT_PRICE_DEVIATION_BPS) revert PriceMoved();

        bytes[] memory collect = new bytes[](2);
        collect[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        collect[1] = abi.encode(key.currency0, key.currency1, address(this));
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), collect), deadline
        );
        uint128 amount0 = _budget(key.currency0);
        uint128 amount1 = _budget(key.currency1);
        addedLiquidity = _liquidity(current, amount0, amount1);
        if (addedLiquidity < minLiquidity) revert InsufficientLiquidity();
        _approve(key.currency0, amount0);
        _approve(key.currency1, amount1);
        bytes[] memory increase = new bytes[](2);
        increase[0] = abi.encode(tokenId, uint256(addedLiquidity), amount0, amount1, bytes(""));
        increase[1] = abi.encode(key.currency0, key.currency1);
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR)), increase),
            deadline
        );
        _approve(key.currency0, 0);
        _approve(key.currency1, 0);
        emit Compounded(tokenId, addedLiquidity, _balance(key.currency0), _balance(key.currency1));
    }

    function release() external nonReentrant {
        _active();
        if (block.timestamp < releaseAt) revert StillLocked();
        released = true;
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(tokenId);
        IERC721(address(POSM)).safeTransferFrom(address(this), TREASURY, tokenId);
        IERC20(Currency.unwrap(key.currency0)).safeTransfer(TREASURY, _balance(key.currency0));
        IERC20(Currency.unwrap(key.currency1)).safeTransfer(TREASURY, _balance(key.currency1));
        emit Released(tokenId, TREASURY);
    }

    function onERC721Received(address operator, address from, uint256 id, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(POSM) || operator != address(this) || from != LOCKER || id != tokenId) {
            revert InvalidPosition();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function _active() private view {
        if (tokenId == 0 || released) revert Inactive();
    }

    function _balance(Currency c) private view returns (uint256) {
        return IERC20(Currency.unwrap(c)).balanceOf(address(this));
    }

    function _budget(Currency c) private view returns (uint128) {
        uint256 balance = _balance(c);
        return balance > type(uint128).max ? type(uint128).max : uint128(balance);
    }

    function _approve(Currency c, uint128 amount) private {
        IERC20 token = IERC20(Currency.unwrap(c));
        token.forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(address(token), address(POSM), amount, amount == 0 ? 0 : uint48(block.timestamp));
    }

    function _liquidity(uint160 price, uint256 a0, uint256 a1) private pure returns (uint128) {
        // Match execution's uint128 budgets; excess donations stay in custody until release.
        if (a0 > type(uint128).max) a0 = type(uint128).max;
        if (a1 > type(uint128).max) a1 = type(uint128).max;
        return LiquidityAmounts.getLiquidityForAmounts(
            price, TickMath.getSqrtPriceAtTick(-887_220), TickMath.getSqrtPriceAtTick(887_220), a0, a1
        );
    }
}
