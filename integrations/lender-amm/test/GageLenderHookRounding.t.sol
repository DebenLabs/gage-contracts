// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LenderAmmFixture} from "./utils/LenderAmmFixture.sol";

/// @notice Rounding: a swap never leaves more owed than the float it was sized by, LPs never round in their own favour,
/// and moving the float in and out of a vault loses at most dust.
contract GageLenderHookRoundingTest is LenderAmmFixture {
    /// @dev A run of swaps either way, with both vaults refusing every call: exact input from dust to three times the
    /// float, exact output up to half of what the just-in-time position holds of the output currency
    /// (`test_exactOut_pastThePosition_cannotSettle`: more than that cannot be filled, whatever the float holds). Every
    /// swap settles from the float, and none lowers the floats' value at the price before it (fees and the curve's
    /// convexity are the LPs').
    function testFuzz_swaps_settleFromTheFloat(uint256 seed) public {
        _seedAndSweep();
        vault0.setOffline(true);
        vault1.setOffline(true);
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool zeroForOne = r & 1 == 0;
            bool exactIn = r & 2 == 0;
            uint256 float0 = gld.balanceOf(address(hook));
            uint256 float1 = usdg.balanceOf(address(hook));
            uint256 size;
            if (exactIn) size = bound(r >> 8, 1, 3 * (zeroForOne ? float0 : float1));
            else size = bound(r >> 8, 1, _positionOut(zeroForOne) / 2);
            uint160 before = _price();
            uint256 value = _quote(float0, before) + float1;
            _swapAs(attacker, zeroForOne, exactIn ? -int256(size) : int256(size));
            uint256 valueAfter = _quote(gld.balanceOf(address(hook)), before) + usdg.balanceOf(address(hook));
            assertGe(valueAfter + 2, value, "a swap never costs the LPs more than rounding");
        }
    }

    /// @dev CI run 41976097668's counterexample. Under the old bound (half the output float) its eleventh swap asked
    /// for 0.759 USDG out of a position holding 0.643: nine sales had taken GLDx from 250 USDG to 0.000025, so the
    /// hook's 25,732 GLDx were worth 0.64 USDG and they, not the 2.17 USDG float, sized the position.
    function test_swaps_settleFromTheFloat_ci41976097668() public {
        testFuzz_swaps_settleFromTheFloat(0x0000000401fa519278484df02bed5a936235f5e8697b5de4f0bb9035b38227dc);
    }

    /// @dev The position is sized by both floats at the price, so when one is worth less there it holds less of the
    /// other than the float does. An exact output past what the position holds runs to the router's price limit and
    /// owes more input than exists: the pool manager cannot advance the hook that input before the swapper pays (and
    /// no swapper could pay it). The float is never short; a swap for half the position's output settles.
    function test_exactOut_pastThePosition_cannotSettle() public {
        _seedAndSweep();
        uint16 thin = hook.MIN_FLOAT_BPS();
        vm.prank(owner);
        hook.setFloatBps(currency0, thin);
        _rebalance(currency0);
        uint256 float1 = hook.floatOf(currency1);
        uint256 out = _positionOut(true);
        assertLt(out, float1 / 10, "the thin GLDx float sizes the position");

        bytes memory managerShort = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(gld),
            IERC20.transfer.selector,
            stdError.arithmeticError,
            abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                managerShort,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swapAs(attacker, true, int256(float1 / 2));

        uint256 before = usdg.balanceOf(attacker);
        _swapAs(attacker, true, int256(out / 2));
        assertEq(usdg.balanceOf(attacker) - before, out / 2, "half the position's output settles");
    }

    /// @dev Entering and leaving at once returns no more than was paid, in either currency.
    function testFuzz_addThenRemove_neverPaysTheLP(uint256 shares, bool swapFirst) public {
        _seedAndSweep();
        if (swapFirst) _swapAs(attacker, true, -3e18);
        shares = bound(shares, 1, hook.totalSupply() * 3);
        uint256 gld0 = gld.balanceOf(lp);
        uint256 usdg0 = usdg.balanceOf(lp);
        vm.startPrank(lp);
        hook.addReHypothecatedLiquidity(shares, type(uint256).max, type(uint256).max);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();
        assertLe(gld.balanceOf(lp), gld0, "no GLDx out of rounding");
        assertLe(usdg.balanceOf(lp), usdg0, "no USDG out of rounding");
    }

    /// @dev Moving the float to new targets and back loses at most a few raw units of backing per move.
    function testFuzz_sweepAndRefill_loseAtMostDust(uint16 bpsA, uint16 bpsB) public {
        _seedAndSweep();
        bpsA = uint16(bound(bpsA, hook.MIN_FLOAT_BPS(), hook.MAX_FLOAT_BPS()));
        bpsB = uint16(bound(bpsB, hook.MIN_FLOAT_BPS(), hook.MAX_FLOAT_BPS()));
        uint256 backing0 = hook.backingOf(currency0);
        uint256 backing1 = hook.backingOf(currency1);
        uint256 moves;
        uint16[2] memory targets = [bpsA, bpsB];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(owner);
            hook.setFloatBps(currency0, targets[i]);
            hook.setFloatBps(currency1, targets[i]);
            vm.stopPrank();
            moves += _rebalanceIfAny(currency0) + _rebalanceIfAny(currency1);
        }
        assertLe(backing0 - hook.backingOf(currency0), 2 * moves, "GLDx backing kept");
        assertLe(backing1 - hook.backingOf(currency1), 2 * moves, "USDG backing kept");
    }

    /// @dev Donating to inflate the share price before a victim enters never pays back the donation.
    function testFuzz_inflation_neverPays(uint256 mintShares, uint256 donation0, uint256 donation1) public {
        _seedAndSweep();
        mintShares = bound(mintShares, 1, 1e9);
        donation0 = bound(donation0, 0, 100e18);
        donation1 = bound(donation1, 0, 30_000e6);
        uint256 gld0 = gld.balanceOf(attacker);
        uint256 usdg0 = usdg.balanceOf(attacker);
        vm.startPrank(attacker);
        hook.addReHypothecatedLiquidity(mintShares, type(uint256).max, type(uint256).max);
        gld.transfer(address(hook), donation0);
        usdg.transfer(address(hook), donation1);
        vm.stopPrank();
        vm.prank(lp);
        hook.addReHypothecatedLiquidity(hook.totalSupply(), type(uint256).max, type(uint256).max);
        vm.prank(attacker);
        hook.removeReHypothecatedLiquidity(mintShares, 0, 0);
        uint256 spent = _quote(gld0 - gld.balanceOf(attacker), startPrice) + (usdg0 - usdg.balanceOf(attacker));
        assertGe(spent + 1, _quote(donation0, startPrice) / 2 + donation1 / 2, "most of a donation stays with the LPs");
    }

    /// @dev What the just-in-time position would hold of a swap's output currency at the current price, sized as the
    /// base hook sizes it (`_getLiquidityToUse`) from each float up to its swap float: the most an exact output can
    /// take.
    function _positionOut(bool zeroForOne) internal view returns (uint256) {
        uint160 sqrtPriceX96 = _price();
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(TICK_SPACING));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING));
        uint256 usable0 = Math.min(hook.floatOf(currency0), hook.swapFloatOf(currency0));
        uint256 usable1 = Math.min(hook.floatOf(currency1), hook.swapFloatOf(currency1));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, lower, upper, usable0, usable1);
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        if (liquidity > maxLiquidity) liquidity = maxLiquidity;
        return zeroForOne
            ? SqrtPriceMath.getAmount1Delta(lower, sqrtPriceX96, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(sqrtPriceX96, upper, liquidity, false);
    }

    function _rebalanceIfAny(Currency currency) internal returns (uint256) {
        if (hook.rebalanceAmount(currency) == 0) return 0;
        _rebalance(currency);
        return 1;
    }
}
