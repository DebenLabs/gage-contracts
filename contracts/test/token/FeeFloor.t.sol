// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TokenLayerFixture} from "./TokenLayerFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FeeFloor} from "../../src/token/FeeFloor.sol";
import {DealFeeRouter} from "../../src/token/DealFeeRouter.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {ICreatorFeeSplitter} from "../../src/interfaces/token/ICreatorFeeSplitter.sol";

contract FeeClaimFixture {
    address public recipient;

    function setRecipient(address to) external {
        recipient = to;
    }

    function claimCreatorFees() external returns (uint256 amount) {
        amount = address(this).balance;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok);
    }

    receive() external payable {}
}

contract FeeFloorTest is TokenLayerFixture {
    FeeFloor internal floor;
    DealFeeRouter internal processor;
    FeeClaimFixture internal claimSource;
    PoolKey internal usdgEth;
    PoolKey internal gageEth;

    function setUp() public override {
        super.setUp();
        vm.chainId(46_630);
        vm.deal(treasury, 10_000 ether);
        usdg.mint(treasury, 10_000_000e6);
        gage.mint(treasury, 1_000_000_000e18);
        usdgEth = _initPoolAtPrice(address(0), 1 ether, address(usdg), 2500e6, address(0));
        gageEth = _initPoolAtPrice(address(0), 1 ether, address(gage), 1_000_000e18, address(0));
        _addRawLiquidityNative(usdgEth, FULL_LOWER, FULL_UPPER, 1e17, treasury, 3000 ether);
        _addRawLiquidityNative(gageEth, FULL_LOWER, FULL_UPPER, 1e23, treasury, 101 ether);
        claimSource = new FeeClaimFixture();
        floor = new FeeFloor(
            FeeFloor.Params({
                poolManager: poolManager,
                positionManager: posm,
                permit2: permit2,
                opsWallet: other,
                sgage: sgage,
                gage: address(gage),
                usdgEth: usdgEth,
                gageEth: gageEth,
                gageSgage: pool,
                launchPoolFeePips: 0,
                ponsClaimTarget: address(claimSource),
                ponsClaimCalldata: abi.encodeCall(claimSource.claimCreatorFees, ()),
                threshold: 100e6,
                initialOwner: address(this)
            }),
            address(0)
        );
        claimSource.setRecipient(address(floor));
        processor = new DealFeeRouter(
            DealFeeRouter.Params({
                poolManager: poolManager,
                usdg: usdg,
                gage: gage,
                feeSink: feeSink,
                floor: floor,
                usdgEth: usdgEth,
                gageEth: gageEth,
                launchPoolFeePips: 0,
                threshold: 100e6,
                initialOwner: address(this)
            }),
            address(0)
        );
        lpRewards.setFloor(address(floor));
        vm.startPrank(safe);
        registry.setFee(100);
        feeSink.setBuyback(address(processor));
        feeSink.setRoute(FeeSink.Route.BUYBACK);
        vm.stopPrank();
    }

    function test_creatorBelowThresholdLeavesUnclaimedFundsAndOpsUntouched() public {
        vm.deal(address(claimSource), 0.01 ether); // 25 USDG gross
        uint256 ops = other.balance;
        vm.expectPartialRevert(ICreatorFeeSplitter.BelowThreshold.selector);
        floor.claimAndSplit(0.01 ether);
        assertEq(address(claimSource).balance, 0.01 ether);
        assertEq(address(floor).balance, 0);
        assertEq(other.balance, ops);
        assertEq(floor.floorCount(), 0);
    }

    function test_creatorHalfToOpsHalfToFloorAndBatchFinishesBelowTrigger() public {
        vm.deal(address(claimSource), 0.05 ether); // 125 USDG gross
        uint256 ops = other.balance;
        uint256 supply = sgage.totalSupply();
        uint256 gageAdded = floor.claimAndSplit(0.02 ether);
        assertEq(other.balance - ops, 0.01 ether);
        assertGt(gageAdded, 0);
        assertEq(floor.batchRemaining(), 0.03 ether);
        assertLt(floor.ethValueUSDG(address(floor).balance), floor.threshold());
        floor.claimAndSplit(0.03 ether);
        assertEq(other.balance - ops, 0.025 ether);
        assertEq(address(floor).balance, 0);
        assertEq(floor.batchRemaining(), 0);
        assertEq(sgage.totalSupply(), supply, "fee purchases do not burn sGAGE");
        assertEq(lpRewards.positionState(floor.floorTokenIds(0)).weight, 0, "floor excluded from emissions");
    }

    function test_dealFeePullsActualVaultCreditAtomicallyAndKeepsAllProceedsForFloor() public {
        (uint256 dealId,) = _fundDeal(); // 79.60 USDG fee
        assertGt(dealId, 0);
        uint256 credited = vault.balanceUSDG(address(feeSink));
        assertEq(credited, 79_600_000);
        vm.expectPartialRevert(DealFeeRouter.BelowThreshold.selector);
        processor.process(25e6);
        assertEq(vault.balanceUSDG(address(feeSink)), credited);
        assertEq(usdg.balanceOf(address(processor)), 0);
        // Fees can be split between internal vault credit, sink and the processor.
        usdg.mint(address(feeSink), 15e6);
        usdg.mint(address(processor), 6e6);
        uint256 available = processor.availableUSDG();
        uint256 supply = sgage.totalSupply();
        uint256 ops = other.balance;
        uint256 added = processor.process(25e6);
        assertGt(added, 0);
        assertEq(vault.balanceUSDG(address(feeSink)), 0);
        assertEq(usdg.balanceOf(address(feeSink)), 0);
        assertEq(usdg.balanceOf(address(processor)), available - 25e6);
        assertEq(processor.batchRemaining(), available - 25e6);
        processor.process(available - 25e6);
        assertEq(processor.totalUSDGProcessed(), available);
        assertEq(processor.batchRemaining(), 0);
        assertEq(processor.availableUSDG(), 0);
        assertEq(other.balance, ops, "no operations cut from deal fees");
        assertEq(sgage.totalSupply(), supply, "no fee-funded sGAGE burn");
        assertEq(gage.balanceOf(address(processor)), 0);
        assertEq(gage.allowance(address(processor), address(floor)), 0);
        (uint256 backing,) = floor.floorBacking();
        assertGt(backing, 0);
    }

    function test_triggerBoundsAndOverlargeClipAreAtomic() public {
        vm.expectRevert(FeeFloor.ThresholdOutOfBounds.selector);
        floor.setThreshold(1e6);
        vm.expectRevert(DealFeeRouter.ThresholdOutOfBounds.selector);
        processor.setThreshold(10_001e6);
        vm.prank(other);
        vm.expectRevert();
        processor.setThreshold(500e6);
        usdg.mint(address(feeSink), 100e6);
        vm.expectPartialRevert(DealFeeRouter.ClipTooLarge.selector);
        processor.process(101e6);
        assertEq(usdg.balanceOf(address(feeSink)), 100e6);
        assertEq(processor.batchRemaining(), 0);
    }
}
