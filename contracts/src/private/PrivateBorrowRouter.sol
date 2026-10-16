// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Collateral, Kind} from "../types/Types.sol";
import {GageV2Vault} from "../v2/GageV2Vault.sol";
import {V2State} from "../v2/V2Types.sol";
import {IntentFillRouter} from "../intent/IntentFillRouter.sol";
import {IntentQuoteVerifier} from "../intent/IntentQuoteVerifier.sol";
import {IPrivacyPool, IPrivacyPoolsEntrypoint} from "./IPrivacyPools.sol";

/// @title PrivateBorrowRouter
/// @notice The private lane's entry. In one transaction it withdraws a piece of a screened deposit from the privacy
///         pool the Entrypoint registers for the token, lists that piece for the borrower the withdrawal proof names,
///         and funds it with a signed plan. Collateral only ever comes out of the pool, under an association-set root
///         the screener attests is current, so a deposit the screener did not approve, or has revoked, backs no loan.
///         Per-token caps bound the principal open through it.
/// @dev The router is the withdrawal's processooor and passes the loan terms as its data. The pool binds both into the
///      proof's context, so the proof fixes the borrower and the terms and anyone may submit the call. The screener's
///      attestation is an EIP-712 signature for this chain and this router, over the root, the token, its issue time and
///      its expiry, and lives at most two minutes. The router holds nothing between calls. It is admitted as an entry router
///      by the core's registry and as a filler by the Intent factory; the signed plan names it as filler and names the
///      id the core issues next.
contract PrivateBorrowRouter is Ownable2Step, ReentrancyGuardTransient, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice The loan a withdrawal commits to, as its data: the pool binds every field into the proof.
    struct Terms {
        /// @dev Originator: receives the borrower right and the proceeds.
        address borrower;
        uint128 principal;
        uint128 cap;
        uint32 term;
        uint40 fundingDeadline;
        bool withRewards;
    }

    /// @notice The screener's statement that `root` is the association-set root it stands behind for borrowing against
    ///         `token`, from `issuedAt` to `validUntil`. Per token, so a problem with one token's lists pauses only it.
    struct RootAttestation {
        uint256 root;
        address token;
        uint40 issuedAt;
        uint40 validUntil;
        bytes signature;
    }

    struct Opened {
        address token;
        uint128 principal;
        bool open;
    }

    /// @notice The largest cap any token may have, in USDG raw units.
    uint128 public constant MAX_TOKEN_CAP = 10_000_000e6;
    /// @notice The longest an attestation may live, from issue to expiry.
    uint40 public constant MAX_ATTESTATION_LIFE = 2 minutes;
    bytes32 public constant ROOT_ATTESTATION_TYPEHASH =
        keccak256("RootAttestation(uint256 root,address token,uint40 issuedAt,uint40 validUntil)");

    /// @dev Positions in `WithdrawProof.pubSignals`.
    uint256 internal constant WITHDRAWN_VALUE = 2;
    uint256 internal constant ASP_ROOT = 5;

    GageV2Vault public immutable CORE;
    IntentFillRouter public immutable FILLS;
    IPrivacyPoolsEntrypoint public immutable ENTRYPOINT;
    IERC20 public immutable USDG;

    /// @notice The key whose attestations admit borrowing; zero stops every private borrow.
    address public attester;
    /// @notice The most principal that may be open through this router against each token; zero closes the token.
    mapping(address token => uint128) public tokenCap;
    /// @notice Principal opened through this router against each token and not yet released.
    mapping(address token => uint128) public openPrincipal;

    mapping(uint256 id => Opened) internal _opened;

    error InvalidConfiguration();
    error InvalidCap();
    error AttesterDisabled();
    error TokenClosed();
    error CapExceeded(uint256 open, uint256 cap);
    error UnknownPool();
    error AttestationRootMismatch();
    error AttestationTokenMismatch();
    error AttestationNotCurrent();
    error AttestationTooLong();
    error BadAttestation();
    error ZeroCollateral();
    error InexactTransfer(uint256 expected, uint256 received);
    error StrayBalance();
    error ListingMismatch(uint256 listed, uint256 planned);

    event AttesterSet(address indexed previous, address indexed attester);
    event TokenCapSet(address indexed token, uint128 cap);
    event PrivateBorrow(
        uint256 indexed id,
        address indexed borrower,
        address indexed token,
        uint256 collateral,
        uint128 principal,
        uint128 cap,
        uint32 term
    );
    event Released(uint256 indexed id, address indexed token, uint128 principal);

    constructor(IntentFillRouter fills, IPrivacyPoolsEntrypoint entrypoint, address attester_, address initialOwner)
        Ownable(initialOwner)
        EIP712("gage private lane", "1")
    {
        if (address(fills).code.length == 0 || address(entrypoint).code.length == 0 || attester_ == address(0)) {
            revert InvalidConfiguration();
        }
        GageV2Vault core = fills.CORE();
        if (address(core).code.length == 0) revert InvalidConfiguration();
        CORE = core;
        FILLS = fills;
        ENTRYPOINT = entrypoint;
        USDG = core.USDG();
        attester = attester_;
        emit AttesterSet(address(0), attester_);
    }

    /// @notice Withdraw a piece of a screened deposit from `pool`, list it for `terms.borrower` and fund all four units
    ///         with `plan`; all of it or none of it.
    /// @dev The proof must name this router as processooor and `abi.encode(terms)` as data, against the root the
    ///      attestation names, which must be the Entrypoint's latest. If another listing takes the planned id first the
    ///      call reverts before any funding, and the note stays unspent.
    /// @param pool The privacy pool the Entrypoint registers for `plan.token`.
    /// @param proof The withdrawal proof; its withdrawn value is the collateral.
    /// @param terms The loan the proof commits to.
    /// @param attestation The screener's attestation of the proof's association-set root.
    /// @param plan Funding plan signed by the quote signer for this router and the next id.
    /// @param planSignature The quote signer's signature over `plan`.
    /// @param maxReserveShares Per purchase, a caller ceiling that may tighten each allocation's signed ceiling.
    /// @return id The listing id, active when this returns.
    function borrow(
        IPrivacyPool pool,
        IPrivacyPool.WithdrawProof calldata proof,
        Terms calldata terms,
        RootAttestation calldata attestation,
        IntentQuoteVerifier.Plan calldata plan,
        bytes calldata planSignature,
        uint256[] calldata maxReserveShares
    ) external nonReentrant returns (uint256 id) {
        if (attester == address(0)) revert AttesterDisabled();
        address token = plan.token;
        uint128 open = _checkCapacity(token, terms.principal);
        (address registered,,,) = ENTRYPOINT.assetConfig(token);
        if (registered == address(0) || registered != address(pool)) revert UnknownPool();
        _checkAttestation(attestation, proof.pubSignals[ASP_ROOT], token);
        uint256 amount = proof.pubSignals[WITHDRAWN_VALUE];
        if (amount == 0) revert ZeroCollateral();

        IERC20 collateral = IERC20(token);
        uint256 held = collateral.balanceOf(address(this));
        uint256 cash = USDG.balanceOf(address(this));
        pool.withdraw(IPrivacyPool.Withdrawal(address(this), abi.encode(terms)), proof);
        uint256 balance = collateral.balanceOf(address(this));
        uint256 received = balance > held ? balance - held : 0;
        if (received != amount) revert InexactTransfer(amount, received);

        collateral.forceApprove(address(CORE), amount);
        id = CORE.listFor(
            Collateral(Kind.ERC20, token, amount),
            terms.principal,
            terms.cap,
            terms.term,
            terms.fundingDeadline,
            terms.withRewards,
            terms.borrower
        );
        collateral.forceApprove(address(CORE), 0);
        if (collateral.balanceOf(address(this)) != held) revert StrayBalance();
        if (id != plan.listingId) revert ListingMismatch(id, plan.listingId);
        FILLS.fill(plan, planSignature, maxReserveShares);
        if (collateral.balanceOf(address(this)) != held || USDG.balanceOf(address(this)) != cash) {
            revert StrayBalance();
        }

        openPrincipal[token] = open + terms.principal;
        _opened[id] = Opened(token, terms.principal, true);
        emit PrivateBorrow(id, terms.borrower, token, amount, terms.principal, terms.cap, terms.term);
    }

    /// @notice Return the principal of closed loans to their tokens' capacity. Anyone may call it.
    /// @dev Ids not opened here, already released, or still funding or active are skipped, so a keeper may pass any
    ///      batch.
    /// @param ids Listing ids opened through this router.
    function release(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            Opened storage o = _opened[id];
            if (!o.open) continue;
            V2State state = CORE.getLoan(id).state;
            if (state == V2State.FUNDING || state == V2State.ACTIVE) continue;
            o.open = false;
            openPrincipal[o.token] -= o.principal;
            emit Released(id, o.token, o.principal);
        }
    }

    /// @notice Set the key whose attestations admit borrowing. Zero stops every private borrow.
    /// @dev Takes effect at once: attestations signed by the previous key stop working.
    /// @param next The new attester, or zero.
    function setAttester(address next) external onlyOwner {
        emit AttesterSet(attester, next);
        attester = next;
    }

    /// @notice Set the most principal that may be open through this router against `token`.
    /// @dev Zero stops new private loans on the token. A cap below what is already open only blocks new loans.
    /// @param token Collateral token.
    /// @param cap New cap in USDG raw units, at most MAX_TOKEN_CAP.
    function setTokenCap(address token, uint128 cap) external onlyOwner {
        if (token == address(0) || cap > MAX_TOKEN_CAP) revert InvalidCap();
        tokenCap[token] = cap;
        emit TokenCapSet(token, cap);
    }

    /// @notice What this router opened as listing `id`, and whether its principal still counts against the cap.
    /// @param id Listing id.
    function opened(uint256 id) external view returns (address token, uint128 principal, bool open) {
        Opened memory o = _opened[id];
        return (o.token, o.principal, o.open);
    }

    /// @notice The EIP-712 digest the attester signs for `root` and `token`, valid from `issuedAt` to `validUntil`.
    /// @param root Association-set root.
    /// @param token Collateral token the attestation admits.
    /// @param issuedAt First second the attestation holds.
    /// @param validUntil Last second the attestation holds.
    function attestationDigest(uint256 root, address token, uint40 issuedAt, uint40 validUntil)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(ROOT_ATTESTATION_TYPEHASH, root, token, issuedAt, validUntil)));
    }

    function _checkCapacity(address token, uint128 principal) internal view returns (uint128 open) {
        uint128 limit = tokenCap[token];
        if (limit == 0) revert TokenClosed();
        open = openPrincipal[token];
        if (open >= limit || principal > limit - open) revert CapExceeded(uint256(open) + principal, limit);
    }

    /// @dev The attested root must be both the proof's and the Entrypoint's latest, for the plan's token; the attestation
    ///      must be current, live at most MAX_ATTESTATION_LIFE from issue to expiry, and carry the attester's signature.
    function _checkAttestation(RootAttestation calldata a, uint256 proofRoot, address token) internal view {
        if (a.root != proofRoot || a.root != ENTRYPOINT.latestRoot()) revert AttestationRootMismatch();
        if (a.token != token) revert AttestationTokenMismatch();
        if (a.issuedAt > block.timestamp || block.timestamp > a.validUntil) revert AttestationNotCurrent();
        if (a.validUntil - a.issuedAt > MAX_ATTESTATION_LIFE) revert AttestationTooLong();
        (address signer, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(attestationDigest(a.root, a.token, a.issuedAt, a.validUntil), a.signature);
        if (err != ECDSA.RecoverError.NoError || signer != attester) revert BadAttestation();
    }
}
