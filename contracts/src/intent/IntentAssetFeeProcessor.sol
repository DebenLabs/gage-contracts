// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUniV3Factory, IV2FlashPool} from "../interfaces/IUniV3.sol";
import {IIntentFeeProcessor} from "../interfaces/IIntentFeeProcessor.sol";
import {IV4SwapperErrors} from "../interfaces/token/IV4SwapperErrors.sol";

/// @notice The protocol fee recipient of an Intent generation that lends an asset other than USDG (root D249): it holds
/// the generation's fees in that asset and converts them, in clips its keeper sizes, into USDG for the GAGE floor (D57).
/// @dev `IntentFactory` requires its protocol recipient, and the release makes the core's immutable `FEE_RECIPIENT`, a
/// fee processor whose `USDG()` is the core's lent asset: here `USDG()` is that asset (`ASSET`) and `availableUSDG()`
/// its balance. Fees arrive by plain transfer (`IntentVault.claimFees`, `IntentFillRouter.claim`,
/// `GageV2Vault.withdrawUSDGFor`, the cash-out router's fee). `convert` sells the asset through one canonical Uniswap v3
/// ASSET/USDG pool for at least the keeper's minimum and within D57's 1% impact bound at spot, then sends every USDG held
/// here to `forwardTo`, a fee processor of USDG (`DealFeeRouter`), which batches it into the floor. No other path moves
/// the asset or USDG. Outside the audit scope (D240).
contract IntentAssetFeeProcessor is IIntentFeeProcessor, IV4SwapperErrors, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The most a sale may fall short of the pool's spot price beyond its fee, in basis points: D57's per-hop
    /// impact bound, as `DealFeeRouter` and `FeeFloor` apply it.
    uint16 public constant MAX_IMPACT_BPS = 100;
    uint256 private constant FEE_UNITS = 1e6;
    uint256 private constant Q96 = 2 ** 96;

    /// @notice The generation's lent asset, in which its fees arrive; `USDG()` returns it.
    IERC20 public immutable ASSET;
    /// @notice The USDG a sale buys and `forwardTo` takes.
    IERC20 public immutable FLOOR_USDG;
    /// @notice The canonical Uniswap v3 factory whose `getPool` admits the pool.
    address public immutable V3_FACTORY;
    /// @dev Whether the asset is the pool's token0: a canonical pool orders its tokens by address.
    bool private immutable ZERO_FOR_ONE;

    /// @notice The v3 pool every sale goes through.
    address public pool;
    /// @notice That pool's fee tier, in hundredths of a basis point.
    uint24 public poolFee;
    /// @notice Where every USDG goes: a fee processor of USDG.
    address public forwardTo;
    /// @notice The one account that may convert; zero while conversion is stopped.
    address public keeper;
    /// @notice The asset sold, over every conversion.
    uint256 public totalConverted;
    /// @notice The USDG sent to the forward targets, over every conversion.
    uint256 public totalForwarded;
    /// @dev The pool `convert` is swapping on, during that swap only: the one caller the swap callback pays.
    address private transient _swapping;

    event PoolSet(address indexed pool, uint24 fee);
    event ForwardToSet(address indexed target);
    event KeeperSet(address indexed keeper);
    /// @notice One conversion: the asset sold, the USDG it bought, and the USDG sent on (that, and any already held).
    event Converted(
        address indexed pool, address indexed forwardTo, uint256 assetIn, uint256 usdgOut, uint256 forwarded
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error InvalidConfiguration();
    /// @notice Not the canonical v3 pool of the asset and USDG at its fee tier.
    error InvalidPool();
    /// @notice The forward target does not answer as a fee processor of USDG.
    error NotAFeeProcessor();
    error NotKeeper();
    error InvalidAmount();
    error ClipTooLarge(uint256 requested, uint256 available);
    error BadCallback();
    /// @notice The asset and USDG leave only through `convert`.
    error ProtectedToken();

    /// @param asset The generation's lent asset (the core's `USDG()`).
    /// @param usdg The USDG the floor's processor takes.
    /// @param v3Factory The canonical Uniswap v3 factory.
    /// @param pool_ The factory's pool of `asset` and `usdg`, at the tier to sell through.
    /// @param forwardTo_ The fee processor of `usdg` every USDG goes to (`DealFeeRouter`).
    /// @param keeper_ The account that may convert; zero leaves conversion stopped.
    /// @param initialOwner The owner of the settings.
    constructor(
        IERC20 asset,
        IERC20 usdg,
        address v3Factory,
        address pool_,
        address forwardTo_,
        address keeper_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(asset).code.length == 0 || address(usdg).code.length == 0 || address(asset) == address(usdg)
                || v3Factory.code.length == 0
        ) revert InvalidConfiguration();
        ASSET = asset;
        FLOOR_USDG = usdg;
        V3_FACTORY = v3Factory;
        ZERO_FOR_ONE = address(asset) < address(usdg);
        _setPool(pool_);
        _setForwardTo(forwardTo_);
        _setKeeper(keeper_);
    }

    /// @notice The generation's lent asset. `IIntentFeeProcessor` names it USDG: the factory requires this view to equal
    /// the core's `USDG()`, its lent asset. The USDG bought is `FLOOR_USDG`.
    function USDG() external view returns (address) {
        return address(ASSET);
    }

    /// @notice The asset waiting for conversion: this contract's balance of it.
    function availableUSDG() external view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    /// @notice Sell `amountIn` of the asset for USDG through `pool`, then send every USDG held here to `forwardTo`. The
    /// keeper only, in clips it sizes (D57: gas at most 1% of the value converted). A failed clip changes nothing.
    /// @dev Reverts `TooLittleOut` unless the sale returns at least `minUsdgOut` and at least the pool's spot quote less
    /// its fee and `MAX_IMPACT_BPS`: the keeper's minimum guards the price, the spot bound the clip's own impact.
    /// @param amountIn The asset to sell, at most `availableUSDG()`.
    /// @param minUsdgOut The least USDG the sale must return; zero is refused.
    /// @return usdgOut The USDG the sale bought.
    /// @return forwarded The USDG sent to `forwardTo`: the sale's and any already held here.
    function convert(uint256 amountIn, uint256 minUsdgOut)
        external
        nonReentrant
        returns (uint256 usdgOut, uint256 forwarded)
    {
        if (msg.sender != keeper) revert NotKeeper();
        if (amountIn == 0 || minUsdgOut == 0) revert InvalidAmount();
        uint256 available = ASSET.balanceOf(address(this));
        if (amountIn > available) revert ClipTooLarge(amountIn, available);
        address pool_ = pool;
        uint256 least = Math.max(minUsdgOut, _spotMinimum(pool_, amountIn));
        uint256 held = FLOOR_USDG.balanceOf(address(this));
        _swapping = pool_;
        IV2FlashPool(pool_)
            .swap(
                address(this),
                ZERO_FOR_ONE,
                SafeCast.toInt256(amountIn),
                ZERO_FOR_ONE ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(amountIn)
            );
        // The callback clears it; a pool that never called back leaves it set.
        if (_swapping != address(0)) revert BadCallback();
        forwarded = FLOOR_USDG.balanceOf(address(this));
        usdgOut = forwarded - held;
        if (usdgOut < least) revert TooLittleOut(usdgOut, least);
        address target = forwardTo;
        totalConverted += amountIn;
        totalForwarded += forwarded;
        emit Converted(pool_, target, amountIn, usdgOut, forwarded);
        FLOOR_USDG.safeTransfer(target, forwarded);
    }

    /// @notice Pay the pool `convert` is swapping on exactly the asset it sells, once. Any other caller, and any call
    /// outside that swap, is refused.
    /// @dev An exact-input sale: the asset's delta must be the amount `convert` passed, and the USDG delta negative.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        // msg.sender is never zero, so a cleared `_swapping` refuses every caller.
        if (msg.sender != _swapping) revert BadCallback();
        _swapping = address(0);
        uint256 amountIn = abi.decode(data, (uint256));
        (int256 paid, int256 bought) = ZERO_FOR_ONE ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (paid != SafeCast.toInt256(amountIn) || bought >= 0) revert BadCallback();
        ASSET.safeTransfer(msg.sender, amountIn);
    }

    /// @notice Sell through `pool_` from now on: the factory's pool of the asset and USDG at that pool's own fee tier.
    function setPool(address pool_) external onlyOwner {
        _setPool(pool_);
    }

    /// @notice Send USDG to `target` from now on: a fee processor of USDG, checked as `IntentFactory` checks its
    /// protocol recipient (`DealFeeRouter` counts the USDG it holds and batches it into the floor).
    function setForwardTo(address target) external onlyOwner {
        _setForwardTo(target);
    }

    /// @notice Name the account that may convert; zero stops conversion until another is named.
    function setKeeper(address keeper_) external onlyOwner {
        _setKeeper(keeper_);
    }

    /// @notice Send `amount` of a token sent here by mistake to `to`: never the asset or USDG, which leave only by
    /// `convert`.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (address(token) == address(ASSET) || address(token) == address(FLOOR_USDG)) revert ProtectedToken();
        if (to == address(0)) revert InvalidConfiguration();
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    /// @dev The factory's pool of the asset and USDG at the pool's own tier, its tokens in the order `ZERO_FOR_ONE` sells.
    function _setPool(address pool_) private {
        if (pool_.code.length == 0) revert InvalidPool();
        IV2FlashPool p = IV2FlashPool(pool_);
        uint24 fee = p.fee();
        (address token0, address token1) =
            ZERO_FOR_ONE ? (address(ASSET), address(FLOOR_USDG)) : (address(FLOOR_USDG), address(ASSET));
        if (
            p.token0() != token0 || p.token1() != token1
                || IUniV3Factory(V3_FACTORY).getPool(token0, token1, fee) != pool_
        ) revert InvalidPool();
        pool = pool_;
        poolFee = fee;
        emit PoolSet(pool_, fee);
    }

    /// @dev A contract that names USDG and answers `availableUSDG()`; a wallet, this contract (its `USDG()` is the
    /// asset) and a processor of another token are refused, and a missing or reverting view reverts the call.
    function _setForwardTo(address target) private {
        if (target.code.length == 0 || IIntentFeeProcessor(target).USDG() != address(FLOOR_USDG)) {
            revert NotAFeeProcessor();
        }
        // forge-lint: disable-next-line(unused-return)
        IIntentFeeProcessor(target).availableUSDG();
        forwardTo = target;
        emit ForwardToSet(target);
    }

    function _setKeeper(address keeper_) private {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @dev What `amountIn` buys at the pool's spot price, less its fee and `MAX_IMPACT_BPS` (`V4Swapper._quoteAtSpot`).
    function _spotMinimum(address pool_, uint256 amountIn) private view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IV2FlashPool(pool_).slot0();
        uint256 out = ZERO_FOR_ONE
            ? Math.mulDiv(Math.mulDiv(amountIn, sqrtP, Q96), sqrtP, Q96)
            : Math.mulDiv(Math.mulDiv(amountIn, Q96, sqrtP), Q96, sqrtP);
        return Math.mulDiv(out, (FEE_UNITS - poolFee) * (10_000 - MAX_IMPACT_BPS), FEE_UNITS * 10_000);
    }
}
