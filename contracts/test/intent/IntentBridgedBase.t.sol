// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TokenBaseTest} from "../token/TokenBase.t.sol";
import {IntentAccountingRouter} from "./IntentAccountingBase.t.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {MockFeeProcessor} from "../mocks/MockFeeProcessor.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";
import {ReserveLensMock} from "../mocks/ReserveLensMock.sol";
import {IntentVault, IntentCategory} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Rewards, IFunderGate} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @notice One partner vault on a bridged core, with the real local legacy reward contracts behind it: the
/// `GageLegacyAdapter`, its party clones, `Drip` and `DealRewards`.
/// @dev USDG, collateral and the reserve are local mocks. `lender` holds 100,000 USDG of shares and `lender2` 2,000.
abstract contract IntentBridgedBaseTest is TokenBaseTest {
    GageV2Vault internal core;
    GageV2Rewards internal coreRewards;
    GageLegacyAdapter internal bridge;
    HybridReserveMock internal reserve;
    ReserveLensMock internal reserveLens;
    IntentFactory internal partnerFactory;
    IntentVault internal partner;
    IntentAccountingRouter internal intentRouter;

    function setUp() public virtual override {
        super.setUp();
        bridge = new GageLegacyAdapter(address(this), vault, dealRewards, usdg);
        vm.startPrank(safe);
        registry.setFee(100);
        registry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        vm.stopPrank();

        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        GageV2TokenRegistry cfg = new GageV2TokenRegistry(address(this), terms, address(this));
        cfg.setERC20Allowed(address(nvda), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        core = new GageV2Vault(cfg, usdg, sgage, treasury, 0, bridge);
        coreRewards = core.REWARDS();
        bridge.setEngine(address(core));

        reserve = new HybridReserveMock(usdg);
        reserveLens = new ReserveLensMock();
        IntentVaultCode code = new IntentVaultCode();
        partnerFactory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: address(reserve),
                reserveLens: address(reserveLens),
                grades: address(new GradeRegistry(address(this), address(this))),
                protocolRecipient: address(new MockFeeProcessor(address(usdg))),
                initialOwner: address(this),
                codeA: code.CHUNK_A(),
                codeB: code.CHUNK_B()
            })
        );
        coreRewards.bindFunderGate(IFunderGate(address(partnerFactory)));
        partnerFactory.assignCategory(address(nvda), IntentCategory.STOCK);
        partnerFactory.setCreator(address(this), true);
        address[] memory assets = new address[](1);
        assets[0] = address(nvda);
        partner = IntentVault(
            partnerFactory.create(
                IntentVault.Mandate({
                    curator: address(this),
                    categoryWeights: [uint16(10_000), 0, 0, 0],
                    assets: assets,
                    maxLoanTerm: T21,
                    feeBps: 1000,
                    minGrade: 0,
                    minRateGrade: 0,
                    maxLoanPrincipal: 1_000_000e6,
                    maxAssetBps: 10_000,
                    bufferBps: 0,
                    executionCapBps: IntentFeeMath.MAX_EXECUTION_CAP_BPS
                }),
                false,
                0,
                "Test vault"
            )
        );
        intentRouter = new IntentAccountingRouter(partnerFactory);
        partnerFactory.setFillRouter(address(intentRouter));
        partnerFactory.setQuoteSigner(address(0x5151));
        partnerFactory.setFiller(address(this), true);

        vm.startPrank(borrower);
        nvda.approve(address(core), type(uint256).max);
        usdg.approve(address(core), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(lender);
        usdg.approve(address(partner), type(uint256).max);
        partner.deposit(100_000e6, 0);
        vm.stopPrank();
        vm.startPrank(lender2);
        usdg.approve(address(partner), type(uint256).max);
        partner.deposit(2000e6, 0);
        vm.stopPrank();
    }
}
