// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Puts a Uniswap v4 instance on Robinhood Chain Testnet, which has none: PoolManager (v4-core's own build,
///         24,009 bytes), PositionManager and StateView (v4-periphery's build), plus the two v4-core test routers
///         for raw liquidity and swaps. Permit2 already exists at its canonical address on the testnet.
/// @dev Env: TESTNET_DEPLOYER_KEY, optional DEPLOYMENT_TAG. Merges into deployments/<chainId><tag>.json.
contract DeployV4Testnet is DeploymentFile {
    string internal constant POOL_MANAGER_ARTIFACT =
        "lib/v4-periphery/lib/v4-core/out/PoolManager.sol/PoolManager.json";
    string internal constant POSITION_MANAGER_ARTIFACT =
        "lib/v4-periphery/foundry-out/PositionManager.sol/PositionManager.json";
    string internal constant STATE_VIEW_ARTIFACT = "lib/v4-periphery/foundry-out/StateView.sol/StateView.json";
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant TESTNET_WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;

    address public poolManager;
    address public positionManager;
    address public stateView;
    address public liquidityRouter;
    address public swapRouter;

    function run() external {
        uint256 key = vm.envUint("TESTNET_DEPLOYER_KEY");
        address deployer = vm.addr(key);
        string memory tag = vm.envOr("DEPLOYMENT_TAG", string(""));
        require(PERMIT2.code.length > 0, "Permit2 missing on this chain");

        vm.startBroadcast(key);
        poolManager = deployCode(POOL_MANAGER_ARTIFACT, abi.encode(deployer));
        positionManager = deployCode(
            POSITION_MANAGER_ARTIFACT, abi.encode(poolManager, PERMIT2, uint256(300_000), address(0), TESTNET_WETH)
        );
        stateView = deployCode(STATE_VIEW_ARTIFACT, abi.encode(poolManager));
        liquidityRouter = address(new PoolModifyLiquidityTest(IPoolManager(poolManager)));
        swapRouter = address(new PoolSwapTest(IPoolManager(poolManager)));
        vm.stopBroadcast();

        string memory path = string.concat("deployments/", vm.toString(block.chainid), tag, ".json");
        if (vm.isFile(path)) _carryForward(vm.readFile(path));
        else vm.serializeUint(OBJ, "chainId", block.chainid);
        vm.serializeAddress(OBJ, "PoolManager", poolManager);
        vm.serializeAddress(OBJ, "PositionManager", positionManager);
        vm.serializeAddress(OBJ, "StateView", stateView);
        vm.serializeAddress(OBJ, "Permit2", PERMIT2);
        vm.serializeAddress(OBJ, "LiquidityRouter", liquidityRouter);
        string memory out = vm.serializeAddress(OBJ, "SwapRouter", swapRouter);
        vm.writeJson(out, path);
        console2.log("PoolManager      ", poolManager);
        console2.log("PositionManager  ", positionManager);
        console2.log("StateView        ", stateView);
        console2.log("LiquidityRouter  ", liquidityRouter);
        console2.log("SwapRouter       ", swapRouter);
        console2.log("written", path);
    }
}
