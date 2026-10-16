// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";

import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {EntryRouter} from "../src/EntryRouter.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockUniversalRouter} from "../test/mocks/MockUniversalRouter.sol";

/// @notice Testnet deployment of the M1 vault layer with mock tokens, because Robinhood Chain Testnet (46630) has no
///         USDG and no Stock Tokens we can rely on. Same vault bytecode as mainnet; only the tokens and the swap
///         router are mocks. Not for mainnet: Deploy.s.sol is the mainnet script.
/// @dev Env: TESTNET_DEPLOYER_KEY, BORROWER_KEY, LENDER_KEY (actors get mock balances and gas), optional
///      GAGE_TESTNET_SALT, ACTOR_GAS_WEI, DEPLOYMENT_TAG. Writes deployments/<chainId><tag>.json.
///      Usage: forge script script/DeployTestnet.s.sol --rpc-url robinhood_testnet --broadcast
contract DeployTestnet is DeploymentFile {
    MockERC20 public usdg;
    MockERC20 public nvda;
    MockERC20 public meme;
    MockUniversalRouter public swapRouter;
    CollateralRegistry public registry;
    FeeSink public feeSink;
    DealVault public vault;
    EntryRouter public router;

    address internal deployer;
    address internal borrower;
    address internal lender;
    address internal positionManager;
    string internal path;

    function run() external {
        uint256 deployerKey = vm.envUint("TESTNET_DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);
        borrower = vm.addr(vm.envUint("BORROWER_KEY"));
        lender = vm.addr(vm.envUint("LENDER_KEY"));
        bytes32 salt = keccak256(bytes(vm.envOr("GAGE_TESTNET_SALT", string("gage.testnet.v1"))));
        path =
            string.concat("deployments/", vm.toString(block.chainid), vm.envOr("DEPLOYMENT_TAG", string("")), ".json");
        // Deploy Uniswap v4 first (DeployV4Testnet.s.sol) so the vault's immutable PositionManager is real.
        if (vm.isFile(path)) {
            string memory existing = vm.readFile(path);
            if (vm.keyExistsJson(existing, ".PositionManager")) {
                positionManager = vm.parseJsonAddress(existing, ".PositionManager");
            }
        }

        vm.startBroadcast(deployerKey);
        _deployMocks(salt);
        _deployVaultLayer(salt);
        _configure();
        _fundActors(vm.envOr("ACTOR_GAS_WEI", uint256(0.02 ether)));
        vm.stopBroadcast();

        _write();
    }

    function _deployMocks(bytes32 salt) internal {
        usdg = new MockERC20{salt: salt}("Test Global Dollar", "tUSDG", 6);
        nvda = new MockERC20{salt: salt}("Test NVIDIA Stock Token", "tNVDAx", 18);
        meme = new MockERC20{salt: salt}("Test NVIDIA Dog", "tNVDOG", 18);
        swapRouter = new MockUniversalRouter{salt: salt}(usdg, 3000e6);
    }

    function _deployVaultLayer(bytes32 salt) internal {
        uint32[] memory terms = new uint32[](3);
        terms[0] = 1 days;
        terms[1] = 7 days;
        terms[2] = 21 days;
        registry = new CollateralRegistry{salt: salt}(deployer, terms, 50);
        feeSink = new FeeSink{salt: salt}(usdg, deployer, deployer);
        vault = new DealVault{salt: salt}(usdg, registry, address(feeSink), positionManager, 24 hours);
        router = new EntryRouter{salt: salt}(vault, usdg, swapRouter);
    }

    function _configure() internal {
        feeSink.setVault(vault);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 1000e18, 5000e18);
        registry.setERC20Allowed(address(meme), true, Lane.MEME, 1000e18, 100_000e18, 500_000e18);
        registry.setRouter(address(router), true);
    }

    function _fundActors(uint256 actorGas) internal {
        usdg.mint(lender, 1_000_000e6);
        usdg.mint(borrower, 1_000_000e6);
        nvda.mint(borrower, 10_000e18);
        meme.mint(borrower, 1_000_000e18);
        if (actorGas > 0) {
            (bool ok1,) = borrower.call{value: actorGas}("");
            (bool ok2,) = lender.call{value: actorGas}("");
            require(ok1 && ok2, "actor gas transfer failed");
        }
    }

    function _write() internal {
        if (vm.isFile(path)) _carryForward(vm.readFile(path));
        vm.serializeUint(OBJ, "chainId", block.chainid);
        vm.serializeAddress(OBJ, "deployer", deployer);
        vm.serializeAddress(OBJ, "borrower", borrower);
        vm.serializeAddress(OBJ, "lender", lender);
        vm.serializeAddress(OBJ, "USDG", address(usdg));
        vm.serializeAddress(OBJ, "NVDAx", address(nvda));
        vm.serializeAddress(OBJ, "NVDOG", address(meme));
        vm.serializeAddress(OBJ, "MockUniversalRouter", address(swapRouter));
        vm.serializeAddress(OBJ, "CollateralRegistry", address(registry));
        vm.serializeAddress(OBJ, "FeeSink", address(feeSink));
        vm.serializeAddress(OBJ, "DealVault", address(vault));
        string memory out = vm.serializeAddress(OBJ, "EntryRouter", address(router));
        vm.writeJson(out, path);

        console2.log("chain", block.chainid);
        console2.log("USDG (mock)         ", address(usdg));
        console2.log("NVDAx (mock)        ", address(nvda));
        console2.log("NVDOG (mock meme)   ", address(meme));
        console2.log("MockUniversalRouter ", address(swapRouter));
        console2.log("CollateralRegistry  ", address(registry));
        console2.log("FeeSink             ", address(feeSink));
        console2.log("DealVault           ", address(vault));
        console2.log("EntryRouter         ", address(router));
        console2.log("PositionManager     ", positionManager);
        console2.log("written", path);
    }
}
