// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFunderGate} from "../interfaces/IFunderGate.sol";
import {GageV2Vault} from "./GageV2Vault.sol";
import {GageLegacyAdapter} from "./GageLegacyAdapter.sol";
import {unitSlice} from "./V2Types.sol";

/// @notice V2 rewards, separately funded or backed by a legacy grant through `BRIDGE`; immutable vault callbacks only
/// perform accounting, never token transfers.
/// @dev Bridged, the ledger takes no donations and has no free budget of its own: each loan's allocation is the
/// adapter's record of it, which the core opens in the same call that activates the loan, and each claim is paid
/// through `BRIDGE.pay`. Closing only updates accounting, so neither sGAGE transfers nor harvesting can block a
/// repayment.
contract GageV2Rewards is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable VAULT;
    IERC20 public immutable SGAGE;
    /// @notice The legacy adapter whose grants back this ledger's allocations, or zero for a separately funded ledger.
    GageLegacyAdapter public immutable BRIDGE;

    struct Allocation {
        address borrower;
        uint40 start;
        uint40 end;
        uint32 term;
        uint128 borrowerTotal;
        uint128 lenderTotal;
        uint128 borrowerAccounted;
        address[4] lenders;
    }

    mapping(uint256 => Allocation) private _allocations;
    /// @dev Earned borrower and lender rewards checkpointed per account; claimable adds the live accrual.
    mapping(uint256 => mapping(address => uint256)) private _earned;
    mapping(uint256 => uint128[4]) private _lenderAccounted;
    mapping(uint256 => mapping(address => uint256)) private _claimed;
    /// @notice sGAGE available to future activations. The ledger's outstanding reward liability is its balance less
    /// this, donations aside; a bridged ledger has no budget of its own, so it stays zero there.
    uint256 public freeBudget;
    /// @notice Once bound, the only accounts that take lender quarters on this ledger's engine, by funding a listing or
    /// by buying a listed position. Zero until the engine's registry owner binds it, once and for good; unbound, no
    /// account lends (D47).
    IFunderGate public funderGate;

    error InsufficientBudget();
    error NothingToClaim();
    error InvalidTransfer();
    /// @notice The caller is not the core, for its callbacks; or, for `bindFunderGate`, not the registry owner, a
    /// second binding, or a gate without code.
    error NotAuthorized();
    /// @notice Same selector as the engine's own: its registry pauses new deals.
    error Paused();
    /// @notice The engine is bound to a funder gate that does not name this account.
    error NotFunder();

    event Funded(address indexed funder, uint256 amount);
    event Claimed(uint256 indexed id, address indexed account, address indexed recipient, uint256 amount);
    event FunderGateBound(address indexed gate);

    constructor(IERC20 sgage, GageLegacyAdapter bridge) {
        VAULT = msg.sender;
        SGAGE = sgage;
        BRIDGE = bridge;
    }

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotAuthorized();
        _;
    }

    /// @notice Open lending on this engine to the gate's accounts, and only to them, for good: the engine's registry
    /// owner only, once, and only a contract. Until then the engine lends to no one (D47).
    /// @dev The engine's `REGISTRY()` is the one view this ledger reads from its engine: the registry that pauses
    /// funding and whose owner binds the gate.
    function bindFunderGate(IFunderGate gate) external {
        if (
            msg.sender != GageV2Vault(VAULT).REGISTRY().owner() || address(funderGate) != address(0)
                || address(gate).code.length == 0
        ) revert NotAuthorized();
        funderGate = gate;
        emit FunderGateBound(address(gate));
    }

    /// @notice The engine's precondition for every funding: `Paused` while its registry pauses new deals, then
    /// `requireFunder(lender)`.
    function requireFunding(address lender) external view {
        if (GageV2Vault(VAULT).REGISTRY().newDealsPaused()) revert Paused();
        requireFunder(lender);
    }

    /// @notice Revert `NotFunder` unless `account` may take a lender quarter: no account while no gate is bound (D47),
    /// afterwards only one the gate names. Funding asks it through `requireFunding`; purchases are checked quarter by
    /// quarter here.
    function requireFunder(address account) public view {
        IFunderGate gate = funderGate;
        if (address(gate) == address(0) || !gate.isVault(account)) revert NotFunder();
    }

    /// @notice Irrevocably add separately sourced sGAGE to the free reward budget. A bridged ledger refuses every
    /// donation: they must use the source's recycling path, and this ledger cannot invent a new allocation.
    /// @dev `SGAGE` is the protocol's plain ERC-20 (no transfer fee or hook), so the amount pulled is the amount held.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0 || address(BRIDGE) != address(0)) revert InvalidTransfer();
        SGAGE.safeTransferFrom(msg.sender, address(this), amount);
        freeBudget += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Reserve a fully backed allocation exactly when the fourth lender unit activates a loan.
    /// @dev The ledger does not re-check its immutable core's state machine: the core calls this once per loan, in the
    /// funding that activates it, with a nonzero borrower and a term its registry allows. Bridged, the allocation is
    /// the adapter's own: `GageV2Vault._activate` calls `BRIDGE.open` and then this in the same call, so the adapter's
    /// record of the loan names this ledger and this core, starts now and carries these totals.
    function activate(
        uint256 id,
        address borrower,
        address[4] calldata lenders,
        uint32 term,
        uint128 borrowerReward,
        uint128 lenderReward
    ) external onlyVault {
        uint256 total = uint256(borrowerReward) + lenderReward;
        if (address(BRIDGE) == address(0)) {
            if (total > freeBudget) revert InsufficientBudget();
            freeBudget -= total;
        }
        Allocation storage a = _allocations[id];
        a.borrower = borrower;
        a.start = uint40(block.timestamp);
        a.term = term;
        a.borrowerTotal = borrowerReward;
        a.lenderTotal = lenderReward;
        a.lenders = lenders;
    }

    /// @notice Preserve the seller's earned allocation and assign only future accrual to the buyer.
    /// @dev The core calls this only on the sale of an ACTIVE loan's right, to a nonzero buyer it has checked.
    function transferRight(uint256 id, address buyer) external onlyVault {
        Allocation storage a = _allocations[id];
        _checkpoint(id, a);
        a.borrower = buyer;
    }

    /// @notice Checkpoint the exact quarters sold; only their future accrual changes owner, quarter by quarter.
    /// @dev `recipients[i]` takes quarter i of `slots`, and is never zero, the vault or the seller; entries outside
    /// `slots` are ignored. `minRewards[i]` bounds quarter i's remaining future reward, which depends on the clock,
    /// not the owner. The vault validated the ask and its price.
    function transferLenders(
        uint256 id,
        address seller,
        uint8 slots,
        address[4] calldata recipients,
        uint128[4] calldata minRewards
    ) external onlyVault {
        Allocation storage a = _allocations[id];
        if (a.start == 0 || a.end != 0 || slots == 0 || slots > 15) revert InvalidTransfer();
        uint256 earned = _curve(a.lenderTotal, a);
        for (uint8 i; i < 4; ++i) {
            if (slots & (1 << i) == 0) continue;
            address buyer = recipients[i];
            if (buyer == address(0) || buyer == VAULT || buyer == seller || a.lenders[i] != seller) {
                revert InvalidTransfer();
            }
            requireFunder(buyer);
            uint256 slice = unitSlice(earned, i);
            if (unitSlice(a.lenderTotal, i) - slice < minRewards[i]) revert InvalidTransfer();
            _earned[id][seller] += slice - _lenderAccounted[id][i];
            _lenderAccounted[id][i] = uint128(slice);
            a.lenders[i] = buyer;
        }
    }

    /// @notice Freeze the original quadratic clock and recycle its unearned portion, without any token call.
    /// @dev The core calls this once per ACTIVE loan, at its repayment or its default finalization. Bridged, the core
    /// closes the adapter loan first in the same call (`BRIDGE.repay` or `BRIDGE.finalizeDefault`), so both clocks stop
    /// in the same second, and the unearned portion is not freed here: future drips are not liquid today, and the
    /// source exposes only harvested surplus as reusable.
    function close(uint256 id) external onlyVault {
        Allocation storage a = _allocations[id];
        a.end = uint40(block.timestamp);
        _checkpoint(id, a);
        uint256 recycled =
            uint256(a.borrowerTotal) + a.lenderTotal - _curve(a.borrowerTotal, a) - _curve(a.lenderTotal, a);
        if (address(BRIDGE) == address(0)) freeBudget += recycled;
    }

    /// @notice Withdraw the caller's earned rewards to a chosen recipient. Rewards are pulled only by their owner.
    /// @dev Bridged, the adapter delivers the claim first and may pay less while its source awaits an unlock; the
    /// loan's adapter id is write-once (`adapterId`), so it names the same source record at every claim.
    function claim(uint256 id, address recipient) external nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidTransfer();
        uint256 amount = claimable(id, msg.sender);
        if (amount != 0 && address(BRIDGE) != address(0)) amount = BRIDGE.pay(BRIDGE.adapterId(VAULT, id), amount);
        if (amount == 0) revert NothingToClaim();
        _claimed[id][msg.sender] += amount;
        SGAGE.safeTransfer(recipient, amount);
        emit Claimed(id, msg.sender, recipient, amount);
    }

    /// @notice Complete reward snapshot for indexers and claim previews.
    function allocation(uint256 id) external view returns (Allocation memory) {
        return _allocations[id];
    }

    /// @notice Earned borrower plus lender rewards, less this account's previous withdrawals.
    function claimable(uint256 id, address account) public view returns (uint256) {
        Allocation storage a = _allocations[id];
        if (a.start == 0 || account == address(0)) return 0;
        uint256 earned = _earned[id][account];
        if (a.end == 0 && a.borrower == account) earned += _curve(a.borrowerTotal, a) - a.borrowerAccounted;
        uint256 lender = _curve(a.lenderTotal, a);
        for (uint8 i; i < 4; ++i) {
            if (a.lenders[i] == account) earned += unitSlice(lender, i) - _lenderAccounted[id][i];
        }
        return earned - _claimed[id][account];
    }

    function _checkpoint(uint256 id, Allocation storage a) private {
        uint256 earned = _curve(a.borrowerTotal, a);
        _earned[id][a.borrower] += earned - a.borrowerAccounted;
        a.borrowerAccounted = uint128(earned);
    }

    function _curve(uint256 amount, Allocation storage a) private view returns (uint256) {
        uint256 elapsed = Math.min((a.end == 0 ? block.timestamp : a.end) - a.start, a.term);
        return Math.mulDiv(amount, elapsed * elapsed, uint256(a.term) * a.term);
    }
}
