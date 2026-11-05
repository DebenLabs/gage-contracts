// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Rollover: gage's RolloverRouter on a fork of Robinhood Chain mainnet.
//
// It reads each generation's router (its core, fill router, factory, PoolManager and cash asset, its owner, its pause
// and its admissions), then, as a borrower, approves the router, leaves a standing instruction to roll a loan they hold
// the reclaim right of, reads it back and cancels it. It uses a running (ACTIVE) loan of the USDG generation when one
// exists; when none does, the borrower lists one of their own, which `setAutoRoll` accepts while it is still funding.
// A roll needs funding plans signed by gage's rates service, and a standing roll is run by gage's keeper (the
// manifest's `rolloverExecutor`): the test stops before those steps and shows what the router refuses without them.
//
// Run from examples/foundry: forge test --match-path test/Rollover.t.sol -vv

import {MainnetFork} from "./MainnetFork.sol";
import {console2} from "forge-std/console2.sol";

interface IRolloverRouter {
    struct Roll {
        uint256 loanId;
        uint256 maxTopUp;
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
        uint128 maxTopUp;
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

    function CORE() external view returns (address);
    function FILLS() external view returns (address);
    function FACTORY() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function USDG() external view returns (address);
    function MAX_WINDOW() external view returns (uint32);
    function MAX_PLANS() external view returns (uint256);
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
            uint128 maxTopUp
        );
    function rollableAt(uint256 loanId) external view returns (uint256);
    function evidenceFor(address borrower, bytes32 pricing) external pure returns (bytes32);
    function setAutoRoll(
        uint256 loanId,
        address executor,
        uint32 term,
        uint32 window,
        uint128 maxCost,
        uint128 maxTopUp,
        uint8 rollsLeft,
        bool withRewards,
        uint40 until
    ) external;
    function cancelAutoRoll(uint256 loanId) external;
    function roll(
        Roll calldata r,
        Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external returns (uint256 id);
    function rollFor(
        uint256 loanId,
        bytes32 pricing,
        Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external returns (uint256 id);
    function rescueCollateral(uint256 loanId) external;
}

/// @dev GageV2Vault, the core: the reads and the borrower's own calls used here. `kind` and `state` are enums.
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
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function setApprovalForAll(address operator, bool approved) external;
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
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract RolloverTest is MainnetFork {
    uint8 internal constant ACTIVE = 2;

    error NotBorrower();
    error NotExecutor();
    error NoAutoRoll();
    error InvalidAutoRoll();
    error PlanMismatch();
    error NothingToRescue();

    event AutoRollSet(uint256 indexed loanId, address indexed borrower, IRolloverRouter.AutoRoll autoRoll);
    event AutoRollCancelled(uint256 indexed loanId, address indexed borrower);

    IRolloverRouter internal router;
    ICore internal core;
    address internal executor;

    function setUp() public override {
        super.setUp();
        router = IRolloverRouter(addressOf("intentV1.rolloverRouter"));
        core = ICore(addressOf("intentV1.core"));
        executor = addressOf("rolloverExecutor");
    }

    /// @notice Every generation's router is wired to its own core, fill router and factory, and admitted by both.
    function test_eachGenerationsRouter() public view {
        _checkRouter("intentV1", addressOf("USDG"));
        string[3] memory assets = ["GLD", "NVDA", "HIMS"];
        for (uint256 i; i < assets.length; ++i) {
            string memory g = string.concat("intentV1Assets.", assets[i]);
            // A generation whose entry names no router has none to use from this manifest.
            if (!has(string.concat(g, ".rolloverRouter"))) {
                console2.log("no rolloverRouter in the manifest for", assets[i]);
                continue;
            }
            _checkRouter(g, addressOf(string.concat(g, ".lendAsset.token")));
        }
    }

    function _checkRouter(string memory g, address cash) internal view {
        IRolloverRouter r = IRolloverRouter(addressOf(string.concat(g, ".rolloverRouter")));
        address c = addressOf(string.concat(g, ".core"));
        assertEq(r.CORE(), c, "core");
        assertEq(r.FILLS(), addressOf(string.concat(g, ".fillRouter")), "fill router");
        assertEq(r.FACTORY(), addressOf(string.concat(g, ".factory")), "factory");
        assertEq(r.POOL_MANAGER(), addressOf("PoolManager"), "PoolManager");
        // The cash asset: USDG for the USDG generation, the lent asset for a lend generation.
        assertEq(r.USDG(), cash, "cash asset");
        assertEq(ICore(c).USDG(), cash, "core's cash asset");
        assertEq(r.MAX_WINDOW(), 1 days);
        assertEq(r.MAX_PLANS(), 8);
        // The core lists for it (`listFor`) and the factory lets it fill.
        assertTrue(IRegistry(ICore(c).REGISTRY()).isRouter(address(r)), "entry router");
        assertTrue(IFactory(r.FACTORY()).isFiller(address(r)), "filler");
        console2.log(g, address(r));
        console2.log("  owner", r.owner(), "paused", r.paused());
    }

    /// @notice A borrower leaves a standing instruction, reads it back and cancels it; nobody else can run or end it.
    function test_standingInstruction() public {
        (uint256 id, address borrower, bool active) = _borrowersLoan();
        IRolloverRouter.AutoRoll memory a = _limits(id, borrower, active);
        _approve(id, borrower, a);
        _refusedLimits(id, a);

        // Set it: only gage's keeper (the executor named here) may run it, the same term, at most `maxCost` a roll.
        vm.expectEmit(address(router));
        emit AutoRollSet(id, borrower, a);
        vm.prank(borrower);
        router.setAutoRoll(id, a.executor, a.term, a.window, a.maxCost, a.maxTopUp, a.rollsLeft, a.withRewards, a.until);
        _readBack(id, a, active);

        _refusedRuns(id, borrower);

        // Only the borrower who set it ends it.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotBorrower.selector);
        router.cancelAutoRoll(id);
        vm.expectEmit(address(router));
        emit AutoRollCancelled(id, borrower);
        vm.prank(borrower);
        router.cancelAutoRoll(id);
        (address who,,,,,,,,) = router.autoRolls(id);
        assertEq(who, address(0));
        assertEq(router.rollableAt(id), 0);
        if (!router.paused()) {
            vm.prank(makeAddr("stranger"));
            vm.expectRevert(NoAutoRoll.selector);
            router.rollFor(id, bytes32(0), new IRolloverRouter.Plan[](0), new bytes[](0), new uint256[](0));
        }

        // Collateral only ever reaches this router by a repayment that named it by mistake: none here.
        vm.expectRevert(NothingToRescue.selector);
        router.rescueCollateral(id);
    }

    /// @dev An instruction as gage's app leaves one: the loan's own term, four rolls, the last six hours (at most an
    ///      eighth of the term), a cost ceiling of twice this loan's fixed cost and fee, run by gage's keeper.
    function _limits(uint256 id, address borrower, bool active)
        internal
        view
        returns (IRolloverRouter.AutoRoll memory a)
    {
        ICore.V2Loan memory l = core.getLoan(id);
        uint256 fee = uint256(l.principal) * IRegistry(core.REGISTRY()).feeBps() / 10_000;
        uint128 maxCost = uint128(2 * (uint256(l.cap) - l.principal + fee));
        if (maxCost == 0) maxCost = 1;
        uint256 end = active ? uint256(l.fundedAt) + l.term : block.timestamp + 1 days + l.term;
        a = IRolloverRouter.AutoRoll({
            borrower: borrower,
            term: l.term,
            window: l.term / 8 < 6 hours ? l.term / 8 : 6 hours,
            rollsLeft: 4,
            withRewards: false,
            executor: executor,
            until: uint40(end + 4 * uint256(l.term) + 1 days),
            maxCost: maxCost,
            maxTopUp: maxCost
        });
    }

    /// @dev The approvals a standing roll needs: the reclaim right of every loan it makes, and the cash asset each roll
    ///      takes back, the old loan's whole repayment: at most the first repayment, then principal plus the ceiling.
    function _approve(uint256 id, address borrower, IRolloverRouter.AutoRoll memory a) internal {
        ICore.V2Loan memory l = core.getLoan(id);
        uint256 allowance = uint256(l.cap) + (a.rollsLeft - 1) * (uint256(l.principal) + a.maxCost);
        IERC20 cash = IERC20(router.USDG());
        vm.startPrank(borrower);
        core.setApprovalForAll(address(router), true);
        cash.approve(address(router), allowance);
        vm.stopPrank();
        assertTrue(core.isApprovedForAll(borrower, address(router)));
        assertEq(cash.allowance(borrower, address(router)), allowance);
    }

    /// @dev Limits the router refuses when the instruction is set, and a caller who does not hold the reclaim right.
    function _refusedLimits(uint256 id, IRolloverRouter.AutoRoll memory a) internal {
        ICore.V2Loan memory l = core.getLoan(id);
        uint256 fee = uint256(l.principal) * IRegistry(core.REGISTRY()).feeBps() / 10_000;
        uint32 tooLong = router.MAX_WINDOW() + 1; // read before `expectRevert`, which binds to the next call
        vm.startPrank(a.borrower);
        vm.expectRevert(InvalidAutoRoll.selector); // a window above MAX_WINDOW
        router.setAutoRoll(id, a.executor, a.term, tooLong, a.maxCost, a.maxTopUp, 4, false, a.until);
        if (fee > 1) {
            vm.expectRevert(InvalidAutoRoll.selector); // a ceiling under the origination fee, which no roll can meet
            router.setAutoRoll(id, a.executor, a.term, a.window, uint128(fee - 1), a.maxTopUp, 4, false, a.until);
        }
        vm.expectRevert(InvalidAutoRoll.selector); // a date already past
        router.setAutoRoll(id, a.executor, a.term, a.window, a.maxCost, a.maxTopUp, 4, false, uint40(block.timestamp));
        vm.expectRevert(InvalidAutoRoll.selector); // no rolls
        router.setAutoRoll(id, a.executor, a.term, a.window, a.maxCost, a.maxTopUp, 0, false, a.until);
        vm.stopPrank();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotBorrower.selector);
        router.setAutoRoll(id, a.executor, a.term, a.window, a.maxCost, a.maxTopUp, 4, false, a.until);
    }

    function _readBack(uint256 id, IRolloverRouter.AutoRoll memory a, bool active) internal view {
        (address who, uint32 term,, uint8 left,, address runner, uint40 date, uint128 ceiling,) = router.autoRolls(id);
        assertEq(who, a.borrower);
        assertEq(term, a.term);
        assertEq(left, a.rollsLeft);
        assertEq(runner, a.executor);
        assertEq(date, a.until);
        assertEq(ceiling, a.maxCost);
        // When it may first roll: the last `window` of the term (held to a day and an eighth of the term); zero for a
        // loan that is not running.
        ICore.V2Loan memory l = core.getLoan(id);
        uint256 opens = uint256(l.fundedAt) + l.term - a.window;
        assertEq(router.rollableAt(id), active ? (opens > a.until ? 0 : opens) : 0);
        console2.log("loan", id, active ? "ACTIVE" : "FUNDING (listed by this test)");
        console2.log("rollableAt", router.rollableAt(id));
    }

    /// @dev Anyone but the named executor is refused; the executor's own run and a roll by hand both need plans signed
    ///      by gage's rates service, so both stop here. While the owner pauses the router, both revert `EnforcedPause`.
    function _refusedRuns(uint256 id, address borrower) internal {
        if (router.paused()) return;
        IRolloverRouter.Plan[] memory none = new IRolloverRouter.Plan[](0);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotExecutor.selector);
        router.rollFor(id, bytes32(0), none, new bytes[](0), new uint256[](0));

        // One to eight plans for this router and this borrower, or nothing moves.
        vm.prank(borrower);
        vm.expectRevert(PlanMismatch.selector);
        router.roll(IRolloverRouter.Roll(id, 0, false, bytes32(0)), none, new bytes[](0), new uint256[](0));
        // A plan's evidence commits to the borrower: keccak256(abi.encode(borrower, pricing)).
        bytes32 pricing = keccak256("a pricing commitment from the signer");
        assertEq(router.evidenceFor(borrower, pricing), keccak256(abi.encode(borrower, pricing)));
    }

    /// @dev The newest running loan on the USDG core and its reclaim-right holder; when none runs, a listing of the
    ///      borrower's own, still funding.
    function _borrowersLoan() internal returns (uint256 id, address borrower, bool active) {
        uint256 n = core.loanCount();
        uint256 stop = n > 300 ? n - 300 : 0;
        for (uint256 i = n; i > stop; --i) {
            if (core.getLoan(i).state != ACTIVE) continue;
            try core.ownerOf(i) returns (address holder) {
                if (holder.code.length == 0) return (i, holder, true);
            } catch {}
        }
        // No running loan: list one. NVDA is admitted as collateral on the USDG core; principal and cap are USDG,
        // six decimals.
        borrower = makeAddr("borrower");
        address token = addressOf("intentV1Assets.NVDA.lendAsset.token");
        IRegistry registry = IRegistry(core.REGISTRY());
        (bool allowed,, uint256 minAmount,,) = registry.getERC20Config(token);
        if (!allowed) vm.skip(true);
        uint256 amount = minAmount > 1e18 ? minAmount : 1e18;
        uint32[] memory terms = registry.allowedTerms();
        uint32 term = terms[terms.length - 1];
        deal(token, borrower, amount);
        vm.startPrank(borrower);
        IERC20(token).approve(address(core), amount);
        id = core.list(ICore.Collateral(0, token, amount), 100e6, 101e6, term, uint40(block.timestamp + 1 days), false);
        vm.stopPrank();
        assertEq(core.ownerOf(id), borrower);
    }
}
