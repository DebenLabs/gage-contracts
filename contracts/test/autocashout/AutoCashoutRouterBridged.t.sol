// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TokenBaseTest} from "../token/TokenBase.t.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {DealState} from "../../src/interfaces/IDealVault.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {AutoCashoutRouter} from "../../src/autocashout/AutoCashoutRouter.sol";

/// @notice The auto cash-out router on a bridged core, where repaying a loan also settles its legacy receipt: a 1-day
/// NVDA loan earns from the weekly pot's short budget and is cashed out in its last fifteen minutes through a real
/// Uniswap v4 pool at 100 USDG per NVDA.
contract AutoCashoutRouterBridgedTest is TokenBaseTest, V4Fixture {
    uint32 internal constant T1 = 1 days;
    uint256 internal constant PLEDGE = 100e18;
    uint128 internal constant CAP = 9900e6;
    uint128 internal constant PRINCIPAL = 9850e6;

    GageV2Vault internal v2;
    GageLegacyAdapter internal bridge;
    AutoCashoutRouter internal cashout;
    PoolKey internal key;
    address internal b0 = address(0xB0B);
    address internal l0 = address(0x1E0);
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");

    function setUp() public override {
        super.setUp();
        bridge = new GageLegacyAdapter(address(this), vault, dealRewards, usdg);
        uint32[] memory terms = new uint32[](3);
        terms[0] = T1;
        terms[1] = T7;
        terms[2] = T21;
        vm.startPrank(safe);
        registry.setFee(100);
        registry.setTerms(terms);
        registry.setERC20Allowed(address(bridge), true, Lane.STOCK, 1, 1, type(uint256).max);
        vm.stopPrank();
        GageV2TokenRegistry cfg = new GageV2TokenRegistry(address(this), terms, address(this));
        cfg.setERC20Allowed(address(nvda), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        v2 = new GageV2Vault(cfg, IERC20(address(usdg)), IERC20(address(sgage)), treasury, 0, bridge);
        bridge.setEngine(address(v2));
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        v2.REWARDS().bindFunderGate(openGate);

        _deployV4();
        key = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        nvda.mint(lp, 200_000e18);
        usdg.mint(lp, 20_000_000e6);
        _addRawLiquidity(key, FULL_LOWER, FULL_UPPER, 1e18, lp);

        cashout = new AutoCashoutRouter(v2, poolManager, keeper, address(this));
    }

    function _loan() internal returns (uint256 id) {
        nvda.mint(b0, PLEDGE);
        vm.startPrank(b0);
        nvda.approve(address(v2), PLEDGE);
        id = v2.list(
            Collateral(Kind.ERC20, address(nvda), PLEDGE), PRINCIPAL, CAP, T1, uint40(block.timestamp + 1 days), true
        );
        vm.stopPrank();
        usdg.mint(l0, PRINCIPAL);
        vm.startPrank(l0);
        usdg.approve(address(v2), PRINCIPAL);
        v2.fund(id, 4);
        vm.stopPrank();
        vm.prank(b0);
        v2.approve(address(cashout), id);
    }

    function test_cashOut_settlesTheLegacyReceiptToo() public {
        uint256 id = _loan();
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        V2Loan memory l = v2.getLoan(id);
        vm.warp(uint256(l.fundedAt) + T1 - 5 minutes);

        vm.prank(keeper);
        uint256 net = cashout.cashOut(id, key, 1);

        assertGt(net, 55e6, "gain credited");
        assertEq(cashout.owed(b0), net, "holder");
        assertEq(uint256(v2.getLoan(id).state), uint256(V2State.REPAID), "repaid");
        assertEq(uint256(vault.getDeal(a.legacyId).state), uint256(DealState.RECLAIMED), "legacy reclaimed");
        assertEq(usdg.balanceOf(address(bridge)), 0, "bridge holds nothing");
        assertEq(usdg.balanceOf(address(cashout)), net, "router holds the credit");
        assertEq(v2.cashCredit(l0), CAP, "lender paid the cap");
    }

    function test_cashOut_keepsTheEarnedRewards() public {
        uint256 id = _loan();
        GageV2Rewards ledger = v2.REWARDS();
        GageLegacyAdapter.Loan memory a = bridge.loan(bridge.adapterId(address(v2), id));
        assertGt(a.borrowerReward, 0, "earns from the weekly pot");
        V2Loan memory l = v2.getLoan(id);
        vm.warp(uint256(l.fundedAt) + T1 - 5 minutes);
        uint256 dripped = ledger.claimable(id, b0);

        vm.prank(keeper);
        cashout.cashOut(id, key, 1);

        // A repayment keeps what has dripped so far, as a borrower's own reclaim does.
        assertGe(ledger.claimable(id, b0), dripped, "drip kept");
        vm.prank(b0);
        ledger.claim(id, b0);
        assertGt(sgage.balanceOf(b0), 0, "claimed");
    }
}
