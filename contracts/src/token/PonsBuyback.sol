// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PonsV4Swapper} from "./base/PonsV4Swapper.sol";
import {IBuyback} from "../interfaces/token/IBuyback.sol";
import {IsGAGE} from "../interfaces/token/IsGAGE.sol";

/// @title PonsBuyback
/// @notice FeeSink's BUYBACK route. USDG → ETH → GAGE (launch pool) → sGAGE (our pool), each leg bounded by
///         MAX_IMPACT_BPS against the pre-swap spot, then the sGAGE is burned (T6). Anyone may clip above the
///         threshold and earns the bounty. It never sells GAGE or sGAGE: there is no code path that could.
contract PonsBuyback is IBuyback, PonsV4Swapper, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_IMPACT_BPS = 100;
    uint16 public constant MAX_BOUNTY_BPS = 100;

    IERC20 public immutable USDG;
    IsGAGE public immutable SGAGE;
    address public immutable GAGE;
    /// @notice Fee assumed for the launch pool when its fee is dynamic (Pons hook). VERIFY before mainnet.
    uint24 public immutable LAUNCH_POOL_FEE_PIPS;

    PoolKey internal _usdgEth;
    PoolKey internal _gageEth;
    PoolKey internal _gageSgage;

    uint256 public threshold;
    uint16 public bountyBps;
    uint256 public totalBurned;

    error PoolMismatch();

    struct Params {
        IPoolManager poolManager;
        IERC20 usdg;
        IsGAGE sgage;
        address gage;
        PoolKey usdgEth;
        PoolKey gageEth;
        PoolKey gageSgage;
        uint24 launchPoolFeePips;
        uint256 threshold;
        uint16 bountyBps;
        address initialOwner;
    }

    constructor(Params memory p, address curve_)
        PonsV4Swapper(p.poolManager, curve_, p.gageEth, p.launchPoolFeePips)
        Ownable(p.initialOwner)
    {
        if (address(p.usdg) == address(0) || address(p.sgage) == address(0) || p.gage == address(0)) {
            revert ZeroAddress();
        }
        // native ETH is always currency0
        if (!p.usdgEth.currency0.isAddressZero() || Currency.unwrap(p.usdgEth.currency1) != address(p.usdg)) {
            revert PoolMismatch();
        }
        if (!p.gageEth.currency0.isAddressZero() || Currency.unwrap(p.gageEth.currency1) != p.gage) {
            revert PoolMismatch();
        }
        if (!_isPair(p.gageSgage, p.gage, address(p.sgage))) revert PoolMismatch();
        if (p.bountyBps > MAX_BOUNTY_BPS) revert BountyOutOfBounds();
        USDG = p.usdg;
        SGAGE = p.sgage;
        GAGE = p.gage;
        LAUNCH_POOL_FEE_PIPS = p.launchPoolFeePips;
        _usdgEth = p.usdgEth;
        _gageEth = p.gageEth;
        _gageSgage = p.gageSgage;
        threshold = p.threshold;
        bountyBps = p.bountyBps;
        emit ThresholdSet(p.threshold);
        emit BountySet(p.bountyBps);
    }

    function _isPair(PoolKey memory key, address a, address b) internal pure returns (bool) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        return (c0 == a && c1 == b) || (c0 == b && c1 == a);
    }

    /// @inheritdoc IBuyback
    function buyback(uint256 clipUSDG) external nonReentrant returns (uint256 burned) {
        uint256 bal = USDG.balanceOf(address(this));
        if (bal < threshold) revert BelowThreshold(bal, threshold);
        if (clipUSDG == 0 || clipUSDG > bal) revert ClipTooLarge(clipUSDG, bal);

        uint256 bounty = (clipUSDG * bountyBps) / 10_000;
        uint256 spend = clipUSDG - bounty;

        // USDG (currency1) → ETH (currency0)
        uint256 ethOut = _swapExactIn(_usdgEth, false, spend, _quoteAtSpot(_usdgEth, false, spend, MAX_IMPACT_BPS, 0));
        // ETH (currency0) → GAGE (currency1) on the launch pool
        uint256 gageOut = _swapExactIn(
            _gageEth, true, ethOut, _quoteAtSpot(_gageEth, true, ethOut, MAX_IMPACT_BPS, LAUNCH_POOL_FEE_PIPS)
        );
        // GAGE → sGAGE in our pool
        bool gageIsZero = _isCurrency0(_gageSgage, GAGE);
        burned = _swapExactIn(
            _gageSgage, gageIsZero, gageOut, _quoteAtSpot(_gageSgage, gageIsZero, gageOut, MAX_IMPACT_BPS, 0)
        );
        SGAGE.burn(burned);
        totalBurned += burned;
        if (bounty > 0) USDG.safeTransfer(msg.sender, bounty);
        emit Clip(msg.sender, clipUSDG, ethOut, gageOut, burned, bounty);
    }

    function setThreshold(uint256 threshold_) external onlyOwner {
        threshold = threshold_;
        emit ThresholdSet(threshold_);
    }

    function setBounty(uint16 bountyBps_) external onlyOwner {
        if (bountyBps_ > MAX_BOUNTY_BPS) revert BountyOutOfBounds();
        bountyBps = bountyBps_;
        emit BountySet(bountyBps_);
    }

    function pools() external view returns (PoolKey memory usdgEth, PoolKey memory gageEth, PoolKey memory gageSgage) {
        return (_usdgEth, _gageEth, _gageSgage);
    }
}
