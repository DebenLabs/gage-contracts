// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {BaseTest} from "./Base.t.sol";
import {V4Fixture} from "./utils/V4Fixture.sol";
import {ZapDealVault} from "../src/ZapDealVault.sol";
import {LPZapRouter, IWrappedETH} from "../src/LPZapRouter.sol";
import {LPZapQuoter} from "../src/LPZapQuoter.sol";
import {IDealVault, Deal, DealState} from "../src/interfaces/IDealVault.sol";
import {Kind, Collateral} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";

contract FixedPermit2AllowanceToken is ERC20 {
    address constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    error Permit2AllowanceIsFixedAtInfinity();

    constructor(address holder) ERC20("Fixed Permit2", "FIXED") {
        _mint(holder, 1_000_000 ether);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return spender == PERMIT2_ADDRESS ? type(uint256).max : super.allowance(owner, spender);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (spender == PERMIT2_ADDRESS && value != type(uint256).max) revert Permit2AllowanceIsFixedAtInfinity();
        return super.approve(spender, value);
    }
}

contract ZapTestWETH is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/// @notice Exercises real v4 minting/swaps/escrow, plus borrower rights and complete rollback on failure.
contract LPZapRouterTest is BaseTest, V4Fixture {
    ZapDealVault internal zvault;
    LPZapRouter internal zap;
    ZapTestWETH internal weth;
    PoolKey internal target;
    PoolKey internal ethUsd;
    PoolKey internal memeTarget;

    function setUp() public override {
        super.setUp();
        _deployV4();
        weth = new ZapTestWETH();
        zvault = new ZapDealVault(usdg, registry, address(feeSink), address(posm), GRACE);
        target = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        ethUsd = _initPoolAtPrice(address(weth), 1e18, address(usdg), 3000e6, address(0));
        memeTarget = _initPoolAtPrice(address(meme), 1000e18, address(nvda), 1e18, address(0));
        _approvePosm(borrower, address(nvda));
        _approvePosm(borrower, address(usdg));
        _approvePosm(borrower, address(meme));
        _approvePosm(borrower, address(weth));
        vm.prank(borrower);
        weth.deposit{value: 50 ether}();
        _mintFullRange(target, 1e16, borrower, borrower);
        _mintFullRange(ethUsd, 1e15, borrower, borrower);
        _mintFullRange(memeTarget, 1e22, borrower, borrower);
        PoolKey[] memory routing = new PoolKey[](2);
        routing[0] = ethUsd;
        routing[1] = target;
        zap = new LPZapRouter(zvault, posm, permit2, IWrappedETH(address(weth)), routing);
        vm.startPrank(safe);
        registry.setRouter(address(zap), true);
        registry.setPoolAllowed(_poolId(target), true, 1);
        registry.setPoolAllowed(_poolId(memeTarget), true, 1);
        vm.stopPrank();
        vm.startPrank(borrower);
        usdg.approve(address(zap), type(uint256).max);
        weth.approve(address(zap), type(uint256).max);
        usdg.approve(address(zvault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        usdg.approve(address(zvault), type(uint256).max);
    }

    function _params() internal view returns (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) {
        z = LPZapRouter.Zap({
            inputToken: address(usdg),
            amountIn: 100e6,
            unwrapWeth: false,
            pool: target,
            tickLower: FULL_LOWER,
            tickUpper: FULL_UPPER,
            minLiquidity: 1,
            cap: 90e6,
            minPrice: 85e6,
            term: T7,
            deadline: block.timestamp + 300
        });
        swaps = new LPZapRouter.Swap[](1);
        swaps[0] = LPZapRouter.Swap(target, Currency.unwrap(target.currency0) == address(usdg), 50e6, 4e17);
    }

    function _zap() internal returns (uint256 id, uint256 nft) {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        vm.prank(borrower);
        (id, nft,) = zap.zapAndList(z, swaps);
    }

    function test_usdgCreatesLPAndListsForUser() public {
        uint256 before = usdg.balanceOf(borrower);
        (uint256 id, uint256 nft) = _zap();
        Deal memory d = zvault.getDeal(id);
        assertEq(d.borrower, borrower);
        assertEq(uint8(d.state), uint8(DealState.LISTED));
        assertEq(d.listingExpiry, 0);
        assertEq(d.minPrice, 85e6);
        assertEq(IERC721(address(posm)).ownerOf(nft), address(zvault));
        assertGt(posm.getPositionLiquidity(nft), 0);
        assertLt(usdg.balanceOf(borrower), before);
        assertEq(zvault.balanceUSDG(borrower), 0, "listing is not funding");
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(nvda.balanceOf(address(zap)), 0);
        assertEq(usdg.allowance(address(zap), PERMIT2), 0);
    }

    function test_zapVaultCannotCreateSecondERC20Market() public {
        vm.startPrank(borrower);
        nvda.approve(address(zvault), type(uint256).max);
        vm.expectRevert(IDealVault.UnsupportedKind.selector);
        zvault.list(Collateral(Kind.ERC20, address(nvda), 1e18), 90e6, T7, 0, 85e6);
        vm.stopPrank();
        assertEq(zvault.dealCount(), 0);
    }

    function test_fixedPermit2AllowanceTokenCanMintAndClearsSpenderAllowance() public {
        FixedPermit2AllowanceToken fixedToken = new FixedPermit2AllowanceToken(borrower);
        PoolKey memory pool = _initPoolAtPrice(address(fixedToken), 1e18, address(usdg), 100e6, address(0));
        _approvePosm(borrower, address(fixedToken));
        _mintFullRange(pool, 1e16, borrower, borrower);
        vm.startPrank(safe);
        registry.setERC20Allowed(address(fixedToken), true, Lane.STOCK, 1, type(uint128).max, type(uint128).max);
        registry.setPoolAllowed(_poolId(pool), true, 1);
        vm.stopPrank();
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        z.pool = pool;
        swaps[0] = LPZapRouter.Swap(pool, Currency.unwrap(pool.currency0) == address(usdg), 50e6, 4e17);
        vm.prank(borrower);
        zap.zapAndList(z, swaps);
        (uint160 allowance,,) = permit2.allowance(address(zap), address(fixedToken), address(posm));
        assertEq(allowance, 0);
        assertEq(fixedToken.balanceOf(address(zap)), 0);
    }

    function test_simulatedQuoteExecutesAndDoesNotChangePool() public {
        LPZapQuoter quoter = new LPZapQuoter(poolManager);
        (LPZapRouter.Zap memory z,) = _params();
        uint256 next = posm.nextTokenId();
        uint256 balance = usdg.balanceOf(address(poolManager));
        LPZapQuoter.Result memory q = quoter.quote(
            LPZapQuoter.Params({
                inputCurrency: address(usdg),
                amountIn: z.amountIn,
                pool: target,
                baseToken: address(usdg),
                tickLower: z.tickLower,
                tickUpper: z.tickUpper,
                slippageBps: 100,
                route: new PoolKey[](0)
            })
        );
        assertEq(posm.nextTokenId(), next);
        assertEq(usdg.balanceOf(address(poolManager)), balance);
        assertGt(q.split.liquidity, 0);
        z.minLiquidity = uint128(uint256(q.split.liquidity) * 99 / 100);
        vm.prank(borrower);
        (uint256 id,, uint128 minted) = zap.zapAndList(z, q.swaps);
        assertGe(minted, z.minLiquidity);
        assertEq(zvault.getDeal(id).borrower, borrower);
    }

    function test_simulatedWethRouteExecutes() public {
        LPZapQuoter quoter = new LPZapQuoter(poolManager);
        (LPZapRouter.Zap memory z,) = _params();
        z.inputToken = address(weth);
        z.amountIn = 0.05 ether;
        PoolKey[] memory route = new PoolKey[](1);
        route[0] = ethUsd;
        LPZapQuoter.Result memory q = quoter.quote(
            LPZapQuoter.Params({
                inputCurrency: address(weth),
                amountIn: z.amountIn,
                pool: target,
                baseToken: address(usdg),
                tickLower: z.tickLower,
                tickUpper: z.tickUpper,
                slippageBps: 100,
                route: route
            })
        );
        z.minLiquidity = uint128(uint256(q.split.liquidity) * 99 / 100);
        vm.prank(borrower);
        (,, uint128 minted) = zap.zapAndList(z, q.swaps);
        assertGe(minted, z.minLiquidity);
    }

    function test_userCanCancelAndWithdraw() public {
        (uint256 id, uint256 nft) = _zap();
        vm.startPrank(borrower);
        zvault.cancel(id);
        zvault.withdrawCollateral(id);
        vm.stopPrank();
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function test_fundingCreditsUserAndUserCanReclaim() public {
        (uint256 id, uint256 nft) = _zap();
        vm.prank(lender);
        zvault.fund(id, lender);
        assertEq(zvault.balanceUSDG(borrower), 85e6 - (85e6 * FEE_BPS / 10_000));
        assertEq(zvault.balanceUSDG(address(zap)), 0);
        vm.startPrank(borrower);
        zvault.reclaim(id);
        zvault.withdrawCollateral(id);
        vm.stopPrank();
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function test_lenderCanClaimAfterGrace() public {
        (uint256 id, uint256 nft) = _zap();
        vm.prank(lender);
        zvault.fund(id, lender);
        vm.warp(zvault.claimableAt(id));
        vm.startPrank(lender);
        zvault.claim(id);
        zvault.withdrawCollateral(id);
        vm.stopPrank();
        assertEq(IERC721(address(posm)).ownerOf(nft), lender);
    }

    function test_routerCannotCancelUsersListing() public {
        (uint256 id,) = _zap();
        vm.prank(address(zap));
        vm.expectRevert(IDealVault.NotBorrower.selector);
        zvault.cancel(id);
    }

    function test_failedListingRollsBackSwapsMintAndPayment() public {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        z.term = 3 days;
        uint256 before = usdg.balanceOf(borrower);
        uint256 next = posm.nextTokenId();
        vm.prank(borrower);
        vm.expectRevert();
        zap.zapAndList(z, swaps);
        assertEq(usdg.balanceOf(borrower), before);
        assertEq(posm.nextTokenId(), next);
        assertEq(zvault.dealCount(), 0);
    }

    function test_minLiquidityFailureRollsBack() public {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        z.minLiquidity = type(uint128).max;
        uint256 before = usdg.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert();
        zap.zapAndList(z, swaps);
        assertEq(usdg.balanceOf(borrower), before);
    }

    function test_expiredQuoteCannotSpend() public {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        z.deadline = block.timestamp;
        vm.prank(borrower);
        vm.expectRevert(LPZapRouter.Expired.selector);
        zap.zapAndList(z, swaps);
    }

    function test_disallowedPoolCannotSpend() public {
        vm.prank(safe);
        registry.setPoolAllowed(_poolId(target), false, 0);
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        vm.prank(borrower);
        vm.expectRevert();
        zap.zapAndList(z, swaps);
    }

    function test_donationsRemainIsolated() public {
        usdg.mint(address(zap), 123e6);
        nvda.mint(address(zap), 2e18);
        vm.deal(address(zap), 1 ether);
        _zap();
        assertEq(usdg.balanceOf(address(zap)), 123e6);
        assertEq(nvda.balanceOf(address(zap)), 2e18);
        assertEq(address(zap).balance, 1 ether);
    }

    function test_cannotSpendDonationAsRouteInput() public {
        usdg.mint(address(zap), 1000e6);
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        swaps[0].amountIn = 101e6;
        vm.prank(borrower);
        vm.expectRevert();
        zap.zapAndList(z, swaps);
        assertEq(usdg.balanceOf(address(zap)), 1000e6);
    }

    function test_wethRoutesIntoUSDGThenLists() public {
        (LPZapRouter.Zap memory z,) = _params();
        z.inputToken = address(weth);
        z.amountIn = 0.1 ether;
        LPZapRouter.Swap[] memory swaps = new LPZapRouter.Swap[](2);
        swaps[0] = LPZapRouter.Swap(ethUsd, Currency.unwrap(ethUsd.currency0) == address(weth), 0.1 ether, 200e6);
        swaps[1] = LPZapRouter.Swap(target, Currency.unwrap(target.currency0) == address(usdg), 100e6, 8e17);
        vm.prank(borrower);
        (uint256 id,,) = zap.zapAndList(z, swaps);
        assertEq(zvault.getDeal(id).borrower, borrower);
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(usdg.balanceOf(address(zap)), 0);
    }

    function test_memeStockLPFromUSDG() public {
        (LPZapRouter.Zap memory z,) = _params();
        z.pool = memeTarget;
        LPZapRouter.Swap[] memory swaps = new LPZapRouter.Swap[](2);
        swaps[0] = LPZapRouter.Swap(target, Currency.unwrap(target.currency0) == address(usdg), 100e6, 8e17);
        swaps[1] = LPZapRouter.Swap(memeTarget, Currency.unwrap(memeTarget.currency0) == address(nvda), 4e17, 300e18);
        vm.prank(borrower);
        (uint256 id,,) = zap.zapAndList(z, swaps);
        assertEq(zvault.getDeal(id).borrower, borrower);
        assertEq(meme.balanceOf(address(zap)), 0);
    }

    function test_nonRouterCannotListForAnotherUser() public {
        vm.prank(other);
        vm.expectRevert(ZapDealVault.NotListingRouter.selector);
        zvault.listPositionFor(Collateral(Kind.UNIV4_POSITION, address(posm), 1), 100, T7, 90, borrower);
    }

    function test_routerCannotPullBorrowersApprovedNFT() public {
        uint256 nft = _mintFullRange(target, 1e12, borrower, borrower);
        vm.prank(borrower);
        IERC721(address(posm)).setApprovalForAll(address(zvault), true);
        vm.prank(address(zap));
        vm.expectRevert();
        zvault.listPositionFor(Collateral(Kind.UNIV4_POSITION, address(posm), nft), 100, T7, 90, borrower);
        assertEq(IERC721(address(posm)).ownerOf(nft), borrower);
    }

    function test_unwrapWethForNativeRoute() public {
        PoolKey memory nativeUsd = _initPoolAtPrice(address(0), 1e18, address(usdg), 3000e6, address(0));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            nativeUsd, FULL_LOWER, FULL_UPPER, uint256(1e15), type(uint128).max, type(uint128).max, borrower, bytes("")
        );
        params[1] = abi.encode(nativeUsd.currency0, nativeUsd.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), borrower);
        vm.prank(borrower);
        posm.modifyLiquidities{value: 20 ether}(
            abi.encode(
                abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)), params
            ),
            block.timestamp + 1
        );
        PoolKey[] memory routes = new PoolKey[](1);
        routes[0] = nativeUsd;
        LPZapRouter nativeZap = new LPZapRouter(zvault, posm, permit2, IWrappedETH(address(weth)), routes);
        vm.prank(safe);
        registry.setRouter(address(nativeZap), true);
        (LPZapRouter.Zap memory z,) = _params();
        z.inputToken = address(weth);
        z.amountIn = 0.1 ether;
        z.unwrapWeth = true;
        LPZapRouter.Swap[] memory swaps = new LPZapRouter.Swap[](2);
        swaps[0] = LPZapRouter.Swap(nativeUsd, true, 0.09 ether, 200e6);
        swaps[1] = LPZapRouter.Swap(target, Currency.unwrap(target.currency0) == address(usdg), 100e6, 8e17);
        uint256 before = weth.balanceOf(borrower);
        vm.startPrank(borrower);
        weth.approve(address(nativeZap), z.amountIn);
        (uint256 id,,) = nativeZap.zapAndList(z, swaps);
        vm.stopPrank();
        assertEq(zvault.getDeal(id).borrower, borrower);
        assertEq(weth.balanceOf(borrower), before - 0.09 ether, "unused ETH rewrapped and returned as WETH");
        assertEq(address(nativeZap).balance, 0);
        assertEq(weth.balanceOf(address(nativeZap)), 0);
    }

    function test_unreviewedRouteReverts() public {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        swaps[0].key = memeTarget; // collateral admission alone does not make it a route for another target
        vm.prank(borrower);
        vm.expectRevert();
        zap.zapAndList(z, swaps);
    }

    function test_zeroMinOutReverts() public {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        swaps[0].minOut = 0;
        vm.prank(borrower);
        vm.expectRevert();
        zap.zapAndList(z, swaps);
    }

    function test_pausedListingsRollBackEverything() public {
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        vm.prank(safe);
        registry.pauseNewDeals(true);
        uint256 before = usdg.balanceOf(borrower);
        vm.prank(borrower);
        vm.expectRevert(IDealVault.NewDealsPaused.selector);
        zap.zapAndList(z, swaps);
        assertEq(usdg.balanceOf(borrower), before);
    }

    function testFuzz_userOwnsListingAndRouterHoldsNoFunds(uint128 amount) public {
        amount = uint128(bound(amount, 1e6, 1000e6));
        (LPZapRouter.Zap memory z, LPZapRouter.Swap[] memory swaps) = _params();
        z.amountIn = amount;
        swaps[0].amountIn = amount / 2;
        swaps[0].minOut = uint128(uint256(swaps[0].amountIn) * 1e10 * 9 / 10);
        uint256 before = usdg.balanceOf(borrower);
        vm.prank(borrower);
        (uint256 id, uint256 nft,) = zap.zapAndList(z, swaps);
        assertEq(zvault.getDeal(id).borrower, borrower);
        assertEq(IERC721(address(posm)).ownerOf(nft), address(zvault));
        assertGe(usdg.balanceOf(borrower), before - amount);
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(nvda.balanceOf(address(zap)), 0);
        assertEq(zvault.balanceUSDG(borrower), 0);
    }
}
