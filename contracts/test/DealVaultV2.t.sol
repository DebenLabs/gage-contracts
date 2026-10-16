// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockSubscriber} from "./mocks/MockSubscriber.sol";
import {MockRemovalObserver} from "./mocks/MockRemovalObserver.sol";
import {BaseTest} from "./Base.t.sol";
import {V4Fixture} from "./utils/V4Fixture.sol";
import {DealVault} from "../src/DealVault.sol";
import {DealVaultV2} from "../src/DealVaultV2.sol";
import {LPFeeForwarder} from "../src/LPFeeForwarder.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {UniV4MemeUSDGAdapter as Adapter} from "../src/libraries/UniV4MemeUSDGAdapter.sol";
import {UniV4PositionAdapter} from "../src/libraries/UniV4PositionAdapter.sol";
import {IDealVault, DealState} from "../src/interfaces/IDealVault.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";

contract DealVaultV2Test is BaseTest, V4Fixture {
    DealVaultV2 internal v2;
    CollateralRegistry internal r2;
    LPFeeForwarder internal forwarder;
    PoolKey internal pair;
    uint256 internal nft;
    uint128 constant LIQ = 1e15;
    uint128 constant CAP = 100e6;
    uint128 constant PRICE = 90e6;

    function setUp() public override {
        super.setUp();
        _deployV4();
        uint32[] memory terms = new uint32[](2);
        terms[0] = T7;
        terms[1] = T21;
        r2 = new CollateralRegistry(safe, terms, 100);
        forwarder = new LPFeeForwarder(usdg, address(feeSink));
        v2 = new DealVaultV2(usdg, r2, address(forwarder), address(posm), GRACE);
        forwarder.bind(v2);
        pair = _initPoolAtPrice(address(meme), 1e18, address(usdg), 1e6, address(0));
        vm.startPrank(safe);
        r2.setMemePairs(2);
        r2.setERC20Allowed(address(meme), true, Lane.MEME, 1, type(uint128).max, type(uint128).max);
        r2.setPoolAllowed(_poolId(pair), true, 1);
        r2.setInRangeRequired(true);
        vm.stopPrank();
        _approvePosm(borrower, address(meme));
        _approvePosm(borrower, address(usdg));
        nft = _mintFullRange(pair, LIQ, borrower, borrower);
        vm.startPrank(borrower);
        IERC721(address(posm)).setApprovalForAll(address(v2), true);
        usdg.approve(address(v2), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        usdg.approve(address(v2), type(uint256).max);
    }

    function collateral(uint256 id) internal view returns (Collateral memory) {
        return Collateral(Kind.UNIV4_POSITION, address(posm), id);
    }

    function listed() internal returns (uint256 id) {
        vm.prank(borrower);
        id = v2.list(collateral(nft), CAP, T7, _listingExpiry(), PRICE);
    }

    function funded() internal returns (uint256 id) {
        id = listed();
        vm.prank(lender);
        v2.fund(id, lender);
    }

    function test_reclaimAndUnwind_preservesFeesAndLiquidity() public {
        uint256 id = funded();
        _swap(pair, Currency.unwrap(pair.currency0) == address(meme), -1e18, other);
        assertEq(posm.getPositionLiquidity(nft), LIQ);
        vm.prank(borrower);
        v2.reclaim(id);
        vm.prank(borrower);
        v2.withdrawCollateral(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
        uint256 before = usdg.balanceOf(borrower);
        _decrease(pair, nft, LIQ, borrower, borrower);
        assertGt(usdg.balanceOf(borrower), before);
        assertEq(posm.getPositionLiquidity(nft), 0);
        assertEq(v2.balanceUSDG(lender), CAP);
    }

    function test_defaultAndUnwind_afterPauseAndDelist() public {
        uint256 id = funded();
        vm.startPrank(safe);
        r2.pauseNewDeals(true);
        r2.setPoolAllowed(_poolId(pair), false, 1);
        vm.stopPrank();
        vm.warp(v2.claimableAt(id));
        vm.prank(lender);
        v2.claim(id);
        vm.prank(lender);
        v2.withdrawCollateral(id);
        _decrease(pair, nft, LIQ, lender, lender);
        assertEq(posm.getPositionLiquidity(nft), 0);
    }

    function test_cancel_andBidRefund() public {
        uint256 id = listed();
        vm.prank(lender);
        uint256 bid = v2.bid(id, PRICE, uint40(block.timestamp + 1 days), lender);
        vm.prank(borrower);
        v2.cancel(id);
        vm.prank(lender);
        v2.withdrawBid(bid);
        assertEq(v2.balanceUSDG(lender), PRICE);
        vm.prank(borrower);
        v2.withdrawCollateral(id);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function test_feeForwarding_isPermissionlessAndExact() public {
        funded();
        uint256 before = usdg.balanceOf(address(feeSink));
        assertEq(forwarder.availableUSDG(), PRICE / 100);
        vm.prank(other);
        forwarder.forward();
        assertEq(usdg.balanceOf(address(feeSink)) - before, PRICE / 100);
        assertEq(v2.balanceUSDG(address(forwarder)), 0);
        assertEq(v2.balanceUSDG(borrower), PRICE - PRICE / 100);
        assertEq(forwarder.forward(), 0);
        vm.expectRevert(LPFeeForwarder.InvalidBinding.selector);
        forwarder.bind(v2);
    }

    function test_erc20CannotDuplicateV1Exposure() public {
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vm.prank(borrower);
        v2.list(Collateral(Kind.ERC20, address(meme), 1e18), CAP, T7, _listingExpiry(), PRICE);
    }

    function test_v1StillRejectsMemeUSDG_andOldDealStillSettles() public {
        vm.prank(borrower);
        uint256 old = vault.list(Collateral(Kind.ERC20, address(nvda), 1e18), CAP, T7, _listingExpiry(), PRICE);
        DealVault oldWithPositions = new DealVault(usdg, r2, address(feeSink), address(posm), GRACE);
        vm.expectPartialRevert(UniV4PositionAdapter.PairNotAllowed.selector);
        vm.prank(borrower);
        oldWithPositions.list(collateral(nft), CAP, T7, _listingExpiry(), PRICE);
        uint256 next = funded();
        assertEq(old, next, "IDs overlap across vaults");
        vm.prank(borrower);
        vault.cancel(old);
        vm.prank(borrower);
        vault.withdrawCollateral(old);
        assertEq(uint8(v2.getDeal(next).state), uint8(DealState.FUNDED));
    }

    function test_rejectUnlistedPoolOrTokenOrQuotePolicy() public {
        vm.prank(safe);
        r2.setPoolAllowed(_poolId(pair), false, 1);
        vm.expectPartialRevert(Adapter.PoolNotAllowed.selector);
        listed();
        vm.startPrank(safe);
        r2.setPoolAllowed(_poolId(pair), true, 1);
        r2.setMemePairs(1);
        vm.stopPrank();
        vm.expectPartialRevert(Adapter.PairNotAllowed.selector);
        listed();
        vm.startPrank(safe);
        r2.setMemePairs(2);
        r2.setERC20Allowed(address(meme), false, Lane.MEME, 0, 0, 0);
        vm.stopPrank();
        vm.expectPartialRevert(Adapter.PairNotAllowed.selector);
        listed();
    }

    function test_rejectZeroLiquidity() public {
        _decrease(pair, nft, LIQ, borrower, borrower);
        vm.expectPartialRevert(Adapter.LiquidityBelowMinimum.selector);
        listed();
    }

    function test_rejectNotOwner() public {
        vm.expectPartialRevert(Adapter.NotPositionOwner.selector);
        vm.prank(other);
        v2.list(collateral(nft), CAP, T7, _listingExpiry(), PRICE);
    }

    function test_rejectSubscriberAndDirectTransfer() public {
        MockSubscriber sub = new MockSubscriber();
        vm.prank(borrower);
        posm.subscribe(nft, address(sub), "");
        vm.expectPartialRevert(Adapter.HasSubscriber.selector);
        listed();
        vm.expectPartialRevert(IDealVault.UnexpectedERC721.selector);
        vm.prank(borrower);
        IERC721(address(posm)).safeTransferFrom(borrower, address(v2), nft);
    }

    function test_rejectOutOfRange() public {
        stateView = address(deployCode(STATE_VIEW_ARTIFACT, abi.encode(address(poolManager))));
        int24 lower = (_currentTick(pair) / TICK_SPACING + 10) * TICK_SPACING;
        nft = _mint(pair, lower, lower + 600, LIQ, borrower, borrower);
        vm.expectPartialRevert(Adapter.OutOfRange.selector);
        listed();
    }

    function test_hookHashMustMatchExactPoolRuntime() public {
        address hook = address(0x100);
        vm.etch(hook, address(new MockRemovalObserver()).code);
        pair = _initPoolAtPrice(address(meme), 1e18, address(usdg), 1e6, hook);
        vm.prank(safe);
        r2.setPoolAllowed(_poolId(pair), true, 1);
        nft = _mintFullRange(pair, LIQ, borrower, borrower);
        vm.expectPartialRevert(Adapter.HookCanBlockRemoval.selector);
        listed();
        vm.prank(safe);
        r2.setPoolRemovalHook(_poolId(pair), hook, hook.codehash);
        uint256 id = listed();
        vm.prank(safe);
        r2.setPoolRemovalHook(_poolId(pair), hook, bytes32(0));
        vm.prank(borrower);
        v2.cancel(id);
        vm.prank(borrower);
        v2.withdrawCollateral(id);
        _decrease(pair, nft, LIQ, borrower, borrower);
        nft = _mintFullRange(pair, LIQ, borrower, borrower);
        vm.prank(safe);
        r2.setPoolRemovalHook(_poolId(pair), hook, hook.codehash);
        vm.etch(hook, hex"00");
        vm.expectPartialRevert(Adapter.HookCanBlockRemoval.selector);
        listed();
    }
}
