// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {UnlockCheckedHook} from "../src/UnlockCheckedHook.sol";

/// @notice gage's rehypo source factory (`src/rehypo/GageRehypoSourceFactory.sol`), as a partner calls it.
interface IGageRehypoSourceFactory {
    function POOL_MANAGER() external view returns (IPoolManager);
    function REGISTRY() external view returns (address);
    function create(IERC20 asset, address vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (address source);
    function predict(
        address creator,
        IERC20 asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        bytes32 salt
    ) external view returns (address);
}

/// @notice A rehypo source (`GageRehypoSource`), as its owner sets it up and the keeper rebalances it.
interface IGageRehypoSource {
    function asset() external view returns (address);
    function vault() external view returns (address);
    function depositor() external view returns (address);
    function isKeeper(address keeper) external view returns (bool);
    function bind(PoolKey calldata key) external;
    function setKeeper(address keeper, bool allowed) external;
    function rebalance(uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) external;
}

/// @notice The generation deployer's record of the Intent factories whose vaults a source may lend through.
interface IIntentFactoryRegistry {
    function isFactory(address factory) external view returns (bool);
}

/// @notice gage's rehypo source in one script. `run` is the release step: it deploys the source factory with the
/// generation deployer as its registry (2b), right after the release deploys that deployer. `rehearse` sets a pegged
/// pool up as `docs/rehypo-source.md` "Set-up" lists it: the testnet rehearsal, and the reference handed to partners,
/// whose Safe makes the same calls in the same order. Guide: docs/rehypo-source.md, "Running it".
/// @dev The factory compiles in `contracts/` (0.8.28, the `rehypo` profile) and this kit with 0.8.26, so the script
/// deploys it from its artifact there: `forge build src/rehypo/GageRehypoSourceFactory.sol` in `contracts/` first.
contract RehypoSource is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MAINNET = 4663;
    string internal constant FACTORY_ARTIFACT =
        "../../out/GageRehypoSourceFactory.sol/GageRehypoSourceFactory.json";
    /// @dev `ReHypothecationHook`'s permissions, which the reference hook does not change.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev A stable pair's pool: 0.01%, every tick. A static fee, since the stock hook sets no dynamic one.
    uint24 internal constant FEE = 100;
    int24 internal constant TICK_SPACING = 1;
    uint16 internal constant BPS = 10_000;
    /// @dev The float-only side keeps all its backing as float.
    uint16 internal constant ALL_FLOAT = 10_000;
    /// @dev The keeper's band: 0.5% either side of one whole unit for one whole unit.
    uint16 internal constant BAND_BPS = 50;

    /// @notice A pegged pool's two sides: one lent through a gage vault, one float-only.
    struct Pool {
        IGageRehypoSourceFactory factory;
        /// @dev The lent side (USDG), its gage partner vault (from a factory the generation deployer recorded) and its
        /// float target.
        IERC20 lend;
        address vault;
        uint16 floatBps;
        /// @dev The float-only side (frxUSD on day one).
        IERC20 floatOnly;
        address keeper;
        /// @dev The seed, in raw units of each token.
        uint256 seedLend;
        uint256 seedFloat;
        /// @dev The creator's CREATE2 salt for both sources; a second run from the same broadcaster needs another.
        bytes32 salt;
    }

    /// @notice What the set-up leaves: the two sources, the hook and its pool.
    struct Plugged {
        IGageRehypoSource lendSource;
        IGageRehypoSource floatSource;
        UnlockCheckedHook hook;
        PoolKey key;
    }

    /// @notice The release step. Env: `POOL_MANAGER`, `GENERATION_DEPLOYER`.
    function run() external returns (address factory) {
        address deployer = msg.sender;
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address registry = vm.envAddress("GENERATION_DEPLOYER");
        vm.startBroadcast(deployer);
        factory = deployFactory(poolManager, registry);
        vm.stopBroadcast();
        console2.log("GageRehypoSourceFactory", factory);
    }

    /// @notice Deploy the factory. It keeps its registry for good, so an address that does not answer `isFactory` is
    /// refused first.
    function deployFactory(IPoolManager poolManager, address registry) public returns (address factory) {
        try IIntentFactoryRegistry(registry).isFactory(address(0)) returns (bool) {}
        catch {
            revert("GENERATION_DEPLOYER does not answer isFactory: not the generation deployer");
        }
        factory = deployCode(FACTORY_ARTIFACT, abi.encode(poolManager, registry));
    }

    /// @notice The rehearsal, never on chain 4663. The broadcaster is the partner: owner and beneficiary of both
    /// sources. Env: `REHYPO_FACTORY`, `LEND_TOKEN`, `LEND_VAULT`, `FLOAT_TOKEN`, `KEEPER`, `SEED_LEND`, `SEED_FLOAT`
    /// (raw units), and optionally `LEND_FLOAT_BPS` (default 2000) and `REHYPO_SALT`.
    function rehearse() external returns (Plugged memory p) {
        p = setUpPool(
            Pool({
                factory: IGageRehypoSourceFactory(vm.envAddress("REHYPO_FACTORY")),
                lend: IERC20(vm.envAddress("LEND_TOKEN")),
                vault: vm.envAddress("LEND_VAULT"),
                floatBps: uint16(vm.envOr("LEND_FLOAT_BPS", uint256(2000))),
                floatOnly: IERC20(vm.envAddress("FLOAT_TOKEN")),
                keeper: vm.envAddress("KEEPER"),
                seedLend: vm.envUint("SEED_LEND"),
                seedFloat: vm.envUint("SEED_FLOAT"),
                salt: vm.envOr("REHYPO_SALT", bytes32(0))
            })
        );
        console2.log("lent source      ", address(p.lendSource));
        console2.log("float-only source", address(p.floatSource));
        console2.log("hook             ", address(p.hook));
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(p.key.toId()));
        console2.log(string.concat("gage keeper entry, rehypo-sources.", vm.toString(block.chainid), ".json:"));
        console2.log(keeperFile(p));
    }

    /// @notice The partner's set-up, in the guide's order, from the caller.
    function setUpPool(Pool memory pool) public returns (Plugged memory p) {
        require(
            block.chainid != MAINNET,
            "the rehearsal never runs on chain 4663: there the partner's Safe makes these calls"
        );
        address partner = msg.sender;
        IPoolManager poolManager = pool.factory.POOL_MANAGER();
        // The sources' addresses ahead of time: a Safe batch names them in the hook's constructor before they exist.
        address lendAt =
            pool.factory.predict(partner, pool.lend, pool.vault, partner, partner, pool.floatBps, pool.salt);
        address floatAt =
            pool.factory.predict(partner, pool.floatOnly, address(0), partner, partner, ALL_FLOAT, pool.salt);
        require(
            lendAt.code.length == 0 && floatAt.code.length == 0,
            "a source already exists at this address: set another REHYPO_SALT"
        );
        bool lendFirst = address(pool.lend) < address(pool.floatOnly);

        vm.startBroadcast(partner);
        // 1. One source per pool token.
        require(
            pool.factory.create(pool.lend, pool.vault, partner, partner, pool.floatBps, pool.salt) == lendAt,
            "lent source not at its predicted address"
        );
        require(
            pool.factory.create(pool.floatOnly, address(0), partner, partner, ALL_FLOAT, pool.salt) == floatAt,
            "float-only source not at its predicted address"
        );
        // 2. The hook, naming the two sources in currency order.
        p.hook = _deployHook(poolManager, lendFirst ? lendAt : floatAt, lendFirst ? floatAt : lendAt);
        // 3. The pool, at one whole unit for one whole unit.
        p.key = PoolKey({
            currency0: Currency.wrap(lendFirst ? address(pool.lend) : address(pool.floatOnly)),
            currency1: Currency.wrap(lendFirst ? address(pool.floatOnly) : address(pool.lend)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(p.hook))
        });
        poolManager.initialize(p.key, _sqrtPriceX96(p.key, BPS));
        // 4. Each source takes the pool's hook as its one depositor.
        IGageRehypoSource(lendAt).bind(p.key);
        IGageRehypoSource(floatAt).bind(p.key);
        // 5. The seed, through the hook.
        pool.lend.approve(address(p.hook), pool.seedLend);
        pool.floatOnly.approve(address(p.hook), pool.seedFloat);
        p.hook.seedLiquidity(lendFirst ? pool.seedLend : pool.seedFloat, lendFirst ? pool.seedFloat : pool.seedLend);
        // 6. gage's keeper rebalances the lent side.
        IGageRehypoSource(lendAt).setKeeper(pool.keeper, true);
        vm.stopBroadcast();

        p.lendSource = IGageRehypoSource(lendAt);
        p.floatSource = IGageRehypoSource(floatAt);
    }

    /// @notice The keeper's band for a pegged pool: `BAND_BPS` either side of one whole unit for one whole unit.
    function band(PoolKey memory key) public view returns (uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) {
        return (_sqrtPriceX96(key, BPS - BAND_BPS), _sqrtPriceX96(key, BPS + BAND_BPS));
    }

    /// @notice gage's keeper entry (`rehypo-sources.<chainId>.json`) for the pool: its lent side with the band (the keeper
    /// leaves a float-only side alone).
    function keeperFile(Plugged memory p) public view returns (string memory) {
        (uint160 lo, uint160 hi) = band(p.key);
        string memory name = string.concat(
            _symbol(Currency.unwrap(p.key.currency0)),
            "/",
            _symbol(Currency.unwrap(p.key.currency1)),
            ", ",
            _symbol(p.lendSource.asset()),
            " side"
        );
        return string.concat(
            '{ "schemaVersion": 1, "chainId": ',
            vm.toString(block.chainid),
            ', "sources": [ { "name": "',
            name,
            '", "source": "',
            vm.toString(address(p.lendSource)),
            '", "minSqrtPriceX96": "',
            vm.toString(lo),
            '", "maxSqrtPriceX96": "',
            vm.toString(hi),
            '" } ] }'
        );
    }

    /// @dev Mine a salt whose CREATE2 address from the deterministic deployer carries the hook's flags, then deploy
    /// there (a broadcast `new` with a salt goes through that deployer).
    function _deployHook(IPoolManager poolManager, address source0, address source1)
        internal
        returns (UnlockCheckedHook hook)
    {
        (address at, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, HOOK_FLAGS, type(UnlockCheckedHook).creationCode, abi.encode(poolManager, source0, source1)
        );
        hook = new UnlockCheckedHook{salt: salt}(poolManager, source0, source1);
        require(address(hook) == at, "hook address differs from the mined one");
    }

    /// @dev floor(sqrt(price × 10^decimals1 / 10^decimals0) × 2^96), for a price of `bps / 10,000` whole currency1 per
    /// whole currency0 ("Rehypo sources"). Exact: the floor of the root of a floor is the
    /// floor of the root.
    function _sqrtPriceX96(PoolKey memory key, uint256 bps) internal view returns (uint160) {
        uint256 unit0 = 10 ** IERC20Metadata(Currency.unwrap(key.currency0)).decimals();
        uint256 unit1 = 10 ** IERC20Metadata(Currency.unwrap(key.currency1)).decimals();
        return uint160(Math.sqrt(Math.mulDiv(bps * unit1, 1 << 192, BPS * unit0)));
    }

    function _symbol(address token) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }
}
