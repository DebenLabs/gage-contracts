// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IUniV3Factory, IUniV3Pool, IV2FlashPool} from "../interfaces/IUniV3.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";

/// @title V4CashoutRouter
/// @notice Owner-authorized atomic whole-position cash-out for a core whose lent asset has no Uniswap v3 pool to flash
///         from: inside one Uniswap v4 PoolManager unlock, with no flash fee, the router takes the cap, repays
///         the loan, sells the whole collateral, repays the PoolManager and pays the holder what is left, less 0.5%.
/// @dev The twin of `GageV2CashoutRouter`, which is unchanged. A core does not name its router: the holder approves one
///      for the loan's reclaim right (ERC-721 `approve` or `setApprovalForAll` on the core), so a generation can have
///      either or both. Inside the unlock:
///      1. `take` the cap in the core's asset (`USDG`): the only draw on the PoolManager's own balance of it;
///      2. `reclaim`, then `withdrawCollateral`: a token-only core never touches the PoolManager while it repays;
///      3. sell the collateral, through allowlisted routes (`cashOutDetailed`), or through one owner-admitted executor,
///         an aggregator's router, then an optional tail of allowlisted routes into the asset (`cashOutVia`). A
///         v4 route swaps on the PoolManager directly (no nested unlock), hooked pools included; one into the asset
///         leaves its output there as credit against the cap instead of taking it, so a cap can use up to the
///         PoolManager's whole balance of the asset. V3 routes and the WETH unwrap run as in `GageV2CashoutRouter`;
///      4. repay the cap: the credit first, the rest by `sync` and `settle` from the asset the sale brought in, and any
///         credit above the cap taken out.
///      Once the unlock returns, 0.5% of what is left goes to the core's fee recipient and the rest to the recipient.
///      An executor cannot use the PoolManager inside the unlock (its own `unlock` reverts), so an aggregator's route
///      leaves out the PoolManager's sources. Preexisting router balances are never spent or paid out by either entry.
///      Outside the audit scope.
contract V4CashoutRouter is Ownable2Step, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    GageV2Vault public immutable VAULT;
    /// @notice The core's lent asset, in which the cap is repaid and the holder paid: `GageV2CashoutRouter`'s name for
    ///         it, so readers of either router read the same view.
    IERC20 public immutable USDG;
    address public immutable WETH;
    address public immutable V3_FACTORY;
    IPoolManager public immutable POOL_MANAGER;
    address public immutable FEE_RECIPIENT;
    uint16 public constant CASHOUT_FEE_BPS = 50;
    uint8 public constant MAX_ROUTES = 8;
    uint32 public constant MAX_EXECUTION_WINDOW = 15 minutes;

    enum RouteKind {
        V4,
        V3,
        UNWRAP_WETH
    }

    struct Route {
        RouteKind kind;
        address tokenIn;
        address tokenOut;
        uint24 v3Fee;
        PoolKey key;
        uint256 minOut;
    }

    /// @notice `GageV2CashoutRouter`'s exit, field for field, so `cashOutDetailed` keeps its selector and the app's route
    ///         search and simulation reuse as they are.
    struct Exit {
        uint256 loanId;
        address recipient;
        uint256 minimumNet;
        // Ignored, as both minimums below: the PoolManager charges no flash fee, and the router takes the whole token
        // collateral with `withdrawCollateral`. Kept so the `Exit` encoding is that of the V3 routers.
        uint256 maxFinanceFee;
        uint256 minUnderlying0;
        uint256 minUnderlying1;
        uint256 deadline;
        Route[] routes;
    }

    /// @notice A whole-collateral sale through one executor the owner admits, then a tail of admitted routes.
    struct ExitVia {
        uint256 loanId;
        address recipient;
        uint256 minimumNet;
        uint256 deadline;
        /// @dev The admitted executor and the call made on it: it takes exactly the loan's collateral from this router
        ///      by `transferFrom` and pays `tokenOut` to this router.
        address executor;
        bytes data;
        /// @dev What the executor pays: the asset, or the first input of `tail`. Never the collateral.
        address tokenOut;
        /// @dev The least of `tokenOut` the executor must pay.
        uint256 minOut;
        /// @dev Admitted routes from `tokenOut` into the asset, run after the executor's sale; empty when `tokenOut` is
        ///      the asset. They let an aggregator sell the collateral away from the PoolManager, into USDG say, and the
        ///      router finish through pools on it: a Fables pool is the only way into eUSD.
        Route[] tail;
    }

    /// @dev What a cash-out carries into the PoolManager's callback: the loan, its collateral token and cap, the
    ///      executor's sale (a zero executor for `cashOutDetailed`), the routes or tail, and the router's balances
    ///      before the unlock, in `_snapshot`'s layout (never spent or paid out).
    struct Call {
        uint256 loanId;
        address token;
        uint256 cap;
        address executor;
        bytes data;
        address tokenOut;
        uint256 minOut;
        Route[] routes;
        uint256[] balances;
    }

    /// @notice Whether a V4 route is currently enabled, keyed by its PoolId, keccak256(abi.encode(key)), as V4RouteSet
    ///         emits it.
    mapping(bytes32 => bool) public v4Allowed;
    /// @notice Whether a V3 pool is currently enabled.
    mapping(address => bool) public v3Allowed;
    /// @notice The executors `cashOutVia` may call, admitted by the owner.
    mapping(address executor => bool allowed) public executorAllowed;
    /// @dev Set by an entry for its own unlock only: the one moment the PoolManager's callback answers.
    bool private transient _unlocking;
    /// @dev The v3 pool a route is swapping on, during that swap only: the one caller the swap callback pays.
    address private transient _activeV3;

    error InvalidConfiguration();
    /// @dev A malformed exit, a caller who does not hold the right, a route that is not admitted, or a recorded token
    ///      left unsold.
    error InvalidExit();
    error BadCallback();
    error InsufficientOutput();
    /// @dev An executor that is not admitted, or one `setExecutor` may never admit.
    error InvalidExecutor();

    event V4RouteSet(bytes32 indexed poolId, bool allowed);
    event V3RouteSet(address indexed pool, bool allowed);
    event ExecutorSet(address indexed executor, bool allowed);
    /// @notice A `cashOutVia` sale: the executor, what it paid in, the collateral sold and the amount it paid. Its tail
    ///         and `CashedOut`, with the payout, follow.
    event SoldVia(
        uint256 indexed loanId, address indexed executor, address indexed tokenOut, uint256 sold, uint256 amountOut
    );
    /// @notice `GageV2CashoutRouter`'s event, so fee readers count both routers; `financeFee` is always zero here.
    event CashedOut(
        uint256 indexed loanId,
        address indexed owner,
        address indexed recipient,
        uint256 gross,
        uint256 cap,
        uint256 financeFee,
        uint256 platformFee,
        uint256 net
    );

    /// @param vault The token-only core whose loans this router cashes out; its lent asset, fee recipient and its
    ///        registry's v3 factory are read from it.
    /// @param manager The Uniswap v4 PoolManager that lends the cap and runs the v4 routes.
    /// @param weth The WETH the unwrap route withdraws.
    /// @param admin The owner, who admits routes and executors.
    constructor(GageV2Vault vault, IPoolManager manager, address weth, address admin) Ownable(admin) {
        if (address(vault).code.length == 0 || address(manager).code.length == 0 || weth == address(0)) {
            revert InvalidConfiguration();
        }
        VAULT = vault;
        USDG = vault.USDG();
        FEE_RECIPIENT = vault.FEE_RECIPIENT();
        V3_FACTORY = vault.REGISTRY().V3_FACTORY();
        POOL_MANAGER = manager;
        WETH = weth;
    }

    /// @notice Admit or drop a reviewed V4 swap path, hooked pools included (FablesRamp's among them, the amendment of
    ///         The holder's own minimum bounds a fee raised after the quote). Revocation never affects ordinary
    ///         vault repayment or recovery.
    /// @param key The pool, its currencies sorted.
    /// @param allowed Whether routes may swap through it.
    function setV4Route(PoolKey calldata key, bool allowed) external onlyOwner {
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1) || key.tickSpacing <= 0) {
            revert InvalidConfiguration();
        }
        bytes32 id = keccak256(abi.encode(key));
        v4Allowed[id] = allowed;
        emit V4RouteSet(id, allowed);
    }

    /// @notice Admit or drop a canonical V3 pool: one the registry's factory created. Dropping needs no check.
    /// @param pool The pool.
    /// @param allowed Whether routes may swap through it.
    function setV3Route(address pool, bool allowed) external onlyOwner {
        if (allowed) {
            IUniV3Pool p = IUniV3Pool(pool);
            if (p.factory() != V3_FACTORY || IUniV3Factory(V3_FACTORY).getPool(p.token0(), p.token1(), p.fee()) != pool)
            {
                revert InvalidConfiguration();
            }
        }
        v3Allowed[pool] = allowed;
        emit V3RouteSet(pool, allowed);
    }

    /// @notice Admit or drop an executor `cashOutVia` may call: an aggregator's router.
    /// @dev Never an address without code, nor one of the contracts this router acts on, pays or holds: itself, the
    ///      core, its asset, WETH, the PoolManager, the V3 factory, the fee recipient, or the core's registry, rewards,
    ///      collateral-account implementation, bridge or sGAGE. Dropping needs no check. The executor is called with
    ///      this router as `msg.sender`, so it must be a router that holds no balance or right per caller: never a
    ///      token, nor any contract that credits or lets its caller move what it holds for them.
    /// @param executor The executor.
    /// @param allowed Whether `cashOutVia` may call it.
    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (allowed && (executor.code.length == 0 || _isDependency(executor))) revert InvalidExecutor();
        executorAllowed[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    /// @notice Exercise your approved reclaim right, sell the whole collateral through admitted routes, repay the cap the
    ///         PoolManager lent and receive at least `exit.minimumNet` of the asset, or revert everything. Returns the
    ///         complete fee breakdown; also usable in an eth_call simulation.
    /// @dev `GageV2CashoutRouter.cashOutDetailed`'s selector, checks and fee math, with the cap from the PoolManager:
    ///      `financeFee` is always zero and `exit.maxFinanceFee` is ignored, as are `minUnderlying0/1`.
    /// @param exit The loan, recipient, minimum net, deadline (at most 15 minutes ahead) and routes.
    /// @return gross What the sale brought in: what is left plus the cap.
    /// @return financeFee Zero: the PoolManager charges no flash fee.
    /// @return platformFee The 0.5% fee on what was left after the cap.
    /// @return net What the recipient received.
    function cashOutDetailed(Exit calldata exit)
        external
        nonReentrant
        returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net)
    {
        _checkExit(exit.loanId, exit.recipient, exit.minimumNet, exit.deadline, exit.routes.length);
        V2Loan memory loan = _activeLoan(exit.loanId);
        return _cashOut(
            Call(exit.loanId, loan.token, loan.cap, address(0), "", address(USDG), 0, exit.routes, new uint256[](0)),
            exit.recipient,
            exit.minimumNet
        );
    }

    /// @notice Exercise your approved reclaim right and sell the whole collateral through an admitted executor (an
    ///         aggregator's router), then through `exit.tail`'s admitted routes into the asset, with the cap the
    ///         PoolManager lent; repay it and receive at least `exit.minimumNet`, or revert everything. Returns the
    ///         complete fee breakdown; also usable in an eth_call simulation.
    /// @dev Inside the unlock the router reclaims, withdraws the collateral, approves the executor for exactly that
    ///      amount, calls it with `exit.data` (a revert is bubbled), resets the approval and measures by balance: every
    ///      unit sold and none sent back, at least `exit.minOut` of `exit.tokenOut` paid; then the tail runs and the
    ///      cap is repaid. The executor runs inside the PoolManager's unlock, so a route of its own through the
    ///      PoolManager reverts. Same holder, recipient, minimum and deadline rules, the same 0.5% fee and the same lock
    ///      as `cashOutDetailed`.
    /// @param exit The loan, recipient, minimum net, deadline, executor and its call, what it pays and the least of it,
    ///        and the tail.
    /// @return gross What the sale brought in: what is left plus the cap.
    /// @return financeFee Zero: the PoolManager charges no flash fee.
    /// @return platformFee The 0.5% fee on what was left after the cap.
    /// @return net What the recipient received.
    function cashOutVia(ExitVia calldata exit)
        external
        nonReentrant
        returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net)
    {
        _checkExit(exit.loanId, exit.recipient, exit.minimumNet, exit.deadline, exit.tail.length);
        if (!executorAllowed[exit.executor]) revert InvalidExecutor();
        V2Loan memory loan = _activeLoan(exit.loanId);
        if (loan.token == address(USDG) || exit.tokenOut == loan.token) revert InvalidExit();
        return _cashOut(
            Call(
                exit.loanId,
                loan.token,
                loan.cap,
                exit.executor,
                exit.data,
                exit.tokenOut,
                exit.minOut,
                exit.tail,
                new uint256[](0)
            ),
            exit.recipient,
            exit.minimumNet
        );
    }

    /// @notice The PoolManager's callback inside a cash-out: take the cap, repay, take the collateral back, sell it, and
    ///         repay the cap.
    /// @dev Only the PoolManager, and only inside this router's own unlock: it calls back only the account that unlocked
    ///      it, and refuses a second unlock while one is open.
    /// @param data The encoded `Call`.
    /// @return Nothing.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_unlocking) revert BadCallback();
        _unlocking = false;
        Call memory c = abi.decode(data, (Call));
        Currency cash = Currency.wrap(address(USDG));
        POOL_MANAGER.take(cash, address(this), c.cap);
        USDG.forceApprove(address(VAULT), c.cap);
        VAULT.reclaim(c.loanId, address(this));
        USDG.forceApprove(address(VAULT), 0);
        VAULT.withdrawCollateral(c.loanId, address(this));
        if (c.executor != address(0)) _sellVia(c);
        uint256 credit;
        for (uint256 i; i < c.routes.length; ++i) {
            credit += _route(c.routes[i], c.balances[3 + 2 * i]);
        }
        // The cap is repaid from the credit first; the rest comes from the asset the sale brought in, and credit above
        // the cap comes out. The fee, the net, their checks and payouts run in the entry once the unlock returns.
        if (credit > c.cap) {
            POOL_MANAGER.take(cash, address(this), credit - c.cap);
        } else if (credit < c.cap) {
            uint256 owed = c.cap - credit;
            if (USDG.balanceOf(address(this)) < c.balances[0] + owed) revert InsufficientOutput();
            POOL_MANAGER.sync(cash);
            USDG.safeTransfer(address(POOL_MANAGER), owed);
            POOL_MANAGER.settle();
        }
        return "";
    }

    /// @notice Authenticated V3 swap payment, limited to the exact input amount and the pool a route is swapping on.
    function uniswapV3SwapCallback(int256 delta0, int256 delta1, bytes calldata data) external {
        // msg.sender is never zero, so a cleared _activeV3 rejects every caller. _activeV3 is an admitted pool created
        // by V3_FACTORY, whose standard v3 code calls back once per swap (LOK) with the data the router passed.
        if (msg.sender != _activeV3) revert BadCallback();
        (address input, uint256 amount) = abi.decode(data, (address, uint256));
        bool input0 = IUniV3Pool(msg.sender).token0() == input;
        if ((input0 ? delta0 : delta1) != int256(amount) || (input0 ? delta1 : delta0) >= 0) revert BadCallback();
        _activeV3 = address(0);
        IERC20(input).safeTransfer(msg.sender, amount);
    }

    /// @dev The checks both entries make before anything moves: the caller holds the right, and the exit is well formed.
    function _checkExit(uint256 loanId, address recipient, uint256 minimumNet, uint256 deadline, uint256 routes)
        private
        view
    {
        if (VAULT.ownerOf(loanId) != msg.sender) revert InvalidExit();
        if (
            recipient == address(0) || recipient == address(this) || minimumNet == 0 || deadline < block.timestamp
                || deadline > block.timestamp + MAX_EXECUTION_WINDOW || routes > MAX_ROUTES
        ) revert InvalidExit();
    }

    function _activeLoan(uint256 loanId) private view returns (V2Loan memory loan) {
        loan = VAULT.getLoan(loanId);
        if (loan.state != V2State.ACTIVE) revert InvalidExit();
    }

    /// @dev The unlock, then the payout: 0.5% of what the router holds above its recorded asset balance to the fee
    ///      recipient and the rest to the recipient, once every other recorded token is back at its balance.
    ///      `financeFee` stays zero: the PoolManager charges no flash fee.
    function _cashOut(Call memory c, address recipient, uint256 minimumNet)
        private
        returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net)
    {
        address[] memory tokens;
        (tokens, c.balances) = _snapshot(c.token, c.tokenOut, c.routes);
        _unlocking = true;
        POOL_MANAGER.unlock(abi.encode(c));
        // The callback clears it; a manager that never called back leaves it set.
        if (_unlocking) revert BadCallback();
        uint256 remainder = USDG.balanceOf(address(this)) - c.balances[0];
        gross = remainder + c.cap;
        platformFee = remainder * CASHOUT_FEE_BPS / 10_000;
        net = remainder - platformFee;
        if (net < minimumNet) revert InsufficientOutput();
        // Every other recorded token must be back at its balance: never strand a user's unquoted remainder.
        for (uint256 i = 1; i < tokens.length; ++i) {
            address t = tokens[i];
            if (t != address(USDG) && _balance(t) != c.balances[i]) revert InvalidExit();
        }
        if (platformFee != 0) USDG.safeTransfer(FEE_RECIPIENT, platformFee);
        USDG.safeTransfer(recipient, net);
        emit CashedOut(c.loanId, msg.sender, recipient, gross, c.cap, financeFee, platformFee, net);
    }

    /// @dev `cashOutVia`'s sale, inside the unlock: every unit of the collateral through the executor approved for
    ///      exactly that amount, measured by balance.
    function _sellVia(Call memory c) private {
        IERC20 token = IERC20(c.token);
        uint256 held = c.balances[1];
        uint256 amount = token.balanceOf(address(this)) - held;
        if (amount == 0) revert InvalidExit();
        uint256 before = _balance(c.tokenOut);
        token.forceApprove(c.executor, amount);
        (bool ok, bytes memory reason) = c.executor.call(c.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        token.forceApprove(c.executor, 0);
        // No dust: every unit sold, and none sent back in.
        if (token.balanceOf(address(this)) != held) revert InvalidExit();
        uint256 paid = _balance(c.tokenOut);
        if (paid < before || paid - before < c.minOut) revert InsufficientOutput();
        emit SoldVia(c.loanId, c.executor, c.tokenOut, amount, paid - before);
    }

    /// @dev One route: the router's whole balance of its input above the recorded one, exact input. Returns the asset a
    ///      v4 route left in the PoolManager as credit, zero otherwise.
    function _route(Route memory r, uint256 baseline) private returns (uint256 credit) {
        if (r.tokenIn == address(USDG) || r.tokenIn == r.tokenOut || r.minOut == 0) revert InvalidExit();
        uint256 amount = _balance(r.tokenIn) - baseline;
        if (amount == 0) return 0;
        if (amount > uint256(type(int256).max)) revert InvalidExit();
        uint256 out;
        if (r.kind == RouteKind.V4) {
            (out, credit) = _swapV4(r, amount);
        } else {
            uint256 beforeOut = _balance(r.tokenOut);
            if (r.kind == RouteKind.UNWRAP_WETH) {
                if (r.tokenIn != WETH || r.tokenOut != address(0)) revert InvalidExit();
                IWETH9(WETH).withdraw(amount);
            } else {
                address pool = IUniV3Factory(V3_FACTORY).getPool(r.tokenIn, r.tokenOut, r.v3Fee);
                if (!v3Allowed[pool]) revert InvalidExit();
                bool zeroForOne = IUniV3Pool(pool).token0() == r.tokenIn;
                uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
                _activeV3 = pool;
                IV2FlashPool(pool).swap(address(this), zeroForOne, int256(amount), limit, abi.encode(r.tokenIn, amount));
                if (_activeV3 != address(0)) revert BadCallback();
            }
            out = _balance(r.tokenOut) - beforeOut;
        }
        if (_balance(r.tokenIn) != baseline || out < r.minOut) revert InsufficientOutput();
    }

    /// @dev An exact-input swap on the PoolManager inside the open unlock: the input paid from the router's balance, the
    ///      output left as credit when it is the asset and taken out otherwise.
    function _swapV4(Route memory r, uint256 amount) private returns (uint256 out, uint256 credit) {
        if (!v4Allowed[keccak256(abi.encode(r.key))]) revert InvalidExit();
        // The route must name the admitted key's pair. Admitted keys are strictly sorted and tokenIn != tokenOut, so
        // comparing the sorted pair is the same test as either orientation matching.
        (address lo, address hi) = r.tokenIn < r.tokenOut ? (r.tokenIn, r.tokenOut) : (r.tokenOut, r.tokenIn);
        if (Currency.unwrap(r.key.currency0) != lo || Currency.unwrap(r.key.currency1) != hi) revert InvalidExit();
        bool zeroForOne = lo == r.tokenIn;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = POOL_MANAGER.swap(r.key, SwapParams(zeroForOne, -int256(amount), limit), "");
        int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
        if (inDelta >= 0 || outDelta <= 0 || uint256(-int256(inDelta)) != amount) revert InsufficientOutput();
        out = uint256(uint128(outDelta));
        // As v4-periphery's DeltaResolver: sync first (for ETH it clears any synced currency), then pay and settle.
        POOL_MANAGER.sync(Currency.wrap(r.tokenIn));
        if (r.tokenIn != address(0)) IERC20(r.tokenIn).safeTransfer(address(POOL_MANAGER), amount);
        POOL_MANAGER.settle{value: r.tokenIn == address(0) ? amount : 0}();
        if (r.tokenOut == address(USDG)) credit = out;
        else POOL_MANAGER.take(Currency.wrap(r.tokenOut), address(this), out);
    }

    /// @dev The contracts this router acts on, pays or holds, which `setExecutor` never admits.
    function _isDependency(address a) private view returns (bool) {
        return a == address(this) || a == address(VAULT) || a == address(USDG) || a == WETH || a == V3_FACTORY
            || a == address(POOL_MANAGER) || a == FEE_RECIPIENT || a == address(VAULT.REGISTRY())
            || a == address(VAULT.REWARDS()) || a == VAULT.ACCOUNT_IMPLEMENTATION() || a == address(VAULT.BRIDGE())
            || a == address(VAULT.SGAGE());
    }

    /// @dev Fixed layout: 0 = the asset, 1 = the collateral token (the core's token-only account refuses every position
    ///      kind), 2 = what the executor pays (the asset again for `cashOutDetailed`), 3 + 2i = route i's input,
    ///      4 + 2i = route i's output. Repeats are intentional: every entry is read in the same pass, so a repeated
    ///      token holds the same snapshot wherever it appears.
    function _snapshot(address collateral, address tokenOut, Route[] memory routes)
        private
        view
        returns (address[] memory tokens, uint256[] memory balances)
    {
        tokens = new address[](3 + routes.length * 2);
        balances = new uint256[](tokens.length);
        tokens[0] = address(USDG);
        tokens[1] = collateral;
        tokens[2] = tokenOut;
        for (uint256 i; i < routes.length; ++i) {
            tokens[3 + 2 * i] = routes[i].tokenIn;
            tokens[4 + 2 * i] = routes[i].tokenOut;
        }
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = _balance(tokens[i]);
        }
    }

    function _balance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    receive() external payable {}
}
