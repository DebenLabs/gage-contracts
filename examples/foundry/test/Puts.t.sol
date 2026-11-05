// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Puts: the NVDA generation's PutRouter and LoopRouter on a fork of Robinhood Chain mainnet.
//
// A put is a loan of NVDA against USDG: what is repaid is fixed in NVDA, so the position gains as NVDA falls; walking
// away at the end gives up the USDG pledged. It opens through the NVDA generation's LoopRouter and closes or rolls
// through its PutRouter, paying only in USDG. This test reads both routers' wiring, the pools a close may buy through
// and USDG's admission as collateral; then, as a borrower, lists a put-shaped loan of their own (USDG pledged, NVDA
// principal), shows what `close` and `roll` refuse before the loan runs, and sets and cancels a standing roll
// instruction. Opening a put needs a funding plan signed by gage's rates service: the loop reverts at the fill without
// one. When a running put exists, `test_closeARunningPut` closes it as its borrower: a close needs no plan and no
// service, only a pool.
//
// Run from examples/foundry: forge test --match-path test/Puts.t.sol -vv

import {MainnetFork} from "./MainnetFork.sol";
import {console2} from "forge-std/console2.sol";

/// @dev Uniswap v4's PoolKey, with its Currency and IHooks types as addresses.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

// IntentQuoteVerifier.Allocation and IntentQuoteVerifier.Plan, field for field.
struct Allocation {
    address vault;
    uint8 units;
    uint128 principal;
    uint128 interest;
    uint128 minimum;
    uint128 executionFee;
    uint128 maxReserveShares;
    uint8 minRateGrade;
    uint16 capBps;
    uint16 managerBps;
}

struct Plan {
    address engine;
    uint256 listingId;
    address filler;
    address token;
    uint8 kind;
    uint256 collateral;
    uint128 principal;
    uint128 cap;
    uint32 term;
    uint32 costBps;
    uint32 feePolicy;
    uint64 epoch;
    uint40 issuedAt;
    uint40 expiry;
    bytes32 evidence;
    Allocation[] allocations;
}

interface IPutRouter {
    /// @dev `venue`: 0 buys through the hookless v4 pool `key`, 1 through the V3 factory's pool at `v3Fee`.
    struct Swap {
        uint8 venue;
        PoolKey key;
        uint24 v3Fee;
    }

    struct Close {
        uint256 loanId;
        Swap swap;
        uint256 maxSpend;
        uint256 minBack;
        address recipient;
    }

    struct Roll {
        uint256 loanId;
        Swap swap;
        uint256 maxSpend;
        bool withRewards;
        bytes32 pricing;
    }

    struct AutoRoll {
        address borrower;
        uint32 term;
        uint32 window;
        uint8 rollsLeft;
        bool withRewards;
        address executor;
        uint40 until;
        uint128 maxCost;
        uint128 maxSpend;
    }

    function CORE() external view returns (address);
    function FILLS() external view returns (address);
    function FACTORY() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function V3_FACTORY() external view returns (address);
    function USDG() external view returns (address);
    function MAX_WINDOW() external view returns (uint32);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function autoRolls(uint256 loanId)
        external
        view
        returns (
            address borrower,
            uint32 term,
            uint32 window,
            uint8 rollsLeft,
            bool withRewards,
            address executor,
            uint40 until,
            uint128 maxCost,
            uint128 maxSpend
        );
    function close(Close calldata c) external returns (uint256 spent, uint256 returned);
    function roll(
        Roll calldata r,
        Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external returns (uint256 id);
    function rollFor(
        uint256 loanId,
        bytes32 pricing,
        Swap calldata swap,
        Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external returns (uint256 id);
    function setAutoRoll(
        uint256 loanId,
        address executor,
        uint32 term,
        uint32 window,
        uint128 maxCost,
        uint128 maxSpend,
        uint8 rollsLeft,
        bool withRewards,
        uint40 until
    ) external;
    function cancelAutoRoll(uint256 loanId) external;
    function evidenceFor(address borrower, bytes32 pricing) external pure returns (bytes32);
}

interface ILoopRouter {
    struct LoopV3 {
        uint24 fee;
        uint256 own;
        uint256 buy;
        uint256 maxCost;
        uint40 fundingDeadline;
        bool withRewards;
        bytes32 pricing;
    }

    function CORE() external view returns (address);
    function FILLS() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function V3_FACTORY() external view returns (address);
    function USDG() external view returns (address);
    function paused() external view returns (bool);
    function evidenceFor(address borrower, bytes32 pricing) external pure returns (bytes32);
    function loopV3(
        LoopV3 calldata l,
        Plan calldata plan,
        bytes calldata signature,
        uint256[] calldata maxReserveShares
    ) external returns (uint256 id, uint256 cost);
}

interface ICore {
    struct Collateral {
        uint8 kind;
        address token;
        uint256 amountOrTokenId;
    }

    struct V2Loan {
        address originator;
        address account;
        address token;
        address collateralBeneficiary;
        uint8 kind;
        uint8 state;
        uint8 filled;
        uint32 term;
        uint40 fundingDeadline;
        uint40 fundedAt;
        uint40 closedAt;
        uint128 principal;
        uint128 cap;
        uint128 originationFee;
        uint128 borrowerReward;
        uint128 lenderReward;
        uint256 collateral;
        bytes32 exposureKey;
        uint256 exposureAmount;
    }

    function REGISTRY() external view returns (address);
    function USDG() external view returns (address);
    function loanCount() external view returns (uint256);
    function getLoan(uint256 id) external view returns (V2Loan memory);
    function ownerOf(uint256 id) external view returns (address);
    function approve(address to, uint256 id) external;
    function list(
        Collateral calldata c,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint40 fundingDeadline,
        bool withRewards
    ) external returns (uint256 id);
}

interface IRegistry {
    function isRouter(address account) external view returns (bool);
    function feeBps() external view returns (uint16);
    function allowedTerms() external view returns (uint32[] memory);
    function getERC20Config(address token)
        external
        view
        returns (bool allowed, uint8 lane, uint256 minAmount, uint256 maxDealRaw, uint256 maxOpenRaw);
}

interface IFactory {
    function isFiller(address filler) external view returns (bool);
    function quoteSigner() external view returns (address);
}

interface IUniV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PutsTest is MainnetFork {
    uint8 internal constant ACTIVE = 2;
    uint8 internal constant V3 = 1;

    error NotBorrower();
    error NotExecutor();
    error NotActive();
    error InvalidAutoRoll();
    error InvalidRecipient();
    error NotBorrowersPlan();
    error Refused(uint8 reason);

    event AutoRollSet(uint256 indexed loanId, address indexed borrower, IPutRouter.AutoRoll autoRoll);
    event AutoRollCancelled(uint256 indexed loanId, address indexed borrower);

    IPutRouter internal puts;
    ILoopRouter internal loops;
    ICore internal core;
    IRegistry internal registry;
    address internal usdg;
    address internal nvda;

    function setUp() public override {
        super.setUp();
        if (!has("intentV1Assets.NVDA.putRouter") || !has("intentV1Assets.NVDA.loopRouter")) vm.skip(true);
        puts = IPutRouter(addressOf("intentV1Assets.NVDA.putRouter"));
        loops = ILoopRouter(addressOf("intentV1Assets.NVDA.loopRouter"));
        core = ICore(addressOf("intentV1Assets.NVDA.core"));
        registry = IRegistry(core.REGISTRY());
        usdg = addressOf("USDG");
        nvda = addressOf("intentV1Assets.NVDA.lendAsset.token");
    }

    /// @notice Both routers serve the NVDA core, pay in NVDA (the core's cash asset) and are admitted by its registry
    ///         and factory; USDG is admitted as collateral there; the pools a close may buy NVDA through exist.
    function test_wiring() public view {
        address factory = addressOf("intentV1Assets.NVDA.factory");
        assertEq(puts.CORE(), address(core));
        assertEq(puts.FILLS(), addressOf("intentV1Assets.NVDA.fillRouter"));
        assertEq(puts.FACTORY(), factory);
        assertEq(puts.POOL_MANAGER(), addressOf("PoolManager"));
        assertEq(puts.USDG(), nvda, "the put router's cash asset is the lent asset, NVDA");
        assertEq(loops.CORE(), address(core));
        assertEq(loops.FILLS(), addressOf("intentV1Assets.NVDA.fillRouter"));
        assertEq(loops.USDG(), nvda);
        assertEq(loops.V3_FACTORY(), puts.V3_FACTORY());
        assertTrue(registry.isRouter(address(puts)) && registry.isRouter(address(loops)), "entry routers");
        assertTrue(IFactory(factory).isFiller(address(puts)) && IFactory(factory).isFiller(address(loops)), "fillers");

        (bool allowed,, uint256 minAmount, uint256 maxDeal,) = registry.getERC20Config(usdg);
        assertTrue(allowed, "USDG is admitted as collateral on the NVDA core");
        console2.log("USDG pledge: at least", minAmount, "at most", maxDeal);
        console2.log("put router owner", puts.owner(), "paused", puts.paused());

        // V3 venue: the V3 factory's pool of USDG and NVDA at a fee tier.
        address pool = IUniV3Factory(puts.V3_FACTORY()).getPool(usdg, nvda, 500);
        assertTrue(pool != address(0), "a V3 USDG/NVDA pool at 0.05%");
        console2.log("V3 pool at 500", pool);
        // V4 venue: a hookless pool pairing the two, its currencies sorted. The manifest names one.
        PoolKey memory key = _v4Key();
        (address lo, address hi) = usdg < nvda ? (usdg, nvda) : (nvda, usdg);
        assertEq(key.currency0, lo);
        assertEq(key.currency1, hi);
        assertEq(key.hooks, address(0));
    }

    /// @notice A borrower's own put-shaped listing: what `close` and `roll` refuse before it runs, and a standing roll
    ///         instruction set and cancelled.
    function test_listingAndStandingRoll() public {
        (uint256 id, address borrower) = _listPut();
        ICore.V2Loan memory l = core.getLoan(id);
        IPutRouter.Swap memory swap = IPutRouter.Swap(V3, _noKey(), 500);

        // close: only the reclaim-right holder, a real recipient, and a running loan.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotBorrower.selector);
        puts.close(IPutRouter.Close(id, swap, l.collateral, 0, borrower));
        vm.startPrank(borrower);
        core.approve(address(puts), id);
        vm.expectRevert(InvalidRecipient.selector);
        puts.close(IPutRouter.Close(id, swap, l.collateral, 0, address(0)));
        vm.expectRevert(NotActive.selector);
        puts.close(IPutRouter.Close(id, swap, l.collateral, 0, borrower));
        if (!puts.paused()) {
            vm.expectRevert(NotActive.selector);
            puts.roll(IPutRouter.Roll(id, swap, 0, false, bytes32(0)), new Plan[](0), new bytes[](0), new uint256[](0));
        }
        vm.stopPrank();

        // A standing roll: the executor is never zero here (it picks the pool), and each roll spends at most
        // `maxSpend` USDG from the wallet.
        address executor = addressOf("rolloverExecutor");
        uint256 fee = uint256(l.principal) * registry.feeBps() / 10_000;
        uint128 maxCost = uint128(2 * (uint256(l.cap) - l.principal + fee));
        uint32 window = l.term / 8 < 6 hours ? l.term / 8 : 6 hours;
        uint40 until = uint40(block.timestamp + 1 days + 5 * uint256(l.term) + 1 days);
        uint128 maxSpend = 5e6; // 5 USDG, six decimals
        vm.startPrank(borrower);
        vm.expectRevert(InvalidAutoRoll.selector);
        puts.setAutoRoll(id, address(0), l.term, window, maxCost, maxSpend, 4, false, until);
        vm.expectRevert(InvalidAutoRoll.selector);
        puts.setAutoRoll(id, executor, l.term, window, maxCost, 0, 4, false, until);
        IPutRouter.AutoRoll memory want =
            IPutRouter.AutoRoll(borrower, l.term, window, 4, false, executor, until, maxCost, maxSpend);
        vm.expectEmit(address(puts));
        emit AutoRollSet(id, borrower, want);
        puts.setAutoRoll(id, executor, l.term, window, maxCost, maxSpend, 4, false, until);
        vm.stopPrank();
        (address who,,,,, address runner,,, uint128 spend) = puts.autoRolls(id);
        assertEq(who, borrower);
        assertEq(runner, executor);
        assertEq(spend, maxSpend);

        // Only gage's keeper, the executor named, runs it, with plans signed by gage's rates service.
        if (!puts.paused()) {
            vm.prank(makeAddr("stranger"));
            vm.expectRevert(NotExecutor.selector);
            puts.rollFor(id, bytes32(0), swap, new Plan[](0), new bytes[](0), new uint256[](0));
        }
        vm.expectEmit(address(puts));
        emit AutoRollCancelled(id, borrower);
        vm.prank(borrower);
        puts.cancelAutoRoll(id);
        (who,,,,,,,,) = puts.autoRolls(id);
        assertEq(who, address(0));
    }

    /// @notice Opening a put: the plan must be priced for the caller, and signed by gage's rates service. Without that
    ///         signature the loop buys the USDG, lists the loan and reverts at the fill, so nothing moves.
    function test_openNeedsASignedPlan() public {
        if (loops.paused()) vm.skip(true);
        address borrower = makeAddr("borrower");
        bytes32 pricing = keccak256("a pricing commitment from the signer");
        uint32[] memory terms = registry.allowedTerms();
        // A 2x put on 20 USDG of margin: the loan of NVDA buys 20 more USDG, and 40 USDG is pledged.
        uint256 own = 20e6;
        uint256 buy = 20e6;
        Plan memory plan;
        plan.engine = address(core);
        plan.listingId = core.loanCount() + 1;
        plan.filler = address(loops);
        plan.token = usdg;
        plan.kind = 0;
        plan.collateral = own + buy;
        plan.principal = 0.2e18; // NVDA, 18 decimals: enough to buy 20 USDG
        plan.cap = 0.202e18;
        plan.term = terms[0];
        plan.evidence = loops.evidenceFor(makeAddr("someone else"), pricing);
        ILoopRouter.LoopV3 memory l =
            ILoopRouter.LoopV3(500, own, buy, 0.2e18, uint40(block.timestamp + 1 hours), false, pricing);

        // A plan priced and screened for another wallet funds no other.
        vm.prank(borrower);
        vm.expectRevert(NotBorrowersPlan.selector);
        loops.loopV3(l, plan, "", new uint256[](0));

        // Priced for this borrower but not signed by the factory's quote signer: refused at the fill.
        plan.evidence = loops.evidenceFor(borrower, pricing);
        deal(usdg, borrower, own);
        deal(nvda, borrower, 0.2e18);
        vm.startPrank(borrower);
        IERC20(usdg).approve(address(loops), own);
        IERC20(nvda).approve(address(loops), 0.2e18);
        uint8 reason = IFactory(addressOf("intentV1Assets.NVDA.factory")).quoteSigner() == address(0) ? 1 : 2;
        vm.expectRevert(abi.encodeWithSelector(Refused.selector, reason)); // FILLS_CLOSED, or BAD_SIGNATURE
        loops.loopV3(l, plan, "", new uint256[](0));
        vm.stopPrank();
    }

    /// @notice Close a running put as its borrower: the router repays the loan, buys exactly the NVDA repayment back
    ///         with the pledged USDG through a V3 pool, and returns the rest. No plan and no service: only a pool.
    function test_closeARunningPut() public {
        (uint256 id, address borrower) = _runningPut();
        if (id == 0) {
            console2.log("no running put on the NVDA core now");
            vm.skip(true);
        }
        if (puts.paused()) vm.skip(true);
        ICore.V2Loan memory l = core.getLoan(id);
        IPutRouter.Swap memory swap = IPutRouter.Swap(V3, _noKey(), 500);
        uint256 before = IERC20(usdg).balanceOf(borrower);
        vm.startPrank(borrower);
        core.approve(address(puts), id);
        // The pledge bounds what the purchase may spend; a real close sets `maxSpend` near a quote and `minBack` to
        // the least it accepts back.
        try puts.close(IPutRouter.Close(id, swap, l.collateral, 0, borrower)) returns (uint256 spent, uint256 back) {
            assertEq(spent + back, l.collateral);
            assertEq(IERC20(usdg).balanceOf(borrower) - before, back);
            assertEq(core.getLoan(id).state, 3, "REPAID");
            console2.log("closed put", id);
            console2.log("USDG spent", spent, "returned", back);
        } catch (bytes memory reason) {
            // A pledge that cannot buy the repayment back (or a thin pool) cannot close: repay in NVDA instead.
            console2.logBytes(reason);
            vm.skip(true);
        }
        vm.stopPrank();
    }

    /// @dev The manifest's hookless v4 USDG/NVDA pool.
    function _v4Key() internal view returns (PoolKey memory key) {
        key.currency0 = vm.parseJsonAddress(manifest, ".pools.nvdaUsdg.currency0");
        key.currency1 = vm.parseJsonAddress(manifest, ".pools.nvdaUsdg.currency1");
        key.fee = uint24(vm.parseJsonUint(manifest, ".pools.nvdaUsdg.fee"));
        key.tickSpacing = int24(vm.parseJsonInt(manifest, ".pools.nvdaUsdg.tickSpacing"));
        key.hooks = vm.parseJsonAddress(manifest, ".pools.nvdaUsdg.hooks");
    }

    /// @dev A V3 purchase carries a key the router never reads.
    function _noKey() internal pure returns (PoolKey memory) {
        return PoolKey(address(0), address(0), 0, 0, address(0));
    }

    /// @dev A put-shaped listing of the borrower's own: 50 USDG pledged for 0.1 NVDA. It stays funding: only partner
    ///      vaults fund, on gage's plans.
    function _listPut() internal returns (uint256 id, address borrower) {
        borrower = makeAddr("borrower");
        (bool allowed,, uint256 minAmount,,) = registry.getERC20Config(usdg);
        if (!allowed) vm.skip(true);
        uint256 pledge = minAmount > 50e6 ? minAmount : 50e6;
        uint32[] memory terms = registry.allowedTerms();
        deal(usdg, borrower, pledge);
        vm.startPrank(borrower);
        IERC20(usdg).approve(address(core), pledge);
        id = core.list(
            ICore.Collateral(0, usdg, pledge), 0.1e18, 0.101e18, terms[0], uint40(block.timestamp + 1 days), false
        );
        vm.stopPrank();
        assertEq(core.ownerOf(id), borrower);
    }

    /// @dev The newest running loan on the NVDA core pledging USDG, and its reclaim-right holder; zero for none.
    function _runningPut() internal view returns (uint256 id, address borrower) {
        uint256 n = core.loanCount();
        uint256 stop = n > 300 ? n - 300 : 0;
        for (uint256 i = n; i > stop; --i) {
            ICore.V2Loan memory l = core.getLoan(i);
            if (l.state != ACTIVE || l.token != usdg || block.timestamp >= uint256(l.fundedAt) + l.term) continue;
            try core.ownerOf(i) returns (address holder) {
                return (i, holder);
            } catch {}
        }
    }
}
