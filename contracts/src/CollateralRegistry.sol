// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ICollateralRegistry, PairAsset, Lane} from "./interfaces/ICollateralRegistry.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title CollateralRegistry
/// @notice Allowlists, minimums, caps, terms, fee and the pause of new deals. Owner: the deployment wallet.
/// @dev Every adjustable parameter has a compile-time bound (spec 13, I12). Pausing affects only
///      `list`, `bid` and `accept` on the vault (spec I3); the registry has no other reach.
contract CollateralRegistry is ICollateralRegistry, Ownable2Step {
    uint16 public constant MAX_FEE_BPS = 200;
    uint32 public constant MIN_TERM = 1 days;
    uint32 public constant MAX_TERM = 30 days;
    uint256 public constant MAX_TERMS = 8;
    /// @dev Bit i of `memePairMask` is PairAsset(i): STOCK = 1, USDG = 2, ETH = 4.
    uint8 public constant MEME_PAIR_STOCK = 1;
    uint8 public constant MEME_PAIR_USDG = 2;
    uint8 public constant MEME_PAIR_ETH = 4;
    uint8 public constant MEME_PAIR_ALL = MEME_PAIR_STOCK | MEME_PAIR_USDG | MEME_PAIR_ETH;

    mapping(address token => ERC20Config) internal _erc20;
    mapping(bytes32 poolId => PoolConfig) internal _pools;
    mapping(bytes32 poolId => bytes32) public removalHookCodeHash;
    mapping(uint32 term => bool) internal _termAllowed;
    uint32[] internal _terms;

    uint16 public feeBps;
    bool public inRangeRequired;
    bool public newDealsPaused;
    mapping(address account => bool) public isRouter;
    /// @notice Which pair assets qualify a meme pool (spec open decision 23). Default: Stock Tokens only.
    uint8 public memePairMask;

    error ZeroAddress();
    error FeeAboveMax(uint16 bps, uint16 max);
    error TermOutOfBounds(uint32 term);
    error TooManyTerms(uint256 count, uint256 max);
    error NoTerms();
    error DuplicateTerm(uint32 term);
    error CapsInconsistent();
    error MemePairMaskInvalid(uint8 mask);
    error InvalidRemovalHook();

    constructor(address initialOwner, uint32[] memory terms, uint16 initialFeeBps) Ownable(initialOwner) {
        _setTerms(terms);
        _setFee(initialFeeBps);
        _setMemePairs(MEME_PAIR_STOCK);
    }

    // ----------------------------------------------------------------- owner

    /// @notice Allow or disallow an ERC-20 as collateral, with its lane, minimum, per-deal cap and open cap (raw units).
    /// @dev Memes: the registry owner applies spec 7.4 off-chain (stock-paired v4 pool, 7-day age, 1,000,000 USDG market cap,
    ///      clean contract checks) before calling this, and revisits the caps weekly. The ERC-20 adapter does not read `lane`; the position adapter checks both underlying lanes.
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
        _erc20[token] = ERC20Config({
            allowed: ok, lane: lane, minAmount: minAmount, maxDealRaw: maxDealRaw, maxOpenRaw: maxOpenRaw
        });
        emit ERC20Set(token, ok, lane, minAmount, maxDealRaw, maxOpenRaw);
    }

    /// @notice Allow or disallow a Uniswap v4 pool for position collateral (M2).
    function setPoolAllowed(bytes32 poolId, bool ok, uint128 minLiquidity) external onlyOwner {
        _pools[poolId] = PoolConfig({allowed: ok, minLiquidity: minLiquidity});
        emit PoolSet(poolId, ok, minLiquidity);
    }

    /// @notice Approve a reviewed, non-proxy hook whose removal callback only observes/emits. Zero revokes.
    /// @dev Pool IDs include the hook address. Before-remove and return-delta permissions can never be exempted.
    ///      Review must establish immutable removal behavior; a proxy's code hash does not pin its implementation.
    function setPoolRemovalHook(bytes32 poolId, address hook, bytes32 codeHash) external onlyOwner {
        if (codeHash != bytes32(0)) {
            uint160 flags = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
            if (
                hook.code.length == 0 || hook.codehash != codeHash
                    || uint160(hook) & flags != Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) revert InvalidRemovalHook();
        }
        removalHookCodeHash[poolId] = codeHash;
        emit PoolRemovalHookSet(poolId, hook, codeHash);
    }

    /// @notice Replace the allowed term set. Each term within [MIN_TERM, MAX_TERM], at most MAX_TERMS, no duplicates.
    function setTerms(uint32[] calldata terms) external onlyOwner {
        _setTerms(terms);
    }

    /// @notice Protocol fee in basis points on the accepted price. Bounded by MAX_FEE_BPS.
    function setFee(uint16 bps) external onlyOwner {
        _setFee(bps);
    }

    function setInRangeRequired(bool required) external onlyOwner {
        inRangeRequired = required;
        emit InRangeRequiredSet(required);
    }

    /// @notice Stop new deals. Never touches existing deals (spec I3).
    function pauseNewDeals(bool paused) external onlyOwner {
        newDealsPaused = paused;
        emit NewDealsPausedSet(paused);
    }

    /// @notice Allow a stateless router (EntryRouter) to place bids on behalf of the account that called it.
    function setRouter(address router, bool ok) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = ok;
        emit RouterSet(router, ok);
    }

    /// @notice Set which pair assets qualify a meme's pool. Any non-empty subset of {STOCK, USDG, ETH}.
    /// @dev Read by the screening service, indexer and meme/stock position adapter. Resolves spec open decision 23
    ///      either way without a redeploy.
    function setMemePairs(uint8 mask) external onlyOwner {
        _setMemePairs(mask);
    }

    // ----------------------------------------------------------------- views

    function getERC20Config(address token) external view returns (ERC20Config memory) {
        return _erc20[token];
    }

    function getPoolConfig(bytes32 poolId) external view returns (PoolConfig memory) {
        return _pools[poolId];
    }

    function isTermAllowed(uint32 term) external view returns (bool) {
        return _termAllowed[term];
    }

    function allowedTerms() external view returns (uint32[] memory) {
        return _terms;
    }

    function isMemePairAllowed(PairAsset pair) external view returns (bool) {
        return memePairMask & (uint8(1) << uint8(pair)) != 0;
    }

    // ----------------------------------------------------------------- internal

    function _setTerms(uint32[] memory terms) internal {
        if (terms.length == 0) revert NoTerms();
        if (terms.length > MAX_TERMS) revert TooManyTerms(terms.length, MAX_TERMS);
        uint256 oldLen = _terms.length;
        for (uint256 i = 0; i < oldLen; ++i) {
            _termAllowed[_terms[i]] = false;
        }
        delete _terms;
        for (uint256 i = 0; i < terms.length; ++i) {
            uint32 t = terms[i];
            if (t < MIN_TERM || t > MAX_TERM) revert TermOutOfBounds(t);
            if (_termAllowed[t]) revert DuplicateTerm(t);
            _termAllowed[t] = true;
            _terms.push(t);
        }
        emit TermsSet(terms);
    }

    function _setMemePairs(uint8 mask) internal {
        if (mask == 0 || mask > MEME_PAIR_ALL) revert MemePairMaskInvalid(mask);
        memePairMask = mask;
        emit MemePairsSet(mask);
    }

    function _setFee(uint16 bps) internal {
        if (bps > MAX_FEE_BPS) revert FeeAboveMax(bps, MAX_FEE_BPS);
        feeBps = bps;
        emit FeeSet(bps);
    }
}
