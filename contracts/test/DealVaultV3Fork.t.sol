// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IV3PositionManager, IV3Pool} from "../src/interfaces/IV3PositionManager.sol";
import {DealVaultV3} from "../src/DealVaultV3.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {LPFeeForwarder} from "../src/LPFeeForwarder.sol";
import {IUniversalRouter} from "../src/interfaces/IUniversalRouter.sol";
import {EntryRouter} from "../src/EntryRouter.sol";
import {IDealVault, DealState} from "../src/interfaces/IDealVault.sol";
import {UniV3PositionAdapter as Adapter} from "../src/libraries/UniV3PositionAdapter.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";

interface V3Mint {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
}

interface V3Swap {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

contract DealVaultV3ForkTest is Test {
    address constant PM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant POOL = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PROCESSOR = 0xEaE95cD11e1105BF1E82033c918ff17f931B0245;
    address constant OLD = 0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF;
    address constant V2 = 0xc23A08282AA1A9141C6fD7A29e7dFbFe841cC6B6;
    address borrower = makeAddr("v3-borrower");
    address lender = makeAddr("v3-lender");
    address other = makeAddr("v3-other");
    DealVaultV3 vault;
    CollateralRegistry reg;
    LPFeeForwarder forwarder;
    uint256 nft;
    uint128 liq;
    bytes32 oldHash;
    bytes32 v2Hash;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 57_258_971);
        assertEq(block.chainid, 4663);
        oldHash = OLD.codehash;
        v2Hash = V2.codehash;
        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        reg = new CollateralRegistry(address(this), terms, 100);
        forwarder = new LPFeeForwarder(IERC20(USDG), PROCESSOR);
        vault = new DealVaultV3(IERC20(USDG), reg, address(forwarder), PM, 48 hours);
        forwarder.bind(vault);
        reg.setMemePairs(4);
        reg.setInRangeRequired(true);
        reg.setERC20Allowed(PONS, true, Lane.MEME, 1, type(uint128).max, type(uint128).max);
        reg.setERC20Allowed(WETH, true, Lane.ETH, 1, type(uint128).max, type(uint128).max);
        reg.setPoolAllowed(bytes32(uint256(uint160(POOL))), true, 1);
        deal(PONS, borrower, 10_000e18);
        deal(WETH, borrower, 10e18);
        deal(USDG, borrower, 1000e6);
        deal(USDG, lender, 1000e6);
        vm.startPrank(borrower);
        IERC20(PONS).approve(PM, type(uint256).max);
        IERC20(WETH).approve(PM, type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        (nft, liq) = mint(-887_200, 887_200);
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    function mint(int24 lower, int24 upper) internal returns (uint256 id, uint128 liquidity) {
        vm.startPrank(borrower);
        (id, liquidity,,) = V3Mint(PM)
            .mint(V3Mint.MintParams(WETH, PONS, 10_000, lower, upper, 1e18, 5000e18, 0, 0, borrower, block.timestamp));
        IERC721(PM).approve(address(vault), id);
        vm.stopPrank();
    }

    function c(uint256 id) internal pure returns (Collateral memory) {
        return Collateral(Kind.UNIV3_POSITION, PM, id);
    }

    function listed() internal returns (uint256 id) {
        vm.prank(borrower);
        id = vault.list(c(nft), 100e6, 7 days, 0, 90e6);
    }

    function funded() internal returns (uint256 id) {
        id = listed();
        vm.prank(lender);
        vault.fund(id, lender);
    }

    function trade() internal {
        deal(WETH, address(this), 1e18);
        V3Swap(POOL).swap(other, true, 1e17, 4_295_128_740, "");
    }

    function uniswapV3SwapCallback(int256 a, int256 b, bytes calldata) external {
        require(msg.sender == POOL);
        if (a > 0) IERC20(WETH).transfer(POOL, uint256(a));
        if (b > 0) IERC20(PONS).transfer(POOL, uint256(b));
    }

    function unwind(address owner) internal {
        vm.startPrank(owner);
        V3Mint(PM).decreaseLiquidity(V3Mint.DecreaseParams(nft, liq, 0, 0, block.timestamp));
        V3Mint(PM).collect(V3Mint.CollectParams(nft, owner, type(uint128).max, type(uint128).max));
        vm.stopPrank();
        assertEq(IV3PositionManager(PM).positions(nft).liquidity, 0);
    }

    function testFork_reclaimFeesAndWithdrawal() public {
        uint256 id = funded();
        assertEq(IERC721(PM).ownerOf(nft), address(vault));
        assertEq(IERC721(PM).getApproved(nft), address(0));
        trade();
        vm.prank(borrower);
        vm.expectRevert();
        V3Mint(PM).collect(V3Mint.CollectParams(nft, borrower, type(uint128).max, type(uint128).max));
        vm.prank(borrower);
        vault.reclaim(id);
        vm.prank(borrower);
        vault.withdrawCollateral(id);
        vm.prank(borrower);
        (uint256 fees0, uint256 fees1) =
            V3Mint(PM).collect(V3Mint.CollectParams(nft, borrower, type(uint128).max, type(uint128).max));
        assertGt(fees0 + fees1, 0);
        unwind(borrower);
        vm.prank(lender);
        vault.withdrawUSDG();
        assertEq(IERC20(USDG).balanceOf(lender), 1010e6);
        assertEq(OLD.codehash, oldHash);
        assertEq(V2.codehash, v2Hash);
    }

    function testFork_defaultAfterPauseDelistPreservesFees() public {
        uint256 id = funded();
        trade();
        reg.pauseNewDeals(true);
        reg.setPoolAllowed(bytes32(uint256(uint160(POOL))), false, 1);
        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.prank(lender);
        vault.withdrawCollateral(id);
        assertEq(IERC721(PM).ownerOf(nft), lender);
        unwind(lender);
    }

    function testFork_cancelAndBidRefund() public {
        uint256 id = listed();
        vm.prank(lender);
        uint256 bid = vault.bid(id, 90e6, uint40(block.timestamp + 1 days), lender);
        vm.prank(borrower);
        vault.cancel(id);
        vm.prank(lender);
        vault.withdrawBid(bid);
        vm.prank(lender);
        vault.withdrawUSDG();
        vm.prank(borrower);
        vault.withdrawCollateral(id);
        assertEq(IERC20(USDG).balanceOf(lender), 1000e6);
        assertEq(IERC721(PM).ownerOf(nft), borrower);
    }

    function testFork_dealFeesForwardOnlyOnce() public {
        funded();
        uint256 before = IERC20(USDG).balanceOf(PROCESSOR);
        vm.prank(other);
        assertEq(forwarder.forward(), 900_000);
        assertEq(IERC20(USDG).balanceOf(PROCESSOR) - before, 900_000);
        assertEq(forwarder.forward(), 0);
        assertEq(vault.balanceUSDG(borrower), 89_100_000);
        vm.expectRevert(LPFeeForwarder.InvalidBinding.selector);
        forwarder.bind(vault);
    }

    function testFork_rejectDirectTransferWrongOwnerKindManager() public {
        vm.prank(borrower);
        vm.expectRevert();
        IERC721(PM).safeTransferFrom(borrower, address(vault), nft);
        vm.prank(other);
        vm.expectPartialRevert(Adapter.NotPositionOwner.selector);
        vault.list(c(nft), 100e6, 7 days, 0, 90e6);
        vm.prank(borrower);
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vault.list(Collateral(Kind.UNIV4_POSITION, PM, nft), 100e6, 7 days, 0, 90e6);
        vm.prank(borrower);
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vault.list(Collateral(Kind.UNIV3_POSITION, PONS, nft), 100e6, 7 days, 0, 90e6);
        vm.prank(borrower);
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        vault.list(Collateral(Kind.ERC20, PONS, 1e18), 100e6, 7 days, 0, 90e6);
    }

    function testFork_rejectPoolTokenQuoteChanges() public {
        reg.setPoolAllowed(bytes32(uint256(uint160(POOL))), false, 1);
        vm.expectPartialRevert(Adapter.PoolNotAllowed.selector);
        listed();
        reg.setPoolAllowed(bytes32(uint256(uint160(POOL))), true, 1);
        reg.setMemePairs(2);
        vm.expectPartialRevert(Adapter.PairNotAllowed.selector);
        listed();
        reg.setMemePairs(4);
        reg.setERC20Allowed(PONS, false, Lane.MEME, 0, 0, 0);
        vm.expectPartialRevert(Adapter.PairNotAllowed.selector);
        listed();
    }

    function testFork_rejectZeroLiquidityAndOutOfRange() public {
        unwind(borrower);
        vm.expectPartialRevert(Adapter.LiquidityBelowMinimum.selector);
        listed();
        (nft, liq) = mint(90_000, 90_200);
        vm.expectPartialRevert(Adapter.OutOfRange.selector);
        listed();
    }

    function testFork_lenderCannotClaimEarlyOrTwice() public {
        uint256 id = funded();
        vm.prank(lender);
        vm.expectRevert();
        vault.claim(id);
        vm.prank(other);
        vm.expectRevert();
        vault.withdrawCollateral(id);
        vm.warp(vault.claimableAt(id));
        vm.prank(lender);
        vault.claim(id);
        vm.prank(lender);
        vault.withdrawCollateral(id);
        vm.prank(lender);
        vm.expectRevert();
        vault.withdrawCollateral(id);
    }

    struct V4Key {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct RHSwap {
        V4Key poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function testFork_ethEntryUsesRealRouterAndCorrectV3Deal() public {
        EntryRouter router =
            new EntryRouter(vault, IERC20(USDG), IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904));
        reg.setRouter(address(router), true);
        uint256 id = listed();
        vm.deal(lender, 1 ether);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RHSwap(V4Key(address(0), USDG, 100, 1, address(0)), true, 1 ether, 90e6, 90e6 * 1e36 / 1e18, "")
        );
        params[1] = abi.encode(address(0), uint256(1 ether));
        params[2] = abi.encode(USDG, address(router), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0e", params);
        vm.prank(lender);
        router.fundWithETH{value: 1 ether}(id, hex"10", inputs, block.timestamp);
        assertEq(uint8(vault.getDeal(id).kind), 2);
        assertEq(vault.getDeal(id).lender, lender);
        assertEq(uint8(vault.getDeal(id).state), uint8(DealState.FUNDED));
        assertEq(IERC20(USDG).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(USDG).allowance(address(router), address(vault)), 0);
        vm.prank(borrower);
        vault.reclaim(id);
        vm.prank(borrower);
        vault.withdrawCollateral(id);
        assertEq(IERC721(PM).ownerOf(nft), borrower);
    }
}
