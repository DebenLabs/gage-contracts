// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {LPRegistry} from "./LPRegistry.sol";
import {LPEscrow} from "./LPEscrow.sol";
import {ILPAdapter} from "./interfaces/ILPAdapter.sol";
import {ILPVault} from "./interfaces/ILPVault.sol";
import {Loan, LoanQuote, LoanState, PoolConfig, PositionFacts, UnwindQuote} from "./LPTypes.sol";

/// @title LPCore
/// @notice Fixed-cost, no-liquidation USDG loans against LP positions. A borrower opens a loan on a single-use quote the
/// rates signer gave for that exact position; the position sits in its own escrow until the loan is repaid before its
/// end (the borrower takes it back) or settled at or after its end (the vault takes everything the position holds:
/// its liquidity, its fees and its DEX rewards). The core has no owner and reads no price: the quote carries the
/// price, and the core checks only facts about the position. Everything owed to an account is credited here and
/// withdrawn by that account.
contract LPCore is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bytes32 public constant LOAN_QUOTE_TYPEHASH = keccak256(
        "LoanQuote(address borrower,address vault,address adapter,uint256 tokenId,uint128 liquidity,int24 tickLower,int24 tickUpper,uint128 collateralValue,uint128 principal,uint128 repayment,uint32 term,uint16 feeBps,uint64 deadline)"
    );
    bytes32 public constant UNWIND_QUOTE_TYPEHASH =
        keccak256("UnwindQuote(uint256 loanId,uint256 min0,uint256 min1,uint64 deadline)");

    /// @notice Wait, after the late unwind opens, before a loan whose position cannot be unwound may be abandoned.
    uint32 public constant ABANDON_DELAY = 14 days;
    /// @dev Most distinct tokens one position can deliver: its two pool tokens and up to four reward tokens.
    uint256 internal constant MAX_DELIVERED_TOKENS = 6;
    /// @notice The most a loan may cost, as a share of its principal a year, prorated by its term: 95.9 bps on 7
    /// days, 287.7 on 21. Whatever the quote signer signs, no repayment above it accrues into a vault's price.
    uint256 public constant MAX_COST_BPS_PER_YEAR = 5000;

    /// @notice The lane's settings.
    LPRegistry public immutable REGISTRY;
    /// @notice The lent asset.
    IERC20 public immutable USDG;
    /// @notice The escrow every loan clones.
    address public immutable ESCROW_IMPLEMENTATION;

    /// @notice The id the next loan takes.
    uint256 public nextLoanId = 1;
    mapping(uint256 loanId => Loan) internal _loans;
    /// @notice Quotes already used, by EIP-712 digest.
    mapping(bytes32 digest => bool) public quoteUsed;
    /// @notice What `account` may withdraw of `token`.
    mapping(address account => mapping(address token => uint256)) public credit;
    /// @notice The sum of every account's credit in `token`; the core always holds at least this much.
    mapping(address token => uint256) public totalCredit;
    /// @notice Principal of loans still open, per adapter and pool, against the pool's cap.
    mapping(address adapter => mapping(address pool => uint256)) public outstanding;
    /// @notice New money lent on each UTC day (`block.timestamp / 1 days`), against the registry's daily cap: a loan's
    /// principal, or what a roll adds over the loan it repays (a roll carrying the same principal adds nothing).
    mapping(uint256 day => uint256) public originated;

    event LoanOpened(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed vault,
        address adapter,
        address pool,
        uint256 tokenId,
        uint128 principal,
        uint128 repayment,
        uint256 fee,
        uint40 end,
        address escrow
    );
    event Repaid(uint256 indexed loanId, address indexed payer, uint256 amount);
    /// @notice Loan `loanId` was repaid by `newLoanId` on the same position; `net` is what the borrower was credited
    /// (positive) or paid (negative).
    event Rolled(
        uint256 indexed loanId, uint256 indexed newLoanId, address indexed borrower, uint256 repaid, int256 net
    );
    event PositionReturned(uint256 indexed loanId, address indexed borrower);
    event FeesCollected(uint256 indexed loanId, address token0, uint256 amount0, address token1, uint256 amount1);
    event RewardCredited(uint256 indexed loanId, address indexed account, address token, uint256 amount);
    event Defaulted(uint256 indexed loanId, address[] tokens, uint256[] amounts, bool late);
    event Abandoned(uint256 indexed loanId);
    event AbandonedRecovered(uint256 indexed loanId, address[] tokens, uint256[] amounts);
    event Credited(address indexed account, address indexed token, uint256 amount);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);

    error NewLoansPaused();
    error NotBorrower(address caller);
    error QuoteExpired(uint64 deadline);
    error TermNotAllowed(uint32 term);
    error AdapterNotAllowed(address adapter);
    error AdapterNotBound(address adapter);
    error VaultNotAllowed(address vault);
    error InvalidTerms();
    error FeeChanged(uint16 quoted, uint16 current);
    error AboveLtvCap();
    error QuoteUsed(bytes32 digest);
    error InvalidSignature();
    error EmptyPosition();
    error PositionChanged();
    error NotSamePosition();
    error PoolNotAllowed(address pool);
    error IdenticalTokens();
    error RangeTooNarrow();
    error BelowMinimumLoan();
    error AboveLoanCap();
    error AbovePoolCap();
    error AboveDailyCap();
    /// @notice The quote's repayment costs more than `MAX_COST_BPS_PER_YEAR` allows for its term.
    error CostAboveCeiling();
    error FundingMismatch(uint256 received);
    error NotActive(uint256 loanId);
    error PastTerm(uint256 loanId);
    error BeforeTermEnd(uint256 loanId);
    error NotRepaid(uint256 loanId);
    error AlreadyReturned(uint256 loanId);
    error QuoteMismatch();
    error LateUnwindNotOpen(uint256 opensAt);
    error AbandonNotOpen(uint256 opensAt);
    error NotAbandoned(uint256 loanId);
    error NothingToWithdraw();
    error ZeroAddress();

    /// @notice Deploys the core for one lent asset and its registry.
    constructor(LPRegistry registry, IERC20 usdg) EIP712("gage LP lane", "1") {
        if (address(registry) == address(0) || address(usdg) == address(0)) revert ZeroAddress();
        REGISTRY = registry;
        USDG = usdg;
        ESCROW_IMPLEMENTATION = address(new LPEscrow());
    }

    /// @notice Loan `loanId` as stored.
    function loan(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    /// @notice The EIP-712 digest the rates signer signs for `quote`.
    function loanQuoteDigest(LoanQuote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(LOAN_QUOTE_TYPEHASH, quote)));
    }

    /// @notice The EIP-712 digest the rates signer signs for `quote`.
    function unwindQuoteDigest(UnwindQuote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(UNWIND_QUOTE_TYPEHASH, quote)));
    }

    /// @notice Opens a loan against the caller's position on `quote`: the position moves into a fresh escrow, the
    /// quote's vault funds the principal, and the principal less the quoted fee is credited to the borrower. The
    /// position must still have the quoted range and at least the quoted liquidity (more only adds collateral).
    /// @dev The caller must have approved this core for the position.
    function borrow(LoanQuote calldata quote, bytes calldata signature) external nonReentrant returns (uint256 loanId) {
        (PositionFacts memory facts, uint256 fee) = _acceptQuote(quote, signature);
        _admit(quote.adapter, facts, quote.principal, quote.principal);

        address nft = ILPAdapter(quote.adapter).positionManager();
        address escrow = Clones.clone(ESCROW_IMPLEMENTATION);
        IERC721(nft).transferFrom(msg.sender, escrow, quote.tokenId);
        LPEscrow(escrow).approveOperator(nft, quote.adapter, quote.tokenId);
        uint40 end;
        (loanId, end) = _openLoan(quote, facts.pool, escrow, fee);

        uint256 before = USDG.balanceOf(address(this));
        ILPVault(quote.vault).fund(loanId, quote.principal, quote.repayment, end);
        uint256 received = USDG.balanceOf(address(this)) - before;
        if (received != quote.principal) revert FundingMismatch(received);
        _credit(msg.sender, address(USDG), quote.principal - fee);
        if (fee != 0) _credit(REGISTRY.feeRecipient(), address(USDG), fee);
    }

    /// @notice Rolls loan `loanId` into a new loan on `quote` for the same position, before the old loan's end. The new
    /// loan repays the old one in full and the position stays in its escrow, so nothing is unwound and no NFT moves.
    /// Only the difference moves: the borrower is credited what the new principal, less the fee, leaves over the old
    /// repayment, or pays what it lacks. Into the same vault only the difference leaves the vault too.
    /// @dev The quote is checked as `borrow` checks it, and must name the old loan's adapter and position. The caller
    /// must have approved this core for any USDG it has to pay.
    function roll(uint256 loanId, LoanQuote calldata quote, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 newLoanId)
    {
        if (REGISTRY.newLoansPaused()) revert NewLoansPaused();
        Loan storage old = _loans[loanId];
        if (old.state != LoanState.ACTIVE) revert NotActive(loanId);
        if (block.timestamp >= old.end) revert PastTerm(loanId);
        if (msg.sender != old.borrower) revert NotBorrower(msg.sender);
        if (quote.adapter != old.adapter || quote.tokenId != old.tokenId) revert NotSamePosition();
        (PositionFacts memory facts, uint256 fee) = _acceptQuote(quote, signature);

        old.state = LoanState.ROLLED;
        outstanding[old.adapter][old.pool] -= old.principal;
        // The new loan is booked in the pool whose cap `_admit` charges: the position's pool as its adapter reads it. The
        // day's cap counts only what the roll adds over the old principal, so a borrower can still roll on a full day.
        _admit(
            old.adapter, facts, quote.principal, quote.principal > old.principal ? quote.principal - old.principal : 0
        );
        uint40 end;
        (newLoanId, end) = _openLoan(quote, facts.pool, old.escrow, fee);

        uint256 owed = old.repayment;
        int256 net = int256(uint256(quote.principal)) - int256(fee) - int256(owed);
        if (net < 0) USDG.safeTransferFrom(msg.sender, address(this), uint256(-net));
        uint256 before = USDG.balanceOf(address(this));
        if (quote.vault == old.vault) {
            if (owed > quote.principal) USDG.safeTransfer(old.vault, owed - quote.principal);
            ILPVault(old.vault).refinance(loanId, newLoanId, quote.principal, quote.repayment, end);
        } else {
            ILPVault(quote.vault).fund(newLoanId, quote.principal, quote.repayment, end);
            USDG.safeTransfer(old.vault, owed);
            ILPVault(old.vault).onRepaid(loanId, owed);
        }
        uint256 balance = USDG.balanceOf(address(this));
        if (balance + owed != before + quote.principal) revert FundingMismatch(balance);
        if (fee != 0) _credit(REGISTRY.feeRecipient(), address(USDG), fee);
        if (net > 0) _credit(msg.sender, address(USDG), uint256(net));
        emit Rolled(loanId, newLoanId, msg.sender, owed, net);
    }

    /// @notice Repays loan `loanId` before its end. Anyone may pay; the position becomes the borrower's to take back.
    function repay(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.ACTIVE) revert NotActive(loanId);
        if (block.timestamp >= l.end) revert PastTerm(loanId);
        l.state = LoanState.REPAID;
        outstanding[l.adapter][l.pool] -= l.principal;
        uint256 amount = l.repayment;
        USDG.safeTransferFrom(msg.sender, l.vault, amount);
        ILPVault(l.vault).onRepaid(loanId, amount);
        emit Repaid(loanId, msg.sender, amount);
    }

    /// @notice Sends a repaid loan's position back to its borrower, with any rewards that reached its escrow.
    function returnPosition(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.REPAID) revert NotRepaid(loanId);
        if (l.positionReturned) revert AlreadyReturned(loanId);
        if (msg.sender != l.borrower) revert NotBorrower(msg.sender);
        l.positionReturned = true;
        LPEscrow(l.escrow).sendPosition(ILPAdapter(l.adapter).positionManager(), l.borrower, l.tokenId);
        // After the transfer, so rewards a position manager pays its previous owner on transfer are swept too.
        _sweepRewardsToCredit(loanId, l);
        emit PositionReturned(loanId, l.borrower);
    }

    /// @notice Collects an open loan's fees for its borrower before its end; the liquidity stays in place. From the
    /// end on, the fees belong with the position to the vault.
    function collectFees(uint256 loanId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.ACTIVE) revert NotActive(loanId);
        if (block.timestamp >= l.end) revert PastTerm(loanId);
        if (msg.sender != l.borrower) revert NotBorrower(msg.sender);
        PositionFacts memory facts = ILPAdapter(l.adapter).facts(l.tokenId);
        uint256 before0 = IERC20(facts.token0).balanceOf(address(this));
        uint256 before1 = IERC20(facts.token1).balanceOf(address(this));
        ILPAdapter(l.adapter).collectFees(l.tokenId, address(this));
        amount0 = IERC20(facts.token0).balanceOf(address(this)) - before0;
        amount1 = IERC20(facts.token1).balanceOf(address(this)) - before1;
        _credit(l.borrower, facts.token0, amount0);
        _credit(l.borrower, facts.token1, amount1);
        emit FeesCollected(loanId, facts.token0, amount0, facts.token1, amount1);
    }

    /// @notice Claims an open loan's DEX rewards for its borrower before its end.
    function claimRewards(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.ACTIVE) revert NotActive(loanId);
        if (block.timestamp >= l.end) revert PastTerm(loanId);
        if (msg.sender != l.borrower) revert NotBorrower(msg.sender);
        ILPAdapter(l.adapter).claimRewards(l.tokenId);
        _sweepRewardsToCredit(loanId, l);
    }

    /// @notice Settles loan `loanId` at or after its end: its rewards are claimed, its liquidity is removed within the
    /// rates signer's minimums, and every token goes to the vault. Anyone may call it with a valid quote; the keeper
    /// does by default.
    function settleDefault(uint256 loanId, UnwindQuote calldata quote, bytes calldata signature) external nonReentrant {
        _checkUnwindQuote(loanId, quote, signature);
        _settle(loanId, quote.min0, quote.min1, quote.deadline, false);
    }

    /// @notice Settles loan `loanId` with no minimums once `lateUnwindDelay` has passed since its end, so a lender
    /// never waits on the rates signer forever.
    function settleDefaultLate(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        uint256 opensAt = uint256(l.end) + REGISTRY.lateUnwindDelay();
        if (block.timestamp < opensAt) revert LateUnwindNotOpen(opensAt);
        _settle(loanId, 0, 0, block.timestamp, true);
    }

    /// @notice Last resort for a position that no unwind could remove (a halted DEX, a token refusing the vault):
    /// `ABANDON_DELAY` after the late unwind opened, anyone may close the loan in the vault's books at a full loss so
    /// its lenders are not frozen forever. The position stays in escrow and can still be recovered.
    function abandonDefault(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.ACTIVE) revert NotActive(loanId);
        uint256 opensAt = uint256(l.end) + REGISTRY.lateUnwindDelay() + ABANDON_DELAY;
        if (block.timestamp < opensAt) revert AbandonNotOpen(opensAt);
        l.state = LoanState.ABANDONED;
        outstanding[l.adapter][l.pool] -= l.principal;
        ILPVault(l.vault).onAbandoned(loanId);
        emit Abandoned(loanId);
    }

    /// @notice Unwinds an abandoned loan's position into its vault within the rates signer's minimums, once the DEX
    /// allows it again. The vault books what arrives as a recovery.
    function recoverAbandoned(uint256 loanId, UnwindQuote calldata quote, bytes calldata signature)
        external
        nonReentrant
    {
        _checkUnwindQuote(loanId, quote, signature);
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.ABANDONED) revert NotAbandoned(loanId);
        l.state = LoanState.DEFAULTED;
        (address[] memory tokens, uint256[] memory amounts) = _unwindToVault(l, quote.min0, quote.min1, quote.deadline);
        ILPVault(l.vault).onRecovered(loanId, tokens, amounts);
        emit AbandonedRecovered(loanId, tokens, amounts);
    }

    /// @notice Withdraws the caller's whole credit in `token`.
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        amount = _withdraw(msg.sender, token);
    }

    /// @notice Pays `account`'s whole credit in `token` to `account`. Anyone may trigger it; the funds only go to the
    /// account (how fee recipients that cannot call are paid).
    function withdrawFor(address account, address token) external nonReentrant returns (uint256 amount) {
        amount = _withdraw(account, token);
    }

    /// @dev Every check a loan quote must pass before its loan is admitted: the switches, the caller, the terms, an
    /// adapter bound to this core, the fee, the LTV cap, the signature (marking the quote used) and the
    /// position's facts. Returns those facts and the loan's origination fee.
    function _acceptQuote(LoanQuote calldata quote, bytes calldata signature)
        internal
        returns (PositionFacts memory facts, uint256 fee)
    {
        if (REGISTRY.newLoansPaused()) revert NewLoansPaused();
        if (msg.sender != quote.borrower) revert NotBorrower(msg.sender);
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline);
        if (!REGISTRY.termAllowed(quote.term)) revert TermNotAllowed(quote.term);
        if (!REGISTRY.adapterAllowed(quote.adapter)) revert AdapterNotAllowed(quote.adapter);
        if (ILPAdapter(quote.adapter).core() != address(this)) revert AdapterNotBound(quote.adapter);
        if (!REGISTRY.vaultAllowed(quote.vault)) revert VaultNotAllowed(quote.vault);
        if (quote.principal == 0 || quote.repayment < quote.principal) revert InvalidTerms();
        if (
            uint256(quote.repayment) - quote.principal
                > uint256(quote.principal) * MAX_COST_BPS_PER_YEAR * quote.term / (365 days * 10_000)
        ) revert CostAboveCeiling();
        uint16 feeBps = REGISTRY.feeBps();
        if (quote.feeBps != feeBps) revert FeeChanged(quote.feeBps, feeBps);
        fee = (uint256(quote.principal) * feeBps) / 10_000;
        if (uint256(quote.principal) * 10_000 > uint256(quote.collateralValue) * REGISTRY.ltvCapBps()) {
            revert AboveLtvCap();
        }

        bytes32 digest = loanQuoteDigest(quote);
        if (quoteUsed[digest]) revert QuoteUsed(digest);
        quoteUsed[digest] = true;
        if (ECDSA.recover(digest, signature) != REGISTRY.quoteSigner()) revert InvalidSignature();

        facts = ILPAdapter(quote.adapter).facts(quote.tokenId);
        if (facts.liquidity == 0) revert EmptyPosition();
        if (
            facts.liquidity < quote.liquidity || facts.tickLower != quote.tickLower
                || facts.tickUpper != quote.tickUpper
        ) revert PositionChanged();
    }

    /// @dev Books a new loan on `quote` for the caller, its position held by `escrow` in `pool`, and announces it.
    function _openLoan(LoanQuote calldata quote, address pool, address escrow, uint256 fee)
        internal
        returns (uint256 loanId, uint40 end)
    {
        loanId = nextLoanId++;
        end = uint40(block.timestamp + quote.term);
        _loans[loanId] = Loan({
            borrower: msg.sender,
            vault: quote.vault,
            adapter: quote.adapter,
            escrow: escrow,
            pool: pool,
            tokenId: quote.tokenId,
            principal: quote.principal,
            repayment: quote.repayment,
            start: uint40(block.timestamp),
            end: end,
            state: LoanState.ACTIVE,
            positionReturned: false
        });
        emit LoanOpened(
            loanId,
            msg.sender,
            quote.vault,
            quote.adapter,
            pool,
            quote.tokenId,
            quote.principal,
            quote.repayment,
            fee,
            end,
            escrow
        );
    }

    /// @dev Checks a new loan of `principal` against its pool's terms and caps and books it; `added` is the new money it
    /// lends today, against the daily cap (the whole principal, or a roll's increase). A position whose two tokens are
    /// the same is refused: its fees would be credited twice.
    function _admit(address adapter, PositionFacts memory facts, uint128 principal, uint256 added) internal {
        PoolConfig memory config = REGISTRY.poolConfig(adapter, facts.pool);
        if (!config.allowed) revert PoolNotAllowed(facts.pool);
        if (facts.token0 == facts.token1) revert IdenticalTokens();
        if (
            config.minHalfWidthTicks != 0
                && int256(facts.tickUpper) - int256(facts.tickLower) < 2 * int256(uint256(config.minHalfWidthTicks))
        ) revert RangeTooNarrow();
        if (principal < config.minLoanPrincipal) revert BelowMinimumLoan();
        if (principal > config.maxLoanPrincipal) revert AboveLoanCap();
        uint256 next = outstanding[adapter][facts.pool] + principal;
        if (next > config.maxOutstanding) revert AbovePoolCap();
        outstanding[adapter][facts.pool] = next;
        uint256 day = block.timestamp / 1 days;
        uint256 today = originated[day] + added;
        if (today > REGISTRY.dailyOriginationCap()) revert AboveDailyCap();
        originated[day] = today;
    }

    function _checkUnwindQuote(uint256 loanId, UnwindQuote calldata quote, bytes calldata signature) internal {
        if (quote.loanId != loanId) revert QuoteMismatch();
        if (block.timestamp > quote.deadline) revert QuoteExpired(quote.deadline);
        bytes32 digest = unwindQuoteDigest(quote);
        if (quoteUsed[digest]) revert QuoteUsed(digest);
        quoteUsed[digest] = true;
        if (ECDSA.recover(digest, signature) != REGISTRY.quoteSigner()) revert InvalidSignature();
    }

    function _settle(uint256 loanId, uint256 min0, uint256 min1, uint256 deadline, bool late) internal {
        Loan storage l = _loans[loanId];
        if (l.state != LoanState.ACTIVE) revert NotActive(loanId);
        if (block.timestamp < l.end) revert BeforeTermEnd(loanId);
        l.state = LoanState.DEFAULTED;
        outstanding[l.adapter][l.pool] -= l.principal;
        (address[] memory tokens, uint256[] memory amounts) = _unwindToVault(l, min0, min1, deadline);
        ILPVault(l.vault).onDefault(loanId, tokens, amounts);
        emit Defaulted(loanId, tokens, amounts, late);
    }

    /// @dev Claims the position's rewards (never blocking), removes all its liquidity into the vault, sweeps every
    /// reward the escrow received there too, and returns each distinct token with the amount the vault received.
    function _unwindToVault(Loan storage l, uint256 min0, uint256 min1, uint256 deadline)
        internal
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        ILPAdapter adapter = ILPAdapter(l.adapter);
        PositionFacts memory facts = adapter.facts(l.tokenId);
        address[] memory rewards = adapter.rewardTokens();
        tokens = _distinct(facts.token0, facts.token1, rewards);
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = IERC20(tokens[i]).balanceOf(l.vault);
        }
        // A reward claim that fails must never stop a settlement.
        try adapter.claimRewards(l.tokenId) {} catch {}
        adapter.unwind(l.tokenId, l.vault, min0, min1, deadline);
        for (uint256 i; i < rewards.length; ++i) {
            LPEscrow(l.escrow).sweep(rewards[i], l.vault);
        }
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = IERC20(tokens[i]).balanceOf(l.vault) - amounts[i];
        }
    }

    function _distinct(address token0, address token1, address[] memory rewards)
        internal
        pure
        returns (address[] memory tokens)
    {
        address[] memory all = new address[](MAX_DELIVERED_TOKENS);
        uint256 n;
        all[n++] = token0;
        if (token1 != token0) all[n++] = token1;
        for (uint256 i; i < rewards.length && n < MAX_DELIVERED_TOKENS; ++i) {
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (all[j] == rewards[i]) seen = true;
            }
            if (!seen) all[n++] = rewards[i];
        }
        tokens = new address[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = all[i];
        }
    }

    function _sweepRewardsToCredit(uint256 loanId, Loan storage l) internal {
        address[] memory rewards = ILPAdapter(l.adapter).rewardTokens();
        for (uint256 i; i < rewards.length; ++i) {
            uint256 before = IERC20(rewards[i]).balanceOf(address(this));
            LPEscrow(l.escrow).sweep(rewards[i], address(this));
            uint256 received = IERC20(rewards[i]).balanceOf(address(this)) - before;
            if (received != 0) {
                _credit(l.borrower, rewards[i], received);
                emit RewardCredited(loanId, l.borrower, rewards[i], received);
            }
        }
    }

    function _credit(address account, address token, uint256 amount) internal {
        if (amount == 0) return;
        credit[account][token] += amount;
        totalCredit[token] += amount;
        emit Credited(account, token, amount);
    }

    function _withdraw(address account, address token) internal returns (uint256 amount) {
        amount = credit[account][token];
        if (amount == 0) revert NothingToWithdraw();
        credit[account][token] = 0;
        totalCredit[token] -= amount;
        IERC20(token).safeTransfer(account, amount);
        emit Withdrawn(account, token, amount);
    }
}
