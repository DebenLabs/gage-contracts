// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IntentFactory} from "./IntentFactory.sol";
import {IntentVault} from "./IntentVault.sol";
import {IntentFeeMath} from "./IntentFeeMath.sol";
import {IntentAssetPolicy} from "./IntentAssetPolicy.sol";
import {IntentLenderMarket} from "./IntentLenderMarket.sol";
import {IntentCategory} from "./IntentVaultState.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2Loan, V2State, V2LenderSplit, unitSlice} from "../v2/V2Types.sol";

/// @notice Verifies and consumes signed funding plans for Intent vaults: one listing, the vaults that complete it,
/// and every amount of each purchase, fees included.
/// @dev The S3 boundary the S4 router funds through. This contract moves nothing and funds nothing. A plan is
/// checked against the chain as it stands, never against what the signer saw: the listing's terms, the empty lender
/// units, each vault's fee terms and rate grade, its admission of the purchase (availability, the token, the borrower,
/// the grade floors and the registry's cost) and the fee arithmetic of `IntentFeeMath` are all re-read and recomputed
/// here. A valid signature therefore never widens a vault's limits, which the vault checks again itself.
/// Consumption is recorded only through the factory's current fill router, so it reverts with a failed funding.
/// The lender units are read as the four slots of this engine; an engine with finer units needs its own verifier.
contract IntentQuoteVerifier is EIP712 {
    /// @notice One vault's purchase inside a plan. Amounts are raw USDG units.
    /// @dev Every member is a static atomic type, so `abi.encode(ALLOCATION_TYPEHASH, allocation)` is exactly its
    /// EIP-712 encodeData: the member order is part of the signed schema, and a dynamic or nested member would
    /// break this.
    struct Allocation {
        address vault;
        uint8 units;
        /// @dev What the purchase lends and the interest it earns if the loan repays, for the units it will take.
        uint128 principal;
        uint128 interest;
        /// @dev The interest the purchase must keep after the execution fee and before the manager fee (D7).
        uint128 minimum;
        uint128 executionFee;
        /// @dev The most reserve shares the vault may burn to pay principal plus the execution fee; zero requires
        /// cash-only execution. The filler may tighten this signed ceiling but cannot widen it.
        uint128 maxReserveShares;
        /// @dev The vault's fee terms and rate grade the amounts were computed from; a change refuses the plan.
        uint8 minRateGrade;
        uint16 capBps;
        uint16 managerBps;
    }

    /// @notice A complete funding of one listing. Vaults are listed in ascending address order, each once, and take
    /// the listing's empty lender units in that order.
    struct Plan {
        address engine;
        uint256 listingId;
        address filler;
        address token;
        uint8 kind;
        uint256 collateral;
        uint128 principal;
        uint128 cap;
        uint32 term;
        /// @dev The model's cost of this exact loan, in basis points of principal: the base of every minimum.
        uint32 costBps;
        uint32 feePolicy;
        uint64 epoch;
        uint40 issuedAt;
        uint40 expiry;
        /// @dev Commitment to the pricing evidence the signer used; opaque here, bound in the digest and carried in
        /// the fill calldata.
        bytes32 evidence;
        Allocation[] allocations;
    }

    /// @notice One vault's purchase of existing quarters inside a secondary plan (S9). Amounts are raw USDG units.
    /// @dev Every member is a static atomic type, so `abi.encode(SECONDARY_ALLOCATION_TYPEHASH, allocation)` is
    /// exactly its EIP-712 encodeData: the member order is part of the signed schema, and a dynamic or nested member
    /// would break this.
    struct SecondaryAllocation {
        address vault;
        /// @dev The exact quarters this vault receives; disjoint from every other allocation's.
        uint8 slots;
        /// @dev Its share of the listing price by the fixed per-quarter rule, and what those quarters repay.
        uint128 price;
        uint128 repayment;
        /// @dev What the purchase must keep after the execution fee and before the manager fee, at `issuedAt`.
        uint128 minimum;
        uint128 executionFee;
        /// @dev The most reserve shares the vault may burn to pay `price + executionFee`; finite and near the live
        /// rate.
        uint128 maxReserveShares;
        /// @dev The vault's secondary policy and fee terms the amounts were computed from; a change refuses the plan.
        uint64 policyRevision;
        uint16 extraBps;
        uint16 capBps;
        uint16 managerBps;
    }

    /// @notice The complete purchase of one listed lender bundle by one or more vaults, in one transaction (S9).
    /// Vaults are listed in ascending address order, each once; their masks cover the listing exactly.
    struct SecondaryPlan {
        address engine;
        uint256 loanId;
        /// @dev Whose quarters are sold: an Intent vault, through its own `market`. A wallet's core ask (market 0) is
        /// refused `MARKET_MISMATCH`: on the vault-only core (D47) no wallet holds a quarter.
        address seller;
        address market;
        uint8 slots;
        uint128 price;
        uint256 nonce;
        /// @dev The most trade fee, in basis points of `price`, the sale may charge the seller: the registry's fee at
        /// the purchase, which the sale snapshots into the core ask it posts, must not exceed it (`ASK_CHANGED`), as it
        /// must not exceed the market ask's own bound. The rate service signs the ask's bound.
        uint16 maxFeeBps;
        address filler;
        address token;
        uint256 collateral;
        uint128 principal;
        uint128 cap;
        uint40 maturity;
        /// @dev The model's required annual return on the price for this exact position and remaining term.
        uint32 modelAnnualBps;
        uint32 policyVersion;
        uint64 epoch;
        /// @dev When the valuation behind `modelAnnualBps` was taken; the plan cannot outlive it by more than
        /// `MAX_EVIDENCE_AGE`.
        uint40 valuedAt;
        uint40 issuedAt;
        uint40 expiry;
        bytes32 evidence;
        /// @dev The least future reward each listed quarter must still carry, indexed by quarter.
        uint128[4] minRewards;
        SecondaryAllocation[] allocations;
    }

    /// @notice Why a plan is refused. `NONE` passes these checks at the queried block, the buying vaults' admission of
    /// the purchase included; purchase still enforces its live liquidity, cap and accounting guards. The numbering is
    /// part of the published schema; the S9 secondary reasons from `LOAN_NOT_ACTIVE` on are appended so every earlier
    /// number keeps its meaning, and `RESERVE_BOUND` and `BUYER_UNAVAILABLE` serve primary plans too.
    enum Refusal {
        NONE,
        FILLS_CLOSED,
        BAD_SIGNATURE,
        NOT_YET_VALID,
        EXPIRED,
        LIFE_TOO_LONG,
        CONSUMED,
        EPOCH_REVOKED,
        WRONG_ENGINE,
        WRONG_FEE_POLICY,
        WRONG_FILLER,
        FILLER_NOT_ADMITTED,
        SELF_DEALING,
        LISTING_NOT_FUNDING,
        LISTING_CHANGED,
        // No longer returned: the core holds token collateral only. Kept so every later number keeps its meaning.
        UNSUPPORTED_COLLATERAL,
        NO_MODELED_COST,
        EMPTY_PLAN,
        UNKNOWN_VAULT,
        VAULTS_NOT_ORDERED,
        ALLOCATION_CHANGED,
        INCOMPLETE_PLAN,
        MANDATE_CHANGED,
        MINIMUM_MISMATCH,
        BELOW_RETURN_FLOOR,
        FEE_ABOVE_CEILING,
        LOAN_NOT_ACTIVE,
        ASK_CHANGED,
        // The core has no split sale (`LENDER_SPLIT` false).
        UNSUPPORTED_ENGINE,
        // A buyer is the seller, or another vault the seller's curator runs (L-01).
        SELLER_IS_BUYER,
        MARKET_MISMATCH,
        POLICY_CHANGED,
        STALE_EVIDENCE,
        RESERVE_BOUND,
        MASKS_INVALID,
        SELLER_UNAVAILABLE,
        EXISTING_RECORD,
        BUYER_UNAVAILABLE
    }

    bytes32 public constant ALLOCATION_TYPEHASH = keccak256(
        "Allocation(address vault,uint8 units,uint128 principal,uint128 interest,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint8 minRateGrade,uint16 capBps,uint16 managerBps)"
    );
    bytes32 public constant PLAN_TYPEHASH = keccak256(
        "Plan(address engine,uint256 listingId,address filler,address token,uint8 kind,uint256 collateral,uint128 principal,uint128 cap,uint32 term,uint32 costBps,uint32 feePolicy,uint64 epoch,uint40 issuedAt,uint40 expiry,bytes32 evidence,Allocation[] allocations)Allocation(address vault,uint8 units,uint128 principal,uint128 interest,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint8 minRateGrade,uint16 capBps,uint16 managerBps)"
    );
    bytes32 public constant SECONDARY_ALLOCATION_TYPEHASH = keccak256(
        "SecondaryAllocation(address vault,uint8 slots,uint128 price,uint128 repayment,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint64 policyRevision,uint16 extraBps,uint16 capBps,uint16 managerBps)"
    );
    bytes32 public constant SECONDARY_PLAN_TYPEHASH = keccak256(
        "SecondaryPlan(address engine,uint256 loanId,address seller,address market,uint8 slots,uint128 price,uint256 nonce,uint16 maxFeeBps,address filler,address token,uint256 collateral,uint128 principal,uint128 cap,uint40 maturity,uint32 modelAnnualBps,uint32 policyVersion,uint64 epoch,uint40 valuedAt,uint40 issuedAt,uint40 expiry,bytes32 evidence,uint128[4] minRewards,SecondaryAllocation[] allocations)SecondaryAllocation(address vault,uint8 slots,uint128 price,uint128 repayment,uint128 minimum,uint128 executionFee,uint128 maxReserveShares,uint64 policyRevision,uint16 extraBps,uint16 capBps,uint16 managerBps)"
    );
    /// @notice The longest a plan may live, from the chain time it names as issued.
    uint40 public constant MAX_QUOTE_LIFE = 5 minutes;
    /// @notice The oldest valuation a secondary plan may still be used on, counted to the plan's expiry (proposed D39).
    uint40 public constant MAX_EVIDENCE_AGE = 5 minutes;
    /// @notice How far an allocation's reserve-share bound may exceed the live share cost of its payment
    /// (proposed D39): a finite bound, never the unlimited placeholder.
    uint16 public constant MAX_RESERVE_TOLERANCE_BPS = 100;
    /// @notice The version of the `IntentFeeMath` calculation a signed plan names. A change to any formula there
    /// must bump it.
    uint32 public constant FEE_POLICY_VERSION = 1;
    /// @notice The version of the secondary-purchase calculation (`IntentFeeMath.secondaryMinimum`) a signed
    /// secondary plan names (S9). A change to it must bump this.
    uint32 public constant SECONDARY_POLICY_VERSION = 1;
    uint8 internal constant UNITS = 4;

    IntentFactory public immutable FACTORY;
    GageV2Vault public immutable CORE;
    /// @notice Whether the core delivers one lender ask to several recipients (`GageV2Vault.buyLenderSplit`, S9),
    /// probed once at construction; without it every secondary plan is refused `UNSUPPORTED_ENGINE`.
    /// @dev The rate service reads it before it quotes a secondary plan (services/valuation/src/rates/intent/
    /// secondary.ts).
    bool public immutable LENDER_SPLIT;

    /// @notice Plans that were funded or revoked; neither can be used again.
    mapping(bytes32 => bool) public consumed;
    /// @notice Every outstanding plan names this number; advancing it revokes them all at once.
    uint64 public epoch;

    // A use is logged by the fill router's `Filled`/`SecondaryFilled` for the digest; this contract logs only
    // revocations.
    event Revoked(bytes32 indexed digest);
    event EpochAdvanced(uint64 epoch);

    error InvalidConfiguration();
    error NotRouter();
    error NotAuthority();
    error Refused(Refusal reason);
    /// @notice `quarterPrice` was asked for a quarter that is not listed in a four-quarter mask.
    error InvalidQuarter();

    constructor(IntentFactory factory) EIP712("gage Intent quotes", "1") {
        if (address(factory).code.length == 0) revert InvalidConfiguration();
        FACTORY = factory;
        CORE = GageV2Vault(factory.CORE());
        // The split sale refuses to sell an ask that does not exist (`StaleAsk`) and changes nothing. Any other
        // answer, a missing function's included, is an engine that cannot deliver a bundle to several vaults.
        V2LenderSplit memory none;
        (bool sold, bytes memory reason) = address(CORE).call(abi.encodeCall(GageV2Vault.buyLenderSplit, (0, none)));
        LENDER_SPLIT = !sold && reason.length == 4 && bytes4(reason) == GageV2Vault.StaleAsk.selector;
    }

    /// @notice Use a plan once. Only the factory's current fill router, in the transaction that funds the listing:
    /// if that funding fails, this record reverts with it and the plan remains usable until it expires.
    /// @dev The preflight is an `eth_call` of this from `FACTORY.fillRouter()` (address(0) while fills are closed):
    /// it returns the digest when the plan could be consumed in that block, or reverts `Refused` with the first
    /// check that fails.
    /// @param filler The account the router is funding for; it must be the filler the plan names.
    /// @return digest The EIP-712 digest the signer signed, the plan's identity here.
    function consume(Plan calldata plan, bytes calldata signature, address filler) external returns (bytes32 digest) {
        if (msg.sender != FACTORY.fillRouter()) revert NotRouter();
        digest = planHash(plan);
        Refusal reason = _check(plan, signature, filler, digest);
        if (reason != Refusal.NONE) revert Refused(reason);
        consumed[digest] = true;
    }

    /// @notice Withdraw one plan before it is used. The factory's owner or its current quote signer.
    function revoke(bytes32 digest) external {
        _requireAuthority();
        consumed[digest] = true;
        emit Revoked(digest);
    }

    /// @notice Withdraw every outstanding plan at once. The factory's owner or its current quote signer.
    function revokeAll() external {
        _requireAuthority();
        emit EpochAdvanced(++epoch);
    }

    /// @notice The digest of a plan under this contract's EIP-712 domain.
    function planHash(Plan calldata p) public view returns (bytes32) {
        bytes32[] memory parts = new bytes32[](p.allocations.length);
        for (uint256 i; i < parts.length; ++i) {
            parts[i] = keccak256(abi.encode(ALLOCATION_TYPEHASH, p.allocations[i]));
        }
        bytes memory head = abi.encode(
            PLAN_TYPEHASH, p.engine, p.listingId, p.filler, p.token, p.kind, p.collateral, p.principal, p.cap
        );
        bytes32 allocationsHash = keccak256(abi.encodePacked(parts));
        bytes memory tail =
            abi.encode(p.term, p.costBps, p.feePolicy, p.epoch, p.issuedAt, p.expiry, p.evidence, allocationsHash);
        return _hashTypedDataV4(keccak256(bytes.concat(head, tail)));
    }

    /// @notice Use a secondary plan once; only the factory's current fill router, in the transaction that buys the
    /// listing. A failed purchase reverts this record with it.
    /// @dev Preflighted as `consume` is: an `eth_call` from `FACTORY.fillRouter()` returns the digest or reverts
    /// `Refused`.
    function consumeSecondary(SecondaryPlan calldata plan, bytes calldata signature, address filler)
        external
        returns (bytes32 digest)
    {
        if (msg.sender != FACTORY.fillRouter()) revert NotRouter();
        digest = secondaryPlanHash(plan);
        Refusal reason = _checkSecondary(plan, signature, filler, digest);
        if (reason != Refusal.NONE) revert Refused(reason);
        consumed[digest] = true;
    }

    /// @notice The digest of a secondary plan under this contract's EIP-712 domain; never equal to a primary one.
    function secondaryPlanHash(SecondaryPlan calldata p) public view returns (bytes32) {
        bytes32[] memory parts = new bytes32[](p.allocations.length);
        for (uint256 i; i < parts.length; ++i) {
            parts[i] = keccak256(abi.encode(SECONDARY_ALLOCATION_TYPEHASH, p.allocations[i]));
        }
        bytes memory head = abi.encode(
            SECONDARY_PLAN_TYPEHASH,
            p.engine,
            p.loanId,
            p.seller,
            p.market,
            p.slots,
            p.price,
            p.nonce,
            p.maxFeeBps,
            p.filler,
            p.token,
            p.collateral
        );
        bytes memory body = abi.encode(
            p.principal,
            p.cap,
            p.maturity,
            p.modelAnnualBps,
            p.policyVersion,
            p.epoch,
            p.valuedAt,
            p.issuedAt,
            p.expiry,
            p.evidence,
            keccak256(abi.encodePacked(p.minRewards)),
            keccak256(abi.encodePacked(parts))
        );
        return _hashTypedDataV4(keccak256(bytes.concat(head, body)));
    }

    /// @notice The fixed per-quarter share of a listing price: the `k`-th listed quarter, counted up from quarter 0,
    /// takes `price / n`, plus one raw unit while `k < price % n`, for `n` listed quarters. Whoever buys it.
    /// @dev Only for a listed quarter of a mask of the four quarters: anything else, an empty mask included, reverts
    /// `InvalidQuarter`.
    function quarterPrice(uint256 price, uint8 listed, uint8 quarter) public pure returns (uint256) {
        if (listed > 0xF || quarter >= UNITS || listed & (1 << quarter) == 0) revert InvalidQuarter();
        uint256 n;
        uint256 k;
        for (uint8 i; i < UNITS; ++i) {
            if (listed & (1 << i) == 0) continue;
            if (i < quarter) ++k;
            ++n;
        }
        return price / n + (k < price % n ? 1 : 0);
    }

    function _checkSecondary(SecondaryPlan calldata p, bytes calldata signature, address filler, bytes32 digest)
        internal
        view
        returns (Refusal)
    {
        Refusal common = _checkCommon(signature, filler, digest, p.filler, p.engine, p.epoch, p.issuedAt, p.expiry);
        if (common != Refusal.NONE) return common;
        if (p.policyVersion != SECONDARY_POLICY_VERSION) return Refusal.WRONG_FEE_POLICY;
        if (!LENDER_SPLIT) return Refusal.UNSUPPORTED_ENGINE;
        V2Loan memory l = CORE.getLoan(p.loanId);
        if (l.state != V2State.ACTIVE) return Refusal.LOAN_NOT_ACTIVE;
        uint256 maturity = uint256(l.fundedAt) + l.term;
        if (block.timestamp >= maturity || p.expiry > maturity) return Refusal.LOAN_NOT_ACTIVE;
        if (
            l.token != p.token || l.collateral != p.collateral || l.principal != p.principal || l.cap != p.cap
                || maturity != p.maturity
        ) return Refusal.LISTING_CHANGED;
        if (l.originator == filler) return Refusal.SELF_DEALING;
        if (p.modelAnnualBps == 0) return Refusal.NO_MODELED_COST;
        if (p.valuedAt > p.issuedAt || p.expiry > uint256(p.valuedAt) + MAX_EVIDENCE_AGE) {
            return Refusal.STALE_EVIDENCE;
        }
        Refusal listing = _checkListing(p);
        if (listing != Refusal.NONE) return listing;
        return _checkSecondaryAllocations(p, l.originator);
    }

    /// @dev The listing as it stands: the seller is one of the factory's vaults, selling only through its own market.
    /// On the vault-only core (D47) no other account holds a quarter, and a vault never leaves a standing core ask.
    /// The trade fee the sale will charge is the registry's now, snapshotted by the core ask the sale posts in this
    /// transaction: it must be within both the ask's bound and the plan's signed one.
    function _checkListing(SecondaryPlan calldata p) internal view returns (Refusal) {
        IntentVault seller = IntentVault(p.seller);
        if (!FACTORY.isVault(p.seller) || address(seller.LENDER_MARKET()) != p.market) return Refusal.MARKET_MISMATCH;
        (uint128 price, uint40 deadline, uint16 maxFeeBps, uint8 slots, uint64 nonce) =
            IntentLenderMarket(p.market).asks(p.loanId);
        if (
            price == 0 || price != p.price || slots != p.slots || nonce != p.nonce
                || CORE.REGISTRY().tradeFeeBps() > (maxFeeBps < p.maxFeeBps ? maxFeeBps : p.maxFeeBps)
        ) return Refusal.ASK_CHANGED;
        if (seller.paused() || block.timestamp >= seller.earliestMaturity()) return Refusal.SELLER_UNAVAILABLE;
        return (block.timestamp >= deadline || p.expiry > deadline) ? Refusal.ASK_CHANGED : Refusal.NONE;
    }

    /// @dev Every allocation independently: its quarters, its price and repayment, its vault's live policy and fee
    /// terms, its minimum, its fee under its own ceiling, and a finite reserve bound. No allocation's surplus covers
    /// another's shortfall. A listing priced below its quarter count can leave an allocation a zero share of the
    /// price; that allocation is refused `ALLOCATION_CHANGED`: the vault's `purchase` reads a zero price as a funding
    /// purchase, which an active loan can never be (`IneligibleDeal`), so the plan could never execute. A vault run by
    /// the seller's own curator is refused as the seller itself is (`SELLER_IS_BUYER`, L-01): its curator would
    /// otherwise move its depositors' position, at a price of its choosing, into another vault it runs.
    function _checkSecondaryAllocations(SecondaryPlan calldata p, address originator) internal view returns (Refusal) {
        uint256 count = p.allocations.length;
        if (count == 0) return Refusal.EMPTY_PLAN;
        // `_checkListing` has admitted the seller as one of the factory's vaults.
        address sellerCurator = IntentVault(payable(p.seller)).CURATOR();
        uint8 covered;
        address last;
        for (uint256 i; i < count; ++i) {
            SecondaryAllocation calldata a = p.allocations[i];
            if (!FACTORY.isVault(a.vault)) return Refusal.UNKNOWN_VAULT;
            if (a.vault <= last) return Refusal.VAULTS_NOT_ORDERED;
            last = a.vault;
            // The seller itself included: it has the seller's curator.
            if (IntentVault(payable(a.vault)).CURATOR() == sellerCurator) return Refusal.SELLER_IS_BUYER;
            if (a.slots == 0 || a.slots & covered != 0 || a.slots & ~p.slots != 0) return Refusal.MASKS_INVALID;
            covered |= a.slots;
            if (!_secondaryAmounts(p, a)) return Refusal.ALLOCATION_CHANGED;
            Refusal terms = _checkSecondaryTerms(p, a, originator);
            if (terms != Refusal.NONE) return terms;
        }
        return covered == p.slots ? Refusal.NONE : Refusal.MASKS_INVALID;
    }

    /// @dev Whether an allocation's price is its quarters' shares of the listing price, and not zero, and its
    /// repayment is the core's for those quarters.
    function _secondaryAmounts(SecondaryPlan calldata p, SecondaryAllocation calldata a) internal pure returns (bool) {
        uint256 price;
        uint256 repayment;
        for (uint8 q; q < UNITS; ++q) {
            if (a.slots & (1 << q) == 0) continue;
            price += quarterPrice(p.price, p.slots, q);
            repayment += unitSlice(p.cap, q);
        }
        return price != 0 && a.price == price && a.repayment == repayment;
    }

    function _checkSecondaryTerms(SecondaryPlan calldata p, SecondaryAllocation calldata a, address originator)
        internal
        view
        returns (Refusal)
    {
        IntentVault vault = IntentVault(payable(a.vault));
        Refusal buyer = _checkBuyer(vault, p.token, originator);
        if (buyer != Refusal.NONE) return buyer;
        (,,,,,,,,, uint128 held,,,,,,) = vault.loans(p.loanId);
        // A vault never holds two records of one loan (S9-01).
        if (held != 0) return Refusal.EXISTING_RECORD;
        IntentAssetPolicy policy = vault.ASSET_POLICY();
        if (
            !policy.secondaryEnabled() || policy.secondaryRevision() != a.policyRevision
                || policy.minExtraAnnualReturnBps() != a.extraBps
        ) return Refusal.POLICY_CHANGED;
        if (vault.executionCapBps() != a.capBps || vault.feeBps() != a.managerBps) return Refusal.MANDATE_CHANGED;
        uint256 minimum =
            IntentFeeMath.secondaryMinimum(a.price, uint256(p.modelAnnualBps) + a.extraBps, p.maturity - p.issuedAt);
        if (a.minimum != minimum) return Refusal.MINIMUM_MISMATCH;
        if (a.repayment <= a.price) return Refusal.BELOW_RETURN_FLOOR;
        (bool ok, uint256 most) = IntentFeeMath.executionFee(a.repayment - a.price, minimum, a.capBps);
        if (!ok) return Refusal.BELOW_RETURN_FLOOR;
        if (a.executionFee > most) return Refusal.FEE_ABOVE_CEILING;
        return _checkReserveBound(vault, uint256(a.price) + a.executionFee, a.maxReserveShares);
    }

    function _requireAuthority() internal view {
        if (msg.sender != FACTORY.owner() && msg.sender != FACTORY.quoteSigner()) revert NotAuthority();
    }

    /// @dev What every plan shares: an open fill path, the current signer, its life, single use, the epoch, the
    /// engine, and an admitted filler submitting its own plan.
    function _checkCommon(
        bytes calldata signature,
        address filler,
        bytes32 digest,
        address named,
        address engine,
        uint64 planEpoch,
        uint40 issuedAt,
        uint40 expiry
    ) internal view returns (Refusal) {
        address expected = FACTORY.quoteSigner();
        // No transaction reaches the router clause (address(0) sends none), but it is what makes a preflight
        // `eth_call` from address(0) answer `FILLS_CLOSED` while the signer is set and the router is not: keep it.
        if (expected == address(0) || FACTORY.fillRouter() == address(0)) return Refusal.FILLS_CLOSED;
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != expected) return Refusal.BAD_SIGNATURE;
        if (issuedAt > block.timestamp) return Refusal.NOT_YET_VALID;
        // Dead at its expiry, as the signer's evidence is (L-23): the last usable second is the one before.
        if (block.timestamp >= expiry) return Refusal.EXPIRED;
        if (expiry > uint256(issuedAt) + MAX_QUOTE_LIFE) return Refusal.LIFE_TOO_LONG;
        if (consumed[digest]) return Refusal.CONSUMED;
        if (planEpoch != epoch) return Refusal.EPOCH_REVOKED;
        if (engine != address(CORE)) return Refusal.WRONG_ENGINE;
        if (filler != named) return Refusal.WRONG_FILLER;
        return FACTORY.isFiller(filler) ? Refusal.NONE : Refusal.FILLER_NOT_ADMITTED;
    }

    function _check(Plan calldata p, bytes calldata signature, address filler, bytes32 digest)
        internal
        view
        returns (Refusal)
    {
        Refusal common = _checkCommon(signature, filler, digest, p.filler, p.engine, p.epoch, p.issuedAt, p.expiry);
        if (common != Refusal.NONE) return common;
        if (p.feePolicy != FEE_POLICY_VERSION) return Refusal.WRONG_FEE_POLICY;
        V2Loan memory l = CORE.getLoan(p.listingId);
        if (l.originator == filler) return Refusal.SELF_DEALING;
        if (l.state != V2State.FUNDING || block.timestamp >= l.fundingDeadline) return Refusal.LISTING_NOT_FUNDING;
        // The kind is the core's, so a position cannot be relabelled a token. V1 lends against individual tokens only
        // (D28): the core refuses any other kind at listing (`_validate`, and its clone account again at
        // initialization), and the vault's asset policy refuses one itself.
        if (
            l.token != p.token || uint8(l.kind) != p.kind || l.collateral != p.collateral || l.principal != p.principal
                || l.cap != p.cap || l.term != p.term
        ) return Refusal.LISTING_CHANGED;
        if (p.costBps == 0) return Refusal.NO_MODELED_COST;
        return _checkAllocations(p, l.originator);
    }

    /// @dev Walks the listing's empty lender units exactly as the core and the vaults fill them, vault by vault.
    function _checkAllocations(Plan calldata p, address originator) internal view returns (Refusal) {
        uint256 count = p.allocations.length;
        if (count == 0) return Refusal.EMPTY_PLAN;
        address[4] memory lenders = CORE.lenders(p.listingId);
        uint8 next;
        address last;
        for (uint256 i; i < count; ++i) {
            Allocation calldata a = p.allocations[i];
            if (!FACTORY.isVault(a.vault)) return Refusal.UNKNOWN_VAULT;
            if (a.vault <= last) return Refusal.VAULTS_NOT_ORDERED;
            last = a.vault;
            uint256 principal;
            uint256 repayment;
            uint8 remaining = a.units;
            for (; next < UNITS && remaining != 0; ++next) {
                if (lenders[next] != address(0)) continue;
                principal += unitSlice(p.principal, next);
                repayment += unitSlice(p.cap, next);
                --remaining;
            }
            // An allocation that takes no unit is refused as well (`a.units == 0`).
            if (a.units == 0 || remaining != 0 || principal != a.principal || repayment - principal != a.interest) {
                return Refusal.ALLOCATION_CHANGED;
            }
            Refusal fee = _checkFees(a, p, originator);
            if (fee != Refusal.NONE) return fee;
        }
        // D12: a plan funds every unit that is left, so the listing activates in the same transaction.
        for (; next < UNITS; ++next) {
            if (lenders[next] == address(0)) return Refusal.INCOMPLETE_PLAN;
        }
        return Refusal.NONE;
    }

    function _checkFees(Allocation calldata a, Plan calldata p, address originator) internal view returns (Refusal) {
        IntentVault vault = IntentVault(payable(a.vault));
        Refusal buyer = _checkBuyer(vault, p.token, originator);
        if (buyer != Refusal.NONE) return buyer;
        if (
            vault.minRateGrade() != a.minRateGrade || vault.executionCapBps() != a.capBps
                || vault.feeBps() != a.managerBps
        ) return Refusal.MANDATE_CHANGED;
        if (IntentFeeMath.minimumInterest(a.principal, p.costBps, a.minRateGrade) != a.minimum) {
            return Refusal.MINIMUM_MISMATCH;
        }
        (bool ok, uint256 most) = IntentFeeMath.executionFee(a.interest, a.minimum, a.capBps);
        if (!ok) return Refusal.BELOW_RETURN_FLOOR;
        if (a.executionFee > most) return Refusal.FEE_ABOVE_CEILING;
        // The vault's own floor on the registry's cost of this token and term, whoever signed
        // (`IntentAssetPolicy.quote`): what the purchase keeps after its fee, against its rate grade's share of that
        // cost. The fee is at most the interest less the signed minimum, so the subtraction cannot underflow.
        if (a.minRateGrade != 0) {
            uint256 modeled = vault.GRADES().modeledCostOf(p.token, p.term);
            if (modeled == 0) return Refusal.NO_MODELED_COST;
            if (a.interest - a.executionFee < IntentFeeMath.minimumInterest(a.principal, modeled, a.minRateGrade)) {
                return Refusal.BELOW_RETURN_FLOOR;
            }
        }
        return _checkReserveBound(vault, uint256(a.principal) + a.executionFee, a.maxReserveShares);
    }

    /// @dev The buying vault's admission of the purchase on either route, read as its `purchase` and its policy's
    /// `quote` read it: the loan is neither the vault's nor its manager's (`SELF_DEALING`); the vault is not paused,
    /// is open to fillers, has holders and no loan past its term; it still picks the token, which the factory still
    /// admits in one of its categories; and the token's live grade meets its floor (`BUYER_UNAVAILABLE`). The vault
    /// rechecks all of it at execution.
    function _checkBuyer(IntentVault vault, address token, address originator) internal view returns (Refusal) {
        if (originator == address(vault) || originator == vault.CURATOR()) return Refusal.SELF_DEALING;
        uint8 floor = vault.minGrade();
        if (
            vault.paused() || !vault.fillersOpen() || vault.totalSupply() == 0
                || block.timestamp >= vault.earliestMaturity() || !vault.ASSET_POLICY().picked(token)
                || FACTORY.eligibleCategory(token, vault.CATEGORY_MASK()) > uint8(type(IntentCategory).max)
                || (floor != 0 && vault.GRADES().gradeOf(token) < floor)
        ) return Refusal.BUYER_UNAVAILABLE;
        return Refusal.NONE;
    }

    /// @dev A finite reserve-share bound near the live rate: at most the reserve's `previewWithdraw` of the payment
    /// plus `MAX_RESERVE_TOLERANCE_BPS`, which refuses the unlimited placeholder. Zero, a cash-only bound, passes here;
    /// purchase checks the shares it actually burns against the bound.
    function _checkReserveBound(IntentVault vault, uint256 payment, uint256 most) internal view returns (Refusal) {
        uint256 shares = vault.RESERVE().previewWithdraw(payment);
        return most > shares + shares * MAX_RESERVE_TOLERANCE_BPS / 10_000 ? Refusal.RESERVE_BOUND : Refusal.NONE;
    }
}
