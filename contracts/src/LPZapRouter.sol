// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Swapper} from "./token/base/V4Swapper.sol";
import {ZapDealVault} from "./ZapDealVault.sol";
import {Collateral, Kind} from "./types/Types.sol";

interface IWrappedETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title LPZapRouter
/// @notice USDG or WETH in; an allowed v4 LP escrowed in a borrow listing out. Every operation is atomic.
///         This router has no owner, arbitrary-call facility or right to cancel/reclaim the user's deal.
contract LPZapRouter is V4Swapper, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    ZapDealVault public immutable VAULT;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    IERC20 public immutable USDG;
    IWrappedETH public immutable WETH;
    uint256 public constant MAX_SWAPS = 4;
    /// @notice Reviewed routing pools, distinct from collateral admission. Frozen at construction.
    mapping(bytes32 poolId => bool allowed) public routingPoolAllowed;

    struct Swap {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minOut;
    }

    struct Zap {
        address inputToken;
        uint128 amountIn;
        bool unwrapWeth;
        PoolKey pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 minLiquidity;
        uint128 cap;
        uint128 minPrice;
        uint32 term;
        uint256 deadline;
    }

    struct Balances {
        address[] tokens;
        uint256[] before;
        uint256 count;
        uint256 nativeBefore;
    }

    error InvalidConfiguration();
    error Expired();
    error InvalidInput();
    error InvalidRange();
    error PoolNotAllowed(bytes32 poolId);
    error RouteNotAllowed(bytes32 poolId);
    error InsufficientInput(address token);
    error TransferMismatch();
    error TooLittleLiquidity(uint128 minted, uint128 minimum);
    error UnexpectedPosition();

    event ZappedAndListed(
        address indexed borrower,
        uint256 indexed dealId,
        uint256 indexed tokenId,
        bytes32 poolId,
        address inputToken,
        uint128 amountIn,
        uint128 liquidity
    );

    constructor(
        ZapDealVault vault,
        IPositionManager posm,
        IAllowanceTransfer permit2,
        IWrappedETH weth,
        PoolKey[] memory routingPools
    ) V4Swapper(posm.poolManager()) {
        if (
            address(weth) == address(0) || address(permit2) == address(0) || vault.POSITION_MANAGER() != address(posm)
                || address(vault.USDG()) == address(weth) || vault.zapListingVersion() != 1
        ) revert InvalidConfiguration();
        VAULT = vault;
        POSM = posm;
        PERMIT2 = permit2;
        USDG = vault.USDG();
        WETH = weth;
        for (uint256 i; i < routingPools.length; ++i) {
            routingPoolAllowed[_id(routingPools[i])] = true;
        }
    }

    /// @notice Pull exactly the approved input, execute bounded swaps, mint and list for the caller.
    /// @dev Quotes choose the split at the expected post-swap price. No quote service has signing authority.
    ///      Only this invocation's balances are spendable or refundable; donations cannot subsidise a zap.
    function zapAndList(Zap calldata z, Swap[] calldata swaps)
        external
        nonReentrant
        returns (uint256 dealId, uint256 tokenId, uint128 liquidity)
    {
        _validate(z, swaps.length);
        Balances memory b = _snapshot(z, swaps);
        IERC20(z.inputToken).safeTransferFrom(msg.sender, address(this), z.amountIn);
        if (_available(b, z.inputToken) != z.amountIn) revert TransferMismatch();
        if (z.unwrapWeth) WETH.withdraw(z.amountIn);

        for (uint256 i; i < swaps.length; ++i) {
            Swap calldata s = swaps[i];
            bytes32 id = _id(s.key);
            if (id != _id(z.pool) && !routingPoolAllowed[id]) revert RouteNotAllowed(id);
            address input = Currency.unwrap(s.zeroForOne ? s.key.currency0 : s.key.currency1);
            if (s.amountIn == 0 || s.minOut == 0 || _available(b, input) < s.amountIn) {
                revert InsufficientInput(input);
            }
            _swapExactIn(s.key, s.zeroForOne, s.amountIn, s.minOut);
        }

        (tokenId, liquidity) = _mint(z, b);
        IERC721(address(POSM)).approve(address(VAULT), tokenId);
        dealId = VAULT.listPositionFor(
            Collateral(Kind.UNIV4_POSITION, address(POSM), tokenId), z.cap, z.term, z.minPrice, msg.sender
        );
        _refund(b);
        emit ZappedAndListed(msg.sender, dealId, tokenId, _id(z.pool), z.inputToken, z.amountIn, liquidity);
    }

    function _validate(Zap calldata z, uint256 swaps) private view {
        if (block.timestamp >= z.deadline) revert Expired();
        if (
            z.amountIn == 0 || z.minLiquidity == 0 || swaps > MAX_SWAPS
                || (z.inputToken != address(USDG) && z.inputToken != address(WETH))
                || (z.unwrapWeth && z.inputToken != address(WETH))
        ) revert InvalidInput();
        if (!VAULT.REGISTRY().getPoolConfig(_id(z.pool)).allowed) revert PoolNotAllowed(_id(z.pool));
        if (
            z.pool.currency0.isAddressZero() || z.pool.currency1.isAddressZero() || z.pool.tickSpacing <= 0
                || z.tickLower < TickMath.MIN_TICK || z.tickUpper > TickMath.MAX_TICK || z.tickLower >= z.tickUpper
                || z.tickLower % z.pool.tickSpacing != 0 || z.tickUpper % z.pool.tickSpacing != 0
        ) revert InvalidRange();
    }

    function _mint(Zap calldata z, Balances memory b) private returns (uint256 tokenId, uint128 liquidity) {
        uint256 amount0 = _available(b, Currency.unwrap(z.pool.currency0));
        uint256 amount1 = _available(b, Currency.unwrap(z.pool.currency1));
        if (amount0 > type(uint128).max || amount1 > type(uint128).max) revert InvalidInput();
        (uint160 sqrtP, int24 tick,,) = POOL_MANAGER.getSlot0(z.pool.toId());
        // Recommended zaps always begin in range, even when the registry also admits one-sided existing LPs.
        if (tick < z.tickLower || tick >= z.tickUpper) revert InvalidRange();
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(z.tickLower), TickMath.getSqrtPriceAtTick(z.tickUpper), amount0, amount1
        );
        if (liquidity < z.minLiquidity) revert TooLittleLiquidity(liquidity, z.minLiquidity);
        _approve(Currency.unwrap(z.pool.currency0), uint128(amount0));
        _approve(Currency.unwrap(z.pool.currency1), uint128(amount1));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            z.pool,
            z.tickLower,
            z.tickUpper,
            uint256(liquidity),
            uint128(amount0),
            uint128(amount1),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(z.pool.currency0, z.pool.currency1);
        tokenId = POSM.nextTokenId();
        POSM.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params), z.deadline
        );
        if (IERC721(address(POSM)).ownerOf(tokenId) != address(this)) revert UnexpectedPosition();
        _approve(Currency.unwrap(z.pool.currency0), 0);
        _approve(Currency.unwrap(z.pool.currency1), 0);
    }

    function _approve(address token, uint128 amount) private {
        // Some admitted Solady tokens fix their ERC20 allowance to canonical Permit2 at infinity.
        // Their approve(Permit2, anything-else) reverts. The actual PositionManager allowance lives
        // inside Permit2, remains exact for this invocation, and is cleared after minting.
        if (IERC20(token).allowance(address(this), address(PERMIT2)) != type(uint256).max) {
            IERC20(token).forceApprove(address(PERMIT2), amount);
        }
        PERMIT2.approve(token, address(POSM), amount, uint48(block.timestamp));
    }

    function _snapshot(Zap calldata z, Swap[] calldata swaps) private view returns (Balances memory b) {
        b.tokens = new address[](swaps.length * 2 + 4);
        b.before = new uint256[](b.tokens.length);
        b.nativeBefore = address(this).balance;
        _add(b, z.inputToken);
        _add(b, address(WETH));
        _add(b, Currency.unwrap(z.pool.currency0));
        _add(b, Currency.unwrap(z.pool.currency1));
        for (uint256 i; i < swaps.length; ++i) {
            _add(b, Currency.unwrap(swaps[i].key.currency0));
            _add(b, Currency.unwrap(swaps[i].key.currency1));
        }
    }

    function _add(Balances memory b, address token) private view {
        if (token == address(0)) return;
        for (uint256 i; i < b.count; ++i) {
            if (b.tokens[i] == token) return;
        }
        b.tokens[b.count] = token;
        b.before[b.count++] = IERC20(token).balanceOf(address(this));
    }

    function _available(Balances memory b, address token) private view returns (uint256) {
        if (token == address(0)) return address(this).balance - b.nativeBefore;
        for (uint256 i; i < b.count; ++i) {
            if (b.tokens[i] == token) return IERC20(token).balanceOf(address(this)) - b.before[i];
        }
        revert InsufficientInput(token);
    }

    function _refund(Balances memory b) private {
        uint256 nativeLeft = address(this).balance - b.nativeBefore;
        if (nativeLeft > 0) WETH.deposit{value: nativeLeft}();
        for (uint256 i; i < b.count; ++i) {
            uint256 left = IERC20(b.tokens[i]).balanceOf(address(this)) - b.before[i];
            if (left > 0) IERC20(b.tokens[i]).safeTransfer(msg.sender, left);
        }
    }

    function _id(PoolKey memory key) private pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }
}
