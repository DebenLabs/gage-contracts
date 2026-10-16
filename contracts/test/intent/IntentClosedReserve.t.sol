// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IntentClosedReserve} from "../../src/intent/IntentClosedReserve.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The closed reserve alone: an ERC-4626 over the lent asset that nothing enters, whose every view answers one
/// to one, donations included. `IntentAssetGeneration.t.sol` runs it under a whole generation.
contract IntentClosedReserveTest is Test {
    MockERC20 internal gld;
    IntentClosedReserve internal reserve;
    address internal alice = makeAddr("alice");

    function setUp() public {
        gld = new MockERC20("GLD", "GLD", 18);
        reserve = new IntentClosedReserve(IERC20(address(gld)));
        gld.mint(alice, 1000e18);
        vm.prank(alice);
        gld.approve(address(reserve), type(uint256).max);
    }

    function test_isAnErc4626OverTheAssetThatHoldsNothing() public view {
        assertEq(reserve.asset(), address(gld));
        assertEq(reserve.decimals(), 18);
        assertEq(reserve.name(), "gage closed reserve");
        assertEq(reserve.symbol(), "gage-closed");
        assertEq(reserve.totalAssets(), 0);
        assertEq(reserve.totalSupply(), 0);
        assertEq(reserve.maxDeposit(alice), 0);
        assertEq(reserve.maxMint(alice), 0);
        assertEq(reserve.maxWithdraw(alice), 0);
        assertEq(reserve.maxRedeem(alice), 0);
    }

    /// @dev A six-decimal asset gives six-decimal shares: no offset.
    function test_sharesTakeTheAssetsDecimals() public {
        IntentClosedReserve six = new IntentClosedReserve(IERC20(address(new MockERC20("USDG", "USDG", 6))));
        assertEq(six.decimals(), 6);
    }

    function test_noDepositOrMintEnters() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1e18, 0));
        reserve.deposit(1e18, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, alice, 1e18, 0));
        reserve.mint(1e18, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1, 0));
        reserve.deposit(1, alice);
        // A zero amount passes the zero maximums and moves nothing.
        assertEq(reserve.deposit(0, alice), 0);
        assertEq(reserve.mint(0, alice), 0);
        vm.stopPrank();
        assertEq(gld.balanceOf(alice), 1000e18);
        assertEq(gld.balanceOf(address(reserve)), 0);
        assertEq(reserve.totalSupply(), 0);
        assertEq(reserve.balanceOf(alice), 0);
    }

    function test_nothingCanLeave() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, 1, 0));
        reserve.withdraw(1, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, 1, 0));
        reserve.redeem(1, alice, alice);
        vm.stopPrank();
    }

    /// @dev A token sent here is lost to its sender: it moves no view, so it cannot move a signed plan's reserve bound,
    /// and no share exists to take it out.
    function test_aDonationMovesNoView() public {
        vm.prank(alice);
        gld.transfer(address(reserve), 500e18);
        assertEq(gld.balanceOf(address(reserve)), 500e18);
        assertEq(reserve.totalAssets(), 0);
        assertEq(reserve.previewWithdraw(101e18), 101e18);
        assertEq(reserve.convertToAssets(0), 0);
        assertEq(reserve.maxWithdraw(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, 1, 0));
        reserve.redeem(1, alice, alice);
    }

    /// @dev No allowance a holder gives makes a share: there is none to spend.
    function test_anAllowanceMovesNothing() public {
        vm.prank(alice);
        reserve.approve(address(this), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        reserve.transferFrom(alice, address(this), 1);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Every conversion is one to one, whatever was sent here.
    function testFuzz_everyConversionIsOneToOne(uint256 amount, uint256 donation) public {
        amount = bound(amount, 0, type(uint128).max);
        donation = bound(donation, 0, 1000e18);
        vm.prank(alice);
        gld.transfer(address(reserve), donation);
        IERC4626 r = IERC4626(address(reserve));
        assertEq(r.totalAssets(), 0);
        assertEq(r.convertToShares(amount), amount);
        assertEq(r.convertToAssets(amount), amount);
        assertEq(r.previewDeposit(amount), amount);
        assertEq(r.previewMint(amount), amount);
        assertEq(r.previewWithdraw(amount), amount);
        assertEq(r.previewRedeem(amount), amount);
    }

    /// @dev Nobody deposits or mints any amount for anybody.
    function testFuzz_nothingEnters(address caller, address receiver, uint256 amount) public {
        vm.assume(caller != address(0));
        amount = bound(amount, 1, type(uint128).max);
        assertEq(reserve.maxDeposit(receiver), 0);
        assertEq(reserve.maxMint(receiver), 0);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, receiver, amount, 0));
        reserve.deposit(amount, receiver);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxMint.selector, receiver, amount, 0));
        reserve.mint(amount, receiver);
        vm.stopPrank();
        assertEq(reserve.totalSupply(), 0);
    }
}
