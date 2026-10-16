// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IUniV3Pool} from "../../src/interfaces/IUniV3.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

interface ICuckSwapPool is IUniV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

interface ICuckEarn {
    function CURATOR() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRADES() external view returns (address);
    function pickedAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external;
}

interface ICuckGrades {
    function publisher() external view returns (address);
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external;
}

/// Current V3 custody, reclaim, recovery and executable route checks for Cuckware token only.
contract CuckAdmissionLiveForkTest is V4Fixture {
    address constant CUCK = address(bytes20(hex"7648f37c2314466726a28f7a5edbdb8dc7b3e23f"));
    address constant HOOD = 0x32aC8C1D7672667D5EbdEa22935F7B06fC8D496f;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant V3_POOL = address(bytes20(hex"3f9d7f67d98f9a5c9283d69a65ed0d5fddd179c2"));
    address constant HOOD_HOOK = address(0);
    bytes32 constant HOOD_POOL = 0x7fb39eb653999feb9f0d3b1410848911383dfc681f3585229df4aa5b560bf0ba;
    uint256 constant MIN = 100_000e18;
    uint256 constant PER_DEAL = 500_000e18;
    uint256 constant AGGREGATE = 2_500_000e18;
    uint256 constant DEALT = 100_000_000e18;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey key;
    PoolKey hoodKey;
    address borrower;
    address lender;

    receive() external payable {}

    function uniswapV3SwapCallback(int256 delta0, int256 delta1, bytes calldata data) external {
        require(msg.sender == V3_POOL && delta0 < 0 && delta1 > 0, "Invalid callback");
        require(uint256(delta1) <= abi.decode(data, (uint256)), "Input exceeded");
        IERC20(CUCK).transfer(msg.sender, uint256(delta1));
    }

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_CUCK_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_CUCK_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(CUCK.codehash, vm.envBytes32("GAGE_CUCK_TOKEN_HASH"));
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        hoodKey = PoolKey(Currency.wrap(HOOD), Currency.wrap(USDG), 2000, 20, IHooks(HOOD_HOOK));
        assertEq(_poolId(hoodKey), HOOD_POOL);
        assertFalse(registry.getERC20Config(CUCK).allowed);
        assertFalse(registry.getERC20Config(HOOD).allowed);
        assertFalse(cashout.v3Allowed(V3_POOL));
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(hoodKey));
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(CUCK, true, Lane.MEME, MIN, PER_DEAL, AGGREGATE);
        cashout.setV3Route(V3_POOL, true);
        cashout.setV4Route(hoodKey, true);
        vm.stopPrank();
        borrower = makeAddr("CUCK borrower");
        lender = makeAddr("CUCK lender");
        deal(CUCK, borrower, DEALT);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(CUCK).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
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
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
    }

    /// CUCK is currency1 of CUCK/HOOD; HOOD is currency0 of HOOD/USDG.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        (uint160 sqrt,,,,,,) = IUniV3Pool(V3_POOL).slot0();
        uint256 a = sqrt;
        uint256 b = _sqrt(HOOD_POOL);
        uint256 hood = FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, a), 1 << 96, a);
        return FullMath.mulDiv(FullMath.mulDiv(hood, b, 1 << 96), b, 1 << 96);
    }

    /// Exact-input v4 swap by this contract; hook charges and the dynamic LP fee come out of the swap.
    function _swapExact(PoolKey memory k, address tokenIn, uint256 amount) internal returns (uint256 out) {
        bool zeroForOne = tokenIn == Currency.unwrap(k.currency0);
        address output = Currency.unwrap(zeroForOne ? k.currency1 : k.currency0);
        uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 beforeOut = IERC20(output).balanceOf(address(this));
        IERC20(tokenIn).approve(address(swapRouter), amount);
        swapRouter.swap(
            k,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(beforeIn - IERC20(tokenIn).balanceOf(address(this)), amount, "Partial fill or input transfer mismatch");
        out = IERC20(output).balanceOf(address(this)) - beforeOut;
    }

    /// Sell `amount` raw CUCK through the canonical v3 pool, then the HOOD through HOOD / USDG.
    function _sellTwoHop(uint256 amount) internal returns (uint256 usdgOut) {
        deal(CUCK, address(this), amount);
        uint256 beforeHood = IERC20(HOOD).balanceOf(address(this));
        ICuckSwapPool(V3_POOL)
            .swap(address(this), false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, abi.encode(amount));
        assertEq(IERC20(CUCK).balanceOf(address(this)), 0, "Partial v3 fill");
        uint256 hoodOut = IERC20(HOOD).balanceOf(address(this)) - beforeHood;
        assertGt(hoodOut, 0);
        usdgOut = _swapExact(hoodKey, HOOD, hoodOut);
    }

    /// Cash-out routes: CUCK -> HOOD on the canonical v3 pool, HOOD -> USDG.
    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V3, CUCK, HOOD, 10_000, key, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, HOOD, USDG, 0, hoodKey, 1);
    }

    function _erc20Exit(uint256 id) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1; // ERC20 collateral recovers a single asset; the second minimum must be zero.
        x.minUnderlying1 = 0;
        x.deadline = block.timestamp;
        x.routes = _routes();
    }

    function testCuck_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(CUCK).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, CUCK, PER_DEAL));
        _fund(id);
        assertEq(IERC20(CUCK).balanceOf(vault.getLoan(id).account), PER_DEAL);
        _repay(id);
        assertEq(IERC20(CUCK).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, CUCK, PER_DEAL));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(CUCK).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(CUCK).balanceOf(lender) - lenderBefore, PER_DEAL);
    }

    function testCuck_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CUCK, MIN - 1e18));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CUCK, PER_DEAL + 1e18));
        uint256 first;
        uint256 n = AGGREGATE / PER_DEAL;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, CUCK, PER_DEAL));
            if (i == 0) first = id;
        }
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CUCK, MIN));
        vm.prank(registry.owner());
        registry.setERC20Allowed(CUCK, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, CUCK, MIN));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(CUCK).balanceOf(borrower), DEALT - (n - 1) * PER_DEAL);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(CUCK).allowed);
        assertFalse(memeUsdg.getERC20Config(CUCK).allowed);
        assertFalse(ponsWeth.getERC20Config(CUCK).allowed);
        // HOOD stays a routing hop only.
        assertFalse(registry.getERC20Config(HOOD).allowed);
    }

    function testCuck_twoHopCashoutThroughV3PoolAndHood() public {
        uint256 id = _list(Collateral(Kind.ERC20, CUCK, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        uint256 before = IERC20(USDG).balanceOf(borrower);
        uint256 routerHood = IERC20(HOOD).balanceOf(address(cashout));
        uint256 routerToken = IERC20(CUCK).balanceOf(address(cashout));
        vm.prank(borrower);
        (,,, uint256 net) = cashout.cashOutDetailed(x);
        assertGt(net, 0);
        assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(IERC20(HOOD).balanceOf(address(cashout)), routerHood);
        assertEq(IERC20(CUCK).balanceOf(address(cashout)), routerToken);
    }

    function testCuck_cashoutRequiresBothLegs() public {
        uint256 id = _list(Collateral(Kind.ERC20, CUCK, PER_DEAL));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        GageV2CashoutRouter.Exit memory x = _erc20Exit(id);
        vm.prank(cashout.owner());
        cashout.setV3Route(V3_POOL, false);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        vm.startPrank(cashout.owner());
        cashout.setV3Route(V3_POOL, true);
        cashout.setV4Route(hoodKey, false);
        vm.stopPrank();
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testCuck_existingMemesVaultCanFundAfterAdmissionAndNormalGradePublication() public {
        ICuckEarn earn = ICuckEarn(address(bytes20(hex"c04a365061e5d3cf7f614cf353494294b0e3f0c9")));
        assertEq(earn.REGISTRY(), address(registry));
        assertEq(earn.pickedAssets(), 0);
        uint256 id = _list(Collateral(Kind.ERC20, CUCK, PER_DEAL));
        // Mirror the existing D132 keeper policy: publish TOP_RANK for an admitted token.
        ICuckGrades grades = ICuckGrades(earn.GRADES());
        address[] memory tokens = new address[](1);
        tokens[0] = CUCK;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 10;
        vm.prank(grades.publisher());
        grades.setGrades(tokens, ranks);
        uint256 before = earn.freeLiquidity();
        vm.prank(earn.CURATOR());
        earn.fund(id, 4, type(uint256).max);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(before - earn.freeLiquidity(), 90e6);
        assertEq(IERC20(CUCK).balanceOf(vault.getLoan(id).account), PER_DEAL);
    }

    function testCuck_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(PER_DEAL);
        uint256 out = _sellTwoHop(PER_DEAL);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testCuck_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(AGGREGATE);
        uint256 out = _sellTwoHop(AGGREGATE);
        assertGe(out * 100, spot * 95, "maxOpen exit under 95% of spot");
    }
}
