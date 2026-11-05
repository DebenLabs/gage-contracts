// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// What it shows: the rehypo source factory on mainnet. A DEX partner predicts a source's address for a pool token,
// creates it (open to anyone, salted with the creator), and reads back its configuration. The source accepts only a
// gage partner vault of the same token from a factory the GenerationDeployer recorded; a vault of an earlier
// generation is refused. Binding the pool's hook (`bind`), seeding and naming gage's keeper are the partner's next
// calls and are not run here.
// The factory is not in the deployment manifest yet, so its address comes from the environment:
//   REHYPO_FACTORY=<factory address> forge test --match-path test/RehypoSource.t.sol -vv   (from examples/foundry)
// Without REHYPO_FACTORY every test is skipped.

import {console2} from "forge-std/console2.sol";
import {MainnetFork} from "./MainnetFork.sol";

/// @dev `src/rehypo/GageRehypoSourceFactory.sol`; `IERC20`, `IRehypoVault` and `GageRehypoSource` are addresses here.
interface IGageRehypoSourceFactory {
    function POOL_MANAGER() external view returns (address);
    function REGISTRY() external view returns (address);
    function isSource(address source) external view returns (bool created);
    function create(address asset, address vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (address source);
    function predict(
        address creator,
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        bytes32 salt
    ) external view returns (address);
}

/// @dev The parts of `src/rehypo/GageRehypoSource.sol` this example reads, and the errors its constructor raises.
interface IGageRehypoSource {
    error InvalidConfiguration();
    error InvalidFloatBps(uint16 floatBps);
    error NotAGageVault();

    function asset() external view returns (address);
    function vault() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function REGISTRY() external view returns (address);
    function MIN_SWEEP() external view returns (uint256);
    function owner() external view returns (address);
    function beneficiary() external view returns (address);
    function floatBps() external view returns (uint16);
    function depositor() external view returns (address);
    function isKeeper(address keeper) external view returns (bool allowed);
    function maxDeposit(address receiver) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IIntentFactory {
    function count() external view returns (uint256);
    function vaults(uint256 index) external view returns (address);
}

contract RehypoSourceTest is MainnetFork {
    IGageRehypoSourceFactory internal factory;
    /// @dev The partner's Safe in production; here the test contract plays the partner.
    address internal partner;

    function setUp() public override {
        super.setUp();
        factory = IGageRehypoSourceFactory(vm.envOr("REHYPO_FACTORY", address(0)));
        partner = address(this);
    }

    modifier withFactory() {
        if (address(factory) == address(0)) vm.skip(true);
        _;
    }

    function test_factoryTrustsTheGenerationDeployer() public withFactory {
        assertEq(factory.POOL_MANAGER(), addressOf("PoolManager"));
        assertEq(factory.REGISTRY(), addressOf("generationDeployer.address"), "the deployer's factory record");
    }

    /// A float-only source: no vault, a float target of 100%. It can attach a vault later (three days' notice).
    function test_predictAndCreateAFloatOnlySource() public withFactory {
        address usdg = addressOf("USDG");
        bytes32 salt = keccak256("example float-only source");
        address predicted = factory.predict(partner, usdg, address(0), partner, partner, 10_000, salt);
        address source = factory.create(usdg, address(0), partner, partner, 10_000, salt);
        assertEq(source, predicted, "predict gives the address create makes");
        assertTrue(factory.isSource(source));
        _checkConfiguration(IGageRehypoSource(source), usdg, address(0), 10_000);
    }

    /// A lent source: its backing beyond the float goes to a USDG partner vault of the current generation.
    function test_predictAndCreateALentSource() public withFactory {
        IIntentFactory usdgFactory = IIntentFactory(addressOf("intentV1.factory"));
        if (usdgFactory.count() == 0) vm.skip(true);
        address vault = usdgFactory.vaults(0);
        address usdg = addressOf("USDG");
        bytes32 salt = keccak256("example lent source");
        address predicted = factory.predict(partner, usdg, vault, partner, partner, 2_000, salt);
        address source = factory.create(usdg, vault, partner, partner, 2_000, salt);
        assertEq(source, predicted);
        _checkConfiguration(IGageRehypoSource(source), usdg, vault, 2_000);
        console2.log("source", source, "lends through", vault);
    }

    /// The salt is the creator's: another creator with the same arguments gets another address.
    function test_addressesAreTheCreators() public withFactory {
        address usdg = addressOf("USDG");
        bytes32 salt = keccak256("same salt");
        address mine = factory.predict(partner, usdg, address(0), partner, partner, 10_000, salt);
        address theirs = factory.predict(makeAddr("someone else"), usdg, address(0), partner, partner, 10_000, salt);
        assertTrue(mine != theirs);
    }

    /// The checks a source makes of its vault and its settings, at creation (and again at `proposeVault`).
    function test_refusals() public withFactory {
        address usdg = addressOf("USDG");

        // A lookalike vault of the right token whose factory vouches for it: that factory is not in the
        // GenerationDeployer's record.
        RehypoSourceLookalikeFactory lookalikeFactory = new RehypoSourceLookalikeFactory();
        address lookalike = address(new RehypoSourceLookalikeVault(usdg, address(lookalikeFactory)));
        vm.expectRevert(IGageRehypoSource.NotAGageVault.selector);
        factory.create(usdg, lookalike, partner, partner, 2_000, bytes32(uint256(1)));

        // A lookalike that names a recorded factory, which did not create it (`isVault` is false).
        address claimant = address(new RehypoSourceLookalikeVault(usdg, addressOf("intentV1.factory")));
        vm.expectRevert(IGageRehypoSource.NotAGageVault.selector);
        factory.create(usdg, claimant, partner, partner, 2_000, bytes32(uint256(2)));

        // A vault of an earlier generation predates the ERC-4626 surface: its `asset()` reverts, and so does the call.
        IIntentFactory earlier = IIntentFactory(addressOf("intentV1Previous[0].intentV1.factory"));
        if (earlier.count() != 0) {
            address old = earlier.vaults(0);
            vm.expectRevert();
            factory.create(usdg, old, partner, partner, 2_000, bytes32(uint256(3)));
        }

        // A vault of another token than the source's.
        IIntentFactory usdgFactory = IIntentFactory(addressOf("intentV1.factory"));
        if (usdgFactory.count() != 0) {
            address vault = usdgFactory.vaults(0);
            address gld = addressOf("intentV1Assets.GLD.lendAsset.token");
            vm.expectRevert(IGageRehypoSource.InvalidConfiguration.selector);
            factory.create(gld, vault, partner, partner, 2_000, bytes32(uint256(4)));
        }

        // A float target outside 1% to 100% of the backing.
        vm.expectRevert(abi.encodeWithSelector(IGageRehypoSource.InvalidFloatBps.selector, uint16(50)));
        factory.create(usdg, address(0), partner, partner, 50, bytes32(uint256(5)));

        // A beneficiary of zero.
        vm.expectRevert(IGageRehypoSource.InvalidConfiguration.selector);
        factory.create(usdg, address(0), partner, address(0), 10_000, bytes32(uint256(6)));
    }

    function _checkConfiguration(IGageRehypoSource source, address asset, address vault, uint16 floatBps)
        internal
        view
    {
        assertEq(source.asset(), asset);
        assertEq(source.vault(), vault);
        assertEq(source.POOL_MANAGER(), addressOf("PoolManager"));
        assertEq(source.REGISTRY(), addressOf("generationDeployer.address"));
        assertEq(source.owner(), partner, "the partner's Safe owns it");
        assertEq(source.beneficiary(), partner, "where sGAGE and recovered collateral go");
        assertEq(source.floatBps(), floatBps);
        assertEq(source.MIN_SWEEP(), 1e6, "one whole USDG");
        assertEq(source.depositor(), address(0), "no hook until the owner binds one");
        assertFalse(source.isKeeper(address(0)));
        assertEq(source.maxDeposit(partner), 0, "nobody deposits before bind");
        assertEq(source.name(), "gage rehypo source USDG");
        assertEq(source.symbol(), "grsUSDG");
    }
}

/// @dev A contract that answers the two views a source reads of a vault, standing in for a vault gage did not create.
contract RehypoSourceLookalikeVault {
    address public immutable asset;
    address public immutable PROTOCOL_SOURCE;

    constructor(address asset_, address factory_) {
        asset = asset_;
        PROTOCOL_SOURCE = factory_;
    }
}

/// @dev A factory that vouches for every vault, and that the GenerationDeployer never recorded.
contract RehypoSourceLookalikeFactory {
    function isVault(address) external pure returns (bool) {
        return true;
    }
}
