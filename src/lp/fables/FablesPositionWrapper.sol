// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IFablesLedger} from "../interfaces/IFablesLedger.sol";
import {FablesShareHolder} from "./FablesShareHolder.sol";

/// @title FablesPositionWrapper
/// @notice Turns Fables LP receipts into a position NFT, so any holder of NFTs (the LP lane's escrow among them) can
/// hold and operate them. Each NFT has its own holder clone that keeps that position's receipts: the hook books fees to
/// each position separately, and the NFT's owner, or whoever the owner approved, withdraws or collects them. No owner,
/// no fee, nothing upgradable. A position's receipts and fees leave its holder only on a call by the NFT's owner or an
/// account the owner approved, and go to whatever address that caller names: `unwrap` sends the receipts and their
/// fees, `withdraw` burns receipts and pays out the liquidity they stand for, and `collectFees` pays the fees.
/// @dev Fables' `withdraw` and `claimFees` act only for the caller's own receipts, which is why a position needs an
/// account of its own rather than the borrower's or the escrow's.
contract FablesPositionWrapper is ERC721, ReentrancyGuardTransient {
    struct Position {
        address holder;
        uint256 rangeId;
    }

    /// @notice The Fables hook whose receipts this wrapper holds.
    IFablesLedger public immutable HOOK;
    /// @notice The holder every position clones.
    address public immutable HOLDER_IMPLEMENTATION;

    /// @notice The id the next position takes.
    uint256 public nextTokenId = 1;
    mapping(uint256 tokenId => Position) internal _positions;

    event Wrapped(uint256 indexed tokenId, address indexed to, uint256 indexed rangeId, uint128 shares, address holder);
    event Unwrapped(uint256 indexed tokenId, address indexed to, uint256 shares);

    error ZeroAddress();
    error ZeroShares();
    error WrongHook(address hooks);

    constructor(IFablesLedger hook) ERC721("gage Fables position", "GAGE-FBL") {
        if (address(hook) == address(0)) revert ZeroAddress();
        HOOK = hook;
        HOLDER_IMPLEMENTATION = address(new FablesShareHolder());
    }

    /// @notice Moves `shares` of the caller's receipts of one range into a new position and mints its NFT to `to`.
    /// @dev The caller must first let this wrapper move them (`HOOK.approve(wrapper, rangeId, shares)` or
    /// `HOOK.setOperator(wrapper, true)`), and they must be unstaked. The hook refuses a transfer while it is paused.
    function wrap(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares, address to)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (shares == 0) revert ZeroShares();
        if (to == address(0)) revert ZeroAddress();
        if (address(key.hooks) != address(HOOK)) revert WrongHook(address(key.hooks));
        uint256 id = HOOK.rangeId(key.toId(), tickLower, tickUpper);
        address holder = Clones.clone(HOLDER_IMPLEMENTATION);
        tokenId = nextTokenId++;
        _positions[tokenId] = Position({holder: holder, rangeId: id});
        HOOK.transferFrom(msg.sender, holder, id, shares);
        _mint(to, tokenId);
        emit Wrapped(tokenId, to, id, shares, holder);
    }

    /// @notice Burns position `tokenId` and sends its fees and receipts to `to`. The owner or an approved account only.
    function unwrap(uint256 tokenId, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
        Position memory p = _positions[tokenId];
        delete _positions[tokenId];
        _burn(tokenId);
        uint256 shares = HOOK.balanceOf(p.holder, p.rangeId);
        (PoolKey memory key, int24 tickLower, int24 tickUpper,) = HOOK.rangeKey(p.rangeId);
        FablesShareHolder holder = FablesShareHolder(p.holder);
        if (shares != 0) {
            // Fees first: receipts leave their fees behind with the account they leave.
            holder.claimFees(HOOK, key, tickLower, tickUpper, to, type(uint16).max);
            holder.transferShares(HOOK, to, p.rangeId, shares);
        } else {
            // A withdrawn position may still be owed fees; with none owed the hook refuses the claim.
            try holder.claimFees(HOOK, key, tickLower, tickUpper, to, type(uint16).max) {} catch {}
        }
        emit Unwrapped(tokenId, to, shares);
    }

    /// @notice Withdraws `liquidity` of position `tokenId` to `to` within the minimums (never paused by the hook). The
    /// owner or an approved account only.
    function withdraw(uint256 tokenId, uint128 liquidity, address to, uint128 min0, uint128 min1, uint256 deadline)
        external
        nonReentrant
    {
        _checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
        Position memory p = _positions[tokenId];
        (PoolKey memory key, int24 tickLower, int24 tickUpper,) = HOOK.rangeKey(p.rangeId);
        FablesShareHolder(p.holder).withdraw(HOOK, key, tickLower, tickUpper, liquidity, to, min0, min1, deadline);
    }

    /// @notice Pays position `tokenId`'s fees to `to`, refused while the hook's claim fee is above `maxFeeBps`. The
    /// owner or an approved account only.
    function collectFees(uint256 tokenId, address to, uint16 maxFeeBps) external nonReentrant {
        _checkAuthorized(_requireOwned(tokenId), msg.sender, tokenId);
        Position memory p = _positions[tokenId];
        (PoolKey memory key, int24 tickLower, int24 tickUpper,) = HOOK.rangeKey(p.rangeId);
        FablesShareHolder(p.holder).claimFees(HOOK, key, tickLower, tickUpper, to, maxFeeBps);
    }

    /// @notice Position `tokenId`: its pool key, range, receipts (liquidity units, 1:1), holder and range id.
    function position(uint256 tokenId)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 shares, address holder, uint256 rangeId)
    {
        _requireOwned(tokenId);
        Position memory p = _positions[tokenId];
        (key, tickLower, tickUpper,) = HOOK.rangeKey(p.rangeId);
        shares = uint128(HOOK.balanceOf(p.holder, p.rangeId));
        holder = p.holder;
        rangeId = p.rangeId;
    }
}
