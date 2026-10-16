// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentVaultCode} from "../helpers/IntentVaultCode.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {IntentCategory} from "../../src/intent/IntentVault.sol";

// ABI-only interfaces; every reserve, adapter, IRM and market implementation is upstream bytecode.
struct LensMarket {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface LensReserve is IERC4626 {
    function setCurator(address) external;
    function submit(bytes calldata) external;
    function setIsAllocator(address, bool) external;
    function addAdapter(address) external;
    function increaseAbsoluteCap(bytes calldata, uint256) external;
    function increaseRelativeCap(bytes calldata, uint256) external;
    function allocate(address, bytes calldata, uint256) external;
    function setLiquidityAdapterAndData(address, bytes calldata) external;
}

interface LensMorpho {
    function enableIrm(address) external;
    function enableLltv(uint256) external;
    function createMarket(LensMarket calldata) external;
    function supplyCollateral(LensMarket calldata, uint256, address, bytes calldata) external;
    function borrow(LensMarket calldata, uint256, uint256, address, address) external returns (uint256, uint256);
    function repay(LensMarket calldata, uint256, uint256, address, bytes calldata) external returns (uint256, uint256);
}

interface LensAdapterFactory {
    function createMorphoMarketV1AdapterV2(address) external returns (address);
}

interface LensOracle {
    function setPrice(uint256) external;
}

/// @notice Opt-in: the partner vault and MorphoV2ReserveLens against actual upstream Morpho Vault V2, adapter, IRM and
/// Morpho Blue bytecode at the S0 pin. Skipped unless INTENT_S0_MORPHO_OUT names the upstream build, so normal runs
/// fetch nothing and use no RPC. The S0 baseline counted a fully lent reserve as free liquidity and failed the exit
/// inside Morpho; here the lens measures it and the vault refuses first, with every balance intact.
contract IntentMorphoLensTest is IntentAccountingBaseTest {
    LensReserve private actualReserve;
    LensMorpho private morpho;
    LensMarket private market;
    address private adapter;
    string private upstream;
    MorphoV2ReserveLens private lens;

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
        actualReserve = LensReserve(_upstream("VaultV2", abi.encode(address(this), address(usdg))));
        actualReserve.setCurator(address(this));
        actualReserve.submit(abi.encodeCall(LensReserve.setIsAllocator, (address(this), true)));
        actualReserve.setIsAllocator(address(this), true);

        morpho = LensMorpho(_upstream("Morpho", abi.encode(address(this))));
        address irm = _upstream("AdaptiveCurveIrm", abi.encode(address(morpho)));
        address oracle = _upstream("OracleMock", "");
        LensOracle(oracle).setPrice(1e24); // Controlled $1 collateral, 18 decimals; loan asset has 6.
        market = LensMarket(address(usdg), address(nvda), oracle, irm, 0.8e18);
        morpho.enableIrm(irm);
        morpho.enableLltv(market.lltv);
        morpho.createMarket(market);
        address adapterFactory = _upstream("MorphoMarketV1AdapterV2Factory", abi.encode(address(morpho), irm));
        adapter = LensAdapterFactory(adapterFactory).createMorphoMarketV1AdapterV2(address(actualReserve));
        actualReserve.submit(abi.encodeCall(LensReserve.addAdapter, (adapter)));
        actualReserve.addAdapter(adapter);
        _cap(abi.encode("this", adapter));
        _cap(abi.encode("collateralToken", market.collateralToken));
        _cap(abi.encode("this/marketParams", adapter, market));

        lens = new MorphoV2ReserveLens();
        IntentVaultCode store_ = new IntentVaultCode();
        partnerFactory = new IntentFactory(
            IntentFactory.Params({
                core: address(core),
                reserve: address(actualReserve),
                reserveLens: address(lens),
                grades: address(grades),
                protocolRecipient: feeProcessor,
                initialOwner: address(this),
                codeA: store_.CHUNK_A(),
                codeB: store_.CHUNK_B()
            })
        );
        partnerFactory.assignCategory(address(nvda), IntentCategory.STOCK);
        partnerFactory.assignCategory(address(gold), IntentCategory.COMMODITY);
        partnerFactory.setCreator(curator, true);
        _configure();
    }

    function _cap(bytes memory idData) private {
        actualReserve.submit(abi.encodeCall(LensReserve.increaseAbsoluteCap, (idData, type(uint128).max)));
        actualReserve.increaseAbsoluteCap(idData, type(uint128).max);
        actualReserve.submit(abi.encodeCall(LensReserve.increaseRelativeCap, (idData, uint256(1e18))));
        actualReserve.increaseRelativeCap(idData, 1e18);
    }

    function _investAndLend() private {
        _enter(alice, 1000e6);
        _invest(1000e6);
        actualReserve.allocate(adapter, abi.encode(market), 1000e6);
        actualReserve.setLiquidityAdapterAndData(adapter, abi.encode(market));
    }

    function _borrow(uint256 assets) private returns (uint256 borrowedShares) {
        vm.startPrank(borrower);
        nvda.approve(address(morpho), MAX);
        morpho.supplyCollateral(market, 2000e18, borrower, "");
        (, borrowedShares) = morpho.borrow(market, assets, 0, borrower, borrower);
        vm.stopPrank();
    }

    function testLensCountsTheIdleBalanceThenTheMarket() public {
        _enter(alice, 1000e6);
        _invest(1000e6);
        assertEq(actualReserve.maxWithdraw(address(partner)), 0, "the view is zero by design");
        assertEq(lens.withdrawable(address(actualReserve), address(partner)), 1000e6, "idle");
        actualReserve.allocate(adapter, abi.encode(market), 1000e6);
        actualReserve.setLiquidityAdapterAndData(adapter, abi.encode(market));
        assertEq(usdg.balanceOf(address(actualReserve)), 0);
        assertEq(lens.withdrawable(address(actualReserve), address(partner)), 1000e6, "supplied and unlent");
        assertEq(partner.freeLiquidity(), 1000e6);
        assertApproxEqAbs(_exitAll(alice), 1000e6, 2);
    }

    function testAFullyLentReserveIsRefusedByTheVaultThenRestoredByRepayment() public {
        _investAndLend();
        uint256 borrowedShares = _borrow(1000e6);
        assertEq(lens.withdrawable(address(actualReserve), address(partner)), 0);
        assertEq(partner.freeLiquidity(), 0, "a fully lent reserve is not free liquidity");
        assertApproxEqAbs(partner.totalAssets(), 1000e6, 1, "and is still priced");
        uint256 shares = partner.balanceOf(alice);
        uint256 reserveShares = partner.reserveShares();
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(shares / 2, 0);
        assertEq(partner.balanceOf(alice), shares);
        assertEq(partner.reserveShares(), reserveShares);
        vm.startPrank(borrower);
        usdg.approve(address(morpho), MAX);
        morpho.repay(market, 0, borrowedShares, borrower, "");
        vm.stopPrank();
        assertGe(partner.freeLiquidity(), 1000e6);
        assertGe(_exit(alice, shares / 2), 500e6 - 1);
    }

    /// @dev The measure is exact against Morpho itself: an exit for all of it succeeds, so it is not an overestimate,
    /// and it equals what the market has not lent, so it is not an underestimate.
    function testAPartlyLentReserveExitsForExactlyTheMeasure() public {
        _investAndLend();
        _borrow(600e6);
        uint256 measured = lens.withdrawable(address(actualReserve), address(partner));
        assertEq(measured, 400e6);
        assertEq(partner.freeLiquidity(), 400e6);
        uint256 tooMany = partner.convertToShares(400e6 + 1e6);
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(tooMany, 0);
        uint256 out = _exit(alice, partner.convertToShares(400e6));
        assertApproxEqAbs(out, 400e6, 2);
        assertLe(lens.withdrawable(address(actualReserve), address(partner)), 2);
    }

    /// @dev Pashov M-56. The adapter decodes the market from the liquidity data and ignores trailing bytes, so with one
    /// extra word the reserve still pays exactly what the market has not lent. The lens reads that market too, and the
    /// vault's exit goes through it. Data the adapter cannot decode pays nothing from the market, and the lens counts
    /// the idle balance alone.
    function testTheLensReadsTheMarketTheAdapterDecodes() public {
        _investAndLend();
        _borrow(600e6);
        actualReserve.setLiquidityAdapterAndData(adapter, bytes.concat(abi.encode(market), bytes32(uint256(1))));
        uint256 state = vm.snapshotState();
        vm.prank(address(partner));
        actualReserve.withdraw(400e6, address(partner), address(partner));
        vm.revertToState(state);
        vm.prank(address(partner));
        vm.expectRevert();
        actualReserve.withdraw(400e6 + 1, address(partner), address(partner));
        assertEq(lens.withdrawable(address(actualReserve), address(partner)), 400e6, "not the adapter's market");
        assertEq(partner.freeLiquidity(), 400e6);
        assertApproxEqAbs(_exit(alice, partner.convertToShares(100e6)), 100e6, 2, "an exit through the market");

        actualReserve.setLiquidityAdapterAndData(adapter, _prefix(abi.encode(market), 96));
        vm.prank(address(partner));
        vm.expectRevert();
        actualReserve.withdraw(1, address(partner), address(partner));
        assertEq(lens.withdrawable(address(actualReserve), address(partner)), 0, "data the adapter cannot decode");
        assertEq(partner.freeLiquidity(), 0);
    }

    function _prefix(bytes memory data, uint256 length) private pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[i];
        }
    }

    /// @dev A fill that needs the reserve is refused by the vault before anything moves.
    function testAFillCannotDrawOnALentReserve() public {
        _investAndLend();
        _borrow(1000e6);
        uint256 id = _list(borrower, address(nvda), 100e18, 500e6, 550e6, T21);
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        router.fund(partner, id, UNITS, 0);
        assertEq(partner.performingPrincipal(), 0);
        address[4] memory lenders = core.lenders(id);
        for (uint256 i; i < 4; ++i) {
            assertEq(lenders[i], address(0));
        }
    }
}
