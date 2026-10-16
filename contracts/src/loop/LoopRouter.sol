// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Collateral, Kind} from "../types/Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {IntentFillRouter} from "../intent/IntentFillRouter.sol";
import {IntentQuoteVerifier} from "../intent/IntentQuoteVerifier.sol";
import {IUniV3Factory, IV2FlashPool} from "../interfaces/IUniV3.sol";

/// @title LoopRouter
/// @notice One-click loop: in one transaction it buys an exact amount of a collateral token with USDG it does not yet
///         have, lists that amount plus the borrower's own for the borrower, funds all four units with a signed plan,
///         pays the principal out to the borrower and takes the purchase's cost back from them. The result is one loan,
///         on the core's own terms, whose collateral is the borrower's tokens and the tokens the loan itself bought.
///         It buys through a Uniswap v4 pool (`loop`), a Uniswap V3 pool (`loopV3`, D242) or an executor the owner
///         admits, an aggregator's router (`loopVia`, D243); the app quotes them all and sends the cheapest.
/// @dev The v4 purchase is a swap whose input is settled last, inside the same unlock, so the PoolManager's flash
///      accounting fronts the USDG until the principal arrives. The V3 purchase is an exact-output swap on the canonical
///      pool of the token, USDG and a fee (the V3 factory's `getPool`): the pool sends the tokens first and calls back
///      for its USDG, which the callback pays from the borrower once the loan has paid them its principal. The purchase
///      through an executor spends USDG flash-borrowed from a V3 factory pool the caller names, one the executor's route
///      does not use, which leaves the PoolManager unlocked for that route; the executor is approved for exactly that
///      USDG and judged only by the balances it leaves, and the flash is repaid from what it did not spend and from the
///      borrower. The router is
///      admitted as an entry router by the core's registry and as a filler by the Intent factory; the signed plan names
///      it as filler and names the id the core issues next, and the loan's terms are the plan's, which the verifier
///      holds the listing to. The plan's evidence commits to the borrower, so a plan priced and screened for one wallet
///      funds no other. Any hookless v4 pool, the factory's V3 pool or an admitted executor's route for the plan's token
///      will do: it sets only what the borrower pays, which their own `maxCost` bounds, never the loan the vaults fund.
///      Exposure is capped where it is held, by the core's registry and the vaults' own limits; the owner can only pause
///      new loops and admit or drop executors. Every entry takes one lock, so one loop runs at a time whichever way it
///      buys. The router holds nothing between calls, and touches no audited contract except through the entry points
///      every entry router and filler uses.
contract LoopRouter is Ownable2Step, Pausable, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice The loop a borrower asks for; the loan's principal, cap and term are the signed plan's.
    struct Loop {
        /// @dev A hookless pool pairing USDG with the plan's collateral token.
        PoolKey key;
        /// @dev Collateral the borrower adds from their wallet; zero loops USDG alone.
        uint256 own;
        /// @dev Collateral bought with USDG, exactly.
        uint256 buy;
        /// @dev The most USDG the purchase may cost.
        uint256 maxCost;
        uint40 fundingDeadline;
        bool withRewards;
        /// @dev The signer's pricing commitment; with the borrower it makes the plan's evidence.
        bytes32 pricing;
    }

    /// @notice A loop that buys through a Uniswap V3 pool (D242); the loan's principal, cap and term are the plan's.
    struct LoopV3 {
        /// @dev The fee tier of the V3 factory's pool pairing USDG with the plan's collateral token.
        uint24 fee;
        /// @dev Collateral the borrower adds from their wallet; zero loops USDG alone.
        uint256 own;
        /// @dev Collateral bought with USDG, exactly.
        uint256 buy;
        /// @dev The most USDG the purchase may cost.
        uint256 maxCost;
        uint40 fundingDeadline;
        bool withRewards;
        /// @dev The signer's pricing commitment; with the borrower it makes the plan's evidence.
        bytes32 pricing;
    }

    /// @notice A loop that buys through an executor the owner admits (D243); the loan's principal, cap and term are the
    ///         plan's.
    struct LoopVia {
        /// @dev The admitted executor and the call it is made with: it sells up to `spend` of this router's USDG for
        ///      the plan's token and sends what it buys back to this router.
        address executor;
        bytes data;
        /// @dev The V3 factory's pool of USDG, `flashToken` and `flashFee`, which lends `spend` for the call: one the
        ///      executor's route does not use, since the pool is locked while it lends.
        address flashToken;
        uint24 flashFee;
        /// @dev The USDG the executor may take, flash-borrowed for the call.
        uint256 spend;
        /// @dev Collateral the borrower adds from their wallet; zero loops USDG alone.
        uint256 own;
        /// @dev Collateral pledged from the purchase: the executor must return at least this, and the rest goes to the
        ///      borrower.
        uint256 buy;
        /// @dev The most USDG the purchase may cost: what the executor spent plus the flash fee.
        uint256 maxCost;
        uint40 fundingDeadline;
        bool withRewards;
        /// @dev The signer's pricing commitment; with the borrower it makes the plan's evidence.
        bytes32 pricing;
    }

    /// @dev What the unlock carries into the callback.
    struct Call {
        address borrower;
        bool usdgIsZero;
        Loop loop;
        IntentQuoteVerifier.Plan plan;
        bytes signature;
        uint256[] maxReserveShares;
    }

    /// @dev What a V3 swap carries into its callback.
    struct V3Call {
        address borrower;
        LoopV3 loop;
        IntentQuoteVerifier.Plan plan;
        bytes signature;
        uint256[] maxReserveShares;
    }

    /// @dev What the flash carries into its callback.
    struct ViaCall {
        address borrower;
        LoopVia loop;
        IntentQuoteVerifier.Plan plan;
        bytes signature;
        uint256[] maxReserveShares;
    }

    GageV2Vault public immutable CORE;
    IntentFillRouter public immutable FILLS;
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The Uniswap V3 factory whose pools `loopV3` buys through and `loopVia` flash-borrows from.
    IUniV3Factory public immutable V3_FACTORY;
    IERC20 public immutable USDG;

    /// @notice The executors `loopVia` may call, admitted by the owner (D243).
    mapping(address executor => bool allowed) public executorAllowed;

    /// @dev The V3 pool a `loopV3` swaps in, for that swap only: the one caller the V3 callback answers.
    address private transient _activeV3;
    /// @dev The pool a `loopVia` borrows from, during that flash only: the one caller the flash callback answers.
    address private transient _activeFlash;
    /// @dev What the V3 and flash callbacks hand back to their entry: the listing id and the purchase's cost.
    uint256 private transient _loopId;
    uint256 private transient _loopCost;

    error InvalidConfiguration();
    error InvalidExecutor();
    error InvalidPool();
    error NothingToBuy();
    error CollateralMismatch(uint256 planned, uint256 looped);
    error NotBorrowersPlan();
    error NotPoolManager();
    error NotPool();
    error PartialPurchase(uint256 bought, uint256 wanted);
    error TooExpensive(uint256 cost, uint256 maxCost);
    error InexactTransfer(uint256 expected, uint256 received);
    error StrayBalance();
    error ListingMismatch(uint256 listed, uint256 planned);

    event Looped(
        uint256 indexed id,
        address indexed borrower,
        address indexed token,
        uint256 own,
        uint256 bought,
        uint256 cost,
        uint128 principal,
        uint128 cap,
        uint32 term
    );
    /// @notice A `loopVia` purchase: the pool that lent, what the executor spent, the flash fee, and the tokens it
    ///         returned beyond the pledge, which went to the borrower.
    event BoughtVia(
        uint256 indexed id,
        address indexed executor,
        address flashPool,
        uint256 spent,
        uint256 flashFee,
        uint256 surplus
    );
    event ExecutorSet(address indexed executor, bool allowed);

    constructor(IntentFillRouter fills, IPoolManager poolManager, IUniV3Factory v3Factory, address initialOwner)
        Ownable(initialOwner)
    {
        if (
            address(fills).code.length == 0 || address(poolManager).code.length == 0
                || address(v3Factory).code.length == 0
        ) revert InvalidConfiguration();
        GageV2Vault core = fills.CORE();
        if (address(core).code.length == 0) revert InvalidConfiguration();
        CORE = core;
        FILLS = fills;
        POOL_MANAGER = poolManager;
        V3_FACTORY = v3Factory;
        USDG = core.USDG();
    }

    /// @notice Buy `l.buy` of the plan's token, list it with `l.own` of the caller's for the caller, fund all four units
    ///         with `plan`, pay the principal to the caller and take the purchase's cost from them; all of it or none.
    /// @dev The caller approves this router for `l.own` of the token and for the cost in USDG, which it takes after the
    ///      principal has been paid to them: what the principal does not cover comes from their wallet. If another
    ///      listing takes the planned id first the call reverts and nothing moves.
    /// @param l The loop: pool, amounts, the most the purchase may cost, the funding deadline, rewards and the pricing
    ///        commitment.
    /// @param plan Funding plan signed by the quote signer for this router, the next id and the caller; the loan's terms.
    /// @param signature The quote signer's signature over `plan`.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The listing id, active when this returns.
    /// @return cost The USDG the purchase cost.
    function loop(
        Loop calldata l,
        IntentQuoteVerifier.Plan calldata plan,
        bytes calldata signature,
        uint256[] calldata maxReserveShares
    ) external nonReentrant whenNotPaused returns (uint256 id, uint256 cost) {
        bool usdgIsZero = _checkPool(l.key, plan.token);
        _checkLoop(l.own, l.buy, l.pricing, plan);

        IERC20 collateral = IERC20(plan.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        _pullOwn(collateral, l.own, held);

        (id, cost) = abi.decode(
            POOL_MANAGER.unlock(abi.encode(Call(msg.sender, usdgIsZero, l, plan, signature, maxReserveShares))),
            (uint256, uint256)
        );
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }
        emit Looped(id, msg.sender, plan.token, l.own, l.buy, cost, plan.principal, plan.cap, plan.term);
    }

    /// @notice As `loop`, buying through the V3 factory's pool of the plan's token, USDG and `l.fee` (D242).
    /// @dev An exact-output swap: the pool sends `l.buy` first and calls back for its USDG, and the callback lists, funds,
    ///      pays the principal to the caller and pays the pool from the caller's USDG. The caller approves this router
    ///      as for `loop`. If another listing takes the planned id first the call reverts and nothing moves.
    /// @param l The loop: the pool's fee tier, amounts, the most the purchase may cost, the funding deadline, rewards and
    ///        the pricing commitment.
    /// @param plan Funding plan signed by the quote signer for this router, the next id and the caller; the loan's terms.
    /// @param signature The quote signer's signature over `plan`.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The listing id, active when this returns.
    /// @return cost The USDG the purchase cost.
    function loopV3(
        LoopV3 calldata l,
        IntentQuoteVerifier.Plan calldata plan,
        bytes calldata signature,
        uint256[] calldata maxReserveShares
    ) external nonReentrant whenNotPaused returns (uint256 id, uint256 cost) {
        address pool = plan.token == address(USDG) ? address(0) : V3_FACTORY.getPool(plan.token, address(USDG), l.fee);
        if (pool == address(0)) revert InvalidPool();
        _checkLoop(l.own, l.buy, l.pricing, plan);

        IERC20 collateral = IERC20(plan.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        _pullOwn(collateral, l.own, held);

        // Paying USDG for the token: from token0 to token1 when USDG sorts first.
        bool usdgIsZero = address(USDG) < plan.token;
        _activeV3 = pool;
        IV2FlashPool(pool)
            .swap(
                address(this),
                usdgIsZero,
                -int256(l.buy),
                usdgIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(V3Call(msg.sender, l, plan, signature, maxReserveShares))
            );
        // The callback clears the pool; a pool that never called back leaves it set.
        if (_activeV3 != address(0)) revert NotPool();
        (id, cost) = (_loopId, _loopCost);
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }
        emit Looped(id, msg.sender, plan.token, l.own, l.buy, cost, plan.principal, plan.cap, plan.term);
    }

    /// @notice As `loop`, buying through an executor the owner admits, an aggregator's router (D243), with USDG
    ///         flash-borrowed from the V3 factory's pool of USDG, `l.flashToken` and `l.flashFee`.
    /// @dev The flash callback approves the executor for exactly `l.spend`, calls it with `l.data`, resets the approval
    ///      and measures by balance what it spent and returned: at least `l.buy` tokens, the rest of which go to the
    ///      caller. It then lists, funds and pays the principal to the caller, and repays the flash from the USDG the
    ///      executor left and the caller's own, whose total cost, spent plus the flash fee, `l.maxCost` bounds. The
    ///      lending pool is locked while it lends, so a route through it reverts: the caller picks one the route does
    ///      not use. The caller approves this router as for `loop`. If another listing takes the planned id first the
    ///      call reverts.
    /// @param l The loop: the executor and its call, the pool that lends and the USDG it may spend, amounts, the most
    ///        the purchase may cost, the funding deadline, rewards and the pricing commitment.
    /// @param plan Funding plan signed by the quote signer for this router, the next id and the caller; the loan's terms.
    /// @param signature The quote signer's signature over `plan`.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The listing id, active when this returns.
    /// @return cost The USDG the purchase cost, the flash fee included.
    function loopVia(
        LoopVia calldata l,
        IntentQuoteVerifier.Plan calldata plan,
        bytes calldata signature,
        uint256[] calldata maxReserveShares
    ) external nonReentrant whenNotPaused returns (uint256 id, uint256 cost) {
        if (!executorAllowed[l.executor]) revert InvalidExecutor();
        address pool =
            plan.token == address(USDG) ? address(0) : V3_FACTORY.getPool(address(USDG), l.flashToken, l.flashFee);
        if (pool == address(0)) revert InvalidPool();
        if (l.spend == 0) revert NothingToBuy();
        _checkLoop(l.own, l.buy, l.pricing, plan);

        IERC20 collateral = IERC20(plan.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        _pullOwn(collateral, l.own, held);

        bool usdgIsZero = address(USDG) < l.flashToken;
        _activeFlash = pool;
        IV2FlashPool(pool)
            .flash(
                address(this),
                usdgIsZero ? l.spend : 0,
                usdgIsZero ? 0 : l.spend,
                abi.encode(ViaCall(msg.sender, l, plan, signature, maxReserveShares))
            );
        // The callback clears the flash pool; a flash that never called back leaves it set.
        if (_activeFlash != address(0)) revert NotPool();
        (id, cost) = (_loopId, _loopCost);
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }
        emit Looped(id, msg.sender, plan.token, l.own, l.buy, cost, plan.principal, plan.cap, plan.term);
    }

    /// @notice The PoolManager's callback inside `loop`: buy, list, fund, pay out, settle.
    /// @dev Only the PoolManager may call it, and it calls back only the account that unlocked it, which for this
    ///      router is `loop` alone.
    /// @param data The encoded `Call`.
    /// @return The listing id and the purchase's cost, encoded.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        Call memory c = abi.decode(data, (Call));
        Loop memory l = c.loop;
        address token = c.plan.token;

        uint256 cost = _buy(l.key, c.usdgIsZero, l.buy, l.maxCost);
        POOL_MANAGER.take(Currency.wrap(token), address(this), l.buy);
        uint256 id = _listAndFill(
            c.borrower, l.own + l.buy, l.fundingDeadline, l.withRewards, c.plan, c.signature, c.maxReserveShares
        );

        CORE.withdrawUSDGFor(c.borrower);
        POOL_MANAGER.sync(Currency.wrap(address(USDG)));
        USDG.safeTransferFrom(c.borrower, address(POOL_MANAGER), cost);
        POOL_MANAGER.settle();
        return abi.encode(id, cost);
    }

    /// @notice The V3 pool's callback inside `loopV3`: the bought tokens are here; list, fund, pay out, pay the pool.
    /// @dev Only the pool `loopV3` is swapping in may call it, once: outside that swap no caller is answered.
    /// @param amount0Delta The pool's token0 owed to it (positive) or sent from it (negative).
    /// @param amount1Delta The pool's token1 owed to it (positive) or sent from it (negative).
    /// @param data The encoded `V3Call`.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activeV3) revert NotPool();
        _activeV3 = address(0);
        V3Call memory c = abi.decode(data, (V3Call));
        LoopV3 memory l = c.loop;

        (int256 paid, int256 got) =
            address(USDG) < c.plan.token ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (got >= 0 || uint256(-got) != l.buy) revert PartialPurchase(got < 0 ? uint256(-got) : 0, l.buy);
        uint256 cost = paid > 0 ? uint256(paid) : 0;
        if (cost > l.maxCost) revert TooExpensive(cost, l.maxCost);
        uint256 id = _listAndFill(
            c.borrower, l.own + l.buy, l.fundingDeadline, l.withRewards, c.plan, c.signature, c.maxReserveShares
        );

        CORE.withdrawUSDGFor(c.borrower);
        USDG.safeTransferFrom(c.borrower, msg.sender, cost);
        (_loopId, _loopCost) = (id, cost);
    }

    /// @notice The lending pool's callback inside `loopVia`: the USDG is here; buy through the executor, list, fund,
    ///         pay out, repay the flash.
    /// @dev Only the pool `loopVia` borrows from may call it, once, during that flash: outside it no caller is answered.
    /// @param fee0 The flash fee in the pool's token0.
    /// @param fee1 The flash fee in the pool's token1.
    /// @param data The encoded `ViaCall`.
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        if (msg.sender != _activeFlash) revert NotPool();
        _activeFlash = address(0);
        ViaCall memory c = abi.decode(data, (ViaCall));
        LoopVia memory l = c.loop;

        (uint256 got, uint256 spent) = _buyVia(l, c.plan.token);
        uint256 fee = fee0 + fee1;
        uint256 cost = spent + fee;
        if (cost > l.maxCost) revert TooExpensive(cost, l.maxCost);
        uint256 id = _listAndFill(
            c.borrower, l.own + l.buy, l.fundingDeadline, l.withRewards, c.plan, c.signature, c.maxReserveShares
        );

        CORE.withdrawUSDGFor(c.borrower);
        // The flash is repaid from the USDG the executor left, then from the borrower.
        if (l.spend > spent) USDG.safeTransfer(msg.sender, l.spend - spent);
        USDG.safeTransferFrom(c.borrower, msg.sender, cost);
        if (got > l.buy) IERC20(c.plan.token).safeTransfer(c.borrower, got - l.buy);
        emit BoughtVia(id, l.executor, msg.sender, spent, fee, got - l.buy);
        (_loopId, _loopCost) = (id, cost);
    }

    /// @notice Admit or drop an executor `loopVia` may call: an aggregator's router (D243).
    /// @dev Never one of the contracts this router acts on or holds: the core, the fill router, USDG, the PoolManager,
    ///      the V3 factory or the router itself. A dropped executor can be called by no new loop.
    /// @param executor The executor.
    /// @param allowed Whether `loopVia` may call it.
    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (
            allowed
                && (executor.code.length == 0
                    || executor == address(this)
                    || executor == address(CORE)
                    || executor == address(FILLS)
                    || executor == address(USDG)
                    || executor == address(POOL_MANAGER)
                    || executor == address(V3_FACTORY))
        ) revert InvalidExecutor();
        executorAllowed[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    /// @notice Stop new loops; loans already open are the core's and are untouched.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allow new loops again.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice The evidence a plan for `borrower` must carry, from the signer's pricing commitment.
    /// @param borrower The wallet the plan was priced and screened for.
    /// @param pricing The signer's pricing commitment.
    function evidenceFor(address borrower, bytes32 pricing) public pure returns (bytes32) {
        return keccak256(abi.encode(borrower, pricing));
    }

    /// @dev The checks both paths make before anything moves: something to buy (within a swap's signed amount), the
    ///      plan's collateral is the loop's, and the plan was priced and screened for the caller.
    function _checkLoop(uint256 own, uint256 buy, bytes32 pricing, IntentQuoteVerifier.Plan calldata plan)
        internal
        view
    {
        if (buy == 0 || buy > uint256(type(int256).max)) revert NothingToBuy();
        if (plan.collateral != own + buy) revert CollateralMismatch(plan.collateral, own + buy);
        if (plan.evidence != evidenceFor(msg.sender, pricing)) revert NotBorrowersPlan();
    }

    /// @dev Take the caller's own collateral, exactly.
    function _pullOwn(IERC20 collateral, uint256 own, uint256 held) internal {
        if (own == 0) return;
        collateral.safeTransferFrom(msg.sender, address(this), own);
        uint256 balance = collateral.balanceOf(address(this));
        uint256 received = balance > held ? balance - held : 0;
        if (received != own) revert InexactTransfer(own, received);
    }

    /// @dev List `amount` of the plan's token for `borrower` on the plan's terms, then fund all four units with the
    ///      plan. The listing must take the plan's id, or another listing would be funded.
    function _listAndFill(
        address borrower,
        uint256 amount,
        uint40 fundingDeadline,
        bool withRewards,
        IntentQuoteVerifier.Plan memory plan,
        bytes memory signature,
        uint256[] memory maxReserveShares
    ) internal returns (uint256 id) {
        IERC20(plan.token).forceApprove(address(CORE), amount);
        id = CORE.listFor(
            Collateral(Kind.ERC20, plan.token, amount),
            plan.principal,
            plan.cap,
            plan.term,
            fundingDeadline,
            withRewards,
            borrower
        );
        IERC20(plan.token).forceApprove(address(CORE), 0);
        if (id != plan.listingId) revert ListingMismatch(id, plan.listingId);
        FILLS.fill(plan, signature, maxReserveShares);
    }

    /// @dev The executor's purchase: approved for exactly `l.spend` USDG and called with `l.data`, it must return at least
    ///      `l.buy` of `token` and take nothing else; returns the tokens it returned and the USDG it spent.
    function _buyVia(LoopVia memory l, address token) internal returns (uint256 got, uint256 spent) {
        uint256 tokens = IERC20(token).balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        USDG.forceApprove(l.executor, l.spend);
        (bool ok, bytes memory reason) = l.executor.call(l.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        USDG.forceApprove(l.executor, 0);
        uint256 tokensNow = IERC20(token).balanceOf(address(this));
        uint256 cashNow = USDG.balanceOf(address(this));
        if (tokensNow < tokens || cashNow > cash) revert StrayBalance();
        (got, spent) = (tokensNow - tokens, cash - cashNow);
        if (got < l.buy) revert PartialPurchase(got, l.buy);
    }

    /// @dev Exact-output purchase of `amount` of the pool's other token for USDG, owed to the PoolManager until settled.
    function _buy(PoolKey memory key, bool usdgIsZero, uint256 amount, uint256 maxCost)
        internal
        returns (uint256 cost)
    {
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: usdgIsZero,
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: usdgIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 paid = usdgIsZero ? delta.amount0() : delta.amount1();
        int128 got = usdgIsZero ? delta.amount1() : delta.amount0();
        if (got < 0 || uint256(uint128(got)) != amount) revert PartialPurchase(got < 0 ? 0 : uint128(got), amount);
        cost = uint256(uint128(-paid));
        if (cost > maxCost) revert TooExpensive(cost, maxCost);
    }

    /// @dev The pool must pair USDG with `token` and have no hooks, so no pool code runs inside a loop; returns whether
    ///      USDG is its currency0.
    function _checkPool(PoolKey calldata key, address token) internal view returns (bool usdgIsZero) {
        address zero = Currency.unwrap(key.currency0);
        address one = Currency.unwrap(key.currency1);
        usdgIsZero = zero == address(USDG);
        if ((usdgIsZero ? one : zero) != token || (usdgIsZero ? zero : one) != address(USDG)) revert InvalidPool();
        if (address(key.hooks) != address(0)) revert InvalidPool();
    }
}
