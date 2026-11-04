// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {GageLenderHook} from "../src/GageLenderHook.sol";
import {IGageVault} from "../src/interfaces/IGageVault.sol";
import {IIntentFactory} from "../src/interfaces/IIntentFactory.sol";
import {LenderAmmSetup} from "./LenderAmmSetup.sol";

/// @notice One command for a lender pool: create its two gage vaults with the broadcaster as their curator, deploy
/// the hook at a mined address with those vaults as its yield sources (the hook is their depositor; gage vaults take
/// deposits from anyone, so nothing is admitted on them), initialize the pool at the hookless pool's price, allow the
/// keeper, and seed. The broadcaster must be an admitted creator on both generations' factories; it owns the hook.
/// @dev Env: LEND_ASSET (default GLDx), KEEPER, SEED_ASSET and SEED_USDG (raw units; zero skips the seed), USDG_VAULT
/// and ASSET_VAULT to reuse vaults created by an earlier run, and the mandate and float knobs read by LenderAmmSetup.
/// Writes deployments/<chainId>.json. Run: README.md.
contract DeployLenderAmm is Script, LenderAmmSetup {
    uint256 internal constant MAINNET = 4663;

    function run() external returns (GageLenderHook hook) {
        if (block.chainid == MAINNET) {
            require(
                vm.envOr("LENDER_AMM_ALLOW_MAINNET", false),
                "gage deploys no lender AMM on mainnet; a partner deploying its own audited copy sets LENDER_AMM_ALLOW_MAINNET=true"
            );
        }
        Network memory n = _network(vm.envOr("LEND_ASSET", string("GLDx")));
        address curator = msg.sender;
        _requireCreator(n.usdgFactory, curator, "USDG");
        _requireCreator(n.assetFactory, curator, n.symbol);

        vm.startBroadcast(curator);
        (IGageVault usdgVault, IGageVault assetVault) = _vaults(n, curator);
        hook = _deployHook(_hookConfig(n, usdgVault, assetVault, curator), CREATE2_FACTORY);
        PoolKey memory key = _poolKey(hook);
        uint160 start = _startPrice(n);
        n.poolManager.initialize(key, start);
        address keeper = vm.envOr("KEEPER", address(0));
        if (keeper != address(0)) hook.setKeeper(keeper, true);
        uint256 seedAsset = vm.envOr("SEED_ASSET", uint256(0));
        uint256 seedUsdg = vm.envOr("SEED_USDG", uint256(0));
        if (seedAsset != 0 || seedUsdg != 0) {
            IERC20(n.asset).approve(address(hook), seedAsset);
            IERC20(n.usdg).approve(address(hook), seedUsdg);
            bool assetFirst = Currency.unwrap(hook.CURRENCY0()) == n.asset;
            hook.seedLiquidity(assetFirst ? seedAsset : seedUsdg, assetFirst ? seedUsdg : seedAsset);
        }
        vm.stopBroadcast();

        _record(n, hook, usdgVault, assetVault, start, keeper);
        console2.log("hook     ", address(hook));
        console2.log("USDG vault", address(usdgVault));
        console2.log("asset vault", address(assetVault));
        console2.log("pool id");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }

    function _requireCreator(IIntentFactory factory, address curator, string memory generation) internal view {
        require(
            factory.openCreation() || factory.isCreator(curator),
            string.concat(
                "the curator is not an admitted creator on the ",
                generation,
                " factory: ask gage to admit it as a creator (PARTNERS.md)"
            )
        );
    }

    /// @dev The vaults of an earlier run (`USDG_VAULT`, `ASSET_VAULT`), checked to be this curator's on these factories,
    /// or two new ones.
    function _vaults(Network memory n, address curator) internal returns (IGageVault usdgVault, IGageVault assetVault) {
        address usdgAt = vm.envOr("USDG_VAULT", address(0));
        address assetAt = vm.envOr("ASSET_VAULT", address(0));
        if (usdgAt == address(0) && assetAt == address(0)) return _createVaults(n, curator);
        require(n.usdgFactory.isVault(usdgAt) && n.assetFactory.isVault(assetAt), "not vaults of these factories");
        require(_curator(usdgAt) == curator && _curator(assetAt) == curator, "another curator's vaults");
        return (IGageVault(usdgAt), IGageVault(assetAt));
    }

    function _curator(address vault) internal view returns (address) {
        (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("CURATOR()"));
        require(ok && data.length == 32, "unreadable vault");
        return abi.decode(data, (address));
    }

    function _record(
        Network memory n,
        GageLenderHook hook,
        IGageVault usdgVault,
        IGageVault assetVault,
        uint160 start,
        address keeper
    ) internal {
        string memory o = "lender-amm";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "lendAsset", n.symbol);
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "owner", hook.owner());
        vm.serializeAddress(o, "keeper", keeper);
        vm.serializeAddress(o, "poolManager", address(n.poolManager));
        vm.serializeAddress(o, "currency0", Currency.unwrap(hook.CURRENCY0()));
        vm.serializeAddress(o, "currency1", Currency.unwrap(hook.CURRENCY1()));
        vm.serializeUint(o, "fee", hook.FEE());
        vm.serializeInt(o, "tickSpacing", hook.TICK_SPACING());
        vm.serializeBytes32(o, "poolId", PoolId.unwrap(_poolKey(hook).toId()));
        vm.serializeBytes32(o, "referencePoolId", n.referencePool);
        vm.serializeUint(o, "startSqrtPriceX96", start);
        vm.serializeAddress(o, "usdgVault", address(usdgVault));
        vm.serializeAddress(o, "assetVault", address(assetVault));
        vm.serializeAddress(o, "usdgFactory", address(n.usdgFactory));
        vm.serializeAddress(o, "assetFactory", address(n.assetFactory));
        vm.serializeUint(o, "floatBps0", hook.floatBps0());
        vm.serializeUint(o, "floatBps1", hook.floatBps1());
        string memory out = vm.serializeUint(o, "deployBlock", block.number);
        vm.createDir("deployments", true);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
