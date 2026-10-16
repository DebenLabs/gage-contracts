// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {V2Loan, V2State} from "../v2/V2Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {EarnFactory} from "./EarnFactory.sol";
import {EarnVault} from "./EarnVault.sol";

/// @notice The one path a filler takes into an Earn strategy: a signed, sized quote for the listing, a listing old
/// enough that listing and fill cannot share a block, and a filler the factory admits. The strategy then checks
/// its own mandate exactly as it does for its curator, so a filler has no discretion beyond the quote.
/// @dev Project Intent, slices 1 and 3 (D152, D154). The core stores no listing timestamp, so the age runs from a
/// first-seen stamp anyone may write once the listing exists on the core. The quote binds the listing's own record
/// (collateral, principal, cost, term) as the core holds it, so a quote for one listing fits no other, and carries
/// the model's cost for that listing at its size and term, which the strategy's rate floor is measured against.
/// Nothing here holds funds or charges a fee; the factory owner may replace this contract, and every strategy
/// follows the factory.
contract FillRouter is EIP712, ReentrancyGuardTransient {
    /// @notice What the rating service signs: the listing exactly as the core records it, for one strategy, and
    /// the model's cost of that loan in basis points of principal for its term (zero: the model has no opinion).
    struct Quote {
        address strategy;
        uint256 listingId;
        address token;
        uint256 collateral;
        uint128 principal;
        uint128 cap;
        uint32 term;
        uint32 costBps;
        uint40 expiry;
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address strategy,uint256 listingId,address token,uint256 collateral,uint128 principal,uint128 cap,uint32 term,uint32 costBps,uint40 expiry)"
    );
    /// @notice A listing may be filled through the router only this long after it was first seen.
    uint40 public constant MIN_AGE = 2 minutes;
    /// @notice A quote whose expiry lies further out than this is refused, whoever signed it.
    uint40 public constant MAX_QUOTE_LIFE = 5 minutes;
    /// @notice The lowest floor any strategy may set: the listing must offer three quarters of the modeled cost
    /// (the C preset), so no mandate lends at any cost a borrower cares to name.
    uint16 public constant MIN_FLOOR_BPS = 7500;
    /// @notice The highest floor: twice the modeled cost.
    uint16 public constant MAX_FLOOR_BPS = 20_000;
    /// @notice The presets the app offers, as shares of the modeled cost.
    uint16 public constant FLOOR_C = 7500;
    uint16 public constant FLOOR_B = 9000;
    uint16 public constant FLOOR_A = 10_000;
    uint256 internal constant BPS = 10_000;

    EarnFactory public immutable FACTORY;
    GageV2Vault public immutable CORE;

    /// @notice When a listing was first seen on the core by anyone who cared to say so; zero until then.
    mapping(uint256 => uint40) public seenAt;
    /// @notice Each strategy's rate floor as a share of the quoted cost; zero reads as `MIN_FLOOR_BPS`.
    mapping(address => uint16) public floorBps;

    event Noticed(uint256 indexed listingId, uint40 at);
    event FloorSet(address indexed strategy, uint16 bps);
    event Filled(
        address indexed strategy, uint256 indexed listingId, address indexed filler, uint8 units, bytes32 quoteHash
    );

    error InvalidConfiguration();
    error NotFiller();
    error NotAVault();
    error NotListed();
    error TooYoung();
    error QuoteExpired();
    error QuoteMismatch();
    error BadSignature();
    error SelfDealing();
    error NotCurator();
    error BelowFloor();

    constructor(EarnFactory factory) EIP712("gage FillRouter", "1") {
        if (address(factory).code.length == 0) revert InvalidConfiguration();
        FACTORY = factory;
        CORE = GageV2Vault(factory.CORE());
    }

    /// @notice Record that a listing exists on the core; the first call sets the stamp the age runs from. Anyone
    /// may call, and the keeper does on every Listed event.
    function notice(uint256 listingId) external {
        if (seenAt[listingId] != 0) return;
        if (CORE.getLoan(listingId).state != V2State.FUNDING) revert NotListed();
        uint40 at = uint40(block.timestamp);
        seenAt[listingId] = at;
        emit Noticed(listingId, at);
    }

    /// @notice Set a strategy's rate floor, as a share of the quoted cost, between the C preset and twice the model;
    /// the strategy's curator only. Open loans are untouched.
    function setFloor(address strategy, uint16 bps) external {
        if (!FACTORY.isVault(strategy)) revert NotAVault();
        if (msg.sender != EarnVault(payable(strategy)).CURATOR()) revert NotCurator();
        if (bps < MIN_FLOOR_BPS || bps > MAX_FLOOR_BPS) revert InvalidConfiguration();
        floorBps[strategy] = bps;
        emit FloorSet(strategy, bps);
    }

    /// @notice The floor a strategy applies now: its setting, or the C preset until its curator sets one.
    function floorOf(address strategy) public view returns (uint16) {
        uint16 bps = floorBps[strategy];
        return bps == 0 ? MIN_FLOOR_BPS : bps;
    }

    /// @notice Fund `units` of the quoted listing from the quoted strategy, on the filler's behalf. The listing must
    /// offer at least the strategy's floor share of the quoted cost. The strategy checks its mandate, its pause and
    /// its liquidity itself and books the loan as if its curator had called.
    function fill(Quote calldata q, uint8 units, uint256 maxReserveShares, bytes calldata signature)
        external
        nonReentrant
    {
        if (!FACTORY.canFill(msg.sender)) revert NotFiller();
        if (!FACTORY.isVault(q.strategy)) revert NotAVault();
        uint40 seen = seenAt[q.listingId];
        if (seen == 0 || block.timestamp < uint256(seen) + MIN_AGE) revert TooYoung();
        if (block.timestamp > q.expiry || q.expiry > block.timestamp + MAX_QUOTE_LIFE) revert QuoteExpired();
        V2Loan memory l = CORE.getLoan(q.listingId);
        if (
            l.token != q.token || l.collateral != q.collateral || l.principal != q.principal || l.cap != q.cap
                || l.term != q.term
        ) revert QuoteMismatch();
        if (l.originator == msg.sender) revert SelfDealing();
        // The rate floor: the listing's cost for the whole loan against the model's, both as shares of principal
        // for the term. No model, no fill.
        if (
            q.costBps == 0
                || uint256(q.cap - q.principal) * BPS * BPS < uint256(q.principal) * q.costBps * floorOf(q.strategy)
        ) revert BelowFloor();
        bytes32 digest = quoteHash(q);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        address expected = FACTORY.quoteSigner();
        if (err != ECDSA.RecoverError.NoError || expected == address(0) || signer != expected) revert BadSignature();
        EarnVault(payable(q.strategy)).fund(q.listingId, units, maxReserveShares);
        emit Filled(q.strategy, q.listingId, msg.sender, units, digest);
    }

    /// @notice Move a strategy's idle cash into its reserve on a filler's behalf; the strategy's own rules apply.
    function investReserve(address strategy, uint256 assets, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (!FACTORY.canFill(msg.sender)) revert NotFiller();
        if (!FACTORY.isVault(strategy)) revert NotAVault();
        return EarnVault(payable(strategy)).investReserve(assets, minShares);
    }

    /// @notice The EIP-712 digest the signer signs for a quote, under this contract's domain.
    function quoteHash(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    q.strategy,
                    q.listingId,
                    q.token,
                    q.collateral,
                    q.principal,
                    q.cap,
                    q.term,
                    q.costBps,
                    q.expiry
                )
            )
        );
    }
}
