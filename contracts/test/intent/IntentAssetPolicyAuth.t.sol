// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {IntentAssetPolicy} from "../../src/intent/IntentAssetPolicy.sol";

contract PolicyCategoryFixture {
    function eligibleCategory(address, uint8) external pure returns (uint8) {
        return 0;
    }
}

contract IntentAssetPolicyAuthTest is Test {
    function testOnlyTheCreatingVaultCanSubmitAnActorOrChangePolicy() public {
        address curator = address(123);
        address token = address(456);
        IntentAssetPolicy policy = new IntentAssetPolicy(
            address(0), curator, address(new PolicyCategoryFixture()), address(0), 1, 1, new address[](0), false, 0
        );
        vm.prank(curator);
        vm.expectRevert(IntentAssetPolicy.NotVault.selector);
        policy.update(token, 1, curator);
        vm.expectRevert(IntentAssetPolicy.NotCurator.selector);
        policy.update(token, 1, address(999));
        assertEq(policy.readyAt(token), 0);
        policy.update(token, 1, curator);
        assertEq(policy.readyAt(token), block.timestamp + 3 hours);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(curator);
        vm.expectRevert(IntentAssetPolicy.NotVault.selector);
        policy.update(token, 2, curator);
        policy.update(token, 2, address(999));
        assertTrue(policy.picked(token));
    }
}
