// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LenderAmmFixture} from "./utils/LenderAmmFixture.sol";

/// @notice Rounding: a swap never leaves more owed than the float it was sized by, LPs never round in their own favour,
/// and moving the float in and out of a vault loses at most dust.
contract GageLenderHookRoundingTest is LenderAmmFixture {
    /// @dev A run of swaps either way, exact input and exact output, from dust to several times the float, with both
    /// vaults refusing every call: every swap settles from the float, and none lowers the floats' value at the price
    /// before it (fees and the curve's convexity are the LPs').
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
            else size = bound(r >> 8, 1, (zeroForOne ? float1 : float0) / 2);
            uint160 before = _price();
            uint256 value = _quote(float0, before) + float1;
            _swapAs(attacker, zeroForOne, exactIn ? -int256(size) : int256(size));
            uint256 valueAfter = _quote(gld.balanceOf(address(hook)), before) + usdg.balanceOf(address(hook));
            assertGe(valueAfter + 2, value, "a swap never costs the LPs more than rounding");
        }
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

    function _rebalanceIfAny(Currency currency) internal returns (uint256) {
        if (hook.rebalanceAmount(currency) == 0) return 0;
        _rebalance(currency);
        return 1;
    }
}
