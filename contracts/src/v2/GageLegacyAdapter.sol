// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDealVault, IGageLegacyCashIdentity, Deal} from "../interfaces/IDealVault.sol";
import {DealRewards} from "../token/DealRewards.sol";
import {Kind} from "../types/Types.sol";
import {GageLegacyParty} from "./GageLegacyParty.sol";
import {GageV2TokenCollateralAccount} from "./GageV2TokenCollateralAccount.sol";

interface IGageAdapterEngine {
    function USDG() external view returns (address);
    function SGAGE() external view returns (address);
    function BRIDGE() external view returns (address);
    function REWARDS() external view returns (address);
}

/// @notice Stable, restricted legacy receipt and reward source for explicitly selected immutable engines.
/// @dev Engine selection affects new loans only. Each loan permanently binds its engine and reward ledger; its account
///      is recorded in `LoanOpened` and `pledgedAccount`, and the engine id in `adapterId`.
///      The legacy deal behind a loan holds one unit of this receipt and nothing else, so an engine may close a loan
///      on its own clock: a default is recorded here at once and the legacy deal is claimed whenever the legacy vault
///      allows it, by anyone, moving nothing of value.
///      It serves token-collateral engines only (D35, D44): an engine with position collateral needs a new adapter.
contract GageLegacyAdapter is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable ADMIN;
    IDealVault public immutable VAULT;
    DealRewards public immutable REWARDS;
    IERC20 public immutable USDG;
    IERC20 public immutable SGAGE;
    address public immutable PARTY_IMPLEMENTATION;
    address public activeEngine;
    uint256 public loanCount;
    uint256 public recycledFree;

    struct Loan {
        address engine;
        address ledger;
        address borrower;
        address lender;
        uint256 legacyId;
        uint128 cap;
        uint128 borrowerReward;
        uint128 lenderReward;
        uint40 start;
        uint40 closedAt;
        uint32 term;
        uint256 liquid;
        uint256 paid;
    }

    mapping(uint256 => Loan) private _loans;
    mapping(address => mapping(uint256 => uint256)) public adapterId;
    mapping(address => uint256) public partyLoan;
    mapping(address => bool) public pledgedAccount;

    /// @notice The caller is not the admin (`setEngine`), the active engine (`open`), the engine that opened the loan
    /// (`repay`, `finalizeDefault`) or the loan's ledger (`pay`).
    error NotAuthorized();
    error InvalidConfiguration();
    error InvalidLoan();
    error InvalidBacking();
    error RestrictedReceipt();
    error CashMismatch();
    error ExcessClaim();

    event EngineSelected(address indexed previousEngine, address indexed engine);
    event LoanOpened(
        uint256 indexed id,
        address indexed engine,
        uint256 indexed engineId,
        uint256 legacyId,
        address account,
        address borrower,
        address lender,
        uint128 borrowerReward,
        uint128 lenderReward
    );
    event LoanClosed(uint256 indexed id, bool repaid, uint40 closedAt);
    event LegacySettled(uint256 indexed id, uint256 indexed legacyId);
    event RewardsPaid(uint256 indexed id, address indexed ledger, uint256 amount);
    event RewardsRecycled(uint256 indexed id, uint256 amount);

    constructor(address admin, IDealVault vault, DealRewards rewards, IERC20 usdg)
        ERC20("Gage internal collateral receipt", "GAGE-RECEIPT")
    {
        // A vault or rewards address without code reverts on these reads; usdg is the vault's own USDG.
        if (
            admin == address(0) || address(rewards.VAULT()) != address(vault)
                || IGageLegacyCashIdentity(address(vault)).USDG() != address(usdg)
        ) revert InvalidConfiguration();
        ADMIN = admin;
        VAULT = vault;
        REWARDS = rewards;
        USDG = usdg;
        SGAGE = rewards.SGAGE();
        PARTY_IMPLEMENTATION = address(new GageLegacyParty(vault, rewards, usdg));
    }

    /// @notice Select the only engine allowed to create new loans, or zero to stop originations.
    function setEngine(address engine) external {
        if (msg.sender != ADMIN) revert NotAuthorized();
        if (engine != address(0)) {
            IGageAdapterEngine e = IGageAdapterEngine(engine);
            if (
                engine.code.length == 0 || e.BRIDGE() != address(this) || e.USDG() != address(USDG)
                    || e.SGAGE() != address(SGAGE) || e.REWARDS().code.length == 0
            ) revert InvalidConfiguration();
        }
        emit EngineSelected(activeEngine, engine);
        activeEngine = engine;
    }

    /// @notice Quote the current available allocation, including already unlocked recycled rewards.
    /// @dev Availability is checked again during the atomic fourth-quarter activation.
    function quote(uint32 term, uint128 fee) public view returns (uint128 borrower, uint128 lender) {
        (uint128 legacy, uint256 epoch,,) = REWARDS.quote(term, fee);
        if (!_bridgedTerm(term)) return (0, 0);
        DealRewards.EpochRates memory rates = REWARDS.effectiveRates(epoch);
        uint256 maximum;
        if (rates.set && rates.priceUSDGPerSGAGE != 0 && epoch < REWARDS.EMISSIONS().WEEKS()) {
            maximum = Math.min(
                // As `DealRewards` buckets terms: 21 days earns the 21-day rate, every shorter term the 7-day rate.
                Math.mulDiv(fee, term == 21 days ? rates.rate21 : rates.rate7, REWARDS.USDG_UNIT()),
                Math.mulDiv(uint256(fee) * 1e18, 8000, uint256(rates.priceUSDGPerSGAGE) * 10_000)
            );
        }
        // At most the legacy allocation plus recycled sGAGE, both below sGAGE's fixed 5e27 supply: far below 2^128.
        uint256 total = uint256(legacy) + Math.min(recycledFree, maximum > legacy ? maximum - legacy : 0);
        lender = uint128(Math.mulDiv(total, rates.lenderShareBps, 10_000));
        borrower = uint128(total - lender);
    }

    /// @notice Atomically back a receipt, list/fund V1, register its grant and return net principal to its engine.
    function open(uint256 engineId, address account, uint128 principal, uint128 cap, uint32 term, uint128 expectedFee)
        external
        nonReentrant
        returns (uint128 borrowerReward, uint128 lenderReward)
    {
        if (msg.sender != activeEngine) revert NotAuthorized();
        // The engine numbers loans from 1 and lists at least 4 units with a cap at or above the principal; the legacy
        // vault enforces its own price and cap bounds again.
        if (adapterId[msg.sender][engineId] != 0 || !_bridgedTerm(term)) revert InvalidLoan();
        _checkBacking(account);
        uint256 id = ++loanCount;
        adapterId[msg.sender][engineId] = id;
        pledgedAccount[account] = true;
        Loan storage l = _loans[id];
        l.engine = msg.sender;
        l.ledger = IGageAdapterEngine(msg.sender).REWARDS();
        l.cap = cap;
        l.term = term;
        l.start = uint40(block.timestamp);
        l.borrower = Clones.clone(PARTY_IMPLEMENTATION);
        l.lender = Clones.clone(PARTY_IMPLEMENTATION);
        partyLoan[l.borrower] = id;
        partyLoan[l.lender] = id;
        _mint(l.borrower, 1);
        USDG.safeTransferFrom(msg.sender, l.lender, principal);
        l.legacyId = GageLegacyParty(l.borrower).list(principal, cap, term);
        GageLegacyParty(l.lender).fund(l.legacyId, principal);
        Deal memory d = VAULT.getDeal(l.legacyId);
        if (d.fee != expectedFee || d.price != principal || d.cap != cap || d.fundedAt != l.start) {
            revert CashMismatch();
        }
        // Quote before register consumes this loan's remaining legacy budget.
        (borrowerReward, lenderReward) = quote(term, d.fee);
        REWARDS.register(l.legacyId);
        (uint128 total, uint128 legacyLender, uint128 legacyBorrower) = REWARDS.rewardOf(l.legacyId);
        uint256 selected = uint256(borrowerReward) + lenderReward;
        // Registration is synchronous and must match the quoted legacy source, including zero allocations.
        if (selected < total || borrowerReward < legacyBorrower || lenderReward < legacyLender) revert InvalidLoan();
        l.liquid = selected - total;
        recycledFree -= l.liquid;
        l.borrowerReward = borrowerReward;
        l.lenderReward = lenderReward;
        uint256 proceeds = GageLegacyParty(l.borrower).withdrawCash();
        if (proceeds != uint256(principal) - d.fee) revert CashMismatch();
        USDG.safeTransfer(l.engine, proceeds);
        emit LoanOpened(
            id, msg.sender, engineId, l.legacyId, account, l.borrower, l.lender, borrowerReward, lenderReward
        );
    }

    /// @notice Settle V1 at its full cap and return repayment to the original engine's lender-credit ledger.
    function repay(uint256 engineId) external nonReentrant {
        (, Loan storage l) = _closeLoan(engineId, true);
        USDG.safeTransferFrom(msg.sender, l.borrower, l.cap);
        GageLegacyParty(l.borrower).repay(l.legacyId, l.cap);
        _burn(l.borrower, 1);
        uint256 repayment = GageLegacyParty(l.lender).withdrawCash();
        if (repayment != l.cap) revert CashMismatch();
        USDG.safeTransfer(l.engine, repayment);
    }

    /// @notice Record the engine's default now; claim the legacy deal at once if its own grace has already passed.
    /// @dev Closing here ends the loan's reward clock and its repay path. The legacy deal keeps only this adapter's
    ///      receipt, and only this adapter can act on it, so a later `settleLegacy` changes nothing for anyone.
    function finalizeDefault(uint256 engineId) external nonReentrant {
        (uint256 id, Loan storage l) = _closeLoan(engineId, false);
        if (block.timestamp >= VAULT.claimableAt(l.legacyId)) _settleLegacy(id, l);
    }

    /// @notice Claim and burn the receipt of a defaulted loan's legacy deal once the legacy vault allows it. Anyone.
    /// @dev The legacy vault's `claim` reverts `GraceNotOver(at)` before its grace ends and `DealNotFunded(legacyId)`
    ///      once the deal was repaid or already claimed.
    function settleLegacy(uint256 id) external nonReentrant {
        Loan storage l = _loans[id];
        if (l.closedAt == 0) revert InvalidLoan();
        _settleLegacy(id, l);
    }

    function _settleLegacy(uint256 id, Loan storage l) private {
        GageLegacyParty(l.lender).finalizeDefault(l.legacyId);
        _burn(l.lender, 1);
        emit LegacySettled(id, l.legacyId);
    }

    /// @notice Deliver only this loan's earned rewards to its permanently recorded reward ledger.
    /// @dev A few raw units can await the next source unlock because independent curves round separately.
    function pay(uint256 id, uint256 requested) external nonReentrant returns (uint256 amount) {
        Loan storage l = _loans[id];
        if (msg.sender != l.ledger || l.engine == address(0)) revert NotAuthorized();
        if (requested > _earned(l) - l.paid) revert ExcessClaim();
        _harvest(l);
        amount = Math.min(requested, l.liquid);
        l.paid += amount;
        l.liquid -= amount;
        if (amount != 0) SGAGE.safeTransfer(l.ledger, amount);
        emit RewardsPaid(id, l.ledger, amount);
    }

    /// @notice Harvest a closed loan and make only its unlocked surplus available to future eligible loans.
    function recycle(uint256 id) external nonReentrant returns (uint256 amount) {
        Loan storage l = _loans[id];
        if (l.closedAt == 0) revert InvalidLoan();
        _harvest(l);
        uint256 owed = _earned(l) - l.paid;
        if (l.liquid > owed) {
            amount = l.liquid - owed;
            l.liquid = owed;
            recycledFree += amount;
        }
        emit RewardsRecycled(id, amount);
    }

    /// @notice Complete source, authority and reward accounting for an adapter loan.
    function loan(uint256 id) external view returns (Loan memory) {
        return _loans[id];
    }

    function _closeLoan(uint256 engineId, bool repaid) private returns (uint256 id, Loan storage l) {
        id = adapterId[msg.sender][engineId];
        l = _loans[id];
        if (id == 0 || l.engine != msg.sender) revert NotAuthorized();
        if (l.closedAt != 0) revert InvalidLoan();
        l.closedAt = uint40(block.timestamp);
        emit LoanClosed(id, repaid, l.closedAt);
    }

    function _checkBacking(address account) private view {
        if (account.code.length == 0 || pledgedAccount[account]) revert InvalidBacking();
        GageV2TokenCollateralAccount a = GageV2TokenCollateralAccount(payable(account));
        if (a.vault() != msg.sender || a.released() || a.recovered()) revert InvalidBacking();
        (Kind kind, address token, uint256 amount) = a.collateral();
        if (amount == 0 || token == address(this) || token == address(SGAGE)) revert InvalidBacking();
        if (kind != Kind.ERC20 || IERC20(token).balanceOf(account) < amount) revert InvalidBacking();
    }

    function _harvest(Loan storage l) private {
        l.liquid += GageLegacyParty(l.borrower).harvest(l.legacyId) + GageLegacyParty(l.lender).harvest(l.legacyId);
    }

    function _earned(Loan storage l) private view returns (uint256) {
        uint256 elapsed = Math.min((l.closedAt == 0 ? block.timestamp : l.closedAt) - l.start, l.term);
        uint256 square = elapsed * elapsed;
        uint256 denominator = uint256(l.term) * l.term;
        return Math.mulDiv(l.borrowerReward, square, denominator) + Math.mulDiv(l.lenderReward, square, denominator);
    }

    function _update(address from, address to, uint256 value) internal override {
        bool minting = from == address(0) && partyLoan[to] != 0;
        bool burning = to == address(0) && partyLoan[from] != 0;
        bool depositing = to == address(VAULT) && msg.sender == address(VAULT) && partyLoan[from] != 0;
        bool withdrawing = from == address(VAULT) && msg.sender == address(VAULT) && partyLoan[to] != 0;
        if (value != 1 || (!minting && !burning && !depositing && !withdrawing)) revert RestrictedReceipt();
        super._update(from, to, value);
    }

    /// @dev The terms a bridged loan may have: the 7- and 21-day buckets' own, and 1 day, which the weekly pot's short
    ///      (under 21 days) budget pays at the 7-day rate. The legacy vault must allow each term as well.
    function _bridgedTerm(uint32 term) private pure returns (bool) {
        return term == 1 days || term == 7 days || term == 21 days;
    }
}
