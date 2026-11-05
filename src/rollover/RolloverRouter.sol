// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Collateral, Kind} from "../types/Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";
import {GageV2TokenCollateralAccount} from "../v2/GageV2TokenCollateralAccount.sol";
import {IntentFactory} from "../intent/IntentFactory.sol";
import {IntentFillRouter} from "../intent/IntentFillRouter.sol";
import {IntentQuoteVerifier} from "../intent/IntentQuoteVerifier.sol";
import {IntentVault} from "../intent/IntentVault.sol";

/// @title RolloverRouter
/// @notice Roll an active loan into a new one on the same collateral, in one transaction: repay the old loan in full,
///         take its collateral back, list the same collateral for the same borrower and fund all four units with a
///         signed plan. The borrower pays only the difference between the old repayment and the new loan's payout,
///         or keeps what the new payout leaves over. The new loan is an ordinary loan on the core's own terms: priced
///         when it is made, with the core's origination fee, and repaid or walked away from as any other.
/// @dev The PoolManager's flash accounting fronts the old repayment: `take` inside one unlock, repaid by `settle` once
///      the new loan has paid its payout (its principal less the origination fee) to the borrower and the borrower's
///      wallet has paid the repayment back. The old lenders are paid their whole repayment on time, so no claim is
///      delayed and no reclaim is accelerated; the new loan's lenders decide afresh under their own limits. The router
///      is admitted as an entry router by the core's registry and as a filler by the Intent factory, as the loop router
///      is; a signed plan names it as filler and the id the core will issue, and its evidence commits to the borrower,
///      so a plan priced and screened for one wallet rolls no other. A roll carries plans for a few ids in a row, all
///      on the same terms: another listing landing first moves the id, and the plan for the id the core then issues is
///      the one used, so a roll is not stopped by a single listing ahead of it. A borrower rolls their own loan with
///      `roll`. With `setAutoRoll` they leave a standing instruction that the executor they name runs with `rollFor`,
///      inside limits the router checks on chain: only near the end of the loan, always the same principal, never
///      another term, never above their cost ceiling or their top-up limit, with the rewards they chose. The owner can
///      only pause new rolls, `roll` and `rollFor` alike; open loans are the core's and are untouched, but a standing
///      instruction does not run while the router is paused, so if a pause lasts through the rest of a loan's roll
///      window, the loan relying on it reaches its end and, with no grace period, defaults unless its holder repays it.
/// The router holds nothing between calls, and touches audited contracts only through the entry
///      points every entry router, filler and keeper uses.
contract RolloverRouter is Ownable2Step, Pausable, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice A roll the borrower sends themselves; the new loan's principal, cap and term are the signed plans'.
    struct Roll {
        /// @dev The active loan to roll, whose reclaim right the caller holds and has approved this router for.
        uint256 loanId;
        /// @dev The most USDG the roll may draw from the caller's wallet beyond the new loan's payout.
        uint256 maxTopUp;
        bool withRewards;
        /// @dev The signer's pricing commitment; with the borrower it makes the plans' evidence.
        bytes32 pricing;
    }

    /// @notice A standing instruction to roll a loan near its end, set by the holder of its reclaim right.
    /// @dev It holds only while that holder still holds the right, and moves to each new loan it makes. Its amounts are
    ///      in the core's cash asset, `USDG` here: USDG, or a lend generation's lent asset. Its fields are in the order
    ///      that packs them into three storage slots.
    struct AutoRoll {
        /// @dev Who set it; it runs only while they hold the loan's reclaim right.
        address borrower;
        /// @dev Each new loan's term.
        uint32 term;
        /// @dev How long before the end of the loan a roll may run, at most `MAX_WINDOW` and an eighth of the term.
        uint32 window;
        /// @dev How many more rolls it may make.
        uint8 rollsLeft;
        /// @dev Whether each new listing asks for rewards: the borrower's choice, never the executor's.
        bool withRewards;
        /// @dev The only account that may run it; zero lets anyone.
        address executor;
        /// @dev No roll after this time.
        uint40 until;
        /// @dev The most each new loan may cost in total, cap less principal plus origination fee, in USDG: an amount
        ///      the borrower names, held to the unit. Every roll it makes renews the same principal.
        uint128 maxCost;
        /// @dev The most USDG each roll may draw from the borrower's wallet beyond the new loan's payout.
        uint128 maxTopUp;
    }

    /// @dev What the unlock carries into the callback.
    struct Call {
        address borrower;
        uint256 oldId;
        uint128 oldCap;
        uint256 maxTopUp;
        bool withRewards;
        IntentQuoteVerifier.Plan[] plans;
        bytes[] signatures;
        uint256[] maxReserveShares;
    }

    /// @notice The longest window before the end of a loan in which a standing instruction may roll it.
    uint32 public constant MAX_WINDOW = 1 days;
    /// @notice The most plans one roll carries, one per id it may be issued.
    uint256 public constant MAX_PLANS = 8;

    GageV2Vault public immutable CORE;
    IntentFillRouter public immutable FILLS;
    IntentFactory public immutable FACTORY;
    IPoolManager public immutable POOL_MANAGER;
    IERC20 public immutable USDG;

    /// @notice Standing roll instructions, by the loan they roll next.
    mapping(uint256 loanId => AutoRoll) public autoRolls;

    /// @dev Set by a roll for its own unlock only: the one moment the callback answers.
    bool private transient _rolling;

    error InvalidConfiguration();
    error InvalidAutoRoll();
    error NotBorrower();
    error NotExecutor();
    error NoAutoRoll();
    error AutoRollEnded();
    error NotActive();
    error TooEarly(uint256 opensAt);
    error TermMismatch(uint32 planned, uint32 wanted);
    error PrincipalMismatch(uint128 planned, uint128 old);
    error TooExpensive(uint256 cost, uint256 maxCost);
    error TopUpTooHigh(uint256 topUp, uint256 maxTopUp);
    error CollateralMismatch();
    error PlanMismatch();
    error NotBorrowersPlan();
    error NotPoolManager();
    error InexactTransfer(uint256 expected, uint256 received);
    error StrayBalance();
    error ListingMismatch(uint256 listed, uint256 planned);
    error NothingToRescue();

    /// @notice One loan rolled into the next: the repayment the old loan's lenders were paid, the new loan's terms and
    ///         what the borrower's wallet added.
    event Rolled(
        uint256 indexed oldId,
        uint256 indexed newId,
        address indexed borrower,
        address caller,
        uint128 repaid,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint256 topUp
    );
    event AutoRollSet(uint256 indexed loanId, address indexed borrower, AutoRoll autoRoll);
    event AutoRollCancelled(uint256 indexed loanId, address indexed borrower);
    /// @notice A standing instruction moved to the loan its roll made, with the rolls it has left.
    event AutoRollCarried(uint256 indexed fromId, uint256 indexed toId, uint8 rollsLeft);
    /// @notice Collateral of a loan repaid to this router outside a roll, sent to the holder its right had then.
    event CollateralRescued(uint256 indexed loanId, address indexed holder);

    constructor(IntentFillRouter fills, IPoolManager poolManager, address initialOwner) Ownable(initialOwner) {
        if (address(fills).code.length == 0 || address(poolManager).code.length == 0) revert InvalidConfiguration();
        GageV2Vault core = fills.CORE();
        IntentFactory factory = fills.FACTORY();
        if (address(core).code.length == 0 || address(factory).code.length == 0) revert InvalidConfiguration();
        CORE = core;
        FILLS = fills;
        FACTORY = factory;
        POOL_MANAGER = poolManager;
        USDG = core.USDG();
    }

    // ---------------------------------------------------------------- rolls

    /// @notice Roll the caller's active loan into a new one on the same collateral; all of it or none.
    /// @dev The caller holds the loan's reclaim right and has approved this router for it (`approve` or
    ///      `setApprovalForAll` on the core), and approved this router for the old loan's whole repayment in USDG,
    ///      which it takes back after the new loan has paid its payout (principal less the origination fee) to them:
    ///      what the payout does not cover comes from their wallet, at most `r.maxTopUp`. If the id the core issues
    ///      is none of the plans', the call reverts and nothing moves. A standing instruction on the old loan ends
    ///      with it.
    /// @param r The roll: the loan, the most the wallet may add, rewards and the pricing commitment.
    /// @param plans Funding plans signed by the quote signer for this router and the caller, one per id the new listing
    ///        may be issued, all on the same terms; the new loan's terms.
    /// @param signatures The quote signer's signature over each plan, in the same order.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The new loan, active when this returns.
    function roll(
        Roll calldata r,
        IntentQuoteVerifier.Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        if (CORE.ownerOf(r.loanId) != msg.sender) revert NotBorrower();
        address instructed = autoRolls[r.loanId].borrower;
        if (instructed != address(0)) {
            delete autoRolls[r.loanId];
            emit AutoRollCancelled(r.loanId, instructed);
        }
        id = _roll(msg.sender, r.loanId, r.maxTopUp, r.withRewards, r.pricing, plans, signatures, maxReserveShares);
    }

    /// @notice Run the standing instruction on `loanId`: roll it into a new loan inside the borrower's limits.
    /// @dev Only the executor the borrower named (anyone when they named none), only while they still hold the right,
    ///      before `until`, inside the last `window` of the loan, with the term and the rewards they chose, the old
    ///      loan's principal, a total cost within their ceiling and a top-up within their limit. The
    ///      instruction then moves to the new loan with one roll fewer, or ends with its last.
    /// @param loanId The loan to roll, which carries the instruction.
    /// @param pricing The signer's pricing commitment; with the borrower it makes the plans' evidence.
    /// @param plans Funding plans signed by the quote signer for this router and the borrower, one per id the new
    ///        listing may be issued, all on the same terms.
    /// @param signatures The quote signer's signature over each plan, in the same order.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The new loan, active when this returns.
    function rollFor(
        uint256 loanId,
        bytes32 pricing,
        IntentQuoteVerifier.Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        AutoRoll memory a = autoRolls[loanId];
        if (a.borrower == address(0)) revert NoAutoRoll();
        if (a.executor != address(0) && msg.sender != a.executor) revert NotExecutor();
        if (CORE.ownerOf(loanId) != a.borrower) revert NotBorrower();
        if (block.timestamp > a.until || a.rollsLeft == 0) revert AutoRollEnded();
        V2Loan memory old = CORE.getLoan(loanId);
        if (old.state != V2State.ACTIVE) revert NotActive();
        uint256 opensAt = _opensAt(old, a.window);
        if (block.timestamp < opensAt) revert TooEarly(opensAt);
        // Every plan carries the same terms (`_checkPlans`), so the first stands for all.
        if (plans.length != 0 && plans[0].term != a.term) revert TermMismatch(plans[0].term, a.term);
        // The same principal, so the borrower's amount is what each roll of this loan may cost: a smaller one could
        // otherwise spend all of it on less loan.
        if (plans.length != 0 && plans[0].principal != old.principal) {
            revert PrincipalMismatch(plans[0].principal, old.principal);
        }

        id = _roll(a.borrower, loanId, a.maxTopUp, a.withRewards, pricing, plans, signatures, maxReserveShares);

        V2Loan memory made = CORE.getLoan(id);
        uint256 cost = uint256(made.cap) - made.principal + made.originationFee;
        if (cost > a.maxCost) revert TooExpensive(cost, a.maxCost);
        delete autoRolls[loanId];
        if (a.rollsLeft > 1) {
            --a.rollsLeft;
            autoRolls[id] = a;
            emit AutoRollCarried(loanId, id, a.rollsLeft);
        } else {
            emit AutoRollCarried(loanId, id, 0);
        }
    }

    // ---------------------------------------------------------------- standing instructions

    /// @notice Leave a standing instruction to roll `loanId` near its end, or replace the one there.
    /// @dev Only the holder of the loan's reclaim right, for a loan that is funding or active. It runs only while they
    ///      still hold the right, so a sold right carries none. Setting it moves nothing: the roll also needs this
    ///      router's approval for the right (`setApprovalForAll` lets it follow every loan it makes) and for the USDG
    ///      each roll takes back, the old loan's whole repayment.
    /// @param loanId The loan to roll.
    /// @param executor The only account that may run it; zero lets anyone.
    /// @param term Each new loan's term.
    /// @param window How long before the end of the loan a roll may run: from 1 second to `MAX_WINDOW`, and never more
    ///        than an eighth of the loan's term.
    /// @param maxCost The most each new loan may cost in total, its fixed cost and origination fee, in USDG.
    /// @param maxTopUp The most USDG each roll may draw from the wallet beyond the new loan's payout.
    /// @param rollsLeft How many rolls it may make, at least one.
    /// @param withRewards Whether each new listing asks for rewards.
    /// @param until No roll after this time, which must be in the future.
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
    ) external nonReentrant {
        if (CORE.ownerOf(loanId) != msg.sender) revert NotBorrower();
        if (
            term == 0 || window == 0 || window > MAX_WINDOW || maxCost == 0 || rollsLeft == 0
                || until <= block.timestamp
        ) revert InvalidAutoRoll();
        // Limits no roll can meet are refused: a window that opens after `until`, or a cost cap below
        // the origination fee every roll pays on the same principal.
        V2Loan memory l = CORE.getLoan(loanId);
        if (_opensAt(l, window) > until || maxCost < uint256(l.principal) * CORE.REGISTRY().feeBps() / 10_000) {
            revert InvalidAutoRoll();
        }
        AutoRoll memory a = AutoRoll({
            borrower: msg.sender,
            term: term,
            window: window,
            rollsLeft: rollsLeft,
            withRewards: withRewards,
            executor: executor,
            until: until,
            maxCost: maxCost,
            maxTopUp: maxTopUp
        });
        autoRolls[loanId] = a;
        emit AutoRollSet(loanId, msg.sender, a);
    }

    /// @notice End the standing instruction on `loanId`. Only the borrower who set it.
    /// @param loanId The loan whose instruction ends.
    function cancelAutoRoll(uint256 loanId) external nonReentrant {
        if (autoRolls[loanId].borrower != msg.sender) revert NotBorrower();
        delete autoRolls[loanId];
        emit AutoRollCancelled(loanId, msg.sender);
    }

    /// @notice When the standing instruction on `loanId` may first roll it: zero when none could run, because there is
    ///         none, the loan is not active, its right has another holder, its date or its rolls are spent, or its next
    ///         window opens after its date. It does not read the pause: no instruction runs while the router is paused.
    /// @param loanId The loan.
    function rollableAt(uint256 loanId) external view returns (uint256) {
        AutoRoll memory a = autoRolls[loanId];
        if (a.borrower == address(0) || a.rollsLeft == 0 || block.timestamp > a.until) return 0;
        V2Loan memory l = CORE.getLoan(loanId);
        if (l.state != V2State.ACTIVE || CORE.ownerOf(loanId) != a.borrower) return 0;
        uint256 opens = _opensAt(l, a.window);
        return opens > a.until ? 0 : opens;
    }

    /// @notice Send the collateral of a loan repaid to this router outside a roll to the holder its right had when it
    ///         closed. Anyone may call; the collateral only ever goes to that holder.
    /// @dev A roll withdraws the collateral it reclaims in the same transaction, so only a repayment that named this
    ///      router as recipient by mistake leaves any here: without this it could never leave the loan's account.
    /// @param loanId The repaid loan.
    function rescueCollateral(uint256 loanId) external nonReentrant {
        V2Loan memory l = CORE.getLoan(loanId);
        if (
            l.state != V2State.REPAID || l.collateralBeneficiary != address(this)
                || GageV2TokenCollateralAccount(payable(l.account)).released()
        ) revert NothingToRescue();
        address holder = CORE.REWARDS().allocation(loanId).borrower;
        if (holder == address(0)) revert NothingToRescue();
        CORE.withdrawCollateral(loanId, holder);
        emit CollateralRescued(loanId, holder);
    }

    /// @notice Stop new rolls, `roll` and `rollFor` alike; loans already open are the core's and are untouched. A loan
    /// whose holder relies on a standing instruction here is not rolled while paused: if the pause lasts through the
    /// rest of its roll window, the instruction cannot run before the loan's end, and with no grace period the loan
    /// defaults at that end unless its holder repays it.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allow new rolls again.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice The evidence a plan for `borrower` must carry, from the signer's pricing commitment.
    /// @param borrower The wallet the plan was priced and screened for.
    /// @param pricing The signer's pricing commitment.
    function evidenceFor(address borrower, bytes32 pricing) public pure returns (bytes32) {
        return keccak256(abi.encode(borrower, pricing));
    }

    // ---------------------------------------------------------------- the roll

    /// @notice The PoolManager's callback inside a roll: front the old repayment, repay, relist, fund, pay out, settle.
    /// @dev Only the PoolManager may call it, and only inside this router's own roll.
    /// @param data The encoded `Call`.
    /// @return The new loan's id and the USDG the borrower's wallet added, encoded.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_rolling) revert NotPoolManager();
        Call memory c = abi.decode(data, (Call));
        IntentQuoteVerifier.Plan memory terms = c.plans[0];
        Currency cash = Currency.wrap(address(USDG));

        // The old loan's whole repayment, fronted; its lenders are credited on the core and the collateral is ours.
        POOL_MANAGER.take(cash, address(this), c.oldCap);
        USDG.forceApprove(address(CORE), c.oldCap);
        CORE.reclaim(c.oldId, address(this));
        USDG.forceApprove(address(CORE), 0);
        _settleLenders(c.oldId);
        uint256 before = IERC20(terms.token).balanceOf(address(this));
        CORE.withdrawCollateral(c.oldId, address(this));
        uint256 received = IERC20(terms.token).balanceOf(address(this)) - before;
        if (received != terms.collateral) revert InexactTransfer(terms.collateral, received);

        // The same collateral, listed for the borrower and funded by the plan for the id the core issued.
        uint256 id = _listAndFill(c, received);
        V2Loan memory made = CORE.getLoan(id);
        uint256 payout = uint256(made.principal) - made.originationFee;
        uint256 topUp = c.oldCap > payout ? c.oldCap - payout : 0;
        if (topUp > c.maxTopUp) revert TopUpTooHigh(topUp, c.maxTopUp);

        // The payout reaches the borrower, who pays the repayment back: the rest of it from their wallet.
        CORE.withdrawUSDGFor(c.borrower);
        POOL_MANAGER.sync(cash);
        USDG.safeTransferFrom(c.borrower, address(POOL_MANAGER), c.oldCap);
        POOL_MANAGER.settle();
        return abi.encode(id, topUp);
    }

    /// @dev The checks before anything moves, the unlock, and the check that nothing stayed here.
    function _roll(
        address borrower,
        uint256 oldId,
        uint256 maxTopUp,
        bool withRewards,
        bytes32 pricing,
        IntentQuoteVerifier.Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) internal returns (uint256 id) {
        V2Loan memory old = CORE.getLoan(oldId);
        _checkPlans(borrower, pricing, old, plans, signatures);

        IERC20 collateral = IERC20(old.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        _rolling = true;
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(Call(borrower, oldId, old.cap, maxTopUp, withRewards, plans, signatures, maxReserveShares))
        );
        _rolling = false;
        uint256 topUp;
        (id, topUp) = abi.decode(result, (uint256, uint256));
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }
        emit Rolled(oldId, id, borrower, msg.sender, old.cap, plans[0].principal, plans[0].cap, plans[0].term, topUp);
    }

    /// @dev One to `MAX_PLANS` plans for consecutive ids, each priced for `borrower`, each on the old loan's collateral
    ///      to the unit, and all on the same terms, so the listing made before its id is known is every plan's listing.
    function _checkPlans(
        address borrower,
        bytes32 pricing,
        V2Loan memory old,
        IntentQuoteVerifier.Plan[] calldata plans,
        bytes[] calldata signatures
    ) internal view {
        uint256 n = plans.length;
        if (n == 0 || n > MAX_PLANS || signatures.length != n) revert PlanMismatch();
        bytes32 evidence = evidenceFor(borrower, pricing);
        IntentQuoteVerifier.Plan calldata first = plans[0];
        if (
            old.token == address(USDG) || first.token != old.token || first.kind != uint8(Kind.ERC20)
                || first.collateral != old.collateral
        ) revert CollateralMismatch();
        for (uint256 i; i < n; ++i) {
            IntentQuoteVerifier.Plan calldata p = plans[i];
            if (p.evidence != evidence) revert NotBorrowersPlan();
            if (
                p.listingId != first.listingId + i || p.token != first.token || p.kind != first.kind
                    || p.collateral != first.collateral || p.principal != first.principal || p.cap != first.cap
                    || p.term != first.term
            ) revert PlanMismatch();
        }
    }

    /// @dev Book the old loan's repayment in each lending vault, so a vault can lend it again in this very fill.
    ///      `settle` is every keeper's permissionless entry point; a vault that cannot settle now is left for the next
    ///      keeper pass, and the fill then stands on that vault's other liquidity alone.
    function _settleLenders(uint256 oldId) internal {
        address[4] memory lenders = CORE.lenders(oldId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = oldId;
        for (uint256 i; i < 4; ++i) {
            address lender = lenders[i];
            if (lender == address(0) || !FACTORY.isVault(lender)) continue;
            bool seen = false;
            for (uint256 j; j < i; ++j) {
                if (lenders[j] == lender) seen = true;
            }
            if (seen) continue;
            try IntentVault(lender).settle(ids) {} catch {}
        }
    }

    /// @dev List `amount` of the plans' token for the borrower on their terms, then fund all four units with the plan
    ///      for the id the core issued. No plan for that id, and another listing would be funded: none is.
    function _listAndFill(Call memory c, uint256 amount) internal returns (uint256 id) {
        IntentQuoteVerifier.Plan memory terms = c.plans[0];
        IERC20(terms.token).forceApprove(address(CORE), amount);
        // The listing activates in this transaction or not at all, so its funding deadline is the next second.
        id = CORE.listFor(
            Collateral(Kind.ERC20, terms.token, amount),
            terms.principal,
            terms.cap,
            terms.term,
            uint40(block.timestamp + 1),
            c.withRewards,
            c.borrower
        );
        IERC20(terms.token).forceApprove(address(CORE), 0);
        uint256 first = terms.listingId;
        if (id < first || id - first >= c.plans.length) revert ListingMismatch(id, first);
        FILLS.fill(c.plans[id - first], c.signatures[id - first], c.maxReserveShares);
    }

    /// @dev The first second a standing instruction may roll an active loan: the end of its term less the window, the
    ///      window held to `MAX_WINDOW` and to an eighth of the term. Closing a loan early forfeits the rest of its
    ///      quadratic reward curve; at an eighth the most a roll can forfeit is under a quarter (1 - (7/8)^2).
    function _opensAt(V2Loan memory l, uint32 window) internal pure returns (uint256) {
        uint256 w = window;
        if (w > MAX_WINDOW) w = MAX_WINDOW;
        if (w > l.term / 8) w = l.term / 8;
        return uint256(l.fundedAt) + l.term - w;
    }
}
