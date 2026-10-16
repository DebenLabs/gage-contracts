// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICollateralRegistry, Lane} from "../interfaces/ICollateralRegistry.sol";

/// @notice Admission, bounded terms and fees for a token-only V2 core; existing loans retain their recorded economics.
/// @dev Standalone: it keeps exactly the settings a token-only core, its ledger and routers read, with the
///      bounds, errors and events of `GageV2Registry`. It has no pool, removal-hook, range, meme-pair or v3-pool
///      settings. `GageV2Registry` (with `V3CollateralRegistry` and `CollateralRegistry`) stays the source of the live
///      position-capable engines and of `TestnetV2Registry`.
contract GageV2TokenRegistry is Ownable2Step {
    uint16 public constant MAX_FEE_BPS = 200;
    uint32 public constant MIN_TERM = 1 days;
    uint32 public constant MAX_TERM = 30 days;
    uint256 public constant MAX_TERMS = 8;
    uint16 public constant MAX_TRADE_FEE_BPS = 200;
    uint128 public constant MAX_REWARD_RATE = 1e30;
    uint256 public constant MAX_REWARD_PER_LOAN = 5_000_000_000e18;
    uint16 public constant REWARD_VALUE_CAP_BPS = 8000;

    struct RewardTerms {
        uint128 rate;
        uint128 referencePrice;
        uint16 lenderShareBps;
    }

    /// @notice The v3 factory the cash-out router's flash pool and routes are checked against.
    address public immutable V3_FACTORY;
    mapping(address token => ICollateralRegistry.ERC20Config) internal _erc20;
    /// @notice Whether a term is currently allowed.
    mapping(uint32 term => bool) public isTermAllowed;
    uint32[] internal _terms;
    uint16 public feeBps = 100;
    uint16 public tradeFeeBps = 100;
    bool public newDealsPaused;
    mapping(address account => bool) public isRouter;
    mapping(uint32 term => RewardTerms) public rewardTerms;

    error ZeroAddress();
    error FeeAboveMax(uint16 bps, uint16 max);
    error TermOutOfBounds(uint32 term);
    error TooManyTerms(uint256 count, uint256 max);
    error NoTerms();
    error DuplicateTerm(uint32 term);
    error CapsInconsistent();
    error InvalidV3Pool();
    error InvalidRewardTerms();

    event RewardTermsSet(uint32 indexed term, uint128 rate, uint128 referencePrice, uint16 lenderShareBps);
    event TradeFeeSet(uint16 feeBps);

    /// @dev Same checks and order as `GageV2Registry`: the owner, then the terms, then the fee event, then the
    ///      factory's code. Its construction logs are the same less `MemePairsSet`, a setting this registry does not
    ///      have.
    constructor(address admin, uint32[] memory terms, address factory) Ownable(admin) {
        _setTerms(terms);
        emit ICollateralRegistry.FeeSet(feeBps);
        if (factory.code.length == 0) revert InvalidV3Pool();
        V3_FACTORY = factory;
    }

    /// @notice Allow or disallow an ERC-20 as collateral, with its lane, minimum, per-deal cap and open cap (raw
    /// units).
    /// @dev The lane is informational: no engine contract reads it.
    function setERC20Allowed(
        address token,
        bool ok,
        Lane lane,
        uint256 minAmount,
        uint256 maxDealRaw,
        uint256 maxOpenRaw
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (ok && (minAmount == 0 || maxDealRaw < minAmount || maxOpenRaw < maxDealRaw)) revert CapsInconsistent();
        _erc20[token] = ICollateralRegistry.ERC20Config(ok, lane, minAmount, maxDealRaw, maxOpenRaw);
        emit ICollateralRegistry.ERC20Set(token, ok, lane, minAmount, maxDealRaw, maxOpenRaw);
    }

    /// @notice Replace the allowed term set. Each term within [MIN_TERM, MAX_TERM], at most MAX_TERMS, no duplicates.
    function setTerms(uint32[] calldata terms) external onlyOwner {
        _setTerms(terms);
    }

    /// @notice Origination fee in basis points, fixed into each loan at listing. Bounded by MAX_FEE_BPS.
    function setFee(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeAboveMax(bps, MAX_FEE_BPS);
        feeBps = bps;
        emit ICollateralRegistry.FeeSet(bps);
    }

    /// @notice Change fees for subsequently posted sale asks, within a fixed bound.
    function setTradeFee(uint16 bps) external onlyOwner {
        if (bps > MAX_TRADE_FEE_BPS) revert FeeAboveMax(bps, MAX_TRADE_FEE_BPS);
        tradeFeeBps = bps;
        emit TradeFeeSet(bps);
    }

    /// @notice Stop new listings and funding. Never touches existing loans.
    function pauseNewDeals(bool paused) external onlyOwner {
        newDealsPaused = paused;
        emit ICollateralRegistry.NewDealsPausedSet(paused);
    }

    /// @notice Admit a router to `listFor` and `fundFor`.
    function setRouter(address router, bool ok) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = ok;
        emit ICollateralRegistry.RouterSet(router, ok);
    }

    /// @notice Set future listings' reward terms. The reference price is not an execution-price guarantee.
    function setRewardTerms(uint32 term, uint128 rate, uint128 referencePrice, uint16 lenderShareBps)
        external
        onlyOwner
    {
        if (!isTermAllowed[term] || rate > MAX_REWARD_RATE || referencePrice == 0 || lenderShareBps > 10_000) {
            revert InvalidRewardTerms();
        }
        rewardTerms[term] = RewardTerms(rate, referencePrice, lenderShareBps);
        emit RewardTermsSet(term, rate, referencePrice, lenderShareBps);
    }

    /// @notice Admission and caps of a token.
    function getERC20Config(address token) external view returns (ICollateralRegistry.ERC20Config memory) {
        return _erc20[token];
    }

    /// @notice The allowed term set.
    function allowedTerms() external view returns (uint32[] memory) {
        return _terms;
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

    function _setTerms(uint32[] memory terms) internal {
        if (terms.length == 0) revert NoTerms();
        if (terms.length > MAX_TERMS) revert TooManyTerms(terms.length, MAX_TERMS);
        for (uint256 i = 0; i < _terms.length; ++i) {
            isTermAllowed[_terms[i]] = false;
        }
        delete _terms;
        for (uint256 i = 0; i < terms.length; ++i) {
            uint32 t = terms[i];
            if (t < MIN_TERM || t > MAX_TERM) revert TermOutOfBounds(t);
            if (isTermAllowed[t]) revert DuplicateTerm(t);
            isTermAllowed[t] = true;
            _terms.push(t);
        }
        emit ICollateralRegistry.TermsSet(terms);
    }
}
