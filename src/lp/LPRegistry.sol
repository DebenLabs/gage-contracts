// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolConfig} from "./LPTypes.sol";

/// @notice What the registry asks of a vault factory.
interface ILPVaultFactoryView {
    function isVault(address vault) external view returns (bool);
}

/// @title LPRegistry
/// @notice The LP lane's settings: which adapters, pools, vaults and sale executors new loans may use, the origination
/// fee, the loan cap, the terms, the daily origination cap, the quote signer and the late-unwind delay. Owned by the
/// Safe on mainnet. Every setting is bounded at compile time. Adapters, pools, vaults, terms, the fee and the caps
/// shape only NEW loans: a running loan keeps its adapter, vault and terms. The quote signer, the sale executors and
/// the late-unwind delay are operational and also govern how running loans are settled, so a signer key in the wrong
/// hands can
/// be replaced for every loan at once.
contract LPRegistry is Ownable2Step {
    /// @notice Highest origination fee, in basis points of the principal.
    uint16 public constant MAX_FEE_BPS = 200;
    /// @notice Highest principal as a share of the signed collateral value, in basis points.
    uint16 public constant MAX_LTV_BPS = 9000;
    /// @notice Shortest and longest loan terms, and how many terms may be offered at once.
    uint32 public constant MIN_TERM = 1 days;
    uint32 public constant MAX_TERM = 30 days;
    uint256 public constant MAX_TERMS = 8;
    /// @notice Bounds on the wait after a term's end before anyone may unwind a defaulted position without a quote.
    uint32 public constant MIN_LATE_UNWIND_DELAY = 1 days;
    uint32 public constant MAX_LATE_UNWIND_DELAY = 14 days;
    /// @notice Widest half-width a pool may demand (the full tick range).
    uint24 public constant MAX_MIN_HALF_WIDTH_TICKS = 887_272;
    /// @notice Highest principal the whole lane may open in one UTC day; bounds what a signer key in the wrong hands
    /// can lend out
    /// before it is rotated.
    uint128 public constant MAX_DAILY_ORIGINATION = 100_000_000e6;
    /// @notice Highest per-loan principal and outstanding principal a pool may be given.
    uint128 public constant MAX_POOL_LOAN_PRINCIPAL = 10_000_000e6;
    uint128 public constant MAX_POOL_OUTSTANDING = 100_000_000e6;

    /// @notice Origination fee in basis points, fixed into each loan when it opens.
    uint16 public feeBps;
    /// @notice Highest principal per unit of signed collateral value, in basis points.
    uint16 public ltvCapBps;
    /// @notice Seconds after a term's end before `settleDefaultLate` opens to anyone.
    uint32 public lateUnwindDelay;
    /// @notice When true, no new loan opens. Repay, collect, return, settle and withdraw never stop.
    bool public newLoansPaused;
    /// @notice The rates service's hot key whose EIP-712 quotes the core and vaults accept.
    address public quoteSigner;
    /// @notice Where origination fees and the protocol's share of performance fees are credited.
    address public feeRecipient;
    /// @notice Principal the lane may open per UTC day, at most `MAX_DAILY_ORIGINATION`.
    uint128 public dailyOriginationCap;

    uint32[] internal _terms;
    /// @notice Whether a new loan may run for `term` seconds.
    mapping(uint32 term => bool) public termAllowed;
    /// @notice Whether new loans may use `adapter`.
    mapping(address adapter => bool) public adapterAllowed;
    /// @notice The factory whose vaults may fund new loans unless the owner removed them; zero for none.
    address public vaultFactory;
    /// @notice Whether `curator` may open a vault through the factory.
    mapping(address curator => bool) public curatorAllowed;
    /// @notice Whether anyone may open a vault through the factory, not only the curators allowed.
    bool public openCreation;
    /// @dev The owner's own word on a vault: 1 allowed, 2 removed; 0 defers to the factory.
    mapping(address vault => uint8) internal _vaultDecision;
    /// @notice Whether vaults may sell recovered tokens through `executor`.
    mapping(address executor => bool) public executorAllowed;
    mapping(address adapter => mapping(address pool => PoolConfig)) internal _pools;

    event FeeSet(uint16 bps);
    event LtvCapSet(uint16 bps);
    event LateUnwindDelaySet(uint32 delay);
    event NewLoansPausedSet(bool paused);
    event QuoteSignerSet(address signer);
    event FeeRecipientSet(address recipient);
    event DailyOriginationCapSet(uint128 amount);
    event TermSet(uint32 term, bool allowed);
    event AdapterSet(address indexed adapter, bool allowed);
    event VaultSet(address indexed vault, bool allowed);
    event VaultFactorySet(address factory);
    event CuratorSet(address indexed curator, bool allowed);
    event OpenCreationSet(bool open);
    event ExecutorSet(address indexed executor, bool allowed);
    event PoolSet(address indexed adapter, address indexed pool, PoolConfig config);

    error FeeAboveMax(uint16 bps, uint16 max);
    error LtvAboveMax(uint16 bps, uint16 max);
    error LateUnwindDelayOutOfRange(uint32 delay);
    error TermOutOfRange(uint32 term);
    error TooManyTerms();
    error TermUnchanged(uint32 term);
    error ZeroAddress();
    error HalfWidthAboveMax(uint24 ticks);
    error PoolCapsInconsistent();
    error PoolCapAboveMax(uint128 maxLoanPrincipal, uint128 maxOutstanding);
    error DailyCapAboveMax(uint128 amount);

    /// @notice Deploys the registry with its first settings; terms and allowlists start empty.
    constructor(
        address owner_,
        address quoteSigner_,
        address feeRecipient_,
        uint16 feeBps_,
        uint16 ltvCapBps_,
        uint32 lateUnwindDelay_
    ) Ownable(owner_) {
        _setQuoteSigner(quoteSigner_);
        _setFeeRecipient(feeRecipient_);
        _setFee(feeBps_);
        _setLtvCap(ltvCapBps_);
        _setLateUnwindDelay(lateUnwindDelay_);
        dailyOriginationCap = MAX_DAILY_ORIGINATION;
        emit DailyOriginationCapSet(MAX_DAILY_ORIGINATION);
    }

    /// @notice Sets how much principal the lane may open per UTC day, at most `MAX_DAILY_ORIGINATION`.
    function setDailyOriginationCap(uint128 amount) external onlyOwner {
        if (amount > MAX_DAILY_ORIGINATION) revert DailyCapAboveMax(amount);
        dailyOriginationCap = amount;
        emit DailyOriginationCapSet(amount);
    }

    /// @notice Sets the origination fee for new loans, at most `MAX_FEE_BPS`.
    function setFee(uint16 bps) external onlyOwner {
        _setFee(bps);
    }

    /// @notice Sets the loan cap for new loans, at most `MAX_LTV_BPS`.
    function setLtvCap(uint16 bps) external onlyOwner {
        _setLtvCap(bps);
    }

    /// @notice Sets how long after a term's end anyone may unwind a defaulted position without a quote.
    function setLateUnwindDelay(uint32 delay) external onlyOwner {
        _setLateUnwindDelay(delay);
    }

    /// @notice Stops or restarts new loans. Nothing else ever pauses.
    function setNewLoansPaused(bool paused) external onlyOwner {
        newLoansPaused = paused;
        emit NewLoansPausedSet(paused);
    }

    /// @notice Rotates the quote signer. Quotes it signed before stop working at once.
    function setQuoteSigner(address signer) external onlyOwner {
        _setQuoteSigner(signer);
    }

    /// @notice Changes where fees are credited from now on.
    function setFeeRecipient(address recipient) external onlyOwner {
        _setFeeRecipient(recipient);
    }

    /// @notice Offers or withdraws a term for new loans.
    function setTerm(uint32 term, bool allowed) external onlyOwner {
        if (term < MIN_TERM || term > MAX_TERM) revert TermOutOfRange(term);
        if (termAllowed[term] == allowed) revert TermUnchanged(term);
        if (allowed) {
            if (_terms.length == MAX_TERMS) revert TooManyTerms();
            _terms.push(term);
        } else {
            uint256 n = _terms.length;
            for (uint256 i; i < n; ++i) {
                if (_terms[i] == term) {
                    _terms[i] = _terms[n - 1];
                    _terms.pop();
                    break;
                }
            }
        }
        termAllowed[term] = allowed;
        emit TermSet(term, allowed);
    }

    /// @notice Allows or removes an adapter for new loans; loans already open keep theirs.
    function setAdapter(address adapter, bool allowed) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        adapterAllowed[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    /// @notice Allows or removes a vault for new loans, the factory's included; loans already open keep theirs.
    function setVault(address vault, bool allowed) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        _vaultDecision[vault] = allowed ? 1 : 2;
        emit VaultSet(vault, allowed);
    }

    /// @notice Lets the vaults `factory` creates fund new loans (zero stops trusting any factory's vaults).
    function setVaultFactory(address factory) external onlyOwner {
        vaultFactory = factory;
        emit VaultFactorySet(factory);
    }

    /// @notice Allows or removes `curator` as one who may open a vault through the factory.
    function setCurator(address curator, bool allowed) external onlyOwner {
        if (curator == address(0)) revert ZeroAddress();
        curatorAllowed[curator] = allowed;
        emit CuratorSet(curator, allowed);
    }

    /// @notice Lets anyone open a vault through the factory (`true`), or only the curators allowed (`false`); vaults
    /// already open are not touched either way.
    function setOpenCreation(bool open) external onlyOwner {
        openCreation = open;
        emit OpenCreationSet(open);
    }

    /// @notice Whether `account` may open a vault through the factory: creation is open, or it is an allowed curator.
    function mayOpenVault(address account) external view returns (bool) {
        return openCreation || curatorAllowed[account];
    }

    /// @notice Whether `vault` may fund new loans: the owner allowed it, or the factory made it and the owner has not
    /// removed it.
    function vaultAllowed(address vault) external view returns (bool) {
        uint8 decision = _vaultDecision[vault];
        if (decision != 0) return decision == 1;
        address factory = vaultFactory;
        return factory != address(0) && ILPVaultFactoryView(factory).isVault(vault);
    }

    /// @notice Allows or removes a sale executor for recovered tokens.
    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        executorAllowed[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    /// @notice Sets a pool's admission and caps under `adapter` for new loans.
    function setPool(address adapter, address pool, PoolConfig calldata config) external onlyOwner {
        if (adapter == address(0) || pool == address(0)) revert ZeroAddress();
        if (config.minHalfWidthTicks > MAX_MIN_HALF_WIDTH_TICKS) revert HalfWidthAboveMax(config.minHalfWidthTicks);
        if (config.minLoanPrincipal > config.maxLoanPrincipal || config.maxLoanPrincipal > config.maxOutstanding) {
            revert PoolCapsInconsistent();
        }
        if (config.maxLoanPrincipal > MAX_POOL_LOAN_PRINCIPAL || config.maxOutstanding > MAX_POOL_OUTSTANDING) {
            revert PoolCapAboveMax(config.maxLoanPrincipal, config.maxOutstanding);
        }
        _pools[adapter][pool] = config;
        emit PoolSet(adapter, pool, config);
    }

    /// @notice A pool's admission and caps under `adapter`.
    function poolConfig(address adapter, address pool) external view returns (PoolConfig memory) {
        return _pools[adapter][pool];
    }

    /// @notice The terms new loans may use.
    function terms() external view returns (uint32[] memory) {
        return _terms;
    }

    function _setFee(uint16 bps) internal {
        if (bps > MAX_FEE_BPS) revert FeeAboveMax(bps, MAX_FEE_BPS);
        feeBps = bps;
        emit FeeSet(bps);
    }

    function _setLtvCap(uint16 bps) internal {
        if (bps > MAX_LTV_BPS) revert LtvAboveMax(bps, MAX_LTV_BPS);
        ltvCapBps = bps;
        emit LtvCapSet(bps);
    }

    function _setLateUnwindDelay(uint32 delay) internal {
        if (delay < MIN_LATE_UNWIND_DELAY || delay > MAX_LATE_UNWIND_DELAY) revert LateUnwindDelayOutOfRange(delay);
        lateUnwindDelay = delay;
        emit LateUnwindDelaySet(delay);
    }

    function _setQuoteSigner(address signer) internal {
        if (signer == address(0)) revert ZeroAddress();
        quoteSigner = signer;
        emit QuoteSignerSet(signer);
    }

    function _setFeeRecipient(address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }
}
