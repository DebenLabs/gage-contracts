// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDealVault, Deal, DealState} from "../../../src/interfaces/IDealVault.sol";
import {IEmissions} from "../../../src/interfaces/token/IEmissions.sol";
import {CollateralRegistry} from "../../../src/CollateralRegistry.sol";
import {DealRewards} from "../../../src/token/DealRewards.sol";
import {Emissions} from "../../../src/token/Emissions.sol";
import {Collateral, Kind} from "../../../src/types/Types.sol";
import {Lane} from "../../../src/interfaces/ICollateralRegistry.sol";
import {LegacyPartyProbe} from "./LegacyRewardBridgeFork.t.sol";
import {LegacyAdmissionSnapshot} from "./LegacyAdmissionSnapshot.sol";
import {LegacyForkState} from "./LegacyForkState.sol";

/// @dev Research-only borrower/lender contract. A production version needs complete settlement/reward controls.
contract ReceiptPartyProbe is LegacyPartyProbe {
    constructor(IDealVault vault, DealRewards rewards, IERC20 usdg) LegacyPartyProbe(vault, rewards, usdg) {}

    function withdrawReceipt(address receipt) external controlled {
        VAULT.withdrawERC20(receipt);
    }
}

/// @dev Research-only, SPY-backed receipt and engine gate. Not a production collateral or reward implementation.
contract ExclusiveReceiptProbe is ERC20 {
    address public immutable ADMIN;
    IDealVault public immutable VAULT;
    DealRewards public immutable REWARDS;
    IERC20 public immutable USDG;
    IERC20 public immutable BACKING;
    address public activeEngine;
    uint256 public count;

    struct Loan {
        address engine;
        ReceiptPartyProbe borrower;
        ReceiptPartyProbe lender;
        uint256 backing;
        uint256 legacyId;
        bool redeemed;
    }

    mapping(uint256 => Loan) private _loans;
    mapping(address => uint256) public partyLoan;

    error NotActiveEngine();
    error WrongLoanEngine();
    error RestrictedReceipt();

    constructor(IDealVault vault, DealRewards rewards, IERC20 usdg, IERC20 backing)
        ERC20("Research-only collateral receipt", "PROBE")
    {
        ADMIN = msg.sender;
        VAULT = vault;
        REWARDS = rewards;
        USDG = usdg;
        BACKING = backing;
    }

    function setEngine(address engine) external {
        require(msg.sender == ADMIN, "probe admin");
        activeEngine = engine;
    }

    function loan(uint256 id) external view returns (Loan memory) {
        return _loans[id];
    }

    function open(uint256 amount, uint32 term) external returns (uint256 id) {
        if (msg.sender != activeEngine) revert NotActiveEngine();
        require(amount != 0, "probe amount");
        uint256 beforeBacking = BACKING.balanceOf(address(this));
        BACKING.transferFrom(msg.sender, address(this), amount);
        require(BACKING.balanceOf(address(this)) == beforeBacking + amount, "probe backing");
        id = ++count;
        Loan storage l = _loans[id];
        l.engine = msg.sender;
        l.backing = amount;
        l.borrower = new ReceiptPartyProbe(VAULT, REWARDS, USDG);
        l.lender = new ReceiptPartyProbe(VAULT, REWARDS, USDG);
        partyLoan[address(l.borrower)] = id;
        partyLoan[address(l.lender)] = id;
        _mint(address(l.borrower), 1);
        USDG.transferFrom(msg.sender, address(l.lender), 90e6);
        // Creation and funding are atomic; no public unfunded receipt listing is left behind.
        l.legacyId = l.borrower.list(address(this), 1, term);
        l.lender.fund(l.legacyId);
        REWARDS.register(l.legacyId);
    }

    function repay(uint256 id) external {
        Loan storage l = _loans[id];
        if (msg.sender != l.engine) revert WrongLoanEngine();
        USDG.transferFrom(msg.sender, address(l.borrower), 100e6);
        l.borrower.repay(l.legacyId);
        l.borrower.withdrawReceipt(address(this));
        require(!l.redeemed && balanceOf(address(l.borrower)) == 1, "probe redeem");
        l.redeemed = true;
        _burn(address(l.borrower), 1);
        // The original engine is fixed per loan. A newly selected engine cannot redirect this payout.
        BACKING.transfer(l.engine, l.backing);
    }

    function _update(address from, address to, uint256 value) internal override {
        bool minting = from == address(0) && partyLoan[to] != 0;
        bool burning = to == address(0) && partyLoan[from] != 0;
        bool depositing = to == address(VAULT) && msg.sender == address(VAULT) && partyLoan[from] != 0;
        bool withdrawing = from == address(VAULT) && msg.sender == address(VAULT) && partyLoan[to] != 0;
        if ((!minting && !burning && !depositing && !withdrawing) || value != 1) revert RestrictedReceipt();
        super._update(from, to, value);
    }
}

/// @dev Research-only stand-in for an authenticated future loan engine. Not a user-facing vault.
contract VersionEngineProbe {
    address public immutable CONTROLLER;
    ExclusiveReceiptProbe public immutable GATE;

    constructor(ExclusiveReceiptProbe gate, IERC20 backing, IERC20 usdg) {
        CONTROLLER = msg.sender;
        GATE = gate;
        backing.approve(address(gate), type(uint256).max);
        usdg.approve(address(gate), type(uint256).max);
    }

    function open() external returns (uint256) {
        require(msg.sender == CONTROLLER, "probe controller");
        return GATE.open(1e18, 7 days);
    }

    function repay(uint256 id) external {
        require(msg.sender == CONTROLLER, "probe controller");
        GATE.repay(id);
    }
}

contract ExclusiveLegacyAdapterForkTest is LegacyForkState {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SGAGE = 0x78c88CF8F6E612955526cEB501be82BF3279Bd5d;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    IDealVault constant VAULT = IDealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
    CollateralRegistry constant REGISTRY = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
    DealRewards constant REWARDS = DealRewards(0x5B95978dbE6193E9510aff8a8d78A92d84e6340d);
    Emissions constant EMISSIONS = Emissions(0x6784E12e3cf4A5bbd71406ad30Ef693D819a976C);
    ExclusiveReceiptProbe internal gate;
    VersionEngineProbe internal v2;
    VersionEngineProbe internal v3;
    address internal outsider;
    /// @dev An unfunded, open-ended listing left at the simulated cutover. Listing 45, which this research was written
    ///      against, has since been cancelled by its borrower on mainnet, as have listings 46 to 49.
    uint256 internal preCutoverListing;

    function setUp() public {
        string memory rpc = vm.envOr("GAGE_EXCLUSIVE_ADAPTER_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_EXCLUSIVE_ADAPTER_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        outsider = makeAddr("direct legacy caller");
        gate = new ExclusiveReceiptProbe(VAULT, REWARDS, IERC20(USDG), IERC20(SPY));
        v2 = new VersionEngineProbe(gate, IERC20(SPY), IERC20(USDG));
        v3 = new VersionEngineProbe(gate, IERC20(SPY), IERC20(USDG));
        gate.setEngine(address(v2));
        // Only loan capital is simulated. Existing reserve/token balances and deployed code remain real.
        deal(SPY, address(v2), 10e18);
        deal(SPY, address(v3), 10e18);
        deal(USDG, address(v2), 10_000e6);
        deal(USDG, address(v3), 10_000e6);
        deal(USDG, outsider, 10_000e6);
        // At the snapshot, SPY was admitted, unfunded listings were open and the current epoch's 7-day loan budget was
        // spent. Mainnet has since moved past all three. SPY is admitted again on this fork only, long enough to open
        // one such listing and spend that budget before the simulated cutover closes it.
        _readmitLegacy(SPY);
        address lister = makeAddr("pre-cutover borrower");
        deal(SPY, lister, 1e18);
        vm.startPrank(lister);
        IERC20(SPY).approve(address(VAULT), 1e18);
        preCutoverListing = VAULT.list(Collateral(Kind.ERC20, SPY, 1e18), 100e6, 21 days, 0, 90e6);
        vm.stopPrank();
        _exhaustCurrentLoanBudget(VAULT, REWARDS, SPY, USDG, 7 days);
        _simulateAdmissionCutover();
    }

    function _simulateAdmissionCutover() private {
        // Simulated owner calls on this local fork only. No public-chain configuration is changed.
        address owner = REGISTRY.owner();
        address[] memory tokens = LegacyAdmissionSnapshot.tokens();
        bytes32[] memory pools = LegacyAdmissionSnapshot.pools();
        vm.startPrank(owner);
        REGISTRY.pauseNewDeals(true);
        for (uint256 i; i < tokens.length; ++i) {
            REGISTRY.setERC20Allowed(tokens[i], false, Lane.STOCK, 0, 0, 0);
        }
        for (uint256 i; i < pools.length; ++i) {
            REGISTRY.setPoolAllowed(pools[i], false, 0);
        }
        REGISTRY.setERC20Allowed(address(gate), true, Lane.STOCK, 1, 1, 1_000_000);
        REGISTRY.pauseNewDeals(false);
        vm.stopPrank();
        for (uint256 i; i < tokens.length; ++i) {
            assertFalse(REGISTRY.getERC20Config(tokens[i]).allowed);
        }
        for (uint256 i; i < pools.length; ++i) {
            assertFalse(REGISTRY.getPoolConfig(pools[i]).allowed);
        }
    }

    function _nextEpoch() private {
        uint256 e = EMISSIONS.currentEpoch() + 1;
        // The rewards owner has since posted zero rates for later epochs on mainnet; the fork carries them forward.
        _carryLegacyRates(REWARDS, e);
        vm.warp(uint256(EMISSIONS.epochStart(e)) + 60);
    }

    function testFork_directLegacyNewListingsFailForEveryPreviouslyAdmittedToken() public {
        address[] memory tokens = LegacyAdmissionSnapshot.tokens();
        for (uint256 i; i < tokens.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("TokenNotAllowed(address)", tokens[i]));
            vm.prank(outsider);
            VAULT.list(Collateral(Kind.ERC20, tokens[i], 1e18), 100e6, 7 days, 0, 90e6);
        }
    }

    function testFork_outsiderCannotCreateGateLoansOrObtainSpendableReceipts() public {
        vm.expectRevert(ExclusiveReceiptProbe.NotActiveEngine.selector);
        vm.prank(outsider);
        gate.open(1e18, 7 days);
        vm.prank(outsider);
        gate.approve(address(VAULT), 1);
        vm.expectRevert(ExclusiveReceiptProbe.RestrictedReceipt.selector);
        vm.prank(outsider);
        VAULT.list(Collateral(Kind.ERC20, address(gate), 1), 100e6, 7 days, 0, 90e6);
    }

    function testFork_outsiderCannotSelectEngineOrAuthorizeTheirOwnReceipt() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "probe admin"));
        vm.prank(outsider);
        gate.setEngine(outsider);
        assertEq(gate.activeEngine(), address(v2));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        vm.prank(outsider);
        REGISTRY.setERC20Allowed(outsider, true, Lane.STOCK, 1, 1, 100);
        assertFalse(REGISTRY.getERC20Config(outsider).allowed);
    }

    function testFork_outsiderCanDeployIdenticalAdapterButCannotConnectItToLegacyRewards() public {
        vm.prank(outsider);
        ExclusiveReceiptProbe copy = new ExclusiveReceiptProbe(VAULT, REWARDS, IERC20(USDG), IERC20(SPY));
        VersionEngineProbe copyEngine = new VersionEngineProbe(copy, IERC20(SPY), IERC20(USDG));
        vm.prank(outsider);
        copy.setEngine(address(copyEngine));
        deal(SPY, address(copyEngine), 1e18);
        deal(USDG, address(copyEngine), 90e6);
        assertEq(copy.ADMIN(), outsider);
        assertFalse(REGISTRY.getERC20Config(address(copy)).allowed);
        vm.expectRevert(abi.encodeWithSignature("TokenNotAllowed(address)", address(copy)));
        copyEngine.open();
        assertEq(copy.totalSupply(), 0);
        assertEq(IERC20(SPY).balanceOf(address(copyEngine)), 1e18);
        assertEq(gate.activeEngine(), address(v2));
    }

    function testFork_gateLoanActivatesWithZeroRewardsAndNextEpochNewLoanReceivesRewards() public {
        uint256 first = v2.open();
        ExclusiveReceiptProbe.Loan memory a = gate.loan(first);
        (uint128 firstReward,,) = REWARDS.rewardOf(a.legacyId);
        assertEq(firstReward, 0);
        assertEq(uint256(VAULT.getDeal(a.legacyId).state), uint256(DealState.FUNDED));
        _nextEpoch();
        uint256 second = v2.open();
        ExclusiveReceiptProbe.Loan memory b = gate.loan(second);
        (uint128 secondReward,,) = REWARDS.rewardOf(b.legacyId);
        assertGt(secondReward, 0);
        (firstReward,,) = REWARDS.rewardOf(a.legacyId);
        assertEq(firstReward, 0); // An old zero grant is not retroactively promoted to a later epoch.
        assertEq(gate.totalSupply(), 2);
        assertEq(IERC20(SPY).balanceOf(address(gate)), 2e18);
    }

    function testFork_switchToV3BlocksNewV2LoansButOldV2StillRepaysAndGetsBacking() public {
        uint256 oldId = v2.open();
        gate.setEngine(address(v3));
        vm.expectRevert(ExclusiveReceiptProbe.NotActiveEngine.selector);
        v2.open();
        uint256 newId = v3.open();
        vm.expectRevert(ExclusiveReceiptProbe.WrongLoanEngine.selector);
        v3.repay(oldId);
        uint256 beforeV2 = IERC20(SPY).balanceOf(address(v2));
        uint256 beforeV3 = IERC20(SPY).balanceOf(address(v3));
        v2.repay(oldId);
        assertEq(IERC20(SPY).balanceOf(address(v2)), beforeV2 + 1e18);
        assertEq(IERC20(SPY).balanceOf(address(v3)), beforeV3);
        assertEq(gate.totalSupply(), 1);
        v3.repay(newId);
        assertEq(gate.totalSupply(), 0);
        assertEq(IERC20(SPY).balanceOf(address(gate)), 0);
    }

    function testFork_preCutoverUnfundedLegacyListingCanStillConsumeNextEpochRewards() public {
        _nextEpoch();
        Deal memory d = VAULT.getDeal(preCutoverListing);
        assertEq(uint256(d.state), uint256(DealState.LISTED));
        assertFalse(REGISTRY.getERC20Config(d.token).allowed);
        vm.startPrank(outsider);
        IERC20(USDG).approve(address(VAULT), d.minPrice);
        VAULT.fund(preCutoverListing, outsider);
        REWARDS.register(preCutoverListing);
        vm.stopPrank();
        (uint128 reward,,) = REWARDS.rewardOf(preCutoverListing);
        assertGt(reward, 0);
        assertEq(VAULT.getDeal(preCutoverListing).lender, outsider);
        emit log_named_uint("legacy pending listing still gets a scheduled reward", reward);
    }

    function testFork_admissionCutoverPreservesExistingFundedLoanRepaymentAndCollateral() public {
        uint256 id;
        Deal memory d;
        for (uint256 i = 1; i <= 52; ++i) {
            Deal memory candidate = VAULT.getDeal(i);
            if (candidate.state == DealState.FUNDED && candidate.kind == Kind.ERC20) {
                id = i;
                d = candidate;
                break;
            }
        }
        assertGt(id, 0);
        assertFalse(REGISTRY.getERC20Config(d.token).allowed);
        uint256 beforeCollateral = IERC20(d.token).balanceOf(d.borrower);
        deal(USDG, d.borrower, uint256(d.cap));
        vm.startPrank(d.borrower);
        IERC20(USDG).approve(address(VAULT), d.cap);
        VAULT.reclaim(id);
        VAULT.withdrawERC20(d.token);
        vm.stopPrank();
        assertEq(uint256(VAULT.getDeal(id).state), uint256(DealState.RECLAIMED));
        assertGe(IERC20(d.token).balanceOf(d.borrower), beforeCollateral + d.amountOrTokenId);
    }

    function testFork_futureLoanShareCannotBeSetToEntireDistribution() public {
        address owner = EMISSIONS.owner();
        uint256 next = EMISSIONS.currentEpoch() + 1;
        assertEq(EMISSIONS.MAX_DEAL_SHARE_BPS(), 8000);
        vm.expectRevert(IEmissions.SharesOutOfBounds.selector);
        vm.prank(owner);
        EMISSIONS.setShares(next, 10_000, 7000);
    }
}
