// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Collateral, Kind} from "../types/Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";
import {GageV2TokenCollateralAccount} from "../v2/GageV2TokenCollateralAccount.sol";
import {IntentFactory} from "../intent/IntentFactory.sol";
import {IntentFillRouter} from "../intent/IntentFillRouter.sol";
import {IntentQuoteVerifier} from "../intent/IntentQuoteVerifier.sol";
import {IntentVault} from "../intent/IntentVault.sol";
import {IUniV3Factory, IV2FlashPool} from "../interfaces/IUniV3.sol";

/// @title PutRouter
/// @notice Close or roll a loan paying only in its own collateral token, so a borrower never has to hold the lent asset.
///         Built for puts, a lend generation's asset (NVDA) lent against USDG and opened through that generation's loop
///         router, it serves any token collateral on the core. `close` repays the loan out of its own collateral: it
///         buys back exactly the repayment and returns the rest of the collateral. `roll` renews the loan on the same
///         collateral as the rollover router does, and buys the part of the old repayment the new payout does not cover
///         with the collateral token from the borrower's wallet. A standing instruction lets an executor the borrower
///         names roll for them, inside limits the router checks on chain.
/// @dev The PoolManager's flash accounting fronts the old repayment: `take` inside one unlock, repaid in the same unlock
///      by a swap (a hookless v4 pool netted in the same accounting, or the V3 factory's pool paid from this router) and,
///      in a roll, by the new loan's payout. The old lenders are paid their whole repayment on time, so no claim is
///      delayed and no reclaim is accelerated. Rolls follow `RolloverRouter`: the router is admitted as an entry router
///      by the core's registry and as a filler by the Intent factory; a signed plan names it as filler and the id the
///      core will issue, its evidence commits to the borrower, and a roll carries plans for a few ids in a row on the
///      same terms. The pool a call names sets only what the borrower pays, which their own limits bound (`maxSpend`,
///      `minBack`), never the loan the vaults fund. The owner can only pause rolls, `roll` and `rollFor` alike: a
///      close always runs, repayments and settlements on the core go on, and no open loan changes. A pause is not
///      harmless to a borrower relying on a standing instruction: one that cannot run while the router is paused lets
///      the loan reach its end, and with no grace period it defaults like any other unless its holder closes or
///      repays it. The router holds nothing between calls, and touches
///      audited contracts only through the entry points every entry router, filler and keeper uses.
contract PutRouter is Ownable2Step, Pausable, ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice Where the lent asset is bought with the collateral token.
    enum Venue {
        V4,
        V3
    }

    /// @notice A purchase of the lent asset, exact output, paid in the loan's collateral token.
    struct Swap {
        Venue venue;
        /// @dev `V4`: a hookless pool pairing the core's cash asset with the loan's collateral token.
        PoolKey key;
        /// @dev `V3`: the fee tier of the V3 factory's pool of the two.
        uint24 v3Fee;
    }

    /// @notice A close the borrower sends: repay the loan out of its collateral, the rest to `recipient`.
    struct Close {
        /// @dev The active loan, whose reclaim right the caller holds and has approved this router for.
        uint256 loanId;
        Swap swap;
        /// @dev The most collateral buying back the repayment may spend.
        uint256 maxSpend;
        /// @dev The least collateral that must come back.
        uint256 minBack;
        address recipient;
    }

    /// @notice A roll the borrower sends themselves; the new loan's principal, cap and term are the signed plans'.
    struct Roll {
        /// @dev The active loan to roll, whose reclaim right the caller holds and has approved this router for.
        uint256 loanId;
        Swap swap;
        /// @dev The most collateral token the roll may draw from the caller's wallet to buy what the payout leaves short.
        uint256 maxSpend;
        bool withRewards;
        /// @dev The signer's pricing commitment; with the borrower it makes the plans' evidence.
        bytes32 pricing;
    }

    /// @notice A standing instruction to roll a loan near its end, set by the holder of its reclaim right.
    /// @dev It holds only while that holder still holds the right, and moves to each new loan it makes. `maxCost` is in
    ///      the core's cash asset, `maxSpend` in the loan's collateral token. Fields pack into three storage slots.
    struct AutoRoll {
        address borrower;
        uint32 term;
        uint32 window;
        uint8 rollsLeft;
        bool withRewards;
        /// @dev The only account that may run it, never zero.
        address executor;
        uint40 until;
        /// @dev The most each new loan may cost in total, cap less principal plus origination fee, in the cash asset.
        uint128 maxCost;
        /// @dev The most collateral token each roll may draw from the borrower's wallet.
        uint128 maxSpend;
    }

    enum Action {
        CLOSE,
        ROLL
    }

    /// @dev What the unlock carries into the callback.
    struct Call {
        Action action;
        address borrower;
        uint256 loanId;
        uint128 cap;
        address collateral;
        uint256 amount;
        Swap swap;
        uint256 maxSpend;
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
    /// @notice The Uniswap V3 factory whose pools a `V3` purchase swaps in.
    IUniV3Factory public immutable V3_FACTORY;
    /// @notice The core's cash asset: USDG, or a lend generation's lent asset (NVDA for the NVDA generation).
    IERC20 public immutable USDG;

    /// @notice Standing roll instructions, by the loan they roll next.
    mapping(uint256 loanId => AutoRoll) public autoRolls;

    /// @dev Set by a close or a roll for its own unlock only: the one moment the unlock callback answers.
    bool private transient _unlocking;
    /// @dev The V3 pool a purchase swaps in, for that swap only, and what its callback may draw and from whom.
    address private transient _activeV3;
    address private transient _v3Payer;
    uint256 private transient _v3MaxSpend;
    uint256 private transient _v3Spent;

    error InvalidConfiguration();
    error InvalidAutoRoll();
    error InvalidSwap();
    error InvalidRecipient();
    error NotBorrower();
    error NotExecutor();
    error NoAutoRoll();
    error AutoRollEnded();
    error NotActive();
    error TooEarly(uint256 opensAt);
    error TermMismatch(uint32 planned, uint32 wanted);
    error PrincipalMismatch(uint128 planned, uint128 old);
    error CostTooHigh(uint256 cost, uint256 maxCost);
    error SpendTooHigh(uint256 spent, uint256 maxSpend);
    error ReturnTooLow(uint256 returned, uint256 minBack);
    error PartialPurchase(uint256 bought, uint256 wanted);
    error CollateralMismatch();
    error PlanMismatch();
    error NotBorrowersPlan();
    error NotPoolManager();
    error NotPool();
    error InexactTransfer(uint256 expected, uint256 received);
    error StrayBalance();
    error ListingMismatch(uint256 listed, uint256 planned);
    error NothingToRescue();

    /// @notice A loan repaid out of its own collateral: the repayment its lenders were paid, the collateral that bought
    ///         it back and the collateral returned.
    event Closed(
        uint256 indexed loanId,
        address indexed borrower,
        address recipient,
        uint128 repaid,
        uint256 spent,
        uint256 returned
    );
    /// @notice One loan rolled into the next: the old repayment, the new loan's terms, the part of the repayment bought
    ///         with the borrower's collateral token and what that purchase cost them.
    event Rolled(
        uint256 indexed oldId,
        uint256 indexed newId,
        address indexed borrower,
        address caller,
        uint128 repaid,
        uint128 principal,
        uint128 cap,
        uint32 term,
        uint256 topUp,
        uint256 spent
    );
    event AutoRollSet(uint256 indexed loanId, address indexed borrower, AutoRoll autoRoll);
    event AutoRollCancelled(uint256 indexed loanId, address indexed borrower);
    /// @notice A standing instruction moved to the loan its roll made, with the rolls it has left.
    event AutoRollCarried(uint256 indexed fromId, uint256 indexed toId, uint8 rollsLeft);
    /// @notice Collateral of a loan repaid to this router outside its own calls, sent to the holder its right had then.
    event CollateralRescued(uint256 indexed loanId, address indexed holder);

    constructor(IntentFillRouter fills, IPoolManager poolManager, IUniV3Factory v3Factory, address initialOwner)
        Ownable(initialOwner)
    {
        if (
            address(fills).code.length == 0 || address(poolManager).code.length == 0
                || address(v3Factory).code.length == 0
        ) revert InvalidConfiguration();
        GageV2Vault core = fills.CORE();
        IntentFactory factory = fills.FACTORY();
        if (address(core).code.length == 0 || address(factory).code.length == 0) revert InvalidConfiguration();
        CORE = core;
        FILLS = fills;
        FACTORY = factory;
        POOL_MANAGER = poolManager;
        V3_FACTORY = v3Factory;
        USDG = core.USDG();
    }

    // ---------------------------------------------------------------- close

    /// @notice Repay the caller's active loan out of its own collateral and send what is left of it to `c.recipient`;
    ///         all of it or none.
    /// @dev The caller holds the loan's reclaim right and has approved this router for it (`approve` or
    ///      `setApprovalForAll` on the core). The repayment is fronted, the loan repaid and its collateral taken back,
    ///      exactly the repayment bought back with that collateral through `c.swap`, at most `c.maxSpend` of it, and at
    ///      least `c.minBack` returned. A loan the collateral cannot buy back reverts: its borrower walks away instead.
    ///      A standing instruction on the loan ends with it. Never paused: with no grace period, a holder who cannot
    ///      close by the end defaults.
    /// @param c The close: the loan, the pool, the most it may spend, the least it must return and the recipient.
    /// @return spent The collateral that bought back the repayment.
    /// @return returned The collateral sent to the recipient.
    function close(Close calldata c) external nonReentrant returns (uint256 spent, uint256 returned) {
        if (CORE.ownerOf(c.loanId) != msg.sender) revert NotBorrower();
        if (c.recipient == address(0) || c.recipient == address(this)) revert InvalidRecipient();
        V2Loan memory l = CORE.getLoan(c.loanId);
        if (l.state != V2State.ACTIVE) revert NotActive();
        if (l.token == address(USDG)) revert CollateralMismatch();
        _checkSwap(c.swap, l.token);
        _endInstruction(c.loanId);

        IERC20 collateral = IERC20(l.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        bytes memory result = _unlock(
            Call(
                Action.CLOSE,
                msg.sender,
                c.loanId,
                l.cap,
                l.token,
                l.collateral,
                c.swap,
                c.maxSpend,
                false,
                new IntentQuoteVerifier.Plan[](0),
                new bytes[](0),
                new uint256[](0)
            )
        );
        (, spent,) = abi.decode(result, (uint256, uint256, uint256));
        returned = l.collateral - spent;
        if (returned < c.minBack) revert ReturnTooLow(returned, c.minBack);
        if (returned != 0) collateral.safeTransfer(c.recipient, returned);
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }
        emit Closed(c.loanId, msg.sender, c.recipient, l.cap, spent, returned);
    }

    // ---------------------------------------------------------------- rolls

    /// @notice Roll the caller's active loan into a new one on the same collateral; all of it or none.
    /// @dev The caller holds the loan's reclaim right and has approved this router for it, for the new loan's payout in
    ///      the cash asset (which it takes back towards the old repayment), and for the collateral token it buys the rest
    ///      with, at most `r.maxSpend`. A payout above the old repayment leaves the excess with the caller. If the id the
    ///      core issues is none of the plans', the call reverts and nothing moves. A standing instruction on the old
    ///      loan ends with it.
    /// @param r The roll: the loan, the pool, the most the wallet may spend, rewards and the pricing commitment.
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
        _endInstruction(r.loanId);
        id = _roll(
            msg.sender, r.loanId, r.swap, r.maxSpend, r.withRewards, r.pricing, plans, signatures, maxReserveShares
        );
    }

    /// @notice Run the standing instruction on `loanId`: roll it into a new loan inside the borrower's limits.
    /// @dev Only the executor the borrower named, only while they still hold the right, before `until`, inside the
    ///      last `window` of the loan, with the term and the rewards they chose, the old loan's principal, a total cost
    ///      within their ceiling and a wallet spend within their limit. The instruction then moves to the new loan with
    ///      one roll fewer, or ends with its last.
    /// @param loanId The loan to roll, which carries the instruction.
    /// @param pricing The signer's pricing commitment; with the borrower it makes the plans' evidence.
    /// @param swap The pool the top-up is bought through; the borrower's `maxSpend` bounds what it may cost them.
    /// @param plans Funding plans signed by the quote signer for this router and the borrower, one per id the new
    ///        listing may be issued, all on the same terms.
    /// @param signatures The quote signer's signature over each plan, in the same order.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The new loan, active when this returns.
    function rollFor(
        uint256 loanId,
        bytes32 pricing,
        Swap calldata swap,
        IntentQuoteVerifier.Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) external nonReentrant whenNotPaused returns (uint256 id) {
        AutoRoll memory a = autoRolls[loanId];
        if (a.borrower == address(0)) revert NoAutoRoll();
        if (msg.sender != a.executor) revert NotExecutor();
        if (CORE.ownerOf(loanId) != a.borrower) revert NotBorrower();
        if (block.timestamp > a.until || a.rollsLeft == 0) revert AutoRollEnded();
        V2Loan memory old = CORE.getLoan(loanId);
        if (old.state != V2State.ACTIVE) revert NotActive();
        uint256 opensAt = _opensAt(old, a.window);
        if (block.timestamp < opensAt) revert TooEarly(opensAt);
        // Every plan carries the same terms (`_checkPlans`), so the first stands for all.
        if (plans.length != 0 && plans[0].term != a.term) revert TermMismatch(plans[0].term, a.term);
        // The same principal, so the borrower's ceiling is what each roll of this loan may cost.
        if (plans.length != 0 && plans[0].principal != old.principal) {
            revert PrincipalMismatch(plans[0].principal, old.principal);
        }

        id = _roll(a.borrower, loanId, swap, a.maxSpend, a.withRewards, pricing, plans, signatures, maxReserveShares);

        V2Loan memory made = CORE.getLoan(id);
        uint256 cost = uint256(made.cap) - made.principal + made.originationFee;
        if (cost > a.maxCost) revert CostTooHigh(cost, a.maxCost);
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
    /// @dev Only the holder of the loan's reclaim right. It runs only while they still hold the right, so a sold right
    ///      carries none. Setting it moves nothing: each roll also needs this router's approval for the right
    ///      (`setApprovalForAll` lets it follow every loan it makes), for the payout in the cash asset and for the
    ///      collateral token it spends.
    /// @param loanId The loan to roll.
    /// @param executor The only account that may run it, never zero: whoever rolls chooses the pool the top-up is
    ///        bought through and the plan, inside the borrower's limits.
    /// @param term Each new loan's term.
    /// @param window How long before the end of the loan a roll may run: from 1 second to `MAX_WINDOW`, and never more
    ///        than an eighth of the loan's term.
    /// @param maxCost The most each new loan may cost in total, its fixed cost and origination fee, in the cash asset.
    /// @param maxSpend The most collateral token each roll may draw from the wallet.
    /// @param rollsLeft How many rolls it may make, at least one.
    /// @param withRewards Whether each new listing asks for rewards.
    /// @param until No roll after this time, which must be in the future.
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
    ) external nonReentrant {
        if (CORE.ownerOf(loanId) != msg.sender) revert NotBorrower();
        if (
            executor == address(0) || term == 0 || window == 0 || window > MAX_WINDOW || maxCost == 0 || rollsLeft == 0
                || until <= block.timestamp || maxSpend == 0
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
            maxSpend: maxSpend
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

    /// @notice Send the collateral of a loan repaid to this router outside its own calls to the holder its right had
    ///         when it closed. Anyone may call; the collateral only ever goes to that holder.
    /// @dev A close or a roll withdraws the collateral it reclaims in the same transaction, so only a repayment that
    ///      named this router as recipient by mistake leaves any here.
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

    /// @notice Stop rolls through this router, `roll` and `rollFor` alike. Closes go on, and every loan stays repayable
    /// on the core directly; but a loan whose holder relies on a standing instruction here is not rolled while paused:
    /// if the pause lasts through the rest of its roll window, the instruction cannot run before the loan's end, and
    /// with no grace period the loan defaults at that end unless its holder closes or repays it.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Allow rolls again.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice The evidence a plan for `borrower` must carry, from the signer's pricing commitment.
    /// @param borrower The wallet the plan was priced and screened for.
    /// @param pricing The signer's pricing commitment.
    function evidenceFor(address borrower, bytes32 pricing) public pure returns (bytes32) {
        return keccak256(abi.encode(borrower, pricing));
    }

    // ---------------------------------------------------------------- callbacks

    /// @notice The PoolManager's callback inside a close or a roll: front the repayment, repay, then buy it back with
    ///         the collateral (close) or relist, fund, take the payout back and buy the rest with the wallet's
    ///         collateral token (roll).
    /// @dev Only the PoolManager may call it, and only inside this router's own close or roll.
    /// @param data The encoded `Call`.
    /// @return The new loan's id (zero for a close), the collateral spent and the cash it bought, encoded.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER) || !_unlocking) revert NotPoolManager();
        Call memory c = abi.decode(data, (Call));
        Currency cash = Currency.wrap(address(USDG));

        // The old loan's whole repayment, fronted; its lenders are credited on the core and the collateral is ours.
        POOL_MANAGER.take(cash, address(this), c.cap);
        USDG.forceApprove(address(CORE), c.cap);
        CORE.reclaim(c.loanId, address(this));
        USDG.forceApprove(address(CORE), 0);
        _settleLenders(c.loanId);
        uint256 before = IERC20(c.collateral).balanceOf(address(this));
        CORE.withdrawCollateral(c.loanId, address(this));
        uint256 received = IERC20(c.collateral).balanceOf(address(this)) - before;
        if (received != c.amount) revert InexactTransfer(c.amount, received);

        if (c.action == Action.CLOSE) {
            // Exactly the repayment, bought back with the collateral itself: never more of it than the loan held.
            uint256 most = c.maxSpend < received ? c.maxSpend : received;
            uint256 spent = _buyCash(c.swap, c.collateral, c.cap, most, address(this));
            return abi.encode(uint256(0), spent, uint256(c.cap));
        }

        // The same collateral, listed for the borrower and funded by the plan for the id the core issued.
        uint256 id = _listAndFill(c, received);
        V2Loan memory made = CORE.getLoan(id);
        uint256 payout = uint256(made.principal) - made.originationFee;
        uint256 fromPayout = payout < c.cap ? payout : c.cap;
        uint256 topUp = c.cap - fromPayout;

        // The payout reaches the borrower and comes back towards the repayment; the rest is bought with their
        // collateral token. A payout above the repayment leaves the excess with them.
        CORE.withdrawUSDGFor(c.borrower);
        POOL_MANAGER.sync(cash);
        USDG.safeTransferFrom(c.borrower, address(POOL_MANAGER), fromPayout);
        POOL_MANAGER.settle();
        uint256 spentFromWallet;
        if (topUp != 0) spentFromWallet = _buyCash(c.swap, c.collateral, topUp, c.maxSpend, c.borrower);
        return abi.encode(id, spentFromWallet, topUp);
    }

    /// @notice The V3 pool's callback inside a purchase: pay the pool the collateral it is owed.
    /// @dev Only the pool a purchase is swapping in may call it, once: outside that swap no caller is answered.
    /// @param amount0Delta The pool's token0 owed to it (positive) or sent from it (negative).
    /// @param amount1Delta The pool's token1 owed to it (positive) or sent from it (negative).
    /// @param data The encoded collateral token.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activeV3) revert NotPool();
        _activeV3 = address(0);
        address collateral = abi.decode(data, (address));
        int256 owed = collateral < address(USDG) ? amount0Delta : amount1Delta;
        uint256 spent = owed > 0 ? uint256(owed) : 0;
        if (spent > _v3MaxSpend) revert SpendTooHigh(spent, _v3MaxSpend);
        _v3Spent = spent;
        address payer = _v3Payer;
        if (payer == address(this)) IERC20(collateral).safeTransfer(msg.sender, spent);
        else IERC20(collateral).safeTransferFrom(payer, msg.sender, spent);
    }

    // ---------------------------------------------------------------- internals

    /// @dev The checks a roll makes before anything moves, the unlock, and the check that nothing stayed here.
    function _roll(
        address borrower,
        uint256 oldId,
        Swap calldata swap,
        uint256 maxSpend,
        bool withRewards,
        bytes32 pricing,
        IntentQuoteVerifier.Plan[] calldata plans,
        bytes[] calldata signatures,
        uint256[] calldata maxReserveShares
    ) internal returns (uint256 id) {
        V2Loan memory old = CORE.getLoan(oldId);
        if (old.state != V2State.ACTIVE) revert NotActive();
        _checkPlans(borrower, pricing, old, plans, signatures);
        _checkSwap(swap, old.token);

        IERC20 collateral = IERC20(old.token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        bytes memory result = _unlock(
            Call(
                Action.ROLL,
                borrower,
                oldId,
                old.cap,
                old.token,
                old.collateral,
                swap,
                maxSpend,
                withRewards,
                plans,
                signatures,
                maxReserveShares
            )
        );
        (uint256 made, uint256 spent, uint256 topUp) = abi.decode(result, (uint256, uint256, uint256));
        id = made;
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }
        emit Rolled(
            oldId, id, borrower, msg.sender, old.cap, plans[0].principal, plans[0].cap, plans[0].term, topUp, spent
        );
    }

    /// @dev One unlock, answered by `unlockCallback` alone.
    function _unlock(Call memory c) internal returns (bytes memory result) {
        _unlocking = true;
        result = POOL_MANAGER.unlock(abi.encode(c));
        _unlocking = false;
    }

    /// @dev Buy exactly `amount` of the cash asset with `collateral`, at most `maxSpend` of it, paid by `payer` (this
    ///      router or the borrower), and leave the PoolManager whole for that amount of cash: a v4 purchase nets against
    ///      the fronted repayment in the same accounting, a V3 purchase delivers the cash here and it is settled.
    function _buyCash(Swap memory s, address collateral, uint256 amount, uint256 maxSpend, address payer)
        internal
        returns (uint256 spent)
    {
        if (amount > uint256(type(int256).max)) revert InvalidSwap();
        bool collateralIsZero = collateral < address(USDG);
        if (s.venue == Venue.V4) {
            BalanceDelta delta = POOL_MANAGER.swap(
                s.key,
                SwapParams({
                    zeroForOne: collateralIsZero,
                    amountSpecified: int256(amount),
                    sqrtPriceLimitX96: collateralIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 paid = collateralIsZero ? delta.amount0() : delta.amount1();
            int128 got = collateralIsZero ? delta.amount1() : delta.amount0();
            if (got < 0 || uint256(uint128(got)) != amount) {
                revert PartialPurchase(got < 0 ? 0 : uint128(got), amount);
            }
            spent = paid < 0 ? uint256(uint128(-paid)) : 0;
            if (spent > maxSpend) revert SpendTooHigh(spent, maxSpend);
            Currency token = Currency.wrap(collateral);
            POOL_MANAGER.sync(token);
            if (payer == address(this)) IERC20(collateral).safeTransfer(address(POOL_MANAGER), spent);
            else IERC20(collateral).safeTransferFrom(payer, address(POOL_MANAGER), spent);
            POOL_MANAGER.settle();
        } else {
            address pool = V3_FACTORY.getPool(collateral, address(USDG), s.v3Fee);
            uint256 before = USDG.balanceOf(address(this));
            _activeV3 = pool;
            _v3Payer = payer;
            _v3MaxSpend = maxSpend;
            IV2FlashPool(pool)
                .swap(
                    address(this),
                    collateralIsZero,
                    -int256(amount),
                    collateralIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                    abi.encode(collateral)
                );
            // The callback clears the pool; a pool that never called back leaves it set.
            if (_activeV3 != address(0)) revert NotPool();
            spent = _v3Spent;
            uint256 got = USDG.balanceOf(address(this)) - before;
            if (got != amount) revert PartialPurchase(got, amount);
            Currency cash = Currency.wrap(address(USDG));
            POOL_MANAGER.sync(cash);
            USDG.safeTransfer(address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    /// @dev The pool must pair the cash asset with the loan's collateral token: a hookless v4 pool, so no pool code runs
    ///      inside a close or a roll, or the V3 factory's own pool of the two.
    function _checkSwap(Swap calldata s, address collateral) internal view {
        if (s.venue == Venue.V4) {
            address zero = Currency.unwrap(s.key.currency0);
            address one = Currency.unwrap(s.key.currency1);
            (address lo, address hi) =
                collateral < address(USDG) ? (collateral, address(USDG)) : (address(USDG), collateral);
            if (zero != lo || one != hi || address(s.key.hooks) != address(0)) revert InvalidSwap();
        } else if (V3_FACTORY.getPool(collateral, address(USDG), s.v3Fee) == address(0)) {
            revert InvalidSwap();
        }
    }

    /// @dev A standing instruction on a loan its holder closes or rolls by hand ends with it.
    function _endInstruction(uint256 loanId) internal {
        address instructed = autoRolls[loanId].borrower;
        if (instructed != address(0)) {
            delete autoRolls[loanId];
            emit AutoRollCancelled(loanId, instructed);
        }
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

    /// @dev Book the old loan's repayment in each lending vault, so a vault can lend it again at once and never holds a
    ///      repaid loan past its end. `settle` is every keeper's permissionless entry point; a vault that cannot settle
    ///      now is left for the next keeper pass.
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
    ///      window held to `MAX_WINDOW` and to an eighth of the term.
    function _opensAt(V2Loan memory l, uint32 window) internal pure returns (uint256) {
        uint256 w = window;
        if (w > MAX_WINDOW) w = MAX_WINDOW;
        if (w > l.term / 8) w = l.term / 8;
        return uint256(l.fundedAt) + l.term - w;
    }
}
