// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniV3Factory, IUniV3Pool} from "../../src/interfaces/IUniV3.sol";
import {IIntentFeeProcessor} from "../../src/interfaces/IIntentFeeProcessor.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";
import {IntentAssetFeeProcessor} from "../../src/intent/IntentAssetFeeProcessor.sol";
import {IntentClosedReserve} from "../../src/intent/IntentClosedReserve.sol";

/// @notice The asset fee processor on a fork of Robinhood Chain mainnet (4663): real GLD and NVDA sold for real USDG
/// through the canonical Uniswap v3 0.05% pools, the USDG forwarded into the live `DealFeeRouter`
/// (`launch/live/4663.json`), whose `availableUSDG()` counts it for the floor (D57). Nothing is sent to the chain: the
/// processor is deployed on the local fork and its stock tokens are `deal`t.
/// @dev Skipped unless ROBINHOOD_RPC_URL is set; FORK_BLOCK pins the block, otherwise the head is used. Fork through a
/// read-only endpoint (the local test relay), never the production RPC.
contract IntentAssetFeeProcessorForkTest is Test {
    string internal constant MANIFEST = "../launch/live/4663.json";
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    /// @dev `getPool(token, USDG, 500)` of the canonical factory, read 14 October 2026: USDG is token0 of both.
    address internal constant GLD_USDG_500 = 0xBA2f1ed4cEB2169D538d1e614D847E83C5A55913;
    address internal constant NVDA_USDG_500 = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    address internal dealFeeRouter;
    address internal keeper = makeAddr("asset-fee-keeper");
    address internal owner = makeAddr("asset-fee-owner");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        assertEq(block.chainid, 4663, "Robinhood Chain mainnet only");
        string memory manifest = vm.readFile(MANIFEST);
        assertEq(vm.parseJsonAddress(manifest, ".USDG"), USDG, "manifest USDG");
        dealFeeRouter = vm.parseJsonAddress(manifest, ".DealFeeRouter");
        assertEq(IIntentFeeProcessor(dealFeeRouter).USDG(), USDG, "the live floor processor takes USDG");
    }

    function test_fork_convertsGldThroughItsFiveBasisPointPool() public {
        _convert(GLD, GLD_USDG_500, 5e18);
    }

    function test_fork_convertsNvdaThroughItsFiveBasisPointPool() public {
        _convert(NVDA, NVDA_USDG_500, 5e18);
    }

    /// @dev A clip of a third of the pool's GLD moves it far past D57's 1% at spot: refused, whatever the minimum.
    function test_fork_anOversizedClipIsRefused() public {
        IntentAssetFeeProcessor processor = _processor(GLD, GLD_USDG_500);
        uint256 clip = IERC20(GLD).balanceOf(GLD_USDG_500) / 3;
        deal(GLD, address(processor), clip);
        vm.prank(keeper);
        vm.expectPartialRevert(IV4SwapperErrors.TooLittleOut.selector);
        processor.convert(clip, 1);
        assertEq(processor.availableUSDG(), clip);
    }

    /// @dev The closed reserve over real GLD: what the factory and its vaults read answers.
    function test_fork_theClosedReserveTakesRealGld() public {
        IntentClosedReserve reserve = new IntentClosedReserve(IERC20(GLD));
        assertEq(reserve.asset(), GLD);
        assertEq(reserve.decimals(), IERC20Metadata(GLD).decimals());
        assertEq(reserve.maxDeposit(address(this)), 0);
        deal(GLD, address(reserve), 1e18);
        assertEq(reserve.totalAssets(), 0);
        assertEq(reserve.previewWithdraw(101e18), 101e18);
    }

    function _processor(address asset, address expectedPool) internal returns (IntentAssetFeeProcessor processor) {
        address pool = IUniV3Factory(V3_FACTORY).getPool(asset, USDG, 500);
        assertEq(pool, expectedPool, "the canonical 0.05% pool");
        processor =
            new IntentAssetFeeProcessor(IERC20(asset), IERC20(USDG), V3_FACTORY, pool, dealFeeRouter, keeper, owner);
        assertEq(processor.USDG(), asset, "answers the factory with the lent asset");
        assertEq(IERC20Metadata(asset).decimals(), 18);
    }

    /// @dev Five tokens sold for at least their spot value less the pool fee and half a percent, the USDG counted by
    /// the live `DealFeeRouter`.
    function _convert(address asset, address expectedPool, uint256 amount) internal {
        IntentAssetFeeProcessor processor = _processor(asset, expectedPool);
        deal(asset, address(processor), amount);
        assertEq(processor.availableUSDG(), amount);
        uint256 spot = _spotValue(expectedPool, amount);
        uint256 least = spot * 9995 / 10_000 * 995 / 1000;
        uint256 counted = IIntentFeeProcessor(dealFeeRouter).availableUSDG();
        uint256 held = IERC20(USDG).balanceOf(dealFeeRouter);
        vm.prank(keeper);
        (uint256 usdgOut, uint256 forwarded) = processor.convert(amount, least);
        assertGe(usdgOut, least, "the keeper's minimum");
        assertLe(usdgOut, spot, "never above spot");
        assertEq(forwarded, usdgOut);
        assertEq(IERC20(USDG).balanceOf(dealFeeRouter) - held, usdgOut, "USDG reached DealFeeRouter");
        assertEq(IIntentFeeProcessor(dealFeeRouter).availableUSDG() - counted, usdgOut, "counted for the floor");
        assertEq(processor.availableUSDG(), 0);
        assertEq(IERC20(USDG).balanceOf(address(processor)), 0);
        emit log_named_decimal_uint("USDG for five tokens", usdgOut, 6);
        emit log_named_decimal_uint("spot value", spot, 6);
    }

    /// @dev `amount` of the pool's token1 (the stock token) at spot, in its token0 (USDG).
    function _spotValue(address pool, uint256 amount) internal view returns (uint256) {
        assertEq(IUniV3Pool(pool).token0(), USDG, "USDG is token0");
        (uint160 sqrtP,,,,,,) = IUniV3Pool(pool).slot0();
        return Math.mulDiv(Math.mulDiv(amount, 2 ** 96, sqrtP), 2 ** 96, sqrtP);
    }
}
