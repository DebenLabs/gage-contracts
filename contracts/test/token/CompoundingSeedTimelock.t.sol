// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CompoundingSeedTimelock} from "../../src/token/CompoundingSeedTimelock.sol";
import {TokenLayerFixture} from "./TokenLayerFixture.sol";

contract CompoundingSeedTimelockTest is TokenLayerFixture {
    // Keep the legacy indexer's event layout compatible with the new custody contract.
    event Released(uint256 indexed tokenId, address to);

    CompoundingSeedTimelock internal compoundLock;

    function setUp() public override {
        super.setUp();
        compoundLock = new CompoundingSeedTimelock(posm, IAllowanceTransfer(address(permit2)), treasury, treasury);
        vm.startPrank(treasury);
        IERC721(address(posm)).approve(address(compoundLock), seedId);
        compoundLock.lock(seedId);
        vm.stopPrank();
    }

    function _fees() internal {
        _swap(pool, Currency.unwrap(pool.currency0) == address(gage), -int256(100e18), lp2);
        _swap(pool, Currency.unwrap(pool.currency0) == address(sgage), -int256(100_000e18), lp2);
    }

    function _compound() internal returns (uint128 added) {
        (uint160 price,, uint128 quote,,) = compoundLock.previewCompound();
        vm.prank(treasury);
        added = compoundLock.compound(price, quote, block.timestamp + 60);
    }

    function test_realFeesIncreaseSameNftWithoutPayoutOrExtendingLock() public {
        _fees();
        uint256 beforeGage = gage.balanceOf(treasury);
        uint256 beforeSgage = sgage.balanceOf(treasury);
        uint40 unlock = compoundLock.releaseAt();
        uint128 beforeLiq = posm.getPositionLiquidity(seedId);
        (,, uint128 quote, uint256 a0, uint256 a1) = compoundLock.previewCompound();
        assertGt(a0, 0);
        assertGt(a1, 0);
        uint128 added = _compound();
        assertEq(added, quote, "view fee accounting matches collection");
        assertGt(added, 0);
        assertEq(posm.getPositionLiquidity(seedId), beforeLiq + added);
        assertEq(IERC721(address(posm)).ownerOf(seedId), address(compoundLock));
        assertEq(compoundLock.releaseAt(), unlock);
        assertEq(gage.balanceOf(treasury), beforeGage);
        assertEq(sgage.balanceOf(treasury), beforeSgage);
        assertEq(lpRewards.positionState(seedId).weight, 0, "compounded seed remains excluded from emissions");
        assertEq(gage.allowance(address(compoundLock), address(permit2)), 0);
        assertEq(sgage.allowance(address(compoundLock), address(permit2)), 0);
        (uint160 permitAmount,,) = permit2.allowance(address(compoundLock), address(gage), address(posm));
        assertEq(permitAmount, 0);
    }

    function test_oneSidedFeesWaitThenCompoundAndCarrySurplus() public {
        _swap(pool, Currency.unwrap(pool.currency0) == address(gage), -int256(200e18), lp2);
        (uint160 price,, uint128 quote,,) = compoundLock.previewCompound();
        assertEq(quote, 0);
        vm.prank(treasury);
        vm.expectRevert(CompoundingSeedTimelock.InsufficientLiquidity.selector);
        compoundLock.compound(price, 1, block.timestamp + 60);
        _swap(pool, Currency.unwrap(pool.currency0) == address(sgage), -int256(10_000e18), lp2);
        _compound();
        assertGt(gage.balanceOf(address(compoundLock)), 0, "unmatched fees retained");
        uint40 unlock = compoundLock.releaseAt();
        vm.warp(block.timestamp + 1 days);
        _fees();
        uint128 added = _compound();
        assertGt(added, 0);
        assertEq(compoundLock.releaseAt(), unlock);
    }

    function test_rejectsUnauthorizedCallerAndLockHijack() public {
        vm.expectRevert(CompoundingSeedTimelock.Unauthorized.selector);
        compoundLock.compound(1, 1, block.timestamp + 60);
        CompoundingSeedTimelock empty = new CompoundingSeedTimelock(posm, permit2, treasury, treasury);
        vm.expectRevert(CompoundingSeedTimelock.Unauthorized.selector);
        empty.lock(seedId);
    }

    function test_expiredOverlongAndZeroQuotesRejected() public {
        _fees();
        (uint160 price,, uint128 quote,,) = compoundLock.previewCompound();
        vm.startPrank(treasury);
        vm.expectRevert(CompoundingSeedTimelock.InvalidQuote.selector);
        compoundLock.compound(price, quote, block.timestamp - 1);
        vm.expectRevert(CompoundingSeedTimelock.InvalidQuote.selector);
        compoundLock.compound(price, quote, block.timestamp + 121);
        vm.expectRevert(CompoundingSeedTimelock.InvalidQuote.selector);
        compoundLock.compound(price, 0, block.timestamp + 60);
        vm.stopPrank();
    }

    function test_priceMovementAndMinimumLiquidityRevertAtomically() public {
        _fees();
        (uint160 price,, uint128 quote,,) = compoundLock.previewCompound();
        vm.startPrank(treasury);
        vm.expectRevert(CompoundingSeedTimelock.PriceMoved.selector);
        compoundLock.compound(price / 2, quote, block.timestamp + 60);
        vm.expectRevert(CompoundingSeedTimelock.InsufficientLiquidity.selector);
        compoundLock.compound(price, quote + 1, block.timestamp + 60);
        vm.stopPrank();
        assertEq(gage.balanceOf(address(compoundLock)), 0);
        assertEq(sgage.balanceOf(address(compoundLock)), 0);
        (,, uint128 afterQuote,,) = compoundLock.previewCompound();
        assertEq(afterQuote, quote, "failed collection rolled back");
    }

    function test_yearUnlockIncludesCompoundedPrincipalAndRetainedFees() public {
        _fees();
        _compound();
        uint128 liquidity = posm.getPositionLiquidity(seedId);
        vm.prank(treasury);
        gage.transfer(address(compoundLock), 1e18);
        uint256 walletBefore = gage.balanceOf(treasury);
        uint256 retained = gage.balanceOf(address(compoundLock));
        vm.warp(compoundLock.releaseAt() - 1);
        vm.expectRevert(CompoundingSeedTimelock.StillLocked.selector);
        compoundLock.release();
        vm.warp(compoundLock.releaseAt());
        vm.expectEmit(true, false, false, true, address(compoundLock));
        emit Released(seedId, treasury);
        compoundLock.release();
        assertEq(IERC721(address(posm)).ownerOf(seedId), treasury);
        assertEq(posm.getPositionLiquidity(seedId), liquidity);
        assertEq(gage.balanceOf(treasury), walletBefore + retained);
        assertEq(gage.balanceOf(address(compoundLock)), 0);
        assertEq(sgage.balanceOf(address(compoundLock)), 0);
        vm.expectRevert(CompoundingSeedTimelock.Inactive.selector);
        compoundLock.release();
    }
}
