// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EarnVault, EarnLane} from "../../src/earn/EarnVault.sol";
import {EarnFactory} from "../../src/earn/EarnFactory.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2CollateralValidator} from "../../src/v2/GageV2CollateralValidator.sol";
import {GageLegacyAdapter} from "../../src/v2/GageLegacyAdapter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {HybridReserveMock} from "../mocks/HybridReserveMock.sol";
import {MockOpenFunderGate} from "../mocks/MockFunderGate.sol";
import {answerLegacyValidator} from "../helpers/LegacyCoreValidator.sol";
import {GradeRegistry} from "../../src/earn/GradeRegistry.sol";

/// @notice Shared fixture: a local Gage V2 core, an ERC-4626 reserve mock and one third-design Earn strategy.
abstract contract EarnV3BaseTest is Test {
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;
    uint8 internal constant UNITS = 4;
    uint256 internal constant MAX = type(uint256).max;

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal borrower = makeAddr("borrower");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal curator = makeAddr("earn-curator");
    address internal feeRecipient = makeAddr("fee-recipient");
    address[3] internal fillers;

    MockERC20 internal usdg;
    MockERC20 internal sgage;
    MockERC20 internal nvda;
    MockERC20 internal meme;
    GageV2Registry internal registry;
    GageV2CollateralValidator internal validator;
    GageV2Vault internal core;
    GageV2Rewards internal coreRewards;
    HybridReserveMock internal reserve;
    GradeRegistry internal grades;
    EarnVault internal earn;
    EarnVault.Params internal p;
    /// @dev Stand-in for the deal fee router: protocol fee shares are plain USDG at this address.
    address internal floor;

    /// @dev An engine lends to no one until a funder gate is bound (D47). These suites fund with any account, so the
    /// core names every account; a suite that binds the partner factory itself opts out.
    function _opensCoreToEveryone() internal view virtual returns (bool) {
        return true;
    }

    /// @dev The lent asset's decimals: USDG's six here; a suite may lend an 18-decimal stock token instead.
    function _cashDecimals() internal pure virtual returns (uint8) {
        return 6;
    }

    /// @dev The lent asset's raw units in one six-decimal unit: the fixture's USDG amounts are multiplied by it.
    function _cashScale() internal pure returns (uint256) {
        return 10 ** (_cashDecimals() - 6);
    }

    function setUp() public virtual {
        vm.warp(10_000);
        usdg = new MockERC20("USDG", "USDG", _cashDecimals());
        sgage = new MockERC20("sGAGE", "sGAGE", 18);
        nvda = new MockERC20("NVDA", "NVDA", 18);
        meme = new MockERC20("MEME", "MEME", 18);
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        registry = new GageV2Registry(safe, terms, address(this));
        vm.startPrank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 1000e18, 100_000e18);
        registry.setERC20Allowed(address(meme), true, Lane.MEME, 1e18, 100_000e18, 1_000_000e18);
        registry.setRewardTerms(T7, 100e18, 1, 5000);
        registry.setRewardTerms(T21, 100e18, 1, 5000);
        vm.stopPrank();
        validator = new GageV2CollateralValidator(registry, address(usdg), address(sgage), address(0), address(0));
        core = new GageV2Vault(
            GageV2TokenRegistry(address(registry)),
            IERC20(address(usdg)),
            IERC20(address(sgage)),
            treasury,
            0,
            GageLegacyAdapter(address(0))
        );
        answerLegacyValidator(address(core), address(validator));
        coreRewards = core.REWARDS();
        if (_opensCoreToEveryone()) {
            // Deployed and bound by the registry's owner, so this fixture's own deployments keep their addresses.
            vm.startPrank(safe);
            coreRewards.bindFunderGate(new MockOpenFunderGate());
            vm.stopPrank();
        }
        sgage.mint(address(this), 10_000_000e18);
        sgage.approve(address(coreRewards), type(uint256).max);
        coreRewards.fund(10_000_000e18);
        reserve = new HybridReserveMock(IERC20(address(usdg)));
        grades = new GradeRegistry(address(this), address(this));
        floor = address(new MockERC20("Floor", "FLOOR", 18));
        p = EarnVault.Params({
            core: address(core),
            reserve: address(reserve),
            grades: address(grades),
            protocolSource: address(this),
            protocolShareBps: 1000,
            mandate: EarnVault.Mandate({
                curator: curator,
                laneWeights: [uint16(6000), 3000, 1000],
                assets: new address[](0),
                maxLoanTerm: T21,
                feeBps: 1500,
                maxTotalDeposits: uint128(1_000_000e6 * _cashScale()),
                minGrade: 0,
                minRateGrade: 0
            })
        });
        address[4] memory funded = [borrower, alice, bob, carol];
        for (uint256 i; i < funded.length; ++i) {
            usdg.mint(funded[i], 1_000_000e6 * _cashScale());
            vm.prank(funded[i]);
            usdg.approve(address(core), type(uint256).max);
        }
        for (uint256 i; i < fillers.length; ++i) {
            fillers[i] = makeAddr(string(abi.encodePacked("filler", i)));
            usdg.mint(fillers[i], 1_000_000e6 * _cashScale());
            vm.prank(fillers[i]);
            usdg.approve(address(core), type(uint256).max);
        }
        nvda.mint(borrower, 1_000_000e18);
        meme.mint(borrower, 1_000_000e18);
        vm.startPrank(borrower);
        nvda.approve(address(core), type(uint256).max);
        meme.approve(address(core), type(uint256).max);
        vm.stopPrank();
        _deploy();
    }

    function _deploy() internal virtual {
        earn = new EarnVault(p);
        vm.prank(curator);
        earn.setFeeRecipient(feeRecipient);
        address[3] memory depositors = [alice, bob, carol];
        for (uint256 i; i < depositors.length; ++i) {
            vm.prank(depositors[i]);
            usdg.approve(address(earn), type(uint256).max);
        }
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = earn.deposit(assets, 0);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    /// @dev List whole ERC-20 collateral on the V2 core with rewards, funding open for one day.
    function _list(address who, address token, uint256 amount, uint128 principal, uint128 cap, uint32 term)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = core.list(
            Collateral(Kind.ERC20, token, amount), principal, cap, term, uint40(block.timestamp + 1 days), true
        );
    }

    /// @dev A 7-day NVDA listing at a 5% premium, the shape most cases use.
    function _listed(uint128 principal) internal returns (uint256 id) {
        id = _list(borrower, address(nvda), 100e18, principal, principal * 105 / 100, T7);
    }

    /// @dev The curator funds in one transaction.
    function _fund(uint256 id, uint8 units) internal {
        vm.prank(curator);
        earn.fund(id, units, MAX);
    }

    function _funded(uint128 principal) internal returns (uint256 id) {
        id = _listed(principal);
        _fund(id, UNITS);
    }

    /// @dev External lenders take every unit the strategy has not bought, activating the loan.
    function _fill(uint256 id) internal {
        address[4] memory lenders = core.lenders(id);
        uint256 filler;
        for (uint8 i; i < UNITS; ++i) {
            if (lenders[i] != address(0)) continue;
            vm.prank(fillers[filler++ % fillers.length]);
            core.fund(id, 1);
        }
    }

    function _repay(uint256 id) internal {
        address originator = core.getLoan(id).originator;
        vm.prank(originator);
        core.reclaim(id, originator);
    }

    /// @dev The end of the term: repayment closes and the strategy may finalize the default from this second.
    function _maturity(uint256 id) internal view returns (uint256) {
        V2Loan memory l = core.getLoan(id);
        return uint256(l.fundedAt) + l.term;
    }

    function _settle(uint256 id) internal {
        earn.settle(_ids(id));
    }

    function _state(uint256 id) internal view returns (V2State) {
        return core.getLoan(id).state;
    }

    function _loan(uint256 id) internal view returns (EarnVault.Loan memory ln) {
        (
            ln.slots,
            ln.lane,
            ln.feeBps,
            ln.maturity,
            ln.withdrawn,
            ln.settled,
            ln.recovered,
            ln.snapshotId,
            ln.principal,
            ln.snapshotSupply,
            ln.interest,
            ln.rate,
            ln.clockStart
        ) = earn.loans(id);
    }

    /// @dev Stands in for the factory: where the protocol's fee share is paid.
    function protocolRecipient() external view returns (address) {
        return floor;
    }

    /// @dev Stands in for the factory: no fill router, so only the curator funds here.
    function fillRouter() external pure returns (address) {
        return address(0);
    }
}
