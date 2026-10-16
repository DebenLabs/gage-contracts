// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {DealVault} from "../src/DealVault.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {SGAGE} from "../src/token/SGAGE.sol";
import {Drip} from "../src/token/Drip.sol";
import {Emissions} from "../src/token/Emissions.sol";
import {DealRewards} from "../src/token/DealRewards.sol";
import {LPHook} from "../src/token/LPHook.sol";
import {LPRewards} from "../src/token/LPRewards.sol";
import {SeedTimelock} from "../src/token/SeedTimelock.sol";
import {Buyback} from "../src/token/Buyback.sol";
import {CreatorFeeSplitter} from "../src/token/CreatorFeeSplitter.sol";
import {ReinvestRouter} from "../src/token/ReinvestRouter.sol";
import {IsGAGE} from "../src/interfaces/token/IsGAGE.sol";
import {ILPRewards} from "../src/interfaces/token/ILPRewards.sol";
import {PositionMath} from "../src/libraries/PositionMath.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Testnet deployment of the whole token layer on top of the M1 vault and the testnet v4 instance: a mock
///         GAGE (the real one is a Pons launch on mainnet), sGAGE, Drip, Emissions, DealRewards, the mined LPHook,
///         LPRewards, SeedTimelock, Buyback, CreatorFeeSplitter, ReinvestRouter; five pools with liquidity; the seed
///         locked; FeeSink switched to BUYBACK; emissions launched; epoch-0 rates posted; the stock/USDG pool
///         allowlisted for position collateral. Owner of everything ownable is the deployer (a Safe on mainnet).
/// @dev Env: TESTNET_DEPLOYER_KEY, BORROWER_KEY (gets a stock/USDG position to list), optional DEPLOYMENT_TAG,
///      GAGE_TESTNET_SALT. Reads and extends deployments/<chainId><tag>.json.
contract DeployTokenLayer is DeploymentFile {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    int24 internal constant SPACING = 60;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;

    // inputs
    string internal path;
    uint256 internal deployerKey;
    address internal deployer;
    address internal borrower;
    bytes32 internal salt;
    IPoolManager internal poolManager;
    IPositionManager internal posm;
    IAllowanceTransfer internal permit2;
    PoolModifyLiquidityTest internal lpRouter;
    DealVault internal vault;
    CollateralRegistry internal registry;
    FeeSink internal feeSink;
    MockERC20 internal usdg;
    MockERC20 internal nvda;
    MockERC20 internal meme;

    // outputs
    MockERC20 internal gage;
    Emissions internal emissions;
    SGAGE internal sgage;
    Drip internal drip;
    LPHook internal hook;
    LPRewards internal lpRewards;
    DealRewards internal dealRewards;
    SeedTimelock internal seedTimelock;
    Buyback internal buyback;
    CreatorFeeSplitter internal splitter;
    ReinvestRouter internal reinvest;
    PoolKey internal gageSgage;
    PoolKey internal gageEth;
    PoolKey internal usdgEth;
    PoolKey internal nvdaUsdg;
    PoolKey internal nvdogNvda;
    uint256 internal seedId;
    uint256 internal borrowerPositionId;

    function run() external {
        _load();
        vm.startBroadcast(deployerKey);
        _deployTokens();
        _deployHookAndPools();
        _deployRewards();
        _deployRouters();
        _seedAndWire();
        _launch();
        vm.stopBroadcast();
        _write();
    }

    // ----------------------------------------------------------------- steps

    function _load() internal {
        deployerKey = vm.envUint("TESTNET_DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);
        borrower = vm.addr(vm.envUint("BORROWER_KEY"));
        salt = keccak256(bytes(vm.envOr("GAGE_TESTNET_SALT", string("gage.testnet.v1"))));
        path =
            string.concat("deployments/", vm.toString(block.chainid), vm.envOr("DEPLOYMENT_TAG", string("")), ".json");
        string memory json = vm.readFile(path);
        poolManager = IPoolManager(vm.parseJsonAddress(json, ".PoolManager"));
        posm = IPositionManager(vm.parseJsonAddress(json, ".PositionManager"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(json, ".Permit2"));
        lpRouter = PoolModifyLiquidityTest(vm.parseJsonAddress(json, ".LiquidityRouter"));
        vault = DealVault(vm.parseJsonAddress(json, ".DealVault"));
        registry = CollateralRegistry(vm.parseJsonAddress(json, ".CollateralRegistry"));
        feeSink = FeeSink(vm.parseJsonAddress(json, ".FeeSink"));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        nvda = MockERC20(vm.parseJsonAddress(json, ".NVDAx"));
        meme = MockERC20(vm.parseJsonAddress(json, ".NVDOG"));
    }

    function _deployTokens() internal {
        gage = new MockERC20{salt: salt}("Test GAGE", "tGAGE", 18);
        gage.mint(deployer, 10_000_000e18);
        emissions = new Emissions{salt: salt}(deployer, deployer);
        sgage = new SGAGE{salt: salt}(address(emissions), deployer);
        drip = new Drip{salt: salt}(sgage, deployer);
        usdg.mint(deployer, 10_000_000e6);
        nvda.mint(deployer, 100_000e18);
        meme.mint(deployer, 100_000_000e18);
    }

    function _deployHookAndPools() internal {
        (, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER,
            uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG),
            type(LPHook).creationCode,
            abi.encode(poolManager, address(posm), deployer)
        );
        hook = new LPHook{salt: hookSalt}(poolManager, address(posm), deployer);

        // 1 GAGE = 1,000 sGAGE (3% fee, hooked); 1 ETH = 1,000 GAGE; 1 ETH = 3,000 USDG; 1 NVDAx = 100 USDG;
        // 1 NVDAx = 1,000 NVDOG. A token-layer redeploy on a kept vault layer meets the USDG, NVDAx and NVDOG pools
        // already initialized and funded: those are reused as they are (D48).
        (gageSgage,) = _init(address(gage), 1e18, address(sgage), 1000e18, address(hook), 30_000);
        (gageEth,) = _init(address(0), 1e18, address(gage), 1000e18, address(0), 3000);
        bool usdgEthFresh;
        bool nvdaUsdgFresh;
        bool nvdogNvdaFresh;
        (usdgEth, usdgEthFresh) = _init(address(0), 1e18, address(usdg), 3000e6, address(0), 3000);
        (nvdaUsdg, nvdaUsdgFresh) = _init(address(nvda), 1e18, address(usdg), 100e6, address(0), 3000);
        (nvdogNvda, nvdogNvdaFresh) = _init(address(meme), 1000e18, address(nvda), 1e18, address(0), 3000);

        _approvePosm(address(gage));
        _approvePosm(address(sgage));
        _approvePosm(address(usdg));
        _approvePosm(address(nvda));
        _approvePosm(address(meme));

        // ERC-20 pools through the PositionManager; native pools through the liquidity router
        seedId = _mintFullRange(gageSgage, 2e24, deployer); // ~63k GAGE + 63M sGAGE
        if (nvdaUsdgFresh) _mintFullRange(nvdaUsdg, 1e16, deployer); // ~1,000 NVDAx + 100k USDG
        borrowerPositionId = _mintFullRange(nvdaUsdg, 1e14, borrower); // ~10 NVDAx + 1,000 USDG, for listing
        if (nvdogNvdaFresh) _mintFullRange(nvdogNvda, 1e21, deployer); // ~1k NVDAx + 1M NVDOG
        // 3e19 is ~1 ETH + 1,000 GAGE; GAGE_ETH_LIQUIDITY scales it down when the deployer runs low on testnet ETH
        _addNative(gageEth, uint128(vm.envOr("GAGE_ETH_LIQUIDITY", uint256(3e19))));
        if (usdgEthFresh) _addNative(usdgEth, 5.5e13); // ~1 ETH + 3,000 USDG
    }

    function _deployRewards() internal {
        lpRewards = new LPRewards{salt: salt}(sgage, drip, emissions, posm, address(hook), gageSgage, deployer);
        hook.setLPRewards(lpRewards);
        dealRewards = new DealRewards{salt: salt}(vault, emissions, drip, sgage, 6, deployer);
        emissions.wire(sgage, lpRewards, address(dealRewards));
        drip.setGrantors(address(dealRewards), address(lpRewards));
        seedTimelock = new SeedTimelock{salt: salt}(posm, deployer);
    }

    function _deployRouters() internal {
        buyback = new Buyback{salt: salt}(
            Buyback.Params({
                poolManager: poolManager,
                usdg: usdg,
                sgage: IsGAGE(address(sgage)),
                gage: address(gage),
                usdgEth: usdgEth,
                gageEth: gageEth,
                gageSgage: gageSgage,
                launchPoolFeePips: 3000,
                threshold: 1e6,
                bountyBps: 50,
                initialOwner: deployer
            })
        );
        splitter = new CreatorFeeSplitter{salt: salt}(
            CreatorFeeSplitter.Params({
                poolManager: poolManager,
                positionManager: posm,
                permit2: permit2,
                opsWallet: deployer,
                sgage: sgage,
                gage: address(gage),
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
        reinvest = new ReinvestRouter{salt: salt}(
            ReinvestRouter.Params({
                poolManager: poolManager,
                posm: posm,
                permit2: permit2,
                sgage: sgage,
                gage: gage,
                usdg: usdg,
                gageSgage: gageSgage,
                gageEth: gageEth,
                usdgEth: usdgEth
            })
        );
    }

    function _seedAndWire() internal {
        IERC721(address(posm)).approve(address(seedTimelock), seedId);
        seedTimelock.lock(seedId);
        lpRewards.setSeed(seedId);
        lpRewards.setFloor(address(splitter));
        feeSink.setBuyback(address(buyback));
        feeSink.setRoute(FeeSink.Route.BUYBACK);
        registry.setPoolAllowed(PoolId.unwrap(nvdaUsdg.toId()), true, 1e12);
        // the borrower can list its position and reinvest from day one
        gage.mint(borrower, 10_000e18);
        sgage.transfer(borrower, 1_000_000e18);
    }

    function _launch() internal {
        // ten minutes back: the broadcast lands after the block the script was simulated in
        emissions.launch(uint40(block.timestamp - 10 minutes));
        // 1 sGAGE = 0.003 USDG at 1 GAGE = 3 USDG; the 80% cap binds at ~267 sGAGE per USDG of fee
        dealRewards.setEpochRates(0, 1000e18, 2000e18, 3000, 5000);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Initializes the pool at the given price, or reuses it when it already has one; `fresh` says which.
    function _init(address a, uint256 amountA, address b, uint256 amountB, address hooks, uint24 fee)
        internal
        returns (PoolKey memory key, bool fresh)
    {
        (Currency c0, Currency c1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
        bool aIsZero = Currency.unwrap(c0) == a;
        uint160 sqrtPrice = uint160(
            Math.sqrt(aIsZero ? Math.mulDiv(amountB, 1 << 192, amountA) : Math.mulDiv(amountA, 1 << 192, amountB))
        );
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: SPACING, hooks: IHooks(hooks)});
        (uint160 existing,,,) = _slot0(key);
        fresh = existing == 0;
        if (fresh) poolManager.initialize(key, sqrtPrice);
        else console2.log("pool already initialized, reused", Currency.unwrap(c0), Currency.unwrap(c1));
    }

    function _approvePosm(address token) internal {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(posm), type(uint160).max, type(uint48).max);
    }

    function _mintFullRange(PoolKey memory key, uint128 liquidity, address recipient) internal returns (uint256 id) {
        id = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, FULL_LOWER, FULL_UPPER, uint256(liquidity), type(uint128).max, type(uint128).max, recipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    /// @dev Native pools: pay the exact ETH the full-range liquidity needs plus a hair, through the test router.
    function _addNative(PoolKey memory key, uint128 liquidity) internal {
        (uint160 sqrtP,,,) = _slot0(key);
        (uint256 eth,) = PositionMath.amountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(FULL_LOWER), TickMath.getSqrtPriceAtTick(FULL_UPPER), liquidity
        );
        IERC20(Currency.unwrap(key.currency1)).approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: eth + 1e12}(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
    }

    function _slot0(PoolKey memory key) internal view returns (uint160 sqrtPriceX96, int24 tick, uint24 a, uint24 b) {
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), uint256(6)));
        bytes32 data = poolManager.extsload(slot);
        sqrtPriceX96 = uint160(uint256(data));
        tick = int24(int256(uint256(data) >> 160));
        return (sqrtPriceX96, tick, a, b);
    }

    function _write() internal {
        _carryForward(vm.readFile(path));
        vm.serializeAddress(OBJ, "GAGE", address(gage));
        vm.serializeAddress(OBJ, "sGAGE", address(sgage));
        vm.serializeAddress(OBJ, "Drip", address(drip));
        vm.serializeAddress(OBJ, "Emissions", address(emissions));
        vm.serializeAddress(OBJ, "DealRewards", address(dealRewards));
        vm.serializeAddress(OBJ, "LPRewards", address(lpRewards));
        vm.serializeAddress(OBJ, "LPHook", address(hook));
        vm.serializeAddress(OBJ, "Buyback", address(buyback));
        vm.serializeAddress(OBJ, "CreatorFeeSplitter", address(splitter));
        vm.serializeAddress(OBJ, "ReinvestRouter", address(reinvest));
        vm.serializeAddress(OBJ, "SeedTimelock", address(seedTimelock));
        vm.serializeUint(OBJ, "seedTokenId", seedId);
        vm.serializeUint(OBJ, "borrowerPositionId", borrowerPositionId);
        // through _addPool so pools other scripts added (the faucet assets) are carried, not dropped
        _addPool("gageSgage", _pool("gageSgage", gageSgage));
        _addPool("gageEth", _pool("gageEth", gageEth));
        _addPool("usdgEth", _pool("usdgEth", usdgEth));
        _addPool("nvdaUsdg", _pool("nvdaUsdg", nvdaUsdg));
        string memory out = _addPool("nvdogNvda", _pool("nvdogNvda", nvdogNvda));
        vm.writeJson(out, path);
        console2.log("GAGE (mock)        ", address(gage));
        console2.log("sGAGE              ", address(sgage));
        console2.log("Emissions          ", address(emissions));
        console2.log("Drip               ", address(drip));
        console2.log("DealRewards        ", address(dealRewards));
        console2.log("LPHook             ", address(hook));
        console2.log("LPRewards          ", address(lpRewards));
        console2.log("SeedTimelock       ", address(seedTimelock));
        console2.log("Buyback            ", address(buyback));
        console2.log("CreatorFeeSplitter ", address(splitter));
        console2.log("ReinvestRouter     ", address(reinvest));
        console2.log("seed tokenId       ", seedId);
        console2.log("borrower position  ", borrowerPositionId);
        console2.log("written", path);
    }

    function _pool(string memory name, PoolKey memory key) internal returns (string memory) {
        vm.serializeAddress(name, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(name, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(name, "fee", key.fee);
        vm.serializeInt(name, "tickSpacing", key.tickSpacing);
        vm.serializeAddress(name, "hooks", address(key.hooks));
        return vm.serializeBytes32(name, "poolId", PoolId.unwrap(key.toId()));
    }
}
