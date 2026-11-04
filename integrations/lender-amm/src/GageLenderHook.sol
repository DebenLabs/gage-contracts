// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";
import {IGageVault} from "./interfaces/IGageVault.sol";

/// @title GageLenderHook
/// @notice gage's lender-AMM reference hook: OpenZeppelin's `ReHypothecationHook` (uniswap-hooks v1.3.0-rc.0, unaudited) with a gage
/// tier. Each pool currency has its own gage partner vault, curated by the partner, which lends what the pool does not
/// need. Swaps draw on a float the hook holds itself; an allowed keeper refills the float from the vault's free cash
/// and sweeps the excess back, outside swaps. The hook never calls a vault inside a swap.
/// @dev The base contract's yield source for each currency is that float. `_getAmountInYieldSource` counts the float
/// plus the value of the vault shares the hook bought itself (`previewRedeem`), so the LP share price includes lent
/// principal and the interest it has earned, and vault shares sent to the hook count for nothing;
/// `_getMaxWithdrawFromYieldSource` counts the float only, so the just-in-time position, and
/// what a swap can leave owed, never exceeds what the hook already holds. Rebalancing comes from price and arbitrage
/// only: nothing here trades on another venue.
///
/// WARNING: Reference code, unaudited, like the OpenZeppelin contract it extends (marked experimental there). A partner
/// deploys and audits its own copy; gage deploys none on mainnet. See `docs/lender-amm.md` in this repository.
contract GageLenderHook is ReHypothecationHook, Ownable2Step {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientSlot for *;

    /// @notice The pool this hook serves, its two vaults, its first float targets and its owner, at deployment.
    struct Config {
        IPoolManager poolManager;
        /// @dev The gage vault of each currency: its `asset()` is the currency, and `vault0`'s sorts first.
        IGageVault vault0;
        IGageVault vault1;
        uint24 fee;
        int24 tickSpacing;
        uint16 floatBps0;
        uint16 floatBps1;
        /// @dev The partner's Safe: it initializes and seeds the pool, names keepers and sets the float targets.
        address owner;
        string name;
        string symbol;
    }

    uint16 public constant BPS = 10_000;
    /// @notice The bounds of a float target, in basis points of the currency's backing (float plus vault value).
    uint16 public constant MIN_FLOAT_BPS = 100;
    uint16 public constant MAX_FLOAT_BPS = 10_000;

    IGageVault public immutable VAULT0;
    IGageVault public immutable VAULT1;
    Currency public immutable CURRENCY0;
    Currency public immutable CURRENCY1;
    uint24 public immutable FEE;
    int24 public immutable TICK_SPACING;
    /// @notice One whole unit of each currency: the smallest deposit a gage vault takes (IntentVault `MIN_DEPOSIT`
    /// scaled by the asset's decimals), so the smallest sweep.
    uint256 public immutable MIN_SWEEP0;
    uint256 public immutable MIN_SWEEP1;

    /// @dev keccak256(abi.encode(uint256(keccak256("gage.storage.GageLenderHook.swapping")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SWAPPING_SLOT = 0x93d06f021aa7cff29d9e4da149a9835d4a74a879587bf97d30b840f0e65edc00;
    /// @dev The floats before the swap in progress, by the same rule from "gage.storage.GageLenderHook.held0" and "held1".
    bytes32 private constant HELD0_SLOT = 0x0202357fa17c0121511c563b891a215971afd91a6da5ab83cc3490d98405f800;
    bytes32 private constant HELD1_SLOT = 0x36719ba7be550fc609572071ae455b12fe71efcd9f9b1ddf2430700e0ff13000;

    /// @notice Addresses allowed to move the float (`rebalance`) and to claim the vaults' pockets and rewards.
    mapping(address => bool) public isKeeper;
    /// @notice The float each currency is kept at, in basis points of its backing.
    uint16 public floatBps0;
    uint16 public floatBps1;
    /// @dev The most of each float a swap may use (`swapFloatOf`): set by the seed and the keeper's rebalance, scaled
    /// by the share supply on every entry and exit, and moved by each swap as the float is, so an LP's entry deepens the
    /// curve by its share of the float, not by its whole deposit. What the float holds beyond it is the
    /// deposits since the keeper's last rebalance, which the keeper sweeps.
    uint256 internal _swapFloat0;
    uint256 internal _swapFloat1;
    /// @dev The vault shares the hook bought itself (the keeper's sweeps), less those its refills and exits burned:
    /// the only vault shares that are backing. Counting shares someone sends the hook would let a holder of lent vault
    /// shares enter, send them and leave with the LPs' float.
    uint256 internal _vaultShares0;
    uint256 internal _vaultShares1;

    event KeeperSet(address indexed keeper, bool allowed);
    event FloatTargetSet(Currency indexed currency, uint16 bps);
    /// @notice The keeper moved `assets` from the vault's free cash into the float, burning `shares`.
    event Refilled(Currency indexed currency, uint256 assets, uint256 shares);
    /// @notice The keeper moved `assets` of the float's excess into the vault, minting `shares`.
    event Swept(Currency indexed currency, uint256 assets, uint256 shares);
    /// @notice An LP's exit took `assets` beyond the float from the vault's free cash, burning `shares`.
    event ExitFunded(Currency indexed currency, uint256 assets, uint256 shares);
    event PocketsClaimed(Currency indexed currency, uint256[] pocketIds);
    event TokenRecovered(address indexed token, address indexed to, uint256 amount);

    error InvalidConfiguration();
    error UnexpectedPool();
    error NotKeeper();
    /// @dev Called from inside a swap, which only the float may serve.
    error Swapping();
    /// @dev Unreachable when sizing holds: a swap left more owed than the float it was sized by.
    error FloatShort(Currency currency, uint256 amount, uint256 held);
    /// @dev An exit needs more than the float and the vault's free cash hold now; it waits until loans repay.
    error ExitWaitsOnFreeCash(Currency currency, uint256 shortfall, uint256 freeCash);
    /// @dev The vault's pricing is paused, from the end of a loan's term until it is settled (`earliestMaturity`).
    error VaultSettling(Currency currency);
    error PriceOutOfBand(uint160 sqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96);
    error NothingToMove();
    /// @dev Pool backing and the hook's own shares never leave through `recoverToken`.
    error BackingToken();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    modifier notSwapping() {
        if (_swapping()) revert Swapping();
        _;
    }

    constructor(Config memory c) BaseHook(c.poolManager) ERC20(c.name, c.symbol) Ownable(c.owner) {
        Currency currency0 = Currency.wrap(c.vault0.asset());
        Currency currency1 = Currency.wrap(c.vault1.asset());
        // ERC-20 currencies only, sorted as the pool manager sorts them.
        if (currency0.isAddressZero() || !(currency0 < currency1)) revert InvalidConfiguration();
        VAULT0 = c.vault0;
        VAULT1 = c.vault1;
        CURRENCY0 = currency0;
        CURRENCY1 = currency1;
        FEE = c.fee;
        TICK_SPACING = c.tickSpacing;
        MIN_SWEEP0 = 10 ** IERC20Metadata(Currency.unwrap(currency0)).decimals();
        MIN_SWEEP1 = 10 ** IERC20Metadata(Currency.unwrap(currency1)).decimals();
        _setFloatBps(currency0, c.floatBps0);
        _setFloatBps(currency1, c.floatBps1);
    }

    // ---------------------------------------------------------------- pool binding and liquidity

    /// @dev OpenZeppelin warns that initialization is permissionless and binds the hook to the first key it sees:
    /// here only the owner may initialize, and only the pool this hook was built for.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (sender != owner()) revert OwnableUnauthorizedAccount(sender);
        if (
            !(key.currency0 == CURRENCY0) || !(key.currency1 == CURRENCY1) || key.fee != FEE
                || key.tickSpacing != TICK_SPACING
        ) revert UnexpectedPool();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @notice Seed the pool's first liquidity into the floats, minting `sqrt(amount0 * amount1)` shares; the owner
    /// only, so nobody can front-run the seed at a skewed ratio or redeem the virtual residual after a full exit.
    function seedLiquidity(uint256 amount0, uint256 amount1)
        public
        payable
        override
        onlyOwner
        returns (uint256 shares, BalanceDelta delta)
    {
        if (msg.value != 0) revert InvalidMsgValue();
        (shares, delta) = super.seedLiquidity(amount0, amount1);
        _setSwapFloat(CURRENCY0, CURRENCY0.balanceOfSelf());
        _setSwapFloat(CURRENCY1, CURRENCY1.balanceOfSelf());
    }

    /// @notice Add liquidity in the ratio of the hook's backing; the tokens join the floats, and the keeper sweeps
    /// what the floats do not need into the vaults. Refused while either vault is settling (`VaultSettling`).
    function addReHypothecatedLiquidity(uint256 shares, uint256 amount0Max, uint256 amount1Max)
        public
        payable
        override
        returns (BalanceDelta delta)
    {
        if (msg.value != 0) revert InvalidMsgValue();
        uint256 supply = totalSupply();
        delta = super.addReHypothecatedLiquidity(shares, amount0Max, amount1Max);
        _scaleSwapFloats(supply, supply + shares);
    }

    /// @notice Burn `shares` for their part of the backing: the float first, then the vaults' free cash. The swap
    /// float shrinks by the same share.
    function removeReHypothecatedLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min)
        public
        override
        returns (BalanceDelta delta)
    {
        uint256 supply = totalSupply();
        delta = super.removeReHypothecatedLiquidity(shares, amount0Min, amount1Min);
        _scaleSwapFloats(supply, supply - shares);
    }

    // ---------------------------------------------------------------- yield sources: the float, then the vault

    /// @inheritdoc ReHypothecationHook
    /// @dev A currency's gage vault: where the float's excess is lent.
    function getCurrencyYieldSource(Currency currency) public view override returns (address) {
        return address(_vault(currency));
    }

    /// @dev What arrives stays in the float. The tokens are already here, sent by an LP or taken from the pool manager
    /// after a swap; the keeper sweeps the excess into the vault outside swaps (`rebalance`).
    function _depositToYieldSource(Currency, uint256) internal pure override {}

    /// @dev Pay out of the float. Inside a swap that is all there is: the just-in-time position was sized by the
    /// float, so what the swap leaves owed fits in it. Outside a swap (an LP's exit), a shortfall is withdrawn from the
    /// vault's free cash, up to what the hook's own vault shares are worth; an exit that needs more waits until loans
    /// repay.
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal override {
        uint256 held = currency.balanceOfSelf();
        if (held >= amount) return;
        if (_swapping()) revert FloatShort(currency, amount, held);
        IGageVault vault = _vault(currency);
        uint256 shortfall = amount - held;
        uint256 freeCash = _vaultFree(currency);
        if (shortfall > freeCash) revert ExitWaitsOnFreeCash(currency, shortfall, freeCash);
        uint256 shares = vault.withdraw(shortfall, address(this), address(this));
        _setVaultShares(currency, _vaultShares(currency) - shares);
        emit ExitFunded(currency, shortfall, shares);
    }

    /// @dev The float plus the vault shares the hook bought itself at the vault's own price (`previewRedeem`), lent
    /// principal and the interest earned so far included. Refused while the vault's pricing is paused, from the end of
    /// a loan's term until it is settled: the vault refuses its own share moves then, and an LP must not enter or leave
    /// at a price a pending write-off is about to lower. Never read in a swap.
    function _getAmountInYieldSource(Currency currency) internal view override returns (uint256) {
        IGageVault vault = _vault(currency);
        // forge-lint: disable-next-line(block-timestamp) the vault's own clock: the same comparison pauses it
        if (block.timestamp >= vault.earliestMaturity()) revert VaultSettling(currency);
        return currency.balanceOfSelf() + vault.previewRedeem(_vaultShares(currency));
    }

    /// @dev The float only, up to the swap float: swaps are sized by what the hook holds and never read or call a
    /// vault, and never by a deposit beyond its share of the float.
    function _getMaxWithdrawFromYieldSource(Currency currency) internal view override returns (uint256) {
        return Math.min(currency.balanceOfSelf(), currency == CURRENCY0 ? _swapFloat0 : _swapFloat1);
    }

    /// @dev Mark the swap so that the float alone serves it, then let the base add the just-in-time position.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        SWAPPING_SLOT.asBoolean().tstore(true);
        HELD0_SLOT.asUint256().tstore(CURRENCY0.balanceOfSelf());
        HELD1_SLOT.asUint256().tstore(CURRENCY1.balanceOfSelf());
        return super._beforeSwap(sender, key, params, hookData);
    }

    /// @dev The base removes the position and settles both currencies against the float; then the mark is cleared.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector, int128 hookDelta) {
        (selector, hookDelta) = super._afterSwap(sender, key, params, delta, hookData);
        // What the swap took in or paid out moves the swap float as it moved the float.
        _swapFloat0 = _moved(_swapFloat0, HELD0_SLOT.asUint256().tload(), CURRENCY0.balanceOfSelf());
        _swapFloat1 = _moved(_swapFloat1, HELD1_SLOT.asUint256().tload(), CURRENCY1.balanceOfSelf());
        SWAPPING_SLOT.asBoolean().tstore(false);
    }

    // ---------------------------------------------------------------- the keeper

    /// @notice Move one currency's float toward its target: refill it from the vault's free cash, up to the vault's
    /// `maxWithdraw` and what the hook's own vault shares are worth, or sweep its excess into the vault, at least one
    /// whole unit. Allowed keepers only, outside
    /// swaps, and only while the pool's price is within the keeper's band, so that a price pushed away from the market
    /// cannot make the keeper deploy more liquidity there. Reverts with the vault's own error at a refusal moment.
    /// @return moved The assets moved: positive into the float, negative into the vault.
    function rebalance(Currency currency, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96)
        external
        nonReentrant
        onlyKeeper
        notSwapping
        returns (int256 moved)
    {
        PoolKey memory key = getPoolKey();
        if (address(key.hooks) == address(0)) revert NotInitialized();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 < minSqrtPriceX96 || sqrtPriceX96 > maxSqrtPriceX96) {
            revert PriceOutOfBand(sqrtPriceX96, minSqrtPriceX96, maxSqrtPriceX96);
        }
        IGageVault vault = _vault(currency);
        moved = rebalanceAmount(currency);
        if (moved > 0) {
            // forge-lint: disable-next-line(unsafe-typecast) positive here, and built from a uint256
            uint256 assets = uint256(moved);
            uint256 shares = vault.withdraw(assets, address(this), address(this));
            _setVaultShares(currency, _vaultShares(currency) - shares);
            emit Refilled(currency, assets, shares);
        } else if (moved < 0) {
            // forge-lint: disable-next-line(unsafe-typecast) negative here, and built from a uint256
            uint256 assets = uint256(-moved);
            IERC20 token = IERC20(Currency.unwrap(currency));
            token.forceApprove(address(vault), assets);
            uint256 shares = vault.deposit(assets, address(this));
            _setVaultShares(currency, _vaultShares(currency) + shares);
            emit Swept(currency, assets, shares);
        } else {
            revert NothingToMove();
        }
        // The float the keeper leaves, at the target share of the backing, is what swaps may use until the next.
        _setSwapFloat(currency, currency.balanceOfSelf());
    }

    /// @notice What `rebalance` would move now, before the price band: toward the target float, a refill bounded by
    /// the vault's `maxWithdraw` and the hook's own vault shares, a sweep only of at least one whole unit. Zero when
    /// nothing would move.
    function rebalanceAmount(Currency currency) public view returns (int256) {
        uint256 held = currency.balanceOfSelf();
        uint256 target = targetFloat(currency);
        if (held < target) {
            return SafeCast.toInt256(Math.min(target - held, _vaultFree(currency)));
        }
        uint256 excess = held - target;
        return excess < _minSweep(currency) ? int256(0) : -SafeCast.toInt256(excess);
    }

    /// @notice The float a currency is kept at: its target share of the currency's backing.
    function targetFloat(Currency currency) public view returns (uint256) {
        return Math.mulDiv(_getAmountInYieldSource(currency), _floatBps(currency), BPS);
    }

    /// @notice The most of a currency's float a swap may use: what the seed or the keeper left, scaled by the share
    /// supply since. A swap uses the lesser of it and the float.
    function swapFloatOf(Currency currency) external view returns (uint256) {
        _vault(currency);
        return currency == CURRENCY0 ? _swapFloat0 : _swapFloat1;
    }

    /// @notice The tokens of a currency the hook holds for swaps.
    function floatOf(Currency currency) external view returns (uint256) {
        _vault(currency);
        return currency.balanceOfSelf();
    }

    /// @notice A currency's backing of the LP shares: the float plus the vault shares the hook bought itself, at the
    /// vault's price. Reverts `VaultSettling` while that vault's pricing is paused.
    function backingOf(Currency currency) external view returns (uint256) {
        return _getAmountInYieldSource(currency);
    }

    /// @notice The vault shares of a currency that are backing: those the hook bought itself, less those its refills
    /// and exits burned. Vault shares sent to the hook are not counted.
    function vaultSharesOf(Currency currency) external view returns (uint256) {
        _vault(currency);
        return _vaultShares(currency);
    }

    /// @notice Claim side pockets the hook holds in a currency's vault: earnings claims and write-off backing
    /// in the vault's asset join the float; recovered collateral, another token, is passed on by the owner
    /// (`recoverToken`). Keepers or the owner, so that the step a claim adds to the share price comes at their time.
    function claimPockets(Currency currency, uint256[] calldata pocketIds) external nonReentrant notSwapping {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _vault(currency).claimPockets(pocketIds);
        emit PocketsClaimed(currency, pocketIds);
    }

    /// @notice Collect the sGAGE the hook's shares earned in a currency's vault. It is not pool backing: the owner
    /// passes it on (`recoverToken`), to the LPs as the partner decides. Keepers or the owner.
    function claimVaultRewards(Currency currency) external nonReentrant notSwapping returns (uint256) {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        return _vault(currency).claimRewards();
    }

    // ---------------------------------------------------------------- owner

    /// @notice Allow or remove a keeper.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert InvalidConfiguration();
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Set a currency's float target, in basis points of its backing, within `MIN_FLOAT_BPS`-`MAX_FLOAT_BPS`.
    function setFloatBps(Currency currency, uint16 bps) external onlyOwner {
        _setFloatBps(currency, bps);
    }

    /// @notice Send a token that is not pool backing, such as sGAGE rewards or recovered collateral, to `to`. Never a
    /// pool currency, a vault's shares or the hook's own shares.
    function recoverToken(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        address t = address(token);
        if (
            t == Currency.unwrap(CURRENCY0) || t == Currency.unwrap(CURRENCY1) || t == address(VAULT0)
                || t == address(VAULT1) || t == address(this)
        ) revert BackingToken();
        token.safeTransfer(to, amount);
        emit TokenRecovered(t, to, amount);
    }

    /// @dev ERC-20 currencies only: the vaults take no native currency.
    receive() external payable override {
        revert InvalidMsgValue();
    }

    // ---------------------------------------------------------------- internals

    function _vault(Currency currency) internal view returns (IGageVault) {
        if (currency == CURRENCY0) return VAULT0;
        if (currency == CURRENCY1) return VAULT1;
        revert InvalidConfiguration();
    }

    function _floatBps(Currency currency) internal view returns (uint16) {
        return currency == CURRENCY0 ? floatBps0 : floatBps1;
    }

    function _minSweep(Currency currency) internal view returns (uint256) {
        return currency == CURRENCY0 ? MIN_SWEEP0 : MIN_SWEEP1;
    }

    function _setFloatBps(Currency currency, uint16 bps) internal {
        if (bps < MIN_FLOAT_BPS || bps > MAX_FLOAT_BPS) revert InvalidConfiguration();
        if (currency == CURRENCY0) floatBps0 = bps;
        else if (currency == CURRENCY1) floatBps1 = bps;
        else revert InvalidConfiguration();
        emit FloatTargetSet(currency, bps);
    }

    function _setSwapFloat(Currency currency, uint256 amount) internal {
        if (currency == CURRENCY0) _swapFloat0 = amount;
        else _swapFloat1 = amount;
    }

    function _vaultShares(Currency currency) internal view returns (uint256) {
        return currency == CURRENCY0 ? _vaultShares0 : _vaultShares1;
    }

    function _setVaultShares(Currency currency, uint256 shares) internal {
        if (currency == CURRENCY0) _vaultShares0 = shares;
        else _vaultShares1 = shares;
    }

    /// @dev What the vault can pay the hook now, never more than the vault shares the hook bought itself are worth.
    function _vaultFree(Currency currency) internal view returns (uint256) {
        IGageVault vault = _vault(currency);
        return Math.min(vault.maxWithdraw(address(this)), vault.previewRedeem(_vaultShares(currency)));
    }

    /// @dev `swapFloat` moved by a float's change from `held` to `now_`, never below zero.
    function _moved(uint256 swapFloat, uint256 held, uint256 now_) internal pure returns (uint256) {
        if (now_ >= held) return swapFloat + (now_ - held);
        uint256 out = held - now_;
        return out >= swapFloat ? 0 : swapFloat - out;
    }

    /// @dev Each swap float by `after_ / before_`, the change in the share supply, rounded down.
    function _scaleSwapFloats(uint256 before_, uint256 after_) internal {
        _swapFloat0 = Math.mulDiv(_swapFloat0, after_, before_);
        _swapFloat1 = Math.mulDiv(_swapFloat1, after_, before_);
    }

    function _swapping() internal view returns (bool) {
        return SWAPPING_SLOT.asBoolean().tload();
    }
}
