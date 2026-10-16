// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {TestnetToken} from "../../src/testnet/TestnetToken.sol";
import {TestnetOnly} from "../../src/testnet/TestnetOnly.sol";
import {TestnetPricePeg} from "../../src/testnet/TestnetPricePeg.sol";

/// @notice The testnet price peg on a real Uniswap v4 PoolManager: an NVDAx/USDG pool opened at 180 USDG is moved to
/// 239 USDG (the real price the keeper reads), then back down, by minting and swapping the pool's own test tokens.
contract TestnetPricePegTest is Test, V4Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TestnetToken internal nvdax;
    TestnetToken internal usdg;
    TestnetPricePeg internal peg;
    PoolKey internal key;
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");

    function setUp() public {
        _deployV4();
        nvdax = new TestnetToken("NVIDIA test", "NVDAx", 18, address(this));
        usdg = new TestnetToken("USDG", "USDG", 6, address(this));
        key = _initPoolAtPrice(address(nvdax), 1e18, address(usdg), 180e6, address(0));
        nvdax.mint(lp, 100_000e18);
        usdg.mint(lp, 20_000_000e6);
        _addRawLiquidity(key, FULL_LOWER, FULL_UPPER, 1e17, lp);
        peg = new TestnetPricePeg(poolManager, keeper);
    }

    /// @dev The sqrt price X96 of `usdgPerNvdax` USDG (6 decimals) per NVDAx (18 decimals), in the pool's token order.
    function _target(uint256 usdgPerNvdax) internal view returns (uint160) {
        bool nvdaxIsZero = address(nvdax) < address(usdg);
        return nvdaxIsZero ? _sqrtPriceX96(usdgPerNvdax, 1e18) : _sqrtPriceX96(1e18, usdgPerNvdax);
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
    }

    function test_peg_movesThePoolExactlyToTheTarget() public {
        uint160 up = _target(239e6);
        vm.prank(keeper);
        peg.peg(key, up);
        assertEq(_price(), up, "up to 239");

        uint160 down = _target(150e6);
        vm.prank(keeper);
        peg.peg(key, down);
        assertEq(_price(), down, "down to 150");
    }

    function test_peg_atTheTargetSwapsNothing() public {
        uint160 here = _price();
        vm.prank(keeper);
        peg.peg(key, here);
        assertEq(_price(), here, "unchanged");
        assertEq(nvdax.balanceOf(address(peg)) + usdg.balanceOf(address(peg)), 0, "nothing taken");
    }

    function test_peg_keepsWhatTheSwapPaysOut() public {
        vm.prank(keeper);
        peg.peg(key, _target(239e6));
        // Raising NVDAx's price buys NVDAx, whichever token order the pool has: the peg minted USDG in and holds the
        // NVDAx it bought.
        assertGt(nvdax.balanceOf(address(peg)), 0, "bought NVDAx");
        assertEq(usdg.balanceOf(address(peg)), 0, "no USDG kept");
    }

    function test_peg_onlyTheOperator() public {
        uint160 up = _target(239e6);
        vm.expectRevert(TestnetPricePeg.NotOperator.selector);
        peg.peg(key, up);
    }

    function test_peg_refusesHooksUninitializedPoolsAndOutOfRangeTargets() public {
        PoolKey memory hooked = key;
        hooked.hooks = IHooks(address(0xBEEF));
        uint160 up = _target(239e6);
        vm.startPrank(keeper);
        vm.expectRevert(TestnetPricePeg.InvalidPool.selector);
        peg.peg(hooked, up);
        PoolKey memory unopened = key;
        unopened.fee = 500;
        unopened.tickSpacing = 10;
        vm.expectRevert(TestnetPricePeg.InvalidPool.selector);
        peg.peg(unopened, up);
        vm.expectRevert(TestnetPricePeg.InvalidTarget.selector);
        peg.peg(key, TickMath.MIN_SQRT_PRICE);
        vm.expectRevert(TestnetPricePeg.InvalidTarget.selector);
        peg.peg(key, TickMath.MAX_SQRT_PRICE);
        vm.stopPrank();
    }

    function test_unlockCallback_onlyThePoolManager() public {
        vm.expectRevert(TestnetPricePeg.NotPoolManager.selector);
        peg.unlockCallback("");
    }

    function test_constructor_refusesMainnetAndABadConfiguration() public {
        vm.expectRevert(TestnetPricePeg.InvalidConfiguration.selector);
        new TestnetPricePeg(IPoolManager(address(0xdead)), keeper);
        vm.expectRevert(TestnetPricePeg.InvalidConfiguration.selector);
        new TestnetPricePeg(poolManager, address(0));
        vm.chainId(4663);
        vm.expectRevert(TestnetOnly.MainnetForbidden.selector);
        new TestnetPricePeg(poolManager, keeper);
    }

    /// @dev Any target inside the pool's liquidity is reached exactly, from either side.
    function testFuzz_peg_reachesAnyTarget(uint256 usdgPerNvdax) public {
        usdgPerNvdax = bound(usdgPerNvdax, 20e6, 2000e6);
        uint160 target = _target(usdgPerNvdax);
        vm.prank(keeper);
        peg.peg(key, target);
        assertEq(_price(), target, "reached");
    }
}
