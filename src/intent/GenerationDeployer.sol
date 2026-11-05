// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Lane} from "../interfaces/ICollateralRegistry.sol";
import {IFunderGate} from "../interfaces/IFunderGate.sol";
import {IIntentFactoryRegistry} from "../interfaces/IIntentFactoryRegistry.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {GageV2Rewards} from "../v2/GageV2Rewards.sol";
import {GageV2TokenRegistry} from "../v2/GageV2TokenRegistry.sol";
import {IntentCategory} from "./IntentVaultState.sol";
import {IntentFactory} from "./IntentFactory.sol";

/// @notice The owner setters `deploy` calls on a generation's v4 cash-out router (`V4CashoutRouter`), as on
/// `GageV2CashoutRouter`.
interface IGenerationCashoutRouter {
    /// @notice Admit or drop a v4 swap path.
    function setV4Route(PoolKey calldata key, bool allowed) external;
    /// @notice Admit or drop a canonical V3 pool.
    function setV3Route(address pool, bool allowed) external;
    /// @notice Admit or drop an aggregator executor.
    function setExecutor(address executor, bool allowed) external;
    /// @notice Hand the router to `newOwner`, who accepts it (`Ownable2Step`).
    function transferOwnership(address newOwner) external;
}

/// @notice Lists a lend-asset generation of Intent V1 on its chain in one owner call, from creation code fixed when this
/// deployer is built. It is also the registry a rehypothecation
/// source trusts: the factories it built, and r13's release generations it was
/// given once at its construction.
/// @dev Each contract of a generation is created with CREATE2 under the owner's salt from its blueprint: its exact
/// creation code, read back from one or two SSTORE2 data contracts (a leading STOP, then the code), named at
/// construction and never changeable, so `predict` gives every address before the owner's batch runs. `deploy` holds the
/// token registry, the cash-out router and the factory only while it wires them, then hands each to the owner
/// (`Ownable2Step`: the owner accepts each, in the same Safe batch); the fee processor (its path among its constructor
/// arguments), the grade registry and the rollover router are the owner's from construction. A generation leaves
/// `deploy` with funding closed: its factory's fill router is bound and closed, it has no quote signer and no creator,
/// so no vault exists and none can be funded until the owner opens it (LEND-ASSETS.md §5 step 5). A generation's id is
/// its salt; the owner lists it (`setListed`, the manifest's `public`) once it is open. No function moves funds, and
/// none adds or replaces a blueprint or a factory.
contract GenerationDeployer is IIntentFactoryRegistry, Ownable2Step {
    /// @notice A contract a generation is built from: the order of the blueprints given to the constructor.
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

    /// @notice The shared contracts every generation of this chain is wired to.
    struct Foundation {
        /// @dev The USDG the asset fee processor sells into, for `DealFeeRouter`.
        address usdg;
        address sgage;
        /// @dev Uniswap v4's PoolManager: the cash-out router's flash source, the routes' and the rollover router's.
        address poolManager;
        address weth;
        /// @dev The canonical Uniswap v3 factory the token registry names and V3 routes are checked against.
        address v3Factory;
        /// @dev `DealFeeRouter`: where the asset fee processor sends every USDG it buys.
        address feeRouter;
        /// @dev The chain's `IntentExitDesk`: the one lister whose listings fall to book, which every
        ///      generation's factory names and binds at deploy.
        address exitDesk;
    }

    /// @notice One collateral token a generation admits: its registry admission and its factory category.
    struct Admission {
        address token;
        /// @dev Informational on the core; the release keeps the lane rule off-chain.
        Lane lane;
        IntentCategory category;
        uint256 minAmount;
        uint256 maxDealRaw;
        uint256 maxOpenRaw;
    }

    /// @notice One pool of the fee processor's path and the fee its hop is allowed (`IntentAssetV4FeeProcessor.Hop`).
    struct FeeHop {
        PoolKey key;
        /// @dev For a hooked dynamic-fee pool, the fee its hook may charge in hundredths of a basis point (at most 1%);
        ///      zero for a static-fee pool, whose key carries its fee.
        uint24 feeAllowance;
    }

    /// @notice What the owner chooses for one generation. Every bound is the contracts' own, checked as they are built,
    /// except the list lengths, which this deployer bounds so a generation fits one transaction (`MAX_*`).
    struct Generation {
        /// @dev The generation's release name (`lend-<asset>-r<N>-<date>`), one to `MAX_NAME_BYTES` bytes: display only.
        string name;
        /// @dev The lend asset: the core's `USDG()`, an ERC-20 of 6 to 18 decimals, never USDG or sGAGE.
        address asset;
        /// @dev The core's terms, in seconds: one to eight, each from one to 30 days (`GageV2TokenRegistry`).
        uint32[] terms;
        uint16 feeBps;
        uint16 tradeFeeBps;
        Admission[] collateral;
        /// @dev The cash-out router's admitted v4 swap paths and canonical V3 pools, and its aggregator executors.
        PoolKey[] v4Routes;
        address[] v3Routes;
        address[] executors;
        /// @dev The fee processor's path from the asset to USDG: one or two v4 pools, each with its fee allowance.
        FeeHop[] feePath;
        /// @dev The fee processor's converter: the keeper.
        address feeKeeper;
        /// @dev The grade registry's publisher: the keeper's grade job.
        address gradePublisher;
        /// @dev The factory's filler: the keeper's filler key.
        address filler;
    }

    /// @notice A generation's contracts, as `predict` gives them and `deploy` builds them.
    struct Deployment {
        address feeProcessor;
        address reserve;
        address registry;
        address core;
        /// @dev The core's own `GageV2Rewards`, created by its constructor.
        address rewards;
        address cashoutRouter;
        address gradeRegistry;
        address factory;
        address quoteVerifier;
        address fillRouter;
        address rolloverRouter;
    }

    /// @notice The number of blueprints (`Part`).
    uint256 public constant PARTS = 11;
    /// @notice The most collateral tokens one generation admits at deploy, so that batch A at every list's longest stays
    /// two million gas under the chain's 32M a transaction (GenerationDeployer.t.sol measures it). More tokens are a
    /// later Safe batch on the registry and the factory, which the Safe owns.
    uint256 public constant MAX_ADMISSIONS = 20;
    /// @notice The most v4 and V3 routes, together, one generation's cash-out router admits at deploy.
    uint256 public constant MAX_ROUTES = 20;
    /// @notice The most aggregator executors one generation's cash-out router admits at deploy.
    uint256 public constant MAX_EXECUTORS = 4;
    /// @notice The most release factories the constructor records.
    uint256 public constant MAX_RELEASE_FACTORIES = 8;
    /// @notice The longest generation name, in bytes.
    uint256 public constant MAX_NAME_BYTES = 64;
    /// @dev The largest data one SSTORE2 chunk holds: the runtime size limit (EIP-170) less its leading STOP.
    uint256 internal constant MAX_CHUNK = 24_575;

    address public immutable USDG;
    address public immutable SGAGE;
    address public immutable POOL_MANAGER;
    address public immutable WETH;
    address public immutable V3_FACTORY;
    address public immutable FEE_ROUTER;
    /// @notice The exit desk every factory this deployer builds names.
    address public immutable EXIT_DESK;
    /// @notice How many release factories the constructor recorded: `factories(i)` below it is the release's, at or above
    /// it one `deploy` built.
    uint256 public immutable RELEASE_FACTORY_COUNT;

    /// @dev Each part's one or two chunks (the second zero when one holds it all), written by the constructor only.
    address[2][PARTS] internal _chunks;
    /// @dev Each part's creation-code size and keccak256, written by the constructor only.
    uint256[PARTS] internal _sizes;
    bytes32[PARTS] internal _hashes;
    mapping(address factory => bool) internal _recorded;
    address[] internal _factories;
    mapping(bytes32 id => address factory) internal _factoryOf;
    mapping(bytes32 id => bool) internal _listed;

    /// @notice A blueprint, fixed for good: its chunks, its creation code's size and its keccak256, which the preflight
    /// compares with the audited build.
    event BlueprintFixed(Part indexed part, address[2] chunks, uint256 size, bytes32 codeHash);
    /// @notice A factory `isFactory` answers true for from now on: one of the release's, at construction, or one
    /// `deploy` built. Its core and the asset its vaults lend are named for discovery.
    event FactoryRecorded(address indexed factory, address indexed core, address indexed asset);
    /// @notice A generation `deploy` built, its id (the owner's salt), its lend asset, every contract and its name;
    /// `FactoryRecorded` precedes it. Each contract is a top-level parameter, as an indexer's factory pattern reads it.
    event GenerationDeployed(
        bytes32 indexed id,
        address indexed asset,
        address factory,
        address core,
        address registry,
        address rewards,
        address reserve,
        address feeProcessor,
        address quoteVerifier,
        address fillRouter,
        address gradeRegistry,
        address cashoutRouter,
        address rolloverRouter,
        string name
    );
    /// @notice The owner listed or unlisted a generation it built: whether the app shows it (the manifest's `public`).
    event GenerationListed(bytes32 indexed id, bool listed);

    error InvalidFoundation();
    /// @notice A blueprint chunk is missing, has no leading STOP or holds more than one chunk may.
    error InvalidBlueprint(Part part);
    /// @notice A release factory is not a contract, is given twice, or deploys other vault code than the blueprint.
    error InvalidReleaseFactory(address factory);
    error TooManyReleaseFactories(uint256 count, uint256 max);
    /// @notice The lend asset is zero, not a contract, USDG or sGAGE.
    error InvalidAsset(address asset);
    /// @notice A collateral token is zero or the lend asset itself.
    error InvalidAdmission(address token);
    /// @notice A filler or grade publisher is zero.
    error InvalidRole();
    /// @notice Empty, or longer than `MAX_NAME_BYTES`.
    error InvalidName();
    /// @notice A generation was already built under this salt: its id.
    error SaltUsed(bytes32 id);
    /// @notice No generation was built under this id.
    error UnknownGeneration(bytes32 id);
    error TooManyAdmissions(uint256 count, uint256 max);
    error TooManyRoutes(uint256 count, uint256 max);
    error TooManyExecutors(uint256 count, uint256 max);
    /// @notice CREATE2 produced no contract: its address is taken (a salt reused for the same code) or its constructor
    /// reverted without reason. A constructor's own revert is passed on as it is.
    error DeploymentFailed(Part part);

    /// @param initialOwner The only account that deploys generations, and the owner of every contract they hold: the
    /// gage's Safe.
    /// @param foundation The chain's shared contracts (`Foundation`); each must have code.
    /// @param chunks Each part's SSTORE2 data contracts, in `Part` order: the first always, the second when the
    /// creation code is longer than one chunk holds (zero otherwise; `VAULT` always has two, the factory's `codeA` and
    /// `codeB`).
    /// @param releaseFactories r13's release generations' factories (USDG, GLD, NVDA, HIMS), recorded once. Each must
    /// create its vaults from the `VAULT` blueprint's code (`VAULT_INIT_HASH`).
    constructor(
        address initialOwner,
        Foundation memory foundation,
        address[2][PARTS] memory chunks,
        address[] memory releaseFactories
    ) Ownable(initialOwner) {
        if (
            foundation.usdg.code.length == 0 || foundation.sgage.code.length == 0
                || foundation.poolManager.code.length == 0 || foundation.weth.code.length == 0
                || foundation.v3Factory.code.length == 0 || foundation.feeRouter.code.length == 0
                || foundation.exitDesk.code.length == 0 || foundation.usdg == foundation.sgage
        ) revert InvalidFoundation();
        USDG = foundation.usdg;
        SGAGE = foundation.sgage;
        POOL_MANAGER = foundation.poolManager;
        WETH = foundation.weth;
        V3_FACTORY = foundation.v3Factory;
        FEE_ROUTER = foundation.feeRouter;
        EXIT_DESK = foundation.exitDesk;
        for (uint256 i; i < PARTS; ++i) {
            Part part = Part(i);
            address[2] memory c = chunks[i];
            uint256 size = _chunkSize(part, c[0]);
            if (c[1] != address(0)) size += _chunkSize(part, c[1]);
            else if (part == Part.VAULT) revert InvalidBlueprint(part);
            _chunks[i] = c;
            _sizes[i] = size;
            bytes32 codeHash = keccak256(_read(c, size));
            _hashes[i] = codeHash;
            emit BlueprintFixed(part, c, size, codeHash);
        }
        uint256 count = releaseFactories.length;
        if (count > MAX_RELEASE_FACTORIES) revert TooManyReleaseFactories(count, MAX_RELEASE_FACTORIES);
        for (uint256 i; i < count; ++i) {
            address factory = releaseFactories[i];
            if (
                factory.code.length == 0 || _recorded[factory]
                    || IntentFactory(factory).VAULT_INIT_HASH() != _hashes[uint256(Part.VAULT)]
            ) revert InvalidReleaseFactory(factory);
            address core = IntentFactory(factory).CORE();
            _record(factory, core, address(GageV2Vault(core).USDG()));
        }
        RELEASE_FACTORY_COUNT = count;
    }

    /// @inheritdoc IIntentFactoryRegistry
    function isFactory(address factory) external view returns (bool recorded) {
        return _recorded[factory];
    }

    /// @notice How many factories `isFactory` answers true for: the release's, then each one `deploy` built.
    function factoryCount() external view returns (uint256) {
        return _factories.length;
    }

    /// @notice A recorded factory by its index, in the order recorded.
    function factories(uint256 index) external view returns (address) {
        return _factories[index];
    }

    /// @notice The factory of the generation `deploy` built under `id`, zero when none was.
    function factoryOf(bytes32 id) external view returns (address) {
        return _factoryOf[id];
    }

    /// @notice Whether the generation built under `id` is listed: shown by the app (the manifest's `public`).
    function listed(bytes32 id) external view returns (bool) {
        return _listed[id];
    }

    /// @notice List or unlist a generation this deployer built: the last call of its batch B, once it is open. Display
    /// only: it changes no contract of the generation and no funding. The owner only.
    /// @param id The generation's id, its salt.
    /// @param listed_ Whether the app shows it.
    function setListed(bytes32 id, bool listed_) external onlyOwner {
        if (_factoryOf[id] == address(0)) revert UnknownGeneration(id);
        _listed[id] = listed_;
        emit GenerationListed(id, listed_);
    }

    /// @notice A part's blueprint: its chunks, its creation code's size and keccak256.
    function blueprint(Part part) external view returns (address[2] memory chunks, uint256 size, bytes32 codeHash) {
        uint256 i = uint256(part);
        return (_chunks[i], _sizes[i], _hashes[i]);
    }

    /// @notice A part's exact creation code, as its blueprint holds it.
    function creationCode(Part part) external view returns (bytes memory code) {
        uint256 i = uint256(part);
        return _read(_chunks[i], _sizes[i]);
    }

    /// @notice Every address `deploy(salt, g)` would build now, from this owner, while `salt` is unused.
    /// @param salt The owner's salt, the generation's id.
    /// @param g The generation's choices.
    /// @return d The generation's contracts, `rewards` included.
    function predict(bytes32 salt, Generation calldata g) external view returns (Deployment memory d) {
        d.feeProcessor = _predicted(Part.FEE_PROCESSOR, _feeProcessorArgs(g), salt);
        d.reserve = _predicted(Part.CLOSED_RESERVE, abi.encode(g.asset), salt);
        d.registry = _predicted(Part.TOKEN_REGISTRY, _registryArgs(g), salt);
        d.core = _predicted(Part.CORE, _coreArgs(g, d), salt);
        d.rewards = _createdBy(d.core);
        d.cashoutRouter = _predicted(Part.CASHOUT_ROUTER, _cashoutArgs(d), salt);
        d.gradeRegistry = _predicted(Part.GRADE_REGISTRY, abi.encode(owner(), g.gradePublisher), salt);
        d.factory = _predicted(Part.FACTORY, _factoryArgs(d), salt);
        d.quoteVerifier = _predicted(Part.QUOTE_VERIFIER, abi.encode(d.factory), salt);
        d.fillRouter = _predicted(Part.FILL_ROUTER, abi.encode(d.quoteVerifier, g.asset), salt);
        d.rolloverRouter = _predicted(Part.ROLLOVER_ROUTER, abi.encode(d.fillRouter, POOL_MANAGER, owner()), salt);
    }

    /// @notice Build, wire and record one generation, funding closed (LEND-ASSETS.md §5 step 1). The owner only; in the
    /// same Safe batch it accepts the token registry, the cash-out router and the factory, which this call hands it.
    /// Its addresses are `predict(salt, g)`'s.
    /// @dev Wiring, in order: the registry's fees, admissions and the rollover router as its router; the core's funder
    /// gate bound to the factory; the cash-out router's routes and executors; the factory's categories and
    /// fillers (the keeper's, the rollover router), its fill router bound then closed, so no other router can ever be
    /// bound to it (Pashov L-02/L-05), and the chain's exit desk, bound the same way.
    /// @param salt The owner's salt, the generation's id: one generation a salt.
    /// @param g The generation's choices.
    /// @return d The generation's contracts.
    function deploy(bytes32 salt, Generation calldata g) external onlyOwner returns (Deployment memory d) {
        if (_factoryOf[salt] != address(0)) revert SaltUsed(salt);
        _check(g);
        d.feeProcessor = _create(Part.FEE_PROCESSOR, _feeProcessorArgs(g), salt);
        d.reserve = _create(Part.CLOSED_RESERVE, abi.encode(g.asset), salt);
        d.registry = _create(Part.TOKEN_REGISTRY, _registryArgs(g), salt);
        d.core = _create(Part.CORE, _coreArgs(g, d), salt);
        d.rewards = address(GageV2Vault(d.core).REWARDS());
        d.cashoutRouter = _create(Part.CASHOUT_ROUTER, _cashoutArgs(d), salt);
        d.gradeRegistry = _create(Part.GRADE_REGISTRY, abi.encode(owner(), g.gradePublisher), salt);
        d.factory = _create(Part.FACTORY, _factoryArgs(d), salt);
        d.quoteVerifier = _create(Part.QUOTE_VERIFIER, abi.encode(d.factory), salt);
        d.fillRouter = _create(Part.FILL_ROUTER, abi.encode(d.quoteVerifier, g.asset), salt);
        d.rolloverRouter = _create(Part.ROLLOVER_ROUTER, abi.encode(d.fillRouter, POOL_MANAGER, owner()), salt);
        _wire(g, d);
        _factoryOf[salt] = d.factory;
        _record(d.factory, d.core, g.asset);
        emit GenerationDeployed(
            salt,
            g.asset,
            d.factory,
            d.core,
            d.registry,
            d.rewards,
            d.reserve,
            d.feeProcessor,
            d.quoteVerifier,
            d.fillRouter,
            d.gradeRegistry,
            d.cashoutRouter,
            d.rolloverRouter,
            g.name
        );
    }

    function _wire(Generation calldata g, Deployment memory d) internal {
        GageV2TokenRegistry registry = GageV2TokenRegistry(d.registry);
        registry.setFee(g.feeBps);
        registry.setTradeFee(g.tradeFeeBps);
        uint256 count = g.collateral.length;
        for (uint256 i; i < count; ++i) {
            Admission calldata a = g.collateral[i];
            registry.setERC20Allowed(a.token, true, a.lane, a.minAmount, a.maxDealRaw, a.maxOpenRaw);
        }
        registry.setRouter(d.rolloverRouter, true);
        GageV2Rewards(d.rewards).bindFunderGate(IFunderGate(d.factory));
        IGenerationCashoutRouter cashout = IGenerationCashoutRouter(d.cashoutRouter);
        for (uint256 i; i < g.v4Routes.length; ++i) {
            cashout.setV4Route(g.v4Routes[i], true);
        }
        for (uint256 i; i < g.v3Routes.length; ++i) {
            cashout.setV3Route(g.v3Routes[i], true);
        }
        for (uint256 i; i < g.executors.length; ++i) {
            cashout.setExecutor(g.executors[i], true);
        }
        IntentFactory factory = IntentFactory(d.factory);
        for (uint256 i; i < count; ++i) {
            factory.assignCategory(g.collateral[i].token, g.collateral[i].category);
        }
        factory.setFiller(g.filler, true);
        factory.setFiller(d.rolloverRouter, true);
        factory.setFillRouter(d.fillRouter);
        factory.setFillRouter(address(0));
        factory.setExitDesk(EXIT_DESK);
        address safe = owner();
        registry.transferOwnership(safe);
        cashout.transferOwnership(safe);
        factory.transferOwnership(safe);
    }

    function _check(Generation calldata g) internal view {
        uint256 nameLength = bytes(g.name).length;
        if (nameLength == 0 || nameLength > MAX_NAME_BYTES) revert InvalidName();
        address asset = g.asset;
        if (asset.code.length == 0 || asset == USDG || asset == SGAGE) revert InvalidAsset(asset);
        uint256 count = g.collateral.length;
        if (count > MAX_ADMISSIONS) revert TooManyAdmissions(count, MAX_ADMISSIONS);
        for (uint256 i; i < count; ++i) {
            address token = g.collateral[i].token;
            if (token == address(0) || token == asset) revert InvalidAdmission(token);
        }
        uint256 routes = g.v4Routes.length + g.v3Routes.length;
        if (routes > MAX_ROUTES) revert TooManyRoutes(routes, MAX_ROUTES);
        if (g.executors.length > MAX_EXECUTORS) revert TooManyExecutors(g.executors.length, MAX_EXECUTORS);
        if (g.filler == address(0) || g.gradePublisher == address(0)) revert InvalidRole();
    }

    function _record(address factory, address core, address asset) internal {
        _recorded[factory] = true;
        _factories.push(factory);
        emit FactoryRecorded(factory, core, asset);
    }

    // The constructor arguments of each part, from the generation's choices and the parts built before it.

    /// @dev The owner's from construction: its path is a constructor argument, so nothing is left to wire.
    function _feeProcessorArgs(Generation calldata g) internal view returns (bytes memory) {
        return abi.encode(g.asset, USDG, POOL_MANAGER, g.feePath, FEE_ROUTER, g.feeKeeper, owner());
    }

    function _registryArgs(Generation calldata g) internal view returns (bytes memory) {
        return abi.encode(address(this), g.terms, V3_FACTORY);
    }

    /// @dev Unbridged (no `GageLegacyAdapter`), no grace, its fee recipient the asset fee processor.
    function _coreArgs(Generation calldata g, Deployment memory d) internal view returns (bytes memory) {
        return abi.encode(d.registry, g.asset, SGAGE, d.feeProcessor, uint32(0), address(0));
    }

    function _cashoutArgs(Deployment memory d) internal view returns (bytes memory) {
        return abi.encode(d.core, POOL_MANAGER, WETH, address(this));
    }

    /// @dev The closed reserve's own views measure it, so the factory has no reserve lens (LEND-ASSETS.md §1).
    function _factoryArgs(Deployment memory d) internal view returns (bytes memory) {
        address[2] memory vault = _chunks[uint256(Part.VAULT)];
        return abi.encode(
            IntentFactory.Params({
                core: d.core,
                reserve: d.reserve,
                reserveLens: address(0),
                grades: d.gradeRegistry,
                protocolRecipient: d.feeProcessor,
                initialOwner: address(this),
                codeA: vault[0],
                codeB: vault[1]
            })
        );
    }

    // Blueprints.

    /// @dev One chunk's data size: code behind a leading STOP, at most `MAX_CHUNK` bytes.
    function _chunkSize(Part part, address chunk) internal view returns (uint256 size) {
        size = chunk.code.length;
        if (size < 2 || size > MAX_CHUNK + 1) revert InvalidBlueprint(part);
        uint256 first;
        assembly ("memory-safe") {
            extcodecopy(chunk, 0, 0, 1)
            first := shr(248, mload(0))
        }
        if (first != 0) revert InvalidBlueprint(part);
        return size - 1;
    }

    /// @dev The creation code a blueprint holds, `size` bytes: each chunk's data after its STOP, joined.
    function _read(address[2] memory c, uint256 size) internal view returns (bytes memory code) {
        code = new bytes(size);
        address a = c[0];
        address b = c[1];
        assembly ("memory-safe") {
            let first := sub(extcodesize(a), 1)
            extcodecopy(a, add(code, 0x20), 1, first)
            if b { extcodecopy(b, add(add(code, 0x20), first), 1, sub(size, first)) }
        }
    }

    /// @dev The CREATE2 address of a part built from its blueprint with `args`. The creation code is laid out in free
    /// memory without claiming it, so every part costs the memory of the largest only.
    function _predicted(Part part, bytes memory args, bytes32 salt) internal view returns (address) {
        uint256 i = uint256(part);
        uint256 size = _sizes[i];
        address a = _chunks[i][0];
        address b = _chunks[i][1];
        bytes32 initHash;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let first := sub(extcodesize(a), 1)
            extcodecopy(a, ptr, 1, first)
            if b { extcodecopy(b, add(ptr, first), 1, sub(size, first)) }
            let argsLength := mload(args)
            mcopy(add(ptr, size), add(args, 0x20), argsLength)
            initHash := keccak256(ptr, add(size, argsLength))
        }
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    /// @dev Build a part from its blueprint with `args` by CREATE2, laid out as `_predicted` lays it out.
    function _create(Part part, bytes memory args, bytes32 salt) internal returns (address created) {
        uint256 i = uint256(part);
        uint256 size = _sizes[i];
        address a = _chunks[i][0];
        address b = _chunks[i][1];
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let first := sub(extcodesize(a), 1)
            extcodecopy(a, ptr, 1, first)
            if b { extcodecopy(b, add(ptr, first), 1, sub(size, first)) }
            let argsLength := mload(args)
            mcopy(add(ptr, size), add(args, 0x20), argsLength)
            created := create2(0, ptr, add(size, argsLength), salt)
            if iszero(created) {
                if returndatasize() {
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
        }
        if (created == address(0)) revert DeploymentFailed(part);
    }

    /// @dev The first contract `creator`'s constructor creates (its nonce 1): the core's `REWARDS`.
    function _createdBy(address creator) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), creator, bytes1(0x01))))));
    }
}
