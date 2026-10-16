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

/// The named surface of the unverified TIBBIR token on Robinhood Chain (decompiled; docs/launch-evidence/tibbir-2026-09-29/
/// controls.json). Its other owner controls have no public name and are called by selector below.
interface ITibbirToken {
    function owner() external view returns (address);
    function hook() external view returns (address);
    function setHook(address newHook) external;
    function transfersEnabled() external view returns (bool);
    function quoteFee(address from, address to, uint256 amount) external view returns (uint256);
    function feeRecipient() external view returns (address);
    function buyFeeBasisPoints() external view returns (uint256);
    function sellFeeBasisPoints() external view returns (uint256);
    function maxFeeBasisPoints() external view returns (uint256);
    function setTransferAllowed(address account, bool allowed) external;
}

/// The team hook of the ETH/TIBBIR v4 pool (decompiled). It charges its sell fee on the ETH output and lets the next
/// transfer of the swapped TIBBIR into the PoolManager settle free of the token's own transfer fee.
interface ITibbirHook {
    function owner() external view returns (address);
    function tradingEnabled() external view returns (bool);
    function poolInitialized() external view returns (bool);
    function canonicalPoolId() external view returns (bytes32);
    function coreCurrency() external view returns (address);
    function pairCurrency() external view returns (address);
    function feeRecipient() external view returns (address);
    function buyFeeBasisPoints() external view returns (uint256);
    function sellFeeBasisPoints() external view returns (uint256);
}

/// The Robinhood Chain escrow of the one-way Base-to-Robinhood CCIP bridge (decompiled, names matched by selector).
interface ITibbirEscrow {
    function owner() external view returns (address);
    function token() external view returns (address);
    function origin() external view returns (address);
    function originChainSelector() external view returns (uint64);
    function getRouter() external view returns (address);
    function configurationLocked() external view returns (bool);
    function escrowClosed() external view returns (bool);
    function escrowClosedAt() external view returns (uint256);
    function sweepDelay() external view returns (uint256);
    function MIN_SWEEP_DELAY() external view returns (uint256);
    function closeEscrow() external;
    function sweepSurplus(address to) external;
    function setOrigin(address origin) external;
}

interface ITibbirEarn {
    function CURATOR() external view returns (address);
    function REGISTRY() external view returns (address);
    function GRADES() external view returns (address);
    function pickedAssets() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function fund(uint256 id, uint8 units, uint256 maxReserveShares) external;
}

interface ITibbirGrades {
    function publisher() external view returns (address);
    function setGrades(address[] calldata tokens, uint8[] calldata ranks) external;
}

/// Any contract other than the hook: what `setHook` points at in the freeze test.
contract TibbirNotTheHook {}

/// A Uniswap v2/v3-style contract as the token's pool detector sees it: `token0()` names TIBBIR.
contract TibbirPoolLike {
    address immutable TOKEN;

    constructor(address token) {
        TOKEN = token;
    }

    function token0() external view returns (address) {
        return TOKEN;
    }

    function token1() external pure returns (address) {
        return address(0x1234);
    }
}

/// Fork, identities and exit helpers for TIBBIR at a pinned mainnet block. TIBBIR's only venue is the team-hooked v4
/// ETH/TIBBIR pool (0.3% LP fee, spacing 60); the exit continues on the enabled native ETH/USDG pool. Skips without a
/// fork RPC.
abstract contract TibbirForkBase is V4Fixture {
    address constant TIBBIR = 0x4db7374E966097be94C6680d49156D580F097Bbf;
    address constant HOOK = 0x88e5d1cf9907acD48E7C81ff6eBC088aD358a5cc;
    address constant ESCROW = 0x0a87548fF15d4573cff53e2Ba427C093e0753C5d;
    /// Owner of the token, the hook and the escrow: the team's Splits vault (2-of-3 passkeys).
    address constant TEAM_VAULT = 0x2791F53D6EC377Ad625fd60B6a64061311c7dCf0;
    /// Fee recipient of the token and the hook: the team's 70/30 Split.
    address constant FEE_SPLIT = 0x85A4B39E88228AFc40892092da3c6dbBC1dAa96F;
    address constant BASE_BRIDGE = 0x671be08d6d3c826C2F6d76915f1B54af484D4077;
    address constant CCIP_ROUTER = 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9;
    uint64 constant BASE_SELECTOR = 15_971_525_489_660_198_786;
    /// The gage owner Safe of the registry and the cash-out router.
    address constant SAFE = 0x30e8E13E62DFcd063AF763aB29501FeE74C4918e;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant STATE_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 constant TIBBIR_POOL = 0xbf7dc545ff6d3b0e23f6264f7c23d4fa16a0f3bb1b26eda350593bd63a94da97;
    bytes32 constant ETH_POOL = 0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e;
    /// Hookless v4 WETH/TIBBIR (20% fee) and TIBBIR/USDG (40% fee) pools, initialized after the hooked one; no liquidity.
    bytes32 constant WETH_TIBBIR_POOL = 0x53d1f79c913833f973c0d99111c92a1c13941ff8fb45ed5d5d458432a1dfb036;
    bytes32 constant TIBBIR_USDG_POOL = 0x9016098a20ed5e7669556dd3f5826b7a119784e50dc4176afb3f65a6a9296284;
    /// Unnamed owner controls, by selector (controls.json).
    bytes4 constant SCHEDULE_FEES = 0x40be0bcd; // (uint16 buyBps, uint16 sellBps): token and hook, applied after one day
    bytes4 constant APPLY_FEES = 0x75b80444;
    bytes4 constant FEE_ETA = 0x824f363a;
    bytes4 constant POOL_FEE_FLAG = 0xcaf3d78d; // token: fee on transfers out of v2/v3-style pools, on at the anchor
    bytes4 constant POOL_FEE_OFF = 0x761fa0be;
    bytes4 constant POOL_FEE_SCHEDULE_ON = 0x7cb9d2da;
    bytes4 constant POOL_FEE_ON = 0x9e49ab56;
    bytes4 constant IS_POOL_LIKE = 0x1b03e9a3;
    bytes4 constant POOL_DETECTION_EXEMPT = 0x6c6641d8; // (address, bool)
    bytes4 constant HOOK_PRE_INIT_CONFIG = 0x55c75e8f; // (address, uint16): only before the pool is initialized
    bytes4 constant HOOK_CLEAR_PRE_INIT = 0x7a0bdd5e;
    bytes4 constant POOL_ALREADY_INITIALIZED = 0x7983c051;

    GageV2Vault vault;
    GageV2Registry registry;
    GageV2CashoutRouter cashout;
    PoolKey tibbirKey;
    PoolKey ethKey;

    receive() external payable {}

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("GAGE_TIBBIR_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_TIBBIR_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        // The reviewed (decompiled) runtimes of evidence.json.
        assertEq(TIBBIR.codehash, vm.envBytes32("GAGE_TIBBIR_TOKEN_HASH"));
        assertEq(HOOK.codehash, vm.envBytes32("GAGE_TIBBIR_HOOK_HASH"));
        assertEq(ESCROW.codehash, vm.envBytes32("GAGE_TIBBIR_ESCROW_HASH"));
        poolManager = IPoolManager(STATE_POOL_MANAGER);
        posm = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        permit2 = IAllowanceTransfer(PERMIT2);
        swapRouter = new PoolSwapTest(poolManager);
        vault = GageV2Vault(address(bytes20(hex"fee799ade96229c2c128bc5ed9e55f8d9d01a7e9")));
        registry = GageV2Registry(address(vault.REGISTRY()));
        assertEq(address(registry), address(bytes20(hex"17cfddae7247042a857326c2bb2abe43343e5d33")));
        cashout = GageV2CashoutRouter(payable(address(bytes20(hex"895285fdbbec09eada41fc3784117d5177427acc"))));
        assertEq(address(cashout.VAULT()), address(vault));
        assertEq(address(cashout.POOL_MANAGER()), address(poolManager));
        tibbirKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(TIBBIR), 3000, 60, IHooks(HOOK));
        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        assertEq(_poolId(tibbirKey), TIBBIR_POOL);
        assertEq(_poolId(ethKey), ETH_POOL);
        // The state the review describes: the reviewed hook, transfers and trading on, the team vault owning all three.
        ITibbirToken t = ITibbirToken(TIBBIR);
        assertEq(t.hook(), HOOK);
        assertEq(t.owner(), TEAM_VAULT);
        assertTrue(t.transfersEnabled());
        assertEq(t.feeRecipient(), FEE_SPLIT);
        ITibbirHook h = ITibbirHook(HOOK);
        assertEq(h.owner(), TEAM_VAULT);
        assertTrue(h.tradingEnabled());
        assertTrue(h.poolInitialized());
        assertEq(h.canonicalPoolId(), TIBBIR_POOL);
        assertEq(h.coreCurrency(), TIBBIR);
        assertEq(h.pairCurrency(), address(0));
        assertEq(h.feeRecipient(), FEE_SPLIT);
        assertEq(ITibbirEscrow(ESCROW).owner(), TEAM_VAULT);
        return true;
    }

    function _sqrt(bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
    }

    /// USDG raw value of `amount` raw TIBBIR at the ETH/TIBBIR and ETH/USDG spot, before fees and impact. Native ETH is
    /// currency0 of both pools: ETH per TIBBIR is 2^192 / sqrtTibbir^2 and USDG per ETH is sqrtEth^2 / 2^192.
    function _spotUSDG(uint256 amount) internal view returns (uint256) {
        uint256 sqrtT = _sqrt(TIBBIR_POOL);
        uint256 sqrtE = _sqrt(ETH_POOL);
        uint256 eth = FullMath.mulDiv(amount, 1 << 192, sqrtT * sqrtT);
        return FullMath.mulDiv(eth, sqrtE * sqrtE, 1 << 192);
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// Exact-input v4 sale by this contract through the test router, which settles after the swap as the cash-out
    /// router does. Returns the input consumed and the output received.
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

    /// The exit: TIBBIR to native ETH on the hooked pool, then ETH to USDG. Both legs must fill completely.
    function _sell(uint256 amount) internal returns (uint256 usdgOut) {
        deal(TIBBIR, address(this), amount);
        (uint256 used, uint256 eth) = _swapV4(tibbirKey, TIBBIR, amount);
        assertEq(used, amount, "Partial ETH/TIBBIR fill");
        assertGt(eth, 0);
        uint256 spent;
        (spent, usdgOut) = _swapV4(ethKey, address(0), eth);
        assertEq(spent, eth, "Partial ETH/USDG fill");
    }

    /// Calls `data` on `target` as the team vault; returns whether it succeeded.
    function _asTeam(address target, bytes memory data) internal returns (bool ok) {
        vm.prank(TEAM_VAULT);
        (ok,) = target.call(data);
    }

    function _view(address target, bytes memory data) internal view returns (uint256 value) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        assertTrue(ok);
        value = abi.decode(ret, (uint256));
    }
}

/// Token-only MEME admission of TIBBIR (Ribbita, bridged one way from Base through Chainlink CCIP) on the current V3
/// engine at a pinned mainnet fork (D207). The Safe batch's two calls run as the Safe; then: custody, reclaim and
/// default exact deltas; limits, remainder, revocation and closed earlier registries; the cash-out through the hooked
/// pool (only the hook's sell fee is paid) with each enabled leg required; Memes Earn funding after the normal grade
/// publication; the depth bounds; and every owner power a lender would meet: the instant trading freeze (`setHook`),
/// the one-day fee timelocks of the token and the hook, the pool-detection fee switch, and the escrow's reserve sweep
/// after its 30-day notice. Only the batch's calls, the team's own switches, test capital and the normal grade
/// publication change locally. Limits come from the environment (scripts/tibbir-fork.mjs reads limits.json).
contract TibbirAdmissionLiveForkTest is TibbirForkBase {
    uint256 min;
    uint256 perDeal;
    uint256 aggregate;
    uint256 dealt;
    address borrower;
    address lender;

    function setUp() public {
        if (!_fork()) return;
        min = vm.envUint("GAGE_TIBBIR_MIN");
        perDeal = vm.envUint("GAGE_TIBBIR_PER_DEAL");
        aggregate = vm.envUint("GAGE_TIBBIR_AGGREGATE");
        assertTrue(min > 0 && min <= perDeal && perDeal <= aggregate);
        dealt = aggregate * 4;
        assertFalse(registry.getERC20Config(TIBBIR).allowed);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(tibbirKey));
        _admit();
        borrower = makeAddr("TIBBIR borrower");
        lender = makeAddr("TIBBIR lender");
        deal(TIBBIR, borrower, dealt);
        deal(USDG, borrower, 100_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(borrower);
        IERC20(TIBBIR).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    /// Exactly the prepared Safe batch (safe-tibbir-listing.json): admit TIBBIR in the MEME lane with the limits, and
    /// enable the hooked ETH/TIBBIR pool on the cash-out router. The ETH/USDG leg must already be enabled.
    function _admit() internal {
        assertEq(registry.owner(), SAFE);
        assertEq(cashout.owner(), SAFE);
        assertTrue(ILegacyCashoutRoutes(address(cashout)).v4Allowed(ethKey), "ETH/USDG leg must already be enabled");
        vm.startPrank(SAFE);
        registry.setERC20Allowed(TIBBIR, true, Lane.MEME, min, perDeal, aggregate);
        cashout.setV4Route(tibbirKey, true);
        vm.stopPrank();
    }

    function _list(uint256 amount) internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(
            Collateral(Kind.ERC20, TIBBIR, amount), 90e6, 100e6, 7 days, uint40(vm.getBlockTimestamp() + 1 days), false
        );
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

    /// Past the term (the V3 engine has no grace), finalize and recover; the lender then claims the TIBBIR in kind.
    function _defaultAndClaim(uint256 id) internal returns (uint256 claimed) {
        vm.warp(uint256(vault.getLoan(id).fundedAt) + 7 days + vault.GRACE());
        vault.finalizeDefault(id);
        vm.prank(lender);
        vault.recoverDefault(id, 0, 0, vm.getBlockTimestamp());
        uint256 before = IERC20(TIBBIR).balanceOf(lender);
        vm.prank(lender);
        vault.withdrawRecovery(id, 0, lender);
        claimed = IERC20(TIBBIR).balanceOf(lender) - before;
    }

    function _routes() internal view returns (GageV2CashoutRouter.Route[] memory routes) {
        routes = new GageV2CashoutRouter.Route[](2);
        routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, TIBBIR, address(0), 0, tibbirKey, 1);
        routes[1] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, address(0), USDG, 0, ethKey, 1);
    }

    function _exit(uint256 id) internal view returns (GageV2CashoutRouter.Exit memory x) {
        x.loanId = id;
        x.recipient = borrower;
        x.minimumNet = 1;
        x.maxFinanceFee = 10e6;
        x.minUnderlying0 = 1; // ERC20 collateral recovers a single asset; the second minimum must be zero.
        x.minUnderlying1 = 0;
        x.deadline = vm.getBlockTimestamp();
        x.routes = _routes();
    }

    function testTibbir_erc20ReclaimAndDefaultExactDeltas() public {
        uint256 before = IERC20(TIBBIR).balanceOf(borrower);
        uint256 id = _list(perDeal);
        address account = vault.getLoan(id).account;
        // Wallet-to-contract and contract-to-wallet transfers carry no token fee: exact custody.
        assertEq(ITibbirToken(TIBBIR).quoteFee(borrower, account, perDeal), 0);
        assertEq(ITibbirToken(TIBBIR).quoteFee(account, borrower, perDeal), 0);
        assertEq(IERC20(TIBBIR).balanceOf(account), perDeal);
        _fund(id);
        assertEq(IERC20(TIBBIR).balanceOf(account), perDeal);
        _repay(id);
        assertEq(IERC20(TIBBIR).balanceOf(borrower), before);
        assertEq(IERC20(TIBBIR).balanceOf(account), 0);
        id = _list(perDeal);
        _fund(id);
        assertEq(ITibbirToken(TIBBIR).quoteFee(vault.getLoan(id).account, lender, perDeal), 0);
        assertEq(_defaultAndClaim(id), perDeal);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.DEFAULTED));
    }

    function testTibbir_limitsRemainderRevocationAndLegacyRemainClosed() public {
        assertEq(uint256(registry.getERC20Config(TIBBIR).lane), uint256(Lane.MEME));
        vm.expectRevert();
        _list(min - 1);
        vm.expectRevert();
        _list(perDeal + 1);
        uint256 first;
        uint256 n = aggregate / perDeal;
        for (uint256 i; i < n; ++i) {
            uint256 id = _list(perDeal);
            if (i == 0) first = id;
        }
        // A remainder at or above the minimum still lists; then the aggregate has no room for a minimum listing.
        uint256 rest = aggregate - n * perDeal;
        if (rest >= min) _list(rest);
        else rest = 0;
        vm.expectRevert();
        _list(min);
        vm.prank(registry.owner());
        registry.setERC20Allowed(TIBBIR, false, Lane.MEME, 0, 0, 0);
        vm.expectRevert();
        _list(min);
        vm.startPrank(borrower);
        vault.cancelFunding(first);
        vault.withdrawCollateral(first, borrower);
        vm.stopPrank();
        assertEq(IERC20(TIBBIR).balanceOf(borrower), dealt - (n - 1) * perDeal - rest);
        CollateralRegistry primary = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
        CollateralRegistry memeUsdg = CollateralRegistry(0x0e06d3d954d43A2e66A6D719fc0181e665c22f8d);
        CollateralRegistry ponsWeth = CollateralRegistry(0x38e9D1c40bCf6cD630b01C4a11a7bCe8BcfDE51f);
        assertFalse(primary.getERC20Config(TIBBIR).allowed);
        assertFalse(memeUsdg.getERC20Config(TIBBIR).allowed);
        assertFalse(ponsWeth.getERC20Config(TIBBIR).allowed);
    }

    /// The router swaps before it settles, so the hook lets the TIBBIR into the PoolManager free of the token's 1%
    /// transfer fee: the whole collateral reaches the pool, the Split receives only the hook's 1% of the ETH output, and
    /// the sale equals a direct two-leg sale from the same state. Nothing is left in the router.
    function testTibbir_cashoutThroughHookedPoolPaysOnlyTheHookFee() public {
        uint256 id = _list(perDeal);
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        // The same two legs sold directly from the same state: the ETH leg's output and the hook's fee on it.
        uint256 snapshot = vm.snapshotState();
        uint256 splitBefore = FEE_SPLIT.balance;
        deal(TIBBIR, address(this), perDeal);
        (, uint256 eth) = _swapV4(tibbirKey, TIBBIR, perDeal);
        uint256 hookFee = FEE_SPLIT.balance - splitBefore;
        (, uint256 direct) = _swapV4(ethKey, address(0), eth);
        vm.revertToState(snapshot);
        // The hook's sell fee is 1% of the pool's ETH output (output plus fee), to the wei.
        assertApproxEqAbs(hookFee, (eth + hookFee) / 100, 1);
        uint256 poolTibbir = IERC20(TIBBIR).balanceOf(address(poolManager));
        uint256 splitTibbir = IERC20(TIBBIR).balanceOf(FEE_SPLIT);
        uint256 splitEth = FEE_SPLIT.balance;
        uint256 usdgBefore = IERC20(USDG).balanceOf(borrower);
        uint256 routerTibbir = IERC20(TIBBIR).balanceOf(address(cashout));
        uint256 routerEth = address(cashout).balance;
        uint256 routerUsdg = IERC20(USDG).balanceOf(address(cashout));
        uint256 spot = _spotUSDG(perDeal);
        vm.prank(borrower);
        (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net) = cashout.cashOutDetailed(_exit(id));
        assertEq(gross, direct, "Cash-out sale differs from the direct sale");
        assertEq(net, gross - 100e6 - financeFee - platformFee);
        assertEq(IERC20(USDG).balanceOf(borrower) - usdgBefore, net);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(IERC20(TIBBIR).balanceOf(address(poolManager)) - poolTibbir, perDeal, "Token fee on the settle");
        assertEq(IERC20(TIBBIR).balanceOf(FEE_SPLIT), splitTibbir);
        assertEq(FEE_SPLIT.balance - splitEth, hookFee);
        assertEq(IERC20(TIBBIR).balanceOf(address(cashout)), routerTibbir);
        assertEq(address(cashout).balance, routerEth);
        assertEq(IERC20(USDG).balanceOf(address(cashout)), routerUsdg);
        emit log_named_decimal_uint("per-loan cash-out sale, % of pre-trade spot", gross * 1e4 / spot, 2);
        emit log_named_decimal_uint("hook fee, ETH", hookFee, 18);
    }

    function testTibbir_cashoutRequiresEachEnabledLeg() public {
        uint256 id = _list(perDeal);
        _fund(id);
        vm.prank(borrower);
        vault.approve(address(cashout), id);
        PoolKey[2] memory legs = [tibbirKey, ethKey];
        for (uint256 i; i < legs.length; ++i) {
            vm.prank(SAFE);
            cashout.setV4Route(legs[i], false);
            GageV2CashoutRouter.Exit memory x = _exit(id);
            vm.prank(borrower);
            // The deployed router's error; the current source reverts InvalidExit instead.
            vm.expectRevert(bytes4(keccak256("RouteNotAllowed()")));
            cashout.cashOutDetailed(x);
            vm.prank(SAFE);
            cashout.setV4Route(legs[i], true);
        }
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        uint256 before = IERC20(TIBBIR).balanceOf(borrower);
        _repay(id);
        assertEq(IERC20(TIBBIR).balanceOf(borrower) - before, perDeal);
    }

    function testTibbir_existingMemesVaultCanFundAfterAdmissionAndNormalGradePublication() public {
        ITibbirEarn earn = ITibbirEarn(address(bytes20(hex"c04a365061e5d3cf7f614cf353494294b0e3f0c9")));
        assertEq(earn.REGISTRY(), address(registry));
        assertEq(earn.pickedAssets(), 0);
        uint256 id = _list(perDeal);
        // Mirror the existing D132 keeper policy: publish TOP_RANK for an admitted token (nativeV2.assets).
        ITibbirGrades grades = ITibbirGrades(earn.GRADES());
        address[] memory tokens = new address[](1);
        tokens[0] = TIBBIR;
        uint8[] memory ranks = new uint8[](1);
        ranks[0] = 10;
        vm.prank(grades.publisher());
        grades.setGrades(tokens, ranks);
        uint256 before = earn.freeLiquidity();
        vm.prank(earn.CURATOR());
        earn.fund(id, 4, type(uint256).max);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        assertEq(before - earn.freeLiquidity(), 90e6);
        assertEq(IERC20(TIBBIR).balanceOf(vault.getLoan(id).account), perDeal);
    }

    /// Finding shown to lenders: the team can pause all TIBBIR trading at once. `setHook` has no delay; pointed at any
    /// other contract, every buy and sell in the pool reverts and so does a cash-out, while the vault still returns the
    /// TIBBIR in kind (repayment, default claim) and wallet transfers still settle exactly. Restoring the hook undoes it.
    function testTibbir_setHookPausesTradingNotCustody() public {
        ITibbirToken t = ITibbirToken(TIBBIR);
        uint256 repaid = _list(perDeal);
        _fund(repaid);
        uint256 defaulted = _list(perDeal);
        _fund(defaulted);
        address notTheHook = address(new TibbirNotTheHook());
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        t.setHook(notTheHook);
        vm.prank(TEAM_VAULT);
        vm.expectRevert(); // an address without code is refused
        t.setHook(address(0xC0DE));
        vm.prank(TEAM_VAULT);
        t.setHook(notTheHook);
        assertEq(t.hook(), notTheHook);
        // Sales and buys revert.
        deal(TIBBIR, address(this), perDeal);
        IERC20(TIBBIR).approve(address(swapRouter), perDeal);
        vm.expectRevert();
        swapRouter.swap(
            tibbirKey,
            SwapParams(false, -int256(perDeal), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.expectRevert();
        swapRouter.swap{value: 0.1 ether}(
            tibbirKey,
            SwapParams(true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        // A cash-out reverts as a whole and leaves the loan active.
        vm.prank(borrower);
        vault.approve(address(cashout), repaid);
        GageV2CashoutRouter.Exit memory x = _exit(repaid);
        vm.prank(borrower);
        vm.expectRevert();
        cashout.cashOutDetailed(x);
        assertEq(uint256(vault.getLoan(repaid).state), uint256(V2State.ACTIVE));
        // Custody is untouched: repayment returns the TIBBIR, a default returns it to the lender, wallets still transfer.
        uint256 before = IERC20(TIBBIR).balanceOf(borrower);
        _repay(repaid);
        assertEq(IERC20(TIBBIR).balanceOf(borrower) - before, perDeal);
        assertEq(_defaultAndClaim(defaulted), perDeal);
        vm.prank(lender);
        IERC20(TIBBIR).transfer(borrower, min);
        assertEq(IERC20(TIBBIR).balanceOf(borrower) - before, perDeal + min);
        // The team can undo it at once, and trading resumes.
        vm.prank(TEAM_VAULT);
        t.setHook(HOOK);
        assertGt(_sell(perDeal), 0);
    }

    /// Finding shown to lenders: the only exit charges the hook's sell fee, 1% of the ETH output today, which the team
    /// can raise to at most 10% one day after scheduling it. The token's own fee schedule (also one day, also capped at
    /// 10%) never reaches custody or this exit: the sale is unchanged when it is raised.
    function testTibbir_feeRaisesWaitOneDayCapAtTenPercentAndOnlyTheHookFeeReachesTheExit() public {
        uint256 snapshot = vm.snapshotState();
        uint256 baseline = _sell(perDeal);
        vm.revertToState(snapshot);
        ITibbirToken t = ITibbirToken(TIBBIR);
        ITibbirHook h = ITibbirHook(HOOK);
        assertEq(t.maxFeeBasisPoints(), 1000);
        assertEq(t.buyFeeBasisPoints(), 100);
        assertEq(t.sellFeeBasisPoints(), 100);
        assertEq(h.buyFeeBasisPoints(), 100);
        assertEq(h.sellFeeBasisPoints(), 100);
        // Token: 10% both ways, only after a day; above 10% is refused; custody and the exit are unaffected. Warps use
        // absolute times: under via-IR a `block.timestamp` read after vm.warp can return the value read before it.
        uint256 t0 = vm.getBlockTimestamp();
        assertFalse(_asTeam(TIBBIR, abi.encodeWithSelector(SCHEDULE_FEES, uint16(1001), uint16(1000))));
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(SCHEDULE_FEES, uint16(1000), uint16(1000))));
        assertEq(_view(TIBBIR, abi.encodeWithSelector(FEE_ETA)), t0 + 1 days);
        assertFalse(_asTeam(TIBBIR, abi.encodeWithSelector(APPLY_FEES)));
        vm.warp(t0 + 1 days - 1);
        assertFalse(_asTeam(TIBBIR, abi.encodeWithSelector(APPLY_FEES)));
        vm.warp(t0 + 1 days);
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(APPLY_FEES)));
        assertEq(t.sellFeeBasisPoints(), 1000);
        assertEq(t.quoteFee(borrower, address(poolManager), 1e18), 0.1e18);
        assertEq(t.quoteFee(borrower, address(vault), 1e18), 0);
        uint256 id = _list(perDeal);
        _fund(id);
        assertEq(IERC20(TIBBIR).balanceOf(vault.getLoan(id).account), perDeal);
        snapshot = vm.snapshotState();
        assertEq(_sell(perDeal), baseline, "The token fee reached the exit");
        vm.revertToState(snapshot);
        // Hook: the sell fee to 10%, only after a day; the exit then keeps about 9.1% less.
        assertFalse(_asTeam(HOOK, abi.encodeWithSelector(SCHEDULE_FEES, uint16(100), uint16(1001))));
        assertTrue(_asTeam(HOOK, abi.encodeWithSelector(SCHEDULE_FEES, uint16(100), uint16(1000))));
        assertEq(_view(HOOK, abi.encodeWithSelector(FEE_ETA)), t0 + 2 days);
        assertFalse(_asTeam(HOOK, abi.encodeWithSelector(APPLY_FEES)));
        vm.warp(t0 + 2 days - 1);
        assertFalse(_asTeam(HOOK, abi.encodeWithSelector(APPLY_FEES)));
        vm.warp(t0 + 2 days);
        assertTrue(_asTeam(HOOK, abi.encodeWithSelector(APPLY_FEES)));
        assertEq(h.sellFeeBasisPoints(), 1000);
        uint256 raised = _sell(perDeal);
        assertLt(raised, baseline);
        // The ETH leg keeps 90% instead of 99% of the pool output: 90/99 of the baseline, within the second leg's impact.
        assertApproxEqRel(raised, baseline * 90 / 99, 0.001e18);
        // The loan still repays in USDG and returns the TIBBIR.
        uint256 before = IERC20(TIBBIR).balanceOf(borrower);
        _repay(id);
        assertEq(IERC20(TIBBIR).balanceOf(borrower) - before, perDeal);
    }

    /// Finding shown to lenders: the team can take the unbridged reserve. The escrow's owner closes it, and 30 days
    /// later `sweepSurplus` moves the whole unreleased balance (the TIBBIR still on Base, pre-minted here) to any
    /// address; nothing is burned, so that much Robinhood-Chain TIBBIR would stand without Base TIBBIR behind it.
    function testTibbir_escrowReserveCanBeSweptThirtyDaysAfterClosing() public {
        ITibbirEscrow e = ITibbirEscrow(ESCROW);
        assertEq(e.token(), TIBBIR);
        assertEq(e.origin(), BASE_BRIDGE);
        assertEq(e.originChainSelector(), BASE_SELECTOR);
        assertEq(e.getRouter(), CCIP_ROUTER);
        assertTrue(e.configurationLocked());
        assertFalse(e.escrowClosed());
        assertEq(e.sweepDelay(), 30 days);
        assertEq(e.MIN_SWEEP_DELAY(), 7 days);
        // The configuration is locked: the origin cannot be changed.
        vm.prank(TEAM_VAULT);
        vm.expectRevert();
        e.setOrigin(address(0x1));
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        e.closeEscrow();
        address to = makeAddr("sweep recipient");
        vm.prank(TEAM_VAULT);
        vm.expectRevert();
        e.sweepSurplus(to);
        uint256 closedAt = vm.getBlockTimestamp();
        vm.prank(TEAM_VAULT);
        e.closeEscrow();
        assertTrue(e.escrowClosed());
        assertEq(e.escrowClosedAt(), closedAt);
        vm.warp(closedAt + 30 days - 1);
        vm.prank(TEAM_VAULT);
        vm.expectRevert();
        e.sweepSurplus(to);
        vm.warp(closedAt + 30 days);
        uint256 reserve = IERC20(TIBBIR).balanceOf(ESCROW);
        uint256 supply = IERC20(TIBBIR).totalSupply();
        assertGt(reserve, IERC20(TIBBIR).totalSupply() * 9 / 10);
        vm.prank(TEAM_VAULT);
        e.sweepSurplus(to);
        assertEq(IERC20(TIBBIR).balanceOf(to), reserve);
        assertEq(IERC20(TIBBIR).balanceOf(ESCROW), 0);
        assertEq(IERC20(TIBBIR).totalSupply(), supply);
    }

    /// The token's other switches do not reach a loan: the pool-detection fee (on at the anchor) charges only transfers
    /// out of Uniswap v2/v3-style contracts, which a collateral account is not; the team turns it off at once and on only
    /// after a day; the per-address exemption and the transfer allowlist change nothing for custody; the hook's
    /// pre-initialization setter is closed and its clear call leaves a sale unchanged.
    function testTibbir_otherSwitchesDoNotReachCustodyOrTheExit() public {
        ITibbirToken t = ITibbirToken(TIBBIR);
        uint256 id = _list(perDeal);
        _fund(id);
        address account = vault.getLoan(id).account;
        TibbirPoolLike pool = new TibbirPoolLike(TIBBIR);
        address wallet = makeAddr("TIBBIR wallet");
        assertEq(_view(TIBBIR, abi.encodeWithSelector(POOL_FEE_FLAG)), 1);
        assertEq(_view(TIBBIR, abi.encodeWithSelector(IS_POOL_LIKE, address(pool))), 1);
        assertEq(_view(TIBBIR, abi.encodeWithSelector(IS_POOL_LIKE, account)), 0);
        assertEq(_view(TIBBIR, abi.encodeWithSelector(IS_POOL_LIKE, address(vault))), 0);
        assertEq(t.quoteFee(address(pool), wallet, 1e18), 0.01e18);
        assertEq(t.quoteFee(wallet, address(pool), 1e18), 0);
        assertEq(t.quoteFee(account, borrower, 1e18), 0);
        // Off at once; back on only a day after scheduling.
        uint256 t0 = vm.getBlockTimestamp();
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_FEE_OFF)));
        assertEq(t.quoteFee(address(pool), wallet, 1e18), 0);
        assertFalse(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_FEE_ON)));
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_FEE_SCHEDULE_ON)));
        assertFalse(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_FEE_ON)));
        vm.warp(t0 + 1 days - 1);
        assertFalse(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_FEE_ON)));
        vm.warp(t0 + 1 days);
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_FEE_ON)));
        assertEq(t.quoteFee(address(pool), wallet, 1e18), 0.01e18);
        // The per-address exemption from pool detection, and the (pre-launch) transfer allowlist, set on the account.
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_DETECTION_EXEMPT, address(pool), true)));
        assertEq(t.quoteFee(address(pool), wallet, 1e18), 0);
        assertTrue(_asTeam(TIBBIR, abi.encodeWithSelector(POOL_DETECTION_EXEMPT, account, true)));
        vm.prank(TEAM_VAULT);
        t.setTransferAllowed(account, false);
        uint256 before = IERC20(TIBBIR).balanceOf(borrower);
        _repay(id);
        assertEq(IERC20(TIBBIR).balanceOf(borrower) - before, perDeal);
        // Hook: the pre-initialization setter reverts PoolAlreadyInitialized; the clear call changes no sale.
        vm.prank(TEAM_VAULT);
        (bool ok, bytes memory reason) =
            HOOK.call(abi.encodeWithSelector(HOOK_PRE_INIT_CONFIG, address(0xC0FFEE), 1000));
        assertFalse(ok);
        assertEq(bytes4(reason), POOL_ALREADY_INITIALIZED);
        uint256 snapshot = vm.snapshotState();
        uint256 baseline = _sell(perDeal);
        vm.revertToState(snapshot);
        assertTrue(_asTeam(HOOK, abi.encodeWithSelector(HOOK_CLEAR_PRE_INIT)));
        assertEq(_sell(perDeal), baseline);
    }

    /// The only TIBBIR exit to ETH or USDG with liquidity is the hooked pool: the hookless v4 WETH/TIBBIR (20% fee) and
    /// TIBBIR/USDG (40% fee) pools hold none. The other v4 pools that hold TIBBIR pair it with newly launched tokens that
    /// quote in TIBBIR (evidence.json otherPools); none reaches USDG.
    function testTibbir_noOtherEthOrUsdgPoolHasLiquidity() public view {
        PoolKey memory weth = PoolKey(Currency.wrap(WETH), Currency.wrap(TIBBIR), 200_000, 4000, IHooks(address(0)));
        PoolKey memory usdg = PoolKey(Currency.wrap(TIBBIR), Currency.wrap(USDG), 400_000, 4000, IHooks(address(0)));
        assertEq(_poolId(weth), WETH_TIBBIR_POOL);
        assertEq(_poolId(usdg), TIBBIR_USDG_POOL);
        assertEq(StateLibrary.getLiquidity(poolManager, PoolId.wrap(WETH_TIBBIR_POOL)), 0);
        assertEq(StateLibrary.getLiquidity(poolManager, PoolId.wrap(TIBBIR_USDG_POOL)), 0);
        assertGt(StateLibrary.getLiquidity(poolManager, PoolId.wrap(TIBBIR_POOL)), 0);
    }

    function testTibbir_maxDealExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(perDeal);
        uint256 out = _sell(perDeal);
        emit log_named_decimal_uint("per-loan sale, % of pre-trade spot", out * 1e4 / spot, 2);
        assertGe(out * 100, spot * 95, "maxDeal exit under 95% of spot");
    }

    function testTibbir_maxOpenExitWithinDepthBound() public {
        uint256 spot = _spotUSDG(aggregate);
        uint256 out = _sell(aggregate);
        emit log_named_decimal_uint("aggregate sale, % of pre-trade spot", out * 1e4 / spot, 2);
        assertGe(
            out * 100,
            spot * vm.envOr("GAGE_TIBBIR_AGGREGATE_BOUND", uint256(95)),
            "maxOpen exit under the recorded bound"
        );
    }
}
