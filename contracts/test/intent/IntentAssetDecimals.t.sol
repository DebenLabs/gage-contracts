// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IntentAccountingBaseTest} from "./IntentAccountingBase.t.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";
import {IntentLimit, INTENT_MAX_LOAN_PRINCIPAL} from "../../src/intent/IntentVaultState.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";

/// @notice A partner vault's money paths at its lent asset's decimals: USDG's six, and a stock token's eighteen. Every
/// amount is written in whole units of the asset, so each case asserts the same numbers at both.
abstract contract IntentAssetDecimalsTest is IntentAccountingBaseTest {
    function _one() internal pure returns (uint256) {
        return 10 ** _cashDecimals();
    }

    /// @dev 100 NVDA for `principal`, repaid with `cap` within 21 days, listed without sGAGE rewards (a generation that
    /// lends another asset sets its own reward terms).
    function _listPlain(uint128 principal, uint128 cap) internal returns (uint256 id) {
        vm.prank(borrower);
        id = core.list(
            Collateral(Kind.ERC20, address(nvda), 100e18), principal, cap, T21, uint40(block.timestamp + 1 days), false
        );
    }

    function test_aWholeUnitStartsWorthOneShare() public {
        uint256 shares = _enter(alice, 1000 * _one());
        assertEq(shares, 1000e18);
        assertEq(partner.convertToShares(_one()), 1e18);
        assertEq(partner.convertToAssets(shares), 1000 * _one());
        assertEq(_exitAll(alice), 1000 * _one());
    }

    function test_theSmallestDepositIsOneWholeUnit() public {
        vm.prank(alice);
        vm.expectRevert(IntentVault.InvalidAmount.selector);
        partner.deposit(_one() - 1, 0);
        assertEq(_enter(alice, _one()), 1e18);
    }

    /// @dev Past the smallest deposit any amount is taken, whole units or not: 1.3 units mint 1.3e18 shares.
    function test_aDepositNeedNotBeWholeUnits() public {
        uint256 amount = 13 * _one() / 10;
        assertEq(_enter(alice, amount), 1.3e18);
        assertEq(_exitAll(alice), amount);
    }

    /// @dev `MAX_SUPPLY` is 10^9 whole units at the first price, whatever the decimals.
    function test_sharesStopAtOneBillionWholeUnits() public {
        uint256 billion = 1_000_000_000 * _one();
        usdg.mint(alice, billion);
        assertEq(_enter(alice, billion), 1e27);
        vm.prank(alice);
        vm.expectRevert(IntentVault.LimitExceeded.selector);
        partner.deposit(_one(), 0);
    }

    /// @dev The most per loan is bounded at one billion whole units, at creation and through the asset policy.
    function test_thePerLoanBoundIsOneBillionWholeUnits() public {
        uint256 bound = 1_000_000_000 * _one();
        assertEq(bound, uint256(INTENT_MAX_LOAN_PRINCIPAL) * _cashScale());
        IntentVault.Mandate memory m = mandate;
        m.maxLoanPrincipal = uint128(bound + 1);
        vm.prank(curator);
        vm.expectRevert(IntentFactory.VaultCreationFailed.selector);
        partnerFactory.create(m, false, 0, "Over the bound");
        m.maxLoanPrincipal = uint128(bound);
        vm.prank(curator);
        IntentVault atBound = IntentVault(partnerFactory.create(m, false, 0, "At the bound"));
        assertEq(atBound.maxLoanPrincipal(), bound);
        IntentAssetPolicy policy = atBound.ASSET_POLICY();
        vm.startPrank(curator);
        vm.expectRevert(IntentAssetPolicy.InvalidConfiguration.selector);
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, uint128(bound + 1));
        policy.setLimit(IntentLimit.MAX_LOAN_PRINCIPAL, uint128(bound));
        vm.stopPrank();
        assertEq(atBound.maxLoanPrincipal(), bound);
    }

    /// @dev 1,000 lent for a 100 fixed cost, repaid in the term's last second (repayment closes at its end, D106): the
    /// holder leaves with the 90 left after the 10% fee.
    function test_aLoanRepaidAtTermPaysTheSameWholeUnits() public {
        _enter(alice, 2000 * _one());
        uint256 id = _listPlain(uint128(1000 * _one()), uint128(1100 * _one()));
        _route(id, UNITS);
        vm.warp(_startOf(id) + T21 - 1);
        _repay(id);
        _book(id);
        assertApproxEqAbs(_leave(alice), 2090 * _one(), 2 * _cashScale());
    }

    /// @dev Repaid at half term: the share price has booked half the return, and the rest is the holders' claim through
    /// the exposure clock (D51). The holder leaves with the same 90.
    function test_anEarlyRepaymentPaysTheSameWholeUnits() public {
        _enter(alice, 2000 * _one());
        uint256 id = _listPlain(uint128(1000 * _one()), uint128(1100 * _one()));
        _route(id, UNITS);
        vm.warp(_startOf(id) + T21 / 2);
        _repay(id);
        _book(id);
        assertApproxEqAbs(_leave(alice), 2090 * _one(), 3 * _cashScale());
    }

    /// @dev The exposure clock keeps running over a year with one whole unit outstanding and a year with none.
    function test_theExposureClockRunsOverAnEmptyVault() public {
        vm.warp(1_000_000);
        uint256 shares = _enter(alice, _one());
        vm.warp(1_000_000 + 365 days);
        _exit(alice, shares);
        vm.warp(1_000_000 + 730 days);
        assertGt(_enter(bob, _one()), 0);
        vm.warp(1_000_000 + 731 days);
        assertGt(_exitAll(bob), 0);
    }
}

contract IntentAssetDecimalsSixTest is IntentAssetDecimalsTest {}

contract IntentAssetDecimalsEighteenTest is IntentAssetDecimalsTest {
    function _cashDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
