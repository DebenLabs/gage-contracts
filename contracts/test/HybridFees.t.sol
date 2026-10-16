// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EarnBaseTest} from "./EarnBase.t.sol";
import {HybridVault} from "../src/HybridVault.sol";
import {HybridFees} from "../src/HybridFees.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The fee companion is only a splitter: the strategy charges, the companion divides and pays on request.
contract HybridFeesTest is EarnBaseTest {
    function setUp() public override {
        super.setUp();
        vm.prank(curator);
        hybrid.setFee(1000);
    }

    function _deposit(address who, uint256 assets) internal {
        vm.prank(who);
        hybrid.deposit(assets, 0);
    }

    function _settledRepayment(uint128 principal) internal returns (uint256 id) {
        id = _listed(principal);
        _approve(id);
        hybrid.fund(id, type(uint256).max);
        _repay(id);
        hybrid.settle(_ids(id));
    }

    /// @dev Credit USDG to the companion the way the strategy does, then ask it to split.
    function _distribute(uint256 amount) internal {
        usdg.mint(address(hybridFees), amount);
        vm.prank(address(hybrid));
        hybridFees.distribute(amount);
    }

    function test_constructorBoundsAndIdentity() public {
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(address(hybrid), 10_001, floor, curator);
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(address(hybrid), 1, makeAddr("no-code"), curator);
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(address(hybrid), 1, address(0), curator);
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(address(hybrid), 0, address(0), address(0));
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(address(hybrid), 0, address(0), address(hybrid));
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(address(hybrid), 0, address(0), self);
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        new HybridFees(makeAddr("no-code"), 0, address(0), curator);
        vm.expectRevert();
        new HybridFees(address(usdg), 0, address(0), curator);
        // Zero protocol share needs no floor route; the whole range up to 100% is accepted.
        vm.expectEmit(true, false, false, true);
        emit HybridFees.CuratorRecipientSet(treasury);
        HybridFees companion = new HybridFees(address(hybrid), 0, address(0), treasury);
        assertEq(address(companion.STRATEGY()), address(hybrid));
        assertEq(address(companion.USDG()), address(usdg));
        assertEq(companion.CURATOR(), curator);
        assertEq(companion.PROTOCOL_SHARE_BPS(), 0);
        assertEq(companion.PROTOCOL_RECIPIENT(), address(0));
        assertEq(companion.curatorRecipient(), treasury);
        assertEq(companion.curatorAccrued(), 0);
        assertEq(companion.protocolAccrued(), 0);
        HybridFees all = new HybridFees(address(hybrid), 10_000, floor, curator);
        assertEq(all.PROTOCOL_SHARE_BPS(), 10_000);
        assertEq(hybridFees.PROTOCOL_SHARE_BPS(), 2500);
        assertEq(hybridFees.PROTOCOL_RECIPIENT(), floor);
    }

    function test_distributeOnlyByTheStrategyAndOnlyOnceTheUSDGArrived() public {
        vm.expectRevert(HybridFees.NotStrategy.selector);
        hybridFees.distribute(1);
        vm.prank(curator);
        vm.expectRevert(HybridFees.NotStrategy.selector);
        hybridFees.distribute(1);
        vm.prank(address(hybrid));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.distribute(1);
        usdg.mint(address(hybridFees), 1e6);
        vm.prank(address(hybrid));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.distribute(1e6 + 1);
        vm.expectEmit(false, false, false, true);
        emit HybridFees.FeesDistributed(1e6, 0.75e6, 0.25e6);
        vm.prank(address(hybrid));
        hybridFees.distribute(1e6);
        assertEq(hybridFees.curatorAccrued(), 0.75e6);
        assertEq(hybridFees.protocolAccrued(), 0.25e6);
        // The same USDG cannot be counted twice.
        vm.prank(address(hybrid));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.distribute(1);
        // Paying out does not free room for a replay either.
        hybridFees.claimCurator();
        vm.prank(address(hybrid));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.distribute(1);
        hybridFees.claimProtocol();
        vm.prank(address(hybrid));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.distribute(1);
    }

    function test_splitRoundingFavoursTheCuratorAndConservesEveryUnit() public {
        uint256[4] memory amounts = [uint256(1), 3, 4, 5];
        uint256[4] memory protocol = [uint256(0), 0, 1, 1];
        uint256 curatorTotal;
        uint256 protocolTotal;
        for (uint256 i; i < 4; ++i) {
            _distribute(amounts[i]);
            curatorTotal += amounts[i] - protocol[i];
            protocolTotal += protocol[i];
            assertEq(hybridFees.curatorAccrued(), curatorTotal);
            assertEq(hybridFees.protocolAccrued(), protocolTotal);
        }
        assertEq(usdg.balanceOf(address(hybridFees)), curatorTotal + protocolTotal);
        assertEq(hybridFees.claimCurator(), 11);
        assertEq(hybridFees.claimProtocol(), 2);
        assertEq(usdg.balanceOf(address(hybridFees)), 0);
        // Whole-share companions send everything one way.
        HybridFees all = new HybridFees(address(hybrid), 10_000, floor, curator);
        usdg.mint(address(all), 7);
        vm.prank(address(hybrid));
        all.distribute(7);
        assertEq(all.protocolAccrued(), 7);
        assertEq(all.curatorAccrued(), 0);
        vm.expectRevert(HybridFees.InvalidAmount.selector);
        all.claimCurator();
        HybridFees none = new HybridFees(address(hybrid), 0, address(0), curator);
        usdg.mint(address(none), 7);
        vm.prank(address(hybrid));
        none.distribute(7);
        assertEq(none.curatorAccrued(), 7);
        assertEq(none.protocolAccrued(), 0);
        vm.expectRevert(HybridFees.InvalidAmount.selector);
        none.claimProtocol();
    }

    function test_claimsArePullOnlyAndAnyoneMayTriggerThem() public {
        vm.expectRevert(HybridFees.InvalidAmount.selector);
        hybridFees.claimCurator();
        vm.expectRevert(HybridFees.InvalidAmount.selector);
        hybridFees.claimProtocol();
        _distribute(4e6);
        uint256 curatorBefore = usdg.balanceOf(curator);
        vm.expectEmit(true, false, false, true);
        emit HybridFees.CuratorFeesClaimed(curator, 3e6);
        vm.prank(other);
        assertEq(hybridFees.claimCurator(), 3e6);
        assertEq(usdg.balanceOf(curator) - curatorBefore, 3e6);
        assertEq(hybridFees.curatorAccrued(), 0);
        vm.prank(other);
        vm.expectRevert(HybridFees.InvalidAmount.selector);
        hybridFees.claimCurator();
        assertEq(hybridFees.protocolAccrued(), 1e6, "the protocol share waits for its own claim");
        vm.expectEmit(true, false, false, true);
        emit HybridFees.ProtocolFeesClaimed(floor, 1e6);
        vm.prank(lender);
        assertEq(hybridFees.claimProtocol(), 1e6);
        assertEq(usdg.balanceOf(floor), 1e6);
        assertEq(usdg.balanceOf(address(hybridFees)), 0);
    }

    function test_failedPaymentsKeepTheAccrual() public {
        _distribute(4e6);
        usdg.setBlocked(floor, true);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, floor));
        hybridFees.claimProtocol();
        assertEq(hybridFees.protocolAccrued(), 1e6);
        usdg.setBlocked(floor, false);
        usdg.setPaused(true);
        vm.expectRevert(MockERC20.EnforcedPause.selector);
        hybridFees.claimCurator();
        usdg.setPaused(false);
        vm.mockCall(address(usdg), abi.encodeWithSelector(usdg.transfer.selector, curator, 3e6), abi.encode(false));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.claimCurator();
        vm.clearMockedCalls();
        vm.mockCall(address(usdg), abi.encodeWithSelector(usdg.transfer.selector, curator, 3e6), abi.encode(true));
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.claimCurator();
        vm.clearMockedCalls();
        assertEq(hybridFees.curatorAccrued(), 3e6);
        // Both tokens share the OpenZeppelin layout: a token that starts taxing transfers is rejected too.
        vm.etch(address(usdg), address(feeToken).code);
        vm.expectRevert(HybridFees.TransferAmountMismatch.selector);
        hybridFees.claimCurator();
        assertEq(hybridFees.curatorAccrued(), 3e6);
        assertEq(hybridFees.protocolAccrued(), 1e6);
        assertEq(usdg.balanceOf(address(hybridFees)), 4e6);
    }

    function test_setCuratorRecipientBoundsAndPermissions() public {
        vm.expectRevert(HybridFees.NotCurator.selector);
        hybridFees.setCuratorRecipient(treasury);
        vm.prank(address(hybrid));
        vm.expectRevert(HybridFees.NotCurator.selector);
        hybridFees.setCuratorRecipient(treasury);
        vm.startPrank(curator);
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        hybridFees.setCuratorRecipient(address(0));
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        hybridFees.setCuratorRecipient(address(hybrid));
        vm.expectRevert(HybridFees.InvalidConfiguration.selector);
        hybridFees.setCuratorRecipient(address(hybridFees));
        vm.expectEmit(true, false, false, true);
        emit HybridFees.CuratorRecipientSet(treasury);
        hybridFees.setCuratorRecipient(treasury);
        vm.stopPrank();
        assertEq(hybridFees.curatorRecipient(), treasury);
        // Whatever has accrued is paid to the recipient of the moment; the curator identity never changes.
        _distribute(4e6);
        uint256 before_ = usdg.balanceOf(treasury);
        hybridFees.claimCurator();
        assertEq(usdg.balanceOf(treasury) - before_, 3e6);
        assertEq(hybridFees.CURATOR(), curator);
        vm.prank(treasury);
        vm.expectRevert(HybridFees.NotCurator.selector);
        hybridFees.setCuratorRecipient(curator);
    }

    function test_endToEndFromARepaymentToBothRecipients() public {
        _deposit(lender, 2000e6);
        vm.prank(curator);
        hybridFees.setCuratorRecipient(treasury);
        _settledRepayment(1000e6);
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(hybrid.cash(), 2045e6);
        uint256 assets = hybrid.totalAssets();
        // The strategy hands the fee over on anyone's call; the split lands in the companion, nothing is paid yet.
        vm.expectEmit(true, false, false, true);
        emit HybridVault.FeesClaimed(address(hybridFees), 5e6);
        vm.prank(other);
        hybrid.claimFees();
        assertEq(hybrid.feeAccrued(), 0);
        assertEq(hybrid.cash(), 2045e6);
        assertEq(hybrid.totalAssets(), assets, "the fee was never part of the share price");
        assertEq(usdg.balanceOf(address(hybridFees)), 5e6);
        assertEq(hybridFees.curatorAccrued(), 3.75e6);
        assertEq(hybridFees.protocolAccrued(), 1.25e6);
        assertEq(usdg.balanceOf(treasury), 1_000_000e6);
        assertEq(usdg.balanceOf(floor), 0);
        vm.prank(other);
        assertEq(hybridFees.claimCurator(), 3.75e6);
        vm.prank(other);
        assertEq(hybridFees.claimProtocol(), 1.25e6);
        assertEq(usdg.balanceOf(treasury), 1_000_000e6 + 3.75e6);
        assertEq(usdg.balanceOf(floor), 1.25e6);
        assertEq(usdg.balanceOf(address(hybridFees)), 0);
        vm.expectRevert(HybridVault.InvalidAmount.selector);
        hybrid.claimFees();
        // Fees from later loans accumulate in the strategy until the next hand-over.
        _settledRepayment(1000e6);
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(usdg.balanceOf(address(hybrid)), hybrid.cash() + hybrid.feeAccrued());
    }

    function test_handOverFailsWholeWhenTheCompanionCannotAccount() public {
        _deposit(lender, 2000e6);
        _settledRepayment(1000e6);
        vm.mockCallRevert(address(hybridFees), abi.encodeWithSelector(hybridFees.distribute.selector), "companion down");
        vm.expectRevert(bytes("companion down"));
        hybrid.claimFees();
        vm.clearMockedCalls();
        assertEq(hybrid.feeAccrued(), 5e6);
        assertEq(usdg.balanceOf(address(hybridFees)), 0);
        usdg.setBlocked(address(hybridFees), true);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.BlockedAccount.selector, address(hybridFees)));
        hybrid.claimFees();
        usdg.setBlocked(address(hybridFees), false);
        hybrid.claimFees();
        assertEq(hybridFees.curatorAccrued() + hybridFees.protocolAccrued(), 5e6);
    }
}
