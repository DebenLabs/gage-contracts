// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnV3BaseTest} from "./EarnV3Base.t.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {V2State} from "../../src/v2/V2Types.sol";

/// @notice The curator's bounds on one fill (D153): the cap per listing, the cap per collateral token and the
/// free-liquidity buffer.
contract EarnVaultLimitsTest is EarnV3BaseTest {
    function _limits(uint128 loan, uint16 asset, uint16 buffer) internal {
        vm.prank(curator);
        earn.setLimits(loan, asset, buffer);
    }

    function testLimitsAreTheCuratorsBoundedAndEmitted() public {
        assertEq(earn.maxLoanPrincipal(), 0, "no cap at creation");
        assertEq(earn.maxAssetBps(), 0);
        assertEq(earn.bufferBps(), 0);
        vm.prank(alice);
        vm.expectRevert(EarnVault.NotCurator.selector);
        earn.setLimits(1, 1, 1);
        vm.prank(curator);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setLimits(0, 10_001, 0);
        vm.prank(curator);
        vm.expectRevert(EarnVault.InvalidConfiguration.selector);
        earn.setLimits(0, 0, 10_001);
        vm.prank(curator);
        vm.expectEmit(true, true, true, true, address(earn));
        emit EarnVault.LimitsSet(600e6, 3000, 2000);
        earn.setLimits(600e6, 3000, 2000);
        assertEq(earn.maxLoanPrincipal(), 600e6);
        assertEq(earn.maxAssetBps(), 3000);
        assertEq(earn.bufferBps(), 2000);
    }

    function testTheCapPerListingCountsEveryFillOfThatListing() public {
        _deposit(alice, 10_000e6);
        _limits(600e6, 0, 0);
        uint256 id = _listed(1000e6);
        _fund(id, 2); // 500 of the 600 cap
        assertEq(_loan(id).principal, 500e6);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        _fund(id, 1); // 750 would pass a per-fill cap; the cap is per listing
        uint256 within = _listed(600e6);
        _fund(within, UNITS); // exactly at the cap
        uint256 over = _listed(601e6);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        _fund(over, UNITS);
        _fund(over, 2); // half of it is 300.5, under the cap
        _limits(0, 0, 0); // zero lifts the cap: the first listing completes
        _fund(id, 2);
        assertEq(_state(id) == V2State.ACTIVE, true);
    }

    function testTheCapPerAssetIsAShareOfAssetsAndFallsAsLoansSettle() public {
        _deposit(alice, 10_000e6);
        _limits(0, 3000, 0); // 3,000 per token
        uint256 first = _listed(2000e6);
        _fund(first, UNITS);
        assertEq(earn.assetPrincipal(address(nvda)), 2000e6);
        uint256 second = _listed(1500e6);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        _fund(second, UNITS); // 3,500 of NVDA
        _fund(second, 2); // 750 more: 2,750
        uint256 memeId = _list(borrower, address(meme), 100e18, 1500e6, 1575e6, T7);
        _fund(memeId, UNITS); // another token, its own cap
        assertEq(earn.assetPrincipal(address(meme)), 1500e6);
        // The first loan repays and the half-bought second misses its deadline: both settle and NVDA exposure
        // falls to nothing, so a fresh NVDA listing takes the whole cap again.
        vm.warp(_maturity(first) - 1);
        _repay(first);
        _settle(first);
        assertEq(earn.assetPrincipal(address(nvda)), 750e6, "the open commitment still counts");
        _settle(second);
        assertEq(earn.assetPrincipal(address(nvda)), 0);
        assertEq(_state(second) == V2State.CANCELLED, true);
        uint256 assets = earn.totalAssets();
        uint128 whole = uint128(assets * 3000 / 10_000);
        uint256 over = _listed(whole + 1);
        vm.expectRevert(EarnVault.IneligibleDeal.selector);
        _fund(over, UNITS);
        uint256 third = _listed(whole);
        _fund(third, UNITS);
        assertEq(earn.assetPrincipal(address(nvda)), whole);
    }

    function testAWriteOffReleasesTheAssetExposureToo() public {
        _deposit(alice, 10_000e6);
        uint256 id = _funded(1000e6);
        assertEq(earn.assetPrincipal(address(nvda)), 1000e6);
        vm.warp(_maturity(id));
        _settle(id);
        assertEq(_state(id) == V2State.DEFAULTED, true);
        assertEq(earn.assetPrincipal(address(nvda)), 0);
        assertEq(earn.lanePrincipal(EarnLane.STOCK), 0);
    }

    function testTheBufferKeepsAShareOfAssetsLiquidAndCountsTheReserve() public {
        _deposit(alice, 10_000e6);
        _limits(0, 0, 2000); // 2,000 must stay liquid
        uint256 big = _listed(8000e6);
        vm.prank(curator);
        earn.setMaxTotalDeposits(type(uint128).max);
        // Lane weight 60% of stocks would refuse 8,000; open the lane for the buffer to be the binding bound.
        vm.prank(curator);
        earn.setLaneWeight(_loanLane(), 10_000);
        _fund(big, UNITS); // free liquidity 2,000, exactly the buffer
        uint256 one = _listed(4e6);
        vm.expectRevert(EarnVault.InsufficientLiquidity.selector);
        _fund(one, 1);
        // The reserve counts as liquidity: moving cash there changes nothing for the buffer.
        _limits(0, 0, 1000);
        vm.prank(curator);
        earn.investReserve(1000e6, 0);
        _fund(one, 1);
        assertEq(earn.freeLiquidity(), 1999e6);
    }

    function _loanLane() internal pure returns (EarnLane) {
        return EarnLane.STOCK;
    }
}
