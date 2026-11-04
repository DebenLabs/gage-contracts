// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";
import {IIntentExitDesk} from "../interfaces/IIntentExitDesk.sol";

interface IIntentShareState {
    function readAccountingSlot(uint256 slot) external view returns (uint256);
    function pockets(uint256 id) external view returns (uint256, address, uint256, uint256, uint256, uint64);
    function pocketClaimed(uint256 id, address account) external view returns (bool);
    function exposureWindow(uint256 id) external view returns (uint256);
    function VAULT() external view returns (GageV2Vault);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function performingPrincipal() external view returns (uint256);
    function paused() external view returns (bool);
    function cash() external view returns (uint256);
    function RESERVE() external view returns (address);
    function RESERVE_LENS() external view returns (address);
    function reserveShares() external view returns (uint256);
    function freeLiquidity() external view returns (uint256);
    function PROTOCOL_SOURCE() external view returns (address);
}

/// @dev The vault's factory: the first exit desk it named, bound for good (`IntentFactory.boundExitDesk`).
interface IExitDeskBinding {
    function boundExitDesk() external view returns (address);
}

/// @notice Stateless reads for the native vault, separate only to keep it below EIP-170: its ERC-4626 maxima, its
/// pocket claims, its exposure clock at a past second, its reward records and the core loan fields it uses.
/// @dev Holds no assets, shares or claims. The vault catches a failure of the maxima's reads and advertises zero
/// capacity.
contract IntentVaultViews {
    error InvalidRewardRecordCount();

    // IntentVault's original storage layout is unchanged (slot 8). These private slots are read through its read-only
    // slot accessor; the storage-layout test pins
    // each slot, and the write-off number's bits in a loan record's first word.
    uint256 internal constant HELD_SECONDS_SLOT = 8;
    uint256 internal constant LOANS_SLOT = 28;
    uint256 internal constant OPEN_LOANS_SLOT = 29;
    uint256 internal constant EXPOSURE_CLOCK_SLOT = 31;
    uint256 internal constant EXPOSURE_SLOT = 32;
    uint256 internal constant EXPOSURE_LOG_SLOT = 34;
    /// @dev IntentVault's exposure clock precision and virtual shares.
    uint256 internal constant EXPOSURE_PRECISION = 1e33;
    uint256 internal constant VIRTUAL_SHARES = 1e12;

    /// @notice Every record a share change checkpoints, including settled loans with rewards still owed.
    /// @dev Permissionless maintenance must discover this bounded set after a restart, independently of loan status.
    function rewardRecords(address vault) external view returns (uint256[] memory) {
        return _rewardRecords(IIntentShareState(vault));
    }

    function _rewardRecords(IIntentShareState v) internal view returns (uint256[] memory ids) {
        uint256 length = v.readAccountingSlot(OPEN_LOANS_SLOT);
        if (length > 64) revert InvalidRewardRecordCount();
        ids = new uint256[](length);
        uint256 base = uint256(keccak256(abi.encode(OPEN_LOANS_SLOT)));
        for (uint256 i; i < length; ++i) {
            ids[i] = v.readAccountingSlot(base + i);
        }
    }

    /// @notice The calling vault's `pocketClaimable`: what `who` may still claim from the pocket. An earnings claim
    /// splits by exposure, on the pocket plus any exit debit of its loan, the leaver's part less that debit and
    /// never below zero; a written-off loan's by design.
    /// @dev Reads the factory's bound exit desk for an earnings claim, and reverts when that desk cannot answer.
    function pocketClaimable(uint256 pocketId, address who) external view returns (uint256) {
        IIntentShareState v = IIntentShareState(msg.sender);
        (uint256 loanId,, uint256 amount, uint256 supply, uint256 claimed,) = v.pockets(pocketId);
        if (supply == 0 || v.pocketClaimed(pocketId, who)) return 0;
        uint256 w = v.exposureWindow(loanId);
        uint256 part;
        // The loan record's first slot holds its write-off number in bits 104 to 167: zero unless written off.
        if (uint64(v.readAccountingSlot(uint256(keccak256(abi.encode(loanId, LOANS_SLOT)))) >> 104) == 0) {
            // An earnings claim: by the exposure carried over the window. An exit sale's leaver pays the sale's
            // discount below what a listing starts at out of its own part: every part is of what a sale
            // at the start would have set aside, the pocket plus the debit, and the leaver's is less the debit.
            (address leaver, uint256 debit) = _exitDebit(v, loanId);
            part = Math.mulDiv(amount + debit, _exposureOf(v, who, uint104(w)) - _exposureOf(v, who, w >> 152), supply);
            if (who == leaver) part = part > debit ? part - debit : 0;
        } else {
            // A written-off loan's collateral or backing. The pocket's supply is the supply at the write-off,
            // which bore it by balance. Share moves are refused from the end of the term until then, so a holder's
            // balance at the write-off is what it held over the term's last second. Its part is its share of the loss,
            // times the part of the window it carried that balance in wall-clock seconds, never more: a share added
            // during the loan counts from its arrival, one that left counts for nothing.
            V2Loan memory l = v.VAULT().getLoan(loanId);
            uint256 end = uint256(l.fundedAt) + l.term;
            uint256 heldAtEnd = _heldAt(v, who, end);
            uint256 balance = heldAtEnd - _heldAt(v, who, end - 1);
            if (balance == 0) return 0;
            uint256 span = end - uint40(w >> 104);
            uint256 carried = heldAtEnd - _heldAt(v, who, end - span);
            part = Math.mulDiv(amount, Math.min(carried, balance * span), supply * span);
        }
        return Math.min(part, amount - claimed);
    }

    /// @dev What the exit desk the vault's factory bound charged the leaver of an exit sale of `loanId`.
    /// The bound desk, not the factory's current one: a desk closed with `setExitDesk(0)` keeps its debits. Nothing
    /// without a bound desk, since no exit listing can then have sold. Fails closed: a bound desk that does not answer
    /// reverts the claim rather than pay a leaver as if no exit had sold.
    function _exitDebit(IIntentShareState v, uint256 loanId) internal view returns (address leaver, uint256 debit) {
        address desk = IExitDeskBinding(v.PROTOCOL_SOURCE()).boundExitDesk();
        if (desk == address(0)) return (address(0), 0);
        return IIntentExitDesk(desk).exitDebit(address(v), loanId);
    }

    /// @notice What `who` has carried of holding `id`'s exposure window and the window's whole supply, both as a
    /// lender sale of the holding would close the window in this second: a sale's earnings claim splits by exactly these
    /// (`IntentVault.pockets`' supply is this `supply`), and an exit desk's floor reads them. Zero for a
    /// holding with no window, and in its purchase's second, where a sale cannot book a gain.
    /// @dev For an open window only; once a sale or a write-off closed it, only the closing second reads it again.
    /// @param vault The selling vault, an IntentVault of this generation.
    /// @param id The holding's loan.
    /// @param who The holder.
    /// @return exposure The exposure `who` carried over the window, at the clock's precision.
    /// @return supply The window's seconds at the clock's precision, less what its virtual shares carried.
    function exitShare(address vault, uint256 id, address who)
        external
        view
        returns (uint256 exposure, uint256 supply)
    {
        IIntentShareState v = IIntentShareState(vault);
        uint256 w = v.exposureWindow(id);
        uint256 openedAt = uint40(w >> 104);
        if (openedAt == 0 || block.timestamp <= openedAt) return (0, 0);
        // The clock as `_accrueExposure` would write it this second, over the shares outstanding since its last write.
        uint256 clock = v.readAccountingSlot(EXPOSURE_CLOCK_SLOT);
        uint256 closed = uint104(clock >> 40);
        uint256 at = uint40(clock >> 144);
        uint256 shares = v.totalSupply();
        if (block.timestamp > at && shares != 0) {
            closed += (block.timestamp - at) * EXPOSURE_PRECISION / (shares + VIRTUAL_SHARES);
        }
        uint256 opened = w >> 152;
        exposure = _exposureOf(v, who, closed) - _exposureOf(v, who, opened);
        supply = (block.timestamp - openedAt) * EXPOSURE_PRECISION - VIRTUAL_SHARES * (closed - opened);
    }

    /// @dev The balance-seconds `who` had carried at second `t`: its balance times the seconds held, summed over
    /// its history. Between two entries its balance was constant, so the sum grew with the time.
    function _heldAt(IIntentShareState v, address who, uint256 t) internal view returns (uint256) {
        uint256 slot = uint256(keccak256(abi.encode(who, HELD_SECONDS_SLOT)));
        uint256 length = v.readAccountingSlot(slot);
        uint256 base = uint256(keccak256(abi.encode(slot)));
        uint256 lo;
        uint256 hi = length;
        while (lo < hi) {
            uint256 mid;
            unchecked {
                mid = (lo + hi) / 2;
            }
            if (v.readAccountingSlot(base + mid) >> 216 <= t) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return 0;
        uint256 e = v.readAccountingSlot(base + lo - 1);
        uint256 from = e >> 216;
        uint256 carried = uint216(e);
        if (lo == length) return carried + v.balanceOf(who) * (t - from);
        uint256 next = v.readAccountingSlot(base + lo);
        return carried + Math.mulDiv(uint216(next) - carried, t - from, (next >> 216) - from);
    }

    function _exposureOf(IIntentShareState v, address who, uint256 index) internal view returns (uint256) {
        uint256 slot = uint256(keccak256(abi.encode(who, EXPOSURE_SLOT)));
        uint256 length = v.readAccountingSlot(slot);
        uint256 base = uint256(keccak256(abi.encode(slot)));
        uint256 lo;
        uint256 hi = length;
        while (lo < hi) {
            uint256 mid;
            unchecked {
                mid = (lo + hi) / 2;
            }
            if (v.readAccountingSlot(base + mid) >> 152 <= index) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return 0;
        uint256 e = v.readAccountingSlot(base + lo - 1);
        uint256 from = e >> 152;
        uint256 carried = uint152(e);
        if (lo == length) return carried + v.balanceOf(who) * (index - from);
        uint256 next = v.readAccountingSlot(base + lo);
        return carried + Math.mulDiv(uint152(next) - carried, index - from, (next >> 152) - from);
    }

    /// @notice The calling vault's exposure clock at a past second `t`, interpolated between its written points.
    function indexAt(uint256 t) external view returns (uint256) {
        IIntentShareState v = IIntentShareState(msg.sender);
        uint256 length = v.readAccountingSlot(EXPOSURE_LOG_SLOT);
        uint256 base = uint256(keccak256(abi.encode(EXPOSURE_LOG_SLOT)));
        uint256 lo;
        uint256 hi = length;
        while (lo < hi) {
            uint256 mid;
            unchecked {
                mid = (lo + hi) / 2;
            }
            if (v.readAccountingSlot(base + mid) >> 104 <= t) lo = mid + 1;
            else hi = mid;
        }
        uint256 previous = lo - 1;
        uint256 p = v.readAccountingSlot(base + previous);
        uint256 from = p >> 104;
        uint256 index = uint104(p);
        uint256 to;
        uint256 next;
        if (lo < length) {
            uint256 point = v.readAccountingSlot(base + lo);
            to = point >> 104;
            next = uint104(point);
        } else {
            uint256 clock = v.readAccountingSlot(EXPOSURE_CLOCK_SLOT);
            to = uint40(clock >> 144);
            next = uint104(clock >> 40);
        }
        return index + Math.mulDiv(next - index, t - from, to - from);
    }

    /// @dev Only the core fields the vault needs. Decoding the full core ABI lives in this shared read-only helper.
    struct CoreLoan {
        address account;
        address token;
        V2State state;
        uint32 term;
        uint40 fundingDeadline;
        uint40 fundedAt;
        uint40 closedAt;
        uint128 cap;
        uint256 collateral;
    }

    /// @notice The fields of the core's loan `id` a vault reads.
    function coreLoan(GageV2Vault core, uint256 id) external view returns (CoreLoan memory) {
        V2Loan memory l = core.getLoan(id);
        return
            CoreLoan(
                l.account, l.token, l.state, l.term, l.fundingDeadline, l.fundedAt, l.closedAt, l.cap, l.collateral
            );
    }

    /// @notice The calling vault's ERC-4626 maximum for `selector`: supply room or the owner's balance, bounded by
    /// free liquidity, with the pause, impairment, entry-minimum, final-holder and Morpho exit-gate rules. An exit
    /// maximum that leaves shares outstanding keeps assets behind them that the reserve's rounding cannot take, so both
    /// maxima execute.
    /// @dev The reward checkpoint is not simulated. A positive maximum can still revert `RewardsPending` when a
    /// reward source cannot deliver an owed claim; the keeper's reward-maintenance health reports that case.
    function maximum(address account, bytes4 selector, uint256 assetScale) external view returns (uint256) {
        bool entry = selector == IERC4626.maxDeposit.selector || selector == IERC4626.maxMint.selector;
        (uint256 assets, uint256 shares) = _limits(msg.sender, account, entry, assetScale);
        return selector == IERC4626.maxDeposit.selector || selector == IERC4626.maxWithdraw.selector ? assets : shares;
    }

    function _limits(address vault, address account, bool entry, uint256 assetScale)
        internal
        view
        returns (uint256 assets, uint256 shares)
    {
        IIntentShareState v = IIntentShareState(vault);
        uint256 supply = v.totalSupply();
        uint256 backing = v.totalAssets();
        if ((entry && v.paused()) || (supply != 0 && backing == 0)) return (0, 0);
        uint256 numerator = backing + assetScale;
        uint256 denominator = supply + 1e12;
        if (entry) {
            shares = 1e27 - supply;
            if (shares == 0) return (0, 0);
            // Largest deposit whose floor-rounded mint does not exceed the available supply.
            assets = Math.mulDiv(shares + 1, numerator, denominator, Math.Rounding.Ceil) - 1;
            // Deposit and mint reach the entry minimum at different rounding boundaries.
            if (assets < 1e6 * assetScale) assets = 0;
            if (Math.mulDiv(shares, numerator, denominator, Math.Rounding.Ceil) < 1e6 * assetScale) shares = 0;
        } else {
            shares = v.balanceOf(account);
            if (shares == supply && shares != 0 && v.performingPrincipal() != 0) --shares;
            uint256 liquid = v.freeLiquidity();
            // The Morpho lens counts admitted adapter liquidity. Its reserve's withdrawal gates are independent.
            // An unknown lens-backed reserve is conservatively limited to cash unless both gates confirm payment.
            if (v.RESERVE_LENS() != address(0)) {
                address reserve = v.RESERVE();
                if (
                    !_allows(reserve, IMorphoShareGates.canSendShares.selector, vault)
                        || !_allows(reserve, IMorphoShareGates.canReceiveAssets.selector, vault)
                ) liquid = v.cash();
            }
            uint256 held = shares;
            // Never more than the vault holds, as `redeem` and `previewRedeem` pay; `convertToAssets` keeps
            // the plain rate.
            assets = Math.min(liquid, Math.min(backing, Math.mulDiv(shares, numerator, denominator)));
            // An exit that would take every asset while shares stay keeps one raw unit behind them.
            if (
                assets != 0 && assets >= backing
                    && Math.mulDiv(assets, denominator, numerator, Math.Rounding.Ceil) < supply
            ) --assets;
            // One the reserve pays in part keeps a reserve share's worth more, rounded up, when either maximum leaves
            // shares: the reserve rounds the shares its withdrawal burns up and the value of the rest down, which can
            // take up to that much beyond the exit and leave the shares that stay over nothing. A share is
            // worth less than `(backing + 1) / reserveShares` raw units, so a larger remainder needs no read; otherwise
            // its worth is read as the vault prices the reserve, `convertToAssets`, so no other read can fail the maxima.
            if (
                assets > v.cash()
                    && (Math.mulDiv(assets, denominator, numerator, Math.Rounding.Ceil) < supply
                        || Math.mulDiv(assets + 1, denominator, numerator, Math.Rounding.Ceil) - 1 < supply)
                    && backing - assets < 2 + (backing + 1) / v.reserveShares()
            ) {
                uint256 keep = 2 + IERC4626(v.RESERVE()).convertToAssets(1);
                if (backing - assets < keep) assets = backing > keep ? backing - keep : 0;
            }
            // Redeem rounds assets down, so it can burn more shares than withdraw(assets): at most the shares whose
            // redemption pays the assets maximum, which keeps the same behind the shares that stay.
            shares = Math.min(shares, Math.mulDiv(assets + 1, denominator, numerator, Math.Rounding.Ceil) - 1);
            // A sole holder with every asset free redeems every share: together they are worth what the vault holds.
            if (held == supply && liquid >= backing) shares = held;
        }
    }

    function _allows(address reserve, bytes4 selector, address account) internal view returns (bool) {
        (bool ok, bytes memory result) = reserve.staticcall(abi.encodeWithSelector(selector, account));
        return ok && result.length == 32 && uint256(bytes32(result)) == 1;
    }
}

interface IMorphoShareGates {
    function canSendShares(address account) external view returns (bool);
    function canReceiveAssets(address account) external view returns (bool);
}
