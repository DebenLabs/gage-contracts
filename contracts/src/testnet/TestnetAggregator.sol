// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUniV3Factory, IUniV3Pool, IV2FlashPool} from "../interfaces/IUniV3.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @title TestnetAggregator
/// @notice A labeled gage testnet's stand-in for KyberSwap's router (D245): what `LoopRouter.loopVia` and
///         `GageV2CashoutRouter.cashOutVia` call as their admitted executor on a testnet KyberSwap does not serve. It
///         makes an exact-input sale of `amountIn` of `tokenIn`, pulled from the caller, across up to four paths of up
///         to three hops through hookless Uniswap v4 pools of the PoolManager and canonical V3 pools of the V3
///         factory; the output goes to `recipient` and must reach `minReturn`. To both routers it behaves as
///         KyberSwap's router does: called with no value, it pulls exactly the input they approved and pays them.
/// @dev NEVER deploy on chain 4663. No owner, and no funds held between calls: every hop must consume its whole
///      input, so each swap leaves this contract's balances where it found them. No pool may be used twice in one
///      swap, which makes `quote`, priced hop by hop, exact at the block. ERC-20 tokens only, no native ETH.
contract TestnetAggregator is TestnetOnly, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice Marks this as a testnet stand-in, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: not KyberSwap";
    uint8 public constant MAX_PATHS = 4;
    uint8 public constant MAX_HOPS = 3;

    enum Venue {
        V4,
        V3
    }

    /// @dev One hop from the previous token (the path's start: `Swap.tokenIn`) to `tokenOut`. V4: the hookless pool of
    ///      the pair, `fee` and `tickSpacing`. V3: the V3 factory's pool of the pair and `fee`; `tickSpacing` must be 0.
    struct Hop {
        Venue venue;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @dev One path: `amountIn` of `Swap.tokenIn` sold along `hops`, the last of which ends in `Swap.tokenOut`.
    struct Path {
        uint256 amountIn;
        Hop[] hops;
    }

    /// @dev A sale: the paths' inputs add up to `amountIn`; all of `tokenOut` they make goes to `recipient`.
    struct Swap {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minReturn;
        address recipient;
        uint256 deadline;
        Path[] paths;
    }

    IPoolManager public immutable POOL_MANAGER;
    IUniV3Factory public immutable V3_FACTORY;

    /// @dev The V3 pool a hop swaps in, for that swap only: the one caller the V3 callback answers.
    address private transient _activeV3;
    /// @dev Set by `quoteHop` only: the callbacks price the hop and revert instead of paying.
    bool private transient _quoting;
    bool private transient _entered;

    error Expired();
    error BadSwap();
    error BadPath(uint256 path);
    error RepeatedPool(uint256 path, uint256 hop);
    error UnknownPool(uint256 path, uint256 hop);
    error PartialFill(uint256 path, uint256 hop);
    error ReturnTooLow(uint256 amountOut, uint256 minReturn);
    error InexactPull(uint256 expected, uint256 received);
    error NotPool();
    error NotPoolManager();
    error Reentered();
    /// @notice What `quote` reverts with: the total output and each path's.
    error Quoted(uint256 amountOut, uint256[] pathOut);
    /// @notice What `quoteHop` reverts with: the hop's output.
    error HopQuoted(uint256 amountOut);

    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    /// @param manager The Uniswap v4 PoolManager whose hookless pools v4 hops swap in.
    /// @param factory The Uniswap V3 factory whose pools V3 hops swap in.
    constructor(IPoolManager manager, IUniV3Factory factory) {
        if (address(manager).code.length == 0 || address(factory).code.length == 0) revert BadSwap();
        POOL_MANAGER = manager;
        V3_FACTORY = factory;
    }

    /// @notice Sell exactly `s.amountIn` of `s.tokenIn`, taken from the caller with `transferFrom`, along `s.paths`, and
    ///         send all of the `s.tokenOut` it makes to `s.recipient`. Reverts below `s.minReturn`, after
    ///         `s.deadline`, on a fee-on-transfer input, and on any hop that does not consume its whole input.
    /// @param s The sale.
    /// @return amountOut The `s.tokenOut` sent to `s.recipient`.
    function swap(Swap calldata s) external returns (uint256 amountOut) {
        if (_entered) revert Reentered();
        _entered = true;
        if (block.timestamp > s.deadline) revert Expired();
        if (s.recipient == address(0) || s.recipient == address(this)) revert BadSwap();
        _validate(s);

        IERC20 tokenIn = IERC20(s.tokenIn);
        IERC20 tokenOut = IERC20(s.tokenOut);
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), s.amountIn);
        uint256 received = tokenIn.balanceOf(address(this)) - inBefore;
        if (received != s.amountIn) revert InexactPull(s.amountIn, received);

        for (uint256 i; i < s.paths.length; ++i) {
            Path calldata path = s.paths[i];
            uint256 amount = path.amountIn;
            address from = s.tokenIn;
            for (uint256 j; j < path.hops.length; ++j) {
                amount = _hop(from, path.hops[j], amount, i, j);
                from = path.hops[j].tokenOut;
            }
        }

        amountOut = tokenOut.balanceOf(address(this)) - outBefore;
        if (amountOut < s.minReturn) revert ReturnTooLow(amountOut, s.minReturn);
        if (tokenIn.balanceOf(address(this)) != inBefore) revert PartialFill(type(uint256).max, 0);
        tokenOut.safeTransfer(s.recipient, amountOut);
        emit Swapped(msg.sender, s.tokenIn, s.tokenOut, s.amountIn, amountOut, s.recipient);
        _entered = false;
    }

    /// @notice The output `swap` would give for `s` now, for eth_call: always reverts `Quoted(amountOut, pathOut)`, or
    ///         the error the swap would meet. Takes nothing; ignores `minReturn`, `recipient` and `deadline`.
    /// @dev Each hop is priced alone and rolled back; since no pool appears twice in a sale, each one is found as the
    ///      swap would find it, and the quote is exact at the block.
    /// @param s The sale.
    function quote(Swap calldata s) external {
        _validate(s);
        uint256[] memory pathOut = new uint256[](s.paths.length);
        uint256 total;
        for (uint256 i; i < s.paths.length; ++i) {
            Path calldata path = s.paths[i];
            uint256 amount = path.amountIn;
            address from = s.tokenIn;
            for (uint256 j; j < path.hops.length; ++j) {
                try this.quoteHop(from, path.hops[j], amount) {
                    revert BadSwap();
                } catch (bytes memory err) {
                    if (err.length != 36 || bytes4(err) != HopQuoted.selector) {
                        assembly ("memory-safe") {
                            revert(add(err, 0x20), mload(err))
                        }
                    }
                    assembly ("memory-safe") {
                        amount := mload(add(err, 36))
                    }
                }
                from = path.hops[j].tokenOut;
            }
            pathOut[i] = amount;
            total += amount;
        }
        revert Quoted(total, pathOut);
    }

    /// @notice `quote`'s per-hop probe, callable only by this contract: makes the hop and reverts `HopQuoted(out)`.
    /// @param tokenIn The hop's input token.
    /// @param hop The hop.
    /// @param amountIn The hop's input.
    function quoteHop(address tokenIn, Hop calldata hop, uint256 amountIn) external {
        if (msg.sender != address(this)) revert BadSwap();
        _quoting = true;
        _hop(tokenIn, hop, amountIn, 0, 0);
        revert BadSwap();
    }

    /// @notice The PoolManager's callback for one v4 hop: swap exactly the input, then pay and take (or, in a quote,
    ///         revert with the output).
    /// @dev The PoolManager calls back only the account that unlocked it, which for this contract is `_hop` alone.
    /// @param data The encoded hop: input token, hop, amount and its path and hop indices.
    /// @return The hop's output, encoded.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (address tokenIn, Hop memory hop, uint256 amount, uint256 i, uint256 j) =
            abi.decode(data, (address, Hop, uint256, uint256, uint256));
        bool zeroForOne = tokenIn < hop.tokenOut;
        BalanceDelta d = POOL_MANAGER.swap(
            _key(tokenIn, hop),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
        if (inDelta >= 0 || uint256(-int256(inDelta)) != amount || outDelta <= 0) revert PartialFill(i, j);
        uint256 out = uint256(uint128(outDelta));
        if (_quoting) revert HopQuoted(out);
        POOL_MANAGER.sync(Currency.wrap(tokenIn));
        IERC20(tokenIn).safeTransfer(address(POOL_MANAGER), amount);
        POOL_MANAGER.settle();
        POOL_MANAGER.take(Currency.wrap(hop.tokenOut), address(this), out);
        return abi.encode(out);
    }

    /// @notice The V3 pool's callback for one hop: pay exactly the input (or, in a quote, revert with the output).
    /// @dev Only the pool a hop is swapping in may call it, once: outside that swap no caller is answered.
    /// @param amount0Delta The pool's token0 owed to it (positive) or sent from it (negative).
    /// @param amount1Delta The pool's token1 owed to it (positive) or sent from it (negative).
    /// @param data The encoded input token, amount and the hop's path and hop indices.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activeV3) revert NotPool();
        _activeV3 = address(0);
        (address input, uint256 amount, uint256 i, uint256 j) = abi.decode(data, (address, uint256, uint256, uint256));
        (int256 paid, int256 got) =
            IUniV3Pool(msg.sender).token0() == input ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (paid != int256(amount) || got >= 0) revert PartialFill(i, j);
        if (_quoting) revert HopQuoted(uint256(-got));
        IERC20(input).safeTransfer(msg.sender, amount);
    }

    /// @dev One exact-input hop of `amount` of `tokenIn`; returns what it made.
    function _hop(address tokenIn, Hop calldata hop, uint256 amount, uint256 i, uint256 j)
        private
        returns (uint256 out)
    {
        if (hop.venue == Venue.V4) {
            return abi.decode(POOL_MANAGER.unlock(abi.encode(tokenIn, hop, amount, i, j)), (uint256));
        }
        address pool = V3_FACTORY.getPool(tokenIn, hop.tokenOut, hop.fee);
        if (pool == address(0)) revert UnknownPool(i, j);
        bool zeroForOne = tokenIn < hop.tokenOut;
        _activeV3 = pool;
        (int256 amount0, int256 amount1) = IV2FlashPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(tokenIn, amount, i, j)
            );
        // The callback clears the pool; a pool that never called back leaves it set.
        if (_activeV3 != address(0)) revert NotPool();
        (int256 paid, int256 got) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        if (paid != int256(amount) || got >= 0) revert PartialFill(i, j);
        out = uint256(-got);
    }

    /// @dev The checks `swap` and `quote` share: the sale's shape, each path's, and every pool named once.
    function _validate(Swap calldata s) private view {
        uint256 paths = s.paths.length;
        if (
            s.tokenIn == address(0) || s.tokenOut == address(0) || s.tokenIn == s.tokenOut || paths == 0
                || paths > MAX_PATHS || s.amountIn > uint256(type(int256).max)
        ) revert BadSwap();
        bytes32[] memory pools = new bytes32[](uint256(MAX_PATHS) * MAX_HOPS);
        uint256 seen;
        uint256 sum;
        for (uint256 i; i < paths; ++i) {
            Path calldata path = s.paths[i];
            uint256 hops = path.hops.length;
            if (path.amountIn == 0 || hops == 0 || hops > MAX_HOPS || path.hops[hops - 1].tokenOut != s.tokenOut) {
                revert BadPath(i);
            }
            sum += path.amountIn;
            address from = s.tokenIn;
            for (uint256 j; j < hops; ++j) {
                Hop calldata hop = path.hops[j];
                address to = hop.tokenOut;
                if (to == address(0) || to == s.tokenIn) revert BadPath(i);
                // A token visited twice: the path's later hops may not return to it.
                for (uint256 k; k < j; ++k) {
                    if (path.hops[k].tokenOut == to) revert BadPath(i);
                }
                bytes32 id;
                if (hop.venue == Venue.V3) {
                    if (hop.tickSpacing != 0) revert BadPath(i);
                    address pool = V3_FACTORY.getPool(from, to, hop.fee);
                    if (pool == address(0)) revert UnknownPool(i, j);
                    id = bytes32(uint256(uint160(pool)));
                } else {
                    id = keccak256(abi.encode(_key(from, hop)));
                }
                for (uint256 k; k < seen; ++k) {
                    if (pools[k] == id) revert RepeatedPool(i, j);
                }
                pools[seen++] = id;
                from = to;
            }
        }
        if (sum != s.amountIn) revert BadSwap();
    }

    /// @dev The hookless v4 pool key of `tokenIn`, the hop's output, fee and tick spacing.
    function _key(address tokenIn, Hop memory hop) private pure returns (PoolKey memory) {
        (address lo, address hi) = tokenIn < hop.tokenOut ? (tokenIn, hop.tokenOut) : (hop.tokenOut, tokenIn);
        return PoolKey({
            currency0: Currency.wrap(lo),
            currency1: Currency.wrap(hi),
            fee: hop.fee,
            tickSpacing: hop.tickSpacing,
            hooks: IHooks(address(0))
        });
    }
}
