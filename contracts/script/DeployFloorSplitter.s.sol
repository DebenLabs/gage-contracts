// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CreatorFeeSplitter} from "../src/token/CreatorFeeSplitter.sol";

/// @notice Testnet only. Replaces the CreatorFeeSplitter on a live token layer with the floor-building one (D46)
///         without redeploying anything else, then feeds it a first clip of "creator fees" so the first floor band
///         exists. The live LPRewards predates `setFloor`; floor bands sit out of range, so they carry no weight
///         anyway until the market enters a band. Reads and rewrites deployments/<chainId><tag>.json.
/// @dev Env: TESTNET_DEPLOYER_KEY, GAGE_TESTNET_SALT, optional DEPLOYMENT_TAG, FLOOR_SEED_ETH (default 0.02 ether).
contract DeployFloorSplitter is DeploymentFile {
    function run() external {
        uint256 deployerKey = vm.envUint("TESTNET_DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        bytes32 salt = keccak256(bytes(vm.envOr("GAGE_TESTNET_SALT", string("gage.testnet.v1"))));
        string memory path =
            string.concat("deployments/", vm.toString(block.chainid), vm.envOr("DEPLOYMENT_TAG", string("")), ".json");
        string memory json = vm.readFile(path);

        IPoolManager poolManager = IPoolManager(vm.parseJsonAddress(json, ".PoolManager"));
        IPositionManager posm = IPositionManager(vm.parseJsonAddress(json, ".PositionManager"));
        IAllowanceTransfer permit2 = IAllowanceTransfer(vm.parseJsonAddress(json, ".Permit2"));
        address gage = vm.parseJsonAddress(json, ".GAGE");
        address sgage = vm.parseJsonAddress(json, ".sGAGE");
        PoolKey memory gageEth = _key(json, "gageEth");
        PoolKey memory gageSgage = _key(json, "gageSgage");
        uint256 seedEth = vm.envOr("FLOOR_SEED_ETH", uint256(0.02 ether));

        vm.startBroadcast(deployerKey);
        CreatorFeeSplitter splitter = new CreatorFeeSplitter{salt: salt}(
            CreatorFeeSplitter.Params({
                poolManager: poolManager,
                positionManager: posm,
                permit2: permit2,
                opsWallet: deployer,
                sgage: IERC20(sgage),
                gage: gage,
                gageEth: gageEth,
                gageSgage: gageSgage,
                launchPoolFeePips: 3000,
                ponsClaimTarget: address(0),
                ponsClaimCalldata: "",
                threshold: 0.001 ether,
                bountyBps: 50,
                initialOwner: deployer
            })
        );
        if (seedEth > 0) {
            (bool ok,) = address(splitter).call{value: seedEth}("");
            require(ok, "seed transfer");
            uint256 gageToFloor = splitter.split();
            require(gageToFloor > 0 && splitter.floorCount() == 1, "no floor band");
        }
        vm.stopBroadcast();

        _carryForward(json);
        string memory out = vm.serializeAddress(OBJ, "CreatorFeeSplitter", address(splitter));
        vm.writeJson(out, path);
        (int24 lower, int24 upper) = splitter.bandNow();
        console2.log("CreatorFeeSplitter (floor)", address(splitter));
        console2.log("floor bands               ", splitter.floorCount());
        console2.log("band now lower              ", int256(lower));
        console2.log("band now upper              ", int256(upper));
        console2.log("written", path);
    }

    function _key(string memory json, string memory name) internal pure returns (PoolKey memory k) {
        string memory base = string.concat(".pools.", name);
        k = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(json, string.concat(base, ".currency0"))),
            currency1: Currency.wrap(vm.parseJsonAddress(json, string.concat(base, ".currency1"))),
            fee: uint24(vm.parseJsonUint(json, string.concat(base, ".fee"))),
            tickSpacing: int24(vm.parseJsonInt(json, string.concat(base, ".tickSpacing"))),
            hooks: IHooks(vm.parseJsonAddress(json, string.concat(base, ".hooks")))
        });
    }
}
