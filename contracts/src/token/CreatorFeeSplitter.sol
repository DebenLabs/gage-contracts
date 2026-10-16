// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {V4Swapper} from "./base/V4Swapper.sol";
import {ICreatorFeeSplitter} from "../interfaces/token/ICreatorFeeSplitter.sol";
import {IsGAGE} from "../interfaces/token/IsGAGE.sol";
import {PositionMath} from "../libraries/PositionMath.sol";

/// @title CreatorFeeSplitter
/// @notice The Pons creator wallet, or its forwarding target. Every ETH received splits in half: one half to the
///         operations wallet (less the caller's bounty, so the floor half is always exactly 50%, T7), the other
///         converted ETH → GAGE within the impact bound and parked as GAGE-only liquidity in the GAGE/sGAGE pool
///         in the band just under the market: the sGAGE floor (D46). Bands are owned by this contract and there is
///         no way to remove them; as the market rises, new bands sit higher, and older bands stay as a ladder of
///         floors. When the market falls through a band, the sGAGE that band bought is burned by anyone (`sweep`),
///         so the ladder only ever bids for sGAGE and never sells it back.
/// @dev The GAGE-only side of a band depends on the pool's currency order: above the current tick when GAGE is
///      currency0, below it when GAGE is currency1. Floor bands carry no LP reward weight (LPRewards.setFloor).
contract CreatorFeeSplitter is ICreatorFeeSplitter, V4Swapper, Ownable2Step, ReentrancyGuardTransient, IERC721Receiver {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint16 public constant OPS_SHARE_BPS = 5000;
    uint16 public constant MAX_IMPACT_BPS = 100;
    uint16 public constant MAX_BOUNTY_BPS = 100;
    /// @notice Width of a floor band: 480 ticks, about 4.9% of price. Eight spacings of a 60-tick pool.
    int24 public constant BAND_TICKS = 480;

    address public immutable OPS_WALLET;
    IERC20 public immutable SGAGE;
    address public immutable GAGE;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    bool public immutable GAGE_IS_CURRENCY0;
    int24 public immutable SPACING;
    uint24 public immutable LAUNCH_POOL_FEE_PIPS;
    /// @notice Where creator fees are pulled from when Pons is pull-based; zero when Pons pushes ETH here. VERIFY.
    address public immutable PONS_CLAIM_TARGET;
    bytes internal _ponsClaimCalldata;

    PoolKey internal _gageEth;
    PoolKey internal _gageSgage;
    uint256 public threshold;
    uint16 public bountyBps;

    uint256[] public floorTokenIds;
    mapping(uint256 tokenId => Band) public bands;
    mapping(bytes32 bandKey => uint256 tokenId) internal _bandTokenId;

    error PoolMismatch();
    error OpsTransferFailed();
    error BountyOutOfBounds();

    struct Params {
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
        address opsWallet;
        IERC20 sgage;
        address gage;
        PoolKey gageEth;
        PoolKey gageSgage;
        uint24 launchPoolFeePips;
        address ponsClaimTarget;
        bytes ponsClaimCalldata;
        uint256 threshold;
        uint16 bountyBps;
        address initialOwner;
    }

    constructor(Params memory p) V4Swapper(p.poolManager) Ownable(p.initialOwner) {
        if (
            p.opsWallet == address(0) || address(p.positionManager) == address(0) || address(p.permit2) == address(0)
                || address(p.sgage) == address(0) || p.gage == address(0)
        ) revert ZeroAddress();
        if (!p.gageEth.currency0.isAddressZero() || Currency.unwrap(p.gageEth.currency1) != p.gage) {
            revert PoolMismatch();
        }
        address c0 = Currency.unwrap(p.gageSgage.currency0);
        address c1 = Currency.unwrap(p.gageSgage.currency1);
        if (!((c0 == p.gage && c1 == address(p.sgage)) || (c0 == address(p.sgage) && c1 == p.gage))) {
            revert PoolMismatch();
        }
        if (p.bountyBps > MAX_BOUNTY_BPS) revert BountyOutOfBounds();
        if (p.gageSgage.tickSpacing <= 0 || BAND_TICKS % p.gageSgage.tickSpacing != 0) revert PoolMismatch();
        OPS_WALLET = p.opsWallet;
        SGAGE = p.sgage;
        GAGE = p.gage;
        POSM = p.positionManager;
        PERMIT2 = p.permit2;
        GAGE_IS_CURRENCY0 = c0 == p.gage;
        SPACING = p.gageSgage.tickSpacing;
        LAUNCH_POOL_FEE_PIPS = p.launchPoolFeePips;
        PONS_CLAIM_TARGET = p.ponsClaimTarget;
        _ponsClaimCalldata = p.ponsClaimCalldata;
        _gageEth = p.gageEth;
        _gageSgage = p.gageSgage;
        threshold = p.threshold;
        bountyBps = p.bountyBps;
        // the PositionManager pulls GAGE through Permit2
        IERC20(p.gage).forceApprove(address(p.permit2), type(uint256).max);
        p.permit2.approve(p.gage, address(p.positionManager), type(uint160).max, type(uint48).max);
        emit ThresholdSet(p.threshold);
    }

    /// @inheritdoc ICreatorFeeSplitter
    function claim() external nonReentrant returns (uint256 amount) {
        if (PONS_CLAIM_TARGET == address(0)) return 0;
        uint256 before = address(this).balance;
        (bool ok,) = PONS_CLAIM_TARGET.call(_ponsClaimCalldata);
        require(ok, "pons claim failed");
        amount = address(this).balance - before;
        emit Claimed(amount);
    }

    /// @inheritdoc ICreatorFeeSplitter
    function split() external nonReentrant returns (uint256 gageToFloor) {
        uint256 total = address(this).balance;
        if (total < threshold || total == 0) revert BelowThreshold(total, threshold);

        uint256 toFloorEth = total - (total * OPS_SHARE_BPS) / 10_000;
        uint256 opsHalf = total - toFloorEth;
        uint256 bounty = (opsHalf * bountyBps) / 10_000;
        uint256 toOps = opsHalf - bounty;

        // ETH (currency0) → GAGE (currency1) on the launch pool, within the impact bound
        _swapExactIn(
            _gageEth, true, toFloorEth, _quoteAtSpot(_gageEth, true, toFloorEth, MAX_IMPACT_BPS, LAUNCH_POOL_FEE_PIPS)
        );
        // everything this contract holds in GAGE (the buy plus any fees kept from a sweep) goes into the floor
        gageToFloor = _addFloor(IERC20(GAGE).balanceOf(address(this)));

        (bool ok,) = OPS_WALLET.call{value: toOps}("");
        if (!ok) revert OpsTransferFailed();
        if (bounty > 0) {
            (ok,) = msg.sender.call{value: bounty}("");
            if (!ok) revert OpsTransferFailed();
        }
        emit Split(msg.sender, total, toOps, gageToFloor, bounty);
    }

    /// @inheritdoc ICreatorFeeSplitter
    function sweep(uint256 tokenId) external nonReentrant returns (uint256 sgageBurned) {
        Band storage b = bands[tokenId];
        if (b.liquidity == 0 && !b.swept) revert NotAFloorBand(tokenId);
        if (b.swept) revert AlreadySwept(tokenId);
        (, int24 tick,,) = POOL_MANAGER.getSlot0(_gageSgage.toId());
        // the band has turned entirely into sGAGE once the tick is past it on the sGAGE side
        bool through = GAGE_IS_CURRENCY0 ? tick >= b.tickUpper : tick < b.tickLower;
        if (!through) revert FloorStillHolding(tokenId, tick);

        uint128 liquidity = b.liquidity;
        b.swept = true;
        b.liquidity = 0;
        uint256 gageKept;
        (sgageBurned, gageKept) = _decreaseAndBurn(tokenId, liquidity);
        emit FloorSwept(tokenId, sgageBurned, gageKept);
    }

    /// @inheritdoc ICreatorFeeSplitter
    function collect(uint256 tokenId) external nonReentrant returns (uint256 sgageBurned, uint256 gageKept) {
        Band storage b = bands[tokenId];
        if (b.liquidity == 0) revert NotAFloorBand(tokenId);
        (sgageBurned, gageKept) = _decreaseAndBurn(tokenId, 0);
    }

    function setThreshold(uint256 threshold_) external onlyOwner {
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    function setBounty(uint16 bountyBps_) external onlyOwner {
        if (bountyBps_ > MAX_BOUNTY_BPS) revert BountyOutOfBounds();
        bountyBps = bountyBps_;
    }

    // ----------------------------------------------------------------- views

    /// @inheritdoc ICreatorFeeSplitter
    function bandNow() public view returns (int24 tickLower, int24 tickUpper) {
        (, int24 tick,,) = POOL_MANAGER.getSlot0(_gageSgage.toId());
        return _bandFor(tick);
    }

    function floorCount() external view returns (uint256) {
        return floorTokenIds.length;
    }

    /// @inheritdoc ICreatorFeeSplitter
    function floorBacking() external view returns (uint256 gage, uint256 sgage) {
        (uint160 sqrtP,,,) = POOL_MANAGER.getSlot0(_gageSgage.toId());
        uint256 n = floorTokenIds.length;
        for (uint256 i = 0; i < n; ++i) {
            Band storage b = bands[floorTokenIds[i]];
            if (b.liquidity == 0) continue;
            (uint256 a0, uint256 a1) = PositionMath.amountsForLiquidity(
                sqrtP, TickMath.getSqrtPriceAtTick(b.tickLower), TickMath.getSqrtPriceAtTick(b.tickUpper), b.liquidity
            );
            (uint256 g, uint256 s) = GAGE_IS_CURRENCY0 ? (a0, a1) : (a1, a0);
            gage += g;
            sgage += s;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ----------------------------------------------------------------- internal

    /// @dev The GAGE-only band adjacent to `tick`: strictly above it when GAGE is currency0 (a position whose lower
    ///      tick is above the current tick holds only token0), at or below it when GAGE is currency1.
    function _bandFor(int24 tick) internal view returns (int24 tickLower, int24 tickUpper) {
        if (GAGE_IS_CURRENCY0) {
            tickLower = _ceilTo(tick + 1);
            tickUpper = tickLower + BAND_TICKS;
        } else {
            tickUpper = _floorTo(tick);
            tickLower = tickUpper - BAND_TICKS;
        }
    }

    function _addFloor(uint256 gage) internal returns (uint256 used) {
        if (gage == 0) return 0;
        (, int24 tick,,) = POOL_MANAGER.getSlot0(_gageSgage.toId());
        (int24 lower, int24 upper) = _bandFor(tick);
        uint128 liquidity = _liquidityForGage(lower, upper, gage);
        if (liquidity == 0) return 0;

        bytes32 key = keccak256(abi.encode(lower, upper));
        uint256 tokenId = _bandTokenId[key];
        uint256 before = IERC20(GAGE).balanceOf(address(this));
        if (tokenId == 0 || bands[tokenId].swept) {
            tokenId = POSM.nextTokenId();
            POSM.modifyLiquidities(_mintCall(lower, upper, liquidity), block.timestamp);
            _bandTokenId[key] = tokenId;
            floorTokenIds.push(tokenId);
            bands[tokenId] = Band({tickLower: lower, tickUpper: upper, liquidity: liquidity, swept: false});
        } else {
            POSM.modifyLiquidities(_increaseCall(tokenId, liquidity), block.timestamp);
            bands[tokenId].liquidity += liquidity;
        }
        used = before - IERC20(GAGE).balanceOf(address(this));
        emit FloorAdded(tokenId, lower, upper, used, bands[tokenId].liquidity);
    }

    /// @dev The band never straddles the price, so its liquidity is set by the GAGE side alone.
    function _liquidityForGage(int24 lower, int24 upper, uint256 gage) internal view returns (uint128) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        return GAGE_IS_CURRENCY0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtA, sqrtB, gage)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, gage);
    }

    function _mintCall(int24 lower, int24 upper, uint128 liquidity) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _gageSgage, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, address(this), bytes("")
        );
        params[1] = abi.encode(_gageSgage.currency0, _gageSgage.currency1);
        return abi.encode(actions, params);
    }

    function _increaseCall(uint256 tokenId, uint128 liquidity) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(_gageSgage.currency0, _gageSgage.currency1);
        return abi.encode(actions, params);
    }

    /// @dev Remove `liquidity` (zero collects fees only), take both tokens here, burn the sGAGE, keep the GAGE.
    function _decreaseAndBurn(uint256 tokenId, uint128 liquidity)
        internal
        returns (uint256 sgageBurned, uint256 gageKept)
    {
        uint256 gageBefore = IERC20(GAGE).balanceOf(address(this));
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(_gageSgage.currency0, _gageSgage.currency1, address(this));
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        sgageBurned = SGAGE.balanceOf(address(this));
        if (sgageBurned > 0) IsGAGE(address(SGAGE)).burn(sgageBurned);
        gageKept = IERC20(GAGE).balanceOf(address(this)) - gageBefore;
    }

    function _ceilTo(int24 tick) internal view returns (int24) {
        int24 r = tick % SPACING;
        if (r == 0) return tick;
        return r > 0 ? tick - r + SPACING : tick - r;
    }

    function _floorTo(int24 tick) internal view returns (int24) {
        int24 r = tick % SPACING;
        if (r == 0) return tick;
        return r > 0 ? tick - r : tick - r - SPACING;
    }
}
