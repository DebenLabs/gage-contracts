// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralRegistry} from "../../src/CollateralRegistry.sol";
import {DealVault} from "../../src/DealVault.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {Kind, Collateral} from "../../src/types/Types.sol";
import {DealState} from "../../src/interfaces/IDealVault.sol";
import {Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @notice M1 exit test: a full deal lifecycle on a fork of Robinhood Chain with a real Stock Token and real USDG.
/// @dev Runs only when ROBINHOOD_RPC_URL is set and addresses.json marks USDG and NVDA as VERIFIED. Until then the
///      whole contract is skipped. Pin the block with FORK_BLOCK so CI is reproducible.
contract LifecycleForkTest is Test {
    IERC20 internal usdg;
    IERC20 internal nvda;
    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");

    CollateralRegistry internal registry;
    DealVault internal vault;
    FeeSink internal feeSink;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        string memory json = vm.readFile("addresses.json");
        if (!_verified(json, ".tokens.USDG") || !_verified(json, ".stockTokens.NVDA")) {
            vm.skip(true);
            return;
        }
        uint256 block_ = vm.envOr("FORK_BLOCK", uint256(0));
        if (block_ == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, block_);

        usdg = IERC20(vm.parseJsonAddress(json, ".tokens.USDG.address"));
        nvda = IERC20(vm.parseJsonAddress(json, ".stockTokens.NVDA.address"));

        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        registry = new CollateralRegistry(safe, terms, 50);
        feeSink = new FeeSink(usdg, safe, treasury);
        vault = new DealVault(usdg, registry, address(feeSink), address(0), 48 hours);
        vm.startPrank(safe);
        feeSink.setVault(vault);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 1000e18, 5000e18);
        vm.stopPrank();

        // Real tokens: fund the actors by rewriting balances in storage. If a token's layout defeats `deal`,
        // impersonate a large holder instead (vm.prank on an address from the explorer).
        deal(address(nvda), borrower, 100e18);
        deal(address(usdg), lender, 20_000 * 10 ** _decimals(usdg));
        deal(address(usdg), borrower, 20_000 * 10 ** _decimals(usdg));
    }

    function test_fork_fullLifecycle_reclaim() public {
        uint128 unit = uint128(10 ** _decimals(usdg));
        uint128 cap = 8000 * unit;
        uint128 price = 7960 * unit;

        vm.startPrank(borrower);
        nvda.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        uint256 id = vault.list(
            Collateral({kind: Kind.ERC20, token: address(nvda), amountOrTokenId: 100e18}),
            cap,
            7 days,
            uint40(block.timestamp + 3 days),
            0
        );
        vm.stopPrank();

        vm.startPrank(lender);
        usdg.approve(address(vault), type(uint256).max);
        uint256 bidId = vault.bid(id, price, uint40(block.timestamp + 1 days), lender);
        vm.stopPrank();

        vm.prank(borrower);
        vault.accept(id, bidId);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.FUNDED));

        vm.warp(block.timestamp + 6 days);
        vm.prank(borrower);
        vault.reclaim(id);
        vm.prank(borrower);
        vault.withdrawERC20(address(nvda));
        vm.prank(lender);
        vault.withdrawUSDG();

        assertEq(nvda.balanceOf(borrower), 100e18, "NVDA back with the borrower");
        assertEq(vault.balanceUSDG(lender), 0);
        assertEq(usdg.balanceOf(address(vault)), price, "borrower proceeds + fee still credited");
    }

    function test_fork_fullLifecycle_walkAway() public {
        uint128 unit = uint128(10 ** _decimals(usdg));
        vm.startPrank(borrower);
        nvda.approve(address(vault), type(uint256).max);
        uint256 id = vault.list(
            Collateral({kind: Kind.ERC20, token: address(nvda), amountOrTokenId: 100e18}),
            8000 * unit,
            7 days,
            uint40(block.timestamp + 3 days),
            0
        );
        vm.stopPrank();
        vm.startPrank(lender);
        usdg.approve(address(vault), type(uint256).max);
        uint256 bidId = vault.bid(id, 7960 * unit, uint40(block.timestamp + 1 days), lender);
        vm.stopPrank();
        vm.prank(borrower);
        vault.accept(id, bidId);

        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.prank(lender);
        vault.withdrawERC20(address(nvda));
        assertEq(nvda.balanceOf(lender), 100e18, "lender holds the NVDA");
    }

    function _verified(string memory json, string memory key) internal pure returns (bool) {
        return keccak256(bytes(vm.parseJsonString(json, string.concat(key, ".status")))) == keccak256("VERIFIED");
    }

    function _decimals(IERC20 token) internal view returns (uint8) {
        (bool ok, bytes memory data) = address(token).staticcall(abi.encodeWithSignature("decimals()"));
        return ok && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
    }
}
