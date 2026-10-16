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
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// LayerZero V2 `Origin` of an inbound OFT message.
struct ImdOrigin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

/// The owner controls of the unverified IMD OFT on Robinhood Chain, named by their selectors (docs/launch-evidence/
/// imd-2026-09-25/controls.json); the LayerZero OApp surface is the standard one.
interface IImdToken {
    function owner() external view returns (address);
    function endpoint() external view returns (address);
    function transfersEnabled() external view returns (bool);
    function blocked(address account) external view returns (bool);
    function setBlocked(address account, bool isBlocked) external;
    function poolManager() external view returns (address);
    function v4Gate() external view returns (address);
    function v4Gated() external view returns (bool);
    function setV4Config(address manager, address gate, bool gated) external;
    function setPeer(uint32 eid, bytes32 peer) external;
    function lzReceive(
        ImdOrigin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

interface IImdV3Pool {
    function token0() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256, int256);
}

interface IImdWeth {
    function withdraw(uint256) external;
}

interface IImdEarn {
    function CURATOR() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRADES() external view returns (address);
    function pickedAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external;
}

interface IImdGrades {
    function publisher() external view returns (address);
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external;
}

/// Fork, identities and exit helpers for IMD at a pinned mainnet block. IMD's exits are two hookless Uniswap v4 pools:
/// IMD/ETH (native ETH, 1%) followed by the enabled ETH/USDG pool, and a direct IMD/USDG pool (0.9%). The thin canonical
/// v3 IMD/WETH pool (0.3%) is probed but is not a route. Skips without a fork RPC.
abstract contract ImdForkBase is V4Fixture {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant IMD_OWNER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address constant LZ_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant ETH_POOL = 0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e;
    /// Uniswap v4 native ETH / IMD, 1% fee, tick spacing 100, no hooks: the primary exit.
    bytes32 constant IMD_ETH_POOL = 0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02;
    /// Uniswap v4 IMD / USDG, 0.9% fee, tick spacing 90, no hooks: the second, shallower direct exit.
    bytes32 constant IMD_USDG_POOL = 0xaf5bcd88bb2b6084ca18319385b61fcbe17ec579032074861004f2668168406f;
    /// Canonical Uniswap v3 WETH / IMD, 0.3%: a few thousand dollars deep, evaluated and left out.
    address constant IMD_WETH_V3 = 0xfF0c11690648048C6E939C0A049B3Fbd21141575;
    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey ethKey;
    PoolKey imdEthKey;
    PoolKey imdUsdgKey;

    receive() external payable {}

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("GAGE_IMD_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_IMD_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(IMD.codehash, vm.envBytes32("GAGE_IMD_TOKEN_HASH"));
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        assertEq(address(cashout.VAULT()), address(vault));
        assertEq(address(cashout.POOL_MANAGER()), address(poolManager));
        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        imdEthKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 100, IHooks(address(0)));
        imdUsdgKey = PoolKey(Currency.wrap(IMD), Currency.wrap(USDG), 9000, 90, IHooks(address(0)));
        assertEq(_poolId(ethKey), ETH_POOL);
        assertEq(_poolId(imdEthKey), IMD_ETH_POOL);
        assertEq(_poolId(imdUsdgKey), IMD_USDG_POOL);
        // The owner's switches are off at the anchor: transfers open, no block on the manager, the v4 gate dormant.
        IImdToken t = IImdToken(IMD);
        assertEq(t.owner(), IMD_OWNER);
        assertEq(t.endpoint(), LZ_ENDPOINT);
        assertTrue(t.transfersEnabled());
        assertFalse(t.v4Gated());
        assertFalse(t.blocked(address(poolManager)));
        return true;
    }

    /// Pays the v3 pool for this contract's own exact-input sales of IMD.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == IMD_WETH_V3, "Unexpected pool");
        IERC20(IMD).transfer(msg.sender, uint256(amount0Delta > 0 ? amount0Delta : amount1Delta));
    }

    function _sqrt(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
    }

    /// USDG raw value of `amount` raw IMD at the IMD/ETH and ETH/USDG spot, before fees and impact. Native ETH is
    /// currency0 of both pools: ETH per IMD is 2^192 / sqrtImd^2 and USDG per ETH is sqrtEth^2 / 2^192.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        uint256 sqrtImd = _sqrt(IMD_ETH_POOL);
        uint256 sqrtEth = _sqrt(ETH_POOL);
        uint256 eth = FullMath.mulDiv(amount, 1 << 192, sqrtImd * sqrtImd);
        return FullMath.mulDiv(eth, sqrtEth * sqrtEth, 1 << 192);
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// Exact-input v4 sale by this contract through the test router. Returns the input actually consumed (a pool
    /// that runs out of liquidity before the price limit fills partially) and the output received.
    function _swapV4(PoolKey memory k, address tokenIn, uint256 amount) internal returns (uint256 used, uint256 out) {
        bool zeroForOne = tokenIn == Currency.unwrap(k.currency0);
        address output = Currency.unwrap(zeroForOne ? k.currency1 : k.currency0);
        uint256 beforeIn = _balance(tokenIn);
        uint256 beforeOut = _balance(output);
        if (tokenIn != address(0)) IERC20(tokenIn).approve(address(swapRouter), amount);
        swapRouter.swap{value: tokenIn == address(0) ? amount : 0}(
            k,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        used = beforeIn - _balance(tokenIn);
        out = _balance(output) - beforeOut;
    }

    /// Primary exit: IMD to native ETH on IMD/ETH, then ETH to USDG. The IMD leg must fill completely.
    function _sellViaEth(uint256 amount) internal returns (uint256 usdgOut) {
        deal(IMD, address(this), amount);
        (uint256 used, uint256 eth) = _swapV4(imdEthKey, IMD, amount);
        assertEq(used, amount, "Partial IMD/ETH fill");
        assertGt(eth, 0);
        uint256 spent;
        (spent, usdgOut) = _swapV4(ethKey, address(0), eth);
        assertEq(spent, eth, "Partial ETH/USDG fill");
    }

    /// Second exit: IMD to USDG on the direct v4 pool. Returns the IMD left unsold when the pool runs out.
    function _trySellDirect(uint256 amount) internal returns (uint256 usdgOut, uint256 unsold) {
        deal(IMD, address(this), amount);
        uint256 used;
        (used, usdgOut) = _swapV4(imdUsdgKey, IMD, amount);
        unsold = amount - used;
    }

    /// The thin v3 pool: IMD to WETH (IMD is token1), unwrap, then ETH to USDG. Returns the IMD left unsold.
    function _trySellViaV3Weth(uint256 amount) internal returns (uint256 usdgOut, uint256 unsold) {
        deal(IMD, address(this), amount);
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        IImdV3Pool(IMD_WETH_V3).swap(address(this), false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, "");
        unsold = IERC20(IMD).balanceOf(address(this));
        uint256 wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        if (wethOut == 0) return (0, unsold);
        IImdWeth(WETH).withdraw(wethOut);
        (, usdgOut) = _swapV4(ethKey, address(0), wethOut);
    }
}

/// Token-only IMD admission on the current V3 engine at a pinned mainnet fork. IMD is admitted with NO cash-out route
/// (D171): the Safe batch is `setERC20Allowed` only, so `GageV2CashoutRouter` reverts for an IMD loan and borrowers
/// repay in USDG to reclaim. This suite proves custody/reclaim/default deltas, the limits, that cash-out reverts while
/// normal close works, Memes Earn funding, and the owner powers a lender would meet (a blocklist that freezes a loan
/// account, the dormant v4 transfer gate, and a peer/DVN-controlled unbacked mint). Only `setERC20Allowed`, the owner's
/// own switches, test capital and the normal grade publication change locally. Limits come from the environment
/// (scripts/imd-fork.mjs reads them from the admission's limits file).
contract ImdAdmissionLiveForkTest is ImdForkBase {
    uint256 min;
    uint256 perDeal;
    uint256 aggregate;
    uint256 dealt;
    address borrower;
    address lender;

    function setUp() public {
        if (!_fork()) return;
        min = vm.envUint("GAGE_IMD_MIN");
        perDeal = vm.envUint("GAGE_IMD_PER_DEAL");
        aggregate = vm.envUint("GAGE_IMD_AGGREGATE");
        assertTrue(min > 0 && min <= perDeal && perDeal <= aggregate);
        dealt = aggregate * 4;
        assertFalse(registry.getERC20Config(IMD).allowed);
        // The prepared Safe batch is exactly one call: admit IMD as MEME collateral. No cash-out route is enabled.
        vm.prank(registry.owner());
        registry.setERC20Allowed(IMD, true, Lane.MEME, min, perDeal, aggregate);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(imdEthKey));
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(imdUsdgKey));
        assertFalse(cashout.v3Allowed(IMD_WETH_V3));
        borrower = makeAddr("IMD borrower");
        lender = makeAddr("IMD lender");
        deal(IMD, borrower, dealt);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(IMD).approve(address(vault), type(uint256).max);
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

    /// The routes a borrower might try even though none is enabled: IMD/ETH then ETH/USDG, or direct IMD/USDG.
    function _ethRoutes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, IMD, address(0), 0, imdEthKey, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, address(0), USDG, 0, ethKey, 1);
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

    function testImd_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(IMD).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        // Exact custody balance: IMD has no transfer fee.
        assertEq(IERC20(IMD).balanceOf(vault.getLoan(id).account), perDeal);
        _repay(id);
        assertEq(IERC20(IMD).balanceOf(borrower), before);
        id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(IMD).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(IMD).balanceOf(lender) - lenderBefore, perDeal);
    }

    function testImd_limitsRevocationAndLegacyRemainClosed() public {
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, IMD, min - 1));
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, IMD, perDeal + 1));
        uint256 first;
        uint256 n = aggregate / perDeal;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
            if (i == 0) first = id;
        }
        // A remainder at or above the minimum still lists; then the aggregate has no room for a minimum listing.
        uint256 rest = aggregate - n * perDeal;
        if (rest >= min) _list(Collateral(Kind.ERC20, IMD, rest));
        else rest = 0;
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, IMD, min));
        vm.prank(registry.owner());
        registry.setERC20Allowed(IMD, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(Collateral(Kind.ERC20, IMD, min));
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(borrower), dealt - (n - 1) * perDeal - rest);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(IMD).allowed);
        assertFalse(memeUsdg.getERC20Config(IMD).allowed);
        assertFalse(ponsWeth.getERC20Config(IMD).allowed);
    }

    /// D171: no cash-out route is enabled for IMD, so a cash-out reverts RouteNotAllowed and never touches the loan;
    /// the borrower still repays in USDG and reclaims, and a defaulted loan still recovers to the lender.
    function testImd_noCashoutRouteRevertsAndNormalCloseWorks() public {
        uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        vm.prank(borrower);
        // The deployed router's error; the current source reverts InvalidExit instead.
        vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
        cashout.cashOutDetailed(_exit(id, _ethRoutes()));
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        // Repay-in-USDG close still works after the failed cash-out attempt.
        uint256 before = IERC20(IMD).balanceOf(borrower);
        _repay(id);
        assertEq(IERC20(IMD).balanceOf(borrower) - before, perDeal);
        // The default -> recover -> claim path also works, without any cash-out.
        id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        _default(id);
        uint256 lenderBefore = IERC20(IMD).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(IMD).balanceOf(lender) - lenderBefore, perDeal);
    }

    function testImd_existingMemesVaultCanFundAfterAdmissionAndNormalGradePublication() public {
        IImdEarn earn = IImdEarn(address(bytes20(hex"c04a365061e5d3cf7f614cf353494294b0e3f0c9")));
        assertEq(earn.REGISTRY(), address(registry));
        assertEq(earn.pickedAssets(), 0);
        uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        // Mirror the existing D132 keeper policy: publish TOP_RANK for an admitted token.
        IImdGrades grades = IImdGrades(earn.GRADES());
        address[] memory tokens = new address[](1);
        tokens[0] = IMD;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 10;
        vm.prank(grades.publisher());
        grades.setGrades(tokens, ranks);
        uint256 before = earn.freeLiquidity();
        vm.prank(earn.CURATOR());
        earn.fund(id, 4, type(uint256).max);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(before - earn.freeLiquidity(), 90e6);
        assertEq(IERC20(IMD).balanceOf(vault.getLoan(id).account), perDeal);
    }

    /// Finding shown to lenders: the owner can block a loan's collateral account. Repayment still records, but neither
    /// the borrower's withdrawal nor, after a default, the lender's recovery can move the IMD until the owner unblocks.
    function testImd_ownerBlockFreezesLoanCustodyUntilLifted() public {
        IImdToken t = IImdToken(IMD);
        uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        address account = vault.getLoan(id).account;
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        t.setBlocked(account, true);
        vm.prank(IMD_OWNER);
        t.setBlocked(account, true);
        assertTrue(t.blocked(account));
        vm.startPrank(borrower);
        vault.reclaim(id, borrower);
        // The IMD transfer out of the blocked account reverts; the reason is the token's own (unnamed) block revert.
        vm.expectRevert();
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(account), perDeal);
        vm.prank(IMD_OWNER);
        t.setBlocked(account, false);
        vm.prank(borrower);
        vault.withdrawCollateral(id, borrower);
        assertEq(IERC20(IMD).balanceOf(account), 0);

        id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        account = vault.getLoan(id).account;
        vm.prank(IMD_OWNER);
        t.setBlocked(account, true);
        _default(id);
        vm.prank(lender);
        vm.expectRevert();
        vault.withdrawRecovery(id, 0, lender);
        vm.prank(IMD_OWNER);
        t.setBlocked(account, false);
        uint256 lenderBefore = IERC20(IMD).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        assertEq(IERC20(IMD).balanceOf(lender) - lenderBefore, perDeal);
    }

    /// Finding shown to lenders: blocking the v4 PoolManager stops every IMD sale on v4 (how a lender would sell after a
    /// default); the loan's own repay/reclaim still works because it never routes through v4.
    function testImd_poolManagerBlockStopsV4SalesNotRepayment() public {
        uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        vm.prank(IMD_OWNER);
        IImdToken(IMD).setBlocked(address(poolManager), true);
        deal(IMD, address(this), perDeal);
        IERC20(IMD).approve(address(swapRouter), perDeal);
        vm.expectRevert();
        swapRouter.swap(
            imdEthKey,
            SwapParams(false, -int256(perDeal), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        uint256 before = IERC20(IMD).balanceOf(borrower);
        _repay(id);
        assertEq(IERC20(IMD).balanceOf(borrower) - before, perDeal);
    }

    /// Finding shown to lenders: the dormant v4 gate, once the owner switches it on, makes every IMD transfer into or out
    /// of the PoolManager depend on the gate's approval. A v4 sale reverts; wallet transfers and repayment do not.
    function testImd_v4GateStopsV4SalesNotRepayment() public {
        IImdToken t = IImdToken(IMD);
        address gate = makeAddr("IMD v4 gate");
        uint256 id = _list(Collateral(Kind.ERC20, IMD, perDeal));
        _fund(id);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        t.setV4Config(address(poolManager), gate, true);
        vm.prank(IMD_OWNER);
        t.setV4Config(address(poolManager), gate, true);
        assertEq(t.poolManager(), address(poolManager));
        assertEq(t.v4Gate(), gate);
        assertTrue(t.v4Gated());
        deal(IMD, address(this), perDeal);
        IERC20(IMD).approve(address(swapRouter), perDeal);
        vm.expectRevert();
        swapRouter.swap(
            imdEthKey,
            SwapParams(false, -int256(perDeal), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 before = IERC20(IMD).balanceOf(borrower);
        _repay(id);
        assertEq(IERC20(IMD).balanceOf(borrower) - before, perDeal);
        vm.prank(borrower);
        IERC20(IMD).transfer(lender, min);
        assertEq(IERC20(IMD).balanceOf(lender), min);
    }

    /// Finding shown to lenders: the owner sets the OFT's peers (and, as the endpoint delegate, its verifiers), so a
    /// message from a peer of its choosing mints IMD on Robinhood Chain with nothing locked behind it.
    function testImd_ownerPeerMintsUnbackedSupply() public {
        IImdToken t = IImdToken(IMD);
        uint32 eid = 30_999;
        bytes32 peer = bytes32(uint256(uint160(makeAddr("owner-chosen peer"))));
        address receiver = makeAddr("IMD mint receiver");
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        t.setPeer(eid, peer);
        vm.prank(IMD_OWNER);
        t.setPeer(eid, peer);
        uint256 supply = IERC20(IMD).totalSupply();
        uint64 amountSD = 1_000_000e6; // one million IMD in the OFT's six shared decimals
        vm.prank(LZ_ENDPOINT);
        t.lzReceive(
            ImdOrigin(eid, peer, 1),
            keccak256("gage IMD admission review"),
            abi.encodePacked(bytes32(uint256(uint160(receiver))), amountSD),
            address(this),
            ""
        );
        assertEq(IERC20(IMD).balanceOf(receiver), 1_000_000e18);
        assertEq(IERC20(IMD).totalSupply() - supply, 1_000_000e18);
    }
}
