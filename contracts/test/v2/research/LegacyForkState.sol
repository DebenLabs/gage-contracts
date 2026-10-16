// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDealVault} from "../../../src/interfaces/IDealVault.sol";
import {ICollateralRegistry} from "../../../src/interfaces/ICollateralRegistry.sol";
import {CollateralRegistry} from "../../../src/CollateralRegistry.sol";
import {DealRewards} from "../../../src/token/DealRewards.sol";
import {Emissions} from "../../../src/token/Emissions.sol";
import {Collateral, Kind} from "../../../src/types/Types.sol";

/// @dev Research fixtures only. Mainnet has moved on since the legacy research suites were written: the legacy
///      registry has closed direct listings, the rewards owner has posted zero loan rates for later epochs, and the
///      current epoch's loan budget is no longer spent. These helpers restore that state on the local fork. Only the
///      two owners' calls are simulated and only collateral and USDG capital are dealt. No sGAGE is minted and no
///      protocol storage is written.
abstract contract LegacyForkState is Test {
    CollateralRegistry internal constant LEGACY_REGISTRY =
        CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);

    /// @dev Allow direct legacy listings of `token` again, with the lane and limits the registry still records for it.
    function _readmitLegacy(address token) internal {
        ICollateralRegistry.ERC20Config memory c = LEGACY_REGISTRY.getERC20Config(token);
        vm.prank(LEGACY_REGISTRY.owner());
        LEGACY_REGISTRY.setERC20Allowed(token, true, c.lane, c.minAmount, c.maxDealRaw, c.maxOpenRaw);
    }

    /// @dev Post for `epoch` the latest positive rates, as an unset epoch carried them forward when these suites were
    ///      written. Positive rates already in force for `epoch` are left as they are.
    function _carryLegacyRates(DealRewards rewards, uint256 epoch) internal {
        DealRewards.EpochRates memory r = rewards.effectiveRates(epoch);
        if (r.rate7 != 0 && r.rate21 != 0) return;
        for (uint256 e = epoch; e != 0 && (r.rate7 == 0 || r.rate21 == 0);) {
            r = rewards.effectiveRates(--e);
        }
        vm.prank(rewards.owner());
        rewards.setEpochRates(epoch, r.rate7, r.rate21, r.priceUSDGPerSGAGE, r.lenderShareBps);
    }

    /// @dev Spend what is left of the current epoch's `term` loan budget, as ordinary loan activity would: one real
    ///      legacy deal of an admitted `token`, listed, funded and registered. Its asking price doubles until the
    ///      legacy reward quote for its fee is bound by the budget rather than by the posted rate.
    function _exhaustCurrentLoanBudget(IDealVault vault, DealRewards rewards, address token, address usdg, uint32 term)
        internal
    {
        Emissions emissions = Emissions(address(rewards.EMISSIONS()));
        uint256 epoch = emissions.currentEpoch();
        if (emissions.remaining(epoch, term) == 0) return;
        _carryLegacyRates(rewards, epoch);
        uint128 feeBps = LEGACY_REGISTRY.feeBps();
        uint128 price = 100e6;
        (,, bool available,) = rewards.quote(term, price * feeBps / 10_000);
        while (available) {
            price *= 2;
            (,, available,) = rewards.quote(term, price * feeBps / 10_000);
        }
        address borrower = makeAddr("budget borrower");
        address lender = makeAddr("budget lender");
        uint256 amount = LEGACY_REGISTRY.getERC20Config(token).minAmount;
        deal(token, borrower, amount);
        deal(usdg, lender, price);
        vm.startPrank(borrower);
        IERC20(token).approve(address(vault), amount);
        uint256 id = vault.list(Collateral(Kind.ERC20, token, amount), price, term, 0, price);
        vm.stopPrank();
        vm.startPrank(lender);
        IERC20(usdg).approve(address(vault), price);
        vault.fund(id, lender);
        vm.stopPrank();
        rewards.register(id);
        assertEq(emissions.remaining(epoch, term), 0);
    }
}
