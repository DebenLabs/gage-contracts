// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Product risk classes. These indices are distinct from legacy EarnLane and core Lane.
/// @dev Two universes (D33, D41): real-world assets are `STOCK` and `COMMODITY`, the Robinhood ecosystem is `MEME`
/// and `RH_ECOSYSTEM` (utility coins). A vault lends against one universe. New classes are appended so existing
/// indices keep their meaning.
enum IntentCategory {
    STOCK,
    MEME,
    RH_ECOSYSTEM,
    COMMODITY
}

/// @notice A vault's adjustable risk limits (Intent D53). The manager moves each one in the vault's asset policy:
/// tightening applies at once, loosening waits three hours, so depositors see a riskier mandate coming before it applies.
/// @dev Tighter is lower for the caps (`MAX_LOAN_PRINCIPAL`, `MAX_ASSET_BPS`, the four category weights) and higher for
/// the floors (`BUFFER_BPS`, `MIN_RATE_GRADE`). A category weight is `CATEGORY_STOCK + uint8(IntentCategory)`.
enum IntentLimit {
    MAX_LOAN_PRINCIPAL,
    MAX_ASSET_BPS,
    BUFFER_BPS,
    MIN_RATE_GRADE,
    CATEGORY_STOCK,
    CATEGORY_MEME,
    CATEGORY_RH_ECOSYSTEM,
    CATEGORY_COMMODITY
}

// The compile-time bound of a vault's most per loan, at creation and every later change: one billion whole units of
// its asset, given in six-decimal units (one billion USDG) and scaled by 10^(decimals - 6) where it is checked. Every
// other limit is a share of assets (at most 100%) or a grade rank (at most A).
uint128 constant INTENT_MAX_LOAN_PRINCIPAL = 1_000_000_000e6;

// The highest Loan grade rank a vault may require of a new loan: A.
uint8 constant INTENT_MAX_RATE_GRADE = 4;
