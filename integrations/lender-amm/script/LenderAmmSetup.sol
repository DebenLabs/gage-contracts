// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {GageLenderHook} from "../src/GageLenderHook.sol";
import {IGageVault} from "../src/interfaces/IGageVault.sol";
import {IIntentFactory} from "../src/interfaces/IIntentFactory.sol";

/// @notice What the deploy script and the fork suite share: the network's addresses from gage's manifest, the pool's
/// two mandates, and the hook's mined address. Defaults are the testnet rehearsal's; every one is an environment
/// variable (README.md).
abstract contract LenderAmmSetup is CommonBase {
    using stdJson for string;
    using StateLibrary for IPoolManager;

    /// @dev The hook's permissions: `ReHypothecationHook`'s, which this kit does not change.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    /// @dev Category weights in `IntentCategory` order (STOCK, MEME, RH_ECOSYSTEM, COMMODITY), as gage's app sets them.
    uint16 internal constant ALL = 10_000;
    /// @dev What the USDG vault lends against unless `USDG_COLLATERAL` names its own list: manifest keys of the testnet's
    /// real-world assets. The pool's lend asset is left out of it.
    string internal constant DEFAULT_USDG_COLLATERAL = "GLDx,NVDAx,TSLAx,MSFTx";

    /// @notice One lender pool: USDG and a lend asset, each with its gage generation's factory.
    struct Network {
        IPoolManager poolManager;
        address usdg;
        address asset;
        string symbol;
        IIntentFactory usdgFactory;
        IIntentFactory assetFactory;
        /// @dev The hookless pool of the same pair, whose price the hook's pool starts at.
        bytes32 referencePool;
        /// @dev What the USDG vault lends against: real-world assets on the testnet, never the pool's lend asset.
        address[] usdgCollateral;
        /// @dev What the lend asset's vault lends against: its generation's admitted collateral, never USDG.
        address[] assetCollateral;
    }

    /// @notice A vault's mandate knobs a partner chooses; the rest follow gage's app defaults.
    struct VaultTerms {
        uint32 term;
        uint16 feeBps;
        uint128 maxLoanPrincipal;
        uint16 bufferBps;
    }

    function _manifest() internal view returns (string memory) {
        return vm.readFile(string.concat("../../deployments/manifest/", vm.toString(block.chainid), ".json"));
    }

    /// @dev The pool of USDG and `symbol`, a lend asset with its own generation (`intentV1Assets.<symbol>`).
    function _network(string memory symbol) internal view returns (Network memory) {
        return _networkOf(_manifest(), symbol, vm.envOr("USDG_COLLATERAL", string("")));
    }

    /// @dev `_network` from a manifest's text and `USDG_COLLATERAL` as the partner set it (empty: the default).
    function _networkOf(string memory json, string memory symbol, string memory usdgKeys)
        internal
        view
        returns (Network memory n)
    {
        string memory lend = string.concat(".intentV1Assets.", symbol);
        n.poolManager = IPoolManager(json.readAddress(".PoolManager"));
        n.usdg = json.readAddress(".USDG");
        n.asset = json.readAddress(string.concat(lend, ".lendAsset.token"));
        n.symbol = symbol;
        n.usdgFactory = IIntentFactory(json.readAddress(".intentV1.factory"));
        n.assetFactory = IIntentFactory(json.readAddress(string.concat(lend, ".factory")));
        n.referencePool = json.readBytes32(string.concat(".pools.", _poolName(symbol), ".poolId"));
        n.usdgCollateral = _usdgCollateral(json, n, usdgKeys);
        n.assetCollateral = _assetCollateral(json, n, lend);
    }

    // Neither vault lends against a currency of its own pool (docs/lender-amm.md, rule 8): a fall in that currency would
    // reach the LPs twice, through the pool and through the vault's loans. The defaults leave both out, and a list the
    // partner names stops the script where it names one.

    /// @dev What the USDG vault lends against: `keys` (manifest keys, comma-separated) as the partner wrote them, or by
    /// default `DEFAULT_USDG_COLLATERAL` less the pool's lend asset.
    function _usdgCollateral(string memory json, Network memory n, string memory keys)
        internal
        pure
        returns (address[] memory tokens)
    {
        bool named = bytes(keys).length != 0;
        string[] memory list = vm.split(named ? keys : DEFAULT_USDG_COLLATERAL, ",");
        tokens = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            tokens[i] = json.readAddress(string.concat(".", list[i]));
            if (named && _inPool(n, tokens[i])) {
                revert(
                    string.concat(
                        "USDG_COLLATERAL names ",
                        list[i],
                        ", a currency of the ",
                        n.symbol,
                        "/USDG pool: a vault never lends against its pool's currencies (docs/lender-amm.md, rule 8)"
                    )
                );
            }
        }
        return _withoutPool(n, tokens);
    }

    /// @dev What the lend asset's vault lends against: its generation's admitted collateral, less USDG.
    function _assetCollateral(string memory json, Network memory n, string memory lend)
        internal
        view
        returns (address[] memory tokens)
    {
        uint256 count;
        while (json.keyExists(string.concat(lend, ".collateral[", vm.toString(count), "]"))) ++count;
        tokens = new address[](count);
        for (uint256 i; i < count; ++i) {
            tokens[i] = json.readAddress(string.concat(lend, ".collateral[", vm.toString(i), "].token"));
        }
        tokens = _withoutPool(n, tokens);
        if (tokens.length == 0) {
            revert(string.concat("the ", n.symbol, " generation admits no collateral but the pool's currencies"));
        }
    }

    function _inPool(Network memory n, address token) internal pure returns (bool) {
        return token == n.usdg || token == n.asset;
    }

    /// @dev `tokens` in their order, without the pool's two currencies.
    function _withoutPool(Network memory n, address[] memory tokens) internal pure returns (address[] memory kept) {
        uint256 count;
        for (uint256 i; i < tokens.length; ++i) {
            if (!_inPool(n, tokens[i])) ++count;
        }
        kept = new address[](count);
        count = 0;
        for (uint256 i; i < tokens.length; ++i) {
            if (!_inPool(n, tokens[i])) kept[count++] = tokens[i];
        }
    }

    /// @dev The USDG side: lends USDG against real-world assets (STOCK, COMMODITY).
    function _usdgMandate(Network memory n, address curator) internal view returns (IIntentFactory.Mandate memory) {
        VaultTerms memory t = VaultTerms({
            term: uint32(vm.envOr("USDG_TERM", uint256(604_800))),
            feeBps: uint16(vm.envOr("USDG_FEE_BPS", uint256(1000))),
            maxLoanPrincipal: uint128(vm.envOr("USDG_MAX_LOAN", uint256(1500e6))),
            bufferBps: uint16(vm.envOr("USDG_BUFFER_BPS", uint256(3000)))
        });
        return _mandate(curator, [ALL, 0, 0, ALL], n.usdgCollateral, t);
    }

    /// @dev The lend asset's side: lends it against its generation's collateral (memes and Robinhood ecosystem tokens).
    function _assetMandate(Network memory n, address curator) internal view returns (IIntentFactory.Mandate memory) {
        uint256 unit = 10 ** IERC20Metadata(n.asset).decimals();
        VaultTerms memory t = VaultTerms({
            term: uint32(vm.envOr("ASSET_TERM", uint256(604_800))),
            feeBps: uint16(vm.envOr("ASSET_FEE_BPS", uint256(1000))),
            maxLoanPrincipal: uint128(vm.envOr("ASSET_MAX_LOAN", 5 * unit)),
            bufferBps: uint16(vm.envOr("ASSET_BUFFER_BPS", uint256(3000)))
        });
        return _mandate(curator, [0, ALL, ALL, 0], n.assetCollateral, t);
    }

    function _mandate(address curator, uint16[4] memory weights, address[] memory assets, VaultTerms memory t)
        internal
        pure
        returns (IIntentFactory.Mandate memory)
    {
        return IIntentFactory.Mandate({
            curator: curator,
            categoryWeights: weights,
            assets: assets,
            maxLoanTerm: t.term,
            feeBps: t.feeBps,
            minGrade: 0,
            minRateGrade: 0,
            maxLoanPrincipal: t.maxLoanPrincipal,
            maxAssetBps: ALL,
            bufferBps: t.bufferBps,
            executionCapBps: 2000
        });
    }

    /// @dev Create the pool's two vaults, the caller their curator: USDG's on the USDG generation, the asset's on its own.
    function _createVaults(Network memory n, address curator)
        internal
        returns (IGageVault usdgVault, IGageVault assetVault)
    {
        string memory pair = string.concat("Lender AMM ", n.symbol, "-USDG");
        usdgVault =
            IGageVault(n.usdgFactory.create(_usdgMandate(n, curator), false, 0, false, string.concat(pair, " (USDG)")));
        assetVault = IGageVault(
            n.assetFactory.create(_assetMandate(n, curator), false, 0, false, string.concat(pair, " (", n.symbol, ")"))
        );
    }

    function _hookConfig(Network memory n, IGageVault usdgVault, IGageVault assetVault, address owner_)
        internal
        view
        returns (GageLenderHook.Config memory c)
    {
        bool assetFirst = n.asset < n.usdg;
        uint16 assetFloat = uint16(vm.envOr("ASSET_FLOAT_BPS", uint256(2000)));
        uint16 usdgFloat = uint16(vm.envOr("USDG_FLOAT_BPS", uint256(2000)));
        c = GageLenderHook.Config({
            poolManager: n.poolManager,
            vault0: assetFirst ? assetVault : usdgVault,
            vault1: assetFirst ? usdgVault : assetVault,
            fee: uint24(vm.envOr("POOL_FEE", uint256(3000))),
            tickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60)))),
            floatBps0: assetFirst ? assetFloat : usdgFloat,
            floatBps1: assetFirst ? usdgFloat : assetFloat,
            owner: owner_,
            name: string.concat("gage lender AMM ", n.symbol, "/USDG"),
            symbol: string.concat("gLP-", n.symbol, "-USDG")
        });
    }

    /// @dev Mine a salt whose CREATE2 address carries the hook's flags from `deployer`, then deploy there.
    function _deployHook(GageLenderHook.Config memory c, address deployer) internal returns (GageLenderHook hook) {
        (address expected, bytes32 salt) =
            HookMiner.find(deployer, HOOK_FLAGS, type(GageLenderHook).creationCode, abi.encode(c));
        hook = new GageLenderHook{salt: salt}(c);
        require(address(hook) == expected, "hook address differs from the mined one");
    }

    function _poolKey(GageLenderHook hook) internal view returns (PoolKey memory) {
        return PoolKey(hook.CURRENCY0(), hook.CURRENCY1(), hook.FEE(), hook.TICK_SPACING(), IHooks(address(hook)));
    }

    /// @dev Where the hook's pool starts: the hookless pool's price now, or `START_SQRT_PRICE`.
    function _startPrice(Network memory n) internal view returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = uint160(vm.envOr("START_SQRT_PRICE", uint256(0)));
        if (sqrtPriceX96 == 0) (sqrtPriceX96,,,) = n.poolManager.getSlot0(PoolId.wrap(n.referencePool));
    }

    /// @dev The manifest's name for the hookless pool of `symbol` and USDG: GLDx is `gldxUsdg`.
    function _poolName(string memory symbol) internal pure returns (string memory) {
        // A copy: `bytes(symbol)` would alias the caller's string, which also names the vaults.
        bytes memory b = bytes(string.concat(symbol));
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string.concat(string(b), "Usdg");
    }
}
