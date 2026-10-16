// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDealVault, Deal} from "../../../src/interfaces/IDealVault.sol";
import {IEmissions} from "../../../src/interfaces/token/IEmissions.sol";
import {ILPRewards} from "../../../src/interfaces/token/ILPRewards.sol";
import {IsGAGE} from "../../../src/interfaces/token/IsGAGE.sol";
import {DealRewards} from "../../../src/token/DealRewards.sol";
import {Drip} from "../../../src/token/Drip.sol";
import {Emissions} from "../../../src/token/Emissions.sol";
import {GageV2Rewards} from "../../../src/v2/GageV2Rewards.sol";
import {GageLegacyAdapter} from "../../../src/v2/GageLegacyAdapter.sol";
import {Collateral, Kind} from "../../../src/types/Types.sol";
import {LegacyForkState} from "./LegacyForkState.sol";

/// @dev Research fixtures only. These are not deployable production V2 adapters.
contract LegacyPartyProbe {
    address public immutable CONTROLLER;
    IDealVault public immutable VAULT;
    DealRewards public immutable REWARDS;
    Drip public immutable DRIP;
    IERC20 public immutable SGAGE;
    IERC20 public immutable USDG;

    constructor(IDealVault vault, DealRewards rewards, IERC20 usdg) {
        CONTROLLER = msg.sender;
        VAULT = vault;
        REWARDS = rewards;
        DRIP = Drip(address(rewards.DRIP()));
        SGAGE = rewards.SGAGE();
        USDG = usdg;
    }

    modifier controlled() {
        require(msg.sender == CONTROLLER, "probe controller");
        _;
    }

    function list(address token, uint256 amount, uint32 term) external controlled returns (uint256) {
        IERC20(token).approve(address(VAULT), amount);
        return VAULT.list(Collateral(Kind.ERC20, token, amount), 100e6, term, uint40(block.timestamp + 1 days), 90e6);
    }

    function fund(uint256 id) external controlled {
        USDG.approve(address(VAULT), 90e6);
        VAULT.fund(id, address(this));
    }

    function repay(uint256 id) external controlled {
        USDG.approve(address(VAULT), 100e6);
        VAULT.reclaim(id);
    }

    function harvest(uint256 id) external controlled {
        bytes32 key = REWARDS.dripIdOf(id, address(this));
        if (DRIP.claimable(address(this), key) != 0) DRIP.claim(key);
        uint256 amount = SGAGE.balanceOf(address(this));
        if (amount != 0) SGAGE.transfer(CONTROLLER, amount);
    }
}

/// @dev One-loan source/cutoff proof. No marketplace, production custody or lender-fraction implementation.
contract LegacyBridgeProbe {
    address public immutable CONTROLLER;
    address public immutable BENEFICIARY;
    IDealVault public immutable VAULT;
    DealRewards public immutable REWARDS;
    IERC20 public immutable SGAGE;
    GageV2Rewards public immutable RECYCLE;
    LegacyPartyProbe public immutable BORROWER;
    LegacyPartyProbe public immutable LENDER;
    uint256 public id;
    uint40 public fundedAt;
    uint40 public closedAt;
    uint32 public term;
    uint128 public borrowerAllocation;
    uint128 public lenderAllocation;
    uint256 public paid;

    constructor(IDealVault vault, DealRewards rewards, IERC20 usdg, address beneficiary, GageV2Rewards recycleTarget) {
        CONTROLLER = msg.sender;
        BENEFICIARY = beneficiary;
        VAULT = vault;
        REWARDS = rewards;
        SGAGE = rewards.SGAGE();
        RECYCLE = recycleTarget;
        BORROWER = new LegacyPartyProbe(vault, rewards, usdg);
        LENDER = new LegacyPartyProbe(vault, rewards, usdg);
    }

    function start(address token, uint256 amount, uint32 term_) external {
        require(msg.sender == CONTROLLER && id == 0, "probe start");
        id = BORROWER.list(token, amount, term_);
        LENDER.fund(id);
        REWARDS.register(id);
        Deal memory d = VAULT.getDeal(id);
        fundedAt = d.fundedAt;
        term = d.term;
        (, lenderAllocation, borrowerAllocation) = REWARDS.rewardOf(id);
    }

    function close() external {
        require(msg.sender == CONTROLLER && closedAt == 0, "probe close");
        BORROWER.repay(id);
        closedAt = uint40(block.timestamp);
    }

    function earned() public view returns (uint256) {
        uint256 cutoff = closedAt == 0 ? block.timestamp : closedAt;
        uint256 elapsed = cutoff - fundedAt;
        if (elapsed > term) elapsed = term;
        uint256 denominator = uint256(term) * term;
        return uint256(borrowerAllocation) * elapsed * elapsed / denominator + uint256(lenderAllocation) * elapsed
            * elapsed / denominator;
    }

    function harvest() public {
        BORROWER.harvest(id);
        LENDER.harvest(id);
    }

    function claim() external {
        require(msg.sender == BENEFICIARY, "probe beneficiary");
        harvest();
        uint256 amount = earned() - paid;
        paid += amount;
        if (amount != 0) SGAGE.transfer(BENEFICIARY, amount);
    }

    function recycle() external returns (uint256 amount) {
        require(closedAt != 0, "probe active");
        harvest();
        uint256 liability = earned() - paid;
        amount = SGAGE.balanceOf(address(this)) - liability;
        if (amount != 0) {
            SGAGE.approve(address(RECYCLE), amount);
            RECYCLE.fund(amount);
        }
    }
}

contract LegacyRewardBridgeForkTest is LegacyForkState {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SGAGE = 0x78c88CF8F6E612955526cEB501be82BF3279Bd5d;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    IDealVault constant VAULT = IDealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
    DealRewards constant REWARDS = DealRewards(0x5B95978dbE6193E9510aff8a8d78A92d84e6340d);
    Emissions constant EMISSIONS = Emissions(0x6784E12e3cf4A5bbd71406ad30Ef693D819a976C);
    Drip constant DRIP = Drip(0x3f2b11467C0EAbdc7f0D5910193BA012BbCc08Ff);
    LegacyBridgeProbe internal bridge;
    GageV2Rewards internal recycle;
    address internal beneficiary;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_LEGACY_BRIDGE_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_LEGACY_BRIDGE_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        beneficiary = makeAddr("bridge beneficiary");
        recycle = new GageV2Rewards(IERC20(SGAGE), GageLegacyAdapter(address(0)));
        bridge = new LegacyBridgeProbe(VAULT, REWARDS, IERC20(USDG), beneficiary, recycle);
        // Only collateral and USDG capital are simulated. Never mint/deal sGAGE or overwrite protocol storage.
        // The legacy registry has since closed direct SPY listings on mainnet; they reopen on this fork only.
        _readmitLegacy(SPY);
        deal(SPY, address(bridge.BORROWER()), 1e18);
        deal(USDG, address(bridge.LENDER()), 90e6);
        deal(USDG, address(bridge.BORROWER()), 100e6);
    }

    function _nextEpoch() private {
        uint256 e = EMISSIONS.currentEpoch() + 1;
        // The rewards owner has since posted zero rates for later epochs on mainnet; the fork carries them forward.
        _carryLegacyRates(REWARDS, e);
        vm.warp(uint256(EMISSIONS.epochStart(e)) + 60);
        assertFalse(EMISSIONS.rolledOver(e));
        assertGt(EMISSIONS.remaining(e, 7 days), 0);
    }

    function _start() private returns (uint256 allocation) {
        // Release the scheduled LP portion separately, so the reserve delta below is exactly this loan's reward.
        uint256 e = EMISSIONS.currentEpoch();
        if (!EMISSIONS.released(e)) EMISSIONS.release(e);
        uint256 beforeReserve = IERC20(SGAGE).balanceOf(address(EMISSIONS));
        uint256 beforeDrip = IERC20(SGAGE).balanceOf(address(DRIP));
        bridge.start(SPY, 1e18, 7 days);
        allocation = uint256(bridge.borrowerAllocation()) + bridge.lenderAllocation();
        assertEq(beforeReserve - IERC20(SGAGE).balanceOf(address(EMISSIONS)), allocation);
        assertEq(IERC20(SGAGE).balanceOf(address(DRIP)) - beforeDrip, allocation);
        Deal memory d = VAULT.getDeal(bridge.id());
        assertEq(d.borrower, address(bridge.BORROWER()));
        assertEq(d.lender, address(bridge.LENDER()));
        assertEq(d.fee, 900_000);
    }

    function testFork_directReserveRedirectionAndRewiringAreRejected() public {
        uint256 epoch = EMISSIONS.currentEpoch();
        vm.expectRevert(IEmissions.NotDealRewards.selector);
        vm.prank(address(bridge));
        EMISSIONS.reserve(epoch, 7 days, 1, address(recycle));
        address deployer = EMISSIONS.DEPLOYER();
        ILPRewards lp = EMISSIONS.lpRewards();
        vm.expectRevert(Emissions.AlreadyWired.selector);
        vm.prank(deployer);
        EMISSIONS.wire(IsGAGE(SGAGE), lp, address(bridge));
        address dripDeployer = DRIP.DEPLOYER();
        vm.expectRevert(bytes4(keccak256("GrantorsAlreadySet()")));
        vm.prank(dripDeployer);
        DRIP.setGrantors(address(bridge), address(lp));
    }

    function testFork_currentExhaustedEpochDoesNotMagicallyFundBridge() public {
        // The epoch this was written in had spent its 7-day budget; a later live epoch need not have. Spend it first.
        _exhaustCurrentLoanBudget(VAULT, REWARDS, SPY, USDG, 7 days);
        assertEq(EMISSIONS.remaining(EMISSIONS.currentEpoch(), 7 days), 0);
        assertEq(_start(), 0);
        assertEq(IERC20(SGAGE).balanceOf(address(bridge)), 0);
        assertEq(IERC20(SGAGE).balanceOf(address(recycle)), 0);
    }

    function testFork_nextScheduledEpochPaysRealReserveThroughLegacyParties() public {
        _nextEpoch();
        uint256 allocation = _start();
        assertGt(allocation, 0);
        vm.warp(uint256(bridge.fundedAt()) + 7 days);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), allocation);
        assertEq(IERC20(SGAGE).balanceOf(address(bridge)), 0);
        emit log_named_uint("actual sGAGE from existing reserve", allocation);
    }

    function testFork_sameBlockClosePaysZeroThenRecyclesOnlyWhenLegacyDripsVest() public {
        _nextEpoch();
        uint256 allocation = _start();
        bridge.close();
        assertEq(bridge.earned(), 0);
        assertEq(bridge.recycle(), 0);
        vm.warp(uint256(bridge.fundedAt()) + 7 days);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), 0);
        assertEq(bridge.recycle(), allocation);
        assertEq(recycle.freeBudget(), allocation);
        assertEq(IERC20(SGAGE).balanceOf(address(recycle)), allocation);
    }

    function testFork_userCannotBypassBridgeCutoffByClaimingItsLegacyDrip() public {
        _nextEpoch();
        _start();
        bridge.close();
        vm.warp(uint256(bridge.fundedAt()) + 7 days);
        bytes32 key = REWARDS.dripIdOf(bridge.id(), address(bridge.BORROWER()));
        vm.expectRevert(abi.encodeWithSignature("NoDrip(address,bytes32)", beneficiary, key));
        vm.prank(beneficiary);
        DRIP.claim(key);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), 0);
    }

    function testFork_halfwayClosePreservesEarnedAndRoutesOnlyUnearnedIntoV2() public {
        _nextEpoch();
        uint256 allocation = _start();
        vm.warp(uint256(bridge.fundedAt()) + 7 days / 2);
        bridge.close();
        uint256 earned = bridge.earned();
        assertEq(earned, allocation / 4);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), earned);
        vm.warp(uint256(bridge.fundedAt()) + 7 days);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), earned);
        assertEq(bridge.recycle(), allocation - earned);
        assertEq(bridge.recycle(), 0);
    }

    function testFork_recyclingBeforeUserClaimsKeepsTheirEarnedBacking() public {
        _nextEpoch();
        uint256 allocation = _start();
        vm.warp(uint256(bridge.fundedAt()) + 7 days / 2);
        bridge.close();
        uint256 earned = bridge.earned();
        vm.warp(uint256(bridge.fundedAt()) + 7 days);
        assertEq(bridge.recycle(), allocation - earned);
        assertEq(IERC20(SGAGE).balanceOf(address(bridge)), earned);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), earned);
        vm.prank(beneficiary);
        bridge.claim();
        assertEq(IERC20(SGAGE).balanceOf(beneficiary), earned);
    }
}
