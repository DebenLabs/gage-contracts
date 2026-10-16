// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V3CollateralRegistry} from "../V3CollateralRegistry.sol";

/// @notice V2 admission and bounded terms; existing loans retain their recorded economics.
contract GageV2Registry is V3CollateralRegistry {
    uint16 public constant MAX_TRADE_FEE_BPS = 200;
    uint128 public constant MAX_REWARD_RATE = 1e30;
    uint256 public constant MAX_REWARD_PER_LOAN = 5_000_000_000e18;
    uint16 public constant REWARD_VALUE_CAP_BPS = 8000;
    uint16 public tradeFeeBps = 100;
    /// @notice Additional range requirement for an exact v4 pool ID or left-padded v3 pool address.
    mapping(bytes32 pool => bool) public poolInRangeRequired;

    struct RewardTerms {
        uint128 rate;
        uint128 referencePrice;
        uint16 lenderShareBps;
    }

    mapping(uint32 term => RewardTerms) public rewardTerms;

    error InvalidRewardTerms();
    error InvalidTradeFee();

    event RewardTermsSet(uint32 indexed term, uint128 rate, uint128 referencePrice, uint16 lenderShareBps);
    event TradeFeeSet(uint16 feeBps);
    event PoolRangeRequirementSet(bytes32 indexed pool, bool required);

    constructor(address admin, uint32[] memory terms, address factory)
        V3CollateralRegistry(admin, terms, 100, factory)
    {}

    /// @notice Preserve an exact market's deposit range policy when legacy registries are consolidated.
    function setPoolInRangeRequired(bytes32 pool, bool required) external onlyOwner {
        poolInRangeRequired[pool] = required;
        emit PoolRangeRequirementSet(pool, required);
    }

    /// @notice Change fees for subsequently posted sale asks, within a fixed bound.
    function setTradeFee(uint16 bps) external onlyOwner {
        if (bps > MAX_TRADE_FEE_BPS) revert InvalidTradeFee();
        tradeFeeBps = bps;
        emit TradeFeeSet(bps);
    }

    /// @notice Set future listings' reward terms. The reference price is not an execution-price guarantee.
    function setRewardTerms(uint32 term, uint128 rate, uint128 referencePrice, uint16 lenderShareBps)
        external
        onlyOwner
    {
        if (!_termAllowed[term] || rate > MAX_REWARD_RATE || referencePrice == 0 || lenderShareBps > 10_000) {
            revert InvalidRewardTerms();
        }
        rewardTerms[term] = RewardTerms(rate, referencePrice, lenderShareBps);
        emit RewardTermsSet(term, rate, referencePrice, lenderShareBps);
    }

    /// @notice Quote one reward allocation from a six-decimal USDG fee.
    function quoteRewards(uint32 term, uint128 fee) external view returns (uint128 borrower, uint128 lender) {
        RewardTerms memory r = rewardTerms[term];
        if (r.rate == 0 || r.referencePrice == 0) return (0, 0);
        uint256 amount = Math.min(
            Math.mulDiv(fee, r.rate, 1e6),
            Math.mulDiv(uint256(fee) * 1e18, REWARD_VALUE_CAP_BPS, uint256(r.referencePrice) * 10_000)
        );
        amount = Math.min(amount, MAX_REWARD_PER_LOAN);
        lender = uint128(Math.mulDiv(amount, r.lenderShareBps, 10_000));
        borrower = uint128(amount - lender);
    }
}
