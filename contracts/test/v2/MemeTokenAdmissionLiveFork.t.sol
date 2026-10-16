// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

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
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

interface IMemeV3Pool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

interface IMemeV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IMemeWeth {
    function withdraw(uint256) external;
}

interface IMemeEarn {
    function CURATOR() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRADES() external view returns (address);
    function pickedAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external;
}

interface IMemeGrades {
    function publisher() external view returns (address);
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external;
}

/// Token-only MEME admission of the batch in scripts/lib/meme-token-admission.mjs on the current V3 engine at a pinned
/// mainnet fork: custody, reclaim, default recovery, limits, remainder, revocation, earlier registries, every cash-out
/// route and each of its enabled legs, Memes Earn funding after the normal grade publication, plain ERC-20 transfers
/// against the pool that holds the token, and the exit bounds at the per-loan and aggregate sizes. Only this token's calls
/// of the prepared Safe batch, test capital and the grade publication change locally. Skips without a fork RPC.
abstract contract MemeTokenAdmissionLiveForkBase is V4Fixture {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant STATE_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 constant ETH_POOL = 0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e;
    uint256 constant PER_LOAN_BOUND = 95;

    /// One hop in the router's own shape plus the v3 pool used for direct probe sales.
    struct Hop {
        GageV2CashoutRouter.RouteKind kind;
        address tokenIn;
        address tokenOut;
        address v3Pool;
        uint24 v3Fee;
        PoolKey key;
    }

    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey ethKey;
    address borrower;
    address lender;
    address swapping;

    receive() external payable {}

    function _token() internal pure virtual returns (address);
    /// Environment variable holding the token's runtime hash from evidence.json.
    function _hashEnv() internal pure virtual returns (string memory);
    function _min() internal pure virtual returns (uint256);
    function _perDeal() internal pure virtual returns (uint256);
    function _aggregate() internal pure virtual returns (uint256);
    /// Percent of pre-trade spot the whole aggregate keeps at least on the published route, the app's cash-out path (D161 and
    /// main D209 record any value below 95).
    function _aggregateBound() internal pure virtual returns (uint256);
    function _routeCount() internal pure virtual returns (uint256);
    /// Route 0 is the published path; every route ends in USDG.
    function _route(uint256 i) internal view virtual returns (Hop[] memory);
    /// Address that holds the token for the published pool (the v3 pool, or the PoolManager for a v4 pool).
    function _custody() internal pure virtual returns (address);

    function setUp() public virtual {
        string memory rpc = vm.envOr("GAGE_MEME_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_MEME_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(_token().codehash, vm.envBytes32(_hashEnv()));
        poolManager = IPoolManager(STATE_POOL_MANAGER);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        assertEq(address(cashout.VAULT()), address(vault));
        assertEq(address(cashout.V3_FACTORY()), V3_FACTORY);
        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        assertEq(_poolId(ethKey), ETH_POOL);
        assertFalse(registry.getERC20Config(_token()).allowed);
        _admit();
        borrower = makeAddr("meme borrower");
        lender = makeAddr("meme lender");
        deal(_token(), borrower, 4 * _aggregate());
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(_token()).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    /// Exactly this token's calls of the prepared Safe batch: its admission and every new hop of its routes. The legs the
    /// routes continue on (ETH / USDG) must already be enabled and are not touched.
    function _admit() internal {
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(_token(), true, Lane.MEME, _min(), _perDeal(), _aggregate());
        for (uint256 r; r < _routeCount(); ++r) {
            Hop[] memory hops = _route(r);
            for (uint256 i; i < hops.length; ++i) {
                if (hops[i].kind == GageV2CashoutRouter.RouteKind.V3) {
                    IMemeV3Pool p = IMemeV3Pool(hops[i].v3Pool);
                    assertEq(p.factory(), V3_FACTORY);
                    assertEq(IMemeV3Factory(V3_FACTORY).getPool(p.token0(), p.token1(), p.fee()), hops[i].v3Pool);
                    assertTrue(hops[i].v3Pool != address(cashout.FLASH_POOL()), "The flash pool cannot be a route");
                    if (!cashout.v3Allowed(hops[i].v3Pool)) cashout.setV3Route(hops[i].v3Pool, true);
                } else if (hops[i].kind == GageV2CashoutRouter.RouteKind.V4) {
                    bytes32 id = _poolId(hops[i].key);
                    if (id == ETH_POOL) {
                        assertTrue(
                            ILegacyCashoutRoutes(address(cashout)).v4Allowed(hops[i].key), "Leg must already be enabled"
                        );
                    } else if (!ILegacyCashoutRoutes(address(cashout)).v4Allowed(hops[i].key)) {
                        cashout.setV4Route(hops[i].key, true);
                    }
                }
            }
        }
        vm.stopPrank();
    }

    /// Pays the v3 pool of this contract's own exact-input sale.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        assertEq(msg.sender, swapping);
        if (amount0Delta > 0) IERC20(IMemeV3Pool(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IMemeV3Pool(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
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

    /// `amount` of hop input valued at the hop's pre-trade spot: tokenOut per tokenIn is sqrt^2 / 2^192 when tokenIn is
    /// currency0 (token0), else its inverse. Unwrapping is 1:1.
    function _spotHop(Hop memory h, uint256 amount) internal view returns (uint256) {
        if (h.kind == GageV2CashoutRouter.RouteKind.UNWRAP_WETH) return amount;
        uint256 sqrtPrice;
        bool zeroForOne;
        if (h.kind == GageV2CashoutRouter.RouteKind.V3) {
            (uint160 s,,,,,,) = IMemeV3Pool(h.v3Pool).slot0();
            sqrtPrice = s;
            zeroForOne = IMemeV3Pool(h.v3Pool).token0() == h.tokenIn;
        } else {
            (uint160 s,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(_poolId(h.key)));
            sqrtPrice = s;
            zeroForOne = Currency.unwrap(h.key.currency0) == h.tokenIn;
        }
        return zeroForOne
            ? FullMath.mulDiv(FullMath.mulDiv(amount, sqrtPrice, 1 << 96), sqrtPrice, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, sqrtPrice), 1 << 96, sqrtPrice);
    }

    /// USDG raw value of `amount` raw tokens at the pre-trade spot of every hop of route `r`, before fees and impact.
    function _spotUSDG(uint256 r, uint256 amount) internal view returns (uint256 value) {
        value = _spotHops(_route(r), amount);
    }

    function _spotHops(Hop[] memory hops, uint256 amount) internal view returns (uint256 value) {
        value = amount;
        for (uint256 i; i < hops.length; ++i) {
            value = _spotHop(hops[i], value);
        }
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// One exact-input hop by this contract; returns the output. Hook charges and LP fees come out of the swap.
    function _swapHop(Hop memory h, uint256 amount) internal returns (uint256 out) {
        if (h.kind == GageV2CashoutRouter.RouteKind.UNWRAP_WETH) {
            IMemeWeth(WETH).withdraw(amount);
            return amount;
        }
        uint256 beforeIn = _balance(h.tokenIn);
        uint256 beforeOut = _balance(h.tokenOut);
        if (h.kind == GageV2CashoutRouter.RouteKind.V3) {
            bool zeroForOne = IMemeV3Pool(h.v3Pool).token0() == h.tokenIn;
            swapping = h.v3Pool;
            IMemeV3Pool(h.v3Pool)
                .swap(
                    address(this),
                    zeroForOne,
                    int256(amount),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                    ""
                );
            swapping = address(0);
        } else {
            bool zeroForOne = Currency.unwrap(h.key.currency0) == h.tokenIn;
            if (h.tokenIn != address(0)) IERC20(h.tokenIn).approve(address(swapRouter), amount);
            swapRouter.swap{value: h.tokenIn == address(0) ? amount : 0}(
                h.key,
                SwapParams(
                    zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }
        assertEq(beforeIn - _balance(h.tokenIn), amount, "Partial fill or input transfer mismatch");
        out = _balance(h.tokenOut) - beforeOut;
        assertGt(out, 0);
    }

    /// Sell `amount` raw tokens along route `r` (every hop in turn); returns USDG received.
    function _sell(uint256 r, uint256 amount) internal returns (uint256 out) {
        out = _sellHops(_route(r), amount);
    }

    /// Sell `amount` raw tokens along an explicit hop list; returns USDG received.
    function _sellHops(Hop[] memory hops, uint256 amount) internal returns (uint256 out) {
        deal(_token(), address(this), amount);
        out = amount;
        for (uint256 i; i < hops.length; ++i) {
            out = _swapHop(hops[i], out);
        }
    }

    function _routerRoutes(uint256 r) internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = _toRouter(_route(r));
    }

    function _toRouter(Hop[] memory hops) internal pure returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](hops.length);
        for (uint256 i; i < hops.length; ++i) {
            routes[i] = GageV2CashoutRouter.Route(
                hops[i].kind, hops[i].tokenIn, hops[i].tokenOut, hops[i].v3Fee, hops[i].key, 1
            );
        }
    }

    function _exit(uint256 id, uint256 r) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x = _exitWith(id, _routerRoutes(r));
    }

    function _exitWith(uint256 id, GageV2CashoutRouter.Route[] memory routes)
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

    function testMeme_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(_token()).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
        _fund(id);
        // Exact custody balance: no transfer fee.
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

    function testMeme_limitsRemainderRevocationAndLegacyRemainClosed() public {
        assertEq(uint256(registry.getERC20Config(_token()).lane), uint256(Lane.MEME));
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
        // Any remainder under the per-loan limit still lists, then the aggregate is full.
        uint256 rest = _aggregate() - n * _perDeal();
        if (rest >= _min()) _list(Collateral(Kind.ERC20, _token(), rest));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, _token(), _min()));
        vm.prank(registry.owner());
        registry.setERC20Allowed(_token(), false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, _token(), _min()));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        uint256 listed = n * _perDeal() + (rest >= _min() ? rest : 0);
        assertEq(IERC20(_token()).balanceOf(borrower), 4 * _aggregate() - listed + _perDeal());
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(_token()).allowed);
        assertFalse(memeUsdg.getERC20Config(_token()).allowed);
        assertFalse(ponsWeth.getERC20Config(_token()).allowed);
    }

    /// The router's balance of every asset route `r` touches (each hop's input and output, native ETH as the router's own
    /// balance), then WETH and USDG.
    function _routerBalances(uint256 r) internal view returns (uint256[] memory out) {
        Hop[] memory hops = _route(r);
        out = new uint256[](2 * hops.length + 2);
        for (uint256 i; i < hops.length; ++i) {
            out[2 * i] = _heldBy(address(cashout), hops[i].tokenIn);
            out[2 * i + 1] = _heldBy(address(cashout), hops[i].tokenOut);
        }
        out[2 * hops.length] = IERC20(WETH).balanceOf(address(cashout));
        out[2 * hops.length + 1] = IERC20(USDG).balanceOf(address(cashout));
    }

    function _heldBy(address holder, address token) internal view returns (uint256) {
        return token == address(0) ? holder.balance : IERC20(token).balanceOf(holder);
    }

    function testMeme_cashoutThroughEachRoute() public {
        for (uint256 r; r < _routeCount(); ++r) {
            uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
            _fund(id);
            vm.prank(borrower);
            vault.approve(address(cashout), id);
            uint256 before = IERC20(USDG).balanceOf(borrower);
            uint256[] memory router = _routerBalances(r);
            vm.prank(borrower);
            (,,, uint256 net) = cashout.cashOutDetailed(_exit(id, r));
            assertGt(net, 0);
            assertEq(IERC20(USDG).balanceOf(borrower) - before, net);
            assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
            // No residue of any asset the route touches (the token, native ETH, WETH, USDG) stays with the router.
            assertEq(_routerBalances(r), router);
        }
    }

    function testMeme_cashoutRequiresEachEnabledLeg() public {
        uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        address owner = cashout.owner();
        for (uint256 r; r < _routeCount(); ++r) {
            Hop[] memory hops = _route(r);
            for (uint256 i; i < hops.length; ++i) {
                if (hops[i].kind == GageV2CashoutRouter.RouteKind.UNWRAP_WETH) continue;
                vm.prank(owner);
                if (hops[i].kind == GageV2CashoutRouter.RouteKind.V3) cashout.setV3Route(hops[i].v3Pool, false);
                else cashout.setV4Route(hops[i].key, false);
                GageV2CashoutRouter.Exit memory x = _exit(id, r);
                vm.prank(borrower);
                // The deployed router's error; the current source reverts InvalidExit instead.
                vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
                cashout.cashOutDetailed(x);
                vm.prank(owner);
                if (hops[i].kind == GageV2CashoutRouter.RouteKind.V3) cashout.setV3Route(hops[i].v3Pool, true);
                else cashout.setV4Route(hops[i].key, true);
            }
        }
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        _repay(id);
    }

    function testMeme_existingMemesVaultCanFundAfterAdmissionAndNormalGradePublication() public {
        IMemeEarn earn = IMemeEarn(address(bytes20(hex"c04a365061e5d3cf7f614cf353494294b0e3f0c9")));
        assertEq(earn.REGISTRY(), address(registry));
        assertEq(earn.pickedAssets(), 0);
        uint256 id = _list(Collateral(Kind.ERC20, _token(), _perDeal()));
        // Mirror the existing D132 keeper policy: publish TOP_RANK for an admitted token.
        IMemeGrades grades = IMemeGrades(earn.GRADES());
        address[] memory tokens = new address[](1);
        tokens[0] = _token();
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 10;
        vm.prank(grades.publisher());
        grades.setGrades(tokens, ranks);
        uint256 before = earn.freeLiquidity();
        vm.prank(earn.CURATOR());
        earn.fund(id, 4, type(uint256).max);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(before - earn.freeLiquidity(), 90e6);
        assertEq(IERC20(_token()).balanceOf(vault.getLoan(id).account), _perDeal());
    }

    /// Transfers out of and into the account that holds the published pool's tokens move exact amounts, above any launch
    /// limit the token ever had: no fee, no hook, no window.
    function testMeme_poolTransfersArePlainErc20() public {
        address custody = _custody();
        address fresh = makeAddr("meme fresh wallet");
        uint256 amount = IERC20(_token()).balanceOf(custody) / 2;
        assertGt(amount, 0);
        uint256 custodyBefore = IERC20(_token()).balanceOf(custody);
        vm.prank(custody);
        IERC20(_token()).transfer(fresh, amount);
        assertEq(IERC20(_token()).balanceOf(fresh), amount);
        assertEq(custodyBefore - IERC20(_token()).balanceOf(custody), amount);
        vm.prank(fresh);
        IERC20(_token()).transfer(custody, amount);
        assertEq(IERC20(_token()).balanceOf(fresh), 0);
        assertEq(IERC20(_token()).balanceOf(custody), custodyBefore);
    }

    /// The published route (route 0: the pricing row and the app's cash-out path) at the per-loan size.
    function testMeme_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(0, _perDeal());
        uint256 out = _sell(0, _perDeal());
        assertGe(out * 100, spot * PER_LOAN_BOUND, "maxDeal exit under 95% of spot");
    }

    /// The published route at the aggregate size.
    function testMeme_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(0, _aggregate());
        uint256 out = _sell(0, _aggregate());
        assertGe(out * 100, spot * _aggregateBound(), "maxOpen exit under the recorded bound");
    }
}

interface IMemePonsV2Hook {
    function owner() external view returns (address);
    function hookFeeBps() external view returns (uint256);
    function setHookFeeBps(uint256 bps) external;
    function launches(bytes32 poolId)
        external
        view
        returns (bool, bool, address, address, address, address, address, uint16, uint16, uint16, uint16, uint16, bool);
}

interface IMemeLaunchLocker {
    function owner() external view returns (address);
    function factory() external view returns (address);
    function positionManager() external view returns (address);
    function isLocked(address token) external view returns (bool);
    function lockedPositions(address token) external view returns (uint256);
    function lockedTokenSupply(address token) external view returns (uint256);
    function setFactory(address factory_) external;
    function lockPosition(address token, uint256 tokenId) external;
    function renounceOwnership() external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IMemePositionNft {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// PRIORS (Priors Agents), a Pons V2 launcher token (the CME/ORBIO/ROUTE/NOSH token type): published route the hook-free 1%
/// USDG / PRIORS v4 pool, one hop straight to USDG (D214, as main D209 chose for NOSH); second route the USDG / PRIORS v4 launch
/// pool behind the reviewed PonsV2MemeHook (LP fee 0; hook fee plus creator tax taken from each swap output), also one hop,
/// whose only in-range position is the full-range launch NFT in the RobinFunFiV2LaunchLocker.
contract PriorsAdmissionLiveForkTest is MemeTokenAdmissionLiveForkBase {
    using PositionInfoLibrary for PositionInfo;

    address constant PRIORS = 0xeDBf91223639800BCd5756815CAf908Df3b890bE;
    address constant PONS_V2_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant LAUNCH_LOCKER = 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952;
    bytes32 constant PRIORS_LAUNCH = 0xff7b3bd2db34d9ed8160e6dedf1d448777abaa1fa6fc8a31144930a1a656fd92;
    bytes32 constant PRIORS_USDG_1 = 0x9be7ab27227e115085b0949a819a73f6963ddc6da0c6204d37757c24297706e8;
    uint256 constant LAUNCH_NFT = 2_974_146;

    function setUp() public virtual override {
        super.setUp();
        if (address(vault) == address(0)) return;
        assertEq(PONS_V2_HOOK.codehash, 0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db);
        assertEq(_poolId(_launchKey()), PRIORS_LAUNCH);
        assertEq(_poolId(_usdgKey()), PRIORS_USDG_1);
    }

    function _token() internal pure override returns (address) {
        return PRIORS;
    }

    function _hashEnv() internal pure override returns (string memory) {
        return "GAGE_MEME_HASH_PRIORS";
    }

    function _min() internal pure override returns (uint256) {
        return 13_000e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 140_000e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 700_000e18;
    }

    /// main D209's recorded exception, kept by D214: the published pool is hook-free, where D200 asserted 95%, but its 1% LP fee
    /// and depth keep about 94.5% at the aggregate; 92% is the bound D200 set for a hooked route (ROUTE).
    function _aggregateBound() internal pure override returns (uint256) {
        return 92;
    }

    function _launchKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(PRIORS), 0, 200, IHooks(PONS_V2_HOOK));
    }

    function _usdgKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(USDG), Currency.wrap(PRIORS), 10_000, 100, IHooks(address(0)));
    }

    function _routeCount() internal pure override returns (uint256) {
        return 2;
    }

    function _route(uint256 r) internal pure override returns (Hop[] memory h) {
        h = new Hop[](1);
        h[0] = r == 0
            ? Hop(GageV2CashoutRouter.RouteKind.V4, PRIORS, USDG, address(0), 0, _usdgKey())
            : Hop(GageV2CashoutRouter.RouteKind.V4, PRIORS, USDG, address(0), 0, _launchKey());
    }

    function _custody() internal pure override returns (address) {
        return STATE_POOL_MANAGER;
    }

    /// The launch pool's charge (route 1, the backup exit) is the rate registered for it (hook fee 1% + creator tax 2%).
    /// The hook owner's setHookFeeBps changes only future launches: raised to its 10% maximum, this pool's record and a
    /// sale's output are unchanged.
    function testPriors_registeredSwapChargeIsSnapshotted() public {
        IMemePonsV2Hook hook = IMemePonsV2Hook(PONS_V2_HOOK);
        (bool registered,, address memecoin,,,,, uint16 creatorTaxBps,,, uint16 hookFeeBps,, bool buyback) =
            hook.launches(PRIORS_LAUNCH);
        assertTrue(registered);
        assertEq(memecoin, PRIORS);
        assertEq(hookFeeBps, 100);
        assertEq(creatorTaxBps, 200);
        assertFalse(buyback);
        uint256 snapshot = vm.snapshotState();
        uint256 baseline = _sell(1, _perDeal());
        vm.revertToState(snapshot);
        vm.prank(hook.owner());
        hook.setHookFeeBps(1000);
        assertEq(hook.hookFeeBps(), 1000);
        (,,,,,,, uint16 taxAfter,,, uint16 feeAfter,,) = hook.launches(PRIORS_LAUNCH);
        assertEq(feeAfter, 100);
        assertEq(taxAfter, 200);
        assertEq(_sell(1, _perDeal()), baseline);
    }

    /// The full-range launch NFT stays with the launch locker whatever the locker's owner or factory does: the factory wiring
    /// is one-time, renouncing is disabled, relocking reverts, the PositionManager refuses both a transfer and a liquidity
    /// decrease by either of them, and a new owner (two-step transfer) has nothing more. The position, its liquidity and the
    /// locked token remainder are unchanged.
    function testPriors_launchLockerHasNoWithdrawalPath() public {
        IMemeLaunchLocker locker = IMemeLaunchLocker(LAUNCH_LOCKER);
        IMemePositionNft nft = IMemePositionNft(address(posm));
        assertEq(locker.positionManager(), address(posm));
        assertTrue(locker.isLocked(PRIORS));
        assertEq(locker.lockedPositions(PRIORS), LAUNCH_NFT);
        assertEq(nft.ownerOf(LAUNCH_NFT), LAUNCH_LOCKER);
        assertEq(nft.getApproved(LAUNCH_NFT), address(0));
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(LAUNCH_NFT);
        assertEq(_poolId(key), PRIORS_LAUNCH);
        assertEq(info.tickLower(), TickMath.minUsableTick(200));
        assertEq(info.tickUpper(), TickMath.maxUsableTick(200));
        uint128 liquidity = posm.getPositionLiquidity(LAUNCH_NFT);
        assertGt(liquidity, 0);
        uint256 held = IERC20(PRIORS).balanceOf(LAUNCH_LOCKER);
        assertGe(held, locker.lockedTokenSupply(PRIORS));
        address owner = locker.owner();
        address factory = locker.factory();
        assertFalse(nft.isApprovedForAll(LAUNCH_LOCKER, owner));
        assertFalse(nft.isApprovedForAll(LAUNCH_LOCKER, factory));
        vm.startPrank(owner);
        vm.expectRevert();
        locker.setFactory(owner);
        vm.expectRevert();
        locker.renounceOwnership();
        vm.expectRevert();
        nft.transferFrom(LAUNCH_LOCKER, owner, LAUNCH_NFT);
        vm.stopPrank();
        vm.expectRevert();
        _decrease(key, LAUNCH_NFT, liquidity, owner, owner);
        vm.startPrank(factory);
        vm.expectRevert();
        locker.lockPosition(PRIORS, LAUNCH_NFT);
        vm.expectRevert();
        nft.transferFrom(LAUNCH_LOCKER, factory, LAUNCH_NFT);
        vm.stopPrank();
        vm.expectRevert();
        _decrease(key, LAUNCH_NFT, liquidity, factory, factory);
        address next = makeAddr("locker next owner");
        vm.prank(owner);
        locker.transferOwnership(next);
        vm.prank(next);
        locker.acceptOwnership();
        vm.prank(next);
        vm.expectRevert();
        locker.setFactory(next);
        vm.expectRevert();
        _decrease(key, LAUNCH_NFT, liquidity, next, next);
        assertEq(nft.ownerOf(LAUNCH_NFT), LAUNCH_LOCKER);
        assertEq(posm.getPositionLiquidity(LAUNCH_NFT), liquidity);
        assertEq(locker.lockedPositions(PRIORS), LAUNCH_NFT);
        assertEq(IERC20(PRIORS).balanceOf(LAUNCH_LOCKER), held);
    }
}
