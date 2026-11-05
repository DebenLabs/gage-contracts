// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IIntentFeeProcessor} from "../interfaces/IIntentFeeProcessor.sol";
import {V4Swapper} from "../token/base/V4Swapper.sol";

/// @notice The protocol fee recipient of an Intent generation that lends a stablecoin with no Uniswap v3 pool:
/// it holds the generation's fees in that asset and converts them, in clips its keeper sizes, into USDG for the GAGE
/// floor, through a path of one or two Uniswap v4 pools.
/// @dev `IntentAssetFeeProcessor`'s face, so `IntentFactory` accepts it as the core's immutable `FEE_RECIPIENT`:
/// `USDG()` is the lent asset (`ASSET`) and `availableUSDG()` its balance. Fees arrive by plain transfer
/// (`IntentVault.claimFees`, `IntentFillRouter.claim`, `GageV2Vault.withdrawUSDGFor`, the cash-out routers' fee).
/// `convert` sells the asset along the owner's path, each hop for at least what it buys at the pool's spot price less
/// the hop's fee and the 1% (`V4Swapper._quoteAtSpot`), and the whole sale for at least the higher of the keeper's
/// minimum and one USDG per unit less the path's fees and `parMarginBps`; then it sends every USDG held here to
/// `forwardTo`, a fee processor of USDG (`DealFeeRouter`, or the rewards bridge that later receives the fees). A hooked
/// dynamic-fee pool's key carries no fee, so the owner sets a fee allowance for its hop, at most 1%; a hook charging
/// more makes `convert` revert, and the fees wait here. No other path moves the asset or USDG. Outside the audit scope.
contract IntentAssetV4FeeProcessor is IIntentFeeProcessor, V4Swapper, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice One pool of the path and the fee its hop is allowed.
    struct Hop {
        PoolKey key;
        /// @dev For a dynamic-fee pool, the fee its hook may charge, in hundredths of a basis point, at most
        ///      `MAX_HOP_FEE_PIPS`; zero for a static-fee pool, whose key carries its fee.
        uint24 feeAllowance;
    }

    /// @notice The most a hop may fall short of its pool's spot price beyond its fee, in basis points: the per-hop
    /// impact bound, as `DealFeeRouter` and `FeeFloor` apply it.
    uint16 public constant MAX_IMPACT_BPS = 100;
    /// @notice The most any hop's fee may be, its pool's own or its allowance, in hundredths of a basis point: 1%.
    uint24 public constant MAX_HOP_FEE_PIPS = 10_000;
    /// @notice The longest path: the asset, at most one token in between, then USDG.
    uint256 public constant MAX_HOPS = 2;
    /// @notice `parMarginBps` at construction: a sale must fetch one USDG per unit less the path's fees and 0.5%.
    uint16 public constant DEFAULT_PAR_MARGIN_BPS = 50;
    /// @notice The widest margin the owner may set: 100%, which leaves the keeper's minimum alone.
    uint16 public constant MAX_PAR_MARGIN_BPS = 10_000;

    /// @notice The generation's lent asset, in which its fees arrive; `USDG()` returns it.
    IERC20 public immutable ASSET;
    /// @notice The USDG a sale buys and `forwardTo` takes.
    IERC20 public immutable FLOOR_USDG;
    /// @dev One unit of USDG and one unit of the asset, in raw units: one asset unit is worth one USDG at par.
    uint256 private immutable USDG_UNIT;
    uint256 private immutable ASSET_UNIT;

    Hop[] private _path;
    /// @notice How far below one USDG per unit of the asset, beyond the path's fees, a sale may fetch, in basis points.
    uint16 public parMarginBps;
    /// @notice Where every USDG goes: a fee processor of USDG.
    address public forwardTo;
    /// @notice The one account that may convert; zero while conversion is stopped.
    address public keeper;
    /// @notice The asset sold, over every conversion.
    uint256 public totalConverted;
    /// @notice The USDG sent to the forward targets, over every conversion.
    uint256 public totalForwarded;

    event PathSet(Hop[] path);
    event ParMarginSet(uint16 bps);
    event ForwardToSet(address indexed target);
    event KeeperSet(address indexed keeper);
    /// @notice One conversion: the asset sold, the USDG it bought, and the USDG sent on (that, and any already held).
    event Converted(address indexed forwardTo, uint256 assetIn, uint256 usdgOut, uint256 forwarded);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error InvalidConfiguration();
    /// @notice Not one or two initialized v4 pools of ERC-20s chaining from the asset to USDG, each hop's fee at most
    /// 1%, an allowance only on a dynamic-fee pool.
    error InvalidPath();
    /// @notice The forward target does not answer as a fee processor of USDG.
    error NotAFeeProcessor();
    error NotKeeper();
    error InvalidAmount();
    error ClipTooLarge(uint256 requested, uint256 available);
    /// @notice A hop sold less than its whole input.
    error PartialSale();
    /// @notice The asset and USDG leave only through `convert`.
    error ProtectedToken();

    /// @param asset The generation's lent asset (the core's `USDG()`).
    /// @param usdg The USDG the floor's processor takes.
    /// @param poolManager The Uniswap v4 PoolManager the path's pools live on.
    /// @param path_ The hops from the asset to USDG.
    /// @param forwardTo_ The fee processor of `usdg` every USDG goes to (`DealFeeRouter`).
    /// @param keeper_ The account that may convert; zero leaves conversion stopped.
    /// @param initialOwner The owner of the settings.
    constructor(
        IERC20 asset,
        IERC20 usdg,
        IPoolManager poolManager,
        Hop[] memory path_,
        address forwardTo_,
        address keeper_,
        address initialOwner
    ) V4Swapper(poolManager) Ownable(initialOwner) {
        if (
            address(asset).code.length == 0 || address(usdg).code.length == 0 || address(asset) == address(usdg)
                || address(poolManager).code.length == 0
        ) revert InvalidConfiguration();
        uint8 assetDecimals = IERC20Metadata(address(asset)).decimals();
        uint8 usdgDecimals = IERC20Metadata(address(usdg)).decimals();
        if (assetDecimals > 18 || usdgDecimals > 18) revert InvalidConfiguration();
        ASSET = asset;
        FLOOR_USDG = usdg;
        ASSET_UNIT = 10 ** assetDecimals;
        USDG_UNIT = 10 ** usdgDecimals;
        _setPath(path_);
        _setParMargin(DEFAULT_PAR_MARGIN_BPS);
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

    /// @notice The hops every sale goes through, from the asset to USDG.
    function path() external view returns (Hop[] memory) {
        return _path;
    }

    /// @notice The least USDG `amountIn` of the asset may fetch, whatever the keeper's minimum: one USDG per unit, less
    /// each hop's fee (its pool's, or its allowance) and `parMarginBps`. The keeper passes the higher of this and
    /// valuation's price less 2% (the v4 pools have no TWAP).
    /// @param amountIn The asset to sell.
    function parFloor(uint256 amountIn) external view returns (uint256) {
        return _parFloor(_path, amountIn);
    }

    /// @notice Sell `amountIn` of the asset for USDG along `path()`, then send every USDG held here to `forwardTo`. The
    /// keeper only, in clips it sizes (gas at most 1% of the value converted). A failed clip changes nothing.
    /// @dev Each hop reverts `TooLittleOut` unless it returns at least what its input buys at its pool's spot price,
    /// less its fee and `MAX_IMPACT_BPS`; the sale then reverts `TooLittleOut` unless it returns at least the higher of
    /// `minUsdgOut` and `parFloor(amountIn)`. Every hop sells its whole input (`PartialSale` otherwise).
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
        Hop[] memory hops = _path;
        uint256 least = Math.max(minUsdgOut, _parFloor(hops, amountIn));
        uint256 held = FLOOR_USDG.balanceOf(address(this));
        // A two-hop path's middle token, and its balance before the sale: never spent, and back there after it.
        IERC20 middle;
        uint256 middleHeld;
        address token = address(ASSET);
        uint256 amount = amountIn;
        for (uint256 i; i < hops.length; ++i) {
            PoolKey memory key = hops[i].key;
            bool zeroForOne = Currency.unwrap(key.currency0) == token;
            token = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
            if (i + 1 < hops.length) {
                middle = IERC20(token);
                middleHeld = middle.balanceOf(address(this));
            }
            amount = _swapExactIn(
                key, zeroForOne, amount, _quoteAtSpot(key, zeroForOne, amount, MAX_IMPACT_BPS, hops[i].feeAllowance)
            );
        }
        if (
            ASSET.balanceOf(address(this)) != available - amountIn
                || (address(middle) != address(0) && middle.balanceOf(address(this)) != middleHeld)
        ) revert PartialSale();
        forwarded = FLOOR_USDG.balanceOf(address(this));
        usdgOut = forwarded - held;
        if (usdgOut < least) revert TooLittleOut(usdgOut, least);
        address target = forwardTo;
        totalConverted += amountIn;
        totalForwarded += forwarded;
        emit Converted(target, amountIn, usdgOut, forwarded);
        FLOOR_USDG.safeTransfer(target, forwarded);
    }

    /// @notice Sell along `hops` from now on: one or two initialized v4 pools of ERC-20s, the first holding the asset,
    /// each next one holding what the one before buys, the last buying USDG. Every hop's fee is at most 1%: a static
    /// pool's own (with no allowance), or the allowance the owner sets for a hooked dynamic-fee pool.
    /// @param hops The new path.
    function setPath(Hop[] calldata hops) external onlyOwner {
        _setPath(hops);
    }

    /// @notice Set how far below one USDG per unit, beyond the path's fees, a sale may fetch: at most 100%, which leaves
    /// the keeper's minimum alone (for a lasting depeg, when the fees would otherwise wait for par).
    /// @param bps The margin, in basis points.
    function setParMargin(uint16 bps) external onlyOwner {
        _setParMargin(bps);
    }

    /// @notice Send USDG to `target` from now on: a fee processor of USDG, checked as `IntentFactory` checks its
    /// protocol recipient (`DealFeeRouter` counts the USDG it holds and batches it into the floor). A later rewards
    /// bridge receives the fees through it.
    function setForwardTo(address target) external onlyOwner {
        _setForwardTo(target);
    }

    /// @notice Name the account that may convert; zero stops conversion until another is named.
    function setKeeper(address keeper_) external onlyOwner {
        _setKeeper(keeper_);
    }

    /// @notice Send `amount` of a token sent here by mistake to `to`: never the asset or USDG, which leave only by
    /// `convert`. A two-hop path's middle token is never held past a conversion, so any here was sent by mistake too.
    function rescue(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (address(token) == address(ASSET) || address(token) == address(FLOOR_USDG)) revert ProtectedToken();
        if (to == address(0)) revert InvalidConfiguration();
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    function _setPath(Hop[] memory hops) private {
        uint256 n = hops.length;
        if (n == 0 || n > MAX_HOPS) revert InvalidPath();
        delete _path;
        address token = address(ASSET);
        for (uint256 i; i < n; ++i) {
            Hop memory hop = hops[i];
            address c0 = Currency.unwrap(hop.key.currency0);
            address c1 = Currency.unwrap(hop.key.currency1);
            // Each hop sells what the one before bought, and buys an ERC-20 that is not the asset: USDG at the end,
            // and only there.
            if (c0 != token && c1 != token) revert InvalidPath();
            token = c0 == token ? c1 : c0;
            if (token == address(0) || token == address(ASSET) || (token == address(FLOOR_USDG)) != (i + 1 == n)) {
                revert InvalidPath();
            }
            if (LPFeeLibrary.isDynamicFee(hop.key.fee)
                    ? hop.feeAllowance > MAX_HOP_FEE_PIPS
                    : (hop.key.fee > MAX_HOP_FEE_PIPS || hop.feeAllowance != 0)) revert InvalidPath();
            // An initialized pool's key is one the PoolManager validated.
            (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(hop.key.toId());
            if (sqrtPriceX96 == 0) revert InvalidPath();
            _path.push(hop);
        }
        emit PathSet(hops);
    }

    function _setParMargin(uint16 bps) private {
        if (bps > MAX_PAR_MARGIN_BPS) revert InvalidConfiguration();
        parMarginBps = bps;
        emit ParMarginSet(bps);
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

    /// @dev One USDG per unit of `amountIn`, less each hop's fee and the margin.
    function _parFloor(Hop[] memory hops, uint256 amountIn) private view returns (uint256 floor) {
        floor = Math.mulDiv(amountIn, USDG_UNIT, ASSET_UNIT);
        for (uint256 i; i < hops.length; ++i) {
            Hop memory hop = hops[i];
            uint24 fee = LPFeeLibrary.isDynamicFee(hop.key.fee) ? hop.feeAllowance : hop.key.fee;
            floor = floor * (LPFeeLibrary.MAX_LP_FEE - fee) / LPFeeLibrary.MAX_LP_FEE;
        }
        floor = floor * (10_000 - parMarginBps) / 10_000;
    }
}
