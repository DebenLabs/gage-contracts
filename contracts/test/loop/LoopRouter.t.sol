// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IntentPlanBaseTest} from "../intent/IntentPlanBase.t.sol";
import {V4Fixture} from "../utils/V4Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IntentVault} from "../../src/intent/IntentVault.sol";
import {IntentFeeMath} from "../../src/intent/IntentFeeMath.sol";
import {IntentQuoteVerifier} from "../../src/intent/IntentQuoteVerifier.sol";
import {IntentFillRouter} from "../../src/intent/IntentFillRouter.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {Kind} from "../../src/types/Types.sol";
import {LoopRouter} from "../../src/loop/LoopRouter.sol";
import {IUniV3Factory, IUniV3Pool, IV2FlashPool} from "../../src/interfaces/IUniV3.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {TestnetAggregator} from "../../src/testnet/TestnetAggregator.sol";

/// @dev The canonical v3 factory and pool calls this suite makes to build its V3 pool.
interface ILoopV3FactorySetup {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface ILoopV3PoolSetup {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @dev An aggregator's router as `loopVia` meets one: it takes the input it is approved for from its caller and sends
///      what it sells from its own stock to a recipient.
contract LoopMockAggregator {
    error Declined();

    function sell(IERC20 tokenIn, uint256 amountIn, IERC20 tokenOut, uint256 amountOut, address to) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(to, amountOut);
    }

    function decline() external pure {
        revert Declined();
    }
}

/// @dev An executor that buys through a V3 pool: an exact-input swap whose callback pays the pool from its caller's
///      approval.
contract LoopMockV3Executor {
    function buy(address pool, bool zeroForOne, uint256 amountIn, address to) external {
        IV2FlashPool(pool)
            .swap(
                to,
                zeroForOne,
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(msg.sender)
            );
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data) external {
        (address token, uint256 owed) = amount0 > 0
            ? (IUniV3Pool(msg.sender).token0(), uint256(amount0))
            : (IUniV3Pool(msg.sender).token1(), uint256(amount1));
        IERC20(token).transferFrom(abi.decode(data, (address)), msg.sender, owed);
    }
}

/// @dev An executor that buys through the PoolManager, which `loopVia`'s V3 flash leaves unlocked: an exact-input swap
///      paid from its caller's approval.
contract LoopMockV4Executor is IUnlockCallback {
    IPoolManager internal immutable PM;

    constructor(IPoolManager pm) {
        PM = pm;
    }

    function buy(PoolKey calldata key, bool zeroForOne, uint256 amountIn, address to) external {
        PM.unlock(abi.encode(msg.sender, key, zeroForOne, amountIn, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) =
            abi.decode(data, (address, PoolKey, bool, uint256, address));
        BalanceDelta d = PM.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        PM.take(output, to, uint128(zeroForOne ? d.amount1() : d.amount0()));
        PM.sync(input);
        IERC20(Currency.unwrap(input)).transferFrom(payer, address(PM), amountIn);
        PM.settle();
        return "";
    }
}

/// @dev A V3 pool or a PoolManager that answers a swap or an unlock by starting the call it is armed with on the router
///      that called it, and bubbles that call's revert.
contract LoopReentry {
    bytes internal _call;

    function arm(bytes calldata data) external {
        _call = data;
    }

    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256) {
        _again();
        return (0, 0);
    }

    function unlock(bytes calldata) external returns (bytes memory) {
        _again();
        return "";
    }

    function _again() internal {
        (bool ok, bytes memory err) = msg.sender.call(_call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}

/// @notice The loop router on the real Intent stack (core, factory, two vaults, verifier, fill router), a real Uniswap v4
/// PoolManager and the canonical Uniswap V3 factory, each holding an NVDA/USDG pool at 100 USDG per NVDA. A borrower with
/// 10 NVDA buys 30 more with USDG the PoolManager fronts (`loop`), the V3 pool waits for (`loopV3`, D242) or a 0.05%
/// USDG/USDC V3 pool lends for an admitted executor's purchase (`loopVia`, D243), borrows against all 40 and repays the
/// purchase from the principal, in one call.
contract LoopRouterTest is IntentPlanBaseTest, V4Fixture {
    IntentFillRouter internal fills;
    LoopRouter internal looper;
    PoolKey internal key;
    /// @dev The bytecode v4-core's own v3/v4 differential tests deploy the canonical v3 factory from.
    string internal constant V3_FACTORY_BYTECODE = "lib/v4-periphery/lib/v4-core/test/bin/v3Factory.bytecode";
    address internal v3Factory;
    address internal v3Pool;
    /// @dev A lender for `loopVia`: the factory's 0.05% USDG/USDC pool.
    MockERC20 internal usdc;
    address internal flashPool;
    LoopMockAggregator internal aggregator;

    address internal user = makeAddr("looper");
    address internal mallory = makeAddr("mallory");
    address internal lp = makeAddr("lp");

    bytes32 internal constant PRICING = keccak256("loop pricing");
    uint256 internal constant OWN = 10e18;
    uint256 internal constant BUY = 30e18;
    uint128 internal constant PRINCIPAL = 3000e6;
    /// @dev 10% over the principal: the fixture's modeled cost, which the vaults' rate-grade floors hold to.
    uint128 internal constant CAP = 3300e6;
    uint256 internal constant MAX_COST = 3100e6;

    function _deployRouter() internal override returns (address) {
        fills = new IntentFillRouter(IntentQuoteVerifier(address(verifier)), IERC20(address(usdg)));
        return address(fills);
    }

    function setUp() public override {
        super.setUp();
        _deployV4();
        // 100 USDG buys one NVDA; about 1,000,000 USDG of depth a side.
        key = _initPoolAtPrice(address(nvda), 1e18, address(usdg), 100e6, address(0));
        nvda.mint(lp, 20_000e18);
        usdg.mint(lp, 2_000_000e6);
        _addRawLiquidity(key, FULL_LOWER, FULL_UPPER, 1e17, lp);

        // The same price and depth on the canonical V3 factory's 0.3% pool.
        bytes memory code = vm.readFileBinary(V3_FACTORY_BYTECODE);
        address factory;
        assembly ("memory-safe") {
            factory := create(0, add(code, 0x20), mload(code))
        }
        assertTrue(factory != address(0), "v3 factory");
        v3Factory = factory;
        v3Pool = ILoopV3FactorySetup(factory).createPool(address(nvda), address(usdg), 3000);
        // 100 USDG (6 decimals) per NVDA (18): a raw price of 1e-10 USDG per NVDA, or 1e10 NVDA per USDG.
        bool usdgFirst = address(usdg) < address(nvda);
        ILoopV3PoolSetup(v3Pool).initialize(usdgFirst ? uint160(uint256(1e5) << 96) : uint160((uint256(1) << 96) / 1e5));
        nvda.mint(address(this), 20_000e18);
        usdg.mint(address(this), 2_000_000e6);
        int24 top = TickMath.MAX_TICK / 60 * 60;
        ILoopV3PoolSetup(v3Pool).mint(address(this), -top, top, 1e17, "");

        // The flash source: about 1,000,000 USDG at one USDC each.
        usdc = new MockERC20("USD Coin", "USDC", 6);
        flashPool = ILoopV3FactorySetup(factory).createPool(address(usdg), address(usdc), 500);
        ILoopV3PoolSetup(flashPool).initialize(uint160(1 << 96));
        usdc.mint(address(this), 2_000_000e6);
        usdg.mint(address(this), 2_000_000e6);
        ILoopV3PoolSetup(flashPool)
            .mint(address(this), -(TickMath.MAX_TICK / 10 * 10), TickMath.MAX_TICK / 10 * 10, 1e12, "");

        looper = new LoopRouter(fills, poolManager, IUniV3Factory(v3Factory), address(this));
        vm.prank(safe);
        registry.setRouter(address(looper), true);
        partnerFactory.setFiller(address(looper), true);

        aggregator = new LoopMockAggregator();
        nvda.mint(address(aggregator), 1000e18);
        looper.setExecutor(address(aggregator), true);

        _wallet(user);
        _wallet(mallory);
    }

    // ---------------------------------------------------------------- fixture

    function _wallet(address who) internal {
        nvda.mint(who, OWN);
        usdg.mint(who, 1000e6);
        vm.startPrank(who);
        nvda.approve(address(looper), type(uint256).max);
        usdg.approve(address(looper), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The loop's own fields; the loan's principal, cap and term are the plan's.
    function _loop(uint256 own, uint256 buy, uint128, uint128) internal view returns (LoopRouter.Loop memory l) {
        l.key = key;
        l.own = own;
        l.buy = buy;
        l.maxCost = MAX_COST;
        l.fundingDeadline = uint40(block.timestamp + 1 days);
        l.withRewards = true;
        l.pricing = PRICING;
    }

    /// @dev The plan an honest signer produces for `borrower`'s loop, ahead of its listing: all four units empty, two
    /// in each vault, the router as filler and the borrower bound through the evidence.
    function _planFor(address borrower, uint256 collateral, uint128 principal, uint128 cap)
        internal
        view
        returns (IntentQuoteVerifier.Plan memory p)
    {
        (IntentVault[] memory vaults, uint8[] memory counts) = _two(2, 2);
        p.engine = address(core);
        p.listingId = core.loanCount() + 1;
        p.filler = address(looper);
        p.token = address(nvda);
        p.kind = uint8(Kind.ERC20);
        p.collateral = collateral;
        p.principal = principal;
        p.cap = cap;
        p.term = T21;
        p.costBps = COST_BPS;
        p.feePolicy = verifier.FEE_POLICY_VERSION();
        p.epoch = verifier.epoch();
        p.issuedAt = uint40(block.timestamp);
        p.expiry = uint40(block.timestamp + 30);
        p.evidence = looper.evidenceFor(borrower, PRICING);
        p.allocations = new IntentQuoteVerifier.Allocation[](vaults.length);
        uint8 next;
        for (uint256 i; i < vaults.length; ++i) {
            IntentQuoteVerifier.Allocation memory al = p.allocations[i];
            al.vault = address(vaults[i]);
            al.units = counts[i];
            uint256 owed;
            for (uint8 left = counts[i]; left != 0; --left) {
                al.principal += uint128(principal / 4 + (next < principal % 4 ? 1 : 0));
                owed += cap / 4 + (next < cap % 4 ? 1 : 0);
                ++next;
            }
            al.interest = uint128(owed - al.principal);
            al.minRateGrade = vaults[i].minRateGrade();
            al.capBps = vaults[i].executionCapBps();
            al.managerBps = vaults[i].feeBps();
            al.minimum = uint128(IntentFeeMath.minimumInterest(al.principal, p.costBps, al.minRateGrade));
            (, uint256 fee) = IntentFeeMath.executionFee(al.interest, al.minimum, al.capBps);
            al.executionFee = uint128(fee);
            al.maxReserveShares = uint128(vaults[i].RESERVE().previewWithdraw(uint256(al.principal) + fee));
        }
    }

    function _shares() internal pure returns (uint256[] memory limits) {
        limits = new uint256[](2);
        limits[0] = type(uint256).max;
        limits[1] = type(uint256).max;
    }

    function _send(address who, LoopRouter.Loop memory l, IntentQuoteVerifier.Plan memory p)
        internal
        returns (uint256 id, uint256 cost)
    {
        bytes memory signature = _sign(p);
        vm.prank(who);
        (id, cost) = looper.loop(l, p, signature, _shares());
    }

    function _expectRevert(address who, LoopRouter.Loop memory l, IntentQuoteVerifier.Plan memory p, bytes memory err)
        internal
    {
        bytes memory signature = _sign(p);
        vm.prank(who);
        vm.expectRevert(err);
        looper.loop(l, p, signature, _shares());
    }

    function _assertRouterEmpty() internal view {
        assertEq(nvda.balanceOf(address(looper)), 0, "router NVDA");
        assertEq(usdg.balanceOf(address(looper)), 0, "router USDG");
    }

    // ---------------------------------------------------------------- the loop

    function test_loop_opensOneLoanOnOwnAndBoughtCollateral() public {
        uint256 usdgBefore = usdg.balanceOf(user);
        uint256 pmUsdg = usdg.balanceOf(address(poolManager));
        (uint256 id, uint256 cost) =
            _send(user, _loop(OWN, BUY, PRINCIPAL, CAP), _planFor(user, OWN + BUY, PRINCIPAL, CAP));

        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active");
        assertEq(l.originator, user, "borrower of record");
        assertEq(core.ownerOf(id), user, "reclaim right");
        assertEq(l.collateral, OWN + BUY, "collateral");
        assertEq(l.principal, PRINCIPAL, "principal");
        assertEq(l.cap, CAP, "cap");
        assertEq(nvda.balanceOf(l.account), OWN + BUY, "escrowed");
        assertEq(nvda.balanceOf(user), 0, "own tokens pledged");

        // 30 NVDA at 100 USDG, plus the 0.3% pool fee and a little impact.
        assertGt(cost, 3000e6, "cost floor");
        assertLt(cost, 3020e6, "cost ceiling");
        assertEq(usdg.balanceOf(user), usdgBefore + PRINCIPAL - l.originationFee - cost, "principal less fee less cost");
        assertEq(core.cashCredit(user), 0, "credit paid out");
        assertEq(usdg.balanceOf(address(poolManager)), pmUsdg + cost, "PoolManager settled");
        assertEq(l.term, T21, "the plan's term");
        _assertRouterEmpty();
    }

    function test_loop_withUSDGAlone() public {
        uint256 usdgBefore = usdg.balanceOf(user);
        (uint256 id, uint256 cost) = _send(user, _loop(0, BUY, PRINCIPAL, CAP), _planFor(user, BUY, PRINCIPAL, CAP));

        V2Loan memory l = core.getLoan(id);
        assertEq(l.collateral, BUY, "collateral is the purchase alone");
        assertEq(nvda.balanceOf(user), OWN, "own tokens untouched");
        assertEq(usdg.balanceOf(user), usdgBefore + PRINCIPAL - l.originationFee - cost, "wallet covers the rest");
        _assertRouterEmpty();
    }

    function test_loop_thenRepayReturnsAllCollateral() public {
        (uint256 id,) = _send(user, _loop(OWN, BUY, PRINCIPAL, CAP), _planFor(user, OWN + BUY, PRINCIPAL, CAP));
        usdg.mint(user, CAP);
        vm.startPrank(user);
        usdg.approve(address(core), CAP);
        core.reclaim(id, user);
        core.withdrawCollateral(id, user);
        vm.stopPrank();
        assertEq(nvda.balanceOf(user), OWN + BUY, "the loop's tokens are the borrower's");
    }

    // ---------------------------------------------------------------- refusals

    function test_loop_revertsWhenAnotherListingTakesTheId() public {
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        _list(borrower, address(nvda), 10e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21);
        uint256 usdgBefore = usdg.balanceOf(user);
        _expectRevert(
            user,
            _loop(OWN, BUY, PRINCIPAL, CAP),
            p,
            abi.encodeWithSelector(LoopRouter.ListingMismatch.selector, p.listingId + 1, p.listingId)
        );
        assertEq(nvda.balanceOf(user), OWN, "nothing pledged");
        assertEq(usdg.balanceOf(user), usdgBefore, "nothing paid");
    }

    function test_loop_refusesAnotherWalletsPlan() public {
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        _expectRevert(
            mallory, _loop(OWN, BUY, PRINCIPAL, CAP), p, abi.encodeWithSelector(LoopRouter.NotBorrowersPlan.selector)
        );
    }

    function test_loop_refusesACostAboveTheBorrowersBound() public {
        LoopRouter.Loop memory l = _loop(OWN, BUY, PRINCIPAL, CAP);
        l.maxCost = 3000e6;
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        bytes memory signature = _sign(p);
        vm.prank(user);
        vm.expectPartialRevert(LoopRouter.TooExpensive.selector);
        looper.loop(l, p, signature, _shares());
    }

    function test_loop_refusesAPlanForOtherCollateral() public {
        _expectRevert(
            user,
            _loop(OWN, BUY, PRINCIPAL, CAP),
            _planFor(user, OWN + BUY + 1, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.CollateralMismatch.selector, OWN + BUY + 1, OWN + BUY)
        );
    }

    /// @dev Any pool pairing USDG with the plan's token, and none with hooks: the pool sets only what the borrower pays.
    function test_loop_refusesAHookedOrForeignPool() public {
        LoopRouter.Loop memory hooked = _loop(OWN, BUY, PRINCIPAL, CAP);
        hooked.key.hooks = IHooks(address(0xBEEF));
        _expectRevert(
            user,
            hooked,
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.InvalidPool.selector)
        );

        LoopRouter.Loop memory foreign = _loop(OWN, BUY, PRINCIPAL, CAP);
        (foreign.key.currency0, foreign.key.currency1) = _sorted(address(meme), address(usdg));
        _expectRevert(
            user,
            foreign,
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.InvalidPool.selector)
        );

        LoopRouter.Loop memory noUsdg = _loop(OWN, BUY, PRINCIPAL, CAP);
        (noUsdg.key.currency0, noUsdg.key.currency1) = _sorted(address(nvda), address(meme));
        _expectRevert(
            user,
            noUsdg,
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.InvalidPool.selector)
        );
    }

    /// @dev The loan's terms are the plan's: the verifier holds the listing to them, so a plan can only fund itself.
    function test_loop_listsThePlansTerms() public {
        uint128 principal = PRINCIPAL - 100e6;
        uint128 cap = principal + principal / 10;
        (uint256 id,) = _send(user, _loop(OWN, BUY, PRINCIPAL, CAP), _planFor(user, OWN + BUY, principal, cap));
        V2Loan memory l = core.getLoan(id);
        assertEq(l.principal, principal, "the plan's principal");
        assertEq(l.cap, cap, "the plan's cap");
    }

    function test_loop_revertsWholeWhenTheBorrowerCannotPay() public {
        vm.prank(user);
        usdg.approve(address(looper), 0);
        uint256 id = core.loanCount() + 1;
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        bytes memory signature = _sign(p);
        LoopRouter.Loop memory l = _loop(OWN, BUY, PRINCIPAL, CAP);
        vm.prank(user);
        vm.expectRevert();
        looper.loop(l, p, signature, _shares());
        assertEq(core.loanCount(), id - 1, "no listing");
        assertEq(nvda.balanceOf(user), OWN, "nothing pledged");
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(LoopRouter.NotPoolManager.selector);
        looper.unlockCallback("");
    }

    // ---------------------------------------------------------------- owner

    /// @dev The owner's one switch: paused, no new loop; loans already open are the core's and are untouched.
    function test_pause_stopsNewLoopsOnly() public {
        (uint256 open,) = _send(user, _loop(OWN, BUY, PRINCIPAL, CAP), _planFor(user, OWN + BUY, PRINCIPAL, CAP));
        looper.pause();
        _expectRevert(
            mallory,
            _loop(OWN, BUY, PRINCIPAL, CAP),
            _planFor(mallory, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        assertEq(uint8(core.getLoan(open).state), uint8(V2State.ACTIVE), "an open loop stands");
        looper.unpause();
        _send(mallory, _loop(OWN, BUY, PRINCIPAL, CAP), _planFor(mallory, OWN + BUY, PRINCIPAL, CAP));
    }

    function test_owner_only() public {
        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        looper.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        looper.unpause();
        vm.stopPrank();
    }

    function test_constructor_refusesAV3FactoryWithoutCode() public {
        vm.expectRevert(LoopRouter.InvalidConfiguration.selector);
        new LoopRouter(fills, poolManager, IUniV3Factory(makeAddr("no factory")), address(this));
    }

    // ---------------------------------------------------------------- the loop through a V3 pool (D242)

    function _loopV3(uint256 own, uint256 buy) internal view returns (LoopRouter.LoopV3 memory l) {
        l.fee = 3000;
        l.own = own;
        l.buy = buy;
        l.maxCost = MAX_COST;
        l.fundingDeadline = uint40(block.timestamp + 1 days);
        l.withRewards = true;
        l.pricing = PRICING;
    }

    function _sendV3(address who, LoopRouter.LoopV3 memory l, IntentQuoteVerifier.Plan memory p)
        internal
        returns (uint256 id, uint256 cost)
    {
        bytes memory signature = _sign(p);
        vm.prank(who);
        (id, cost) = looper.loopV3(l, p, signature, _shares());
    }

    function _expectRevertV3(
        address who,
        LoopRouter.LoopV3 memory l,
        IntentQuoteVerifier.Plan memory p,
        bytes memory err
    ) internal {
        bytes memory signature = _sign(p);
        vm.prank(who);
        vm.expectRevert(err);
        looper.loopV3(l, p, signature, _shares());
    }

    function test_loopV3_opensOneLoanOnOwnAndBoughtCollateral() public {
        uint256 usdgBefore = usdg.balanceOf(user);
        uint256 poolUsdg = usdg.balanceOf(v3Pool);
        uint256 poolNvda = nvda.balanceOf(v3Pool);
        (uint256 id, uint256 cost) = _sendV3(user, _loopV3(OWN, BUY), _planFor(user, OWN + BUY, PRINCIPAL, CAP));

        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active");
        assertEq(l.originator, user, "borrower of record");
        assertEq(core.ownerOf(id), user, "reclaim right");
        assertEq(l.collateral, OWN + BUY, "collateral");
        assertEq(nvda.balanceOf(l.account), OWN + BUY, "escrowed");
        assertEq(nvda.balanceOf(user), 0, "own tokens pledged");

        // 30 NVDA at 100 USDG, plus the 0.3% pool fee and a little impact.
        assertGt(cost, 3000e6, "cost floor");
        assertLt(cost, 3020e6, "cost ceiling");
        assertEq(usdg.balanceOf(user), usdgBefore + PRINCIPAL - l.originationFee - cost, "principal less fee less cost");
        assertEq(usdg.balanceOf(v3Pool), poolUsdg + cost, "the pool is paid what it asked");
        assertEq(nvda.balanceOf(v3Pool), poolNvda - BUY, "the pool sold exactly the purchase");
        _assertRouterEmpty();
    }

    function test_loopV3_withUSDGAlone() public {
        uint256 usdgBefore = usdg.balanceOf(user);
        (uint256 id, uint256 cost) = _sendV3(user, _loopV3(0, BUY), _planFor(user, BUY, PRINCIPAL, CAP));

        V2Loan memory l = core.getLoan(id);
        assertEq(l.collateral, BUY, "collateral is the purchase alone");
        assertEq(nvda.balanceOf(user), OWN, "own tokens untouched");
        assertEq(usdg.balanceOf(user), usdgBefore + PRINCIPAL - l.originationFee - cost, "wallet covers the rest");
        _assertRouterEmpty();
    }

    /// @dev Only the factory's pool for the token, USDG and the fee tier: a tier with no pool is refused before anything
    ///      moves, and so is a plan for USDG itself.
    function test_loopV3_refusesAFeeTierWithNoPool() public {
        LoopRouter.LoopV3 memory l = _loopV3(OWN, BUY);
        l.fee = 500;
        _expectRevertV3(
            user, l, _planFor(user, OWN + BUY, PRINCIPAL, CAP), abi.encodeWithSelector(LoopRouter.InvalidPool.selector)
        );
        assertEq(nvda.balanceOf(user), OWN, "nothing pledged");
    }

    function test_loopV3_refusesACostAboveTheBorrowersBound() public {
        LoopRouter.LoopV3 memory l = _loopV3(OWN, BUY);
        l.maxCost = 3000e6;
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        bytes memory signature = _sign(p);
        vm.prank(user);
        vm.expectPartialRevert(LoopRouter.TooExpensive.selector);
        looper.loopV3(l, p, signature, _shares());
    }

    function test_loopV3_refusesAnotherWalletsPlan() public {
        _expectRevertV3(
            mallory,
            _loopV3(OWN, BUY),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.NotBorrowersPlan.selector)
        );
    }

    function test_loopV3_revertsWhenAnotherListingTakesTheId() public {
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        _list(borrower, address(nvda), 10e18, uint128(REVIEW_PRINCIPAL), uint128(REVIEW_CAP), T21);
        uint256 usdgBefore = usdg.balanceOf(user);
        uint256 poolNvda = nvda.balanceOf(v3Pool);
        _expectRevertV3(
            user,
            _loopV3(OWN, BUY),
            p,
            abi.encodeWithSelector(LoopRouter.ListingMismatch.selector, p.listingId + 1, p.listingId)
        );
        assertEq(nvda.balanceOf(user), OWN, "nothing pledged");
        assertEq(usdg.balanceOf(user), usdgBefore, "nothing paid");
        assertEq(nvda.balanceOf(v3Pool), poolNvda, "nothing bought");
    }

    /// @dev The callback answers the pool `loopV3` is swapping in, once, and nobody else: not an outsider, and not the
    ///      pool itself outside a loop.
    function test_uniswapV3SwapCallback_onlyTheActivePool() public {
        vm.prank(mallory);
        vm.expectRevert(LoopRouter.NotPool.selector);
        looper.uniswapV3SwapCallback(-int256(BUY), int256(1), "");
        vm.prank(v3Pool);
        vm.expectRevert(LoopRouter.NotPool.selector);
        looper.uniswapV3SwapCallback(-int256(BUY), int256(1), "");
    }

    function test_loopV3_pausedLikeLoop() public {
        looper.pause();
        _expectRevertV3(
            user,
            _loopV3(OWN, BUY),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
    }

    // ---------------------------------------------------------------- one loop at a time, whichever pool kind

    /// @dev A pool that answers `loopV3`'s swap by starting a v4 `loop` on the same router meets the lock every entry
    ///      shares, before anything of the inner loop runs.
    function test_loopV3_refusesALoopStartedInsideIt() public {
        LoopReentry pool = new LoopReentry();
        vm.mockCall(
            v3Factory,
            abi.encodeCall(IUniV3Factory.getPool, (address(nvda), address(usdg), 3000)),
            abi.encode(address(pool))
        );
        IntentQuoteVerifier.Plan memory p = _planFor(user, BUY, PRINCIPAL, CAP);
        pool.arm(abi.encodeCall(LoopRouter.loop, (_loop(0, BUY, PRINCIPAL, CAP), p, "", _shares())));
        vm.prank(user);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        looper.loopV3(_loopV3(0, BUY), p, "", _shares());
    }

    /// @dev And the other way round: a PoolManager that answers `loop`'s unlock by starting a `loopV3`.
    function test_loop_refusesALoopV3StartedInsideIt() public {
        LoopReentry manager = new LoopReentry();
        LoopRouter router =
            new LoopRouter(fills, IPoolManager(address(manager)), IUniV3Factory(v3Factory), address(this));
        IntentQuoteVerifier.Plan memory p = _planFor(user, BUY, PRINCIPAL, CAP);
        manager.arm(abi.encodeCall(LoopRouter.loopV3, (_loopV3(0, BUY), p, "", _shares())));
        vm.prank(user);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        router.loop(_loop(0, BUY, PRINCIPAL, CAP), p, "", _shares());
    }

    /// @dev And through an executor: one that answers its call by starting a v4 `loop` meets the same lock.
    function test_loopVia_refusesALoopStartedInsideIt() public {
        LoopReentry executor = new LoopReentry();
        looper.setExecutor(address(executor), true);
        IntentQuoteVerifier.Plan memory p = _planFor(user, BUY, PRINCIPAL, CAP);
        executor.arm(abi.encodeCall(LoopRouter.loop, (_loop(0, BUY, PRINCIPAL, CAP), p, "", _shares())));
        LoopRouter.LoopVia memory lv = _loopVia(0, BUY, 3000e6, 3000e6, BUY);
        lv.executor = address(executor);
        lv.data = abi.encodeCall(LoopReentry.unlock, (""));
        vm.prank(user);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        looper.loopVia(lv, p, "", _shares());
    }

    // ---------------------------------------------------------------- the loop through an admitted executor (D243)

    /// @dev The 0.05% flash pool's fee on `amount`, rounded up as the pool rounds it.
    function _flashFee(uint256 amount) internal pure returns (uint256) {
        return (amount * 500 + 1e6 - 1) / 1e6;
    }

    /// @dev A loop through the suite's aggregator, lent `spend`: it takes `spent` and returns `returned` NVDA.
    function _loopVia(uint256 own, uint256 buy, uint256 spend, uint256 spent, uint256 returned)
        internal
        view
        returns (LoopRouter.LoopVia memory l)
    {
        l.executor = address(aggregator);
        (l.flashToken, l.flashFee) = (address(usdc), 500);
        l.data = abi.encodeCall(
            LoopMockAggregator.sell, (IERC20(address(usdg)), spent, IERC20(address(nvda)), returned, address(looper))
        );
        l.spend = spend;
        l.own = own;
        l.buy = buy;
        l.maxCost = MAX_COST;
        l.fundingDeadline = uint40(block.timestamp + 1 days);
        l.withRewards = true;
        l.pricing = PRICING;
    }

    function _sendVia(address who, LoopRouter.LoopVia memory l, IntentQuoteVerifier.Plan memory p)
        internal
        returns (uint256 id, uint256 cost)
    {
        bytes memory signature = _sign(p);
        vm.prank(who);
        (id, cost) = looper.loopVia(l, p, signature, _shares());
    }

    function _expectRevertVia(
        address who,
        LoopRouter.LoopVia memory l,
        IntentQuoteVerifier.Plan memory p,
        bytes memory err
    ) internal {
        bytes memory signature = _sign(p);
        vm.prank(who);
        vm.expectRevert(err);
        looper.loopVia(l, p, signature, _shares());
    }

    function test_loopVia_opensOneLoanThroughAnAdmittedExecutor() public {
        uint256 usdgBefore = usdg.balanceOf(user);
        uint256 flashBefore = usdg.balanceOf(flashPool);
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        // 3,000 USDG for 30.3 NVDA: 0.3 more than the pledge.
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3000e6, 3000e6, BUY + 3e17);
        bytes memory signature = _sign(p);
        vm.expectEmit(address(looper));
        emit LoopRouter.BoughtVia(p.listingId, address(aggregator), flashPool, 3000e6, _flashFee(3000e6), 3e17);
        vm.prank(user);
        (uint256 id, uint256 cost) = looper.loopVia(lv, p, signature, _shares());

        V2Loan memory l = core.getLoan(id);
        assertEq(uint8(l.state), uint8(V2State.ACTIVE), "active");
        assertEq(l.originator, user, "borrower of record");
        assertEq(core.ownerOf(id), user, "reclaim right");
        assertEq(l.collateral, OWN + BUY, "collateral is the pledge, not the surplus");
        assertEq(nvda.balanceOf(l.account), OWN + BUY, "escrowed");
        assertEq(nvda.balanceOf(user), 3e17, "the surplus is the borrower's");
        assertEq(cost, 3000e6 + _flashFee(3000e6), "spent plus the flash fee");
        assertEq(usdg.balanceOf(user), usdgBefore + PRINCIPAL - l.originationFee - cost, "principal less fee less cost");
        assertEq(usdg.balanceOf(flashPool), flashBefore + _flashFee(3000e6), "the flash repaid with its fee");
        assertEq(usdg.allowance(address(looper), address(aggregator)), 0, "no approval left behind");
        _assertRouterEmpty();
    }

    /// @dev The borrower pays what the executor spent and the fee on what was lent; the rest of the flash goes back
    ///      from the router.
    function test_loopVia_chargesWhatTheExecutorSpent() public {
        uint256 flashBefore = usdg.balanceOf(flashPool);
        (, uint256 cost) =
            _sendVia(user, _loopVia(OWN, BUY, 3000e6, 2900e6, BUY), _planFor(user, OWN + BUY, PRINCIPAL, CAP));
        assertEq(cost, 2900e6 + _flashFee(3000e6), "spent plus the fee on what was lent");
        assertEq(usdg.balanceOf(flashPool), flashBefore + _flashFee(3000e6), "the flash repaid in full");
        _assertRouterEmpty();
    }

    /// @dev The executor may route through Uniswap v4: the V3 flash leaves the PoolManager unlocked.
    function test_loopVia_buysThroughAV4PoolDuringTheFlash() public {
        LoopMockV4Executor v4 = new LoopMockV4Executor(poolManager);
        looper.setExecutor(address(v4), true);
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3050e6, 0, 0);
        lv.executor = address(v4);
        lv.data = abi.encodeCall(LoopMockV4Executor.buy, (key, address(usdg) < address(nvda), 3050e6, address(looper)));
        uint256 pmUsdg = usdg.balanceOf(address(poolManager));
        (uint256 id, uint256 cost) = _sendVia(user, lv, _planFor(user, OWN + BUY, PRINCIPAL, CAP));

        assertEq(core.getLoan(id).collateral, OWN + BUY, "collateral");
        assertEq(cost, 3050e6 + _flashFee(3050e6), "spent plus the flash fee");
        assertEq(usdg.balanceOf(address(poolManager)), pmUsdg + 3050e6, "bought through the v4 pool");
        assertGt(nvda.balanceOf(user), 0, "the surplus is the borrower's");
        _assertRouterEmpty();
    }

    /// @dev The lender is locked while it lends, so a route through it reverts and the app names another: any of the
    ///      factory's pools holding USDG will lend.
    function test_loopVia_lendsFromAPoolTheRouteDoesNotUse() public {
        LoopMockV3Executor v3 = new LoopMockV3Executor();
        looper.setExecutor(address(v3), true);
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3050e6, 0, 0);
        lv.executor = address(v3);
        lv.data =
            abi.encodeCall(LoopMockV3Executor.buy, (v3Pool, address(usdg) < address(nvda), 3050e6, address(looper)));
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);

        (lv.flashToken, lv.flashFee) = (address(nvda), 3000);
        _expectRevertVia(user, lv, p, abi.encodeWithSignature("Error(string)", "LOK"));

        (lv.flashToken, lv.flashFee) = (address(usdc), 500);
        (uint256 id, uint256 cost) = _sendVia(user, lv, p);
        assertEq(core.getLoan(id).collateral, OWN + BUY, "collateral");
        assertEq(cost, 3050e6 + _flashFee(3050e6), "spent plus the flash fee");
        assertGt(nvda.balanceOf(user), 0, "the surplus is the borrower's");
        _assertRouterEmpty();
    }

    function test_loopVia_refusesALenderTheFactoryDoesNotHave() public {
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3000e6, 3000e6, BUY);
        lv.flashFee = 3000;
        _expectRevertVia(
            user, lv, _planFor(user, OWN + BUY, PRINCIPAL, CAP), abi.encodeWithSelector(LoopRouter.InvalidPool.selector)
        );
    }

    function test_loopVia_revertsWhenTheExecutorReturnsTooFew() public {
        uint256 usdgBefore = usdg.balanceOf(user);
        _expectRevertVia(
            user,
            _loopVia(OWN, BUY, 3000e6, 3000e6, BUY - 1),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.PartialPurchase.selector, BUY - 1, BUY)
        );
        assertEq(nvda.balanceOf(user), OWN, "nothing pledged");
        assertEq(usdg.balanceOf(user), usdgBefore, "nothing paid");
    }

    function test_loopVia_refusesACostAboveTheBorrowersBound() public {
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3000e6, 3000e6, BUY);
        lv.maxCost = 3000e6;
        _expectRevertVia(
            user,
            lv,
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.TooExpensive.selector, 3000e6 + _flashFee(3000e6), 3000e6)
        );
    }

    function test_loopVia_refusesAnExecutorNotAdmitted() public {
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3000e6, 3000e6, BUY);
        lv.executor = address(new LoopMockAggregator());
        _expectRevertVia(
            user,
            lv,
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.InvalidExecutor.selector)
        );
        looper.setExecutor(address(aggregator), false);
        _expectRevertVia(
            user,
            _loopVia(OWN, BUY, 3000e6, 3000e6, BUY),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.InvalidExecutor.selector)
        );
    }

    function test_loopVia_bubblesTheExecutorsRevert() public {
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3000e6, 3000e6, BUY);
        lv.data = abi.encodeCall(LoopMockAggregator.decline, ());
        _expectRevertVia(
            user,
            lv,
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopMockAggregator.Declined.selector)
        );
    }

    function test_loopVia_refusesNothingToSpendOrAPlanForUSDG() public {
        _expectRevertVia(
            user,
            _loopVia(OWN, BUY, 0, 0, BUY),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.NothingToBuy.selector)
        );
        IntentQuoteVerifier.Plan memory p = _planFor(user, OWN + BUY, PRINCIPAL, CAP);
        p.token = address(usdg);
        _expectRevertVia(
            user, _loopVia(OWN, BUY, 3000e6, 3000e6, BUY), p, abi.encodeWithSelector(LoopRouter.InvalidPool.selector)
        );
    }

    function test_loopVia_refusesAnotherWalletsPlan() public {
        _expectRevertVia(
            mallory,
            _loopVia(OWN, BUY, 3000e6, 3000e6, BUY),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(LoopRouter.NotBorrowersPlan.selector)
        );
    }

    function test_loopVia_pausedLikeLoop() public {
        looper.pause();
        _expectRevertVia(
            user,
            _loopVia(OWN, BUY, 3000e6, 3000e6, BUY),
            _planFor(user, OWN + BUY, PRINCIPAL, CAP),
            abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
    }

    /// @dev The flash callback answers the flash pool during `loopVia`'s flash only: not an outsider, and not the pool
    ///      itself outside a loop.
    function test_uniswapV3FlashCallback_onlyTheActiveFlash() public {
        vm.prank(mallory);
        vm.expectRevert(LoopRouter.NotPool.selector);
        looper.uniswapV3FlashCallback(0, 0, "");
        vm.prank(flashPool);
        vm.expectRevert(LoopRouter.NotPool.selector);
        looper.uniswapV3FlashCallback(0, 0, "");
    }

    /// @dev Only the owner admits executors, and never a contract the router acts on or holds; dropping needs no check.
    function test_setExecutor_ownerOnlyAndNeverACoreContract() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        looper.setExecutor(address(aggregator), false);

        address[7] memory refused = [
            makeAddr("no code"),
            address(looper),
            address(core),
            address(fills),
            address(usdg),
            address(poolManager),
            v3Factory
        ];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(LoopRouter.InvalidExecutor.selector);
            looper.setExecutor(refused[i], true);
        }

        vm.expectEmit(address(looper));
        emit LoopRouter.ExecutorSet(address(aggregator), false);
        looper.setExecutor(address(aggregator), false);
        assertFalse(looper.executorAllowed(address(aggregator)), "dropped");
        looper.setExecutor(makeAddr("no code"), false);
    }

    // ---------------------------------------------------------------- the testnet stand-in for KyberSwap (D245)

    /// @dev A sale through the stand-in of `amountIn` of `tokenIn` for `tokenOut` (USDG and NVDA), half through the
    ///      suite's V3 pool and half through its v4 pool, paid to `recipient`.
    function _standInSplit(address tokenIn, address tokenOut, uint256 amountIn, uint256 minReturn, address recipient)
        internal
        view
        returns (TestnetAggregator.Swap memory s)
    {
        (s.tokenIn, s.tokenOut, s.amountIn, s.minReturn) = (tokenIn, tokenOut, amountIn, minReturn);
        (s.recipient, s.deadline) = (recipient, block.timestamp);
        s.paths = new TestnetAggregator.Path[](2);
        s.paths[0].amountIn = amountIn / 2;
        s.paths[0].hops = new TestnetAggregator.Hop[](1);
        s.paths[0].hops[0] = TestnetAggregator.Hop(TestnetAggregator.Venue.V3, tokenOut, 3000, 0);
        s.paths[1].amountIn = amountIn - amountIn / 2;
        s.paths[1].hops = new TestnetAggregator.Hop[](1);
        s.paths[1].hops[0] = TestnetAggregator.Hop(TestnetAggregator.Venue.V4, tokenOut, key.fee, key.tickSpacing);
    }

    function _standIn() internal returns (TestnetAggregator standIn) {
        standIn = new TestnetAggregator(poolManager, IUniV3Factory(v3Factory));
        looper.setExecutor(address(standIn), true);
    }

    /// @dev `loopVia` through the stand-in r7 admits on the testnet: USDG to NVDA over a V3 + v4 split.
    function test_loopVia_throughTheTestnetAggregator() public {
        TestnetAggregator standIn = _standIn();
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3050e6, 0, 0);
        lv.executor = address(standIn);
        lv.data = abi.encodeCall(
            TestnetAggregator.swap, (_standInSplit(address(usdg), address(nvda), 3050e6, BUY, address(looper)))
        );
        uint256 flashBefore = usdg.balanceOf(flashPool);
        (uint256 id, uint256 cost) = _sendVia(user, lv, _planFor(user, OWN + BUY, PRINCIPAL, CAP));

        assertEq(core.getLoan(id).collateral, OWN + BUY, "collateral");
        assertEq(cost, 3050e6 + _flashFee(3050e6), "spent plus the flash fee");
        assertGt(nvda.balanceOf(user), 0, "the surplus is the borrower's");
        assertEq(usdg.balanceOf(flashPool), flashBefore + _flashFee(3050e6), "the flash repaid with its fee");
        assertEq(usdg.balanceOf(address(standIn)), 0, "the stand-in holds no USDG");
        assertEq(nvda.balanceOf(address(standIn)), 0, "the stand-in holds no NVDA");
        _assertRouterEmpty();
    }

    /// @dev As with KyberSwap, a stand-in route through the pool that lends reverts: that pool is locked.
    function test_loopVia_standInRouteThroughTheLenderRevertsLOK() public {
        TestnetAggregator standIn = _standIn();
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3050e6, 0, 0);
        lv.executor = address(standIn);
        lv.data = abi.encodeCall(
            TestnetAggregator.swap, (_standInSplit(address(usdg), address(nvda), 3050e6, BUY, address(looper)))
        );
        (lv.flashToken, lv.flashFee) = (address(nvda), 3000);
        _expectRevertVia(
            user, lv, _planFor(user, OWN + BUY, PRINCIPAL, CAP), abi.encodeWithSignature("Error(string)", "LOK")
        );
    }

    /// @dev End to end on the Intent core, both aggregator paths through the stand-in: a loop buys through it, then
    ///      the holder cashes the same loan out through it with `cashOutVia`. The cash-out router reads the core
    ///      registry's V3 factory once, at construction; this fixture's registry names a stand-in factory, so that one
    ///      read is pointed at the suite's real factory.
    function test_standIn_loopThenCashOutTheSameLoan() public {
        TestnetAggregator standIn = _standIn();
        LoopRouter.LoopVia memory lv = _loopVia(OWN, BUY, 3050e6, 0, 0);
        lv.executor = address(standIn);
        lv.data = abi.encodeCall(
            TestnetAggregator.swap, (_standInSplit(address(usdg), address(nvda), 3050e6, BUY, address(looper)))
        );
        (uint256 id,) = _sendVia(user, lv, _planFor(user, OWN + BUY, PRINCIPAL, CAP));

        vm.mockCall(address(core.REGISTRY()), abi.encodeWithSignature("V3_FACTORY()"), abi.encode(v3Factory));
        GageV2CashoutRouter cashout =
            new GageV2CashoutRouter(core, IV2FlashPool(flashPool), poolManager, address(usdc), address(this));
        vm.clearMockedCalls();
        cashout.setExecutor(address(standIn), true);
        vm.prank(user);
        core.approve(address(cashout), id);

        TestnetAggregator.Swap memory s = _standInSplit(address(nvda), address(usdg), OWN + BUY, 1, address(cashout));
        GageV2CashoutRouter.ExitVia memory x = GageV2CashoutRouter.ExitVia({
            loanId: id,
            recipient: user,
            minimumNet: 1,
            maxFinanceFee: _flashFee(CAP),
            deadline: block.timestamp,
            executor: address(standIn),
            data: abi.encodeCall(TestnetAggregator.swap, (s)),
            flashToken: address(usdc),
            flashFee: 500,
            minUsdgOut: CAP + _flashFee(CAP)
        });
        uint256 userBefore = usdg.balanceOf(user);
        vm.prank(user);
        (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net) = cashout.cashOutVia(x);

        assertEq(uint8(core.getLoan(id).state), uint8(V2State.REPAID), "repaid");
        assertGt(gross, 3800e6, "40 NVDA at about 100 USDG");
        assertEq(financeFee, _flashFee(CAP), "the flash fee on the cap");
        assertEq(net + platformFee, gross - CAP - financeFee, "the remainder");
        assertEq(usdg.balanceOf(user), userBefore + net, "the holder paid net");
        assertEq(nvda.balanceOf(address(cashout)), 0, "cash-out router NVDA");
        assertEq(usdg.balanceOf(address(cashout)), 0, "cash-out router USDG");
        assertEq(nvda.balanceOf(address(standIn)), 0, "the stand-in holds no NVDA");
        assertEq(usdg.balanceOf(address(standIn)), 0, "the stand-in holds no USDG");
    }

    // ---------------------------------------------------------------- v3 callbacks of this suite

    /// @notice Pays the suite's own v3 mint.
    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        if (owed0 != 0) IERC20(IUniV3Pool(msg.sender).token0()).transfer(msg.sender, owed0);
        if (owed1 != 0) IERC20(IUniV3Pool(msg.sender).token1()).transfer(msg.sender, owed1);
    }
}
