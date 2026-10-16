// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The one integer fee calculation for Intent fills: the formulas of docs/intent-v1/FEE-MATH.md. Their
/// composition into one fill's parts (manager net fee, depositor interest) is booked by the vault itself, and a
/// test reference replays it (test/intent/IntentFeeBreakdown.sol).
/// @dev Raw USDG units and basis points throughout. The two minimums, `minimumInterest` and `secondaryMinimum`, round
/// up to the next raw unit, toward the vault; every fee calculation (`executionCap`, `executionFee`, `performanceFee`
/// and the protocol's part of a fee) rounds down. An integrator reproduces these functions themselves, which are the
/// reference, not a reading of this comment (Pashov I-02). The vault books fees with `performanceFee`, takes the
/// protocol's part of each as `fee * PROTOCOL_SHARE_BPS / BPS`, and holds every purchase to `executionCap` and
/// `minimum`; the quote verifier and the quote service size the execution fee with `executionFee`. No launch value is
/// chosen here: the ceiling a vault's manager sets and the rate grade it asks for are inputs, and only their outer
/// bounds are constants.
/// The version of this calculation a signed plan names is the quote verifier's `FEE_POLICY_VERSION`, and
/// `SECONDARY_POLICY_VERSION` for `secondaryMinimum`: a change to any formula here must bump it there.
library IntentFeeMath {
    uint256 internal constant BPS = 10_000;
    /// @notice No vault may let execution take more than this share of a purchase's interest.
    /// @dev Provisional outer bound for the S3 candidate; the launch bound is an open product choice.
    uint16 internal constant MAX_EXECUTION_CAP_BPS = 5000;
    /// @notice The protocol's part of every performance fee (D17); the manager keeps the rest and the rounding.
    uint256 internal constant PROTOCOL_SHARE_BPS = 1000;

    /// @notice The share of the modeled cost a purchase must keep per rate grade: none 0, D 50%, C 75%, B 90%, A 100%.
    function floorPct(uint256 rank) internal pure returns (uint256) {
        if (rank == 0) return 0;
        if (rank == 1) return 50;
        if (rank == 2) return 75;
        if (rank == 3) return 90;
        return 100;
    }

    /// @notice The interest a purchase of `principal` must keep after execution costs and before the manager fee
    /// (D7): its rate grade's share of the modeled cost `costBps`, rounded up to the next raw unit.
    function minimumInterest(uint256 principal, uint256 costBps, uint256 rank) internal pure returns (uint256) {
        return (principal * costBps * floorPct(rank) + (BPS * 100 - 1)) / (BPS * 100);
    }

    /// @notice The least USDG a secondary purchase at `price` must keep after execution costs and before the manager
    /// fee (D7): `annualBps` a year of 365 days on the price over the `remaining` seconds to the loan's own maturity,
    /// rounded up to the next raw unit. The price is the purchase's principal, as a new loan's principal is for
    /// `minimumInterest`.
    function secondaryMinimum(uint256 price, uint256 annualBps, uint256 remaining) internal pure returns (uint256) {
        return (price * annualBps * remaining + (BPS * 365 days - 1)) / (BPS * 365 days);
    }

    /// @notice The most the execution fee may be: a share `capBps` of the contribution's contractual interest.
    function executionCap(uint256 gross, uint256 capBps) internal pure returns (uint256) {
        return gross * capBps / BPS;
    }

    /// @notice The execution fee for a contribution earning `gross`, where `minimum` must remain after it and
    /// before the manager fee (D7): the cap, or whatever the minimum leaves if that is less.
    /// @return ok False when even a zero fee leaves less than the minimum; the fill is refused.
    function executionFee(uint256 gross, uint256 minimum, uint256 capBps) internal pure returns (bool ok, uint256 fee) {
        if (gross < minimum) return (false, 0);
        return (true, Math.min(executionCap(gross, capBps), gross - minimum));
    }

    /// @notice The whole performance-fee deduction, charged on interest after execution costs (D8).
    function performanceFee(uint256 gross, uint256 executionFee_, uint256 managerBps) internal pure returns (uint256) {
        return (gross - executionFee_) * managerBps / BPS;
    }
}
