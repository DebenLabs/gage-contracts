// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {RehypoSource, IGageRehypoSource, IGageRehypoSourceFactory} from "../script/RehypoSource.s.sol";
import {FactoryRegistryStandIn} from "./RehypoSourcePlug.t.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";

/// @notice The rehypo source script (`script/RehypoSource.s.sol`) on a local PoolManager: the release step that
/// deploys the factory on the generation deployer, then the partner's set-up the testnet rehearsal runs, with the
/// plug test's stand-ins for the gage vault and the generation deployer's record. The test contract is the partner.
contract RehypoSourceScriptTest is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev The example band of gage's keeper: frxUSD (18 decimals, currency0) against USDG (6) at 0.995 to
    /// 1.005.
    uint160 internal constant MIN_BAND = 79_029_843_899_059_723_247_256;
    uint160 internal constant MAX_BAND = 79_425_985_949_584_624_389_260;
    /// @dev One frxUSD for one USDG: a raw price of 1e-12, sqrt 1e-6.
    uint160 internal constant PAR = uint160(uint256(1 << 96) / 1e6);
    uint256 internal constant SEED_FRX = 100_000e18;
    uint256 internal constant SEED_USDG = 100_000e6;

    MockERC20 internal frx;
    MockERC20 internal usdg;
    MockGageVault internal usdgVault;
    FactoryRegistryStandIn internal registry;
    RehypoSource internal script;
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        deployFreshManagerAndRouters();
        frx = MockERC20(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Frax USD", "frxUSD", uint8(18)), address(frx));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Global", "USDG", uint8(6)), address(usdg));
        usdgVault = new MockGageVault(IERC20(address(usdg)));
        registry = new FactoryRegistryStandIn();
        registry.record(address(usdgVault));
        script = new RehypoSource();
        frx.mint(address(this), 1_000_000e18);
        usdg.mint(address(this), 1_000_000e6);
    }

    function _pool(IGageRehypoSourceFactory factory) internal view returns (RehypoSource.Pool memory) {
        return RehypoSource.Pool({
            factory: factory,
            lend: IERC20(address(usdg)),
            vault: address(usdgVault),
            floatBps: 2000,
            floatOnly: IERC20(address(frx)),
            keeper: keeper,
            seedLend: SEED_USDG,
            seedFloat: SEED_FRX,
            salt: "rehearsal"
        });
    }

    function _factory() internal returns (IGageRehypoSourceFactory) {
        return IGageRehypoSourceFactory(script.deployFactory(manager, address(registry)));
    }

    // ------------------------------------------------ the release step

    function test_theDeployStepBuildsTheFactoryOnTheGenerationDeployer() public {
        IGageRehypoSourceFactory factory = _factory();
        assertEq(address(factory.POOL_MANAGER()), address(manager));
        assertEq(factory.REGISTRY(), address(registry));
    }

    /// @dev The factory keeps its registry for good: an address that does not answer `isFactory` (here a vault, which
    /// has code) is refused before anything is deployed.
    function test_theDeployStepRefusesARegistryThatIsNotTheGenerationDeployer() public {
        vm.expectRevert(bytes("GENERATION_DEPLOYER does not answer isFactory: not the generation deployer"));
        script.deployFactory(manager, address(usdgVault));
    }

    // ------------------------------------------------ the partner's set-up (the rehearsal)

    function test_theRehearsalSetsThePoolUpAsTheRunbookLists() public {
        RehypoSource.Plugged memory p = script.setUpPool(_pool(_factory()));

        // The two sources: USDG lent through the gage vault, frxUSD float-only, both bound to the hook.
        assertEq(p.lendSource.vault(), address(usdgVault));
        assertEq(p.floatSource.vault(), address(0));
        assertEq(p.lendSource.depositor(), address(p.hook));
        assertEq(p.floatSource.depositor(), address(p.hook));
        assertTrue(p.lendSource.isKeeper(keeper), "the keeper may rebalance the lent side");

        // The pool: frxUSD (the lower address) first, at one whole unit for one whole unit, seeded through the hook.
        assertEq(Currency.unwrap(p.key.currency0), address(frx));
        assertEq(Currency.unwrap(p.key.currency1), address(usdg));
        assertEq(address(p.key.hooks), address(p.hook));
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, PAR);
        assertEq(p.hook.balanceOf(address(this)), 100_000e12, "sqrt(seed0 x seed1) shares to the partner");
        assertEq(PoolId.unwrap(p.hook.getPoolKey().toId()), PoolId.unwrap(p.key.toId()), "the hook took this pool");
    }

    function test_theKeeperEntryCarriesTheHalfPercentBand() public {
        RehypoSource.Plugged memory p = script.setUpPool(_pool(_factory()));
        (uint160 lo, uint160 hi) = script.band(p.key);
        assertEq(lo, MIN_BAND);
        assertEq(hi, MAX_BAND);

        string memory json = script.keeperFile(p);
        assertEq(
            json,
            string.concat(
                '{ "schemaVersion": 1, "chainId": ',
                vm.toString(block.chainid),
                ', "sources": [ { "name": "frxUSD/USDG, USDG side", "source": "',
                vm.toString(address(p.lendSource)),
                '", "minSqrtPriceX96": "79029843899059723247256", "maxSqrtPriceX96": "79425985949584624389260" } ] }'
            )
        );
        assertEq(vm.parseJsonAddress(json, ".sources[0].source"), address(p.lendSource), "valid JSON");
    }

    /// @dev What the keeper then does with the entry, and swaps on the result: the set-up is a working pool.
    function test_theKeeperRebalancesInsideTheBandAndSwapsRun() public {
        RehypoSource.Plugged memory p = script.setUpPool(_pool(_factory()));
        vm.prank(keeper);
        p.lendSource.rebalance(MIN_BAND, MAX_BAND);
        assertEq(usdgVault.cash(), SEED_USDG * 4 / 5, "80% of the USDG lent, 20% kept as float");

        frx.approve(address(swapRouter), type(uint256).max);
        usdg.approve(address(swapRouter), type(uint256).max);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        swap(p.key, true, -1000e18, ZERO_BYTES);
        assertGt(usdg.balanceOf(address(this)) - usdgBefore, 900e6, "a 1,000 frxUSD sale against a 20,000 USDG float");
        uint256 frxBefore = frx.balanceOf(address(this));
        swap(p.key, false, -500e6, ZERO_BYTES);
        assertGt(frx.balanceOf(address(this)) - frxBefore, 490e18);
    }

    /// @dev The float-only source's address follows from the broadcaster, its token and the salt alone, so a second run
    /// reusing it would meet its own CREATE2 address: the script says which setting to change.
    function test_aSecondRunNeedsAnotherSalt() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        script.setUpPool(pool);
        pool.vault = address(new MockGageVault(IERC20(address(usdg))));
        registry.record(pool.vault);
        vm.expectRevert(bytes("a source already exists at this address: set another REHYPO_SALT"));
        script.setUpPool(pool);

        pool.salt = "second";
        RehypoSource.Plugged memory p = script.setUpPool(pool);
        assertEq(p.lendSource.vault(), pool.vault);
    }

    function test_theRehearsalNeverRunsOnMainnet() public {
        RehypoSource.Pool memory pool = _pool(_factory());
        vm.chainId(4663);
        vm.expectRevert(bytes("the rehearsal never runs on chain 4663: there the partner's Safe makes these calls"));
        script.setUpPool(pool);
    }
}
