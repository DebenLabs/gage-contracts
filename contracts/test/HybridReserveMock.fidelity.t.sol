// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HybridReserveMock} from "./mocks/HybridReserveMock.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Exercise the external reserve's share precision and rounding contract.
contract HybridReserveMockFidelityTest is Test {
    MockERC20 internal usdg;
    HybridReserveMock internal reserve;

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        reserve = new HybridReserveMock(usdg);
        usdg.mint(address(this), 100e6);
        usdg.approve(address(reserve), type(uint256).max);
    }

    function _fractionalRate() internal {
        reserve.deposit(7e6, address(this));
        usdg.mint(address(reserve), 3e6 + 1);
    }

    function testEighteenDecimalSharesHaveTwelveDecimalOffset() public {
        assertEq(reserve.decimals(), 18);
        assertEq(uint256(reserve.decimals()) - usdg.decimals(), 12);
        assertEq(reserve.convertToShares(1), 1e12);
    }

    function testAccrualViewsMatchTheShareConversionInputs() public {
        reserve.deposit(7e6, address(this));
        usdg.mint(address(reserve), 3e6);
        (uint256 assets, uint256 performanceShares, uint256 managementShares) = reserve.accrueInterestView();
        assertEq(assets, 10e6);
        assertEq(performanceShares, 0);
        assertEq(managementShares, 0);
        assertEq(reserve.virtualShares(), 1e12);
        assertEq(reserve.convertToShares(1e6), 1e6 * (reserve.totalSupply() + reserve.virtualShares()) / (assets + 1));
    }

    function testZeroMaxViewsAreDefaultWhileActualLiquidityRemainsUsable() public {
        assertEq(reserve.maxDeposit(address(this)), 0);
        assertEq(reserve.maxMint(address(this)), 0);
        uint256 shares = reserve.deposit(1e6, address(this));
        assertEq(reserve.maxWithdraw(address(this)), 0);
        assertEq(reserve.maxRedeem(address(this)), 0);
        uint256 beforeCash = usdg.balanceOf(address(this));
        reserve.redeem(shares, address(this), address(this));
        assertEq(usdg.balanceOf(address(this)) - beforeCash, 1e6);
    }

    function testDepositRoundsSharesDownToTheLargestAffordableShareAmount() public {
        _fractionalRate();
        uint256 assets = 1e6;
        uint256 quotedShares = reserve.previewDeposit(assets);
        assertLe(reserve.previewMint(quotedShares), assets);
        assertGt(reserve.previewMint(quotedShares + 1), assets);
        uint256 beforeShares = reserve.balanceOf(address(this));
        uint256 actualShares = reserve.deposit(assets, address(this));
        assertEq(actualShares, quotedShares);
        assertEq(reserve.balanceOf(address(this)) - beforeShares, actualShares);
    }

    function testRedeemRoundsAssetsDownWithoutPayingForTheNextAssetUnit() public {
        _fractionalRate();
        uint256 shares = reserve.balanceOf(address(this)) / 3 + 7;
        uint256 quotedAssets = reserve.previewRedeem(shares);
        assertLe(reserve.previewWithdraw(quotedAssets), shares);
        assertGt(reserve.previewWithdraw(quotedAssets + 1), shares);
        uint256 beforeCash = usdg.balanceOf(address(this));
        uint256 actualAssets = reserve.redeem(shares, address(this), address(this));
        assertEq(actualAssets, quotedAssets);
        assertEq(usdg.balanceOf(address(this)) - beforeCash, actualAssets);
    }

    function testWithdrawRoundsSharesUpToCoverEveryRequestedAssetUnit() public {
        _fractionalRate();
        uint256 assets = 1e6;
        uint256 quotedShares = reserve.previewWithdraw(assets);
        assertGe(reserve.previewRedeem(quotedShares), assets);
        assertLt(reserve.previewRedeem(quotedShares - 1), assets);
        uint256 beforeShares = reserve.balanceOf(address(this));
        uint256 beforeCash = usdg.balanceOf(address(this));
        uint256 actualShares = reserve.withdraw(assets, address(this), address(this));
        assertEq(actualShares, quotedShares);
        assertEq(beforeShares - reserve.balanceOf(address(this)), actualShares);
        assertEq(usdg.balanceOf(address(this)) - beforeCash, assets);
    }
}
