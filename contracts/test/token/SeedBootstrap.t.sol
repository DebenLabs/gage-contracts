// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SeedBootstrap} from "../../src/token/SeedBootstrap.sol";
import {SeedTimelock} from "../../src/token/SeedTimelock.sol";
import {ISeedTimelock} from "../../src/interfaces/token/ISeedTimelock.sol";
import {RehearsalLaunch} from "../../script/rehearsal/RehearsalLaunch.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract SeedBootstrapTest is V4Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal owner = makeAddr("owner");
    MockERC20 internal token0;
    MockERC20 internal token1;
    SeedBootstrap internal bootstrap;
    PoolKey internal key;
    uint160 internal price;

    function setUp() public {
        _deployV4();
        MockERC20 a = new MockERC20("a", "a", 18);
        MockERC20 b = new MockERC20("b", "b", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 30_000, 60, IHooks(address(0)));
        price = _sqrtPriceX96(1_000_000_000e18, 9_000_000e18);
        bootstrap = new SeedBootstrap(owner, posm, permit2);
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
        SeedTimelock lock = bootstrap.timelock();
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
        vm.expectRevert(abi.encodeWithSelector(ISeedTimelock.StillLocked.selector, uint40(lockedAt + 365 days)));
        lock.release();
        vm.warp(lockedAt + 365 days);
        lock.release();
        assertEq(IERC721(address(posm)).ownerOf(id), owner);
    }

    function test_outsiderCannotChooseTheFirstSeed() public {
        vm.expectRevert(SeedBootstrap.NotOwner.selector);
        bootstrap.seed(key, price, 9_000_000e18, 1_000_000_000e18);
        assertEq(address(bootstrap.timelock()), address(0));
    }

    function test_existingWrongPriceFailsBeforeTakingTokens() public {
        poolManager.initialize(key, price + 1);
        vm.expectRevert(SeedBootstrap.UnexpectedPoolState.selector);
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
        vm.expectRevert(SeedBootstrap.AlreadySeeded.selector);
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
        vm.expectRevert(SeedBootstrap.ExcessDust.selector);
        bootstrap.seed(key, _sqrtPriceX96(10e18, 1e18), 9_000_000e18, 1_000_000_000e18);
        assertEq(address(bootstrap.timelock()), address(0));
        assertEq(token1.balanceOf(owner), 1_000_000_000e18);
    }

    function test_mockLaunchActuallyBuysAndSeparatelyRedirectsCreatorFees() public {
        vm.chainId(46_630);
        RehearsalLaunch venue = new RehearsalLaunch(owner, posm, permit2);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        venue.launch{value: 0.11 ether}();
        assertGt(venue.purchased(), 8_000_000e18);
        assertEq(venue.token().balanceOf(owner), venue.purchased());
        assertEq(venue.token().totalSupply(), 1_000_000_000e18);
        address recipient = makeAddr("splitter");
        vm.prank(owner);
        venue.transferCreatorFeeRecipient(recipient);
        venue.claimCreatorFees();
        assertEq(recipient.balance, 0.0001 ether);
        assertEq(venue.creatorFees(), 0);
        vm.prank(owner);
        vm.expectRevert();
        venue.launch{value: 0.11 ether}();
    }

    function test_mockVenueRefusesMainnet() public {
        vm.chainId(4663);
        vm.expectRevert("TESTNET ONLY");
        new RehearsalLaunch(owner, posm, permit2);
    }
}
