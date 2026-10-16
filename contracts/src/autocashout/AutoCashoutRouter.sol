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
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";

/// @title AutoCashoutRouter
/// @notice Cashes a loan out for whoever holds its reclaim right, in the last minutes before repayment closes, when its
///         collateral sells for more than its cap: in one transaction it borrows the cap from the Uniswap v4
///         PoolManager, repays the loan, sells the whole collateral in one pool, pays the PoolManager back and credits
///         the gain, less a 0.5% fee, to the holder, who withdraws it. A holder opts in by approving this router for the
///         right (ERC-721 `approve` or `setApprovalForAll` on the core); only the keeper the owner names can run it.
/// @dev The keeper decides off chain, from a reference price, whether a loan is worth cashing out, and passes the least
///      the holder must net; a pool pushed below that reverts the whole call and leaves the loan untouched. A loan the
///      keeper leaves alone ends as it would without this router: repaid by its holder, or defaulted at the window's
///      end. The core is token-only, so repaying (and, on a bridged core, settling the loan's legacy receipt) and
///      releasing collateral never touch the PoolManager, which stays unlocked for this router's own flash and sale. The
///      owner can only pause new cash-outs and name the keeper; credited USDG is the holders' and stays withdrawable
///      while paused.
contract AutoCashoutRouter is Ownable2Step, Pausable, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice The fee on the holder's gain (proceeds above the cap), as `GageV2CashoutRouter.CASHOUT_FEE_BPS`.
    uint16 public constant FEE_BPS = 50;
    /// @notice How long before repayment closes a cash-out may run.
    uint32 public constant WINDOW = 15 minutes;

    GageV2Vault public immutable CORE;
    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable USDG;
    /// @notice The core's fee recipient (the deal fee router), which receives the fee.
    address public immutable FEE_RECIPIENT;
    /// @notice The core's grace, part of when repayment closes.
    uint32 public immutable GRACE;

    /// @notice The only account that may run cash-outs.
    address public keeper;
    /// @notice USDG each account may withdraw.
    mapping(address account => uint256) public owed;
    /// @notice The sum of `owed`: the USDG this router holds for holders.
    uint256 public totalOwed;

    /// @dev What the unlock carries into the callback.
    struct Call {
        uint256 id;
        address token;
        uint128 cap;
        PoolKey key;
        bool usdgIsZero;
    }

    error InvalidConfiguration();
    error InvalidPool();
    error InvalidRecipient();
    error NotKeeper();
    error NotPoolManager();
    error NothingOwed();
    error ZeroMinimum();
    error StrayBalance();
    error NotActive(uint256 id);
    error OutsideWindow(uint256 opens, uint256 closes);
    error PartialSale(uint256 sold, uint256 amount);
    error InsufficientProceeds(uint256 proceeds, uint256 cap);
    error BelowMinimum(uint256 net, uint256 minNet);

    event KeeperSet(address indexed keeper);
    event CashedOut(
        uint256 indexed id,
        address indexed holder,
        address indexed token,
        uint256 sold,
        uint256 proceeds,
        uint128 cap,
        uint256 fee,
        uint256 net
    );
    event Withdrawn(address indexed account, address indexed recipient, uint256 amount);

    /// @param core The token-only core whose loans this router cashes out.
    /// @param poolManager The Uniswap v4 PoolManager that lends the cap and buys the collateral.
    /// @param initialKeeper The account allowed to run cash-outs.
    /// @param initialOwner The account that may pause and name the keeper.
    constructor(GageV2Vault core, IPoolManager poolManager, address initialKeeper, address initialOwner)
        Ownable(initialOwner)
    {
        if (address(core).code.length == 0 || address(poolManager).code.length == 0) revert InvalidConfiguration();
        CORE = core;
        POOL_MANAGER = poolManager;
        USDG = core.USDG();
        FEE_RECIPIENT = core.FEE_RECIPIENT();
        GRACE = core.GRACE();
        _setKeeper(initialKeeper);
    }

    /// @notice Cash out loan `id` for its holder: repay the cap with USDG the PoolManager lends, sell the whole collateral
    ///         in `key`, repay the PoolManager and credit the gain, less the fee, to the holder; all of it or none.
    /// @dev Keeper only, from `WINDOW` before repayment closes until it closes. The holder must have approved this router
    ///      for the right, or the core's `reclaim` reverts.
    /// @param id The loan, active and inside its window.
    /// @param key A hookless pool pairing USDG with the loan's collateral token.
    /// @param minNet The least the holder must be credited; nonzero.
    /// @return net The USDG credited to the holder.
    function cashOut(uint256 id, PoolKey calldata key, uint256 minNet)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 net)
    {
        if (msg.sender != keeper) revert NotKeeper();
        if (minNet == 0) revert ZeroMinimum();
        V2Loan memory l = CORE.getLoan(id);
        if (l.state != V2State.ACTIVE) revert NotActive(id);
        (uint256 opens, uint256 closes) = _window(l);
        if (block.timestamp < opens || block.timestamp >= closes) revert OutsideWindow(opens, closes);
        bool usdgIsZero = _checkPool(key, l.token);
        // The right is burned by the repayment; whoever holds it now is credited.
        address holder = CORE.ownerOf(id);

        IERC20 collateral = IERC20(l.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        uint256 gain = abi.decode(POOL_MANAGER.unlock(abi.encode(Call(id, l.token, l.cap, key, usdgIsZero))), (uint256));
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash + gain) {
            revert StrayBalance();
        }

        uint256 fee = gain * FEE_BPS / 10_000;
        net = gain - fee;
        if (net < minNet) revert BelowMinimum(net, minNet);
        owed[holder] += net;
        totalOwed += net;
        if (fee != 0) USDG.safeTransfer(FEE_RECIPIENT, fee);
        emit CashedOut(id, holder, l.token, l.collateral, uint256(l.cap) + gain, l.cap, fee, net);
    }

    /// @notice The PoolManager's callback inside `cashOut`: borrow the cap, repay, take the collateral, sell, settle.
    /// @dev Only the PoolManager may call it, and it calls back only the account that unlocked it, which for this router
    ///      is `cashOut` alone.
    /// @param data The encoded `Call`.
    /// @return The holder's gain before the fee, encoded.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        Call memory c = abi.decode(data, (Call));
        IERC20 collateral = IERC20(c.token);

        POOL_MANAGER.take(Currency.wrap(address(USDG)), address(this), c.cap);
        USDG.forceApprove(address(CORE), c.cap);
        CORE.reclaim(c.id, address(this));
        USDG.forceApprove(address(CORE), 0);
        uint256 before = collateral.balanceOf(address(this));
        CORE.withdrawCollateral(c.id, address(this));
        uint256 amount = collateral.balanceOf(address(this)) - before;

        uint256 proceeds = _sell(c.key, c.usdgIsZero, amount);
        if (proceeds <= c.cap) revert InsufficientProceeds(proceeds, c.cap);
        POOL_MANAGER.sync(Currency.wrap(c.token));
        collateral.safeTransfer(address(POOL_MANAGER), amount);
        POOL_MANAGER.settle();
        uint256 gain = proceeds - c.cap;
        POOL_MANAGER.take(Currency.wrap(address(USDG)), address(this), gain);
        return abi.encode(gain);
    }

    /// @notice Withdraw all your credited USDG to `recipient`.
    /// @param recipient Where the USDG goes; not zero and not this router.
    function withdraw(address recipient) external nonReentrant {
        _withdraw(msg.sender, recipient);
    }

    /// @notice Deliver an account's credited USDG to that same account. Permissionless, as the core's `withdrawUSDGFor`.
    /// @param account The account whose credit is delivered to itself.
    function withdrawFor(address account) external nonReentrant {
        _withdraw(account, account);
    }

    /// @notice Name the account allowed to run cash-outs.
    /// @param next The new keeper; not zero.
    function setKeeper(address next) external onlyOwner {
        _setKeeper(next);
    }

    /// @notice Stop new cash-outs; credits stay withdrawable and loans stay the core's.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allow cash-outs again.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice When loan `id` may be cashed out: from `opens` until repayment closes at `closes`.
    /// @param id The loan.
    /// @return opens The first second a cash-out may run.
    /// @return closes The second repayment closes; a cash-out must run before it.
    function windowOf(uint256 id) external view returns (uint256 opens, uint256 closes) {
        return _window(CORE.getLoan(id));
    }

    function _window(V2Loan memory l) private view returns (uint256 opens, uint256 closes) {
        closes = uint256(l.fundedAt) + l.term + GRACE;
        opens = closes > WINDOW ? closes - WINDOW : 0;
    }

    /// @dev Exact-input sale of `amount` collateral for USDG, owed to the PoolManager until settled.
    function _sell(PoolKey memory key, bool usdgIsZero, uint256 amount) private returns (uint256 proceeds) {
        if (amount == 0 || amount > uint256(type(int256).max)) revert PartialSale(0, amount);
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: !usdgIsZero,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: usdgIsZero ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        int128 sold = usdgIsZero ? delta.amount1() : delta.amount0();
        int128 got = usdgIsZero ? delta.amount0() : delta.amount1();
        if (sold >= 0 || uint256(uint128(-sold)) != amount || got <= 0) {
            revert PartialSale(sold < 0 ? uint256(uint128(-sold)) : 0, amount);
        }
        proceeds = uint256(uint128(got));
    }

    /// @dev The pool must pair USDG with `token` and have no hooks; returns whether USDG is its currency0.
    function _checkPool(PoolKey calldata key, address token) private view returns (bool usdgIsZero) {
        address zero = Currency.unwrap(key.currency0);
        address one = Currency.unwrap(key.currency1);
        usdgIsZero = zero == address(USDG);
        if ((usdgIsZero ? one : zero) != token || (usdgIsZero ? zero : one) != address(USDG)) revert InvalidPool();
        if (address(key.hooks) != address(0)) revert InvalidPool();
    }

    function _withdraw(address account, address recipient) private {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        uint256 amount = owed[account];
        if (amount == 0) revert NothingOwed();
        delete owed[account];
        totalOwed -= amount;
        USDG.safeTransfer(recipient, amount);
        emit Withdrawn(account, recipient, amount);
    }

    function _setKeeper(address next) private {
        if (next == address(0)) revert InvalidConfiguration();
        keeper = next;
        emit KeeperSet(next);
    }
}
