// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealVault} from "../../src/DealVault.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {IDealVault, DealState, Deal, BidState, Bid} from "../../src/interfaces/IDealVault.sol";
import {Kind, Collateral} from "../../src/types/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Runs against a live testnet deployment after E2E.s.sol: the walk-away branch under time warp, the guards
///         that cannot be exercised with real transactions (reverts), and solvency over the real state.
/// @dev Env: GAGE_DEPLOYMENT (deployment json), GAGE_E2E_RPC (rpc url). Skips itself when either is unset.
contract TestnetDeploymentForkTest is Test {
    DealVault internal vault;
    CollateralRegistry internal registry;
    FeeSink internal feeSink;
    MockERC20 internal usdg;
    MockERC20 internal nvda;
    address internal deployer;
    address internal borrower;
    address internal lender;

    function setUp() public {
        string memory path = vm.envOr("GAGE_DEPLOYMENT", string(""));
        string memory rpc = vm.envOr("GAGE_E2E_RPC", string(""));
        if (bytes(path).length == 0 || bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment is for another chain");
        vault = DealVault(vm.parseJsonAddress(json, ".DealVault"));
        registry = CollateralRegistry(vm.parseJsonAddress(json, ".CollateralRegistry"));
        feeSink = FeeSink(vm.parseJsonAddress(json, ".FeeSink"));
        usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        nvda = MockERC20(vm.parseJsonAddress(json, ".NVDAx"));
        deployer = vm.parseJsonAddress(json, ".deployer");
        borrower = vm.parseJsonAddress(json, ".borrower");
        lender = vm.parseJsonAddress(json, ".lender");
    }

    /// @dev The FUNDED deal E2E.s.sol left behind: claim reverts inside grace, succeeds after, reclaim then reverts.
    function test_live_walkAwayBranchUnderWarp() public {
        uint256 id = _fundedDeal();
        Deal memory d = vault.getDeal(id);
        uint40 at = vault.claimableAt(id);
        assertEq(at, uint256(d.expiry) + vault.GRACE());

        if (block.timestamp < at) {
            vm.expectRevert(abi.encodeWithSelector(IDealVault.GraceNotOver.selector, at));
            vm.prank(d.lender);
            vault.claim(id);
            vm.warp(at);
        }
        uint256 before = nvda.balanceOf(d.lender);
        vm.prank(d.lender);
        vault.claim(id);
        vm.prank(d.lender);
        vault.withdrawERC20(d.token);
        assertEq(nvda.balanceOf(d.lender), before + d.amountOrTokenId, "lender holds the collateral");

        vm.expectRevert(abi.encodeWithSelector(IDealVault.DealNotFunded.selector, id));
        vm.prank(d.borrower);
        vault.reclaim(id);
    }

    /// @dev The borrower keeps the reclaim right through the whole grace window on the live deal.
    function test_live_reclaimStillPossibleInsideGrace() public {
        uint256 id = _fundedDeal();
        Deal memory d = vault.getDeal(id);
        vm.warp(vault.claimableAt(id) - 1);
        uint256 lenderBefore = vault.balanceUSDG(d.lender);
        deal(address(usdg), d.borrower, d.cap);
        vm.startPrank(d.borrower);
        usdg.approve(address(vault), d.cap);
        vault.reclaim(id);
        vm.stopPrank();
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED));
        assertEq(vault.balanceUSDG(d.lender), lenderBefore + d.cap, "exactly cap credited");
    }

    function test_live_pauseBlocksOnlyNewDeals() public {
        uint256 id = _fundedDeal();
        vm.prank(registry.owner());
        registry.pauseNewDeals(true);

        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        vm.prank(borrower);
        vault.list(
            Collateral({kind: Kind.ERC20, token: address(nvda), amountOrTokenId: 1e18}),
            10e6,
            1 days,
            uint40(block.timestamp + 1 days),
            0
        );

        Deal memory d = vault.getDeal(id);
        deal(address(usdg), d.borrower, d.cap);
        vm.startPrank(d.borrower);
        usdg.approve(address(vault), d.cap);
        vault.reclaim(id);
        vm.stopPrank();
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.RECLAIMED), "reclaim works while paused");
    }

    function test_live_registryOwnerCannotTouchFunds() public {
        // The registry owner can only reach registry setters; the vault has no owner-facing function at all.
        (bool ok,) = address(vault).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "vault has no owner()");
        (ok,) = address(vault).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "vault has no pause()");
        (ok,) = address(vault).call(abi.encodeWithSignature("sweep(address,uint256)", address(usdg), 1));
        assertFalse(ok, "vault has no sweep()");
    }

    /// @dev I5 over the live state: vault USDG covers every open bid plus every balance of the known accounts.
    function test_live_solvency() public view {
        uint256 openBids;
        for (uint256 i = 1; i <= vault.bidCount(); ++i) {
            Bid memory b = vault.getBid(i);
            if (b.state == BidState.OPEN) openBids += b.price;
        }
        uint256 balances = vault.balanceUSDG(borrower) + vault.balanceUSDG(lender) + vault.balanceUSDG(deployer)
            + vault.balanceUSDG(address(feeSink));
        assertGe(usdg.balanceOf(address(vault)), openBids + balances, "I5 on live state");
        assertEq(usdg.balanceOf(address(vault)), openBids + balances, "no stray USDG in the vault");
    }

    function test_live_collateralConserved() public view {
        uint256 escrowed;
        for (uint256 i = 1; i <= vault.dealCount(); ++i) {
            Deal memory d = vault.getDeal(i);
            if (d.token != address(nvda)) continue;
            if (d.state == DealState.LISTED || d.state == DealState.FUNDED) escrowed += d.amountOrTokenId;
        }
        assertEq(vault.openRaw(address(nvda)), escrowed, "openRaw matches open deals");
        uint256 owed = vault.balanceERC20(borrower, address(nvda)) + vault.balanceERC20(lender, address(nvda));
        assertEq(nvda.balanceOf(address(vault)), escrowed + owed, "I1 on live state");
    }

    function _fundedDeal() internal view returns (uint256) {
        for (uint256 i = vault.dealCount(); i >= 1; --i) {
            if (vault.getDeal(i).state == DealState.FUNDED) return i;
        }
        revert("no FUNDED deal on this deployment; run E2E.s.sol first");
    }
}
