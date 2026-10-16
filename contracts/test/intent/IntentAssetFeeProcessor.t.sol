// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IUniV3Pool} from "../../src/interfaces/IUniV3.sol";
import {IV4SwapperErrors} from "../../src/interfaces/token/IV4SwapperErrors.sol";
import {IntentAssetFeeProcessor} from "../../src/intent/IntentAssetFeeProcessor.sol";
import {LocalV3} from "../helpers/LocalV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeProcessor, MockTokenOnlyRecipient} from "../mocks/MockFeeProcessor.sol";

/// @dev A pool look-alike that names the right tokens and tier but that no factory created.
contract FakeV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    constructor(address t0, address t1, uint24 f) {
        (token0, token1, fee) = (t0, t1, f);
    }
}

/// @dev An asset whose transfer out of the armed processor calls `convert` again: a reentrant sale.
contract ReenteringToken is ERC20 {
    IntentAssetFeeProcessor public target;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(IntentAssetFeeProcessor processor) external {
        target = processor;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        IntentAssetFeeProcessor processor = target;
        if (address(processor) != address(0) && from == address(processor)) {
            target = IntentAssetFeeProcessor(address(0));
            processor.convert(1e18, 1);
        }
    }
}

/// @notice The asset fee processor against real Uniswap v3 pools: the generation's lent asset (an 18-decimal GLD) sold
/// for six-decimal USDG at about 400 USDG a GLD, every USDG forwarded to a stand-in for `DealFeeRouter`. Each case runs
/// with the asset as the pool's token0 and as its token1 (mainnet's order: USDG's address is lower than GLD's and
/// NVDA's).
abstract contract IntentAssetFeeProcessorTest is LocalV3 {
    address internal constant LOW = address(0x00000000000000000000000000000000000a55E7);
    address internal constant HIGH = address(0xa55e700000000000000000000000000000000001);
    uint24 internal constant FEE = 500;
    /// @dev 100,000 GLD against 40,000,000 USDG: one GLD is 400 USDG.
    uint256 internal constant POOL_GLD = 100_000e18;
    uint256 internal constant POOL_USDG = 40_000_000e6;

    MockERC20 internal gld;
    MockERC20 internal usdg;
    address internal pool;
    MockFeeProcessor internal floorRouter;
    IntentAssetFeeProcessor internal processor;
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    /// @dev Whether the asset sorts below USDG and is the pool's token0.
    function _assetIsToken0() internal pure virtual returns (bool);

    function setUp() public virtual {
        _deployV3Factory();
        gld = _tokenAt(_assetIsToken0() ? LOW : HIGH, "GLD", 18);
        usdg = _tokenAt(_assetIsToken0() ? HIGH : LOW, "USDG", 6);
        pool = _v3Pool(address(gld), POOL_GLD, address(usdg), POOL_USDG, FEE);
        floorRouter = new MockFeeProcessor(address(usdg));
        processor = _processor(pool, address(floorRouter), keeper);
    }

    function _processor(address pool_, address forward, address keeper_) internal returns (IntentAssetFeeProcessor) {
        return new IntentAssetFeeProcessor(
            IERC20(address(gld)), IERC20(address(usdg)), v3Factory, pool_, forward, keeper_, owner
        );
    }

    /// @dev What `amount` GLD is worth at the pool's spot price, before its fee.
    function _spot(address pool_, uint256 amount) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IUniV3Pool(pool_).slot0();
        return _assetIsToken0()
            ? Math.mulDiv(Math.mulDiv(amount, sqrtP, 2 ** 96), sqrtP, 2 ** 96)
            : Math.mulDiv(Math.mulDiv(amount, 2 ** 96, sqrtP), 2 ** 96, sqrtP);
    }

    /// @dev The processor's own spot bound: the spot value less the pool fee and 1%.
    function _bound(address pool_, uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(_spot(pool_, amount), (1e6 - uint256(IUniV3Pool(pool_).fee())) * 9900, 1e6 * 10_000);
    }

    function _convert(uint256 amountIn, uint256 minUsdgOut) internal returns (uint256 out, uint256 forwarded) {
        vm.prank(keeper);
        (out, forwarded) = processor.convert(amountIn, minUsdgOut);
    }

    // ---------------------------------------------------------------- what the factory reads

    function test_answersTheFactoryAsAFeeProcessorOfTheLentAsset() public {
        assertEq(processor.USDG(), address(gld), "USDG() is the lent asset");
        assertEq(address(processor.ASSET()), address(gld));
        assertEq(address(processor.FLOOR_USDG()), address(usdg));
        assertEq(processor.V3_FACTORY(), v3Factory);
        assertEq(processor.pool(), pool);
        assertEq(processor.poolFee(), FEE);
        assertEq(processor.forwardTo(), address(floorRouter));
        assertEq(processor.keeper(), keeper);
        assertEq(processor.owner(), owner);
        assertEq(processor.MAX_IMPACT_BPS(), 100);
        assertEq(processor.availableUSDG(), 0);
        gld.mint(address(processor), 7e18);
        assertEq(processor.availableUSDG(), 7e18, "its balance of the asset");
    }

    function test_constructionRefusesAnyOtherSetting() public {
        IERC20 a = IERC20(address(gld));
        IERC20 u = IERC20(address(usdg));
        address f = address(floorRouter);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidConfiguration.selector);
        new IntentAssetFeeProcessor(IERC20(makeAddr("no code")), u, v3Factory, pool, f, keeper, owner);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidConfiguration.selector);
        new IntentAssetFeeProcessor(a, IERC20(makeAddr("no code")), v3Factory, pool, f, keeper, owner);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidConfiguration.selector);
        new IntentAssetFeeProcessor(a, a, v3Factory, pool, f, keeper, owner);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidConfiguration.selector);
        new IntentAssetFeeProcessor(a, u, makeAddr("no factory"), pool, f, keeper, owner);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidPool.selector);
        new IntentAssetFeeProcessor(a, u, v3Factory, makeAddr("no pool"), f, keeper, owner);
        address fake = address(new FakeV3Pool(_lo(), _hi(), FEE));
        vm.expectRevert(IntentAssetFeeProcessor.InvalidPool.selector);
        new IntentAssetFeeProcessor(a, u, v3Factory, fake, f, keeper, owner);
        vm.expectRevert(IntentAssetFeeProcessor.NotAFeeProcessor.selector);
        new IntentAssetFeeProcessor(a, u, v3Factory, pool, makeAddr("a wallet"), keeper, owner);
        address ofTheAsset = address(new MockFeeProcessor(address(gld)));
        vm.expectRevert(IntentAssetFeeProcessor.NotAFeeProcessor.selector);
        new IntentAssetFeeProcessor(a, u, v3Factory, pool, ofTheAsset, keeper, owner);
        // Names USDG but cannot count it: the missing view reverts without data, as the factory's check does.
        address tokenOnly = address(new MockTokenOnlyRecipient(address(usdg)));
        vm.expectRevert(bytes(""));
        new IntentAssetFeeProcessor(a, u, v3Factory, pool, tokenOnly, keeper, owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IntentAssetFeeProcessor(a, u, v3Factory, pool, f, keeper, address(0));
        // A stopped keeper is a valid start.
        assertEq(_processor(pool, f, address(0)).keeper(), address(0));
    }

    // ---------------------------------------------------------------- convert

    function test_convertSellsTheAssetAndForwardsEveryUsdg() public {
        gld.mint(address(processor), 10e18);
        // USDG already here (sent by mistake) goes on with the sale's.
        usdg.mint(address(processor), 5e6);
        uint256 spot = _spot(pool, 10e18);
        uint256 least = spot * 995 / 1000;
        vm.expectEmit(true, true, false, false, address(processor));
        emit IntentAssetFeeProcessor.Converted(pool, address(floorRouter), 10e18, 0, 0);
        (uint256 out, uint256 forwarded) = _convert(10e18, least);
        assertGe(out, least, "the keeper's minimum");
        assertLe(out, spot, "never above spot");
        assertApproxEqRel(out, 4000e6, 0.001e18, "10 GLD at 400 USDG");
        assertEq(forwarded, out + 5e6, "every USDG held");
        assertEq(usdg.balanceOf(address(floorRouter)), forwarded);
        assertEq(floorRouter.availableUSDG(), forwarded, "the floor's processor counts it");
        assertEq(usdg.balanceOf(address(processor)), 0);
        assertEq(processor.availableUSDG(), 0);
        assertEq(processor.totalConverted(), 10e18);
        assertEq(processor.totalForwarded(), forwarded);
    }

    /// @dev A clip leaves the rest of the asset for later clips.
    function test_aClipLeavesTheRestForLater() public {
        gld.mint(address(processor), 10e18);
        (uint256 first,) = _convert(4e18, 1);
        assertEq(processor.availableUSDG(), 6e18);
        (uint256 second,) = _convert(6e18, 1);
        assertEq(processor.availableUSDG(), 0);
        assertEq(processor.totalConverted(), 10e18);
        assertEq(processor.totalForwarded(), first + second);
        assertEq(usdg.balanceOf(address(floorRouter)), first + second);
    }

    function test_convertIsTheKeepersOnly() public {
        gld.mint(address(processor), 1e18);
        vm.prank(stranger);
        vm.expectRevert(IntentAssetFeeProcessor.NotKeeper.selector);
        processor.convert(1e18, 1);
        vm.prank(owner);
        vm.expectRevert(IntentAssetFeeProcessor.NotKeeper.selector);
        processor.convert(1e18, 1);
        // A zero keeper stops conversion: no call comes from the zero address.
        vm.prank(owner);
        processor.setKeeper(address(0));
        vm.prank(keeper);
        vm.expectRevert(IntentAssetFeeProcessor.NotKeeper.selector);
        processor.convert(1e18, 1);
        assertEq(processor.availableUSDG(), 1e18);
    }

    function test_convertRefusesAnEmptyOrOversizedClip() public {
        gld.mint(address(processor), 1e18);
        vm.startPrank(keeper);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidAmount.selector);
        processor.convert(0, 1);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidAmount.selector);
        processor.convert(1e18, 0);
        vm.expectRevert(abi.encodeWithSelector(IntentAssetFeeProcessor.ClipTooLarge.selector, 1e18 + 1, 1e18));
        processor.convert(1e18 + 1, 1);
        vm.stopPrank();
    }

    /// @dev The keeper's minimum holds: a sale short of it reverts, and a failed clip changes nothing.
    function test_convertHoldsTheKeepersMinimum() public {
        gld.mint(address(processor), 10e18);
        uint256 snapshot = vm.snapshotState();
        (uint256 out,) = _convert(10e18, 1);
        vm.revertToState(snapshot);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IV4SwapperErrors.TooLittleOut.selector, out, out + 1));
        processor.convert(10e18, out + 1);
        assertEq(processor.availableUSDG(), 10e18);
        assertEq(usdg.balanceOf(address(floorRouter)), 0);
        assertEq(processor.totalConverted(), 0);
        (uint256 exact,) = _convert(10e18, out);
        assertEq(exact, out);
    }

    /// @dev D57's 1% bound at spot holds whatever minimum the keeper passes: 3% of the pool's GLD returns about 3% less
    /// than spot, so the sale reverts naming the bound, the floor of any lower minimum. A tenth of it fits.
    function test_convertHoldsTheImpactBound() public {
        uint256 clip = POOL_GLD * 3 / 100;
        gld.mint(address(processor), clip);
        uint256 out = _quoteExactIn(pool, address(gld), clip);
        uint256 least = _bound(pool, clip);
        assertLt(out, least, "past the bound");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IV4SwapperErrors.TooLittleOut.selector, out, least));
        processor.convert(clip, 1);
        assertEq(processor.availableUSDG(), clip);
        uint256 tenth = _bound(pool, clip / 10);
        (uint256 got,) = _convert(clip / 10, 1);
        assertGe(got, tenth);
    }

    function test_theSwapCallbackPaysOnlyThePoolInItsSale() public {
        gld.mint(address(processor), 1e18);
        vm.prank(stranger);
        vm.expectRevert(IntentAssetFeeProcessor.BadCallback.selector);
        processor.uniswapV3SwapCallback(1e18, -1, abi.encode(uint256(1e18)));
        // The pool itself, outside a sale.
        vm.prank(pool);
        vm.expectRevert(IntentAssetFeeProcessor.BadCallback.selector);
        processor.uniswapV3SwapCallback(1e18, -1, abi.encode(uint256(1e18)));
        assertEq(processor.availableUSDG(), 1e18);
        // And once a sale is over, the pool is refused again.
        _convert(1e18 / 2, 1);
        vm.prank(pool);
        vm.expectRevert(IntentAssetFeeProcessor.BadCallback.selector);
        processor.uniswapV3SwapCallback(1e18, -1, abi.encode(uint256(1e18)));
    }

    // ---------------------------------------------------------------- settings

    function test_settingsAreTheOwnersOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        processor.setPool(pool);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        processor.setForwardTo(address(floorRouter));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        processor.setKeeper(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        processor.rescue(IERC20(address(gld)), stranger, 0);
        vm.stopPrank();
        // The keeper is not an owner either.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        processor.setKeeper(keeper);
    }

    /// @dev Another tier of the same pair, as the factory names it, is admitted, and sales go there; a pool of another
    /// pair, a look-alike and an address without code are refused.
    function test_setPoolAdmitsOnlyTheFactorysPoolOfThePair() public {
        address wider = _v3Pool(address(gld), POOL_GLD, address(usdg), POOL_USDG, 3000);
        vm.expectEmit(true, false, false, true, address(processor));
        emit IntentAssetFeeProcessor.PoolSet(wider, 3000);
        vm.prank(owner);
        processor.setPool(wider);
        assertEq(processor.pool(), wider);
        assertEq(processor.poolFee(), 3000);
        gld.mint(address(processor), 1e18);
        uint256 before = IERC20(address(gld)).balanceOf(wider);
        _convert(1e18, 1);
        assertEq(IERC20(address(gld)).balanceOf(wider), before + 1e18, "sold through the 0.3% pool");

        MockERC20 other = new MockERC20("WETH", "WETH", 18);
        address otherPair = _v3Pool(address(other), 1000e18, address(usdg), 4_000_000e6, FEE);
        address fake = address(new FakeV3Pool(_lo(), _hi(), FEE));
        vm.startPrank(owner);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidPool.selector);
        processor.setPool(otherPair);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidPool.selector);
        processor.setPool(fake);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidPool.selector);
        processor.setPool(makeAddr("no code"));
        vm.stopPrank();
        assertEq(processor.pool(), wider);
    }

    function test_setForwardToAdmitsOnlyAFeeProcessorOfUsdg() public {
        MockFeeProcessor next = new MockFeeProcessor(address(usdg));
        vm.expectEmit(true, false, false, false, address(processor));
        emit IntentAssetFeeProcessor.ForwardToSet(address(next));
        vm.prank(owner);
        processor.setForwardTo(address(next));
        assertEq(processor.forwardTo(), address(next));
        gld.mint(address(processor), 1e18);
        (, uint256 forwarded) = _convert(1e18, 1);
        assertEq(usdg.balanceOf(address(next)), forwarded);
        assertEq(usdg.balanceOf(address(floorRouter)), 0);

        address ofTheAsset = address(new MockFeeProcessor(address(gld)));
        vm.startPrank(owner);
        // Itself: its `USDG()` is the asset.
        vm.expectRevert(IntentAssetFeeProcessor.NotAFeeProcessor.selector);
        processor.setForwardTo(address(processor));
        vm.expectRevert(IntentAssetFeeProcessor.NotAFeeProcessor.selector);
        processor.setForwardTo(stranger);
        vm.expectRevert(IntentAssetFeeProcessor.NotAFeeProcessor.selector);
        processor.setForwardTo(ofTheAsset);
        vm.stopPrank();
        assertEq(processor.forwardTo(), address(next));
    }

    function test_setKeeperNamesTheOneAccountThatConverts() public {
        vm.expectEmit(true, false, false, false, address(processor));
        emit IntentAssetFeeProcessor.KeeperSet(stranger);
        vm.prank(owner);
        processor.setKeeper(stranger);
        gld.mint(address(processor), 1e18);
        vm.prank(keeper);
        vm.expectRevert(IntentAssetFeeProcessor.NotKeeper.selector);
        processor.convert(1e18, 1);
        vm.prank(stranger);
        processor.convert(1e18, 1);
        assertEq(processor.availableUSDG(), 0);
    }

    function test_rescueReturnsAStrayTokenButNeverTheAssetOrUsdg() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(processor), 3e18);
        gld.mint(address(processor), 1e18);
        usdg.mint(address(processor), 1e6);
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(processor));
        emit IntentAssetFeeProcessor.Rescued(address(stray), stranger, 3e18);
        processor.rescue(IERC20(address(stray)), stranger, 3e18);
        assertEq(stray.balanceOf(stranger), 3e18);
        vm.expectRevert(IntentAssetFeeProcessor.ProtectedToken.selector);
        processor.rescue(IERC20(address(gld)), owner, 1e18);
        vm.expectRevert(IntentAssetFeeProcessor.ProtectedToken.selector);
        processor.rescue(IERC20(address(usdg)), owner, 1e6);
        vm.expectRevert(IntentAssetFeeProcessor.InvalidConfiguration.selector);
        processor.rescue(IERC20(address(stray)), address(0), 0);
        vm.stopPrank();
        assertEq(processor.availableUSDG(), 1e18);
        assertEq(usdg.balanceOf(address(processor)), 1e6);
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(owner);
        processor.transferOwnership(stranger);
        assertEq(processor.owner(), owner);
        assertEq(processor.pendingOwner(), stranger);
        vm.prank(stranger);
        processor.acceptOwnership();
        assertEq(processor.owner(), stranger);
    }

    /// @dev A transfer hook that calls `convert` again inside a sale hits the transient lock, and the whole sale reverts.
    function test_aReentrantConvertReverts() public {
        ReenteringToken hook = new ReenteringToken();
        address hookPool = _v3Pool(address(hook), POOL_GLD, address(usdg), POOL_USDG, FEE);
        IntentAssetFeeProcessor exposed = new IntentAssetFeeProcessor(
            IERC20(address(hook)), IERC20(address(usdg)), v3Factory, hookPool, address(floorRouter), keeper, owner
        );
        hook.mint(address(exposed), 2e18);
        hook.arm(exposed);
        vm.prank(keeper);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        exposed.convert(1e18, 1);
        assertEq(exposed.availableUSDG(), 2e18);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Any clip within the bound returns at least the keeper's minimum and the spot bound, or reverts naming the
    /// keeper's minimum when the sale cannot meet it; all of it is forwarded.
    function testFuzz_convertMeetsBothMinimums(uint256 amountIn, uint256 minUsdgOut) public {
        amountIn = bound(amountIn, 1e15, POOL_GLD / 200);
        gld.mint(address(processor), amountIn);
        uint256 snapshot = vm.snapshotState();
        (uint256 out,) = _convert(amountIn, 1);
        vm.revertToState(snapshot);
        assertGe(out, _bound(pool, amountIn), "the spot bound");
        minUsdgOut = bound(minUsdgOut, 1, out * 2);
        if (minUsdgOut > out) {
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(IV4SwapperErrors.TooLittleOut.selector, out, minUsdgOut));
            processor.convert(amountIn, minUsdgOut);
            assertEq(processor.availableUSDG(), amountIn);
        } else {
            (uint256 got, uint256 forwarded) = _convert(amountIn, minUsdgOut);
            assertEq(got, out);
            assertEq(forwarded, out);
            assertEq(usdg.balanceOf(address(floorRouter)), out);
            assertEq(processor.availableUSDG(), 0);
        }
    }

    /// @dev A clip that moves the pool past the bound always reverts, whatever the minimum.
    function testFuzz_anOversizedClipNeverSells(uint256 amountIn, uint256 minUsdgOut) public {
        amountIn = bound(amountIn, POOL_GLD / 40, POOL_GLD / 2);
        minUsdgOut = bound(minUsdgOut, 1, type(uint128).max);
        gld.mint(address(processor), amountIn);
        vm.prank(keeper);
        vm.expectPartialRevert(IV4SwapperErrors.TooLittleOut.selector);
        processor.convert(amountIn, minUsdgOut);
        assertEq(processor.availableUSDG(), amountIn);
    }

    /// @dev No caller is paid outside a sale. (No call ever comes from the zero address.)
    function testFuzz_theCallbackPaysNobodyOutsideASale(address caller, int256 delta0, int256 delta1, uint256 amount)
        public
    {
        vm.assume(caller != address(0));
        gld.mint(address(processor), 1e18);
        vm.prank(caller);
        vm.expectRevert(IntentAssetFeeProcessor.BadCallback.selector);
        processor.uniswapV3SwapCallback(delta0, delta1, abi.encode(amount));
        assertEq(processor.availableUSDG(), 1e18);
    }

    /// @dev The owner cannot take the asset or USDG out, by any amount to anyone.
    function testFuzz_rescueNeverMovesTheAssetOrUsdg(address to, uint256 amount, bool asset) public {
        gld.mint(address(processor), 1e18);
        usdg.mint(address(processor), 1e6);
        vm.prank(owner);
        vm.expectRevert(IntentAssetFeeProcessor.ProtectedToken.selector);
        processor.rescue(IERC20(asset ? address(gld) : address(usdg)), to, amount);
        assertEq(processor.availableUSDG(), 1e18);
        assertEq(usdg.balanceOf(address(processor)), 1e6);
    }

    // ---------------------------------------------------------------- helpers

    function _lo() internal view returns (address) {
        return address(gld) < address(usdg) ? address(gld) : address(usdg);
    }

    function _hi() internal view returns (address) {
        return address(gld) < address(usdg) ? address(usdg) : address(gld);
    }
}

contract IntentAssetFeeProcessorAssetToken0Test is IntentAssetFeeProcessorTest {
    function _assetIsToken0() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Mainnet's order: USDG is token0 of both GLD/USDG and NVDA/USDG.
contract IntentAssetFeeProcessorAssetToken1Test is IntentAssetFeeProcessorTest {
    function _assetIsToken0() internal pure override returns (bool) {
        return false;
    }
}
