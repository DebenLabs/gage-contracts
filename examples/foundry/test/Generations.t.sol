// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// What it shows: the GenerationDeployer, which builds a lend-asset generation from creation code it holds on chain,
// and its record of Intent factories (`IIntentFactoryRegistry.isFactory`), which a rehypo source trusts. It checks the
// deployer's shared contracts against the manifest, that each blueprint's code matches its published hash, that every
// lend-asset factory of the current release is recorded and every earlier one is not, and lists the generations that
// `deploy` built, which the manifest may not carry yet.
// Run from examples/foundry: forge test --match-path test/Generations.t.sol -vv

import {console2} from "forge-std/console2.sol";
import {MainnetFork} from "./MainnetFork.sol";

/// @dev The parts of `src/intent/GenerationDeployer.sol` this example reads.
interface IGenerationDeployer {
    enum Part {
        FEE_PROCESSOR,
        CLOSED_RESERVE,
        TOKEN_REGISTRY,
        CORE,
        CASHOUT_ROUTER,
        GRADE_REGISTRY,
        FACTORY,
        QUOTE_VERIFIER,
        FILL_ROUTER,
        ROLLOVER_ROUTER,
        VAULT
    }

    function isFactory(address factory) external view returns (bool recorded);
    function factoryCount() external view returns (uint256);
    function factories(uint256 index) external view returns (address);
    function blueprint(Part part) external view returns (address[2] memory chunks, uint256 size, bytes32 codeHash);
    function creationCode(Part part) external view returns (bytes memory code);
    function PARTS() external view returns (uint256);
    function RELEASE_FACTORY_COUNT() external view returns (uint256);
    function USDG() external view returns (address);
    function SGAGE() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function WETH() external view returns (address);
    function FEE_ROUTER() external view returns (address);
    function EXIT_DESK() external view returns (address);
    function owner() external view returns (address);
}

/// @dev The parts of `src/intent/IntentFactory.sol` this example reads.
interface IIntentFactory {
    function CORE() external view returns (address);
    function VAULT_INIT_HASH() external view returns (bytes32);
    function isVault(address vault) external view returns (bool);
    function count() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
    function boundExitDesk() external view returns (address);
}

/// @dev The parts of `src/v2/GageV2Vault.sol` (a core) this example reads.
interface ICore {
    function USDG() external view returns (address);
    function BRIDGE() external view returns (address);
}

/// @dev The one view of `src/intent/IntentVault.sol` a rehypo source reads to find its factory.
interface IPartnerVault {
    function PROTOCOL_SOURCE() external view returns (address);
    function asset() external view returns (address);
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}

contract GenerationsTest is MainnetFork {
    IGenerationDeployer internal deployer;

    function setUp() public override {
        super.setUp();
        deployer = IGenerationDeployer(addressOf("generationDeployer.address"));
    }

    /// The deployer wires every generation to the chain's shared contracts, fixed at its construction.
    function test_foundationIsTheManifests() public view {
        assertEq(deployer.USDG(), addressOf("USDG"), "USDG");
        assertEq(deployer.SGAGE(), addressOf("sGAGE"), "sGAGE");
        assertEq(deployer.POOL_MANAGER(), addressOf("PoolManager"), "PoolManager");
        assertEq(deployer.WETH(), addressOf("WETH"), "WETH");
        assertEq(deployer.FEE_ROUTER(), addressOf("DealFeeRouter"), "fee router");
        assertEq(deployer.EXIT_DESK(), addressOf("intentV1.exitDesk"), "exit desk");
        // The owner, the only caller of `deploy` and `setListed`, is a contract account (gage's Safe).
        assertGt(deployer.owner().code.length, 0, "owner");
    }

    /// Each blueprint is creation code held in one or two SSTORE2 data contracts (a STOP byte, then the code), fixed
    /// at construction. Anyone can read it back and compare its hash with a build of the published source.
    function test_blueprintsMatchTheirHashes() public view {
        uint256 parts = deployer.PARTS();
        assertEq(parts, 11);
        for (uint256 i; i < parts; ++i) {
            IGenerationDeployer.Part part = IGenerationDeployer.Part(i);
            (address[2] memory chunks, uint256 size, bytes32 codeHash) = deployer.blueprint(part);
            bytes memory code = deployer.creationCode(part);
            assertEq(code.length, size, "size");
            assertEq(keccak256(code), codeHash, "hash");
            assertEq(uint8(chunks[0].code[0]), 0, "chunk starts with STOP");
            console2.log("part", i, size);
            console2.logBytes32(codeHash);
        }
    }

    /// The release's own generations (USDG and each lend asset) were given to the constructor, so `isFactory` is true
    /// for each, and each creates its vaults from the `VAULT` blueprint's code.
    function test_currentFactoriesAreRecorded() public view {
        (,, bytes32 vaultHash) = deployer.blueprint(IGenerationDeployer.Part.VAULT);

        address usdgFactory = addressOf("intentV1.factory");
        assertTrue(deployer.isFactory(usdgFactory), "USDG factory");
        assertEq(IIntentFactory(usdgFactory).VAULT_INIT_HASH(), vaultHash, "USDG vault code");

        string[] memory symbols = vm.parseJsonKeys(manifest, ".intentV1Assets");
        for (uint256 i; i < symbols.length; ++i) {
            address factory = addressOf(string.concat("intentV1Assets.", symbols[i], ".factory"));
            assertTrue(deployer.isFactory(factory), symbols[i]);
            assertEq(IIntentFactory(factory).VAULT_INIT_HASH(), vaultHash, symbols[i]);
            console2.log(symbols[i], "factory recorded:", factory);
        }
    }

    /// Earlier generations stay live for their own loans, but nothing can add them to the record: a rehypo source
    /// cannot lend through their vaults.
    function test_earlierFactoriesAreNotRecorded() public view {
        for (uint256 i; has(string.concat("intentV1Previous[", vm.toString(i), "].intentV1.factory")); ++i) {
            address factory = addressOf(string.concat("intentV1Previous[", vm.toString(i), "].intentV1.factory"));
            assertFalse(deployer.isFactory(factory), "earlier USDG factory");
        }
        string[] memory symbols = vm.parseJsonKeys(manifest, ".intentV1AssetsPrevious");
        for (uint256 s; s < symbols.length; ++s) {
            for (uint256 i;; ++i) {
                string memory key =
                    string.concat("intentV1AssetsPrevious.", symbols[s], "[", vm.toString(i), "].entry.factory");
                if (!has(key)) break;
                assertFalse(deployer.isFactory(addressOf(key)), symbols[s]);
            }
        }
    }

    /// `factories(i)` lists every recorded factory: the release's first, then each one `deploy` built. A built
    /// generation lends a stablecoin other than USDG, on an unbridged core.
    function test_generationsTheDeployerBuilt() public view {
        uint256 releaseCount = deployer.RELEASE_FACTORY_COUNT();
        uint256 total = deployer.factoryCount();
        assertGe(total, releaseCount);
        (,, bytes32 vaultHash) = deployer.blueprint(IGenerationDeployer.Part.VAULT);
        for (uint256 i = releaseCount; i < total; ++i) {
            address factory = deployer.factories(i);
            address core = IIntentFactory(factory).CORE();
            address asset = ICore(core).USDG();
            assertTrue(deployer.isFactory(factory));
            assertTrue(asset != deployer.USDG() && asset != deployer.SGAGE(), "lend asset");
            assertEq(ICore(core).BRIDGE(), address(0), "unbridged");
            assertEq(IIntentFactory(factory).VAULT_INIT_HASH(), vaultHash, "vault code");
            assertEq(IIntentFactory(factory).boundExitDesk(), deployer.EXIT_DESK(), "exit desk");
            console2.log("built:", IERC20Symbol(asset).symbol(), factory);
        }
    }

    /// The rule a rehypo source applies to the partner vault it lends through.
    function test_aRehypoSourcesVaultCheck() public {
        IIntentFactory factory = IIntentFactory(addressOf("intentV1.factory"));
        if (factory.count() == 0) vm.skip(true);
        address vault = factory.vaults(0);
        address source = IPartnerVault(vault).PROTOCOL_SOURCE();
        assertEq(source, address(factory));
        assertTrue(deployer.isFactory(source) && IIntentFactory(source).isVault(vault), "accepted");
        assertEq(IPartnerVault(vault).asset(), addressOf("USDG"));

        // A vault of an earlier generation: its factory is not recorded, so a source refuses it (`NotAGageVault`).
        IIntentFactory earlier = IIntentFactory(addressOf("intentV1Previous[0].intentV1.factory"));
        if (earlier.count() != 0) {
            address old = earlier.vaults(0);
            assertFalse(deployer.isFactory(IPartnerVault(old).PROTOCOL_SOURCE()), "refused");
        }
    }
}
