// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";
import {DeploymentFile} from "./DeploymentFile.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Testnet only. Widens the collateral menu the faucet (services/faucet) hands out: three more stock
///         tokens (one with 8 decimals), two more memes (one paired with a stock, one paired with USDG so the
///         screening panel has something to reject), a priced USDG pool for each stock, the stock pools allowlisted
///         for position collateral. Every token is a `MockERC20` with open `mint`, like the existing three.
/// @dev Env: TESTNET_DEPLOYER_KEY (the registry owner on testnet), optional DEPLOYMENT_TAG, GAGE_TESTNET_SALT.
///      Reads and extends deployments/<chainId><tag>.json; run once per salt (CREATE2 collides otherwise).
contract DeployFaucetAssets is DeploymentFile {
    using PoolIdLibrary for PoolKey;

    int24 internal constant SPACING = 60;
    int24 internal constant FULL_LOWER = -887_220;
    int24 internal constant FULL_UPPER = 887_220;
    uint24 internal constant FEE = 3000;
    uint128 internal constant STOCK_POOL_MIN_LIQUIDITY = 1e12;
    /// @dev MSFTx has 8 decimals, so its pool liquidity runs ~1e5 smaller than the 18-decimal stocks.
    uint128 internal constant MSFT_POOL_MIN_LIQUIDITY = 1e6;

    string internal path;
    uint256 internal deployerKey;
    address internal deployer;
    bytes32 internal salt;

    IPoolManager internal poolManager;
    IPositionManager internal posm;
    IAllowanceTransfer internal permit2;
    CollateralRegistry internal registry;
    MockERC20 internal usdg;

    MockERC20 internal aapl;
    MockERC20 internal tsla;
    MockERC20 internal msft;
    MockERC20 internal apepe;
    MockERC20 internal moon;

    PoolKey internal aaplUsdg;
    PoolKey internal tslaUsdg;
    PoolKey internal msftUsdg;
    PoolKey internal apepeAapl;
    PoolKey internal moonUsdg;

    function run() external {
        _load();
        vm.startBroadcast(deployerKey);
        _deployTokens();
        _pools();
        _allowlist();
        vm.stopBroadcast();
        _write();
    }

    function _load() internal {
        deployerKey = vm.envUint("TESTNET_DEPLOYER_KEY");
        deployer = vm.addr(deployerKey);
        salt = keccak256(bytes(vm.envOr("GAGE_TESTNET_SALT", string("gage.testnet.v1"))));
        path =
            string.concat("deployments/", vm.toString(block.chainid), vm.envOr("DEPLOYMENT_TAG", string("")), ".json");
        string memory json = vm.readFile(path);
        poolManager = IPoolManager(vm.parseJsonAddress(json, ".PoolManager"));
        posm = IPositionManager(vm.parseJsonAddress(json, ".PositionManager"));
        permit2 = IAllowanceTransfer(vm.parseJsonAddress(json, ".Permit2"));
        registry = CollateralRegistry(vm.parseJsonAddress(json, ".CollateralRegistry"));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        require(registry.owner() == deployer, "deployer must own the registry");
    }

    function _deployTokens() internal {
        aapl = new MockERC20{salt: salt}("Test Apple Stock Token", "tAAPLx", 18);
        tsla = new MockERC20{salt: salt}("Test Tesla Stock Token", "tTSLAx", 18);
        msft = new MockERC20{salt: salt}("Test Microsoft Stock Token", "tMSFTx", 8);
        apepe = new MockERC20{salt: salt}("Test Apple Pepe", "tAPEPE", 18);
        moon = new MockERC20{salt: salt}("Test Moon Coin", "tMOON", 18);

        // the deployer pays the liquidity below
        aapl.mint(deployer, 1_000_000e18);
        tsla.mint(deployer, 1_000_000e18);
        msft.mint(deployer, 1_000_000e8);
        apepe.mint(deployer, 1_000_000_000e18);
        moon.mint(deployer, 1_000_000_000e18);
        usdg.mint(deployer, 10_000_000e6);
    }

    function _pools() internal {
        // 1 AAPLx = 230 USDG; 1 TSLAx = 250 USDG; 1 MSFTx = 500 USDG; 1 AAPLx = 100,000 APEPE; 1 USDG = 1,000 MOON
        aaplUsdg = _init(address(aapl), 1e18, address(usdg), 230e6);
        tslaUsdg = _init(address(tsla), 1e18, address(usdg), 250e6);
        msftUsdg = _init(address(msft), 1e8, address(usdg), 500e6);
        apepeAapl = _init(address(apepe), 100_000e18, address(aapl), 1e18);
        moonUsdg = _init(address(moon), 1000e18, address(usdg), 1e6);

        _approvePosm(address(usdg));
        _approvePosm(address(aapl));
        _approvePosm(address(tsla));
        _approvePosm(address(msft));
        _approvePosm(address(apepe));
        _approvePosm(address(moon));

        _mintFullRange(aaplUsdg, 1.5e16); // ~1,000 AAPLx + 230k USDG
        _mintFullRange(tslaUsdg, 1.5e16); // ~1,000 TSLAx + 250k USDG
        _mintFullRange(msftUsdg, 2e11); // ~900 MSFTx + 450k USDG
        _mintFullRange(apepeAapl, 3e22); // ~95 AAPLx + 9.5M APEPE
        _mintFullRange(moonUsdg, 3e18); // ~95k USDG + 95M MOON
    }

    function _allowlist() internal {
        registry.setERC20Allowed(address(aapl), true, Lane.STOCK, 1e18, 1000e18, 5000e18);
        registry.setERC20Allowed(address(tsla), true, Lane.STOCK, 1e18, 2000e18, 10_000e18);
        registry.setERC20Allowed(address(msft), true, Lane.STOCK, 1e8, 1000e8, 5000e8);
        registry.setERC20Allowed(address(apepe), true, Lane.MEME, 10_000e18, 10_000_000e18, 50_000_000e18);
        registry.setERC20Allowed(address(moon), true, Lane.MEME, 100_000e18, 50_000_000e18, 200_000_000e18);
        registry.setPoolAllowed(PoolId.unwrap(aaplUsdg.toId()), true, STOCK_POOL_MIN_LIQUIDITY);
        registry.setPoolAllowed(PoolId.unwrap(tslaUsdg.toId()), true, STOCK_POOL_MIN_LIQUIDITY);
        registry.setPoolAllowed(PoolId.unwrap(msftUsdg.toId()), true, MSFT_POOL_MIN_LIQUIDITY);
    }

    // ----------------------------------------------------------------- helpers

    function _init(address a, uint256 amountA, address b, uint256 amountB) internal returns (PoolKey memory key) {
        (Currency c0, Currency c1) = a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
        bool aIsZero = Currency.unwrap(c0) == a;
        uint160 sqrtPrice = uint160(
            Math.sqrt(aIsZero ? Math.mulDiv(amountB, 1 << 192, amountA) : Math.mulDiv(amountA, 1 << 192, amountB))
        );
        key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        poolManager.initialize(key, sqrtPrice);
    }

    function _approvePosm(address token) internal {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(posm), type(uint160).max, type(uint48).max);
    }

    function _mintFullRange(PoolKey memory key, uint128 liquidity) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, FULL_LOWER, FULL_UPPER, uint256(liquidity), type(uint128).max, type(uint128).max, deployer, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
    }

    function _write() internal {
        _carryForward(vm.readFile(path));
        vm.serializeAddress(OBJ, "AAPLx", address(aapl));
        vm.serializeAddress(OBJ, "TSLAx", address(tsla));
        vm.serializeAddress(OBJ, "MSFTx", address(msft));
        vm.serializeAddress(OBJ, "APEPE", address(apepe));
        vm.serializeAddress(OBJ, "MOON", address(moon));
        _addPool("aaplUsdg", _pool("aaplUsdg", aaplUsdg));
        _addPool("tslaUsdg", _pool("tslaUsdg", tslaUsdg));
        _addPool("msftUsdg", _pool("msftUsdg", msftUsdg));
        _addPool("apepeAapl", _pool("apepeAapl", apepeAapl));
        string memory out = _addPool("moonUsdg", _pool("moonUsdg", moonUsdg));
        vm.writeJson(out, path);
        console2.log("AAPLx  ", address(aapl));
        console2.log("TSLAx  ", address(tsla));
        console2.log("MSFTx  ", address(msft));
        console2.log("APEPE  ", address(apepe));
        console2.log("MOON   ", address(moon));
        console2.log("written", path);
    }

    function _pool(string memory name, PoolKey memory key) internal returns (string memory) {
        vm.serializeAddress(name, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(name, "currency1", Currency.unwrap(key.currency1));
        vm.serializeUint(name, "fee", key.fee);
        vm.serializeInt(name, "tickSpacing", key.tickSpacing);
        vm.serializeAddress(name, "hooks", address(key.hooks));
        vm.serializeUint(name, "createdAt", block.timestamp);
        return vm.serializeBytes32(name, "poolId", PoolId.unwrap(key.toId()));
    }
}
