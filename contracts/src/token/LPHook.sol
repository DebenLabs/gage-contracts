// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ILPRewards} from "../interfaces/token/ILPRewards.sol";

/// @title LPHook
/// @notice The GAGE/sGAGE pool's hook. It only keeps accounts: on every add and remove through the PositionManager
///         it tells LPRewards which tokenId changed, inside a try with a fixed gas stipend. It never reverts and never
///         returns a delta (T5). Its address encodes exactly AFTER_ADD_LIQUIDITY and AFTER_REMOVE_LIQUIDITY; mine it
///         with a CREATE2 salt (script/DeployTokenLayer.s.sol).
contract LPHook is IHooks {
    IPoolManager public immutable POOL_MANAGER;
    address public immutable POSITION_MANAGER;
    address public immutable DEPLOYER;
    /// @notice Gas handed to LPRewards on each callback. Enough for a checkpoint; a failure is recorded, never raised.
    uint256 public constant CALLBACK_GAS = 400_000;

    ILPRewards public lpRewards;

    event LiquidityChangeRecorded(uint256 indexed tokenId, bool add);
    event RecordFailed(uint256 indexed tokenId, bool add);

    error NotDeployer();
    error AlreadySet();
    error ZeroAddress();
    error HookNotImplemented();

    /// @param admin The account allowed to call `setLPRewards` once. Passed explicitly because a CREATE2 factory,
    ///        not the deployer, is `msg.sender` in the constructor.
    constructor(IPoolManager poolManager, address positionManager, address admin) {
        if (address(poolManager) == address(0) || positionManager == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }
        POOL_MANAGER = poolManager;
        POSITION_MANAGER = positionManager;
        DEPLOYER = admin;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice Deployer, once. The hook can be deployed (and its address mined) before LPRewards exists.
    function setLPRewards(ILPRewards lpRewards_) external {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (address(lpRewards) != address(0)) revert AlreadySet();
        if (address(lpRewards_) == address(0)) revert ZeroAddress();
        lpRewards = lpRewards_;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ----------------------------------------------------------------- the two callbacks

    function afterAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender == address(POOL_MANAGER)) _record(sender, params.salt, true);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender == address(POOL_MANAGER)) _record(sender, params.salt, false);
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev The PositionManager sets `salt` to the tokenId, so nothing can be spoofed and nothing has to be
    ///      registered. Liquidity added by anything else is not rewarded.
    function _record(address sender, bytes32 salt, bool add) internal {
        ILPRewards target = lpRewards;
        if (sender != POSITION_MANAGER || address(target) == address(0)) return;
        uint256 tokenId = uint256(salt);
        try target.onLiquidityChange{gas: CALLBACK_GAS}(tokenId) {
            emit LiquidityChangeRecorded(tokenId, add);
        } catch {
            emit RecordFailed(tokenId, add);
        }
    }

    // ----------------------------------------------------------------- unused callbacks (never called: flags unset)

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
