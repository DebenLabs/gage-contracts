// SPDX-License-Identifier: GPL-3.0-or-later
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
import {GageV2Vault} from "./GageV2Vault.sol";
import {V2Loan, V2State} from "./V2Types.sol";

/// @notice Owner-authorized atomic whole-position cash-out with a 0.5% fee on cash after cap and financing costs.
/// @dev A separate V3 flash pool leaves V4's manager unlocked while the vault releases collateral. `cashOutDetailed`
///      accepts only allowlisted exact-input routes; `cashOutVia` (D245) sells the whole collateral through one
///      owner-admitted executor, an aggregator's router, with the cap lent by a V3 factory pool the caller names.
///      Preexisting router balances are never spent or paid out by either entry.
contract GageV2CashoutRouter is Ownable2Step, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    GageV2Vault public immutable VAULT;
    IERC20 public immutable USDG;
    address public immutable WETH;
    address public immutable V3_FACTORY;
    IV2FlashPool public immutable FLASH_POOL;
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

    struct Exit {
        uint256 loanId;
        address recipient;
        uint256 minimumNet;
        uint256 maxFinanceFee;
        // Both minimums are ignored: the router takes the whole token collateral with `withdrawCollateral`. They are
        // kept so the `Exit` encoding, and so `cashOutDetailed`'s selector, stay those of the deployed routers.
        uint256 minUnderlying0;
        uint256 minUnderlying1;
        uint256 deadline;
        Route[] routes;
    }

    /// @notice A whole-collateral sale through one executor the owner admits, an aggregator's router (D245).
    struct ExitVia {
        uint256 loanId;
        address recipient;
        uint256 minimumNet;
        uint256 maxFinanceFee;
        uint256 deadline;
        /// @dev The admitted executor and the call made on it: it takes exactly the loan's collateral from this router
        ///      by `transferFrom` and pays USDG to this router.
        address executor;
        bytes data;
        /// @dev The V3 factory's pool of USDG, `flashToken` and `flashFee`, which lends the loan's cap for the call:
        ///      one the executor's route does not use, since a pool is locked while it lends.
        address flashToken;
        uint24 flashFee;
        /// @dev The least USDG the sale must return to this router.
        uint256 minUsdgOut;
    }

    /// @dev What the lending pool's flash carries into its callback: the exit, the collateral token, the cap, and this
    ///      router's USDG and collateral-token balances before the call (never spent or paid out).
    struct ViaCall {
        ExitVia exit;
        address token;
        uint256 cap;
        uint256 cash;
        uint256 held;
    }

    /// @notice Whether a V4 route is currently enabled, keyed by its PoolId, keccak256(abi.encode(key)), as V4RouteSet
    ///         emits it.
    mapping(bytes32 => bool) public v4Allowed;
    /// @notice Whether a V3 pool is currently enabled.
    mapping(address => bool) public v3Allowed;
    bytes32 private _flashHash;
    bytes32 private _swapHash;
    address private _activeV3;
    uint256 private _financeFee;
    /// @notice The executors `cashOutVia` may call, admitted by the owner (D245).
    mapping(address executor => bool allowed) public executorAllowed;
    /// @dev The pool `cashOutVia` borrows from, during that flash only: the one caller the aggregator branch answers.
    address private transient _viaLender;
    /// @dev The hash of the data `cashOutVia` passed to that flash.
    bytes32 private transient _viaHash;
    /// @dev The flash fee, from the aggregator branch to its entry.
    uint256 private transient _viaFee;

    error InvalidConfiguration();
    /// @dev A malformed exit, a caller who does not hold the right, a route that is not admitted, or a recorded
    ///      token left unsold.
    error InvalidExit();
    error BadCallback();
    error InsufficientOutput();
    /// @dev An executor that is not admitted, or one `setExecutor` may never admit.
    error InvalidExecutor();

    event V4RouteSet(bytes32 indexed poolId, bool allowed);
    event V3RouteSet(address indexed pool, bool allowed);
    event ExecutorSet(address indexed executor, bool allowed);
    /// @notice A `cashOutVia` sale: the executor, the pool that lent the cap, the collateral sold, the USDG it returned
    ///         and the flash fee. `CashedOut` follows with the payout.
    event SoldVia(
        uint256 indexed loanId,
        address indexed executor,
        address indexed lender,
        uint256 sold,
        uint256 usdgOut,
        uint256 financeFee
    );
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

    constructor(GageV2Vault vault, IV2FlashPool source, IPoolManager manager, address weth, address admin)
        Ownable(admin)
    {
        VAULT = vault;
        USDG = vault.USDG();
        FEE_RECIPIENT = vault.FEE_RECIPIENT();
        V3_FACTORY = vault.REGISTRY().V3_FACTORY();
        FLASH_POOL = source;
        POOL_MANAGER = manager;
        WETH = weth;
        address t0 = source.token0();
        address t1 = source.token1();
        if (
            weth == address(0) || address(manager).code.length == 0 || source.factory() != V3_FACTORY
                || IUniV3Factory(V3_FACTORY).getPool(t0, t1, source.fee()) != address(source)
                || !((t0 == address(USDG) && t1 == weth) || (t1 == address(USDG) && t0 == weth))
        ) revert InvalidConfiguration();
    }

    /// @notice Admit a reviewed V4 swap path. Revocation never affects ordinary vault repayment or recovery.
    function setV4Route(PoolKey calldata key, bool allowed) external onlyOwner {
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1) || key.tickSpacing <= 0) {
            revert InvalidConfiguration();
        }
        bytes32 id = keccak256(abi.encode(key));
        v4Allowed[id] = allowed;
        emit V4RouteSet(id, allowed);
    }
    /// @notice Admit a canonical V3 pool, excluding the flash source to prevent a locked-pool route.

    function setV3Route(address pool, bool allowed) external onlyOwner {
        if (allowed) {
            IUniV3Pool p = IUniV3Pool(pool);
            if (
                pool == address(FLASH_POOL) || p.factory() != V3_FACTORY
                    || IUniV3Factory(V3_FACTORY).getPool(p.token0(), p.token1(), p.fee()) != pool
            ) revert InvalidConfiguration();
        }
        v3Allowed[pool] = allowed;
        emit V3RouteSet(pool, allowed);
    }

    /// @notice Admit or drop an executor `cashOutVia` may call: an aggregator's router (D245).
    /// @dev Never an address without code, nor one of the contracts this router acts on, pays or holds: itself, the
    ///      vault, USDG, WETH, the PoolManager, the V3 factory, the flash pool, the fee recipient, or the vault's
    ///      registry, rewards, collateral-account implementation, bridge or sGAGE. Dropping needs no check. The
    ///      executor is called with this router as `msg.sender`, so it must be a router that holds no balance or right
    ///      per caller: never a token, nor any contract that credits or lets its caller move what it holds for them.
    /// @param executor The executor.
    /// @param allowed Whether `cashOutVia` may call it.
    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (allowed && (executor.code.length == 0 || _isDependency(executor))) revert InvalidExecutor();
        executorAllowed[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    /// @notice Exercise your approved reclaim right, unwind collateral, repay financing and receive minimum net USDG or
    ///         revert everything. Returns the complete fee breakdown; also usable in an eth_call simulation.
    /// @dev The whole token collateral is taken with the core's `withdrawCollateral`; `minUnderlying0/1` are ignored.
    function cashOutDetailed(Exit calldata exit)
        external
        nonReentrant
        returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net)
    {
        if (VAULT.ownerOf(exit.loanId) != msg.sender) revert InvalidExit();
        if (
            exit.recipient == address(0) || exit.recipient == address(this) || exit.minimumNet == 0
                || exit.deadline < block.timestamp || exit.deadline > block.timestamp + MAX_EXECUTION_WINDOW
                || exit.routes.length > MAX_ROUTES
        ) revert InvalidExit();
        V2Loan memory loan = VAULT.getLoan(exit.loanId);
        if (loan.state != V2State.ACTIVE) revert InvalidExit();
        (address[] memory tokens, uint256[] memory balances) = _snapshot(loan.token, exit.routes);
        bytes memory data = abi.encode(exit, loan.cap, balances);
        _flashHash = keccak256(data);
        bool cash0 = FLASH_POOL.token0() == address(USDG);
        FLASH_POOL.flash(address(this), cash0 ? loan.cap : 0, cash0 ? 0 : loan.cap, data);
        if (_flashHash != bytes32(0)) revert BadCallback();
        // The flash source is repaid; what the router holds above its recorded USDG is the remainder.
        financeFee = _financeFee;
        uint256 remainder = USDG.balanceOf(address(this)) - balances[0];
        gross = remainder + loan.cap + financeFee;
        platformFee = remainder * CASHOUT_FEE_BPS / 10_000;
        net = remainder - platformFee;
        if (net < exit.minimumNet) revert InsufficientOutput();
        // Every non-cash asset must have been consumed; never strand a user's unquoted remainder.
        for (uint256 i = 1; i < tokens.length; ++i) {
            address t = tokens[i];
            if (t != address(USDG) && _balance(t) != balances[i]) revert InvalidExit();
        }
        if (platformFee != 0) USDG.safeTransfer(FEE_RECIPIENT, platformFee);
        USDG.safeTransfer(exit.recipient, net);
        emit CashedOut(exit.loanId, msg.sender, exit.recipient, gross, loan.cap, financeFee, platformFee, net);
    }

    /// @notice Exercise your approved reclaim right and sell the whole collateral through an admitted executor (an
    ///         aggregator's router, D245), with the cap flash-borrowed from the V3 factory's pool of USDG,
    ///         `exit.flashToken` and `exit.flashFee`; repay financing and receive at least `exit.minimumNet` USDG, or
    ///         revert everything. Returns the complete fee breakdown; also usable in an eth_call simulation.
    /// @dev The flash callback reclaims, withdraws the collateral, approves the executor for exactly that amount,
    ///      calls it with `exit.data`, resets the approval and measures by balance: every unit sold, at least
    ///      `exit.minUsdgOut` USDG back, enough to repay the cap and the flash fee. The lending pool is locked while
    ///      it lends, so a route through it reverts: the caller picks one the route does not use. Same holder,
    ///      recipient, minimum and deadline rules, and the same 0.5% fee, as `cashOutDetailed`; one lock for both.
    /// @param exit The sale: the loan, recipient, minimum net, most flash fee, deadline, executor and its call, the
    ///        lending pool's other token and fee tier, and the least USDG the sale must return.
    /// @return gross The USDG the sale returned.
    /// @return financeFee The flash fee.
    /// @return platformFee The 0.5% fee on what remained after the cap and the flash fee.
    /// @return net What the recipient received.
    function cashOutVia(ExitVia calldata exit)
        external
        nonReentrant
        returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net)
    {
        if (VAULT.ownerOf(exit.loanId) != msg.sender) revert InvalidExit();
        if (
            exit.recipient == address(0) || exit.recipient == address(this) || exit.minimumNet == 0
                || exit.deadline < block.timestamp || exit.deadline > block.timestamp + MAX_EXECUTION_WINDOW
        ) revert InvalidExit();
        if (!executorAllowed[exit.executor]) revert InvalidExecutor();
        V2Loan memory loan = VAULT.getLoan(exit.loanId);
        if (loan.state != V2State.ACTIVE || loan.token == address(USDG)) revert InvalidExit();
        address lender = IUniV3Factory(V3_FACTORY).getPool(address(USDG), exit.flashToken, exit.flashFee);
        if (lender == address(0)) revert InvalidExit();
        uint256 cash = USDG.balanceOf(address(this));
        bytes memory data =
            abi.encode(ViaCall(exit, loan.token, loan.cap, cash, IERC20(loan.token).balanceOf(address(this))));
        _viaLender = lender;
        _viaHash = keccak256(data);
        // A canonical pool's token0 is the lower address.
        bool usdg0 = address(USDG) < exit.flashToken;
        IV2FlashPool(lender).flash(address(this), usdg0 ? loan.cap : 0, usdg0 ? 0 : loan.cap, data);
        // The callback clears the lender; a pool that never called back leaves it set.
        if (_viaLender != address(0)) revert BadCallback();
        // As cashOutDetailed: the lender is repaid; what the router holds above its recorded USDG is the remainder.
        financeFee = _viaFee;
        uint256 remainder = USDG.balanceOf(address(this)) - cash;
        gross = remainder + loan.cap + financeFee;
        platformFee = remainder * CASHOUT_FEE_BPS / 10_000;
        net = remainder - platformFee;
        if (net < exit.minimumNet) revert InsufficientOutput();
        if (platformFee != 0) USDG.safeTransfer(FEE_RECIPIENT, platformFee);
        USDG.safeTransfer(exit.recipient, net);
        emit CashedOut(exit.loanId, msg.sender, exit.recipient, gross, loan.cap, financeFee, platformFee, net);
    }

    /// @notice Authenticated callback from the pinned V3 flash source during `cashOutDetailed`, or from the pool
    ///         `cashOutVia` borrows from during its flash.
    /// @dev The aggregator branch answers only while `cashOutVia`'s flash is open, and clears its slots before anything
    ///      else runs; otherwise the `cashOutDetailed` body below runs unchanged.
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        address lender = _viaLender;
        if (lender != address(0)) {
            // cashOutVia's flash only: the pool it called, with the data it passed, once.
            if (msg.sender != lender || keccak256(data) != _viaHash) revert BadCallback();
            _viaLender = address(0);
            _viaHash = bytes32(0);
            _sellVia(abi.decode(data, (ViaCall)), fee0 + fee1);
            return;
        }
        // A cleared (zero) hash rejects every call: no known input hashes to zero.
        if (msg.sender != address(FLASH_POOL) || keccak256(data) != _flashHash) revert BadCallback();
        _flashHash = bytes32(0); // A callback can be consumed once only.
        (Exit memory x, uint256 cap, uint256[] memory balances) = abi.decode(data, (Exit, uint256, uint256[]));
        uint256 financeFee = fee0 + fee1;
        if (financeFee > x.maxFinanceFee) revert InsufficientOutput();
        USDG.forceApprove(address(VAULT), cap);
        VAULT.reclaim(x.loanId, address(this));
        USDG.forceApprove(address(VAULT), 0);
        VAULT.withdrawCollateral(x.loanId, address(this));
        for (uint256 i; i < x.routes.length; ++i) {
            _route(x.routes[i], balances[2 + 2 * i]);
        }
        // The sale must cover the cap and the flash fee before the flash source is repaid. The fee, the net, their
        // checks and payouts run in cashOutDetailed once flash returns, still under the reentrancy guard.
        uint256 owed = cap + financeFee;
        if (USDG.balanceOf(address(this)) - balances[0] < owed) revert InsufficientOutput();
        _financeFee = financeFee;
        USDG.safeTransfer(address(FLASH_POOL), owed);
    }

    /// @notice Authenticated V3 swap payment, limited to the exact input amount and expected pool.
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

    /// @notice Authenticated V4 exact-input execution, with full input consumption and caller-specified output minimum.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // A cleared (zero) hash rejects every call: no known input hashes to zero.
        if (msg.sender != address(POOL_MANAGER) || _swapHash != keccak256(data)) revert BadCallback();
        _swapHash = bytes32(0);
        (Route memory r, uint256 amount) = abi.decode(data, (Route, uint256));
        bool zeroForOne = Currency.unwrap(r.key.currency0) == r.tokenIn;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = POOL_MANAGER.swap(r.key, SwapParams(zeroForOne, -int256(amount), limit), "");
        int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outDelta = zeroForOne ? d.amount1() : d.amount0();
        if (
            inDelta >= 0 || outDelta <= 0 || uint256(-int256(inDelta)) != amount
                || uint256(uint128(outDelta)) < r.minOut
        ) revert InsufficientOutput();
        // As v4-periphery's DeltaResolver: sync first (for ETH it clears any synced currency), then pay and settle.
        POOL_MANAGER.sync(Currency.wrap(r.tokenIn));
        if (r.tokenIn != address(0)) IERC20(r.tokenIn).safeTransfer(address(POOL_MANAGER), amount);
        POOL_MANAGER.settle{value: r.tokenIn == address(0) ? amount : 0}();
        POOL_MANAGER.take(Currency.wrap(r.tokenOut), address(this), uint128(outDelta));
        return "";
    }

    /// @dev `cashOutVia`'s sale, inside the lender's flash: reclaim, withdraw, sell every unit through the executor
    ///      approved for exactly that amount, measure by balance, repay the lender.
    function _sellVia(ViaCall memory c, uint256 financeFee) private {
        if (financeFee > c.exit.maxFinanceFee) revert InsufficientOutput();
        USDG.forceApprove(address(VAULT), c.cap);
        VAULT.reclaim(c.exit.loanId, address(this));
        USDG.forceApprove(address(VAULT), 0);
        VAULT.withdrawCollateral(c.exit.loanId, address(this));
        IERC20 token = IERC20(c.token);
        uint256 amount = token.balanceOf(address(this)) - c.held;
        if (amount == 0) revert InvalidExit();
        uint256 before = USDG.balanceOf(address(this));
        token.forceApprove(c.exit.executor, amount);
        (bool ok, bytes memory reason) = c.exit.executor.call(c.exit.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
        token.forceApprove(c.exit.executor, 0);
        // No dust: every unit sold, and none sent back in.
        if (token.balanceOf(address(this)) != c.held) revert InvalidExit();
        uint256 cashNow = USDG.balanceOf(address(this));
        if (cashNow < before || cashNow - before < c.exit.minUsdgOut) revert InsufficientOutput();
        // The sale must cover the cap and the flash fee before the lender is repaid. The fee, the net, their checks
        // and payouts run in cashOutVia once flash returns, still under the reentrancy guard.
        uint256 owed = c.cap + financeFee;
        if (cashNow - c.cash < owed) revert InsufficientOutput();
        _viaFee = financeFee;
        emit SoldVia(c.exit.loanId, c.exit.executor, msg.sender, amount, cashNow - before, financeFee);
        USDG.safeTransfer(msg.sender, owed);
    }

    /// @dev The contracts this router acts on, pays or holds, which `setExecutor` never admits.
    function _isDependency(address a) private view returns (bool) {
        return a == address(this) || a == address(VAULT) || a == address(USDG) || a == WETH || a == V3_FACTORY
            || a == address(FLASH_POOL) || a == address(POOL_MANAGER) || a == FEE_RECIPIENT
            || a == address(VAULT.REGISTRY()) || a == address(VAULT.REWARDS()) || a == VAULT.ACCOUNT_IMPLEMENTATION()
            || a == address(VAULT.BRIDGE()) || a == address(VAULT.SGAGE());
    }

    function _route(Route memory r, uint256 baseline) private {
        if (r.tokenIn == address(USDG) || r.tokenIn == r.tokenOut || r.minOut == 0) revert InvalidExit();
        uint256 amount = _balance(r.tokenIn) - baseline;
        if (amount == 0) return;
        if (amount > uint256(type(int256).max)) revert InvalidExit();
        uint256 beforeOut = _balance(r.tokenOut);
        if (r.kind == RouteKind.UNWRAP_WETH) {
            if (r.tokenIn != WETH || r.tokenOut != address(0)) revert InvalidExit();
            IWETH9(WETH).withdraw(amount);
        } else if (r.kind == RouteKind.V3) {
            address pool = IUniV3Factory(V3_FACTORY).getPool(r.tokenIn, r.tokenOut, r.v3Fee);
            if (!v3Allowed[pool]) revert InvalidExit();
            bool zeroForOne = IUniV3Pool(pool).token0() == r.tokenIn;
            uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            _activeV3 = pool;
            IV2FlashPool(pool).swap(address(this), zeroForOne, int256(amount), limit, abi.encode(r.tokenIn, amount));
            if (_activeV3 != address(0)) revert BadCallback();
        } else {
            if (!v4Allowed[keccak256(abi.encode(r.key))]) revert InvalidExit();
            // The route must name the admitted key's pair. Admitted keys are strictly sorted and tokenIn != tokenOut,
            // so comparing the sorted pair is the same test as either orientation matching.
            (address lo, address hi) = r.tokenIn < r.tokenOut ? (r.tokenIn, r.tokenOut) : (r.tokenOut, r.tokenIn);
            if (Currency.unwrap(r.key.currency0) != lo || Currency.unwrap(r.key.currency1) != hi) revert InvalidExit();
            bytes memory data = abi.encode(r, amount);
            _swapHash = keccak256(data);
            POOL_MANAGER.unlock(data);
            if (_swapHash != bytes32(0)) revert BadCallback();
        }
        if (_balance(r.tokenIn) != baseline) revert InsufficientOutput();
        if (_balance(r.tokenOut) - beforeOut < r.minOut) revert InsufficientOutput();
    }

    /// @dev Fixed layout: 0 = USDG, 1 = the collateral token (the core's token-only account refuses every position
    ///      kind, D44), 2 + 2i = route i's input, 3 + 2i = route i's output. Repeats are intentional: every entry is
    ///      read in the same pass, so a repeated token holds the same snapshot wherever it appears.
    function _snapshot(address collateral, Route[] calldata routes)
        private
        view
        returns (address[] memory tokens, uint256[] memory balances)
    {
        tokens = new address[](2 + routes.length * 2);
        balances = new uint256[](tokens.length);
        tokens[0] = address(USDG);
        tokens[1] = collateral;
        for (uint256 i; i < routes.length; ++i) {
            tokens[2 + 2 * i] = routes[i].tokenIn;
            tokens[3 + 2 * i] = routes[i].tokenOut;
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
