// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State, unitSlice} from "../v2/V2Types.sol";
import {Kind} from "../types/Types.sol";
import {GradeRegistry} from "../earn/GradeRegistry.sol";
import {IntentFeeMath} from "./IntentFeeMath.sol";
import {IntentVault} from "./IntentVault.sol";
import {IntentCategory, IntentLimit, INTENT_MAX_LOAN_PRINCIPAL, INTENT_MAX_RATE_GRADE} from "./IntentVaultState.sol";
import {IntentFactory} from "./IntentFactory.sol";

/// @notice An immutable vault's explicit collateral list and three-hour addition queue, its secondary purchase policy
/// (S9): whether it buys existing lender positions and the extra annual return it asks above the model's, and the
/// three-hour queue of its risk limits (Intent D53).
/// @dev Created once by its vault. Only that vault may change the asset list; only its curator may change the
/// secondary policy and the risk limits, directly here. No owner, upgrade or alternate mutation path. Keeping these
/// bounded policies separate leaves the accounting engine below EIP-170.
contract IntentAssetPolicy {
    IntentVault private immutable VAULT;
    GageV2Vault private immutable CORE;
    address private immutable CURATOR;
    IntentFactory private immutable SOURCE;
    uint8 private immutable MASK;
    GradeRegistry private immutable GRADES;
    /// @dev `INTENT_MAX_LOAN_PRINCIPAL`, given in six-decimal units, times the vault's `ASSET_SCALE`: one billion whole
    /// units of the lent asset.
    uint256 private immutable MAX_PRINCIPAL;
    mapping(address => bool) public picked;
    mapping(address => uint256) public readyAt;

    /// @notice The highest extra annual return a curator may ask of a secondary purchase, in basis points. An outer
    /// bound in code, not a launch value (S9-01).
    uint16 public constant MAX_EXTRA_ANNUAL_RETURN_BPS = 10_000;
    /// @notice How long a change that lets the vault buy more (enabling purchases, or asking less) waits. The same
    /// wait as an asset addition; a change that lets it buy less applies at once (S9-01, proposed D37).
    uint256 public constant SECONDARY_LOOSEN_DELAY = 3 hours;

    /// @notice Whether the vault buys existing lender positions. Absent a policy it never does.
    bool public secondaryEnabled;
    /// @notice The return a purchase must keep above the model's requirement, as an annual rate on its price.
    uint16 public minExtraAnnualReturnBps;
    /// @notice Advances with every change that takes effect; a signed secondary plan names the one it was priced on.
    uint64 public secondaryRevision;
    /// @notice A loosening waiting for `pendingReadyAt`; zero when none is queued. A queued change is always an
    /// enabling one (a narrowing applies at once), so `pendingReadyAt != 0` marks it.
    uint16 public pendingExtraBps;
    uint256 public pendingReadyAt;

    /// @notice How long a loosened risk limit waits before anyone may apply it: more per loan, per token or per
    /// category, less cash kept free, a lower Loan grade floor. A tightened one applies at once (Intent D53).
    uint256 public constant LIMIT_LOOSEN_DELAY = 3 hours;

    /// @notice A loosened limit waiting to apply: the value, and the time from which anyone may activate it.
    struct PendingLimit {
        uint128 value;
        uint64 readyAt;
    }

    /// @notice The loosening queued for each risk limit; `readyAt` zero when none is.
    mapping(IntentLimit => PendingLimit) public pendingLimit;

    event SecondaryPolicySet(bool enabled, uint16 minExtraAnnualReturnBps, uint64 revision);
    event SecondaryPolicyQueued(bool enabled, uint16 minExtraAnnualReturnBps, uint256 readyAt);
    event SecondaryPolicyCancelled();
    /// @notice A risk limit took effect: a tightening at once, or a loosening once activated.
    event LimitSet(IntentLimit indexed limit, uint128 value);
    event LimitQueued(IntentLimit indexed limit, uint128 value, uint256 readyAt);
    event LimitCancelled(IntentLimit indexed limit);

    error InvalidConfiguration();
    error NotCurator();
    error NotVault();
    error IneligibleDeal();
    error LimitExceeded();
    /// @notice The vault does not buy existing positions now.
    error SecondaryClosed();
    /// @notice The vault already has a record of this loan: an open position, a sale or repayment it booked, a
    /// write-off or reward entitlement. S9 refuses a second record rather than mixing the two (S9-01).
    error ExistingRecord();
    /// @notice What the quarters repay beyond their price, after the execution fee, is below the curator's floor.
    error BelowReturnFloor();

    constructor(
        address core,
        address curator,
        address source,
        address grades,
        uint8 mask,
        uint256 assetScale,
        address[] memory initial,
        bool enabled,
        uint16 extraBps
    ) {
        VAULT = IntentVault(msg.sender);
        CORE = GageV2Vault(core);
        MAX_PRINCIPAL = INTENT_MAX_LOAN_PRINCIPAL * assetScale;
        CURATOR = curator;
        SOURCE = IntentFactory(source);
        MASK = mask;
        GRADES = GradeRegistry(grades);
        for (uint256 i; i < initial.length; ++i) {
            address token = initial[i];
            if (picked[token]) revert InvalidConfiguration();
            _eligible(token);
            picked[token] = true;
        }
        // Chosen at creation, before anyone deposits, it applies at once.
        if (extraBps > MAX_EXTRA_ANNUAL_RETURN_BPS) revert InvalidConfiguration();
        _setSecondary(enabled, extraBps);
    }

    // ---------------------------------------------------------------- risk limits

    /// @notice Move one of the vault's risk limits. Tightening (less per loan, per token or per category, more cash
    /// kept free, a higher Loan grade floor) or leaving it unchanged applies at once and drops any loosening queued for
    /// it; loosening waits `LIMIT_LOOSEN_DELAY`, then anyone may activate it. A new loosening replaces the one queued
    /// and restarts its wait. Open loans are untouched either way. The curator only.
    /// @dev Bounds in code: the most per loan at most `INTENT_MAX_LOAN_PRINCIPAL` in the asset's units, a share at most
    /// 100%, a grade at most A, and no weight outside the vault's universe: a category not in its mask stays closed for
    /// good (D41).
    function setLimit(IntentLimit limit, uint128 value) external {
        if (_tightens(limit, value)) {
            delete pendingLimit[limit];
            _applyLimit(limit, value);
        } else {
            uint256 eta = block.timestamp + LIMIT_LOOSEN_DELAY;
            pendingLimit[limit] = PendingLimit(value, uint64(eta));
            emit LimitQueued(limit, value, eta);
        }
    }

    /// @notice Tighten one risk limit at once, as `setLimit` does, and refuse a loosening outright. For a manager key
    /// allowed only to reduce risk: a Safe's agent role grants this function alone (Steward, D177). The curator only.
    function tightenLimit(IntentLimit limit, uint128 value) external {
        if (!_tightens(limit, value)) revert InvalidConfiguration();
        delete pendingLimit[limit];
        _applyLimit(limit, value);
    }

    /// @notice Apply a queued loosening once its wait is over. Anyone may.
    function activateLimit(IntentLimit limit) external {
        PendingLimit memory pending = pendingLimit[limit];
        if (pending.readyAt == 0 || block.timestamp < pending.readyAt) revert InvalidConfiguration();
        delete pendingLimit[limit];
        _applyLimit(limit, pending.value);
    }

    /// @notice Drop a queued loosening. The curator only.
    function cancelLimit(IntentLimit limit) external {
        if (msg.sender != CURATOR) revert NotCurator();
        if (pendingLimit[limit].readyAt == 0) revert InvalidConfiguration();
        delete pendingLimit[limit];
        emit LimitCancelled(limit);
    }

    /// @dev The curator's change checked against the bounds in code and the vault's universe: whether it tightens the
    /// limit (or leaves it unchanged) rather than loosening it.
    function _tightens(IntentLimit limit, uint128 value) private view returns (bool) {
        if (msg.sender != CURATOR) revert NotCurator();
        if (
            (limit == IntentLimit.MAX_LOAN_PRINCIPAL && value > MAX_PRINCIPAL)
                || (limit == IntentLimit.MIN_RATE_GRADE && value > INTENT_MAX_RATE_GRADE)
                || (limit != IntentLimit.MAX_LOAN_PRINCIPAL && value > IntentFeeMath.BPS)
                || (limit >= IntentLimit.CATEGORY_STOCK
                    && value != 0
                    && MASK & uint8(1 << (uint8(limit) - uint8(IntentLimit.CATEGORY_STOCK))) == 0)
        ) revert InvalidConfiguration();
        uint256 current = _limit(limit);
        return
            limit == IntentLimit.BUFFER_BPS || limit == IntentLimit.MIN_RATE_GRADE ? value >= current : value <= current;
    }

    /// @dev The limit's value in force, read from the vault that applies it.
    function _limit(IntentLimit limit) private view returns (uint256) {
        if (limit == IntentLimit.MAX_LOAN_PRINCIPAL) return VAULT.maxLoanPrincipal();
        if (limit == IntentLimit.MAX_ASSET_BPS) return VAULT.maxAssetBps();
        if (limit == IntentLimit.BUFFER_BPS) return VAULT.bufferBps();
        if (limit == IntentLimit.MIN_RATE_GRADE) return VAULT.minRateGrade();
        return VAULT.categoryWeightBps(IntentCategory(uint8(limit) - uint8(IntentLimit.CATEGORY_STOCK)));
    }

    function _applyLimit(IntentLimit limit, uint128 value) private {
        VAULT.applyLimit(limit, value);
        emit LimitSet(limit, value);
    }

    // ---------------------------------------------------------------- secondary policy

    /// @notice Change whether the vault buys existing lender positions and the extra annual return it asks. A change
    /// that only narrows what it may buy (disabling, or asking more) applies at once and drops any queued change; one
    /// that widens it (enabling, or asking less) waits `SECONDARY_LOOSEN_DELAY`. Every change that takes effect
    /// advances `secondaryRevision`, so plans priced on the old policy are refused. The curator only.
    function setSecondaryPolicy(bool enabled, uint16 extraBps) external {
        if (msg.sender != CURATOR) revert NotCurator();
        if (extraBps > MAX_EXTRA_ANNUAL_RETURN_BPS) revert InvalidConfiguration();
        if (enabled && (!secondaryEnabled || extraBps < minExtraAnnualReturnBps)) {
            pendingExtraBps = extraBps;
            uint256 eta = block.timestamp + SECONDARY_LOOSEN_DELAY;
            pendingReadyAt = eta;
            emit SecondaryPolicyQueued(enabled, extraBps, eta);
        } else {
            _clearPending();
            _setSecondary(enabled, extraBps);
        }
    }

    /// @notice Apply a queued loosening once its wait is over. Anyone may.
    function activateSecondaryPolicy() external {
        uint256 eta = pendingReadyAt;
        if (eta == 0 || block.timestamp < eta) revert InvalidConfiguration();
        uint16 extraBps = pendingExtraBps;
        _clearPending();
        _setSecondary(true, extraBps);
    }

    /// @notice Drop a queued loosening. The curator only.
    function cancelSecondaryPolicy() external {
        if (msg.sender != CURATOR) revert NotCurator();
        if (pendingReadyAt == 0) revert InvalidConfiguration();
        _clearPending();
        emit SecondaryPolicyCancelled();
    }

    function _setSecondary(bool enabled, uint16 extraBps) private {
        secondaryEnabled = enabled;
        minExtraAnnualReturnBps = extraBps;
        uint64 revision = ++secondaryRevision;
        emit SecondaryPolicySet(enabled, extraBps, revision);
    }

    function _clearPending() private {
        delete pendingExtraBps;
        delete pendingReadyAt;
    }

    /// @dev 0 removes; 1 queues; 2 activates; 3 cancels. Actor is authenticated by the sole caller, the vault.
    function update(address token, uint8 action, address actor) external returns (uint256 eta) {
        if (msg.sender != address(VAULT)) revert NotVault();
        if (action != 2 && actor != CURATOR) revert NotCurator();
        if (action == 0) {
            if (!picked[token]) revert InvalidConfiguration();
            picked[token] = false;
        } else if (action == 1) {
            if (picked[token] || readyAt[token] != 0) revert InvalidConfiguration();
            _eligible(token);
            eta = block.timestamp + 3 hours;
            readyAt[token] = eta;
        } else if (action == 2) {
            eta = readyAt[token];
            if (eta == 0 || block.timestamp < eta) revert InvalidConfiguration();
            _eligible(token);
            delete readyAt[token];
            picked[token] = true;
        } else if (action == 3) {
            if (readyAt[token] == 0) revert InvalidConfiguration();
            delete readyAt[token];
        } else {
            revert InvalidConfiguration();
        }
    }

    /// @notice The vault's preflight for a purchase, evaluated from its current mandate, its secondary policy and the
    /// live core. `price` zero funds the next `units` empty units of a listing; otherwise the vault buys the exact
    /// quarters `units` (a mask) of an active loan at `price` (S9). The two cannot be confused: they need disjoint core
    /// states (a zero-price buy of an active loan is refused `IneligibleDeal` below), and the verifier refuses a
    /// secondary allocation priced at zero (`ALLOCATION_CHANGED`), so the fill router never passes one.
    /// @dev Read-only separation keeps the vault deployable; no caller-supplied policy or cached state is trusted.
    /// Funding: zero units select no slot and more units than the empty slots leave some unselected, both refused
    /// below; the core lists at least `UNITS` raw units of principal, so every selected slot carries principal.
    /// Buying: what the quarters repay beyond their price is the purchase's gross return. The execution fee is held to
    /// the vault's ceiling on it and must leave the curator's extra annual return on the price over the time left
    /// (after execution costs, before the manager fee, D7); the model's own requirement is the signed plan's, checked
    /// by the verifier. Caps are measured on the larger of the price and the principal the quarters represent, so a
    /// discount never widens them and a premium never hides cash (proposed S9-01 rule); the position is booked, and
    /// priced, at its price. Both kinds measure the category and per-token caps on the assets left after the purchase's
    /// execution fee, the vault's assets once it has paid (Pashov M-24). Neither may book more interest than its
    /// principal, the price for a bought position: a larger gross return is refused `IneligibleDeal` (Pashov L-04).
    function quote(uint256 id, uint8 units, uint256 price, uint256 executionFee)
        external
        view
        returns (uint256 principal, uint256 interest, IntentCategory lane, address token, uint8 slots)
    {
        V2Loan memory l = CORE.getLoan(id);
        (, IntentCategory heldLane,,, bool withdrawn, bool settled,,,, uint128 held,,,,,,) = VAULT.loans(id);
        uint256 gross;
        uint256 exposure;
        uint256 minimum;
        if (price == 0) {
            if (held != 0 && (settled || withdrawn)) revert IneligibleDeal();
            if (
                l.state != V2State.FUNDING || l.term > VAULT.MAX_TERM() || l.originator == address(VAULT)
                    || l.originator == CURATOR || block.timestamp >= l.fundingDeadline || l.kind != Kind.ERC20
            ) revert IneligibleDeal();
            address[4] memory lenders = CORE.lenders(id);
            uint8 remaining = units;
            for (uint8 i; i < 4 && remaining != 0; ++i) {
                if (lenders[i] != address(0)) continue;
                slots |= uint8(1 << i);
                --remaining;
            }
            if (remaining != 0 || slots == 0) revert IneligibleDeal();
            principal = repayment(l.principal, slots);
            gross = repayment(l.cap, slots) - principal;
            exposure = principal;
        } else {
            if (!secondaryEnabled) revert SecondaryClosed();
            if (held != 0) revert ExistingRecord();
            uint256 maturity = uint256(l.fundedAt) + l.term;
            if (
                l.state != V2State.ACTIVE || block.timestamp >= maturity
                    || maturity - block.timestamp > VAULT.MAX_TERM() || l.originator == address(VAULT)
                    || l.originator == CURATOR || l.kind != Kind.ERC20 || units == 0 || units > 15
            ) revert IneligibleDeal();
            (slots, principal) = (units, price);
            uint256 owed = repayment(l.cap, slots);
            if (owed <= price) revert BelowReturnFloor();
            gross = owed - price;
            exposure = Math.max(price, repayment(l.principal, slots));
            minimum = IntentFeeMath.secondaryMinimum(price, minExtraAnnualReturnBps, maturity - block.timestamp);
        }
        // Pashov L-04: a purchase never books more interest than its principal, a bought position's price, so a cap
        // with no bound cannot price fictitious interest into the vault through a compromised funding path.
        if (gross > principal) revert IneligibleDeal();
        if (executionFee > IntentFeeMath.executionCap(gross, VAULT.executionCapBps())) revert LimitExceeded();
        uint256 kept = gross - executionFee;
        if (kept < minimum) revert BelowReturnFloor();
        // The active token, its registry category and the current grade floor are rechecked at every purchase. The
        // rate grade selects new loans only; a bought position answers to the model and the curator's floor.
        token = l.token;
        if (!picked[token]) revert IneligibleDeal();
        uint8 category = SOURCE.eligibleCategory(token, MASK);
        if (category > uint8(type(IntentCategory).max)) revert IneligibleDeal();
        lane = IntentCategory(category);
        uint8 grade = VAULT.minGrade();
        if (grade != 0 && GRADES.gradeOf(token) < grade) revert IneligibleDeal();
        uint8 rateGrade = price == 0 ? VAULT.minRateGrade() : 0;
        if (rateGrade != 0) {
            uint256 modeled = GRADES.modeledCostOf(token, l.term);
            if (modeled == 0 || kept < IntentFeeMath.minimumInterest(principal, modeled, rateGrade)) {
                revert IneligibleDeal();
            }
        }
        if ((held != 0 && lane != heldLane) || held + exposure > VAULT.maxLoanPrincipal()) revert IneligibleDeal();
        // The fee leaves priced assets while the whole principal is booked: the caps must hold after it (Pashov M-24).
        uint256 assets = VAULT.totalAssets() - executionFee;
        if (
            VAULT.categoryPrincipal(lane) + exposure > Math.mulDiv(VAULT.categoryWeightBps(lane), assets, 10_000)
                || VAULT.assetPrincipal(token) + exposure > Math.mulDiv(VAULT.maxAssetBps(), assets, 10_000)
        ) revert IneligibleDeal();
        interest = gross - IntentFeeMath.performanceFee(gross, executionFee, VAULT.feeBps());
    }

    /// @notice Exact repayment for the core's selected quarters, including its raw-unit rounding.
    function repayment(uint128 cap, uint8 slots) public pure returns (uint256 amount) {
        for (uint8 i; i < 4; ++i) {
            if (slots & (1 << i) != 0) amount += unitSlice(cap, i);
        }
    }

    function _eligible(address token) private view {
        if (SOURCE.eligibleCategory(token, MASK) > uint8(type(IntentCategory).max)) revert InvalidConfiguration();
    }
}
