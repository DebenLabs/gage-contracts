// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

interface IUpV3Pool {
    function token0() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

interface IUpWeth {
    function withdraw(uint256) external;
}

interface IUpEarn {
    function CURATOR() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRADES() external view returns (address);
    function pickedAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external;
}

interface IUpGrades {
    function publisher() external view returns (address);
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external;
}

/// Token-only UP admission on the current V3 engine at a pinned mainnet fork: custody, reclaim, default recovery,
/// limits, both canonical Uniswap v3 cash-out routes and Memes Earn funding. Only the three owner calls of the
/// prepared Safe batch, test capital and the normal grade publication change locally.
contract UpAdmissionLiveForkTest is V4Fixture {
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    /// Canonical Uniswap v3 WETH / UP, 1% fee: the primary exit, followed by the native ETH / USDG v4 pool.
    address constant UP_WETH = 0x4EF94cD1Ab45eBbB50F9E73Cd6e45C5027caa3F7;
    /// Canonical Uniswap v3 UP / USDG, 1% fee: the second, much shallower direct exit.
    address constant UP_USDG = 0xb51d3B81eb40f233919AF58bF8BCA4A57E07192b;
    bytes32 constant ETH_POOL = 0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e;
    /// The app's shared WETH exit (already enabled, unchanged): canonical v3 WETH / PONS, then PONS / USDG.
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant WETH_PONS = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA;
    bytes32 constant PONS_POOL = 0x4be9657ec9002e528f4f17a5c43edc525a07f888f7b180c2afbf75e096c4f38a;
    uint256 constant MIN = 200e18;
    uint256 constant PER_DEAL = 5000e18;
    uint256 constant AGGREGATE = 24_000e18;
    uint256 constant DEALT = 100_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey ethKey;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_UP_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_UP_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(UP.codehash, vm.envBytes32("GAGE_UP_TOKEN_HASH"));
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        assertEq(address(cashout.VAULT()), address(vault));
        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        assertEq(_poolId(ethKey), ETH_POOL);
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(ethKey));
        assertFalse(registry.getERC20Config(UP).allowed);
        assertFalse(cashout.v3Allowed(UP_WETH));
        assertFalse(cashout.v3Allowed(UP_USDG));
        // Exactly the prepared Safe batch: token admission and the two canonical v3 routes.
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(UP, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        cashout.setV3Route(UP_WETH, true);
        cashout.setV3Route(UP_USDG, true);
        vm.stopPrank();
        borrower = makeAddr("UP borrower");
        lender = makeAddr("UP lender");
        deal(UP, borrower, DEALT);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(UP).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    /// Pays either canonical pool for this contract's own exact-input sales.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == UP_WETH || msg.sender == UP_USDG, "Unexpected pool");
        address input = amount0Delta > 0 ? IUpV3Pool(msg.sender).token0() : UP;
        require(input == UP, "Only UP is sold");
        IERC20(UP).transfer(msg.sender, uint256(amount0Delta > 0 ? amount0Delta : amount1Delta));
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

    function _sqrt(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (, bytes memory data) = STATE_VIEW.staticcall(abi.encodeWithSignature("getSlot0(bytes32)", poolId));
        (sqrtPriceX96,,,) = abi.decode(data, (uint160, int24, uint24, uint24));
    }

    /// USDG raw value of `amount` raw UP at the WETH / UP and ETH / USDG spot, before fees and impact.
    /// WETH is token0 of the v3 pool, so WETH per UP is 2^192 / sqrtPrice^2; USDG per ETH is sqrtEth^2 / 2^192.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        (uint160 sqrtToken,,,,,,) = IUpV3Pool(UP_WETH).slot0();
        uint256 sqrtEth = _sqrt(ETH_POOL);
        uint256 eth = FullMath.mulDiv(amount, 1 << 192, uint256(sqrtToken) * sqrtToken);
        return FullMath.mulDiv(eth, sqrtEth * sqrtEth, 1 << 192);
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// Exact-input v4 sale of native ETH into ETH / USDG.
    function _sellEth(uint256 amount) internal returns (uint256 out) {
        uint256 beforeIn = address(this).balance;
        uint256 beforeOut = IERC20(USDG).balanceOf(address(this));
        swapRouter.swap{value: amount}(
            ethKey,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(beforeIn - address(this).balance, amount, "Partial ETH fill");
        out = IERC20(USDG).balanceOf(address(this)) - beforeOut;
    }

    /// Primary exit: sell `amount` raw UP into WETH on the canonical v3 pool, unwrap, then sell ETH for USDG.
    function _sellViaWeth(uint256 amount) internal returns (uint256 usdgOut) {
        deal(UP, address(this), amount);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        IUpV3Pool(UP_WETH).swap(address(this), false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, "");
        assertEq(IERC20(UP).balanceOf(address(this)), 0, "Partial v3 fill");
        uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        assertGt(wethOut, 0);
        IUpWeth(WETH).withdraw(wethOut);
        usdgOut = _sellEth(wethOut);
    }

    /// Second exit: sell `amount` raw UP directly for USDG on the canonical v3 UP / USDG pool (UP is token0).
    /// Returns the UP left unsold when the pool runs out of liquidity before the whole amount is sold.
    function _trySellDirect(uint256 amount) internal returns (uint256 usdgOut, uint256 unsold) {
        deal(UP, address(this), amount);
        uint256 before = IERC20(USDG).balanceOf(address(this));
        IUpV3Pool(UP_USDG).swap(address(this), true, int256(amount), TickMath.MIN_SQRT_PRICE + 1, "");
        unsold = IERC20(UP).balanceOf(address(this));
        usdgOut = IERC20(USDG).balanceOf(address(this)) - before;
    }

    function _sellDirect(uint256 amount) internal returns (uint256 usdgOut) {
        uint256 unsold;
        (usdgOut, unsold) = _trySellDirect(amount);
        assertEq(unsold, 0, "Partial v3 fill");
    }

    /// The better of the two enabled exits for a whole sale; the cash-out router takes one path per exit and
    /// reverts when a pool cannot absorb the whole amount, so a partial direct fill counts as no exit.
    function _bestExit(uint256 amount) internal returns (uint256 out) {
        uint256 snapshot = vm.snapshotState();
        (uint256 direct, uint256 unsold) = _trySellDirect(amount);
        if (unsold != 0) direct = 0;
        vm.revertToState(snapshot);
        out = _sellViaWeth(amount);
        if (direct > out) out = direct;
    }

    function _wethRoutes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](3);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, UP, WETH, 10_000, ethKey, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.UNWRAP_WETH, WETH, address(0), 0, ethKey, 1);
        routes[2] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, address(0), USDG, 0, ethKey, 1);
    }

    function _directRoutes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](1);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, UP, USDG, 10_000, ethKey, 1);
    }

    function _exit(uint256 id, GageV2CashoutRouter.Route[] memory routes)
        internal
        view
        returns (GageV2CashoutRouter.Exit memory x)
    {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1; // ERC20 collateral recovers a single asset; the second minimum must be zero.
        x.minUnderlying1 = 0;
        x.deadline = block.timestamp;
        x.routes = routes;
    }

    function _cashOut(uint256 id, GageV2CashoutRouter.Route[] memory routes) internal returns (uint256 net) {
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerEth = address(cashout).balance;
        uint256 routerWeth = IERC20(WETH).balanceOf(address(cashout));
        uint256 routerToken = IERC20(UP).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, net) = cashout.cashOutDetailed(_exit(id, routes));
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(address(cashout).balance, routerEth);
        assertEq(IERC20(WETH).balanceOf(address(cashout)), routerWeth);
        assertEq(IERC20(UP).balanceOf(address(cashout)), routerToken);
    }

    function testUp_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(UP).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        _fund(id);
        // Exact custody balance: UP has no transfer fee.
        assertEq(IERC20(UP).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(UP).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(UP).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(UP).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testUp_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, UP, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, UP, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
            if (i == 0) first = id;
        }
        // 24,000 is not a multiple of 5,000: the remainder still lists, then the aggregate is full.
        uint256 rest = AGGREGATE - n * PER_DEAL;
        _list(Collateral(Kind.ERC20, UP, rest));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, UP, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(UP, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, UP, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(UP).balanceOf(borrower), DEALT - AGGREGATE + PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(UP).allowed);
        assertFalse(memeUsdg.getERC20Config(UP).allowed);
        assertFalse(ponsWeth.getERC20Config(UP).allowed);
    }

    function testUp_cashoutThroughV3WethAndEth() public {
        uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        _fund(id);
        _cashOut(id, _wethRoutes());
    }

    function testUp_cashoutThroughDirectV3Usdg() public {
        uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        _fund(id);
        _cashOut(id, _directRoutes());
    }

    /// The app's route builder sends WETH along its shared WETH path, as it does for HMM: WETH / PONS on the
    /// canonical v3 pool, then PONS / USDG. Both legs are already enabled on the router and stay unchanged.
    function testUp_cashoutThroughAppWethPath() public {
        PoolKey memory ponsKey = PoolKey(Currency.wrap(PONS), Currency.wrap(USDG), 3000, 60, IHooks(address(0)));
        assertEq(_poolId(ponsKey), PONS_POOL);
        assertTrue(cashout.v3Allowed(WETH_PONS));
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(ponsKey));
        GageV2CashoutRouter.Route[] memory routes = new GageV2CashoutRouter.Route[](3);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, UP, WETH, 10_000, ethKey, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, WETH, PONS, 10_000, ethKey, 1);
        routes[2] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, PONS, USDG, 0, ponsKey, 1);
        uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        _fund(id);
        uint256 routerPons = IERC20(PONS).balanceOf(address(cashout));
        _cashOut(id, routes);
        assertEq(IERC20(PONS).balanceOf(address(cashout)), routerPons);
    }

    function testUp_cashoutRequiresEachEnabledLeg() public {
        uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        address owner = cashout.owner();
        vm.prank(owner);
        cashout.setV3Route(UP_WETH, false);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(_exit(id, _wethRoutes()));
        vm.startPrank(owner);
        cashout.setV3Route(UP_WETH, true);
        cashout.setV4Route(ethKey, false);
        vm.stopPrank();
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(_exit(id, _wethRoutes()));
        vm.startPrank(owner);
        cashout.setV4Route(ethKey, true);
        cashout.setV3Route(UP_USDG, false);
        vm.stopPrank();
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(_exit(id, _directRoutes()));
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testUp_existingMemesVaultCanFundAfterAdmissionAndNormalGradePublication() public {
        IUpEarn earn = IUpEarn(address(bytes20(hex"c04a365061e5d3cf7f614cf353494294b0e3f0c9")));
        assertEq(earn.REGISTRY(), address(registry));
        assertEq(earn.pickedAssets(), 0);
        uint256 id = _list(Collateral(Kind.ERC20, UP, PER_DEAL));
        // Mirror the existing D132 keeper policy: publish TOP_RANK for an admitted token.
        IUpGrades grades = IUpGrades(earn.GRADES());
        address[] memory tokens = new address[](1);
        tokens[0] = UP;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 10;
        vm.prank(grades.publisher());
        grades.setGrades(tokens, ranks);
        uint256 before = earn.freeLiquidity();
        vm.prank(earn.CURATOR());
        earn.fund(id, 4, type(uint256).max);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(before - earn.freeLiquidity(), 90e6);
        assertEq(IERC20(UP).balanceOf(vault.getLoan(id).account), PER_DEAL);
    }

    function testUp_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _bestExit(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    /// D161: the aggregate follows the rate model's exposure envelope, and the Uniswap-only exit keeps about
    /// 92% of spot at that size, below the 95% bound of earlier listings. The bound here is the accepted 90%.
    function testUp_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _bestExit(AGGREGATE);
        assertGe(out * 100, spot * 90, "maxOpen exit under 90% of spot");
    }
}
