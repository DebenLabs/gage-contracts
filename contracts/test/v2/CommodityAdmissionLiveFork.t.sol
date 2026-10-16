// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

interface ICommodityV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

interface ICommodityV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

/// Tests the deployed current V3 engine against a commodity ETF Stock Token (GLD, SLV, USO) as token-only STOCK
/// collateral. Its pricing and cash-out route is its canonical Uniswap v3 token / USDG pool: one cash-out step. Only the
/// token admission, the v3 cash-out routes and test capital change locally.
abstract contract CommodityAdmissionLiveForkBase is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    address borrower;
    address lender;
    address swapping;

    function _token() internal pure virtual returns (address);
    /// The first pool is the depth pool the limits come from; every pool is a cash-out route.
    function _pools() internal pure virtual returns (address[] memory);
    function _min() internal pure virtual returns (uint256);
    function _perDeal() internal pure virtual returns (uint256);
    function _aggregate() internal pure virtual returns (uint256);

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_COMMODITY_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_COMMODITY_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        // Every Robinhood Stock Token is the same issuer beacon proxy: the runtime equals an admitted one's.
        assertEq(_token().codehash, SPY.codehash);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        assertEq(address(cashout.V3_FACTORY()), V3_FACTORY);
        assertFalse(registry.getERC20Config(_token()).allowed);
        vm.prank(registry.owner());
        registry.setERC20Allowed(_token(), true, Lane.STOCK, _min(), _perDeal(), _aggregate());
        _configureRoutes();
        borrower = makeAddr("commodity borrower");
        lender = makeAddr("commodity lender");
        deal(_token(), borrower, 2 * _aggregate());
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(_token()).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    /// Override only the route mechanics to reuse the same custody, lifecycle and limit checks for v4.
    function _configureRoutes() internal virtual {
        address[] memory pools = _pools();
        for (uint256 i; i < pools.length; ++i) {
            ICommodityV3Pool p = ICommodityV3Pool(pools[i]);
            assertEq(p.factory(), V3_FACTORY);
            assertEq(ICommodityV3Factory(V3_FACTORY).getPool(p.token0(), p.token1(), p.fee()), pools[i]);
            assertTrue((p.token0() == _token() && p.token1() == USDG) || (p.token0() == USDG && p.token1() == _token()));
            assertTrue(pools[i] != address(cashout.FLASH_POOL()));
            assertGt(p.liquidity(), 0);
            assertFalse(cashout.v3Allowed(pools[i]));
            _setRouteAllowed(i, true);
        }
    }

    function _setRouteAllowed(uint256 i, bool allowed) internal virtual {
        vm.prank(cashout.owner());
        cashout.setV3Route(_pools()[i], allowed);
    }

    function _routeFee(uint256 i) internal view virtual returns (uint24) {
        return ICommodityV3Pool(_pools()[i]).fee();
    }

    /// Pays the v3 pool for this contract's own exact-input sale.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        assertEq(msg.sender, swapping);
        if (amount0Delta > 0) {
            IERC20(ICommodityV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(ICommodityV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function _list(Collateral memory c) internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(c, 90e6, 100e6, 7 days, uint40(block.timestamp + 1 days), false);
    }

    function _fund(uint256 id) internal {
        vm.prank(lender);
        vault.fund(id, 4);
    }

    function _repay(uint256 id) internal {
        vm.startPrank(borrower);
        vault.reclaim(id, borrower);
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
    }

    function _default(uint256 id) internal {
        vm.warp(block.timestamp + 7 days + vault.GRACE());
        vault.finalizeDefault(id);
        vm.prank(lender);
        vault.recoverDefault(id, 0, 0, block.timestamp);
    }

    /// USDG raw value of `amount` raw tokens at the depth pool's spot, before the swap fee and impact. token1 per token0
    /// is sqrt^2 / 2^192.
    function _spotUSDG(uint256 amount) internal view virtual returns (uint256) {
        ICommodityV3Pool p = ICommodityV3Pool(_pools()[0]);
        (uint160 sqrtPrice,,,,,,) = p.slot0();
        uint256 square = uint256(sqrtPrice) * sqrtPrice;
        return
            p.token0() == _token()
                ? FullMath.mulDiv(amount, square, 1 << 192)
                : FullMath.mulDiv(amount, 1 << 192, square);
    }

    /// Sell `amount` raw tokens for USDG through one v3 pool, with no price limit short of the pool's bounds.
    function _sell(address pool, uint256 amount) internal virtual returns (uint256 usdgOut) {
        deal(_token(), address(this), amount);
        uint256 beforeOut = IERC20(USDG).balanceOf(address(this));
        bool zeroForOne = ICommodityV3Pool(pool).token0() == _token();
        swapping = pool;
        ICommodityV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                ""
            );
        swapping = address(0);
        assertEq(IERC20(_token()).balanceOf(address(this)), 0, "Partial v3 fill");
        usdgOut = IERC20(USDG).balanceOf(address(this)) - beforeOut;
    }

    /// One cash-out step: token -> USDG on the v3 pool with this fee tier. The v4 key is unused by a v3 step.
    function _exit(uint256 id, uint24 fee) internal view virtual returns (GageV2CashoutRouter.Exit memory x) {
        PoolKey memory unused;
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1; // ERC20 collateral recovers a single asset; the second minimum must be zero.
        x.minUnderlying1 = 0;
        x.deadline = block.timestamp;
        x.routes = new GageV2CashoutRouter.Route[](1);
        x.routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, _token(), USDG, fee, unused, 1);
    }

    function testCommodity_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(_token()).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
        _fund(id);
        assertEq(IERC20(_token()).balanceOf(vault.getLoan(id).account), _perDeal());
        _repay(id);
        assertEq(IERC20(_token()).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(_token()).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(_token()).balanceOf(lender) - lenderBefore, _perDeal());
    }

    function testCommodity_stockLaneLimitsRevocationAndLegacyRemainClosed() public {
        assertEq(uint256(registry.getERC20Config(_token()).lane), uint256(Lane.STOCK));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, _token(), _min() - 1));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, _token(), _perDeal() + 1));
        uint256 first;
        uint256 n = _aggregate() / _perDeal();
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, _token(), _min()));
        vm.prank(registry.owner());
        registry.setERC20Allowed(_token(), false, Lane.STOCK, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, _token(), _min()));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(_token()).balanceOf(borrower), 2 * _aggregate() - (n - 1) * _perDeal());
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(_token()).allowed);
        assertFalse(memeUsdg.getERC20Config(_token()).allowed);
        assertFalse(ponsWeth.getERC20Config(_token()).allowed);
    }

    function testCommodity_cashoutThroughEachV3Pool() public {
        address[] memory pools = _pools();
        for (uint256 i; i < pools.length; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
            _fund(id);
            vm.prank(borrower);
            vault.approve(address(cashout), id);
            GageV2CashoutRouter.Exit memory x = _exit(id, _routeFee(i));
            uint256 before = IERC20(USDG).balanceOf(borrower);
            uint256 routerToken = IERC20(_token()).balanceOf(address(cashout));
            vm.prank(borrower);
            (,,, uint256 net) = cashout.cashOutDetailed(x);
            assertGt(net, 0);
            assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
            assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
            assertEq(IERC20(_token()).balanceOf(address(cashout)), routerToken);
        }
    }

    function testCommodity_cashoutRequiresTheRoute() public {
        uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _exit(id, _routeFee(0));
        _setRouteAllowed(0, false);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testCommodity_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(_perDeal());
        uint256 out = _sell(_pools()[0], _perDeal());
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testCommodity_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(_aggregate());
        uint256 out = _sell(_pools()[0], _aggregate());
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }
}

/// GLD, SPDR Gold Trust: the 0.3% v3 GLD / USDG pool is the depth pool, the 0.05% pool a second cash-out route.
contract GldAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = 0x7A6A053eCCf1446A2633E05aA6D40D09381997ec;
        pools[1] = 0xBA2f1ed4cEB2169D538d1e614D847E83C5A55913;
    }

    function _min() internal pure override returns (uint256) {
        return 0.25e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 180e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 900e18;
    }
}

/// SLV, iShares Silver Trust: one 0.3% v3 SLV / USDG pool.
contract SlvAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x8cB787e6c315D464775289BaD00FDD67d53Ecb3D;
    }

    function _min() internal pure override returns (uint256) {
        return 1.7e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 140e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 700e18;
    }
}

/// USO, United States Oil Fund: one 0.3% v3 USO / USDG pool.
contract UsoAdmissionLiveForkTest is CommodityAdmissionLiveForkBase {
    function _token() internal pure override returns (address) {
        return 0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x02175608F1b5E6b5ed221cCFdC7Be197D111D915;
    }

    function _min() internal pure override returns (uint256) {
        return 0.65e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 230e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 1150e18;
    }
}
