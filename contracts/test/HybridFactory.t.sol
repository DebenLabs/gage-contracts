// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EarnBaseTest} from "./EarnBase.t.sol";
import {HybridFactory} from "../src/HybridFactory.sol";
import {HybridVault, EarnLane} from "../src/HybridVault.sol";
import {HybridFees} from "../src/HybridFees.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The factory pins one strategy implementation, wires each fee companion once and keeps instances isolated.
contract HybridFactoryTest is EarnBaseTest {
    address internal founder = makeAddr("founder");
    address internal creator = makeAddr("creator");
    address internal curator2 = makeAddr("curator-2");
    HybridFactory internal factory;
    address internal router;

    function setUp() public override {
        super.setUp();
        // Any code-bearing address stands in for the deal fee router: protocol shares are plain USDG at that address.
        router = floor;
        factory = new HybridFactory(_params(router, 2500));
    }

    function _params(address feeRouter, uint16 bps) internal view returns (HybridFactory.Params memory) {
        return HybridFactory.Params({
            core: address(vault),
            reserve: address(reserve),
            feeRouter: feeRouter,
            protocolShareBps: bps,
            initialOwner: founder
        });
    }

    function _mandate(address who) internal view returns (HybridFactory.Mandate memory m) {
        m = HybridFactory.Mandate({
            curator: who,
            laneWeights: p.laneWeights,
            maxLoanTerm: p.maxLoanTerm,
            minReturnBps: p.minReturnBps,
            maxGageExposureBps: p.maxGageExposureBps,
            minDeposit: p.minDeposit,
            maxTotalDeposits: p.maxTotalDeposits
        });
    }

    function test_constructorBoundsInvalidConfiguration() public {
        HybridFactory.Params memory bad = _params(router, 2500);
        bad.core = makeAddr("no-code");
        vm.expectRevert(HybridFactory.InvalidConfiguration.selector);
        new HybridFactory(bad);
        bad = _params(router, 2500);
        bad.reserve = makeAddr("no-code");
        vm.expectRevert(HybridFactory.InvalidConfiguration.selector);
        new HybridFactory(bad);
        vm.expectRevert(HybridFactory.InvalidConfiguration.selector);
        new HybridFactory(_params(makeAddr("no-code"), 2500));
        vm.expectRevert(HybridFactory.InvalidConfiguration.selector);
        new HybridFactory(_params(router, 10_001));
        HybridFactory whole = new HybridFactory(_params(router, 10_000));
        assertEq(whole.PROTOCOL_SHARE_BPS(), 10_000);
    }

    function test_pinsCoreReserveAndExactStrategyCreationCode() public view {
        assertEq(factory.CORE(), address(vault));
        assertEq(factory.RESERVE(), address(reserve));
        assertEq(factory.PROTOCOL_SHARE_BPS(), 2500);
        assertEq(factory.VAULT_INIT_HASH(), keccak256(type(HybridVault).creationCode));
        assertEq(keccak256(factory.vaultCreationCode()), factory.VAULT_INIT_HASH());
        assertEq(factory.owner(), founder);
        assertEq(factory.feeRouter(), router);
        assertFalse(factory.publicCreation());
        assertEq(factory.count(), 0);
    }

    function test_ownerCreatesWiredVaultWithoutPayingAnything() public {
        uint256 routerBefore = usdg.balanceOf(router);
        uint256 founderBefore = usdg.balanceOf(founder);
        uint256 nonce = vm.getNonce(address(factory));
        address expectedVault = vm.computeCreateAddress(address(factory), nonce);
        address expectedFees = vm.computeCreateAddress(address(factory), nonce + 1);
        vm.expectEmit(true, true, true, true);
        emit HybridFactory.VaultCreated(expectedVault, expectedFees, curator, founder);
        vm.prank(founder);
        (address created, address companion) = factory.create(_mandate(curator));
        assertEq(created, expectedVault);
        assertEq(companion, expectedFees);
        HybridVault v = HybridVault(payable(created));
        assertEq(address(v.VAULT()), address(vault));
        assertEq(address(v.RESERVE()), address(reserve));
        assertEq(v.CURATOR(), curator);
        assertEq(v.GRACE(), GRACE);
        assertEq(v.fees(), companion);
        assertEq(v.feeBps(), 0);
        assertEq(v.laneWeightBps(EarnLane.STOCK), 10_000);
        assertEq(v.params().maxTotalDeposits, p.maxTotalDeposits);
        // Runtime bytes differ only by the immutables baked into each instance.
        assertEq(created.code.length, address(hybrid).code.length, "same implementation as the fixture strategy");
        assertEq(usdg.balanceOf(router), routerBefore, "creation is free");
        assertEq(usdg.balanceOf(founder), founderBefore);
        HybridFees f = HybridFees(companion);
        assertEq(address(f.STRATEGY()), created);
        assertEq(f.PROTOCOL_SHARE_BPS(), 2500);
        assertEq(f.PROTOCOL_RECIPIENT(), router);
        assertEq(f.CURATOR(), curator);
        assertEq(f.curatorRecipient(), curator);
        (address fees, address recordedCurator, address recordedCreator, uint64 createdAt) = factory.records(created);
        assertEq(fees, companion);
        assertEq(recordedCurator, curator);
        assertEq(recordedCreator, founder);
        assertEq(createdAt, uint64(block.timestamp));
        assertEq(factory.count(), 1);
        assertEq(factory.vaults(0), created);
        assertTrue(factory.isVault(created));
        assertFalse(factory.isVault(address(hybrid)));
        assertFalse(factory.isVault(companion));
        // The companion is wired, so the curator can turn the fee on at once.
        vm.prank(curator);
        v.setFee(1000);
        assertEq(v.feeBps(), 1000);
    }

    function test_creationIsClosedUntilTheSwitchOpensIt() public {
        vm.prank(creator);
        vm.expectRevert(HybridFactory.CreationClosed.selector);
        factory.create(_mandate(curator2));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.setPublicCreation(true);
        vm.expectEmit(false, false, false, true);
        emit HybridFactory.PublicCreationSet(true);
        vm.prank(founder);
        factory.setPublicCreation(true);
        assertTrue(factory.publicCreation());
        vm.prank(creator);
        (address created,) = factory.create(_mandate(curator2));
        assertEq(HybridVault(payable(created)).CURATOR(), curator2);
        (,, address recordedCreator,) = factory.records(created);
        assertEq(recordedCreator, creator);
        assertEq(usdg.balanceOf(router), 0);
        vm.prank(founder);
        factory.setPublicCreation(false);
        vm.prank(creator);
        vm.expectRevert(HybridFactory.CreationClosed.selector);
        factory.create(_mandate(curator2));
        assertEq(factory.count(), 1);
    }

    function test_feeRouterOnlyChangesLaterCompanionsAndMustHaveCode() public {
        vm.prank(founder);
        (address first,) = factory.create(_mandate(curator));
        address second_router = address(new MockERC20("Floor 2", "FLOOR2", 18));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        factory.setFeeRouter(second_router);
        vm.prank(founder);
        vm.expectRevert(HybridFactory.InvalidConfiguration.selector);
        factory.setFeeRouter(makeAddr("no-code"));
        vm.expectEmit(true, false, false, true);
        emit HybridFactory.FeeRouterSet(second_router);
        vm.prank(founder);
        factory.setFeeRouter(second_router);
        assertEq(factory.feeRouter(), second_router);
        vm.prank(founder);
        (address second,) = factory.create(_mandate(curator2));
        assertEq(HybridFees(HybridVault(payable(first)).fees()).PROTOCOL_RECIPIENT(), router);
        assertEq(HybridFees(HybridVault(payable(second)).fees()).PROTOCOL_RECIPIENT(), second_router);
        assertEq(HybridFees(HybridVault(payable(second)).fees()).PROTOCOL_SHARE_BPS(), 2500, "the share is immutable");
        assertEq(usdg.balanceOf(router), 0);
        assertEq(usdg.balanceOf(second_router), 0);
    }

    function test_rejectedMandateRevertsAfterNothingWasRecorded() public {
        uint256 nonce = vm.getNonce(address(factory));
        HybridFactory.Mandate memory m = _mandate(address(0));
        vm.prank(founder);
        vm.expectRevert(HybridFactory.VaultCreationFailed.selector);
        factory.create(m);
        m = _mandate(curator);
        m.maxTotalDeposits = m.minDeposit - 1;
        vm.prank(founder);
        vm.expectRevert(HybridFactory.VaultCreationFailed.selector);
        factory.create(m);
        m = _mandate(curator);
        m.minDeposit = 0;
        vm.prank(founder);
        vm.expectRevert(HybridFactory.VaultCreationFailed.selector);
        factory.create(m);
        m = _mandate(curator);
        m.laneWeights = [uint16(6000), 4000, 1];
        vm.prank(founder);
        vm.expectRevert(HybridFactory.VaultCreationFailed.selector);
        factory.create(m);
        m = _mandate(curator);
        m.maxLoanTerm = 90 days + 1;
        vm.prank(founder);
        vm.expectRevert(HybridFactory.VaultCreationFailed.selector);
        factory.create(m);
        assertEq(factory.count(), 0);
        assertEq(vm.getNonce(address(factory)), nonce, "no partial deployment survives a rejected mandate");
    }

    function test_instancesAreIsolatedFromEachOtherAndTheFixtureStrategy() public {
        vm.startPrank(founder);
        (address a, address aFees) = factory.create(_mandate(curator));
        (address b, address bFees) = factory.create(_mandate(curator2));
        vm.stopPrank();
        assertTrue(a != b && a != address(hybrid) && aFees != bFees);
        vm.prank(curator2);
        vm.expectRevert(HybridVault.NotCurator.selector);
        HybridVault(payable(a)).setPaused(true);
        vm.prank(curator);
        vm.expectRevert(HybridVault.NotCurator.selector);
        HybridVault(payable(b)).setPaused(true);
        vm.prank(curator);
        HybridVault(payable(a)).setTokenCeiling(address(nvda), 1000e6);
        assertEq(HybridVault(payable(b)).tokenCeiling(address(nvda)), 0);
        vm.startPrank(lender);
        usdg.approve(a, type(uint256).max);
        HybridVault(payable(a)).deposit(500e6, 0);
        vm.stopPrank();
        assertEq(HybridVault(payable(a)).cash(), 500e6);
        assertEq(HybridVault(payable(a)).balanceOf(lender), 500e18);
        assertEq(HybridVault(payable(b)).cash(), 0);
        assertEq(HybridVault(payable(b)).balanceOf(lender), 0);
        assertEq(hybrid.cash(), 0);
        assertEq(usdg.balanceOf(a), 500e6);
        assertEq(usdg.balanceOf(b), 0);
        // A companion answers only to its own strategy.
        vm.prank(a);
        vm.expectRevert(HybridFees.NotStrategy.selector);
        HybridFees(bFees).distribute(0);
        vm.prank(b);
        HybridFees(bFees).distribute(0);
    }

    function test_theFactoryWiresTheCompanionOnceAndNobodyCanRewire() public {
        vm.prank(founder);
        (address created, address companion) = factory.create(_mandate(curator));
        HybridFees another = new HybridFees(created, 0, address(0), curator);
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        HybridVault(payable(created)).setFees(address(another));
        vm.prank(address(factory));
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        HybridVault(payable(created)).setFees(address(another));
        vm.prank(founder);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        HybridVault(payable(created)).setFees(address(another));
        assertEq(HybridVault(payable(created)).fees(), companion);
        // A strategy deployed by hand is wired by its deployer or curator, once, with a companion naming it.
        HybridVault fresh = new HybridVault(p);
        HybridFees freshFees = new HybridFees(address(fresh), 2500, router, curator);
        vm.prank(other);
        vm.expectRevert(HybridVault.NotCurator.selector);
        fresh.setFees(address(freshFees));
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFees(companion);
        fresh.setFees(address(freshFees));
        assertEq(fresh.fees(), address(freshFees));
        vm.prank(curator);
        vm.expectRevert(HybridVault.InvalidConfiguration.selector);
        fresh.setFees(address(freshFees));
    }

    function test_ownershipHandsOverInTwoSteps() public {
        vm.prank(founder);
        factory.transferOwnership(creator);
        assertEq(factory.owner(), founder);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        factory.acceptOwnership();
        vm.prank(creator);
        factory.acceptOwnership();
        assertEq(factory.owner(), creator);
        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, founder));
        factory.setPublicCreation(true);
        vm.prank(creator);
        factory.setPublicCreation(true);
        assertTrue(factory.publicCreation());
    }

    function test_createdVaultRunsTheWholeLifecycleAgainstTheSharedCore() public {
        vm.prank(founder);
        (address created, address companion) = factory.create(_mandate(curator));
        HybridVault v = HybridVault(payable(created));
        vm.startPrank(curator);
        v.setTokenCeiling(address(nvda), 1000e6);
        v.setFee(1000);
        vm.stopPrank();
        vm.startPrank(lender);
        usdg.approve(created, type(uint256).max);
        v.deposit(1000e6, 0);
        vm.stopPrank();
        uint256 id = _listed(1000e6);
        vm.prank(curator);
        v.approveLoan(id, uint40(block.timestamp + 1 hours), UNITS);
        v.fund(id, type(uint256).max);
        _repay(id);
        v.settle(_ids(id));
        assertEq(v.feeAccrued(), 5e6);
        v.claimFees();
        HybridFees(companion).claimProtocol();
        assertEq(usdg.balanceOf(router), 1.25e6, "the protocol share reaches the router pinned at creation");
        assertEq(HybridFees(companion).curatorAccrued(), 3.75e6);
    }
}
