// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";
import {GageLenderHook} from "../src/GageLenderHook.sol";
import {MockGageVault} from "./mocks/MockGageVault.sol";
import {LenderAmmFixture} from "./utils/LenderAmmFixture.sol";

contract GageLenderHookTest is LenderAmmFixture {
    // ---------------------------------------------------------------- binding

    function test_constructor_takesSortedVaultsAndBoundedTargets() public view {
        assertEq(Currency.unwrap(hook.CURRENCY0()), address(gld));
        assertEq(Currency.unwrap(hook.CURRENCY1()), address(usdg));
        assertEq(hook.getCurrencyYieldSource(currency0), address(vault0));
        assertEq(hook.getCurrencyYieldSource(currency1), address(vault1));
        assertEq(hook.MIN_SWEEP0(), 1e18, "one whole GLDx");
        assertEq(hook.MIN_SWEEP1(), 1e6, "one whole USDG");
        assertEq(hook.owner(), owner);
    }

    function test_constructor_refusesUnsortedVaults() public {
        GageLenderHook.Config memory c = _config(owner);
        (c.vault0, c.vault1) = (c.vault1, c.vault0);
        // The constructor runs in deployCodeTo's call at the target address: the next external call.
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        deployCodeTo("GageLenderHook.sol:GageLenderHook", abi.encode(c), _flagged(0x5555));
    }

    function test_constructor_refusesFloatTargetOutOfBounds() public {
        GageLenderHook.Config memory c = _config(owner);
        c.floatBps1 = 99;
        // The constructor runs in deployCodeTo's call at the target address: the next external call.
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        deployCodeTo("GageLenderHook.sol:GageLenderHook", abi.encode(c), _flagged(0x5555));
    }

    function test_initialize_ownerOnly() public {
        GageLenderHook other = _deployHook(_flagged(0x5555), owner);
        PoolKey memory k = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(other)));
        vm.expectRevert(
            _hookError(
                address(other),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
            )
        );
        vm.prank(attacker);
        manager.initialize(k, startPrice);
    }

    function test_initialize_onlyTheConfiguredPool() public {
        GageLenderHook other = _deployHook(_flagged(0x5555), owner);
        PoolKey memory k = PoolKey(currency0, currency1, 500, 10, IHooks(address(other)));
        vm.expectRevert(
            _hookError(
                address(other),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(GageLenderHook.UnexpectedPool.selector)
            )
        );
        vm.prank(owner);
        manager.initialize(k, startPrice);
    }

    function test_directLiquidity_refused() public {
        _seed();
        vm.expectRevert(
            _hookError(
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReHypothecationHook.LiquidityNotAllowed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams({tickLower: -887_220, tickUpper: 887_220, liquidityDelta: 1e12, salt: 0}), ""
        );
    }

    function test_nativeValue_refused() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(ReHypothecationHook.InvalidMsgValue.selector);
        hook.seedLiquidity{value: 1}(SEED0, _quote(SEED0, startPrice));
        vm.prank(owner);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "the hook takes no native currency");
    }

    // ---------------------------------------------------------------- the first depositor of the hook's shares

    function test_seed_ownerOnly() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.seedLiquidity(SEED0, _quote(SEED0, startPrice));
    }

    function test_seed_staysInTheFloat() public {
        uint256 amount1 = _quote(SEED0, startPrice);
        uint256 calls0 = vault0.calls();
        uint256 shares = _seed();
        assertEq(shares, _sqrt(SEED0 * amount1), "sqrt(amount0 * amount1) shares");
        assertEq(hook.floatOf(currency0), SEED0);
        assertEq(hook.floatOf(currency1), amount1);
        assertEq(vault0.balanceOf(address(hook)), 0, "nothing reaches a vault until the keeper sweeps");
        assertEq(vault0.calls(), calls0);
    }

    function test_seed_onceAndAboveTheFloor() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationHook.InsufficientSeed.selector, 99_999_999, 1e8));
        hook.seedLiquidity(99_999_999, 99_999_999);
        _seed();
        vm.prank(owner);
        vm.expectRevert(ReHypothecationHook.AlreadySeeded.selector);
        hook.seedLiquidity(SEED0, 1e9);
    }

    function test_add_waitsForTheSeed() public {
        vm.prank(lp);
        vm.expectRevert(ReHypothecationHook.NotSeeded.selector);
        hook.addReHypothecatedLiquidity(1e12, type(uint256).max, type(uint256).max);
    }

    /// @dev A donation before the seed only raises what the owner's first shares are worth; the attacker holds none.
    function test_firstDepositor_donationBeforeSeedGoesToTheLPs() public {
        vm.startPrank(attacker);
        gld.transfer(address(hook), 5e18);
        usdg.transfer(address(hook), 1000e6);
        vm.stopPrank();
        uint256 shares = _seedAndSweep();
        assertEq(hook.balanceOf(attacker), 0);
        (uint256 owed0, uint256 owed1) = hook.previewRedeem(shares);
        assertGe(owed0, SEED0, "the owner's shares carry the donation");
        assertGe(owed1, _quote(SEED0, startPrice));
    }

    /// @dev The classic inflation attack on the hook's shares: mint one share, donate, let a victim enter, leave. The
    /// owner-only seed leaves the attacker a share of a large supply, so the donation is mostly lost to the others.
    function test_firstDepositor_inflationDoesNotPay() public {
        _seedAndSweep();
        uint256 gld0 = gld.balanceOf(attacker);
        uint256 usdg0 = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        hook.addReHypothecatedLiquidity(1, type(uint256).max, type(uint256).max);
        gld.transfer(address(hook), 10e18);
        usdg.transfer(address(hook), 3000e6);
        vm.stopPrank();

        uint256 victimShares = hook.totalSupply() / 2;
        (uint256 paid0, uint256 paid1) = hook.previewMint(victimShares);
        vm.prank(lp);
        hook.addReHypothecatedLiquidity(victimShares, paid0, paid1);

        vm.prank(attacker);
        hook.removeReHypothecatedLiquidity(1, 0, 0);
        assertLt(gld.balanceOf(attacker), gld0, "the attacker loses its donation");
        assertLt(usdg.balanceOf(attacker), usdg0);
        (uint256 worth0, uint256 worth1) = hook.previewRedeem(victimShares);
        assertGe(worth0 + 2, paid0, "the victim keeps what it paid");
        assertGe(worth1 + 2, paid1);
    }

    /// @dev After every share has left, only the owner may seed again (and so takes the virtual residual).
    function test_fullExit_onlyTheOwnerReseeds() public {
        uint256 shares = _seedAndSweep();
        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        assertEq(hook.totalSupply(), 0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.seedLiquidity(SEED0, _quote(SEED0, startPrice));
        vm.prank(owner);
        hook.seedLiquidity(SEED0, _quote(SEED0, startPrice));
    }

    // ---------------------------------------------------------------- swaps draw on the float only

    function test_swap_bothDirections_neverTouchAVault() public {
        _seedAndSweep();
        uint256 value0 = _backingValue(startPrice);
        uint256 float0 = hook.floatOf(currency0);
        uint256 float1 = hook.floatOf(currency1);
        uint256 calls = vault0.calls() + vault1.calls();
        vault0.setOffline(true);
        vault1.setOffline(true);

        _swapAs(attacker, true, -1e18); // sell one GLDx
        uint256 afterSell0 = gld.balanceOf(address(hook));
        uint256 afterSell1 = usdg.balanceOf(address(hook));
        assertGt(afterSell0, float0, "the float takes the GLDx in");
        assertLt(afterSell1, float1, "and pays the USDG out");
        _swapAs(attacker, false, -600e6); // buy GLDx with 600 USDG
        _swapAs(attacker, true, 100e6); // exact output: 100 USDG
        _swapAs(attacker, false, 1e18); // exact output: one GLDx

        vault0.setOffline(false);
        vault1.setOffline(false);
        assertEq(vault0.calls() + vault1.calls(), calls, "no vault call in a swap");
        assertGe(_backingValue(startPrice) + 2, value0, "the LPs earned the fees");
    }

    /// @dev A thin float gives a swap less depth, never a loss: the swap trades along the float's own curve.
    function test_swap_floatRunsDry_lessDepthNoLoss() public {
        _seedAndSweep();
        uint256 snapshot = vm.snapshotState();
        uint256 deepOut = _sellAndMeasure(10e18);

        vm.revertToState(snapshot);
        vm.startPrank(owner);
        hook.setFloatBps(currency0, hook.MIN_FLOAT_BPS());
        hook.setFloatBps(currency1, hook.MIN_FLOAT_BPS());
        vm.stopPrank();
        _rebalance(currency0);
        _rebalance(currency1);
        uint256 thinFloat1 = hook.floatOf(currency1);
        uint256 value0 = _backingValue(startPrice);
        uint256 thinOut = _sellAndMeasure(10e18);

        assertLt(thinOut, deepOut, "less depth");
        assertLe(thinOut, thinFloat1, "never more than the float");
        assertGe(_backingValue(startPrice), value0, "no loss at the price before the swap");
    }

    /// @dev Exits take the float first. One that empties it leaves swaps without depth on that side until the keeper
    /// refills it; the swap reverts and nobody loses.
    function test_swap_emptyFloatWaitsForTheKeeper() public {
        uint256 shares = _seedAndSweep();
        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);
        assertEq(hook.floatOf(currency0), 0, "the exit took the whole float");
        assertEq(hook.floatOf(currency1), 0);

        vm.expectRevert(
            _hookError(
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ReHypothecationHook.NoUsableLiquidity.selector)
            )
        );
        _swapAs(attacker, true, -1e18);

        _rebalance(currency0);
        _rebalance(currency1);
        _swapAs(attacker, true, -1e18);
    }

    // ---------------------------------------------------------------- the keeper: refill and sweep

    function test_rebalance_sweepsTheExcessToTheTarget() public {
        _seed();
        uint256 target0 = hook.targetFloat(currency0);
        assertEq(hook.rebalanceAmount(currency0), -int256(SEED0 - target0));
        vm.expectEmit(true, false, false, false, address(hook));
        emit GageLenderHook.Swept(currency0, 0, 0);
        int256 moved = _rebalance(currency0);
        assertEq(moved, -int256(SEED0 - target0));
        assertEq(hook.floatOf(currency0), target0);
        assertApproxEqAbs(hook.backingOf(currency0), SEED0, 1, "a sweep moves value, it creates none");
        assertEq(hook.rebalanceAmount(currency0), 0, "at the target");
        vm.prank(keeper);
        vm.expectRevert(GageLenderHook.NothingToMove.selector);
        hook.rebalance(currency0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
    }

    function test_rebalance_refillsFromTheVaultsFreeCash() public {
        _seedAndSweep();
        _swapAs(attacker, true, -8e18); // the hook pays out USDG
        uint256 float1 = hook.floatOf(currency1);
        uint256 target1 = hook.targetFloat(currency1);
        assertLt(float1, target1);
        vm.expectEmit(true, false, false, false, address(hook));
        emit GageLenderHook.Refilled(currency1, 0, 0);
        int256 moved = _rebalance(currency1);
        assertEq(moved, int256(target1 - float1));
        assertEq(hook.floatOf(currency1), target1);
    }

    /// @dev Lent principal is priced but not free: a refill takes what the vault's `maxWithdraw` allows and no more.
    function test_rebalance_refillBoundedByFreeCash() public {
        _seedAndSweep();
        _swapAs(attacker, true, -8e18);
        vault1.lend(vault1.cash() - 50e6);
        int256 moved = _rebalance(currency1);
        assertEq(moved, 50e6, "the vault's free cash");
        assertLt(hook.floatOf(currency1), hook.targetFloat(currency1), "the rest waits for repayments");
        assertEq(hook.rebalanceAmount(currency1), 0);
    }

    function test_rebalance_sweepsNoLessThanOneUnit() public {
        _seedAndSweep();
        // Put 0.9 GLDx above the target: under the vault's one-unit minimum deposit.
        gld.mint(address(hook), 9e17);
        assertGt(hook.floatOf(currency0), hook.targetFloat(currency0));
        assertEq(hook.rebalanceAmount(currency0), 0);
        vm.prank(keeper);
        vm.expectRevert(GageLenderHook.NothingToMove.selector);
        hook.rebalance(currency0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
    }

    function test_rebalance_keepersOnly() public {
        _seed();
        vm.prank(attacker);
        vm.expectRevert(GageLenderHook.NotKeeper.selector);
        hook.rebalance(currency0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
    }

    /// @dev A price pushed away from the market cannot make the keeper deploy liquidity there.
    function test_rebalance_onlyWithinThePriceBand() public {
        _seedAndSweep();
        _swapAs(attacker, true, -20e18);
        uint160 price = _price();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(GageLenderHook.PriceOutOfBand.selector, price, startPrice - 1e18, startPrice + 1e18)
        );
        hook.rebalance(currency1, startPrice - 1e18, startPrice + 1e18);
    }

    // ---------------------------------------------------------------- LP entry and exit

    function test_add_joinsTheFloat() public {
        _seedAndSweep();
        uint256 calls = vault0.calls() + vault1.calls();
        uint256 float0 = hook.floatOf(currency0);
        uint256 shares = hook.totalSupply() / 4;
        (uint256 need0, uint256 need1) = hook.previewMint(shares);
        vm.prank(lp);
        hook.addReHypothecatedLiquidity(shares, need0, need1);
        assertEq(hook.floatOf(currency0), float0 + need0);
        assertEq(vault0.calls() + vault1.calls(), calls, "an entry never calls a vault");
        assertEq(hook.rebalanceAmount(currency0) < 0, true, "the keeper sweeps the new excess");
    }

    function test_remove_paidFromTheFloatWhenItSuffices() public {
        _seedAndSweep();
        uint256 shares = _enter(lp, hook.totalSupply() / 10);
        _rebalance(currency0);
        _rebalance(currency1);
        uint256 calls = vault0.calls() + vault1.calls();
        (uint256 owed0, uint256 owed1) = hook.previewRedeem(shares);
        uint256 before1 = usdg.balanceOf(lp);
        vm.prank(lp);
        hook.removeReHypothecatedLiquidity(shares, owed0, owed1);
        assertEq(usdg.balanceOf(lp), before1 + owed1);
        assertEq(vault0.calls() + vault1.calls(), calls, "the float paid");
    }

    function test_remove_drawsTheVaultsFreeCashBeyondTheFloat() public {
        uint256 shares = _seedAndSweep();
        uint256 vaultShares = vault1.balanceOf(address(hook));
        (uint256 owed0, uint256 owed1) = hook.previewRedeem(shares / 2);
        uint256 shortfall = owed1 - hook.floatOf(currency1);
        vm.expectEmit(true, false, false, false, address(hook));
        emit GageLenderHook.ExitFunded(currency1, shortfall, 0);
        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 2, owed0, owed1);
        assertEq(hook.floatOf(currency1), 0);
        assertLt(vault1.balanceOf(address(hook)), vaultShares);
    }

    /// @dev Exits wait on free cash: lent principal comes back only when its loans repay.
    function test_remove_waitsOnFreeCash() public {
        uint256 shares = _seedAndSweep();
        vault1.lend(vault1.cash() - 10e6);
        (, uint256 owed1) = hook.previewRedeem(shares / 2);
        uint256 shortfall = owed1 - hook.floatOf(currency1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GageLenderHook.ExitWaitsOnFreeCash.selector, currency1, shortfall, 10e6));
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);

        uint256 lent = vault1.performingPrincipal();
        usdg.mint(address(vault1), lent + 5e6);
        vault1.repay(lent, 5e6);
        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);
    }

    function test_vaultInterest_raisesTheSharePrice() public {
        uint256 shares = _seedAndSweep();
        (, uint256 before1) = hook.previewRedeem(shares);
        vault1.accrue(100e6);
        (, uint256 after1) = hook.previewRedeem(shares);
        assertApproxEqAbs(after1 - before1, 100e6, 1e3, "the hook is the vault's only holder");
    }

    // ---------------------------------------------------------------- vault shares sent to the hook

    /// @dev Vault shares someone sends the hook are not backing: the LP share price counts only the shares the hook
    /// bought itself.
    function test_donatedVaultShares_areNotBacking() public {
        uint256 shares = _seedAndSweep();
        uint256 donated = _vaultSharesOf(attacker, 1000e6);
        uint256 backing1 = hook.backingOf(currency1);
        (uint256 owed0, uint256 owed1) = hook.previewRedeem(shares);

        vm.prank(attacker);
        vault1.transfer(address(hook), donated);

        assertEq(hook.backingOf(currency1), backing1, "a donation is not backing");
        (uint256 after0, uint256 after1) = hook.previewRedeem(shares);
        assertEq(after0, owed0);
        assertEq(after1, owed1, "the LP share price does not move");
    }

    /// @dev The attack the count stops: a holder of vault shares whose cash is lent enters, sends the shares to the
    /// hook and leaves with the float, ahead of the vault's own exits and at the other LPs' cost.
    function test_donatedVaultShares_cannotBuyTheFloat() public {
        _seedAndSweep();
        uint256 donated = _vaultSharesOf(attacker, hook.floatOf(currency1) / 2);
        vault1.lend(vault1.cash());
        uint256 float1 = hook.floatOf(currency1);
        uint256 before0 = gld.balanceOf(attacker);
        uint256 before1 = usdg.balanceOf(attacker);

        uint256 entered = _enter(attacker, hook.totalSupply() * 99);
        vm.prank(attacker);
        vault1.transfer(address(hook), donated);
        vm.prank(attacker);
        hook.removeReHypothecatedLiquidity(entered, 0, 0);

        assertLe(gld.balanceOf(attacker), before0);
        assertLe(usdg.balanceOf(attacker), before1, "the donated shares bought none of the float");
        assertGe(hook.floatOf(currency1), float1, "the other LPs keep their float");
    }

    /// @dev The count follows the hook's own sweeps, exits and refills; shares sent to it stay apart, never burned.
    function test_vaultShares_countOnlyTheHooksOwn() public {
        uint256 shares = _seedAndSweep();
        assertEq(hook.vaultSharesOf(currency1), vault1.balanceOf(address(hook)), "the sweep's shares");
        uint256 donated = _vaultSharesOf(attacker, 1000e6);
        vm.prank(attacker);
        vault1.transfer(address(hook), donated);

        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);
        assertEq(hook.floatOf(currency1), 0, "the exit drew the vault's free cash");
        assertEq(vault1.balanceOf(address(hook)) - hook.vaultSharesOf(currency1), donated, "an exit burns its own");

        assertGt(_rebalance(currency1), 0);
        assertEq(vault1.balanceOf(address(hook)) - hook.vaultSharesOf(currency1), donated, "a refill burns its own");
    }

    // ---------------------------------------------------------------- vault refusal moments

    /// @dev From the end of a loan's term until it is settled the vault refuses share moves and its price waits on a
    /// possible write-off: LPs may neither enter nor leave, the keeper waits, swaps go on from the float.
    function test_settlementDue_pausesEntriesExitsAndTheKeeper_notSwaps() public {
        uint256 shares = _seedAndSweep();
        vault0.setEarliestMaturity(uint40(block.timestamp));

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(GageLenderHook.VaultSettling.selector, currency0));
        hook.addReHypothecatedLiquidity(1e12, type(uint256).max, type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GageLenderHook.VaultSettling.selector, currency0));
        hook.removeReHypothecatedLiquidity(shares / 10, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(GageLenderHook.VaultSettling.selector, currency0));
        hook.rebalance(currency0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);

        _swapAs(attacker, true, -1e18);
        _swapAs(attacker, false, -300e6);

        vault0.settle(new uint256[](0));
        assertGt(hook.targetFloat(currency0), 0, "pricing resumes once the loan is settled");
        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 10, 0, 0);
    }

    /// @dev In the second a vault buys a position its maxima read zero and share moves revert `SaleTooSoon`.
    function test_purchaseSecond_keeperWaitsOneSecond() public {
        _seedAndSweep();
        _swapAs(attacker, true, -8e18);
        gld.mint(address(hook), 5e18);
        vault0.setPurchaseSecond(uint40(block.timestamp));
        vault1.setPurchaseSecond(uint40(block.timestamp));

        assertEq(hook.rebalanceAmount(currency1), 0, "maxWithdraw reads zero");
        vm.prank(keeper);
        vm.expectRevert(GageLenderHook.NothingToMove.selector);
        hook.rebalance(currency1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        vm.prank(keeper);
        vm.expectRevert(MockGageVault.SaleTooSoon.selector);
        hook.rebalance(currency0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
        _swapAs(attacker, false, -300e6);

        vm.warp(block.timestamp + 1);
        _rebalance(currency1);
        _rebalance(currency0);
    }

    /// @dev A reward source that cannot pay makes every share move revert `RewardsPending`, which the maxima do not
    /// show: the keeper gets the vault's error and retries; exits the float covers still go through.
    function test_rewardsPending_keeperRetries_floatExitsGoOn() public {
        uint256 shares = _seedAndSweep();
        gld.mint(address(hook), 5e18);
        vault0.setRewardsPending(true);
        vm.prank(keeper);
        vm.expectRevert(MockGageVault.RewardsPending.selector);
        hook.rebalance(currency0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);

        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 100, 0, 0);
        vm.prank(owner);
        vm.expectRevert(MockGageVault.RewardsPending.selector);
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);
        _swapAs(attacker, true, -1e18);

        vault0.setRewardsPending(false);
        _rebalance(currency0);
    }

    // ---------------------------------------------------------------- pockets, rewards and recovery

    function test_claimPockets_earningsJoinTheFloat() public {
        _seedAndSweep();
        usdg.mint(address(vault1), 40e6);
        uint256 id = vault1.openPocket(address(usdg), address(hook), 40e6);
        uint256 backing = hook.backingOf(currency1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(attacker);
        vm.expectRevert(GageLenderHook.NotKeeper.selector);
        hook.claimPockets(currency1, ids);
        vm.prank(keeper);
        hook.claimPockets(currency1, ids);
        assertEq(hook.backingOf(currency1), backing + 40e6);
    }

    /// @dev A write-off's recovered collateral is another token: claimed by the keeper, passed on by the owner.
    function test_collateralPocket_passedOnByTheOwner() public {
        _seedAndSweep();
        MockERC20 meme = new MockERC20("SCHIFFYx", "SCHIFFYx", 18);
        meme.mint(address(vault0), 1e24);
        uint256[] memory ids = new uint256[](1);
        ids[0] = vault0.openPocket(address(meme), address(hook), 1e24);
        vm.prank(keeper);
        hook.claimPockets(currency0, ids);
        address desk = makeAddr("partner-desk");
        vm.prank(owner);
        hook.recoverToken(IERC20(address(meme)), desk, 1e24);
        assertEq(meme.balanceOf(desk), 1e24);
    }

    function test_vaultRewards_claimedThenPassedOn() public {
        _seedAndSweep();
        MockERC20 sgage = new MockERC20("sGAGE", "sGAGE", 18);
        sgage.mint(address(vault1), 7e18);
        vault1.setReward(IERC20(address(sgage)), address(hook), 7e18);
        vm.prank(keeper);
        assertEq(hook.claimVaultRewards(currency1), 7e18);
        vm.prank(owner);
        hook.recoverToken(IERC20(address(sgage)), lp, 7e18);
        assertEq(sgage.balanceOf(lp), 7e18);
    }

    function test_recoverToken_neverTakesBacking() public {
        _seedAndSweep();
        address[5] memory backing = [address(gld), address(usdg), address(vault0), address(vault1), address(hook)];
        for (uint256 i; i < backing.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(GageLenderHook.BackingToken.selector);
            hook.recoverToken(IERC20(backing[i]), owner, 1);
        }
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        hook.recoverToken(IERC20(address(gld)), attacker, 1);
    }

    // ---------------------------------------------------------------- owner settings

    function test_setFloatBps_boundedAndOwnerOnly() public {
        vm.startPrank(owner);
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        hook.setFloatBps(currency0, 99);
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        hook.setFloatBps(currency0, 10_001);
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        hook.setFloatBps(Currency.wrap(address(0xdead)), 500);
        vm.expectEmit(true, false, false, true, address(hook));
        emit GageLenderHook.FloatTargetSet(currency1, 500);
        hook.setFloatBps(currency1, 500);
        vm.stopPrank();
        assertEq(hook.floatBps1(), 500);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        hook.setFloatBps(currency1, 600);
    }

    function test_setKeeper() public {
        vm.prank(owner);
        hook.setKeeper(keeper, false);
        assertFalse(hook.isKeeper(keeper));
        vm.prank(owner);
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        hook.setKeeper(address(0), true);
    }

    // ---------------------------------------------------------------- helpers

    function _config(address hookOwner) internal view returns (GageLenderHook.Config memory c) {
        c = GageLenderHook.Config({
            poolManager: manager,
            vault0: hook.VAULT0(),
            vault1: hook.VAULT1(),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            floatBps0: FLOAT_BPS,
            floatBps1: FLOAT_BPS,
            owner: hookOwner,
            name: "x",
            symbol: "x"
        });
    }

    function _flagged(uint160 nudge) internal pure returns (address) {
        return address(uint160(FLAGS) | (nudge << 144));
    }

    function _hookError(address target, bytes4 selector, bytes memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            target,
            selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev `who` mints `shares` at the hook's current ratio.
    function _enter(address who, uint256 shares) internal returns (uint256) {
        vm.prank(who);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        return shares;
    }

    /// @dev `who` deposits `assets` USDG into the USDG vault directly and holds the shares.
    function _vaultSharesOf(address who, uint256 assets) internal returns (uint256) {
        vm.startPrank(who);
        usdg.approve(address(vault1), assets);
        uint256 shares = vault1.deposit(assets, who);
        vm.stopPrank();
        return shares;
    }

    /// @dev USDG the attacker receives for selling `amount0` GLDx.
    function _sellAndMeasure(uint256 amount0) internal returns (uint256) {
        uint256 before = usdg.balanceOf(attacker);
        _swapAs(attacker, true, -int256(amount0));
        return usdg.balanceOf(attacker) - before;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
