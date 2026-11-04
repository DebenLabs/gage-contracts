// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {GageLenderHook} from "../../src/GageLenderHook.sol";
import {IGageVault} from "../../src/interfaces/IGageVault.sol";
import {LenderAmmSetup} from "../../script/LenderAmmSetup.sol";

/// @notice The kit against gage's live testnet (chain 46630): real IntentVaults from the USDG and GLDx generations'
/// factories, the testnet's own v4 PoolManager and the hookless GLDx/USDG pool's price. Skipped unless
/// `LENDER_AMM_FORK_RPC` is set (the public RPC serves it: https://rpc.testnet.chain.robinhood.com).
contract LenderAmmForkTest is Test, LenderAmmSetup {
    using StateLibrary for IPoolManager;

    /// @dev IntentVault's packed clock word (`IntentVaultSettingsLayout.t.sol`): `earliestMaturity` in its low 40 bits,
    /// the purchase guard `_shareChangeBlockedAt` in bits 184 to 223.
    uint256 internal constant CLOCK_SLOT = 31;

    Network internal n;
    GageLenderHook internal hook;
    IGageVault internal usdgVault;
    IGageVault internal assetVault;
    PoolKey internal key;
    PoolSwapTest internal router;
    Currency internal asset;
    Currency internal usdg;

    address internal curator = makeAddr("partner-safe");
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    function setUp() public {
        string memory rpc = vm.envOr("LENDER_AMM_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        n = _network("GLDx");
        asset = Currency.wrap(n.asset);
        usdg = Currency.wrap(n.usdg);

        // What gage does for a partner: admit its Safe on both generations' factories.
        vm.prank(n.usdgFactory.owner());
        n.usdgFactory.setCreator(curator, true);
        vm.prank(n.assetFactory.owner());
        n.assetFactory.setCreator(curator, true);

        vm.startPrank(curator);
        (usdgVault, assetVault) = _createVaults(n, curator);
        vm.stopPrank();
        hook = _deployHook(_hookConfig(n, usdgVault, assetVault, curator), address(this));
        key = _poolKey(hook);
        vm.startPrank(curator);
        n.poolManager.initialize(key, _startPrice(n));
        hook.setKeeper(keeper, true);
        vm.stopPrank();
        router = new PoolSwapTest(n.poolManager);

        address[3] memory holders = [curator, lp, trader];
        for (uint256 i; i < holders.length; ++i) {
            deal(n.asset, holders[i], 1000e18);
            deal(n.usdg, holders[i], 300_000e6);
            vm.startPrank(holders[i]);
            IERC20(n.asset).approve(address(hook), type(uint256).max);
            IERC20(n.usdg).approve(address(hook), type(uint256).max);
            IERC20(n.asset).approve(address(router), type(uint256).max);
            IERC20(n.usdg).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_fork_vaultsAreGageVaultsOfThePair() public view {
        assertTrue(n.usdgFactory.isVault(address(usdgVault)));
        assertTrue(n.assetFactory.isVault(address(assetVault)));
        assertEq(usdgVault.asset(), n.usdg);
        assertEq(assetVault.asset(), n.asset);
        assertEq(hook.getCurrencyYieldSource(usdg), address(usdgVault));
        assertEq(hook.getCurrencyYieldSource(asset), address(assetVault));
        assertEq(usdgVault.bufferBps(), 3000, "cash kept free, USDG side");
        assertEq(assetVault.bufferBps(), 3000, "cash kept free, GLDx side");
        assertEq(usdgVault.name(), "Lender AMM GLDx-USDG (USDG)", "the factory names the vault, symbol as written");
        assertEq(assetVault.name(), "Lender AMM GLDx-USDG (GLDx)");
    }

    /// @dev Seed, sweep into the real vaults, swap both ways without a vault call, refill from the vault, and let an
    /// LP in and out, its exit drawing the vault's free cash beyond the float.
    function test_fork_lifecycle() public {
        uint256 shares = _seed(50e18);
        _rebalance(asset);
        _rebalance(usdg);
        assertGt(usdgVault.balanceOf(address(hook)), 0, "the USDG float's excess is lent through gage");
        assertGt(assetVault.balanceOf(address(hook)), 0, "and the GLDx float's");
        assertEq(hook.floatOf(usdg), hook.targetFloat(usdg));

        vm.startStateDiffRecording();
        _swap(true, -2e18);
        _swap(false, -900e6);
        _swap(true, 150e6);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        for (uint256 i; i < accesses.length; ++i) {
            assertTrue(
                accesses[i].account != address(usdgVault) && accesses[i].account != address(assetVault),
                "a swap never reads or calls a gage vault"
            );
        }

        _swap(true, -10e18);
        assertLt(hook.floatOf(usdg), hook.targetFloat(usdg), "the swap drew the USDG float down");
        int256 moved = _rebalance(usdg);
        assertGt(moved, 0, "refilled from the vault's free cash");
        assertEq(hook.floatOf(usdg), hook.targetFloat(usdg));

        vm.prank(lp);
        hook.addReHypothecatedLiquidity(shares / 4, type(uint256).max, type(uint256).max);
        _rebalance(asset);
        vm.recordLogs();
        vm.prank(curator);
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);
        assertTrue(_emitted(GageLenderHook.ExitFunded.selector), "the exit drew the vaults' free cash");
        vm.prank(lp);
        hook.removeReHypothecatedLiquidity(shares / 4, 0, 0);
    }

    /// @dev Between a loan's end and its settle the real vault refuses share moves: the hook refuses LP entries and
    /// exits and the keeper waits, while swaps go on from the float.
    function test_fork_settlementDue_keeperWaits_swapsGoOn() public {
        uint256 shares = _seed(50e18);
        _rebalance(usdg);
        _swap(true, -5e18);
        _setClock(usdgVault, uint40(block.timestamp - 1), 0);
        assertEq(usdgVault.maxWithdraw(address(hook)), 0, "the vault's own maxima read zero");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(GageLenderHook.VaultSettling.selector, usdg));
        hook.rebalance(usdg, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(GageLenderHook.VaultSettling.selector, usdg));
        hook.removeReHypothecatedLiquidity(shares / 10, 0, 0);
        _swap(false, -500e6);
        _swap(true, -1e18);

        _setClock(usdgVault, type(uint40).max, 0);
        _rebalance(usdg);
    }

    /// @dev In the second a vault buys a position its maxima read zero and every share move reverts `SaleTooSoon`.
    function test_fork_purchaseSecond_keeperRetriesNextSecond() public {
        _seed(50e18);
        _rebalance(asset);
        _rebalance(usdg);
        _swap(true, -10e18);
        _setClock(usdgVault, type(uint40).max, uint40(block.timestamp));
        _setClock(assetVault, type(uint40).max, uint40(block.timestamp));

        assertEq(hook.rebalanceAmount(usdg), 0, "no free cash this second");
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("SaleTooSoon()")));
        hook.rebalance(asset, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        _swap(false, -500e6);

        vm.warp(block.timestamp + 1);
        _rebalance(usdg);
        _rebalance(asset);
    }

    /// @dev The real vault takes no deposit under one whole unit; the hook never offers one.
    function test_fork_minimumDeposit() public {
        _seed(50e18);
        _rebalance(asset);
        deal(n.asset, address(hook), IERC20(n.asset).balanceOf(address(hook)) + 5e17);
        assertEq(hook.rebalanceAmount(asset), 0, "half a GLDx over the target is not swept");
        deal(n.asset, address(this), 5e17);
        IERC20(n.asset).approve(address(assetVault), 5e17);
        vm.expectRevert(bytes4(keccak256("InvalidAmount()")));
        assetVault.deposit(5e17, address(this));
    }

    /// @dev On the real vault: shares someone sends the hook are not backing; the hook counts the shares it bought.
    function test_fork_donatedVaultSharesAreNotBacking() public {
        _seed(50e18);
        _rebalance(usdg);
        assertEq(hook.vaultSharesOf(usdg), usdgVault.balanceOf(address(hook)), "the sweep's shares");
        uint256 backing = hook.backingOf(usdg);

        vm.startPrank(trader);
        IERC20(n.usdg).approve(address(usdgVault), 1000e6);
        uint256 donated = usdgVault.deposit(1000e6, trader);
        IERC20(address(usdgVault)).transfer(address(hook), donated);
        vm.stopPrank();

        assertEq(hook.backingOf(usdg), backing, "a donation is not backing");
        assertEq(usdgVault.balanceOf(address(hook)) - hook.vaultSharesOf(usdg), donated);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The curator seeds `amount0` GLDx and the USDG worth it at the pool's price.
    function _seed(uint256 assetAmount) internal returns (uint256 shares) {
        (uint160 price,,,) = n.poolManager.getSlot0(key.toId());
        uint256 usdgAmount = _quote(assetAmount, price);
        bool assetFirst = hook.CURRENCY0() == asset;
        vm.prank(curator);
        (shares,) = hook.seedLiquidity(assetFirst ? assetAmount : usdgAmount, assetFirst ? usdgAmount : assetAmount);
    }

    function _rebalance(Currency currency) internal returns (int256) {
        vm.prank(keeper);
        return hook.rebalance(currency, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
    }

    /// @dev `assetIn`: sell GLDx for USDG, else buy GLDx; a negative amount is an exact input.
    function _swap(bool assetIn, int256 amountSpecified) internal {
        bool zeroForOne = assetIn == (hook.CURRENCY0() == asset);
        vm.prank(trader);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Rewrite the vault's clock word: `earliestMaturity` and the purchase guard, the exposure fields kept.
    function _setClock(IGageVault vault, uint40 maturity, uint40 purchase) internal {
        uint256 word = uint256(vm.load(address(vault), bytes32(CLOCK_SLOT)));
        word = (word & ~uint256(type(uint40).max)) | maturity;
        word = (word & ~(uint256(type(uint40).max) << 184))
            | (uint256(purchase == 0 ? type(uint40).max : purchase) << 184);
        vm.store(address(vault), bytes32(CLOCK_SLOT), bytes32(word));
    }

    function _quote(uint256 amount, uint160 sqrtPriceX96) internal view returns (uint256) {
        uint256 p = uint256(sqrtPriceX96);
        // USDG per raw GLDx unit when GLDx is currency0; its inverse otherwise.
        return hook.CURRENCY0() == asset ? amount * p / 2 ** 96 * p / 2 ** 96 : amount * 2 ** 96 / p * 2 ** 96 / p;
    }

    function _emitted(bytes32 topic) internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }
}
