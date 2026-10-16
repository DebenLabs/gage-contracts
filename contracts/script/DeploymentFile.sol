// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

/// @notice deployments/<chainId><tag>.json is rewritten whole on every step: `vm.writeJson` at a key only replaces
///         keys that already exist, so each script copies every known key forward and adds its own.
abstract contract DeploymentFile is Script {
    string internal constant OBJ = "deployment";
    /// @dev Serializer object that accumulates the `pools` entries (carried plus new).
    string internal constant POOLS_OBJ = "carry-pools";

    function _addressKeys() internal pure returns (string[31] memory k) {
        k = [
            "deployer",
            "borrower",
            "lender",
            "USDG",
            "NVDAx",
            "NVDOG",
            "MockUniversalRouter",
            "CollateralRegistry",
            "FeeSink",
            "DealVault",
            "EntryRouter",
            "PoolManager",
            "PositionManager",
            "StateView",
            "Permit2",
            "LiquidityRouter",
            "SwapRouter",
            "GAGE",
            "sGAGE",
            "Drip",
            "Emissions",
            "DealRewards",
            "LPRewards",
            "LPHook",
            "Buyback",
            "CreatorFeeSplitter",
            "AAPLx",
            "TSLAx",
            "MSFTx",
            "APEPE",
            "MOON"
        ];
    }

    function _uintKeys() internal pure returns (string[5] memory k) {
        k = ["chainId", "seedTokenId", "borrowerPositionId", "positionDealId", "reinvestTokenId"];
    }

    /// @dev Copy every known key that exists in `json` into the OBJ serializer.
    function _carryForward(string memory json) internal {
        string[31] memory ak = _addressKeys();
        for (uint256 i = 0; i < ak.length; ++i) {
            string memory key = string.concat(".", ak[i]);
            if (vm.keyExistsJson(json, key)) vm.serializeAddress(OBJ, ak[i], vm.parseJsonAddress(json, key));
        }
        // ReinvestRouter and SeedTimelock overflow the fixed array above; carry them the same way
        if (vm.keyExistsJson(json, ".ReinvestRouter")) {
            vm.serializeAddress(OBJ, "ReinvestRouter", vm.parseJsonAddress(json, ".ReinvestRouter"));
        }
        if (vm.keyExistsJson(json, ".SeedTimelock")) {
            vm.serializeAddress(OBJ, "SeedTimelock", vm.parseJsonAddress(json, ".SeedTimelock"));
        }
        string[5] memory uk = _uintKeys();
        for (uint256 i = 0; i < uk.length; ++i) {
            string memory key = string.concat(".", uk[i]);
            if (vm.keyExistsJson(json, key)) vm.serializeUint(OBJ, uk[i], vm.parseJsonUint(json, key));
        }
        if (vm.keyExistsJson(json, ".pools")) vm.serializeString(OBJ, "pools", _carryPools(json));
    }

    /// @dev Rebuild the nested `pools` object field by field; the cheatcodes cannot copy an object as a string.
    ///      Every pool present in `json` is carried, whatever its name, so later scripts (DeployFaucetAssets, the
    ///      faucet service) may add pools without touching this file.
    function _carryPools(string memory json) internal returns (string memory out) {
        string[] memory names = vm.parseJsonKeys(json, ".pools");
        for (uint256 i = 0; i < names.length; ++i) {
            string memory base = string.concat(".pools.", names[i]);
            string memory obj = string.concat("carry-", names[i]);
            vm.serializeAddress(obj, "currency0", vm.parseJsonAddress(json, string.concat(base, ".currency0")));
            vm.serializeAddress(obj, "currency1", vm.parseJsonAddress(json, string.concat(base, ".currency1")));
            vm.serializeUint(obj, "fee", vm.parseJsonUint(json, string.concat(base, ".fee")));
            vm.serializeInt(obj, "tickSpacing", vm.parseJsonInt(json, string.concat(base, ".tickSpacing")));
            vm.serializeAddress(obj, "hooks", vm.parseJsonAddress(json, string.concat(base, ".hooks")));
            if (vm.keyExistsJson(json, string.concat(base, ".createdAt"))) {
                vm.serializeUint(obj, "createdAt", vm.parseJsonUint(json, string.concat(base, ".createdAt")));
            }
            string memory pool =
                vm.serializeBytes32(obj, "poolId", vm.parseJsonBytes32(json, string.concat(base, ".poolId")));
            out = vm.serializeString(POOLS_OBJ, names[i], pool);
        }
    }

    /// @dev Add a pool to the carried `pools` object and re-serialize it into OBJ; returns the whole deployment
    ///      object, ready for `vm.writeJson`. Call after `_carryForward`.
    function _addPool(string memory name, string memory poolJson) internal returns (string memory) {
        string memory pools = vm.serializeString(POOLS_OBJ, name, poolJson);
        return vm.serializeString(OBJ, "pools", pools);
    }
}
