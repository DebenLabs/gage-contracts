// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CompoundingSeedBootstrap} from "../../src/token/CompoundingSeedBootstrap.sol";
import {CompoundingSeedTimelock} from "../../src/token/CompoundingSeedTimelock.sol";
import {RehearsalLaunch} from "../../script/rehearsal/RehearsalLaunch.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract CompoundingSeedBootstrapTest is V4Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal owner = makeAddr("owner");
    MockERC20 internal token0;
    MockERC20 internal token1;
    CompoundingSeedBootstrap internal bootstrap;
    PoolKey internal key;
    uint160 internal price;

    function setUp() public {
        _deployV4();
        MockERC20 a = new MockERC20("a", "a", 18);
        MockERC20 b = new MockERC20("b", "b", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 30_000, 60, IHooks(address(0)));
        price = _sqrtPriceX96(1_000_000_000e18, 9_000_000e18);
        bootstrap = new CompoundingSeedBootstrap(owner, posm, permit2);
        token0.mint(owner, 9_000_000e18);
        token1.mint(owner, 1_000_000_000e18);
        vm.startPrank(owner);
        token0.approve(address(bootstrap), 9_000_000e18);
        token1.approve(address(bootstrap), 1_000_000_000e18);
        vm.stopPrank();
    }

    function _seed() internal {
        vm.prank(owner);
        bootstrap.seed(key, price, 9_000_000e18, 1_000_000_000e18);
    }

    function test_atomicSeedConsumesFullBudgetLocks365DaysAndRefundsDust() public {
        uint256 id = posm.nextTokenId();
        uint256 lockedAt = block.timestamp;
        _seed();
        CompoundingSeedTimelock lock = bootstrap.timelock();
        assertEq(lock.tokenId(), id);
        assertEq(IERC721(address(posm)).ownerOf(id), address(lock));
        assertEq(lock.TREASURY(), owner);
        assertEq(lock.releaseAt(), lockedAt + 365 days);
        assertGt(posm.getPositionLiquidity(id), 0);
        assertLt(token0.balanceOf(owner), 1e12);
        assertLt(token1.balanceOf(owner), 1e12);
        assertEq(token0.balanceOf(address(bootstrap)), 0);
        assertEq(token1.balanceOf(address(bootstrap)), 0);
        assertEq(token0.allowance(address(bootstrap), address(permit2)), 0);
        vm.warp(lockedAt + 365 days - 1);
        vm.expectRevert(CompoundingSeedTimelock.StillLocked.selector);
        lock.release();
        vm.warp(lockedAt + 365 days);
        lock.release();
        assertEq(IERC721(address(posm)).ownerOf(id), owner);
    }

    function test_outsiderCannotChooseTheFirstSeed() public {
        vm.expectRevert(CompoundingSeedBootstrap.NotOwner.selector);
        bootstrap.seed(key, price, 9_000_000e18, 1_000_000_000e18);
        assertEq(address(bootstrap.timelock()), address(0));
    }

    function test_existingWrongPriceFailsBeforeTakingTokens() public {
        poolManager.initialize(key, price + 1);
        vm.expectRevert(CompoundingSeedBootstrap.UnexpectedPoolState.selector);
        _seed();
        assertEq(token0.balanceOf(owner), 9_000_000e18);
    }

    function test_identicalEmptyInitializationCanBeUsed() public {
        poolManager.initialize(key, price);
        _seed();
        assertGt(bootstrap.timelock().tokenId(), 0);
    }

    function test_insufficientFundsRollsBackInitializationAndLock() public {
        vm.prank(owner);
        token1.transfer(address(123), 1_000_000_000e18);
        vm.expectRevert();
        _seed();
        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        assertEq(current, 0);
        assertEq(address(bootstrap.timelock()), address(0));
        assertEq(token0.balanceOf(owner), 9_000_000e18);
    }

    function test_cannotSeedTwice() public {
        _seed();
        vm.expectRevert(CompoundingSeedBootstrap.AlreadySeeded.selector);
        _seed();
    }

    function test_outsiderDonationCannotBlockSeedOrInflateRecordedDust() public {
        token0.mint(address(bootstrap), 1000e18);
        token1.mint(address(bootstrap), 1000e18);
        _seed();
        assertEq(IERC721(address(posm)).ownerOf(bootstrap.timelock().tokenId()), address(bootstrap.timelock()));
        assertGe(token0.balanceOf(owner), 1000e18);
        assertGe(token1.balanceOf(owner), 1000e18);
    }

    function test_badRatioCannotQuietlyLeaveMostOfAllocationUnused() public {
        vm.prank(owner);
        vm.expectRevert(CompoundingSeedBootstrap.ExcessDust.selector);
        bootstrap.seed(key, _sqrtPriceX96(10e18, 1e18), 9_000_000e18, 1_000_000_000e18);
        assertEq(address(bootstrap.timelock()), address(0));
        assertEq(token1.balanceOf(owner), 1_000_000_000e18);
    }
}
