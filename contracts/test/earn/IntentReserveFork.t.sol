// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice Opt-in local fork characterization; never broadcasts and is skipped in normal CI.
contract IntentReserveForkTest is Test {
    IERC4626 internal constant RESERVE = IERC4626(0xBeEff033F34C046626B8D0A041844C5d1A5409dd);
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function setUp() public {
        string memory rpc = vm.envOr("INTENT_S0_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // An explicit pinned block avoids a moving reference. Only the fork VM is mutated.
        vm.createSelectFork(rpc, vm.envUint("INTENT_S0_FORK_BLOCK"));
        assertEq(block.chainid, 4663);
        vm.chainId(46_630);
        assertEq(RESERVE.asset(), USDG);
    }

    function testRealReserveRoundTripDespiteConservativeMaxWithdraw() public {
        address depositor = makeAddr("intent-s0-local-depositor");
        uint256 assets = 100e6;
        // Seed only this account's local fork balance; no faucet, mint or transfer is sent on mainnet.
        deal(USDG, depositor, assets);
        vm.startPrank(depositor);
        IERC20(USDG).approve(address(RESERVE), assets);
        uint256 shares = RESERVE.deposit(assets, depositor);
        assertGt(shares, 0);
        assertEq(IERC20(USDG).balanceOf(depositor), 0);
        assertEq(RESERVE.maxWithdraw(depositor), 0);
        // One raw unit accommodates normal conversion rounding, rather than assuming an exact reverse mint.
        uint256 withdrawn = assets - 1;
        uint256 burned = RESERVE.withdraw(withdrawn, depositor, depositor);
        assertGt(burned, 0);
        assertLe(burned, shares);
        assertEq(IERC20(USDG).balanceOf(depositor), withdrawn);
        vm.stopPrank();
    }
}
