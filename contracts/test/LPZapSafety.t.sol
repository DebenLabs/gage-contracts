// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LPZapRouterTest} from "./LPZapRouter.t.sol";
import {LPZapRouter} from "../src/LPZapRouter.sol";
import {LPZapQuoter} from "../src/LPZapQuoter.sol";
import {Deal, DealState} from "../src/interfaces/IDealVault.sol";

/// @notice Random interleavings across four users exercise the newly introduced vault, not the original vault.
contract LPZapSafetyTest is LPZapRouterTest {
    function test_nonReceiverCanZapAndRecoverToAnotherWallet() public {
        vm.etch(borrower, hex"60006000fd");
        (uint256 id, uint256 nft) = _zap();
        vm.prank(borrower);
        zvault.cancel(id);
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPosition(nft);
        assertTrue(zvault.owedNFT(borrower, nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), address(zvault));
        vm.prank(borrower);
        zvault.withdrawPositionTo(nft, other);
        assertFalse(zvault.owedNFT(borrower, nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), other);
    }

    function test_alternateRecipientRequiresOwnerAndCannotDoubleWithdraw() public {
        (uint256 id, uint256 nft) = _zap();
        vm.prank(borrower);
        zvault.cancel(id);
        vm.prank(other);
        vm.expectRevert();
        zvault.withdrawPositionTo(nft, other);
        vm.prank(borrower);
        zvault.withdrawPositionTo(nft, other);
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPosition(nft);
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPositionTo(nft, borrower);
        assertEq(IERC721(address(posm)).ownerOf(nft), other);
    }

    function test_failedAlternateRecipientPreservesCreditAndCannotWithdrawEscrow() public {
        (uint256 id, uint256 nft) = _zap();
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPositionTo(nft, other);
        vm.prank(borrower);
        zvault.cancel(id);
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPositionTo(nft, address(0));
        vm.etch(other, hex"60006000fd");
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPositionTo(nft, other);
        assertTrue(zvault.owedNFT(borrower, nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), address(zvault));
        vm.prank(borrower);
        zvault.withdrawPositionTo(nft, borrower);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function test_onlyLenderCanChooseRecipientAfterDefault() public {
        (uint256 id, uint256 nft) = _zap();
        vm.prank(lender);
        zvault.fund(id, lender);
        vm.warp(zvault.claimableAt(id));
        vm.prank(lender);
        zvault.claim(id);
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPositionTo(nft, borrower);
        vm.prank(lender);
        zvault.withdrawPositionTo(nft, other);
        assertEq(IERC721(address(posm)).ownerOf(nft), other);
    }

    function testFuzz_interleavedZapCustodyAndSolvency(uint256 seed) public {
        address[4] memory actors = [borrower, lender, lender2, other];
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            usdg.approve(address(zap), type(uint256).max);
            usdg.approve(address(zvault), type(uint256).max);
            vm.stopPrank();
        }
        usdg.mint(address(zap), 123e6);
        nvda.mint(address(zap), 2 ether);
        vm.deal(address(zap), 1 ether);
        uint256[] memory ids = new uint256[](16);
        uint256 count;
        for (uint256 step; step < 64; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = step < 4 ? 0 : seed % 8;
            address actor = actors[(seed >> 8) % 4];
            if (action == 0 && count < ids.length) {
                (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
                vm.prank(actor);
                (ids[count++],,) = zap.zapAndList(z, swaps);
            } else if (count != 0) {
                uint256 id = ids[(seed >> 16) % count];
                Deal memory d = zvault.getDeal(id);
                if (action == 1 && d.state == DealState.LISTED) {
                    address funder = actor == d.borrower ? actors[((seed >> 8) + 1) % 4] : actor;
                    vm.prank(funder);
                    zvault.fund(id, funder);
                } else if (action == 2 && d.state == DealState.LISTED) {
                    vm.prank(d.borrower);
                    zvault.cancel(id);
                } else if (action == 3 && d.state == DealState.FUNDED) {
                    vm.prank(d.borrower);
                    zvault.reclaim(id);
                } else if (action == 4 && d.state == DealState.FUNDED && block.timestamp >= zvault.claimableAt(id)) {
                    vm.prank(d.lender);
                    zvault.claim(id);
                } else if (action == 5) {
                    vm.warp(block.timestamp + 1 days + (seed >> 32) % (10 days));
                } else if (action == 6 && zvault.balanceUSDG(actor) != 0) {
                    uint256 owed = zvault.balanceUSDG(actor);
                    uint256 before = usdg.balanceOf(actor);
                    vm.prank(actor);
                    zvault.withdrawUSDG();
                    assertEq(usdg.balanceOf(actor) - before, owed);
                } else if (action == 7 && zvault.owedNFT(actor, d.amountOrTokenId)) {
                    vm.prank(actor);
                    zvault.withdrawCollateral(id);
                }
            }
            _assertCustodyAndSolvency(actors, ids, count);
        }
    }

    function _assertCustodyAndSolvency(address[4] memory actors, uint256[] memory ids, uint256 count) private view {
        uint256 liabilities = zvault.balanceUSDG(address(feeSink));
        for (uint256 i; i < actors.length; ++i) {
            liabilities += zvault.balanceUSDG(actors[i]);
        }
        assertEq(usdg.balanceOf(address(zvault)), liabilities, "new vault USDG liabilities are fully backed");
        assertEq(zvault.dealCount(), count);
        for (uint256 i; i < count; ++i) {
            Deal memory d = zvault.getDeal(ids[i]);
            bool escrowed = d.state == DealState.LISTED || d.state == DealState.FUNDED;
            address recipient = d.state == DealState.CLAIMED ? d.lender : d.borrower;
            uint256 credits;
            for (uint256 j; j < actors.length; ++j) {
                if (zvault.owedNFT(actors[j], d.amountOrTokenId)) {
                    ++credits;
                    assertFalse(escrowed);
                    assertEq(actors[j], recipient);
                }
            }
            assertLe(credits, 1, "one withdrawal entitlement per NFT");
            address owner = IERC721(address(posm)).ownerOf(d.amountOrTokenId);
            assertEq(owner, escrowed || credits == 1 ? address(zvault) : recipient);
            assertGt(posm.getPositionLiquidity(d.amountOrTokenId), 0);
        }
        assertEq(usdg.balanceOf(address(zap)), 123e6, "USDG donations cannot fund another user");
        assertEq(nvda.balanceOf(address(zap)), 2 ether, "LP token donations remain isolated");
        assertEq(address(zap).balance, 1 ether, "native donations remain isolated");
        (uint160 allowance0,,) = permit2.allowance(address(zap), address(usdg), address(posm));
        (uint160 allowance1,,) = permit2.allowance(address(zap), address(nvda), address(posm));
        assertEq(allowance0, 0);
        assertEq(allowance1, 0);
    }

    function test_sharedRegistryDoesNotExposeExistingVaultAssets() public {
        (uint256 original,) = _fundDeal();
        bytes32 beforeDeal = keccak256(abi.encode(vault.getDeal(original)));
        uint256 beforeUSDG = usdg.balanceOf(address(vault));
        uint256 beforeNVDA = nvda.balanceOf(address(vault));
        (uint256 id,) = _zap();
        vm.prank(lender);
        zvault.fund(id, lender);
        vm.prank(borrower);
        zvault.reclaim(id);
        vm.prank(borrower);
        zvault.withdrawCollateral(id);
        assertEq(keccak256(abi.encode(vault.getDeal(original))), beforeDeal);
        assertEq(usdg.balanceOf(address(vault)), beforeUSDG);
        assertEq(nvda.balanceOf(address(vault)), beforeNVDA);
    }

    function test_unrelatedAccountCannotTakeEscrowOrWithdrawalCredit() public {
        (uint256 id, uint256 nft) = _zap();
        vm.prank(other);
        vm.expectRevert();
        zvault.withdrawCollateral(id);
        vm.prank(borrower);
        zvault.cancel(id);
        vm.prank(other);
        vm.expectRevert();
        zvault.withdrawPosition(nft);
        assertTrue(zvault.owedNFT(borrower, nft));
        assertEq(IERC721(address(posm)).ownerOf(nft), address(zvault));
        vm.prank(borrower);
        zvault.withdrawPosition(nft);
        vm.prank(borrower);
        vm.expectRevert();
        zvault.withdrawPosition(nft);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function test_callbacksRequireTheirConfiguredCaller() public {
        vm.expectRevert();
        zap.unlockCallback("");
        LPZapQuoter q = new LPZapQuoter(poolManager);
        vm.expectRevert(LPZapQuoter.NotPoolManager.selector);
        q.unlockCallback("");
        vm.expectRevert(LPZapQuoter.NotSelf.selector);
        q.sample(target, true, 1);
    }
}
