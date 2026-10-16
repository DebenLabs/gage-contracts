// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPRewards} from "../src/token/LPRewards.sol";
import {LPStreamer} from "../src/token/LPStreamer.sol";

/// @notice Deploys the LPStreamer next to a live LPRewards (D64) and records it under `LPStreamer` (and its Drip under `LPStreamerDrip`) in the
///         deployment manifest. Any chain. The signer comes from forge: run with `-i 1` so the key is typed at a
///         hidden prompt and never appears in an argument, a log or a file.
/// @dev Env: DEPLOYMENT_PATH (default deployments/<chainId>.json; the mainnet manifest is
///      ../launch/live/4663.json), DEPLOYMENT_WRITE=true to update that file (a simulation without it only prints).
///      Run: forge script script/DeployLPStreamer.s.sol --rpc-url $ROBINHOOD_RPC_URL --broadcast -i 1 \
///           --sender <deployer>
contract DeployLPStreamer is Script {
    function run() external {
        string memory path =
            vm.envOr("DEPLOYMENT_PATH", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        string memory json = vm.readFile(path);
        IERC20 sgage = IERC20(vm.parseJsonAddress(json, ".sGAGE"));
        LPRewards rewards = LPRewards(vm.parseJsonAddress(json, ".LPRewards"));
        require(address(rewards.SGAGE()) == address(sgage), "sGAGE mismatch");
        require(!vm.keyExistsJson(json, ".LPStreamer"), "LPStreamer already recorded");

        vm.startBroadcast();
        LPStreamer streamer = new LPStreamer(sgage, rewards);
        vm.stopBroadcast();

        require(address(streamer.REWARDS()) == address(rewards), "wiring");
        require(streamer.assignedThrough() == rewards.EMISSIONS().currentEpoch(), "epoch");
        console2.log("LPStreamer     ", address(streamer));
        console2.log("LPStreamerDrip ", address(streamer.DRIP()));
        console2.log("LPRewards      ", address(rewards));
        console2.log("current epoch  ", streamer.assignedThrough());
        if (vm.envOr("DEPLOYMENT_WRITE", false)) {
            vm.writeJson(string.concat('"', vm.toString(address(streamer)), '"'), path, ".LPStreamer");
            vm.writeJson(string.concat('"', vm.toString(address(streamer.DRIP())), '"'), path, ".LPStreamerDrip");
            console2.log("written", path);
        } else {
            console2.log("not written: set DEPLOYMENT_WRITE=true to record it in", path);
        }
    }
}
