// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Kind} from "../types/Types.sol";

enum V2State {
    NONE,
    FUNDING,
    ACTIVE,
    REPAID,
    DEFAULTED,
    CANCELLED
}

struct V2Loan {
    address originator;
    address account;
    address token;
    address collateralBeneficiary;
    Kind kind;
    V2State state;
    uint8 filled;
    uint32 term;
    uint40 fundingDeadline;
    uint40 fundedAt;
    uint40 closedAt;
    uint128 principal;
    uint128 cap;
    uint128 originationFee;
    uint128 borrowerReward;
    uint128 lenderReward;
    uint256 collateral;
    bytes32 exposureKey;
    uint256 exposureAmount;
}

struct V2Ask {
    uint128 price;
    uint40 deadline;
    uint16 feeBps;
    uint256 nonce;
}

/// @dev The low four bits identify exact lending quarters; the price buys the complete selected bundle. `seller` is
/// kept deliberately although nothing on chain reads it (every reader names the seller itself): it is part of the
/// `getLenderAsk` return layout that the market, the keeper and the valuation service decode, and it shares a slot
/// with `slots`.
struct V2LenderAsk {
    address seller;
    uint8 slots;
    uint128 price;
    uint40 deadline;
    uint16 feeBps;
    uint256 nonce;
}

/// @dev One ask bought once and delivered quarter by quarter (S9). `recipients[i]` receives quarter i of `slots`;
/// entries outside `slots` are ignored. `minRewards[i]` bounds quarter i's remaining future reward.
struct V2LenderSplit {
    address seller;
    uint8 slots;
    uint128 price;
    uint16 maxFeeBps;
    uint256 nonce;
    address[4] recipients;
    uint128[4] minRewards;
}

/// @dev The core's unit rounding (`GageV2Vault.UNITS` is 4), the one rule every contract uses to split an amount into
/// its four lending quarters: quarter `i` takes `total / 4`, plus one raw unit while `i < total % 4`, so the first
/// quarters take the remainder and the four slices always sum to `total`.
function unitSlice(uint256 total, uint8 i) pure returns (uint256) {
    return total / 4 + (i < total % 4 ? 1 : 0);
}
