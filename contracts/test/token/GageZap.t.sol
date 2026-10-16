// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RoutersTest} from "./Routers.t.sol";
import {ReinvestRouter} from "../../src/token/ReinvestRouter.sol";
import {GageZapRouter} from "../../src/token/GageZapRouter.sol";
import {IReinvestRouter} from "../../src/interfaces/token/IReinvestRouter.sol";
import {IGageZapRouter} from "../../src/interfaces/token/IGageZapRouter.sol";

contract GageZapTest is RoutersTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    GageZapRouter internal zap;

    function setUp() public override {
        super.setUp();
        zap = new GageZapRouter(
            ReinvestRouter.Params({
                poolManager: poolManager,
                posm: posm,
                permit2: permit2,
                sgage: sgage,
                gage: gage,
                usdg: usdg,
                gageSgage: pool,
                gageEth: gageEth,
                usdgEth: usdgEth
            })
        );
        vm.prank(lp1);
        gage.approve(address(zap), type(uint256).max);
    }

    function test_gageZap_mintsAndEarnsWithoutTouchingLaunchPool() public {
        IReinvestRouter.Range memory r = _range();
        (uint160 ethPriceBefore,,,) = poolManager.getSlot0(gageEth.toId());
        (uint160 poolPriceBefore,,,) = poolManager.getSlot0(pool.toId());
        uint256 beforeGage = gage.balanceOf(lp1);
        uint256 beforeSgage = sgage.balanceOf(lp1);
        vm.prank(lp1);
        (uint256 id, uint128 l) = zap.zapGage(10e18, 5e18, r, 1, 1, block.timestamp + 60);
        assertEq(IERC721(address(posm)).ownerOf(id), lp1);
        assertGt(l, 0);
        assertGt(lpRewards.positionState(id).weight, 0);
        assertGe(sgage.balanceOf(lp1), beforeSgage, "no pre-existing sGAGE spent");
        assertLe(beforeGage - gage.balanceOf(lp1), 10e18, "bounded input");
        (uint160 ethPriceAfter,,,) = poolManager.getSlot0(gageEth.toId());
        (uint160 poolPriceAfter,,,) = poolManager.getSlot0(pool.toId());
        assertEq(ethPriceAfter, ethPriceBefore, "no GAGE/ETH swap");
        assertTrue(poolPriceAfter != poolPriceBefore, "GAGE/sGAGE swap happened");
        _assertZapEmpty();
    }

    function test_gageZap_increaseRequiresOwnershipAndApproval() public {
        IReinvestRouter.Range memory r = _range();
        vm.prank(lp1);
        (uint256 id, uint128 l) = zap.zapGage(10e18, 5e18, r, 1, 1, block.timestamp + 60);
        vm.expectRevert(abi.encodeWithSelector(IReinvestRouter.NotPositionOwner.selector, id));
        vm.prank(lp2);
        zap.increaseGageZap(id, 10e18, 5e18, 1, 1, block.timestamp + 60);
        vm.expectRevert();
        vm.prank(lp1);
        zap.increaseGageZap(id, 10e18, 5e18, 1, 1, block.timestamp + 60);
        vm.prank(lp1);
        IERC721(address(posm)).approve(address(zap), id);
        vm.prank(lp1);
        uint128 added = zap.increaseGageZap(id, 10e18, 5e18, 1, 1, block.timestamp + 60);
        assertEq(posm.getPositionLiquidity(id), l + added);
        _assertZapEmpty();
    }

    function test_gageZap_slippageDeadlineAndInputBoundsAreAtomic() public {
        IReinvestRouter.Range memory r = _range();
        uint256 beforeGage = gage.balanceOf(lp1);
        vm.startPrank(lp1);
        vm.expectRevert(ReinvestRouter.Expired.selector);
        zap.zapGage(10e18, 5e18, r, 1, 1, block.timestamp - 1);
        vm.expectRevert(IReinvestRouter.ZeroAmount.selector);
        zap.zapGage(0, 0, r, 1, 1, block.timestamp + 60);
        vm.expectRevert(IGageZapRouter.InvalidZapLimits.selector);
        zap.zapGage(10e18, 10e18, r, 1, 1, block.timestamp + 60);
        vm.expectRevert(IGageZapRouter.InvalidZapLimits.selector);
        zap.zapGage(10e18, 5e18, r, 0, 1, block.timestamp + 60);
        vm.expectRevert(IGageZapRouter.InvalidZapLimits.selector);
        zap.zapGage(10e18, 5e18, r, 1, 0, block.timestamp + 60);
        vm.expectRevert();
        zap.zapGage(10e18, 5e18, r, type(uint128).max, 1, block.timestamp + 60);
        vm.expectPartialRevert(IReinvestRouter.SlippageExceeded.selector);
        zap.zapGage(10e18, 5e18, r, 1, type(uint128).max, block.timestamp + 60);
        vm.stopPrank();
        assertEq(gage.balanceOf(lp1), beforeGage);
        _assertZapEmpty();
    }

    function testFuzz_gageZap_refundsDust(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1e12, 100e18);
        IReinvestRouter.Range memory r = _range();
        vm.prank(lp1);
        (uint256 id, uint128 l) = zap.zapGage(amount, amount / 2, r, 1, 1, block.timestamp + 60);
        assertGt(l, 0);
        assertEq(IERC721(address(posm)).ownerOf(id), lp1);
        _assertZapEmpty();
    }

    function _fundedLimits() internal pure returns (IGageZapRouter.FundedLimits memory) {
        return IGageZapRouter.FundedLimits(1, 8e18, 4e18, 1, 1);
    }

    function test_fundedZap_ETHAndUSDGMintAndIncrease() public {
        usdg.mint(lp1, 1000e6);
        vm.startPrank(lp1);
        usdg.approve(address(zap), type(uint256).max);
        uint256 gageBefore = gage.balanceOf(lp1);
        uint256 sgageBefore = sgage.balanceOf(lp1);
        (uint256 ethId, uint128 l) = zap.zapFunded{value: 0.01 ether}(
            IReinvestRouter.PayAsset.ETH, 0.01 ether, _range(), _fundedLimits(), block.timestamp + 60
        );
        assertEq(IERC721(address(posm)).ownerOf(ethId), lp1);
        assertGt(lpRewards.positionState(ethId).weight, 0);
        IERC721(address(posm)).approve(address(zap), ethId);
        uint128 added =
            zap.increaseFundedZap(ethId, IReinvestRouter.PayAsset.USDG, 30e6, _fundedLimits(), block.timestamp + 60);
        assertEq(posm.getPositionLiquidity(ethId), l + added);
        (uint256 usdId,) =
            zap.zapFunded(IReinvestRouter.PayAsset.USDG, 30e6, _range(), _fundedLimits(), block.timestamp + 60);
        assertEq(IERC721(address(posm)).ownerOf(usdId), lp1);
        assertGt(lpRewards.positionState(usdId).weight, 0);
        IERC721(address(posm)).approve(address(zap), usdId);
        zap.increaseFundedZap{value: 0.01 ether}(
            usdId, IReinvestRouter.PayAsset.ETH, 0.01 ether, _fundedLimits(), block.timestamp + 60
        );
        assertGe(gage.balanceOf(lp1), gageBefore, "no wallet GAGE spent");
        assertGe(sgage.balanceOf(lp1), sgageBefore, "no wallet sGAGE spent");
        vm.stopPrank();
        _assertZapEmpty();
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(IReinvestRouter.NotPositionOwner.selector, ethId));
        zap.increaseFundedZap{value: 0.01 ether}(
            ethId, IReinvestRouter.PayAsset.ETH, 0.01 ether, _fundedLimits(), block.timestamp + 60
        );
    }

    function test_fundedZap_valueAndEveryMinimumRevertAtomically() public {
        IReinvestRouter.Range memory r = _range();
        usdg.mint(lp1, 1000e6);
        uint256 ethBefore = lp1.balance;
        uint256 usdBefore = usdg.balanceOf(lp1);
        vm.startPrank(lp1);
        usdg.approve(address(zap), type(uint256).max);
        IGageZapRouter.FundedLimits memory limits = _fundedLimits();
        vm.expectRevert(IGageZapRouter.InvalidNativeValue.selector);
        zap.zapFunded(IReinvestRouter.PayAsset.ETH, 0.01 ether, r, limits, block.timestamp + 60);
        vm.expectRevert(IGageZapRouter.InvalidNativeValue.selector);
        zap.zapFunded{value: 1}(IReinvestRouter.PayAsset.USDG, 30e6, r, limits, block.timestamp + 60);
        vm.expectRevert(ReinvestRouter.Expired.selector);
        zap.zapFunded{value: 0.01 ether}(IReinvestRouter.PayAsset.ETH, 0.01 ether, r, limits, block.timestamp - 1);
        for (uint256 i; i < 4; i++) {
            limits = _fundedLimits();
            if (i == 0) limits.minEthOut = type(uint128).max;
            if (i == 1) limits.minGageOut = type(uint128).max;
            if (i == 2) limits.minSgageOut = type(uint128).max;
            if (i == 3) limits.minLiquidity = type(uint128).max;
            vm.expectRevert();
            zap.zapFunded(IReinvestRouter.PayAsset.USDG, 30e6, r, limits, block.timestamp + 60);
        }
        limits = _fundedLimits();
        limits.minEthOut = 0;
        vm.expectRevert(IGageZapRouter.InvalidZapLimits.selector);
        zap.zapFunded(IReinvestRouter.PayAsset.USDG, 30e6, r, limits, block.timestamp + 60);
        vm.stopPrank();
        assertEq(lp1.balance, ethBefore);
        assertEq(usdg.balanceOf(lp1), usdBefore);
        _assertZapEmpty();
    }

    function _assertZapEmpty() internal view {
        assertEq(gage.balanceOf(address(zap)), 0);
        assertEq(sgage.balanceOf(address(zap)), 0);
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }
}
