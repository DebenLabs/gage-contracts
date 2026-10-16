// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDealRewards} from "../interfaces/token/IDealRewards.sol";
import {IDealVault, Deal, DealState} from "../interfaces/IDealVault.sol";
import {IEmissions} from "../interfaces/token/IEmissions.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";

/// @title DealRewards
/// @notice Every funded deal earns sGAGE for both parties: fee paid × the epoch's rate for the term, capped at 80% of
///         the fee valued at the epoch's posted price (so a self-dealt wash is a guaranteed loss), reserved from the
///         epoch's term budget in registration order, and granted as two drips over the deal's term (T4).
/// @dev Registration is permissionless. The app calls it right after `accept`; the keeper backstops within the hour.
///      The Safe posts rates per epoch; unset epochs carry the latest posted rates forward.
contract DealRewards is IDealRewards, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IDealVault public immutable VAULT;
    IEmissions public immutable EMISSIONS;
    IDrip public immutable DRIP;
    IERC20 public immutable SGAGE;
    /// @notice Raw units in one USDG. Rates are sGAGE per one USDG of fee.
    uint256 public immutable USDG_UNIT;
    uint16 public constant MAX_REWARD_SHARE_BPS = 8000;

    struct Registration {
        uint128 total;
        uint128 lenderAmount;
        uint128 borrowerAmount;
        bool registered;
    }

    mapping(uint256 epoch => EpochRates) internal _rates;
    uint256[] internal _ratedEpochs;
    mapping(uint256 dealId => Registration) internal _regs;

    constructor(
        IDealVault vault,
        IEmissions emissions,
        IDrip drip,
        IERC20 sgage,
        uint8 usdgDecimals,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            address(vault) == address(0) || address(emissions) == address(0) || address(drip) == address(0)
                || address(sgage) == address(0)
        ) revert ZeroAddress();
        VAULT = vault;
        EMISSIONS = emissions;
        DRIP = drip;
        SGAGE = sgage;
        USDG_UNIT = 10 ** usdgDecimals;
    }

    // ----------------------------------------------------------------- registration

    /// @inheritdoc IDealRewards
    function register(uint256 dealId) external nonReentrant {
        if (_regs[dealId].registered) revert AlreadyRegistered(dealId);
        Deal memory d = VAULT.getDeal(dealId);
        if (d.state != DealState.FUNDED && d.state != DealState.RECLAIMED && d.state != DealState.CLAIMED) {
            revert DealNotFunded(dealId);
        }
        uint40 launchAt = EMISSIONS.launchAt();
        uint256 epoch = EMISSIONS.epochOf(d.fundedAt); // reverts NotLaunched before launch; epoch 0 for earlier deals

        if (epoch < EMISSIONS.WEEKS() && !EMISSIONS.released(epoch)) EMISSIONS.release(epoch);
        (uint128 reward, bool exhausted) = _reward(epoch, d.term, d.fee);
        EpochRates memory r = effectiveRates(epoch);
        uint128 lenderAmount = uint128((uint256(reward) * r.lenderShareBps) / 10_000);
        uint128 borrowerAmount = reward - lenderAmount;
        _regs[dealId] =
            Registration({total: reward, lenderAmount: lenderAmount, borrowerAmount: borrowerAmount, registered: true});

        if (reward > 0) {
            EMISSIONS.reserve(epoch, d.term, reward, address(this));
            SGAGE.forceApprove(address(DRIP), reward);
            uint40 start = d.fundedAt < launchAt ? launchAt : d.fundedAt;
            if (lenderAmount > 0) DRIP.grant(d.lender, dripIdOf(dealId, d.lender), lenderAmount, start, d.term);
            if (borrowerAmount > 0) {
                DRIP.grant(d.borrower, dripIdOf(dealId, d.borrower), borrowerAmount, start, d.term);
            }
        }
        emit Registered(dealId, epoch, d.term, d.fee, reward, lenderAmount, borrowerAmount, exhausted);
    }

    // ----------------------------------------------------------------- owner

    /// @inheritdoc IDealRewards
    function setEpochRates(
        uint256 epoch,
        uint128 rate7,
        uint128 rate21,
        uint128 priceUSDGPerSGAGE,
        uint16 lenderShareBps
    ) external onlyOwner {
        if (priceUSDGPerSGAGE == 0 || lenderShareBps > 10_000) revert InvalidRates();
        if (EMISSIONS.launchAt() != 0 && epoch < EMISSIONS.currentEpoch()) revert RatesForPastEpoch(epoch);
        if (!_rates[epoch].set) _ratedEpochs.push(epoch);
        _rates[epoch] = EpochRates({
            rate7: rate7,
            rate21: rate21,
            priceUSDGPerSGAGE: priceUSDGPerSGAGE,
            lenderShareBps: lenderShareBps,
            set: true
        });
        emit RatesSet(epoch, rate7, rate21, priceUSDGPerSGAGE, lenderShareBps);
    }

    // ----------------------------------------------------------------- views

    function registered(uint256 dealId) external view returns (bool) {
        return _regs[dealId].registered;
    }

    function rewardOf(uint256 dealId)
        external
        view
        returns (uint128 total, uint128 lenderAmount, uint128 borrowerAmount)
    {
        Registration storage r = _regs[dealId];
        return (r.total, r.lenderAmount, r.borrowerAmount);
    }

    function dripIdOf(uint256 dealId, address party) public pure returns (bytes32) {
        return keccak256(abi.encode("deal", dealId, party));
    }

    /// @inheritdoc IDealRewards
    function quote(uint32 term, uint128 fee)
        external
        view
        returns (uint128 reward, uint256 epoch, bool budgetAvailable, uint256 budgetRemaining)
    {
        if (EMISSIONS.launchAt() == 0 || block.timestamp < EMISSIONS.launchAt()) return (0, 0, false, 0);
        epoch = EMISSIONS.currentEpoch();
        if (epoch >= EMISSIONS.WEEKS()) return (0, epoch, false, 0);
        budgetRemaining = EMISSIONS.remaining(epoch, term);
        bool exhausted;
        (reward, exhausted) = _reward(epoch, term, fee);
        budgetAvailable = reward > 0 && !exhausted;
    }

    function epochRates(uint256 epoch) external view returns (EpochRates memory) {
        return _rates[epoch];
    }

    /// @inheritdoc IDealRewards
    function effectiveRates(uint256 epoch) public view returns (EpochRates memory r) {
        if (_rates[epoch].set) return _rates[epoch];
        uint256 best;
        bool found;
        for (uint256 i = 0; i < _ratedEpochs.length; ++i) {
            uint256 e = _ratedEpochs[i];
            if (e < epoch && (!found || e > best)) {
                best = e;
                found = true;
            }
        }
        if (found) return _rates[best];
    }

    // ----------------------------------------------------------------- internal

    /// @dev fee × rate, capped at MAX_REWARD_SHARE_BPS of the fee valued at the posted price, capped at what the
    ///      epoch's term budget still holds. `exhausted` is true when the budget, not the rate, set the amount.
    function _reward(uint256 epoch, uint32 term, uint128 fee) internal view returns (uint128 reward, bool exhausted) {
        if (fee == 0 || epoch >= EMISSIONS.WEEKS()) return (0, true);
        EpochRates memory r = effectiveRates(epoch);
        if (!r.set) return (0, true);
        uint128 rate = _bucket(term) == 21 days ? r.rate21 : r.rate7;
        uint256 raw = (uint256(fee) * rate) / USDG_UNIT;
        uint256 cap = (uint256(fee) * 1e18 * MAX_REWARD_SHARE_BPS) / 10_000 / r.priceUSDGPerSGAGE;
        uint256 amount = raw < cap ? raw : cap;
        if (amount == 0) return (0, false);

        if (EMISSIONS.rolledOver(epoch)) return (0, true);
        uint256 left = EMISSIONS.remaining(epoch, term);
        if (amount > left) {
            amount = left;
            exhausted = true;
        }
        reward = uint128(amount);
    }

    function _bucket(uint32 term) internal pure returns (uint32) {
        return term >= 21 days ? 21 days : 7 days;
    }
}
