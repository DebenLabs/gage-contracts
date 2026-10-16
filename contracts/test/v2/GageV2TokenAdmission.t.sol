// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2VaultTest} from "./GageV2Vault.t.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2CollateralValidator} from "../../src/v2/GageV2CollateralValidator.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {V2Loan} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @notice Token-only engines (D35): the core validates its collateral itself (the former `GageV2TokenValidator`,
/// folded in by CORE-b-20), so it admits individual tokens exactly as the full validator does and never a liquidity
/// position. The inherited suite runs every token case on that engine.
contract GageV2TokenAdmissionTest is GageV2VaultTest {
    /// @dev The full validator, to compare token admission with. It reads only the legacy registry (the release's
    /// core runs on the fixture's `GageV2TokenRegistry`), so `legacy` holds the same terms and token admission.
    GageV2CollateralValidator internal full;
    GageV2Registry internal legacy;

    function setUp() public override {
        super.setUp();
        legacy = new GageV2Registry(address(this), registry.allowedTerms(), address(this));
        // The fixture admits the stock on the core's registry from 1 raw unit up to type(uint128).max per loan.
        legacy.setERC20Allowed(address(stock), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        full = new GageV2CollateralValidator(legacy, address(usdg), address(sgage), address(0), address(0));
    }

    /// @dev The same stock admission on the core's registry and on the full validator's.
    function _admit(uint256 minAmount, uint256 maxDealRaw, uint256 maxOpenRaw) internal {
        registry.setERC20Allowed(address(stock), true, Lane.STOCK, minAmount, maxDealRaw, maxOpenRaw);
        legacy.setERC20Allowed(address(stock), true, Lane.STOCK, minAmount, maxDealRaw, maxOpenRaw);
    }

    function _listing(Collateral memory c) internal returns (uint256) {
        vm.prank(borrower);
        return vault.list(c, 1000e6, 1100e6, TERM, uint40(block.timestamp + 1 days), true);
    }

    function test_theEngineNamesItsRegistryAndTokens() public view {
        assertEq(address(vault.REGISTRY()), address(registry));
        assertEq(address(vault.USDG()), address(usdg));
        assertEq(address(vault.SGAGE()), address(sgage));
    }

    /// @dev The core's refusal keeps the validator's selector, so its revert data is unchanged.
    function test_theRefusalKeepsTheValidatorSelector() public pure {
        assertEq(GageV2Vault.InvalidCollateral.selector, GageV2CollateralValidator.InvalidCollateral.selector);
        assertEq(GageV2Vault.InvalidCollateral.selector, bytes4(keccak256("InvalidCollateral()")));
    }

    /// @dev Same exposure bucket and amount as the full validator, and the same aggregate ceiling.
    function test_tokenAdmissionMatchesTheFullValidator() public {
        _admit(1, 100e18, 150e18);
        Collateral memory c = Collateral(Kind.ERC20, address(stock), 100e18);
        (bytes32 fullKey, uint256 fullRaw, uint256 fullMaximum) = full.validate(c, borrower);
        V2Loan memory l = vault.getLoan(_listing(c));
        assertEq(l.exposureKey, fullKey);
        assertEq(l.exposureAmount, fullRaw);
        assertEq(vault.openExposure(fullKey), fullRaw);
        // The ceiling is the full validator's maximum: 150 admits 100 + 50 and not one raw unit more.
        assertEq(fullMaximum, 150e18);
        vm.expectRevert(GageV2Vault.ExposureCap.selector);
        _listing(Collateral(Kind.ERC20, address(stock), 50e18 + 1));
        _listing(Collateral(Kind.ERC20, address(stock), 50e18));
        assertEq(vault.openExposure(fullKey), fullMaximum);
    }

    function test_refusesEveryLiquidityPositionKind() public {
        address[3] memory managers = [makeAddr("v4 position manager"), makeAddr("v3 position manager"), address(stock)];
        for (uint256 i; i < managers.length; ++i) {
            vm.expectRevert(GageV2Vault.InvalidCollateral.selector);
            _listing(Collateral(Kind.UNIV4_POSITION, managers[i], 1));
            vm.expectRevert(GageV2Vault.InvalidCollateral.selector);
            _listing(Collateral(Kind.UNIV3_POSITION, managers[i], 1));
        }
        assertEq(vault.loanCount(), 0);
    }

    function test_refusesTokensOutsideTheirAdmission() public {
        // The fixture admits the stock from 1 raw unit up to type(uint128).max per loan.
        Collateral[5] memory refused = [
            Collateral(Kind.ERC20, address(0), 1e18),
            Collateral(Kind.ERC20, address(sgage), 1e18),
            Collateral(Kind.ERC20, makeAddr("unadmitted token"), 1e18),
            Collateral(Kind.ERC20, address(stock), 0),
            Collateral(Kind.ERC20, address(stock), type(uint256).max)
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(GageV2Vault.InvalidCollateral.selector);
            _listing(refused[i]);
        }
        assertEq(vault.loanCount(), 0);
    }

    function test_theEngineRefusesAnLPListing() public {
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.InvalidCollateral.selector);
        vault.list(
            Collateral(Kind.UNIV4_POSITION, makeAddr("v4 position manager"), 1),
            1000e6,
            1100e6,
            TERM,
            uint40(block.timestamp + 1 days),
            true
        );
        assertEq(vault.loanCount(), 0);
    }

    /// @dev Activation re-validates the recorded collateral against the registry: an admission withdrawn while the
    /// loan funds refuses its fourth unit with the same selector.
    function test_activationRefusesACollateralNoLongerAdmitted() public {
        uint256 id = _listing(Collateral(Kind.ERC20, address(stock), 100e18));
        for (uint8 i; i < 3; ++i) {
            vm.prank(lender[i]);
            vault.fund(id, 1);
        }
        registry.setERC20Allowed(address(stock), false, Lane.STOCK, 0, 0, 0);
        vm.prank(lender[3]);
        vm.expectRevert(GageV2Vault.InvalidCollateral.selector);
        vault.fund(id, 1);
    }
}
