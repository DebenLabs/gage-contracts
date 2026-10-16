// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GageV2TokenRegistry} from "../../src/v2/GageV2TokenRegistry.sol";
import {GageV2Registry} from "../../src/v2/GageV2Registry.sol";
import {ICollateralRegistry, Lane} from "../../src/interfaces/ICollateralRegistry.sol";

/// @notice The standalone token registry of the release (REG-01): its bounds, events and owner rules, and a
/// differential run against `GageV2Registry` over every setting and view the two share.
contract GageV2TokenRegistryTest is Test {
    uint32 internal constant T7 = 7 days;
    uint32 internal constant T21 = 21 days;

    GageV2TokenRegistry internal registry;
    address internal admin = makeAddr("admin");
    address internal other = makeAddr("other");
    address internal token = makeAddr("token");

    function setUp() public {
        registry = new GageV2TokenRegistry(admin, _terms(T7, T21), address(this));
    }

    function _terms(uint32 a, uint32 b) internal pure returns (uint32[] memory t) {
        t = new uint32[](2);
        t[0] = a;
        t[1] = b;
    }

    // ================================================================= constructor

    function test_constructor_setsTermsFeesOwnerAndFactory() public view {
        uint32[] memory t = registry.allowedTerms();
        assertEq(t.length, 2);
        assertEq(t[0], T7);
        assertEq(t[1], T21);
        assertTrue(registry.isTermAllowed(T7));
        assertTrue(registry.isTermAllowed(T21));
        assertFalse(registry.isTermAllowed(14 days));
        assertEq(registry.feeBps(), 100);
        assertEq(registry.tradeFeeBps(), 100);
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), address(0));
        assertEq(registry.V3_FACTORY(), address(this));
        assertFalse(registry.newDealsPaused());
        assertEq(registry.MAX_FEE_BPS(), 200);
        assertEq(registry.MIN_TERM(), 1 days);
        assertEq(registry.MAX_TERM(), 30 days);
        assertEq(registry.MAX_TERMS(), 8);
        assertEq(registry.MAX_TRADE_FEE_BPS(), 200);
        assertEq(registry.MAX_REWARD_RATE(), 1e30);
        assertEq(registry.MAX_REWARD_PER_LOAN(), 5_000_000_000e18);
        assertEq(registry.REWARD_VALUE_CAP_BPS(), 8000);
    }

    function test_constructor_emitsOwnerTermsAndFee() public {
        vm.recordLogs();
        GageV2TokenRegistry r = new GageV2TokenRegistry(admin, _terms(T7, T21), address(this));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], Ownable.OwnershipTransferred.selector);
        assertEq(logs[1].topics[0], ICollateralRegistry.TermsSet.selector);
        assertEq(abi.encode(abi.decode(logs[1].data, (uint32[]))), abi.encode(_terms(T7, T21)));
        assertEq(logs[2].topics[0], ICollateralRegistry.FeeSet.selector);
        assertEq(abi.decode(logs[2].data, (uint16)), 100);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(r));
        }
    }

    function test_constructor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new GageV2TokenRegistry(address(0), _terms(T7, T21), address(this));
        vm.expectRevert(GageV2TokenRegistry.NoTerms.selector);
        new GageV2TokenRegistry(admin, new uint32[](0), address(this));
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.TermOutOfBounds.selector, uint32(1 days - 1)));
        new GageV2TokenRegistry(admin, _terms(T7, 1 days - 1), address(this));
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.DuplicateTerm.selector, T7));
        new GageV2TokenRegistry(admin, _terms(T7, T7), address(this));
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.TooManyTerms.selector, 9, 8));
        new GageV2TokenRegistry(admin, new uint32[](9), address(this));
        vm.expectRevert(GageV2TokenRegistry.InvalidV3Pool.selector);
        new GageV2TokenRegistry(admin, _terms(T7, T21), makeAddr("no code"));
        // As in GageV2Registry, the terms are checked before the factory.
        vm.expectRevert(GageV2TokenRegistry.NoTerms.selector);
        new GageV2TokenRegistry(admin, new uint32[](0), makeAddr("no code"));
    }

    // ================================================================= fees

    function test_setFee_boundsAndEmits() public {
        vm.startPrank(admin);
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.FeeSet(200);
        registry.setFee(200);
        assertEq(registry.feeBps(), 200);
        registry.setFee(0);
        assertEq(registry.feeBps(), 0);
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.FeeAboveMax.selector, uint16(201), uint16(200)));
        registry.setFee(201);
        vm.stopPrank();
    }

    function test_setTradeFee_boundsAndEmits() public {
        vm.startPrank(admin);
        vm.expectEmit(address(registry));
        emit GageV2TokenRegistry.TradeFeeSet(200);
        registry.setTradeFee(200);
        assertEq(registry.tradeFeeBps(), 200);
        registry.setTradeFee(0);
        assertEq(registry.tradeFeeBps(), 0);
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.FeeAboveMax.selector, uint16(201), uint16(200)));
        registry.setTradeFee(201);
        vm.stopPrank();
    }

    // ================================================================= terms

    function test_setTerms_replacesSetAndEmits() public {
        uint32[] memory t = new uint32[](3);
        t[0] = 1 days;
        t[1] = 14 days;
        t[2] = 30 days;
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.TermsSet(t);
        vm.prank(admin);
        registry.setTerms(t);
        assertEq(abi.encode(registry.allowedTerms()), abi.encode(t));
        assertFalse(registry.isTermAllowed(T7));
        assertFalse(registry.isTermAllowed(T21));
        assertTrue(registry.isTermAllowed(1 days));
        assertTrue(registry.isTermAllowed(14 days));
        assertTrue(registry.isTermAllowed(30 days));
    }

    function test_setTerms_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.TermOutOfBounds.selector, uint32(1 days - 1)));
        registry.setTerms(_terms(T7, 1 days - 1));
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.TermOutOfBounds.selector, uint32(30 days + 1)));
        registry.setTerms(_terms(30 days + 1, T7));
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.DuplicateTerm.selector, T21));
        registry.setTerms(_terms(T21, T21));
        uint32[] memory nine = new uint32[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = uint32(1 days + i);
        }
        vm.expectRevert(abi.encodeWithSelector(GageV2TokenRegistry.TooManyTerms.selector, 9, 8));
        registry.setTerms(nine);
        vm.expectRevert(GageV2TokenRegistry.NoTerms.selector);
        registry.setTerms(new uint32[](0));
        vm.stopPrank();
        // A refused replacement leaves the set as it was.
        assertEq(abi.encode(registry.allowedTerms()), abi.encode(_terms(T7, T21)));
        assertTrue(registry.isTermAllowed(T7));
    }

    // ================================================================= tokens

    function test_setERC20Allowed_storesConfigAndEmits() public {
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.ERC20Set(token, true, Lane.MEME, 2e18, 500e18, 4000e18);
        vm.prank(admin);
        registry.setERC20Allowed(token, true, Lane.MEME, 2e18, 500e18, 4000e18);
        ICollateralRegistry.ERC20Config memory c = registry.getERC20Config(token);
        assertTrue(c.allowed);
        assertEq(uint8(c.lane), uint8(Lane.MEME));
        assertEq(c.minAmount, 2e18);
        assertEq(c.maxDealRaw, 500e18);
        assertEq(c.maxOpenRaw, 4000e18);
    }

    function test_setERC20Allowed_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(GageV2TokenRegistry.ZeroAddress.selector);
        registry.setERC20Allowed(address(0), true, Lane.STOCK, 1, 1, 1);
        vm.expectRevert(GageV2TokenRegistry.CapsInconsistent.selector);
        registry.setERC20Allowed(token, true, Lane.STOCK, 0, 1, 1);
        vm.expectRevert(GageV2TokenRegistry.CapsInconsistent.selector);
        registry.setERC20Allowed(token, true, Lane.STOCK, 2, 1, 1);
        vm.expectRevert(GageV2TokenRegistry.CapsInconsistent.selector);
        registry.setERC20Allowed(token, true, Lane.STOCK, 1, 2, 1);
        // Removing a token skips the cap checks.
        registry.setERC20Allowed(token, false, Lane.STOCK, 0, 0, 0);
        vm.stopPrank();
        assertFalse(registry.getERC20Config(token).allowed);
    }

    // ================================================================= pause and routers

    function test_pauseNewDeals_emits() public {
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.NewDealsPausedSet(true);
        vm.prank(admin);
        registry.pauseNewDeals(true);
        assertTrue(registry.newDealsPaused());
    }

    function test_setRouter() public {
        vm.startPrank(admin);
        vm.expectEmit(address(registry));
        emit ICollateralRegistry.RouterSet(other, true);
        registry.setRouter(other, true);
        assertTrue(registry.isRouter(other));
        registry.setRouter(other, false);
        assertFalse(registry.isRouter(other));
        vm.expectRevert(GageV2TokenRegistry.ZeroAddress.selector);
        registry.setRouter(address(0), true);
        vm.stopPrank();
    }

    // ================================================================= rewards

    function test_setRewardTerms_boundsAndEmits() public {
        vm.startPrank(admin);
        vm.expectEmit(address(registry));
        emit GageV2TokenRegistry.RewardTermsSet(T7, 1e30, 3, 10_000);
        registry.setRewardTerms(T7, 1e30, 3, 10_000);
        (uint128 rate, uint128 referencePrice, uint16 share) = registry.rewardTerms(T7);
        assertEq(rate, 1e30);
        assertEq(referencePrice, 3);
        assertEq(share, 10_000);
        vm.expectRevert(GageV2TokenRegistry.InvalidRewardTerms.selector);
        registry.setRewardTerms(14 days, 1, 1, 0);
        vm.expectRevert(GageV2TokenRegistry.InvalidRewardTerms.selector);
        registry.setRewardTerms(T7, 1e30 + 1, 1, 0);
        vm.expectRevert(GageV2TokenRegistry.InvalidRewardTerms.selector);
        registry.setRewardTerms(T7, 1, 0, 0);
        vm.expectRevert(GageV2TokenRegistry.InvalidRewardTerms.selector);
        registry.setRewardTerms(T7, 1, 1, 10_001);
        vm.stopPrank();
    }

    function test_quoteRewards() public {
        (uint128 borrower, uint128 lender) = registry.quoteRewards(T7, 1e6);
        assertEq(borrower, 0);
        assertEq(lender, 0);
        vm.prank(admin);
        registry.setRewardTerms(T7, 100e18, 1e6, 2500);
        // By rate: 10 USDG of fee earns 1,000 sGAGE; by value at 1 USDG per sGAGE: 10 · 0.8 = 8 sGAGE, the smaller.
        (borrower, lender) = registry.quoteRewards(T7, 10e6);
        assertEq(borrower + lender, 8e18);
        assertEq(lender, 2e18);
        // The per-loan cap binds on a large fee at a tiny reference price.
        vm.prank(admin);
        registry.setRewardTerms(T7, 1e30, 1, 0);
        (borrower, lender) = registry.quoteRewards(T7, type(uint128).max);
        assertEq(borrower, 5_000_000_000e18);
        assertEq(lender, 0);
    }

    // ================================================================= ownership

    function test_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other);
        vm.startPrank(other);
        vm.expectRevert(err);
        registry.setERC20Allowed(token, true, Lane.STOCK, 1, 1, 1);
        vm.expectRevert(err);
        registry.setTerms(_terms(T7, T21));
        vm.expectRevert(err);
        registry.setFee(1);
        vm.expectRevert(err);
        registry.setTradeFee(1);
        vm.expectRevert(err);
        registry.pauseNewDeals(true);
        vm.expectRevert(err);
        registry.setRouter(other, true);
        vm.expectRevert(err);
        registry.setRewardTerms(T7, 1, 1, 0);
        vm.expectRevert(err);
        registry.transferOwnership(other);
        vm.expectRevert(err);
        registry.renounceOwnership();
        vm.stopPrank();
    }

    function test_ownershipTransferIsTwoStep() public {
        vm.prank(admin);
        registry.transferOwnership(other);
        assertEq(registry.owner(), admin);
        assertEq(registry.pendingOwner(), other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.acceptOwnership();
        vm.prank(other);
        registry.acceptOwnership();
        assertEq(registry.owner(), other);
        assertEq(registry.pendingOwner(), address(0));
    }
}

/// @notice The token registry against `GageV2Registry`, which it replaces for the release: for random owner calls on
/// both, every shared setting succeeds or fails alike with the same return data, and every shared view reads the same.
/// The one intended difference (REG-04): the trade-fee bound reverts with `FeeAboveMax` instead of `InvalidTradeFee`.
contract GageV2TokenRegistryDifferentialTest is Test {
    GageV2Registry internal base;
    GageV2TokenRegistry internal slim;

    struct Call {
        uint8 op;
        address token;
        bool ok;
        uint8 lane;
        uint256 minAmount;
        uint256 maxDeal;
        uint256 maxOpen;
        uint16 bps;
        uint128 rate;
        uint128 referencePrice;
        uint16 share;
        uint32 term;
        uint128 fee;
        address router;
    }

    function setUp() public {
        uint32[] memory t = new uint32[](2);
        t[0] = 7 days;
        t[1] = 21 days;
        base = new GageV2Registry(address(this), t, address(this));
        slim = new GageV2TokenRegistry(address(this), t, address(this));
    }

    function _both(bytes memory data) internal {
        (bool okBase, bytes memory outBase) = address(base).call(data);
        (bool okSlim, bytes memory outSlim) = address(slim).call(data);
        assertEq(okSlim, okBase, "success");
        assertEq(outSlim, outBase, "return data");
    }

    function _views(address token, uint32 term, uint128 fee, address router) internal {
        _both(abi.encodeCall(GageV2TokenRegistry.getERC20Config, (token)));
        _both(abi.encodeWithSignature("isTermAllowed(uint32)", term));
        _both(abi.encodeCall(GageV2TokenRegistry.allowedTerms, ()));
        _both(abi.encodeCall(GageV2TokenRegistry.quoteRewards, (term, fee)));
        _both(abi.encodeWithSignature("rewardTerms(uint32)", term));
        _both(abi.encodeWithSignature("isRouter(address)", router));
        _both(abi.encodeWithSignature("feeBps()"));
        _both(abi.encodeWithSignature("tradeFeeBps()"));
        _both(abi.encodeWithSignature("newDealsPaused()"));
        _both(abi.encodeWithSignature("owner()"));
        _both(abi.encodeWithSignature("pendingOwner()"));
        _both(abi.encodeWithSignature("V3_FACTORY()"));
    }

    function _call(Call memory x, uint32[] memory terms) internal {
        uint8 op = x.op % 8;
        if (op == 0) {
            _both(
                abi.encodeCall(
                    GageV2TokenRegistry.setERC20Allowed,
                    (x.token, x.ok, Lane(x.lane % 3), x.minAmount, x.maxDeal, x.maxOpen)
                )
            );
        } else if (op == 1) {
            _both(abi.encodeCall(GageV2TokenRegistry.setTerms, (terms)));
        } else if (op == 2) {
            _both(abi.encodeCall(GageV2TokenRegistry.setFee, (uint16(bound(x.bps, 0, 400)))));
        } else if (op == 3) {
            uint16 bps = uint16(bound(x.bps, 0, 400));
            bytes memory data = abi.encodeCall(GageV2TokenRegistry.setTradeFee, (bps));
            (bool okBase, bytes memory outBase) = address(base).call(data);
            (bool okSlim, bytes memory outSlim) = address(slim).call(data);
            assertEq(okSlim, okBase, "success");
            if (okBase) {
                assertEq(outSlim, outBase, "return data");
            } else {
                assertEq(outBase, abi.encodeWithSelector(GageV2Registry.InvalidTradeFee.selector));
                assertEq(outSlim, abi.encodeWithSelector(GageV2TokenRegistry.FeeAboveMax.selector, bps, uint16(200)));
            }
        } else if (op == 4) {
            _both(abi.encodeCall(GageV2TokenRegistry.pauseNewDeals, (x.ok)));
        } else if (op == 5) {
            _both(abi.encodeCall(GageV2TokenRegistry.setRouter, (x.router, x.ok)));
        } else if (op == 6) {
            _both(abi.encodeCall(GageV2TokenRegistry.setRewardTerms, (x.term, x.rate, x.referencePrice, x.share)));
        } else {
            uint128 rate = uint128(bound(x.rate, 0, 2e30));
            _both(
                abi.encodeCall(
                    GageV2TokenRegistry.setRewardTerms,
                    (7 days, rate, x.referencePrice, uint16(bound(x.share, 0, 12_000)))
                )
            );
        }
    }

    function testFuzz_sharedSurfaceMatches(Call[4] memory calls, uint32[] memory terms) public {
        if (terms.length > 9) {
            assembly {
                mstore(terms, 9)
            }
        }
        for (uint256 i; i < terms.length; ++i) {
            if (i % 2 == 0) terms[i] = uint32(bound(terms[i], 0, 40 days));
        }
        for (uint256 k; k < calls.length; ++k) {
            Call memory x = calls[k];
            if (x.term % 3 == 0 && terms.length > 0) x.term = terms[0];
            _call(x, terms);
            _views(x.token, x.term, x.fee, x.router);
            _views(x.token, 7 days, x.fee, x.router);
        }
    }

    function test_constantsMatch() public view {
        assertEq(slim.MAX_FEE_BPS(), base.MAX_FEE_BPS());
        assertEq(slim.MIN_TERM(), base.MIN_TERM());
        assertEq(slim.MAX_TERM(), base.MAX_TERM());
        assertEq(slim.MAX_TERMS(), base.MAX_TERMS());
        assertEq(slim.MAX_TRADE_FEE_BPS(), base.MAX_TRADE_FEE_BPS());
        assertEq(slim.MAX_REWARD_RATE(), base.MAX_REWARD_RATE());
        assertEq(slim.MAX_REWARD_PER_LOAN(), base.MAX_REWARD_PER_LOAN());
        assertEq(slim.REWARD_VALUE_CAP_BPS(), base.REWARD_VALUE_CAP_BPS());
    }

    function test_ownershipMatches() public {
        address next = makeAddr("next");
        _both(abi.encodeWithSignature("transferOwnership(address)", next));
        _both(abi.encodeWithSignature("pendingOwner()"));
        vm.startPrank(next);
        _both(abi.encodeWithSignature("acceptOwnership()"));
        _both(abi.encodeWithSignature("owner()"));
        _both(abi.encodeWithSignature("renounceOwnership()"));
        vm.stopPrank();
        _both(abi.encodeWithSignature("owner()"));
        _both(abi.encodeCall(GageV2TokenRegistry.setFee, (1)));
    }
}
