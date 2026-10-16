// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFactory} from "../../src/intent/IntentFactory.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {IntentLenderMarket} from "../../src/intent/IntentLenderMarket.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {GageV2Rewards} from "../../src/v2/GageV2Rewards.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

interface IAcceptanceMint {
    function mint(address, uint256) external;
}

/// @dev The published factory's secondary creation entry point, from before `create` took the secondary policy.
interface ILegacySecondaryCreate {
    function createWithSecondary(IntentVault.Mandate calldata mandate, bool secondaryEnabled, uint16 secondaryExtraBps)
        external
        returns (address);
}

/// @dev The published factory's three-argument filler admission, from before the payout record was removed (D49).
interface ILegacyFillerAdmission {
    function setFiller(address filler, bool allowed, address payout) external;
}

/// Functional acceptance against deployed v9 bytecode, on a LOCAL pinned testnet fork only.
/// Setup admits a fresh fixture manager/filler and replaces the quote signer locally; uses public mock mint.
/// Those overrides test deployed execution but do not establish hosted signer/keeper operation.
contract IntentLaunchAcceptanceForkTest is Test {
    IntentFactory internal factory = IntentFactory(0x74d88373E92ACA2d47021ac35b87b2A3C97f9DA4);
    GageV2Vault internal core = GageV2Vault(0x5d1F38F8AE8CadA3AFBC32bf201c571568b7D0e7);
    IntentQuoteVerifier internal verifier = IntentQuoteVerifier(0xa5221f7509c50C29b554d0f9b124125762125171);
    IntentFillRouter internal router = IntentFillRouter(0x1d6C35E4dBF53d1d2Bf335FB77FDC5058F57dCb6);
    IERC20 constant usdg = IERC20(0x445b73572C94287D0334375E4589A5d9EEd81b7f);
    IERC20 constant nvda = IERC20(0x153c8D62895B82314f50d83499E5EE50eAC61dB3);
    uint256 constant KEY = 0xACCE97;
    address manager;
    address alice;
    address bob;
    address borrower;
    address filler;
    IntentVault a;
    IntentVault b;
    IntentVault c;

    function setUp() public {
        string memory rpc = vm.envOr("ACCEPTANCE_TESTNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("ACCEPTANCE_TESTNET_BLOCK"));
        assertEq(block.chainid, 46_630);
        _configureDeployment();
        manager = makeAddr("acceptance manager");
        alice = makeAddr("acceptance depositor");
        bob = makeAddr("acceptance later depositor");
        borrower = makeAddr("acceptance borrower");
        filler = makeAddr("acceptance filler");
        vm.startPrank(factory.owner());
        factory.setCreator(manager, true);
        _admitFiller();
        factory.setQuoteSigner(vm.addr(KEY));
        vm.stopPrank();
        a = _create(500);
        b = _create(1500);
        c = _create(1000);
        if (address(a) > address(b)) (a, b) = (b, a);
        IAcceptanceMint(address(usdg)).mint(alice, 1_000_000e6);
        IAcceptanceMint(address(usdg)).mint(bob, 1_000_000e6);
        IAcceptanceMint(address(usdg)).mint(borrower, 10_000e6);
        IAcceptanceMint(address(nvda)).mint(borrower, 100e18);
        vm.prank(borrower);
        nvda.approve(address(core), type(uint256).max);
        vm.prank(borrower);
        usdg.approve(address(core), type(uint256).max);
        _deposit(a, alice, 10_000e6);
        _deposit(b, alice, 10_000e6);
        _deposit(c, alice, 10_000e6);
    }
    function _configureDeployment() internal virtual {}

    function _create(uint16 fee) internal returns (IntentVault vault) {
        return _create(fee, 1000e6);
    }

    /// @dev `perLoan` bounds any one position the vault holds, including a bought one at its price.
    function _create(uint16 fee, uint128 perLoan) internal returns (IntentVault vault) {
        return _createBy(manager, fee, perLoan);
    }

    /// @dev A vault managed by `who`, an admitted creator.
    function _createBy(address who, uint16 fee, uint128 perLoan) internal returns (IntentVault vault) {
        address[] memory assets = new address[](1);
        assets[0] = address(nvda);
        IntentVault.Mandate memory m = IntentVault.Mandate({
            curator: who,
            categoryWeights: [uint16(10_000), 0, 0, 0],
            assets: assets,
            maxLoanTerm: 21 days,
            feeBps: fee,
            minGrade: 0,
            minRateGrade: 0,
            maxLoanPrincipal: perLoan,
            maxAssetBps: 10_000,
            bufferBps: 0,
            executionCapBps: 2000
        });
        vm.prank(who);
        vault = IntentVault(_open(m));
    }

    /// @dev Admits `filler` through the published v9 factory's legacy entry point, paid to the protocol recipient. A
    /// suite that deploys the factory from this source overrides it: that factory admits fillers only.
    function _admitFiller() internal virtual {
        ILegacyFillerAdmission(address(factory)).setFiller(filler, true, factory.protocolRecipient());
    }

    /// @dev Creates through the published v9 factory's legacy entry point. A suite that deploys the factory from this
    /// source overrides it with `create`.
    function _open(IntentVault.Mandate memory m) internal virtual returns (address) {
        return ILegacySecondaryCreate(address(factory)).createWithSecondary(m, true, 300);
    }

    function _deposit(IntentVault vault, address who, uint256 amount) internal {
        vm.startPrank(who);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(amount, 0);
        vm.stopPrank();
    }

    function _list(uint32 term) internal returns (uint256 id) {
        vm.prank(borrower);
        id = core.list(
            Collateral(Kind.ERC20, address(nvda), 10e18), 1000e6, 1100e6, term, uint40(block.timestamp + 1 days), true
        );
    }

    function _plan(uint256 id, bool split) internal view returns (IntentQuoteVerifier.Plan memory p) {
        V2Loan memory l = core.getLoan(id);
        p.engine = address(core);
        p.listingId = id;
        p.filler = filler;
        p.token = l.token;
        p.kind = uint8(l.kind);
        p.collateral = l.collateral;
        p.principal = l.principal;
        p.cap = l.cap;
        p.term = l.term;
        p.costBps = 1000;
        p.feePolicy = verifier.FEE_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 90);
        p.evidence = keccak256("local functional acceptance");
        p.allocations = new IntentQuoteVerifier.Allocation[](split ? 2 : 1);
        for (uint256 i; i < p.allocations.length; i++) {
            IntentVault vault = i == 0 ? a : b;
            uint8 units = split ? 2 : 4;
            p.allocations[i] = IntentQuoteVerifier.Allocation({
                vault: address(vault),
                units: units,
                principal: uint128(1000e6 * units / 4),
                interest: uint128(100e6 * units / 4),
                minimum: 0,
                executionFee: uint128(20e6 * units / 4),
                maxReserveShares: uint128(vault.RESERVE().previewWithdraw(1020e6 * units / 4)),
                minRateGrade: 0,
                capBps: 2000,
                managerBps: vault.feeBps()
            });
        }
    }

    function _fill(uint256 id, bool split) internal {
        IntentQuoteVerifier.Plan memory p = _plan(id, split);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, verifier.planHash(p));
        uint256[] memory limits = new uint256[](p.allocations.length);
        for (uint256 i; i < limits.length; i++) {
            limits[i] = type(uint256).max;
        }
        vm.prank(filler);
        router.fill(p, abi.encodePacked(r, s, v), limits);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _repay(uint256 id) internal {
        vm.prank(borrower);
        core.reclaim(id, borrower);
        vm.prank(borrower);
        core.withdrawCollateral(id, borrower);
    }

    function _maturity(uint256 id) internal view returns (uint256) {
        V2Loan memory l = core.getLoan(id);
        return uint256(l.fundedAt) + l.term;
    }

    /// @dev The mandate version the factory under test reports: 9 for the published v9 deployment read here. A suite
    /// that deploys the factory from this source overrides it.
    function _mandateVersion() internal pure virtual returns (uint256) {
        return 9;
    }

    function test_deployedIdentityAndUncappedDepositRoundtrip() public {
        assertEq(factory.MANDATE_VERSION(), _mandateVersion());
        assertEq(address(core.REWARDS().funderGate()), address(factory));
        uint256 before_ = usdg.balanceOf(bob);
        _deposit(a, bob, 100_000e6);
        uint256 shares = a.balanceOf(bob);
        vm.prank(bob);
        a.redeem(shares, 100_000e6);
        assertEq(usdg.balanceOf(bob), before_);
    }

    function test_pauseStopsEntryAndPreservesCashExit() public {
        vm.prank(manager);
        a.setPaused(true);
        vm.startPrank(bob);
        usdg.approve(address(a), type(uint256).max);
        vm.expectRevert();
        a.deposit(100e6, 0);
        vm.stopPrank();
        uint256 balance = usdg.balanceOf(alice);
        uint256 shares = a.balanceOf(alice);
        vm.prank(alice);
        a.redeem(shares, 10_000e6);
        assertEq(usdg.balanceOf(alice) - balance, 10_000e6);
    }

    function test_singleVaultWholeFundingPaysOnlyQuotedBorrowerProceeds() public {
        uint256 id = _list(7 days);
        uint256 before_ = usdg.balanceOf(borrower);
        _fill(id, false);
        core.withdrawUSDGFor(borrower);
        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE));
        assertEq(l.filled, 4);
        assertEq(core.unitsOf(id, address(a)), 4);
        assertEq(usdg.balanceOf(borrower) - before_, l.principal - l.originationFee);
    }

    function test_twoVaultFundingIsWholeAndBalancesReconcile() public {
        uint256 id = _list(21 days);
        _fill(id, true);
        assertEq(core.unitsOf(id, address(a)), 2);
        assertEq(core.unitsOf(id, address(b)), 2);
        assertEq(a.performingPrincipal(), 500e6);
        assertEq(b.performingPrincipal(), 500e6);
        assertGe(usdg.balanceOf(address(router)), router.totalOwed());
    }

    function test_fiveMinuteTestnetTermRepays() public virtual {
        uint256 id = _list(300);
        _fill(id, false);
        vm.warp(block.timestamp + 150);
        _repay(id);
        a.settle(_ids(id));
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID));
    }

    function test_twentyMinuteTestnetTermDefaults() public virtual {
        uint256 id = _list(1200);
        _fill(id, false);
        vm.warp(_maturity(id));
        a.settle(_ids(id));
        a.recover(id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED));
        assertEq(a.pocketCount(), 1);
    }

    /// @dev The published v9 vaults' D29 schedule: an early repayment's unearned interest is released into the price
    /// until the original end. A suite built from this source overrides it with D51's earnings claim.
    function test_earlyRepaymentReturnsCollateralAndAccruesToOriginalEnd() public virtual {
        uint256 id = _list(7 days);
        _fill(id, false);
        vm.warp(block.timestamp + 1 days);
        uint256 assets = a.totalAssets();
        _repay(id);
        a.settle(_ids(id));
        assertApproxEqAbs(a.totalAssets(), assets, 1);
        assertEq(nvda.balanceOf(borrower), 100e18);
        assertEq(a.performingPrincipal(), 0);
        vm.warp(_maturity(id));
        a.settle(_ids(id));
        assertEq(a.totalAssets(), 10_000e6 + 80e6 - uint256(80e6) * a.feeBps() / 10_000);
    }

    /// @dev Repaid and booked in the fill second, as the published v9 vaults allow. A suite built from this source
    /// overrides it: D51 books a repayment in the window's opening second from the next second.
    function test_performanceFeesPayManagerAndProtocolExactlyOnce() public virtual {
        uint256 id = _list(7 days);
        _fill(id, false);
        _repay(id);
        a.settle(_ids(id));
        uint256 managerFee = a.curatorFees();
        uint256 protocolFee = a.protocolFees();
        assertGt(managerFee, 0);
        assertEq(managerFee + protocolFee, uint256(80e6) * a.feeBps() / 10_000);
        uint256 m0 = usdg.balanceOf(manager);
        uint256 p0 = usdg.balanceOf(factory.protocolRecipient());
        a.claimFees();
        assertEq(usdg.balanceOf(manager) - m0, managerFee);
        assertEq(usdg.balanceOf(factory.protocolRecipient()) - p0, protocolFee);
        a.claimFees();
        assertEq(usdg.balanceOf(manager) - m0, managerFee);
    }

    function test_defaultHasNoManagerFeeAndCollateralGoesToRecordedHolders() public {
        uint256 id = _list(7 days);
        _fill(id, false);
        vm.warp(_maturity(id));
        a.settle(_ids(id));
        a.recover(id);
        assertEq(a.curatorFees(), 0);
        assertEq(a.protocolFees(), 0);
        assertEq(a.pocketClaimable(1, alice), 10e18);
        _deposit(a, bob, 100e6);
        assertEq(a.pocketClaimable(1, bob), 0);
        vm.prank(alice);
        a.claimPocket(1);
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    function test_repayOneSecondBeforeExpiry() public {
        uint256 id = _list(7 days);
        _fill(id, false);
        vm.warp(_maturity(id) - 1);
        _repay(id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID));
    }

    function test_defaultOnlyAtExpiry() public {
        uint256 id = _list(7 days);
        _fill(id, false);
        vm.warp(_maturity(id) - 1);
        vm.expectRevert();
        core.finalizeDefault(id);
        vm.warp(_maturity(id));
        core.finalizeDefault(id);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.DEFAULTED));
    }

    function test_idleLiquidityWithdrawsDuringAnActiveLoan() public {
        uint256 id = _list(7 days);
        _fill(id, false);
        uint256 before_ = usdg.balanceOf(alice);
        uint256 shares = a.convertToShares(100e6);
        vm.prank(alice);
        a.redeem(shares, 99e6);
        assertGe(usdg.balanceOf(alice) - before_, 99e6);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.ACTIVE));
    }

    function test_walletFundingRefusedByDeployedFunderGate() public {
        uint256 id = _list(7 days);
        vm.startPrank(alice);
        usdg.approve(address(core), type(uint256).max);
        vm.expectRevert(GageV2Rewards.NotFunder.selector);
        core.fund(id, 4);
        vm.stopPrank();
        assertEq(core.getLoan(id).filled, 0);
    }

    function test_unfundedListingCancellationReturnsAllCollateral() public {
        uint256 id = _list(7 days);
        vm.prank(borrower);
        core.cancelFunding(id);
        vm.prank(borrower);
        core.withdrawCollateral(id, borrower);
        assertEq(nvda.balanceOf(borrower), 100e18);
        assertEq(uint8(core.getLoan(id).state), uint8(V2State.CANCELLED));
    }
}
