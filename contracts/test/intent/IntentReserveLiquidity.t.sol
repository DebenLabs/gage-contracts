// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {MorphoV2ReserveLens} from "../../src/intent/MorphoV2ReserveLens.sol";
import {IMorphoVaultV2} from "../../src/interfaces/IMorphoV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";

/// @notice S2-A3 and R3-A2: what the reserve can pay out now is measured by the kind of reserve it is, fixed with
/// the factory. A plain ERC-4626 reserve's `maxWithdraw` is its measurement, and zero there means nothing can leave.
/// A reserve whose max views are zero by design is measured by its lens. A zero is never read as "no limit".
abstract contract IntentReserveLiquidityCases is IntentAccountingBaseTest {
    function _makeIlliquid() internal virtual;

    function _illiquidReserve() internal {
        _enter(alice, 10_000e6);
        _invest(8000e6);
        assertEq(partner.freeLiquidity(), 10_000e6, "a working reserve counts in full");
        _makeIlliquid();
    }

    function testAnIlliquidReserveIsNotFreeLiquidity() public {
        _illiquidReserve();
        assertEq(partner.freeLiquidity(), 2000e6, "an illiquid reserve was counted as free liquidity");
        assertEq(partner.totalAssets(), 10_000e6, "the reserve position is still priced");
    }

    function testExitBeyondCashFailsCleanlyAndLeavesBalancesIntact() public {
        _illiquidReserve();
        uint256 shares = partner.balanceOf(alice);
        uint256 cash = partner.cash();
        uint256 reserveShares = partner.reserveShares();
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(shares / 2, 0);
        assertEq(partner.balanceOf(alice), shares);
        assertEq(partner.cash(), cash);
        assertEq(partner.reserveShares(), reserveShares);
        // What the cash covers still leaves.
        assertApproxEqAbs(_exit(alice, shares / 5), 2000e6, 2);
    }

    function testFillCannotCountAnIlliquidReserveTowardItsBuffer() public {
        mandate.bufferBps = 5000;
        vm.prank(curator);
        partner = IntentVault(partnerFactory.create(mandate, false, 0, "Test vault"));
        vm.prank(alice);
        usdg.approve(address(partner), MAX);
        _illiquidReserve();
        uint256 id = _list(borrower, address(nvda), 100e18, 1000e6, 1100e6, T21);
        // Half of assets must stay liquid: 5,000, and only 2,000 of cash is.
        vm.prank(fillers[0]);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        router.fund(partner, id, UNITS, 0);
        assertEq(partner.performingPrincipal(), 0);
    }

    function testAPartlyLiquidReserveCountsForWhatItCanPay() public {
        _enter(alice, 10_000e6);
        _invest(8000e6);
        reserve.setLimits(type(uint256).max, 3000e6, type(uint256).max);
        assertEq(partner.freeLiquidity(), 5000e6);
        uint256 shares = partner.balanceOf(alice);
        assertApproxEqAbs(_exit(alice, shares / 2), 5000e6, 2);
        assertEq(partner.cash(), 0);
    }
}

/// @notice A plain reserve: its own `maxWithdraw` is the measurement.
contract IntentPlainReserveLiquidityTest is IntentReserveLiquidityCases {
    function setUp() public override {
        super.setUp();
        reserve.setReportZeroMax(false);
        _stand(address(0));
        assertEq(address(partner.RESERVE_LENS()), address(0));
    }

    function _makeIlliquid() internal override {
        // The reserve stops paying out and says so: its limit is zero, not an unreported one.
        reserve.setLimits(type(uint256).max, 0, 0);
        assertEq(reserve.maxWithdraw(address(partner)), 0);
    }
}

/// @notice A reserve whose max views report zero by design, as Morpho Vault V2's do: the lens is the measurement.
contract IntentLensReserveLiquidityTest is IntentReserveLiquidityCases {
    function _makeIlliquid() internal override {
        reserve.setLimits(type(uint256).max, 0, 0);
    }

    function testZeroMaxViewsByDesignAreNotAMeasurement() public {
        _enter(alice, 10_000e6);
        _invest(8000e6);
        assertEq(reserve.maxWithdraw(address(partner)), 0, "the view reports zero while the reserve pays");
        assertEq(partner.freeLiquidity(), 10_000e6);
        assertApproxEqAbs(_exitAll(alice), 10_000e6, 2);
    }

    /// @dev Declared plain, the same reserve would be read as paying nothing: the kind is part of the deployment.
    function testTheSameReserveDeclaredPlainReadsAsIlliquid() public {
        _stand(address(0));
        _enter(alice, 10_000e6);
        _invest(8000e6);
        assertEq(partner.freeLiquidity(), 2000e6);
    }

    function testALensMustBeAContract() public {
        vm.expectRevert(IntentFactory.InvalidConfiguration.selector);
        _factory(address(0xBEEF));
    }
}

/// @dev A Morpho Blue market as the lens reads it: its supply and borrow assets.
contract LensBlueStub {
    uint128 internal _supply;
    uint128 internal _borrow;

    function set(uint128 supply, uint128 borrow) external {
        _supply = supply;
        _borrow = borrow;
    }

    function market(bytes32) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (_supply, 0, _borrow, 0, 0, 0);
    }
}

/// @dev A market adapter as the lens reads it: its Morpho Blue and its supply there, or a revert once it fails.
contract LensAdapterStub {
    error AdapterDown();

    address public immutable morpho;
    uint256 internal immutable _SUPPLIED;
    bool internal _down;

    constructor(address morpho_, uint256 supplied) {
        morpho = morpho_;
        _SUPPLIED = supplied;
    }

    function fail() external {
        _down = true;
    }

    function expectedSupplyAssets(bytes32) external view returns (uint256) {
        if (_down) revert AdapterDown();
        return _SUPPLIED;
    }
}

/// @dev Answers every call with success and no data, so nothing it returns decodes.
contract LensSilentAdapter {
    fallback() external {}
}

/// @notice Pashov M-31, M-57: the real `MorphoV2ReserveLens` over the local reserve, with the Vault V2 liquidity
/// getters mocked. A liquidity adapter the lens cannot read (another kind, one that reverts, one whose Morpho has no
/// code, one whose answers do not decode) adds nothing: the reserve's idle balance is counted alone, which understates
/// and never overstates, so exits and fills that cash and that balance cover go on.
contract IntentMorphoLensFallbackTest is IntentAccountingBaseTest {
    MorphoV2ReserveLens internal lens;
    LensBlueStub internal blue;

    function setUp() public override {
        super.setUp();
        lens = new MorphoV2ReserveLens();
        _stand(address(lens));
        blue = new LensBlueStub();
        _useAdapter(address(0));
        _enter(alice, 10_000e6);
        _invest(5000e6);
        assertEq(partner.freeLiquidity(), 10_000e6, "cash and the idle reserve");
    }

    /// @dev The reserve names `adapter` for withdrawals, with a market's five parameters as its data.
    function _useAdapter(address adapter) internal {
        bytes memory data = abi.encode(address(usdg), address(nvda), address(0x0AC1E), address(0x1235), 0.86e18);
        vm.mockCall(address(reserve), abi.encodeCall(IMorphoVaultV2.liquidityAdapter, ()), abi.encode(adapter));
        vm.mockCall(address(reserve), abi.encodeCall(IMorphoVaultV2.liquidityData, ()), abi.encode(data));
    }

    function _assertIdleOnly() internal view {
        assertEq(lens.withdrawable(address(reserve), address(partner)), 5000e6, "not the idle balance alone");
        assertEq(partner.freeLiquidity(), 10_000e6, "not cash and the idle balance");
    }

    /// @dev Pashov M-31. The reserve's allocator makes an adapter of another kind its liquidity adapter, here a
    /// contract without the market ABI. The lens reverted, and with it every redemption and purchase, even one the
    /// vault's own cash covered. Now the idle balance is counted alone, and exits and fills go on.
    function testAnAdapterOfAnotherKindLeavesExitsAndFillsOpen() public {
        _useAdapter(address(usdg));
        _assertIdleOnly();
        assertApproxEqAbs(_exit(alice, partner.convertToShares(100e6)), 100e6, 2, "an exit from cash");
        _reviewLoan();
        assertEq(partner.performingPrincipal(), REVIEW_PRINCIPAL, "a fill from cash");
        vm.warp(block.timestamp + 1);
        // 3,900 of cash and 2,100 of the reserve's idle balance.
        assertApproxEqAbs(_exit(alice, partner.convertToShares(6000e6)), 6000e6, 2, "an exit from the reserve");
        assertEq(partner.cash(), 0);
    }

    /// @dev Pashov M-57. An adapter whose `expectedSupplyAssets` reverts adds nothing, and the exit goes on.
    function testARevertingAdapterCountsTheIdleBalanceOnly() public {
        LensAdapterStub adapter = new LensAdapterStub(address(blue), 700e6);
        blue.set(1000e6, 0);
        adapter.fail();
        _useAdapter(address(adapter));
        _assertIdleOnly();
        assertApproxEqAbs(_exit(alice, partner.convertToShares(7000e6)), 7000e6, 2);
    }

    /// @dev Pashov M-57. An adapter whose `morpho()` names an address without code adds nothing.
    function testAnAdapterWhoseMorphoHasNoCodeCountsTheIdleBalanceOnly() public {
        _useAdapter(address(new LensAdapterStub(makeAddr("no Morpho here"), 700e6)));
        _assertIdleOnly();
        assertApproxEqAbs(_exit(alice, partner.convertToShares(7000e6)), 7000e6, 2);
    }

    /// @dev Pashov M-31, M-57. Answers that do not decode add nothing: an adapter that returns no data, and an adapter
    /// address with no code at all.
    function testAnAdapterWhoseAnswersDoNotDecodeCountsTheIdleBalanceOnly() public {
        _useAdapter(address(new LensSilentAdapter()));
        _assertIdleOnly();
        _useAdapter(makeAddr("no adapter here"));
        _assertIdleOnly();
        assertApproxEqAbs(_exit(alice, partner.convertToShares(7000e6)), 7000e6, 2);
    }

    /// @dev Pashov M-31. The fallback understates and never overstates. With part of the reserve's value in a market
    /// behind an adapter the lens cannot read, only cash and the idle balance are free, and a larger exit is refused by
    /// the vault before anything moves.
    function testTheFallbackNeverCountsWhatTheLensCannotRead() public {
        _useAdapter(address(usdg));
        // The reserve prices the position at 8,000: 5,000 idle and 3,000 in a market the lens cannot read.
        vm.mockCall(
            address(reserve), abi.encodeCall(reserve.convertToAssets, (partner.reserveShares())), abi.encode(8000e6)
        );
        assertEq(partner.totalAssets(), 13_000e6);
        assertEq(partner.freeLiquidity(), 10_000e6, "only cash and the idle balance");
        uint256 shares = partner.balanceOf(alice);
        uint256 cash = partner.cash();
        uint256 reserveShares = partner.reserveShares();
        uint256 over = partner.convertToShares(10_001e6);
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(over, 0);
        assertEq(partner.balanceOf(alice), shares);
        assertEq(partner.cash(), cash);
        assertEq(partner.reserveShares(), reserveShares);
    }

    /// @dev Pashov M-31. The adapter the lens was written for reads as before: the idle balance, plus the adapter's
    /// supply up to what its market has not lent.
    function testAReadableAdapterStillCountsItsMarket() public {
        _useAdapter(address(new LensAdapterStub(address(blue), 700e6)));
        blue.set(1000e6, 600e6);
        assertEq(lens.withdrawable(address(reserve), address(partner)), 5400e6, "what the market has not lent");
        blue.set(1000e6, 0);
        assertEq(lens.withdrawable(address(reserve), address(partner)), 5700e6, "the adapter's supply");
        blue.set(1000e6, 1000e6);
        assertEq(lens.withdrawable(address(reserve), address(partner)), 5000e6, "a fully lent market");
        blue.set(1000e6, 1200e6);
        assertEq(lens.withdrawable(address(reserve), address(partner)), 5000e6, "borrow above supply");
    }
}

/// @dev Morpho Blue's market parameters, which the market adapter decodes from a reserve's liquidity data.
struct LensMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @dev A market adapter in MorphoMarketV1AdapterV2's shape: it supplies one Morpho Blue market (here, the USDG it
/// holds) and reports that supply for that market's id only. `deallocate` takes the market from the reserve's liquidity
/// data as the adapter does, `abi.decode(data, (MarketParams)).id()`: trailing bytes are ignored, and data that does
/// not decode reverts.
contract LensMarketAdapter {
    error UnknownMarket();

    IERC20 internal immutable _USDG;
    address public immutable morpho;
    bytes32 internal immutable _MARKET;

    constructor(IERC20 usdg, address morpho_, bytes32 market) {
        _USDG = usdg;
        morpho = morpho_;
        _MARKET = market;
    }

    function expectedSupplyAssets(bytes32 id) external view returns (uint256) {
        return id == _MARKET ? _USDG.balanceOf(address(this)) : 0;
    }

    function deallocate(bytes calldata data, uint256 assets) external {
        if (keccak256(abi.encode(abi.decode(data, (LensMarketParams)))) != _MARKET) revert UnknownMarket();
        _USDG.transfer(msg.sender, assets);
    }
}

/// @dev The local reserve with a Morpho Vault V2's liquidity adapter: it prices its idle USDG and the adapter's supply,
/// and a withdrawal beyond the idle balance first deallocates the shortfall from the liquidity adapter with the
/// liquidity data, as VaultV2's exit does.
contract LensMarketReserve is HybridReserveMock {
    address public liquidityAdapter;
    bytes public liquidityData;

    constructor(IERC20 usdg) HybridReserveMock(usdg) {}

    function setLiquidityAdapterAndData(address adapter, bytes calldata data) external {
        liquidityAdapter = adapter;
        liquidityData = data;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + IERC20(asset()).balanceOf(liquidityAdapter);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) LensMarketAdapter(liquidityAdapter).deallocate(liquidityData, assets - idle);
        return super.withdraw(assets, receiver, owner);
    }
}

/// @notice Pashov M-56: the real `MorphoV2ReserveLens` reads the market the liquidity adapter withdraws from. The
/// adapter decodes the liquidity data into the market's five parameters and ignores what follows them; the lens derives
/// the market id the same way instead of hashing the raw bytes. Data the adapter cannot decode pays nothing from the
/// market, and the lens counts the idle balance alone.
contract IntentMorphoLensMarketIdTest is IntentAccountingBaseTest {
    MorphoV2ReserveLens internal lens;
    LensMarketReserve internal marketReserve;
    LensMarketAdapter internal adapter;
    bytes internal canonical;

    function setUp() public override {
        super.setUp();
        marketReserve = new LensMarketReserve(IERC20(address(usdg)));
        reserve = marketReserve;
        lens = new MorphoV2ReserveLens();
        _stand(address(lens));
        LensBlueStub blue = new LensBlueStub();
        canonical =
            abi.encode(LensMarketParams(address(usdg), address(nvda), address(0x0AC1E), address(0x1235), 0.86e18));
        adapter = new LensMarketAdapter(IERC20(address(usdg)), address(blue), keccak256(canonical));
        marketReserve.setLiquidityAdapterAndData(address(adapter), canonical);
        _enter(alice, 10_000e6);
        _invest(8000e6);
        // The reserve supplies 3,000 to the market through its liquidity adapter, none of it lent; 5,000 stays idle.
        reserve.simulateLoss(3000e6, address(adapter));
        blue.set(3000e6, 0);
        assertEq(partner.totalAssets(), 10_000e6);
    }

    /// @dev Whether the reserve pays `assets` to the vault; the payment is undone.
    function _reservePays(uint256 assets) internal returns (bool paid) {
        uint256 state = vm.snapshotState();
        vm.prank(address(partner));
        try marketReserve.withdraw(assets, address(partner), address(partner)) {
            paid = true;
        } catch {}
        vm.revertToState(state);
    }

    function testCanonicalLiquidityDataReadsTheMarket() public {
        assertEq(lens.withdrawable(address(reserve), address(partner)), 8000e6, "the idle balance and the market");
        assertEq(partner.freeLiquidity(), 10_000e6);
        assertApproxEqAbs(_exitAll(alice), 10_000e6, 2);
    }

    /// @dev Pashov M-56. With one word after the five parameters the adapter still withdraws from the market, so the
    /// reserve pays its whole position. The lens hashed the raw bytes, read a market with no supply and counted the
    /// idle balance alone, and the vault refused an exit the reserve could pay. It now reads the adapter's market.
    function testExtendedLiquidityDataReadsTheMarketTheAdapterWithdrawsFrom() public {
        marketReserve.setLiquidityAdapterAndData(address(adapter), bytes.concat(canonical, bytes32(uint256(1))));
        assertTrue(_reservePays(8000e6), "the adapter withdraws from the market");
        assertEq(lens.withdrawable(address(reserve), address(partner)), 8000e6, "not the market the adapter uses");
        assertEq(partner.freeLiquidity(), 10_000e6);
        assertApproxEqAbs(_exitAll(alice), 10_000e6, 2, "an exit through the market");
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    /// @dev Data the adapter cannot decode, too short or with a dirty address word, pays nothing from the market. The
    /// lens counts the idle balance alone and does not revert, so exits that cash and that balance cover go on.
    function testUndecodableLiquidityDataCountsTheIdleBalanceOnly() public {
        bytes memory dirty = bytes.concat(canonical);
        dirty[0] = 0x01;
        bytes[2] memory undecodable = [_prefix(canonical, 96), dirty];
        for (uint256 i; i < undecodable.length; ++i) {
            marketReserve.setLiquidityAdapterAndData(address(adapter), undecodable[i]);
            assertTrue(_reservePays(5000e6), "the idle balance pays");
            assertFalse(_reservePays(5000e6 + 1), "the market pays nothing");
            assertEq(lens.withdrawable(address(reserve), address(partner)), 5000e6, "not the idle balance alone");
            assertEq(partner.freeLiquidity(), 7000e6, "not cash and the idle balance");
        }
        uint256 over = partner.convertToShares(7000e6 + 1e6);
        vm.prank(alice);
        vm.expectRevert(IntentVault.InsufficientLiquidity.selector);
        partner.redeem(over, 0);
        assertApproxEqAbs(_exit(alice, partner.convertToShares(7000e6)), 7000e6, 2);
    }

    function _prefix(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[i];
        }
    }
}
