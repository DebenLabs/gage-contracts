// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest} from "./EarnV3Base.t.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

// ABI-only interfaces; every reserve, adapter, IRM and market implementation is upstream bytecode.
struct S0Market {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface S0Reserve is IERC4626 {
    function setCurator(address) external;
    function submit(bytes calldata) external;
    function setIsAllocator(address, bool) external;
    function addAdapter(address) external;
    function increaseAbsoluteCap(bytes calldata, uint256) external;
    function increaseRelativeCap(bytes calldata, uint256) external;
    function allocate(address, bytes calldata, uint256) external;
    function setLiquidityAdapterAndData(address, bytes calldata) external;
}

interface S0Morpho {
    function enableIrm(address) external;
    function enableLltv(uint256) external;
    function createMarket(S0Market calldata) external;
    function supplyCollateral(S0Market calldata, uint256, address, bytes calldata) external;
    function borrow(S0Market calldata, uint256, uint256, address, address) external returns (uint256, uint256);
    function repay(S0Market calldata, uint256, uint256, address, bytes calldata) external returns (uint256, uint256);
}

interface S0AdapterFactory {
    function createMorphoMarketV1AdapterV2(address) external returns (address);
}

interface S0Oracle {
    function setPrice(uint256) external;
}

/// @notice Opt-in local integration of the pinned Gage baseline with actual upstream Morpho code.
/// Gage's existing token/loan fixture is retained; this does not assert router or legacy bridge parity.
contract IntentMorphoIntegrationTest is EarnV3BaseTest {
    S0Reserve private actualReserve;
    S0Morpho private morpho;
    S0Market private market;
    address private adapter;
    string private upstream;

    function _upstream(string memory name, bytes memory args) private returns (address) {
        return deployCode(string.concat(upstream, "/", name, ".sol/", name, ".json"), args);
    }

    function setUp() public override {
        upstream = vm.envOr("INTENT_S0_MORPHO_OUT", string(""));
        if (bytes(upstream).length == 0) {
            vm.skip(true);
            return;
        }
        super.setUp();
        actualReserve = S0Reserve(_upstream("VaultV2", abi.encode(address(this), address(usdg))));
        p.reserve = address(actualReserve);
        _deploy();
        actualReserve.setCurator(address(this));
        actualReserve.submit(abi.encodeCall(S0Reserve.setIsAllocator, (address(this), true)));
        actualReserve.setIsAllocator(address(this), true);

        morpho = S0Morpho(_upstream("Morpho", abi.encode(address(this))));
        address irm = _upstream("AdaptiveCurveIrm", abi.encode(address(morpho)));
        address oracle = _upstream("OracleMock", "");
        S0Oracle(oracle).setPrice(1e24); // Controlled $1 collateral, 18 decimals; loan asset has 6.
        market = S0Market(address(usdg), address(nvda), oracle, irm, 0.8e18);
        morpho.enableIrm(irm);
        morpho.enableLltv(market.lltv);
        morpho.createMarket(market);
        address factory = _upstream("MorphoMarketV1AdapterV2Factory", abi.encode(address(morpho), irm));
        adapter = S0AdapterFactory(factory).createMorphoMarketV1AdapterV2(address(actualReserve));
        actualReserve.submit(abi.encodeCall(S0Reserve.addAdapter, (adapter)));
        actualReserve.addAdapter(adapter);
        _cap(abi.encode("this", adapter));
        _cap(abi.encode("collateralToken", market.collateralToken));
        _cap(abi.encode("this/marketParams", adapter, market));
    }

    function _cap(bytes memory idData) private {
        actualReserve.submit(abi.encodeCall(S0Reserve.increaseAbsoluteCap, (idData, type(uint128).max)));
        actualReserve.increaseAbsoluteCap(idData, type(uint128).max);
        actualReserve.submit(abi.encodeCall(S0Reserve.increaseRelativeCap, (idData, uint256(1e18))));
        actualReserve.increaseRelativeCap(idData, 1e18);
    }

    function _invest(bool lend) private {
        _deposit(alice, 1000e6);
        earn.investReserve(1000e6, 0);
        if (lend) {
            actualReserve.allocate(adapter, abi.encode(market), 1000e6);
            actualReserve.setLiquidityAdapterAndData(adapter, abi.encode(market));
        }
        assertEq(actualReserve.maxWithdraw(address(earn)), 0);
    }

    function _borrowReserveLiquidity() private returns (uint256 borrowedShares) {
        _invest(true);
        vm.startPrank(borrower);
        nvda.approve(address(morpho), MAX);
        morpho.supplyCollateral(market, 2000e18, borrower, "");
        (, borrowedShares) = morpho.borrow(market, 1000e6, 0, borrower, borrower);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(actualReserve)), 0);
        assertEq(usdg.balanceOf(address(morpho)), 0);
    }

    function testRedeemFromActualIdleReserve() public {
        _invest(false);
        uint256 beforeBalance = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = earn.redeem(500e18, 499e6);
        assertEq(usdg.balanceOf(alice) - beforeBalance, paid);
        assertApproxEqAbs(paid, 500e6, 2);
    }

    function testRedeemPullsFromActualMorphoMarket() public {
        _invest(true);
        assertEq(usdg.balanceOf(address(actualReserve)), 0);
        uint256 beforeBalance = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = earn.redeem(500e18, 499e6);
        assertEq(usdg.balanceOf(alice) - beforeBalance, paid);
        assertApproxEqAbs(paid, 500e6, 2);
    }

    function testLoanRepaymentFeesAndExitThroughActualMorphoMarket() public {
        _invest(true);
        uint256 id = _funded(500e6);
        assertEq(earn.performingPrincipal(), 500e6);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        vm.warp(_maturity(id));
        _settle(id);
        assertEq(earn.performingPrincipal(), 0);
        // Existing fixture terms: $25 gross interest, 15% manager fee, protocol receives 10% of that fee.
        assertEq(earn.curatorFees(), 3.375e6);
        assertEq(earn.protocolFees(), 0.375e6);
        earn.claimFees();
        assertEq(usdg.balanceOf(feeRecipient), 3.375e6);
        assertEq(usdg.balanceOf(floor), 0.375e6);
        uint256 shares = earn.balanceOf(alice);
        uint256 beforeBalance = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = earn.redeem(shares, 1021e6);
        assertEq(usdg.balanceOf(alice) - beforeBalance, paid);
        assertApproxEqAbs(paid, 1021.25e6, 3);
        assertEq(earn.balanceOf(alice), 0);
    }

    function testRevertedRedemptionPreservesClaimsThenRepaymentRestoresExit() public {
        uint256 borrowedShares = _borrowReserveLiquidity();
        uint256 sharesBefore = earn.balanceOf(alice);
        uint256 reserveSharesBefore = earn.reserveShares();
        uint256 balanceBefore = usdg.balanceOf(alice);
        // The baseline estimate includes the reserve position, despite no executable withdrawal liquidity.
        assertGt(earn.freeLiquidity(), 499e6);
        vm.prank(alice);
        vm.expectRevert();
        earn.redeem(500e18, 499e6);
        assertEq(earn.balanceOf(alice), sharesBefore);
        assertEq(earn.totalSupply(), sharesBefore);
        assertEq(earn.reserveShares(), reserveSharesBefore);
        assertEq(usdg.balanceOf(alice), balanceBefore);
        assertEq(earn.cash(), 0);
        vm.startPrank(borrower);
        usdg.approve(address(morpho), MAX);
        morpho.repay(market, 0, borrowedShares, borrower, "");
        vm.stopPrank();
        vm.prank(alice);
        uint256 paid = earn.redeem(500e18, 499e6);
        assertEq(usdg.balanceOf(alice) - balanceBefore, paid);
    }

    function testRevertedLoanFundingPreservesReserveAndLoanSlots() public {
        _borrowReserveLiquidity();
        uint256 id = _listed(500e6);
        uint256 sharesBefore = earn.reserveShares();
        uint256 borrowerBefore = usdg.balanceOf(borrower);
        vm.prank(curator);
        vm.expectRevert();
        earn.fund(id, 4, MAX);
        assertEq(earn.reserveShares(), sharesBefore);
        assertEq(usdg.balanceOf(borrower), borrowerBefore);
        assertEq(_loan(id).principal, 0);
        address[4] memory lenders = core.lenders(id);
        for (uint256 i; i < 4; ++i) {
            assertEq(lenders[i], address(0));
        }
    }
}
