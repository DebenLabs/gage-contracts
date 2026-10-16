// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./Base.t.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {ICollateralRegistry, PairAsset, Lane} from "../src/interfaces/ICollateralRegistry.sol";

contract CollateralRegistryTest is BaseTest {
    function _terms(uint32 a, uint32 b) internal pure returns (uint32[] memory t) {
        t = new uint32[](2);
        t[0] = a;
        t[1] = b;
    }

    // ================================================================= constructor

    function test_constructor_setsTermsFeeOwner() public view {
        uint32[] memory t = registry.allowedTerms();
        assertEq(t.length, 2);
        assertEq(t[0], T7);
        assertEq(t[1], T21);
        assertTrue(registry.isTermAllowed(T7));
        assertTrue(registry.isTermAllowed(T21));
        assertFalse(registry.isTermAllowed(14 days));
        assertEq(registry.feeBps(), FEE_BPS);
        assertEq(registry.owner(), safe);
        assertFalse(registry.newDealsPaused());
        assertFalse(registry.inRangeRequired());
    }

    function test_constructor_revertsFeeAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.FeeAboveMax.selector, uint16(201), uint16(200)));
        new CollateralRegistry(safe, _terms(T7, T21), 201);
    }

    function test_constructor_revertsNoTerms() public {
        vm.expectRevert(CollateralRegistry.NoTerms.selector);
        new CollateralRegistry(safe, new uint32[](0), FEE_BPS);
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CollateralRegistry(address(0), _terms(T7, T21), FEE_BPS);
    }

    // ================================================================= fee

    function test_setFee_boundsAndEmits() public {
        vm.startPrank(safe);
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.FeeSet(200);
        registry.setFee(200);
        assertEq(registry.feeBps(), 200);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.FeeAboveMax.selector, uint16(201), uint16(200)));
        registry.setFee(201);
        registry.setFee(0);
        assertEq(registry.feeBps(), 0);
        vm.stopPrank();
    }

    // ================================================================= terms

    function test_setTerms_replacesSet() public {
        vm.prank(safe);
        registry.setTerms(_terms(14 days, 30 days));
        assertFalse(registry.isTermAllowed(T7));
        assertFalse(registry.isTermAllowed(T21));
        assertTrue(registry.isTermAllowed(14 days));
        assertTrue(registry.isTermAllowed(30 days));
        uint32[] memory t = registry.allowedTerms();
        assertEq(t.length, 2);
        assertEq(t[0], 14 days);
        assertEq(t[1], 30 days);
    }

    function test_setTerms_revertsOutOfBounds() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.TermOutOfBounds.selector, uint32(1 days - 1)));
        registry.setTerms(_terms(1 days - 1, T7));
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.TermOutOfBounds.selector, uint32(30 days + 1)));
        registry.setTerms(_terms(T7, 30 days + 1));
        vm.stopPrank();
    }

    function test_setTerms_acceptsBounds() public {
        vm.prank(safe);
        registry.setTerms(_terms(1 days, 30 days));
        assertTrue(registry.isTermAllowed(1 days));
        assertTrue(registry.isTermAllowed(30 days));
    }

    function test_setTerms_revertsDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.DuplicateTerm.selector, T7));
        vm.prank(safe);
        registry.setTerms(_terms(T7, T7));
    }

    function test_setTerms_revertsTooManyAndEmpty() public {
        uint32[] memory nine = new uint32[](9);
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = uint32((i + 1) * 1 days);
        }
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.TooManyTerms.selector, 9, 8));
        registry.setTerms(nine);
        vm.expectRevert(CollateralRegistry.NoTerms.selector);
        registry.setTerms(new uint32[](0));
        vm.stopPrank();
    }

    // ================================================================= ERC-20 config

    function test_setERC20Allowed_storesConfigAndEmits() public {
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.ERC20Set(address(nvda), true, Lane.STOCK, 2e18, 500e18, 4000e18);
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 2e18, 500e18, 4000e18);
        ICollateralRegistry.ERC20Config memory c = registry.getERC20Config(address(nvda));
        assertTrue(c.allowed);
        assertEq(c.minAmount, 2e18);
        assertEq(c.maxDealRaw, 500e18);
        assertEq(c.maxOpenRaw, 4000e18);
    }

    function test_setERC20Allowed_revertsZeroToken() public {
        vm.expectRevert(CollateralRegistry.ZeroAddress.selector);
        vm.prank(safe);
        registry.setERC20Allowed(address(0), true, Lane.STOCK, 1, 1, 1);
    }

    function test_setERC20Allowed_revertsInconsistentCaps() public {
        vm.startPrank(safe);
        vm.expectRevert(CollateralRegistry.CapsInconsistent.selector);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 0, 1e18, 1e18);
        vm.expectRevert(CollateralRegistry.CapsInconsistent.selector);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 2e18, 1e18, 10e18);
        vm.expectRevert(CollateralRegistry.CapsInconsistent.selector);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 10e18, 9e18);
        vm.stopPrank();
    }

    function test_setERC20Allowed_disallowSkipsCapChecks() public {
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), false, Lane.STOCK, 0, 0, 0);
        assertFalse(registry.getERC20Config(address(nvda)).allowed);
    }

    // ================================================================= pools, flags, routers

    function test_setPoolAllowed() public {
        bytes32 poolId = keccak256("NVDA/USDG");
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.PoolSet(poolId, true, 1e12);
        vm.prank(safe);
        registry.setPoolAllowed(poolId, true, 1e12);
        ICollateralRegistry.PoolConfig memory p = registry.getPoolConfig(poolId);
        assertTrue(p.allowed);
        assertEq(p.minLiquidity, 1e12);
    }

    function test_setInRangeRequired() public {
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.InRangeRequiredSet(true);
        vm.prank(safe);
        registry.setInRangeRequired(true);
        assertTrue(registry.inRangeRequired());
    }

    function test_pauseNewDeals_emits() public {
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.NewDealsPausedSet(true);
        vm.prank(safe);
        registry.pauseNewDeals(true);
        assertTrue(registry.newDealsPaused());
    }

    function test_setRouter() public {
        vm.startPrank(safe);
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.RouterSet(other, true);
        registry.setRouter(other, true);
        assertTrue(registry.isRouter(other));
        registry.setRouter(other, false);
        assertFalse(registry.isRouter(other));
        vm.expectRevert(CollateralRegistry.ZeroAddress.selector);
        registry.setRouter(address(0), true);
        vm.stopPrank();
    }

    // ================================================================= ownership

    function test_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other);
        vm.startPrank(other);
        vm.expectRevert(err);
        registry.setERC20Allowed(address(nvda), true, Lane.STOCK, 1e18, 1e18, 1e18);
        vm.expectRevert(err);
        registry.setPoolAllowed(bytes32(0), true, 0);
        vm.expectRevert(err);
        registry.setTerms(_terms(T7, T21));
        vm.expectRevert(err);
        registry.setFee(1);
        vm.expectRevert(err);
        registry.setInRangeRequired(true);
        vm.expectRevert(err);
        registry.pauseNewDeals(true);
        vm.expectRevert(err);
        registry.setRouter(other, true);
        vm.stopPrank();
    }

    function test_ownershipTransferIsTwoStep() public {
        vm.prank(safe);
        registry.transferOwnership(other);
        assertEq(registry.owner(), safe);
        assertEq(registry.pendingOwner(), other);
        vm.prank(other);
        registry.acceptOwnership();
        assertEq(registry.owner(), other);
    }

    // ================================================================= lanes and meme pairs

    function test_setERC20Allowed_storesLane() public {
        vm.prank(safe);
        registry.setERC20Allowed(address(meme), true, Lane.MEME, 1000e18, 10_000e18, 50_000e18);
        assertEq(uint8(registry.getERC20Config(address(meme)).lane), uint8(Lane.MEME));
        assertEq(uint8(registry.getERC20Config(address(nvda)).lane), uint8(Lane.STOCK));
        vm.prank(safe);
        registry.setERC20Allowed(address(nvda), true, Lane.ETH, 1e18, 1e18, 1e18);
        assertEq(uint8(registry.getERC20Config(address(nvda)).lane), uint8(Lane.ETH));
    }

    function test_memePairs_defaultStockOnly() public view {
        assertEq(registry.memePairMask(), registry.MEME_PAIR_STOCK());
        assertTrue(registry.isMemePairAllowed(PairAsset.STOCK));
        assertFalse(registry.isMemePairAllowed(PairAsset.USDG));
        assertFalse(registry.isMemePairAllowed(PairAsset.ETH));
    }

    function test_setMemePairs_boundsAndEmits() public {
        vm.startPrank(safe);
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.MemePairsSet(registry.MEME_PAIR_ALL());
        registry.setMemePairs(registry.MEME_PAIR_ALL());
        assertTrue(registry.isMemePairAllowed(PairAsset.STOCK));
        assertTrue(registry.isMemePairAllowed(PairAsset.USDG));
        assertTrue(registry.isMemePairAllowed(PairAsset.ETH));

        registry.setMemePairs(registry.MEME_PAIR_STOCK() | registry.MEME_PAIR_ETH());
        assertTrue(registry.isMemePairAllowed(PairAsset.STOCK));
        assertFalse(registry.isMemePairAllowed(PairAsset.USDG));
        assertTrue(registry.isMemePairAllowed(PairAsset.ETH));

        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.MemePairMaskInvalid.selector, uint8(0)));
        registry.setMemePairs(0);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.MemePairMaskInvalid.selector, uint8(8)));
        registry.setMemePairs(8);
        vm.stopPrank();
    }

    function test_setMemePairs_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        registry.setMemePairs(1);
    }
}
