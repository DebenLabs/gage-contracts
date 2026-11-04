// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {GageLenderHook} from "../src/GageLenderHook.sol";
import {LenderAmmFixture} from "./utils/LenderAmmFixture.sol";

/// @notice An LP's entry deepens the swap curve only by its share of the float. Before the fix the hook
/// sized the curve on its raw float, which an entry fills with its whole deposit, so an LP could add, arbitrage the
/// deeper curve to the market price and leave, the loss on the depth it added falling on every holder.
contract GageLenderHookDepthTest is LenderAmmFixture {
    /// @dev The market moved: GLDx is worth 5% more than the pool's price, about 1.025 times the sqrt price.
    function _market() internal view returns (uint160) {
        return uint160(uint256(startPrice) * 10_247 / 10_000);
    }

    /// @dev `who`'s holdings at the market price, in USDG units.
    function _valueOf(address who) internal view returns (uint256) {
        return _quote(gld.balanceOf(who), _market()) + usdg.balanceOf(who);
    }

    /// @dev Buy GLDx with USDG until the pool reaches the market price.
    function _arbitrage(address who) internal {
        vm.prank(who, who);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -1e14, sqrtPriceLimitX96: _market()}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev The arbitrage alone, then the same arbitrage wrapped in an entry and a full exit: what the entry adds to
    /// the arbitrageur's gain, at the market price.
    function _gains(uint256 sharesMultiple)
        internal
        returns (uint256 plain, uint256 wrapped, uint256 holderPlain, uint256 holderWrapped)
    {
        uint256 seeded = _seedAndSweep();
        uint256 snapshot = vm.snapshotState();

        uint256 before = _valueOf(attacker);
        _arbitrage(attacker);
        plain = _valueOf(attacker) - before;
        holderPlain = _ownerValue(seeded);

        vm.revertToState(snapshot);
        before = _valueOf(attacker);
        uint256 shares = hook.totalSupply() * sharesMultiple;
        (uint256 need0, uint256 need1) = hook.previewMint(shares);
        vm.startPrank(attacker, attacker);
        hook.addReHypothecatedLiquidity(shares, need0, need1);
        vm.stopPrank();
        _arbitrage(attacker);
        vm.prank(attacker, attacker);
        hook.removeReHypothecatedLiquidity(shares, 0, 0);
        wrapped = _valueOf(attacker) - before;
        holderWrapped = _ownerValue(seeded);
    }

    /// @dev What the seeding owner's shares redeem for now, at the market price.
    function _ownerValue(uint256 shares) internal view returns (uint256) {
        (uint256 a0, uint256 a1) = hook.previewRedeem(shares);
        return _quote(a0, _market()) + a1;
    }

    function test_entryNeverDeepensTheCurveBeyondItsShare() public {
        uint256 clean = vm.snapshotState();
        for (uint256 multiple = 1; multiple <= 9; multiple += 4) {
            vm.revertToState(clean);
            (uint256 plain, uint256 wrapped, uint256 holderPlain, uint256 holderWrapped) = _gains(multiple);
            assertGt(plain, 0, "the arbitrage pays");
            // The entry's own depth is its share: it earns the arbitrage on that share and bears the same share of
            // the loss, so wrapping the arbitrage in an entry gains nothing beyond rounding.
            assertLe(wrapped, plain + 1e4, "an entry around an arbitrage does not pay");
            assertGe(holderWrapped + 1e4, holderPlain, "the other holders lose no more than to the plain arbitrage");
        }
    }

    /// @dev Swaps are sized by the swap float: the seed sets it, an entry or an exit scales it by the change in the
    /// share supply, and the keeper's rebalance resets it to the float it leaves.
    function test_swapFloat_followsSharesAndTheKeeper() public {
        uint256 seeded = _seed();
        assertEq(hook.swapFloatOf(currency0), SEED0);
        _rebalance(currency0);
        _rebalance(currency1);
        uint256 float0 = hook.floatOf(currency0);
        assertEq(hook.swapFloatOf(currency0), float0, "the keeper's float");
        (uint256 need0, uint256 need1) = hook.previewMint(seeded);
        vm.prank(lp);
        hook.addReHypothecatedLiquidity(seeded, need0, need1);
        assertEq(hook.swapFloatOf(currency0), float0 * 2, "an entry adds its share of the float, not its deposit");
        assertEq(hook.floatOf(currency0), float0 + need0, "the deposit itself waits in the float for the sweep");
        vm.prank(lp);
        hook.removeReHypothecatedLiquidity(seeded, 0, 0);
        assertApproxEqAbs(hook.swapFloatOf(currency0), float0, 2, "an exit takes its share back");
        _swapAs(attacker, true, -1e18);
        assertApproxEqAbs(
            hook.swapFloatOf(currency0),
            float0 + 1e18,
            2,
            "a swap moves it as it moves the float, the scaling's rounding down aside"
        );
        assertApproxEqAbs(hook.swapFloatOf(currency1), hook.floatOf(currency1), 2);
        vm.expectRevert(GageLenderHook.InvalidConfiguration.selector);
        hook.swapFloatOf(Currency.wrap(address(0xdead)));
    }

    /// @dev The curve never uses more than the hook holds: an exit that empties the float leaves no depth.
    function test_swapFloat_neverAboveTheFloat() public {
        uint256 shares = _seedAndSweep();
        vm.prank(owner);
        hook.removeReHypothecatedLiquidity(shares / 2, 0, 0);
        assertEq(hook.floatOf(currency0), 0);
        assertGt(hook.swapFloatOf(currency0), 0, "the stored figure is a cap, not a balance");
        vm.expectRevert();
        _swapAs(attacker, true, -1e18);
    }
}
