// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IntentSecondaryBaseTest} from "./IntentSecondaryBase.t.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice SEC-20: every S9 contract deploys through its real constructor under EIP-170 and EIP-3860, constructor
/// arguments included, with unchanged limits; and the worst supported allocation's gas is measured.
contract IntentSecondaryDeployTest is IntentSecondaryBaseTest {
    uint256 internal constant RUNTIME_LIMIT = 24_576;
    uint256 internal constant INITCODE_LIMIT = 49_152;
    /// @dev More picked assets than either universe holds today (12 stocks, 27 memes on 17 September 2026).
    uint256 internal constant ASSETS = 64;

    function test_everyContractFitsWithItsConstructorArguments() public {
        // Two data contracts carry the vault creation code; the factory does not. Each is a runtime (STOP + half the
        // code), so each must fit EIP-170.
        IntentVaultCode store = new IntentVaultCode();
        assertLe(store.CHUNK_A().code.length, RUNTIME_LIMIT, "first code chunk runtime");
        assertLe(store.CHUNK_B().code.length, RUNTIME_LIMIT, "second code chunk runtime");
        IntentFactory.Params memory fp = IntentFactory.Params({
            core: address(core),
            reserve: address(reserve),
            reserveLens: address(0),
            grades: address(grades),
            protocolRecipient: feeProcessor,
            initialOwner: address(this),
            codeA: store.CHUNK_A(),
            codeB: store.CHUNK_B()
        });
        uint256 factoryInit = type(IntentFactory).creationCode.length + abi.encode(fp).length;
        assertLe(factoryInit, INITCODE_LIMIT, "factory initcode with arguments");
        IntentFactory factory = new IntentFactory(fp);
        assertLe(address(factory).code.length, RUNTIME_LIMIT);

        // A vault with 64 picked assets, created through the factory.
        IntentVault.Mandate memory m = mandate;
        m.assets = new address[](ASSETS);
        vm.startPrank(safe);
        for (uint256 i; i < ASSETS; ++i) {
            MockERC20 token = new MockERC20("T", "T", 18);
            registry.setERC20Allowed(address(token), true, Lane.STOCK, 1e18, 1000e18, 100_000e18);
            m.assets[i] = address(token);
        }
        vm.stopPrank();
        for (uint256 i; i < ASSETS; ++i) {
            factory.assignCategory(m.assets[i], IntentCategory.STOCK);
        }
        factory.setCreator(curator, true);
        // The factory deploys exactly this build's creation code (VAULT_INIT_HASH), followed by the arguments.
        assertEq(factory.VAULT_INIT_HASH(), keccak256(type(IntentVault).creationCode));
        uint256 vaultInit = type(IntentVault).creationCode.length + abi.encode(m, true, uint16(10_000)).length;
        assertLe(vaultInit, INITCODE_LIMIT, "vault initcode with a 64-asset mandate");
        vm.prank(curator);
        IntentVault vault = IntentVault(factory.create(m, true, 10_000, "Test vault"));
        assertLe(address(vault).code.length, RUNTIME_LIMIT, "vault runtime");
        assertLe(address(vault.ASSET_POLICY()).code.length, RUNTIME_LIMIT);
        assertLe(address(vault.LENDER_MARKET()).code.length, RUNTIME_LIMIT);
        assertLe(address(core).code.length, RUNTIME_LIMIT, "core runtime");
        assertLe(type(GageV2Vault).creationCode.length + 128, INITCODE_LIMIT, "core initcode with arguments");
        assertLe(address(verifier).code.length, RUNTIME_LIMIT, "verifier runtime");
        assertLe(address(fills).code.length, RUNTIME_LIMIT, "router runtime");
        console2.log("vault runtime", address(vault).code.length);
        console2.log("vault initcode with 64 assets", vaultInit);
        console2.log("factory initcode with arguments", factoryInit);
        console2.log("first code chunk runtime", store.CHUNK_A().code.length);
        console2.log("second code chunk runtime", store.CHUNK_B().code.length);
        console2.log("asset policy runtime", address(vault.ASSET_POLICY()).code.length);
        console2.log("market runtime", address(vault.LENDER_MARKET()).code.length);
        console2.log("verifier runtime", address(verifier).code.length);
        console2.log("router runtime", address(fills).code.length);
        console2.log("core runtime", address(core).code.length);
        // The whole budget: what a mandate's arguments may still add before the vault stops deploying.
        console2.log("vault initcode headroom", INITCODE_LIMIT - vaultInit);
    }

    function test_worstSupportedAllocationGas() public {
        // Four vaults, one quarter each, through the seller vault's market: the most external calls a fill makes.
        IntentVault fourth = _buyer(300e6);
        uint256 id = _onSale(1070e6 + 3);
        IntentVault[] memory vaults = new IntentVault[](4);
        uint8[] memory masks = new uint8[](4);
        (vaults[0], masks[0]) = (buyerA, 1);
        (vaults[1], masks[1]) = (buyerB, 2);
        (vaults[2], masks[2]) = (buyerC, 4);
        (vaults[3], masks[3]) = (fourth, 8);
        IntentQuoteVerifier.SecondaryPlan memory p = _marketPlan(id, vaults, masks);
        bytes memory signature = _signSecondary(p);
        vm.prank(p.filler);
        uint256 before_ = gasleft();
        fills.fillSecondary(p, signature);
        uint256 used = before_ - gasleft();
        console2.log("fillSecondary gas, 4 vaults via a vault market", used);
        assertLt(used, 3_000_000, "well inside a block");
    }
}
