// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HybridVault} from "../src/HybridVault.sol";
import {HybridFees} from "../src/HybridFees.sol";
import {GageV2Vault} from "../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../src/v2/GageV2Rewards.sol";
import {GageV2Registry} from "../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../src/v2/GageV2TokenRegistry.sol";
import {GageV2CollateralValidator} from "../src/v2/GageV2CollateralValidator.sol";
import {GageLegacyAdapter} from "../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State} from "../src/v2/V2Types.sol";
import {Collateral, Kind} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOpenFunderGate} from "./mocks/MockFunderGate.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {HybridReserveMock} from "./mocks/HybridReserveMock.sol";
import {GageV2VaultWithValidator} from "./helpers/LegacyCoreValidator.sol";

/// @notice Shared fixture: a local Gage V2 core, an ERC-4626 reserve mock and one Earn strategy.
abstract contract EarnBaseTest is Test {
    uint32 internal constant GRACE = 48 hours;
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;
    uint256 internal constant NVDA_MIN = 1e18;
    uint256 internal constant NVDA_MAX_DEAL = 1000e18;
    uint256 internal constant NVDA_MAX_OPEN = 5000e18;
    uint8 internal constant UNITS = 4;

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");
    address internal other = makeAddr("other");
    address internal curator = makeAddr("earn-curator");
    address[3] internal fillers;

    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal nvda;
    MockERC20 internal aapl;
    MockERC20 internal meme;
    MockFeeOnTransferERC20 internal feeToken;
    GageV2Registry internal registry;
    GageV2CollateralValidator internal validator;
    GageV2Vault internal vault;
    GageV2Rewards internal coreRewards;
    HybridReserveMock internal reserve;
    HybridVault internal hybrid;
    HybridFees internal hybridFees;
    HybridVault.Params internal p;
    /// @dev Stand-in for the deal fee router: protocol fee shares are plain USDG at this address.
    address internal floor;

    function setUp() public virtual {
        vm.warp(10_000);
        usdg = new MockERC20("USDG", "USDG", 6);
        sgage = new MockERC20("sGAGE", "sGAGE", 18);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        aapl = new MockERC20("AAPL", "AAPL", 18);
        meme = new MockERC20("MEME", "MEME", 18);
        feeToken = new MockFeeOnTransferERC20();
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        registry = new GageV2Registry(safe, terms, address(this));
        vm.startPrank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        registry.setERC20Allowed(address(aapl), true, Lane.STOCK, NVDA_MIN, NVDA_MAX_DEAL, NVDA_MAX_OPEN);
        registry.setERC20Allowed(address(meme), true, Lane.MEME, 1e18, 100_000e18, 1_000_000e18);
        registry.setRewardTerms(T7, 100e18, 1, 5000);
        registry.setRewardTerms(T21, 100e18, 1, 5000);
        vm.stopPrank();
        validator = new GageV2CollateralValidator(registry, address(usdg), address(sgage), address(0), address(0));
        vault = new GageV2VaultWithValidator(
            address(validator),
            GageV2TokenRegistry(address(registry)),
            IERC20(address(usdg)),
            IERC20(address(sgage)),
            treasury,
            _grace(),
            GageLegacyAdapter(address(0))
        );
        coreRewards = vault.REWARDS();
        // An engine lends to no one until a funder gate is bound (D47); these suites lend from any account.
        vm.startPrank(safe);
        coreRewards.bindFunderGate(new MockOpenFunderGate());
        vm.stopPrank();
        sgage.mint(address(this), 10_000_000e18);
        sgage.approve(address(coreRewards), type(uint256).max);
        coreRewards.fund(10_000_000e18);
        reserve = new HybridReserveMock(IERC20(address(usdg)));
        floor = address(new MockERC20("Floor", "FLOOR", 18));
        p = HybridVault.Params({
            core: address(vault),
            reserve: address(reserve),
            laneWeights: [uint16(10_000), 0, 0],
            curator: curator,
            maxLoanTerm: T21,
            minReturnBps: 200,
            maxGageExposureBps: 10_000,
            minDeposit: 1e6,
            maxTotalDeposits: 100_000e6
        });
        address[6] memory funded = [lender, lender2, other, borrower, safe, treasury];
        for (uint256 i; i < funded.length; ++i) {
            usdg.mint(funded[i], 1_000_000e6);
            vm.prank(funded[i]);
            usdg.approve(address(vault), type(uint256).max);
        }
        for (uint256 i; i < fillers.length; ++i) {
            fillers[i] = makeAddr(string(abi.encodePacked("filler", i)));
            usdg.mint(fillers[i], 1_000_000e6);
            vm.prank(fillers[i]);
            usdg.approve(address(vault), type(uint256).max);
        }
        nvda.mint(borrower, 1_000_000e18);
        aapl.mint(borrower, 1_000_000e18);
        meme.mint(borrower, 1_000_000e18);
        nvda.mint(other, 1_000_000e18);
        vm.startPrank(borrower);
        nvda.approve(address(vault), type(uint256).max);
        aapl.approve(address(vault), type(uint256).max);
        meme.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(other);
        nvda.approve(address(vault), type(uint256).max);
        _deploy();
    }

    /// @dev Deploy the strategy and its companion from the current `p`, admitting NVDA at 1000 USDG.
    function _deploy() internal virtual {
        hybrid = new HybridVault(p);
        vm.prank(curator);
        hybrid.setTokenCeiling(address(nvda), 1000e6);
        hybridFees = new HybridFees(address(hybrid), 2500, floor, curator);
        vm.prank(curator);
        hybrid.setFees(address(hybridFees));
        address[4] memory depositors = [lender, lender2, other, borrower];
        for (uint256 i; i < depositors.length; ++i) {
            vm.prank(depositors[i]);
            usdg.approve(address(hybrid), type(uint256).max);
        }
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _two(uint256 first, uint256 second) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
    }

    /// @dev List whole ERC-20 collateral on the V2 core with rewards, funding open for one day.
    function _list(address who, address token, uint256 amount, uint128 principal, uint128 cap, uint32 term)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = vault.list(
            Collateral(Kind.ERC20, token, amount), principal, cap, term, uint40(block.timestamp + 1 days), true
        );
    }

    /// @dev A 7-day NVDA listing at a 5% premium, the shape most cases use.
    function _listed(uint128 principal) internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 100e18, principal, principal * 105 / 100, T7);
    }

    function _approve(uint256 id, uint8 units) internal {
        vm.prank(curator);
        hybrid.approveLoan(id, uint40(block.timestamp + 1 hours), units);
    }

    function _approve(uint256 id) internal {
        _approve(id, UNITS);
    }

    /// @dev External lenders take every unit the strategy has not bought, activating the loan.
    function _fill(uint256 id) internal {
        address[4] memory lenders = vault.lenders(id);
        uint256 filler;
        for (uint8 i; i < UNITS; ++i) {
            if (lenders[i] != address(0)) continue;
            vm.prank(fillers[filler++ % fillers.length]);
            vault.fund(id, 1);
        }
    }

    function _repay(uint256 id) internal {
        address originator = vault.getLoan(id).originator;
        vm.prank(originator);
        vault.reclaim(id, originator);
    }

    /// @dev The core's grace window. Zero-grace fixtures override it; the deployed strategies read 48 hours.
    function _grace() internal view virtual returns (uint32) {
        return GRACE;
    }

    /// @dev Repayment closes and the strategy may finalize the default from this second.
    function _defaultAt(uint256 id) internal view returns (uint256) {
        V2Loan memory l = vault.getLoan(id);
        return uint256(l.fundedAt) + l.term + vault.GRACE();
    }

    function _state(uint256 id) internal view returns (V2State) {
        return vault.getLoan(id).state;
    }
}
