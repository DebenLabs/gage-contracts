// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BaseTest} from "./Base.t.sol";
import {V4Fixture} from "./utils/V4Fixture.sol";
import {DealVault} from "../src/DealVault.sol";
import {IDealVault, DealState, Deal} from "../src/interfaces/IDealVault.sol";
import {UniV4PositionAdapter} from "../src/libraries/UniV4PositionAdapter.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {MockSubscriber} from "./mocks/MockSubscriber.sol";
import {MockRemovalObserver} from "./mocks/MockRemovalObserver.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";

/// @notice Spec 7.2 and I9: the position adapter against a real Uniswap v4 deployment.
contract UniV4PositionAdapterTest is BaseTest, V4Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DealVault internal pvault;
    PoolKey internal stockPool;
    PoolKey internal memePool;
    uint256 internal tokenId;

    uint128 internal constant LIQ = 1e15; // full range: about 100 NVDAx and 10,000 USDG at 100 USDG per NVDAx
    uint128 internal constant CAP = 8000e6;
    uint128 internal constant PRICE = 7960e6;

    function setUp() public override {
        super.setUp();
        _deployV4();
        pvault = new DealVault(usdg, registry, address(feeSink), address(posm), GRACE);
        vm.label(address(pvault), "DealVault(positions)");

        stockPool = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        memePool = _initPoolAtPrice(address(meme), 1000e18, address(nvda), 1e18, address(0));
        vm.startPrank(safe);
        registry.setPoolAllowed(_poolId(stockPool), true, 1e12);
        registry.setPoolAllowed(_poolId(memePool), true, 1e12);
        vm.stopPrank();

        _approvePosm(borrower, address(nvda));
        _approvePosm(borrower, address(usdg));
        _approvePosm(borrower, address(meme));
        tokenId = _mintFullRange(stockPool, LIQ, borrower, borrower);

        vm.prank(borrower);
        IERC721(address(posm)).setApprovalForAll(address(pvault), true);
        vm.prank(borrower);
        usdg.approve(address(pvault), type(uint256).max);
        vm.prank(lender);
        usdg.approve(address(pvault), type(uint256).max);
        vm.prank(other);
        usdg.approve(address(pvault), type(uint256).max);
    }

    // ----------------------------------------------------------------- helpers

    function _position(uint256 id) internal view returns (Collateral memory) {
        return Collateral({kind: Kind.UNIV4_POSITION, token: address(posm), amountOrTokenId: id});
    }

    function _listPosition(address who, uint256 id) internal returns (uint256 dealId) {
        vm.prank(who);
        dealId = pvault.list(_position(id), CAP, T7, _listingExpiry(), 0);
    }

    function _fundPosition() internal returns (uint256 dealId, uint256 bidId) {
        dealId = _listPosition(borrower, tokenId);
        vm.prank(lender);
        bidId = pvault.bid(dealId, PRICE, uint40(block.timestamp + 1 days), lender);
        vm.prank(borrower);
        pvault.accept(dealId, bidId);
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    // ================================================================= happy paths

    function test_fixture_poolPriceIsAsConfigured() public view {
        // 1 NVDAx = 100 USDG: the tick is where sqrt(price) puts it, and the position holds both sides.
        assertEq(posm.getPositionLiquidity(tokenId), LIQ);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), borrower);
        assertLt(nvda.balanceOf(borrower), 10_000e18, "NVDAx went into the position");
        assertLt(usdg.balanceOf(borrower), 10_000_000e6, "USDG went into the position");
    }

    function test_list_positionEscrowedAndEmits() public {
        uint40 le = _listingExpiry();
        vm.expectEmit(address(pvault));
        emit IDealVault.Listed(1, borrower, Kind.UNIV4_POSITION, address(posm), tokenId, CAP, T7, le, 0);
        vm.prank(borrower);
        uint256 dealId = pvault.list(_position(tokenId), CAP, T7, le, 0);

        Deal memory d = pvault.getDeal(dealId);
        assertEq(uint8(d.kind), uint8(Kind.UNIV4_POSITION));
        assertEq(d.token, address(posm));
        assertEq(d.amountOrTokenId, tokenId);
        assertEq(uint8(d.state), uint8(DealState.LISTED));
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(pvault), "vault holds the NFT");
        assertEq(pvault.openRaw(address(posm)), 0, "positions do not count toward ERC-20 open caps");
    }

    function test_lifecycle_reclaimReturnsPosition() public {
        (uint256 dealId,) = _fundPosition();
        vm.prank(borrower);
        pvault.reclaim(dealId);
        assertTrue(pvault.owedNFT(borrower, tokenId));
        assertEq(pvault.balanceUSDG(lender), CAP);

        vm.expectEmit(address(pvault));
        emit IDealVault.Withdrawn(borrower, address(posm), tokenId);
        vm.prank(borrower);
        pvault.withdrawPosition(tokenId);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), borrower);
        assertFalse(pvault.owedNFT(borrower, tokenId));
    }

    function test_lifecycle_walkAwayGivesLenderThePosition() public {
        (uint256 dealId,) = _fundPosition();
        vm.warp(pvault.claimableAt(dealId));
        vm.prank(lender);
        pvault.claim(dealId);
        assertTrue(pvault.owedNFT(lender, tokenId));
        vm.prank(lender);
        pvault.withdrawCollateral(dealId);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), lender);
    }

    function test_cancel_returnsPosition() public {
        uint256 dealId = _listPosition(borrower, tokenId);
        vm.prank(borrower);
        pvault.cancel(dealId);
        vm.prank(borrower);
        pvault.withdrawCollateral(dealId);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), borrower);
    }

    function test_escrow_liquidityAndFeesStayWithThePosition() public {
        (uint256 dealId,) = _fundPosition();
        // Trading happens while the position is escrowed; nobody can touch its liquidity.
        _swap(stockPool, Currency.unwrap(stockPool.currency0) == address(nvda), -1e18, other);
        assertEq(posm.getPositionLiquidity(tokenId), LIQ, "liquidity untouched");
        vm.prank(borrower);
        pvault.reclaim(dealId);
        vm.prank(borrower);
        pvault.withdrawPosition(tokenId);
        assertEq(posm.getPositionLiquidity(tokenId), LIQ, "fees accrued to the position follow it back");
    }

    function test_withdrawPosition_revertsForSomeoneElse() public {
        (uint256 dealId,) = _fundPosition();
        vm.prank(borrower);
        pvault.reclaim(dealId);
        vm.expectRevert(IDealVault.NothingToWithdraw.selector);
        vm.prank(lender);
        pvault.withdrawPosition(tokenId);
    }

    // ================================================================= I9: rejections

    function test_reject_notOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(UniV4PositionAdapter.NotPositionOwner.selector, tokenId, borrower, other)
        );
        _listPosition(other, tokenId);
    }

    function test_reject_wrongNFTContract() public {
        Collateral memory c = Collateral({kind: Kind.UNIV4_POSITION, token: address(0xBEEF), amountOrTokenId: tokenId});
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vm.prank(borrower);
        pvault.list(c, CAP, T7, _listingExpiry(), 0);
    }

    function test_reject_poolNotAllowed() public {
        vm.prank(safe);
        registry.setPoolAllowed(_poolId(stockPool), false, 0);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.PoolNotAllowed.selector, _poolId(stockPool)));
        _listPosition(borrower, tokenId);
    }

    function test_memeStock_cancelReturnsUnwindablePosition() public {
        uint256 memeId = _mintFullRange(memePool, 1e15, borrower, borrower);
        uint256 id = _listPosition(borrower, memeId);
        vm.prank(borrower);
        pvault.cancel(id);
        vm.prank(borrower);
        pvault.withdrawPosition(memeId);
        uint256 beforeMeme = meme.balanceOf(borrower);
        uint256 beforeStock = nvda.balanceOf(borrower);
        _decrease(memePool, memeId, 1e15, borrower, borrower);
        assertGt(meme.balanceOf(borrower), beforeMeme);
        assertGt(nvda.balanceOf(borrower), beforeStock);
    }

    function test_memeStock_defaultTransfersUnwindablePositionToLender() public {
        tokenId = _mintFullRange(memePool, 1e15, borrower, borrower);
        (uint256 id,) = _fundPosition();
        vm.warp(pvault.claimableAt(id));
        vm.prank(lender);
        pvault.claim(id);
        vm.prank(lender);
        pvault.withdrawPosition(tokenId);
        uint256 beforeMeme = meme.balanceOf(lender);
        uint256 beforeStock = nvda.balanceOf(lender);
        _decrease(memePool, tokenId, 1e15, lender, lender);
        assertGt(meme.balanceOf(lender), beforeMeme);
        assertGt(nvda.balanceOf(lender), beforeStock);
    }

    function test_reject_memeStockWhenMemeDelisted() public {
        uint256 memeId = _mintFullRange(memePool, 1e15, borrower, borrower);
        vm.prank(safe);
        registry.setERC20Allowed(address(meme), false, Lane.MEME, 0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV4PositionAdapter.PairNotAllowed.selector,
                Currency.unwrap(memePool.currency0),
                Currency.unwrap(memePool.currency1)
            )
        );
        _listPosition(borrower, memeId);
    }

    function test_reject_pairStockDelisted() public {
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV4PositionAdapter.PairNotAllowed.selector,
                Currency.unwrap(stockPool.currency0),
                Currency.unwrap(stockPool.currency1)
            )
        );
        _listPosition(borrower, tokenId);
    }

    function test_reject_memeLaneTokenPairedWithUSDG() public {
        PoolKey memory memeUsdg = _initPoolAtPrice(address(meme), 1000e18, address(usdg), 1e6, address(0));
        vm.prank(safe);
        registry.setPoolAllowed(_poolId(memeUsdg), true, 1e12);
        uint256 id = _mintFullRange(memeUsdg, 1e15, borrower, borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV4PositionAdapter.PairNotAllowed.selector,
                Currency.unwrap(memeUsdg.currency0),
                Currency.unwrap(memeUsdg.currency1)
            )
        );
        _listPosition(borrower, id);
    }

    function test_reject_hookWithRemoveLiquidityBits() public {
        // Bits 9 (before remove), 8 (after remove) and 0 (after remove returns delta, which needs bit 8).
        address[3] memory hooks = [address(0x200), address(0x100), address(0x101)];
        for (uint256 i = 0; i < hooks.length; ++i) {
            // A different fee tier per pool so each key is distinct.
            PoolKey memory hooked =
                _initPool(address(nvda), address(usdg), uint24(500 + i), TICK_SPACING, hooks[i], _sqrtForStockPool());
            vm.prank(safe);
            registry.setPoolAllowed(_poolId(hooked), true, 1e12);
            uint256 id = _mintFullRange(hooked, 1e15, borrower, borrower);
            vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, hooks[i]));
            _listPosition(borrower, id);
        }
    }

    function test_reviewedRemovalHook_exactPoolRuntimeAndRevocation() public {
        address hook = address(0x100);
        vm.etch(hook, address(new MockRemovalObserver()).code);
        PoolKey memory key = _initPoolAtPrice(address(meme), 1000e18, address(nvda), 1e18, hook);
        vm.startPrank(safe);
        registry.setPoolAllowed(_poolId(key), true, 1);
        registry.setPoolRemovalHook(_poolId(key), hook, hook.codehash);
        vm.stopPrank();
        uint256 id = _mintFullRange(key, 1e15, borrower, borrower);
        uint256 listed = _listPosition(borrower, id);
        vm.prank(safe);
        registry.setPoolRemovalHook(_poolId(key), hook, bytes32(0));
        vm.prank(borrower);
        pvault.cancel(listed);
        vm.prank(borrower);
        pvault.withdrawPosition(id);
        _decrease(key, id, 1e15, borrower, borrower);
        uint256 second = _mintFullRange(key, 1e15, borrower, borrower);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, hook));
        _listPosition(borrower, second);
        vm.prank(safe);
        registry.setPoolRemovalHook(_poolId(key), hook, hook.codehash);
        vm.etch(hook, hex"00");
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HookCanBlockRemoval.selector, hook));
        _listPosition(borrower, second);
    }

    function test_reviewedRemovalHook_cannotExemptBeforeRemoveOrDeltaOrWrongHash() public {
        address[3] memory hooks = [address(0x200), address(0x101), address(0x100)];
        for (uint256 i; i < hooks.length; ++i) {
            vm.etch(hooks[i], address(new MockRemovalObserver()).code);
            vm.expectRevert(CollateralRegistry.InvalidRemovalHook.selector);
            vm.prank(safe);
            registry.setPoolRemovalHook(_poolId(stockPool), hooks[i], i == 2 ? bytes32(uint256(1)) : hooks[i].codehash);
        }
        vm.expectRevert();
        vm.prank(borrower);
        registry.setPoolRemovalHook(_poolId(stockPool), address(0x100), address(0x100).codehash);
    }

    function test_reject_liquidityAtOrBelowMinimum() public {
        vm.prank(safe);
        registry.setPoolAllowed(_poolId(stockPool), true, LIQ);
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.LiquidityBelowMinimum.selector, tokenId, LIQ, LIQ));
        _listPosition(borrower, tokenId);
    }

    function test_outOfRange_acceptedWithFlagOff_rejectedWithFlagOn() public {
        int24 tick = _tick(stockPool);
        int24 lower = ((tick / TICK_SPACING) + 10) * TICK_SPACING;
        int24 upper = lower + 10 * TICK_SPACING;
        uint256 above = _mint(stockPool, lower, upper, 1e15, borrower, borrower);

        uint256 dealId = _listPosition(borrower, above);
        assertEq(uint8(pvault.getDeal(dealId).state), uint8(DealState.LISTED), "flag off: accepted");

        uint256 above2 = _mint(stockPool, lower, upper, 1e15, borrower, borrower);
        vm.prank(safe);
        registry.setInRangeRequired(true);
        vm.expectRevert(
            abi.encodeWithSelector(UniV4PositionAdapter.OutOfRange.selector, above2, _tick(stockPool), lower, upper)
        );
        _listPosition(borrower, above2);
    }

    function test_inRange_acceptedWithFlagOn() public {
        vm.prank(safe);
        registry.setInRangeRequired(true);
        uint256 dealId = _listPosition(borrower, tokenId);
        assertEq(uint8(pvault.getDeal(dealId).state), uint8(DealState.LISTED));
    }

    function test_reject_subscribedPosition() public {
        MockSubscriber sub = new MockSubscriber();
        vm.prank(borrower);
        posm.subscribe(tokenId, address(sub), "");
        vm.expectRevert(abi.encodeWithSelector(UniV4PositionAdapter.HasSubscriber.selector, tokenId, address(sub)));
        _listPosition(borrower, tokenId);
    }

    function test_reject_directTransferOutsideList() public {
        vm.expectRevert(abi.encodeWithSelector(IDealVault.UnexpectedERC721.selector, borrower, borrower, tokenId));
        vm.prank(borrower);
        IERC721(address(posm)).safeTransferFrom(borrower, address(pvault), tokenId);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), borrower);
    }

    function test_reject_managerWithoutCode() public {
        DealVault v = new DealVault(usdg, registry, address(feeSink), address(0xBEEF), GRACE);
        Collateral memory c = Collateral({kind: Kind.UNIV4_POSITION, token: address(0xBEEF), amountOrTokenId: 1});
        vm.expectRevert();
        vm.prank(borrower);
        v.list(c, CAP, T7, _listingExpiry(), 0);
    }

    function _sqrtForStockPool() internal view returns (uint160) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(stockPool.toId());
        return sqrtPriceX96;
    }
}
