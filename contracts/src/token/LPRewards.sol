// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {PositionMath} from "../libraries/PositionMath.sol";
import {ILPRewards} from "../interfaces/token/ILPRewards.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";
import {IEmissions} from "../interfaces/token/IEmissions.sol";
import {IsGAGE} from "../interfaces/token/IsGAGE.sol";

/// @title LPRewards
/// @notice Liquidity rewards for the GAGE/sGAGE pool by LP score: size times time. A position's weight is its value
///         in GAGE at the last checkpoint (zero out of range, zero for the seed); emissions stream per second at the
///         Emissions table's liquidity rate for the current epoch and lumps (creator fees, rollovers) are split by
///         the weights present when they land. Rewards accrue to the tokenId; the current owner collects emissions
///         into a 7-day drip and lump sGAGE at once. This contract never holds a position NFT (T5).
/// @dev Weights are exact between checkpoints because they are fixed there; price drift between pokes is the only
///      imprecision, bounded by the keeper's cadence. Checkpoint on every add and remove stops interval farming.
contract LPRewards is ILPRewards, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    uint32 public constant LP_DRIP_LENGTH = 7 days;
    uint256 internal constant PRECISION = 1e27;

    IERC20 public immutable SGAGE;
    IDrip public immutable DRIP;
    IEmissions public immutable EMISSIONS;
    IPositionManager public immutable POSM;
    IPoolManager public immutable POOL_MANAGER;
    address public immutable HOOK;
    address public immutable GAGE;
    address public immutable DEPLOYER;
    bool public immutable SGAGE_IS_CURRENCY0;

    PoolKey internal _poolKey;
    PoolId internal _poolId;

    uint256 public totalWeight;
    uint256 public emissionsPerWeightStored;
    uint256 public lumpPerWeightStored;
    uint40 public lastUpdate;
    /// @notice Emissions accrued while nothing eligible was in range. Anyone may burn them.
    uint256 public undistributed;
    uint256 public seedTokenId;
    /// @notice The CreatorFeeSplitter: its floor bands carry no weight (D46). Set once by the deployer.
    address public floor;
    uint256 internal _nextEpochToRelease;
    mapping(uint256 tokenId => PositionState) internal _positions;

    error NotDeployer();
    error PoolHookMismatch();
    error PoolWithoutSGAGE();
    error NothingUndistributed();

    event UndistributedBurned(uint256 amount);

    constructor(
        IERC20 sgage,
        IDrip drip,
        IEmissions emissions,
        IPositionManager posm,
        address hook,
        PoolKey memory poolKey_,
        address admin
    ) {
        if (
            address(sgage) == address(0) || address(drip) == address(0) || address(emissions) == address(0)
                || address(posm) == address(0) || hook == address(0)
        ) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        if (address(poolKey_.hooks) != hook) revert PoolHookMismatch();
        address c0 = Currency.unwrap(poolKey_.currency0);
        address c1 = Currency.unwrap(poolKey_.currency1);
        if (c0 == address(sgage)) {
            SGAGE_IS_CURRENCY0 = true;
            GAGE = c1;
        } else if (c1 == address(sgage)) {
            SGAGE_IS_CURRENCY0 = false;
            GAGE = c0;
        } else {
            revert PoolWithoutSGAGE();
        }
        SGAGE = sgage;
        DRIP = drip;
        EMISSIONS = emissions;
        POSM = posm;
        POOL_MANAGER = posm.poolManager();
        HOOK = hook;
        DEPLOYER = admin;
        _poolKey = poolKey_;
        _poolId = poolKey_.toId();
        lastUpdate = uint40(block.timestamp);
    }

    // ----------------------------------------------------------------- checkpoints

    /// @inheritdoc ILPRewards
    function checkpoint(uint256 tokenId) public {
        _updateGlobal();
        _checkpoint(tokenId);
    }

    /// @inheritdoc ILPRewards
    function checkpointMany(uint256[] calldata tokenIds) external {
        _updateGlobal();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            _checkpoint(tokenIds[i]);
        }
    }

    /// @inheritdoc ILPRewards
    function onLiquidityChange(uint256 tokenId) external {
        if (msg.sender != HOOK) revert NotHook();
        _updateGlobal();
        _checkpoint(tokenId);
    }

    // ----------------------------------------------------------------- inflows

    /// @inheritdoc ILPRewards
    function notifyEmissions(uint256 epoch, uint256 amount) external {
        if (msg.sender != address(EMISSIONS)) revert NotEmissions();
        if (epoch >= _nextEpochToRelease) _nextEpochToRelease = epoch + 1;
        emit EmissionsNotified(epoch, amount);
    }

    /// @inheritdoc ILPRewards
    function notifyLump(uint256 amount) external nonReentrant {
        _updateGlobal();
        SGAGE.safeTransferFrom(msg.sender, address(this), amount);
        if (totalWeight == 0) undistributed += amount;
        else lumpPerWeightStored += (amount * PRECISION) / totalWeight;
        emit LumpNotified(msg.sender, amount, totalWeight);
    }

    // ----------------------------------------------------------------- collect

    /// @inheritdoc ILPRewards
    function collect(uint256 tokenId) external nonReentrant returns (uint256 emissions, uint256 creatorFee) {
        address owner = IERC721(address(POSM)).ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner(tokenId, msg.sender);
        _updateGlobal();
        _checkpoint(tokenId);
        PositionState storage p = _positions[tokenId];
        emissions = p.emissionsEarned;
        creatorFee = p.lumpEarned;
        if (emissions == 0 && creatorFee == 0) revert NothingToCollect(tokenId);
        p.emissionsEarned = 0;
        p.lumpEarned = 0;
        _ensureReleased();

        bytes32 dripId;
        if (emissions > 0) {
            dripId = dripIdOf(tokenId, ++p.collectNonce);
            SGAGE.forceApprove(address(DRIP), emissions);
            DRIP.grant(owner, dripId, uint128(emissions), uint40(block.timestamp), LP_DRIP_LENGTH);
        }
        if (creatorFee > 0) SGAGE.safeTransfer(owner, creatorFee);
        emit Collected(tokenId, owner, emissions, dripId, creatorFee);
    }

    /// @notice Burn emissions that accrued while no eligible liquidity was in range. Anyone may call it.
    function burnUndistributed() external {
        _updateGlobal();
        uint256 amount = undistributed;
        if (amount == 0) revert NothingUndistributed();
        undistributed = 0;
        _ensureReleased();
        IsGAGE(address(SGAGE)).burn(amount);
        emit UndistributedBurned(amount);
    }

    /// @inheritdoc ILPRewards
    function setFloor(address floor_) external {
        if (msg.sender != DEPLOYER) revert NotSeedTimelock();
        if (floor != address(0)) revert FloorAlreadySet();
        if (floor_ == address(0)) revert ZeroAddress();
        floor = floor_;
        emit FloorSet(floor_);
    }

    /// @inheritdoc ILPRewards
    function setSeed(uint256 tokenId) external {
        if (msg.sender != DEPLOYER) revert NotSeedTimelock();
        if (seedTokenId != 0) revert SeedAlreadySet();
        seedTokenId = tokenId;
        _updateGlobal();
        _checkpoint(tokenId);
        emit SeedSet(tokenId);
    }

    // ----------------------------------------------------------------- views

    function earned(uint256 tokenId) external view returns (uint256 emissions, uint256 creatorFee) {
        PositionState storage p = _positions[tokenId];
        (uint256 ePer,, uint256 lPer) = _globalNow();
        emissions = p.emissionsEarned + (p.weight * (ePer - p.emissionsPerWeightPaid)) / PRECISION;
        creatorFee = p.lumpEarned + (p.weight * (lPer - p.lumpPerWeightPaid)) / PRECISION;
    }

    function positionState(uint256 tokenId) external view returns (PositionState memory) {
        return _positions[tokenId];
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function dripIdOf(uint256 tokenId, uint32 collectNonce) public pure returns (bytes32) {
        return keccak256(abi.encode("lp", tokenId, collectNonce));
    }

    /// @inheritdoc ILPRewards
    function valueInGAGE(uint256 tokenId) public view returns (uint256 value, bool inRange) {
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolId)) return (0, false);
        uint128 liquidity = POSM.getPositionLiquidity(tokenId);
        if (liquidity == 0) return (0, false);
        (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(_poolId);
        int24 lower = info.tickLower();
        int24 upper = info.tickUpper();
        inRange = tick >= lower && tick < upper;
        (uint256 amount0, uint256 amount1) = PositionMath.amountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        // value in GAGE = amountGAGE + amountSGAGE × price(GAGE per sGAGE); price = (sqrtP / 2^96)^2 for
        // currency1 per currency0.
        if (SGAGE_IS_CURRENCY0) {
            uint256 sgageInGage =
                Math.mulDiv(Math.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
            value = amount1 + sgageInGage;
        } else {
            uint256 sgageInGage =
                Math.mulDiv(Math.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96);
            value = amount0 + sgageInGage;
        }
    }

    /// @notice Emission rate for the liquidity side in `epoch`, sGAGE per second.
    function emissionRate(uint256 epoch) public view returns (uint256) {
        if (epoch >= EMISSIONS.WEEKS()) return 0;
        return EMISSIONS.liquidityBudget(epoch) / EMISSIONS.EPOCH();
    }

    // ----------------------------------------------------------------- internal

    function _checkpoint(uint256 tokenId) internal {
        PositionState storage p = _positions[tokenId];
        p.emissionsEarned += (p.weight * (emissionsPerWeightStored - p.emissionsPerWeightPaid)) / PRECISION;
        p.lumpEarned += (p.weight * (lumpPerWeightStored - p.lumpPerWeightPaid)) / PRECISION;
        p.emissionsPerWeightPaid = emissionsPerWeightStored;
        p.lumpPerWeightPaid = lumpPerWeightStored;

        (uint256 value, bool inRange) = _excluded(tokenId) ? (0, false) : valueInGAGE(tokenId);
        uint256 newWeight = inRange ? value : 0;
        totalWeight = totalWeight - p.weight + newWeight;
        p.weight = newWeight;
        p.lastCheckpoint = uint40(block.timestamp);
        emit Checkpointed(tokenId, newWeight, totalWeight, inRange);
    }

    /// @dev The seed and the floor bands (owned by the CreatorFeeSplitter) never carry weight.
    function _excluded(uint256 tokenId) internal view returns (bool) {
        if (tokenId == seedTokenId) return true;
        if (floor == address(0)) return false;
        (bool ok, bytes memory data) =
            address(POSM).staticcall(abi.encodeWithSelector(IERC721.ownerOf.selector, tokenId));
        return ok && data.length >= 32 && abi.decode(data, (address)) == floor;
    }

    /// @dev Integrate the emission rate piecewise over [lastUpdate, now) across epoch boundaries.
    function _updateGlobal() internal {
        (uint256 ePer, uint256 undist,) = _globalNow();
        emissionsPerWeightStored = ePer;
        undistributed = undist;
        lastUpdate = uint40(block.timestamp);
    }

    function _globalNow() internal view returns (uint256 ePer, uint256 undist, uint256 lPer) {
        ePer = emissionsPerWeightStored;
        undist = undistributed;
        lPer = lumpPerWeightStored;
        uint40 launchAt = EMISSIONS.launchAt();
        uint256 nowT = block.timestamp;
        if (launchAt == 0 || nowT <= launchAt || nowT == lastUpdate) return (ePer, undist, lPer);
        uint256 epochLen = EMISSIONS.EPOCH();
        uint256 from = lastUpdate > launchAt ? lastUpdate : launchAt;
        uint256 end = nowT < launchAt + EMISSIONS.WEEKS() * epochLen ? nowT : launchAt + EMISSIONS.WEEKS() * epochLen;
        uint256 weight = totalWeight;
        while (from < end) {
            uint256 epoch = (from - launchAt) / epochLen;
            uint256 segEnd = launchAt + (epoch + 1) * epochLen;
            if (segEnd > end) segEnd = end;
            uint256 amount = emissionRate(epoch) * (segEnd - from);
            if (weight > 0) ePer += (amount * PRECISION) / weight;
            else undist += amount;
            from = segEnd;
        }
    }

    /// @dev Tokens for an epoch arrive at release; make sure every started epoch has been released before paying.
    function _ensureReleased() internal {
        if (EMISSIONS.launchAt() == 0 || block.timestamp < EMISSIONS.launchAt()) return;
        uint256 current = EMISSIONS.currentEpoch();
        uint256 last = current < EMISSIONS.WEEKS() ? current : EMISSIONS.WEEKS() - 1;
        for (uint256 e = _nextEpochToRelease; e <= last; ++e) {
            if (!EMISSIONS.released(e)) EMISSIONS.release(e);
        }
        if (_nextEpochToRelease <= last) _nextEpochToRelease = last + 1;
    }
}
