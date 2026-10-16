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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CompoundingSeedTimelock} from "./CompoundingSeedTimelock.sol";

/// @notice One-use seed transaction: initialize, mint, deploy the 365-day compounding lock, lock, refund rounding dust.
/// @dev Only the deployment EOA can choose the pool and amounts. No publicly empty timelock is ever exposed.
contract CompoundingSeedBootstrap is IERC721Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public immutable OWNER;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    CompoundingSeedTimelock public timelock;
    int24 internal constant LOWER = -887_220;
    int24 internal constant UPPER = 887_220;

    error NotOwner();
    error AlreadySeeded();
    error InvalidSeed();
    error UnexpectedPoolState();
    error ExcessDust();

    event Seeded(address indexed timelock, uint256 indexed tokenId, uint256 spent0, uint256 spent1);

    constructor(address owner, IPositionManager posm, IAllowanceTransfer permit2) {
        require(owner != address(0) && address(posm) != address(0) && address(permit2) != address(0));
        OWNER = owner;
        POSM = posm;
        PERMIT2 = permit2;
    }

    function seed(PoolKey calldata key, uint160 sqrtPriceX96, uint128 amount0, uint128 amount1) external nonReentrant {
        if (msg.sender != OWNER) revert NotOwner();
        if (address(timelock) != address(0)) revert AlreadySeeded();
        if (key.currency0.isAddressZero() || key.tickSpacing != 60 || amount0 == 0 || amount1 == 0) {
            revert InvalidSeed();
        }
        IPoolManager manager = POSM.poolManager();
        (uint160 current,,,) = manager.getSlot0(key.toId());
        // A third party may initialize the public key. Accept only our exact price and no existing liquidity.
        if (current == 0) manager.initialize(key, sqrtPriceX96);
        else if (current != sqrtPriceX96 || manager.getLiquidity(key.toId()) != 0) revert UnexpectedPoolState();

        _pull(key.currency0, amount0);
        _pull(key.currency1, amount1);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(LOWER), TickMath.getSqrtPriceAtTick(UPPER), amount0, amount1
        );
        if (liquidity == 0) revert InvalidSeed();
        // Read the global NFT counter inside the same transaction as mint and lock.
        uint256 id = POSM.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, LOWER, UPPER, uint256(liquidity), amount0, amount1, address(this), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp
        );
        CompoundingSeedTimelock lock = new CompoundingSeedTimelock(POSM, PERMIT2, OWNER, address(this));
        timelock = lock;
        IERC721(address(POSM)).approve(address(lock), id);
        lock.lock(id);
        uint256 dust0 = _refund(key.currency0);
        uint256 dust1 = _refund(key.currency1);
        // Full-range truncation and integer rounding only: less than one billionth of either budget.
        if (dust0 > uint256(amount0) / 1e9 + 100 || dust1 > uint256(amount1) / 1e9 + 100) revert ExcessDust();
        emit Seeded(address(lock), id, amount0 - dust0, amount1 - dust1);
    }

    function _pull(Currency currency, uint128 amount) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        // A third party can send tokens to the helper before launch. Forward donations separately so they
        // cannot trip the seed's dust bound or change the recorded contribution.
        uint256 donated = token.balanceOf(address(this));
        if (donated != 0) token.safeTransfer(OWNER, donated);
        token.safeTransferFrom(OWNER, address(this), amount);
        token.forceApprove(address(PERMIT2), amount);
        PERMIT2.approve(address(token), address(POSM), amount, uint48(block.timestamp));
    }

    function _refund(Currency currency) private returns (uint256 dust) {
        IERC20 token = IERC20(Currency.unwrap(currency));
        token.forceApprove(address(PERMIT2), 0);
        PERMIT2.approve(address(token), address(POSM), 0, 0);
        dust = token.balanceOf(address(this));
        if (dust != 0) token.safeTransfer(OWNER, dust);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(POSM));
        return IERC721Receiver.onERC721Received.selector;
    }
}
