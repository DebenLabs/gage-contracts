// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {TestnetV2Registry} from "../../src/testnet/TestnetV2Registry.sol";
import {TestnetOnly} from "../../src/testnet/TestnetOnly.sol";
import {V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {cashOwed} from "../helpers/CoreCash.sol";

using {cashOwed} for GageV2Vault;

/// @notice The S9C testnet registry: 5- and 20-minute terms beside 7 and 21 days, so a loan runs through funding,
///         maturity and settlement in minutes on testnet 46630. Mainnet can never deploy it.
contract TestnetV2RegistryTest is Test {
    uint32 internal constant FIVE_MINUTES = 300;
    uint32 internal constant TWENTY_MINUTES = 1200;
    TestnetV2Registry internal testnetRegistry;

    function _qaTerms() internal pure returns (uint32[] memory terms) {
        terms = new uint32[](4);
        (terms[0], terms[1], terms[2], terms[3]) = (FIVE_MINUTES, TWENTY_MINUTES, 7 days, 21 days);
    }

    function _productionTerms() internal pure returns (uint32[] memory terms) {
        terms = new uint32[](2);
        (terms[0], terms[1]) = (7 days, 21 days);
    }

    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal stock;
    GageV2Vault internal vault;
    address internal borrower = makeAddr("borrower");
    address internal fees = makeAddr("fees");
    address[4] internal lender;

    function setUp() public {
        vm.warp(10_000);
        usdg = new MockERC20("test USDG", "tUSDG", 6);
        sgage = new MockERC20("test sGAGE", "tsGAGE", 18);
        stock = new MockERC20("test stock", "tSTOCK", 18);
        // The S9C shape: deployed with the production terms, then widened by the owner.
        testnetRegistry = new TestnetV2Registry(address(this), _productionTerms(), address(this));
        testnetRegistry.setTestnetTerms(_qaTerms());
        testnetRegistry.setERC20Allowed(address(stock), true, Lane.STOCK, 1, type(uint128).max, type(uint256).max);
        vault = new GageV2Vault(
            GageV2TokenRegistry(address(testnetRegistry)),
            IERC20(address(usdg)),
            IERC20(address(sgage)),
            fees,
            0,
            GageLegacyAdapter(address(0))
        );
        // An engine lends to no one until a funder gate is bound (D47); these wallets stand in for vaults.
        vm.prank(makeAddr("open funder gate"));
        MockOpenFunderGate openGate = new MockOpenFunderGate();
        vault.REWARDS().bindFunderGate(openGate);
        for (uint8 i; i < 4; ++i) {
            lender[i] = makeAddr(string(abi.encodePacked("lender", i)));
            usdg.mint(lender[i], 1_000_000e6);
            vm.prank(lender[i]);
            usdg.approve(address(vault), type(uint256).max);
        }
        usdg.mint(borrower, 1_000_000e6);
        stock.mint(borrower, 1_000_000e18);
        vm.startPrank(borrower);
        usdg.approve(address(vault), type(uint256).max);
        stock.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The core holds exactly what it owes this suite's accounts, plus the contributions of loans still funding.
    function _assertCash() internal view {
        address[] memory holders = new address[](6);
        (holders[0], holders[1]) = (borrower, fees);
        for (uint256 i; i < 4; ++i) {
            holders[2 + i] = lender[i];
        }
        assertEq(usdg.balanceOf(address(vault)), vault.cashOwed(holders));
    }

    function _listFor(uint32 term) internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(
            Collateral(Kind.ERC20, address(stock), 100e18),
            1000e6,
            1100e6,
            term,
            uint40(block.timestamp + 1 days),
            false
        );
        for (uint8 i; i < 4; ++i) {
            vm.prank(lender[i]);
            vault.fund(id, 1);
        }
    }

    function test_allowsMinuteTermsBesideTheProductionTerms() public view {
        uint32[] memory terms = testnetRegistry.allowedTerms();
        assertEq(terms.length, 4);
        for (uint256 i; i < terms.length; ++i) {
            assertTrue(testnetRegistry.isTermAllowed(_qaTerms()[i]));
            assertEq(terms[i], _qaTerms()[i]);
        }
        assertFalse(testnetRegistry.isTermAllowed(60));
        (uint256 rate,,) = testnetRegistry.rewardTerms(FIVE_MINUTES);
        assertEq(rate, 0, "minute terms carry no sGAGE reward");
    }

    function test_theProductionRegistryRefusesMinuteTerms() public {
        GageV2Registry production = new GageV2Registry(address(this), _productionTerms(), address(this));
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.TermOutOfBounds.selector, FIVE_MINUTES));
        production.setTerms(_qaTerms());
    }

    function test_onlyTheOwnerSetsTestnetTerms() public {
        vm.prank(borrower);
        vm.expectRevert();
        testnetRegistry.setTestnetTerms(_qaTerms());
    }

    function test_refusesZeroDuplicateAndTooManyTerms() public {
        uint32[] memory bad = new uint32[](2);
        (bad[0], bad[1]) = (FIVE_MINUTES, 0);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.TermOutOfBounds.selector, uint32(0)));
        testnetRegistry.setTestnetTerms(bad);
        (bad[0], bad[1]) = (FIVE_MINUTES, FIVE_MINUTES);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.DuplicateTerm.selector, FIVE_MINUTES));
        testnetRegistry.setTestnetTerms(bad);
        uint32[] memory many = new uint32[](9);
        for (uint32 i; i < 9; ++i) {
            many[i] = 60 * (i + 1);
        }
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.TooManyTerms.selector, uint256(9), uint256(8)));
        testnetRegistry.setTestnetTerms(many);
    }

    function test_cannotBeDeployedOnMainnet() public {
        vm.chainId(4663);
        vm.expectRevert(TestnetOnly.MainnetForbidden.selector);
        new TestnetV2Registry(address(this), _productionTerms(), address(this));
    }

    function test_fiveMinuteLoanRepaysBeforeItsEnd() public {
        uint256 id = _listFor(FIVE_MINUTES);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.ACTIVE));
        vm.warp(block.timestamp + FIVE_MINUTES - 1);
        vm.prank(borrower);
        vault.reclaim(id, borrower);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.REPAID));
        assertEq(vault.cashCredit(lender[0]), 275e6);
        _assertCash();
    }

    function test_fiveMinuteLoanDefaultsTheSecondItsTermEnds() public {
        uint256 id = _listFor(FIVE_MINUTES);
        uint256 maturity = uint256(vault.getLoan(id).fundedAt) + FIVE_MINUTES;
        vm.warp(maturity - 1);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.finalizeDefault(id);
        vm.warp(maturity);
        vm.prank(borrower);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.reclaim(id, borrower);
        vault.finalizeDefault(id);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.DEFAULTED));
        assertEq(vault.getLoan(id).closedAt, maturity);
        _assertCash();
    }

    function test_twentyMinuteLenderAskCannotOutliveTheRepaymentWindow() public {
        uint256 id = _listFor(TWENTY_MINUTES);
        uint256 windowEnd = uint256(vault.getLoan(id).fundedAt) + TWENTY_MINUTES;
        vm.prank(lender[0]);
        vm.expectRevert(GageV2Vault.Deadline.selector);
        vault.setLenderAsk(id, 1, 250e6, uint40(windowEnd + 1), 100);
        vm.prank(lender[0]);
        vault.setLenderAsk(id, 1, 250e6, uint40(windowEnd), 100);
    }

    function test_unlistedTermStaysRefused() public {
        vm.prank(borrower);
        vm.expectRevert();
        vault.list(
            Collateral(Kind.ERC20, address(stock), 100e18), 1000e6, 1100e6, 600, uint40(block.timestamp + 1 days), false
        );
    }
}
