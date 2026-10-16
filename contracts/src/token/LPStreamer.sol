// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ILPStreamer} from "../interfaces/token/ILPStreamer.sol";
import {IEmissions} from "../interfaces/token/IEmissions.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";
import {Drip} from "./Drip.sol";
import {LPRewards} from "./LPRewards.sol";

/// @title LPStreamer
/// @notice A second sGAGE stream for the GAGE/sGAGE pool that pays by liquidity held over time, on the existing
///         pool and its immutable LPRewards, without a hook (D64). It mirrors LPRewards: what a position accrues
///         from the per-second emission stream in an epoch is the exact measure of the weight it held over that
///         epoch, and the hook keeps that accrual right on every add and remove. Each epoch has a pot, fixed at
///         the epoch's start from everything deposited during the epoch before; a position is paid
///         pot × (its accrual in the epoch / the epoch's liquidity budget). A position minted for one block
///         accrues nothing in LPRewards and so earns nothing here. Rewards accrue to the tokenId; the current
///         owner collects into a 7-day drip on the streamer's own Drip (the live Drip only takes grants from its
///         launch grantors), the same quadratic curve as LPRewards' emissions (D48). This contract never holds a
///         position NFT (T5) and has no owner.
/// @dev One ordering rule: collect here before LPRewards.collect, which resets the accrual this contract reads. A
///      direct LPRewards.collect forfeits the accrual since this contract last saw the position, and only the
///      owner can trigger it. LPRewards checkpoints by anyone only bank accrual and change nothing here. An
///      interval that spans epochs is paid at the smallest pot rate it touches, so what is paid never exceeds what
///      was deposited, epoch by epoch; the keeper checkpoints every position around each epoch boundary to keep
///      that rounding small. The stream ends with the Emissions table.
contract LPStreamer is ILPStreamer, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e27;
    uint32 public constant DRIP_LENGTH = 7 days;

    IERC20 public immutable SGAGE;
    IDrip public immutable DRIP;
    LPRewards public immutable REWARDS;
    IEmissions public immutable EMISSIONS;
    IERC721 public immutable POSM;
    uint256 public immutable EPOCH;
    uint256 public immutable WEEKS;

    uint256 public pending;
    uint256 public assignedThrough;
    mapping(uint256 epoch => uint256) public pot;
    mapping(uint256 epoch => uint256) public rate;
    mapping(uint256 tokenId => Position) internal _positions;

    constructor(IERC20 sgage, LPRewards rewards) {
        if (address(sgage) == address(0) || address(rewards) == address(0)) revert ZeroAddress();
        SGAGE = sgage;
        REWARDS = rewards;
        EMISSIONS = rewards.EMISSIONS();
        POSM = IERC721(address(rewards.POSM()));
        EPOCH = EMISSIONS.EPOCH();
        WEEKS = EMISSIONS.WEEKS();
        assignedThrough = EMISSIONS.currentEpoch();
        Drip drip = new Drip(sgage, address(this));
        drip.setGrantors(address(this), address(this));
        DRIP = drip;
    }

    // ----------------------------------------------------------------- inflow

    /// @inheritdoc ILPStreamer
    function deposit(uint256 amount) external nonReentrant {
        _roll();
        uint256 next = assignedThrough + 1;
        if (next >= WEEKS) revert ScheduleOver();
        SGAGE.safeTransferFrom(msg.sender, address(this), amount);
        pending += amount;
        emit Deposited(msg.sender, amount, next);
    }

    // ----------------------------------------------------------------- checkpoints

    /// @inheritdoc ILPStreamer
    function checkpoint(uint256 tokenId) external {
        _roll();
        _checkpoint(tokenId);
    }

    /// @inheritdoc ILPStreamer
    function checkpointMany(uint256[] calldata tokenIds) external {
        _roll();
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            _checkpoint(tokenIds[i]);
        }
    }

    // ----------------------------------------------------------------- collect

    /// @inheritdoc ILPStreamer
    function collect(uint256 tokenId) external nonReentrant returns (uint256 amount) {
        address owner = POSM.ownerOf(tokenId);
        if (owner != msg.sender) revert NotOwner(tokenId, msg.sender);
        _roll();
        _checkpoint(tokenId);
        Position storage p = _positions[tokenId];
        amount = p.earned;
        if (amount == 0) revert NothingToCollect(tokenId);
        p.earned = 0;
        bytes32 dripId = dripIdOf(tokenId, ++p.collectNonce);
        SGAGE.forceApprove(address(DRIP), amount);
        DRIP.grant(owner, dripId, uint128(amount), uint40(block.timestamp), DRIP_LENGTH);
        emit Collected(tokenId, owner, amount, dripId);
    }

    // ----------------------------------------------------------------- views

    /// @inheritdoc ILPStreamer
    function earned(uint256 tokenId) external view returns (uint256) {
        Position storage p = _positions[tokenId];
        (uint256 credit,,) = _pendingCredit(p, tokenId);
        return p.earned + credit;
    }

    /// @inheritdoc ILPStreamer
    function positionState(uint256 tokenId) external view returns (Position memory) {
        return _positions[tokenId];
    }

    /// @inheritdoc ILPStreamer
    function dripIdOf(uint256 tokenId, uint32 collectNonce) public pure returns (bytes32) {
        return keccak256(abi.encode("lp-stream", tokenId, collectNonce));
    }

    // ----------------------------------------------------------------- internal

    function _checkpoint(uint256 tokenId) internal {
        Position storage p = _positions[tokenId];
        (uint256 credit, uint256 accrual, uint32 nonce) = _pendingCredit(p, tokenId);
        uint256 cur = EMISSIONS.currentEpoch();
        if (p.seen) {
            p.earned += credit;
            emit Checkpointed(tokenId, accrual, credit, cur);
        } else {
            p.seen = true;
        }
        p.accrualSeen = accrual;
        p.collectNonceSeen = nonce;
        p.epochSeen = cur;
    }

    /// @dev The credit for the LPRewards accrual since the last checkpoint here, at the smallest rate of the epochs
    ///      the interval touches. The part before an LPRewards.collect in the interval is forfeited.
    function _pendingCredit(Position storage p, uint256 tokenId)
        internal
        view
        returns (uint256 credit, uint256 accrual, uint32 nonce)
    {
        (accrual,) = REWARDS.earned(tokenId);
        nonce = REWARDS.positionState(tokenId).collectNonce;
        if (!p.seen) return (0, accrual, nonce);
        uint256 delta;
        if (nonce == p.collectNonceSeen) delta = accrual > p.accrualSeen ? accrual - p.accrualSeen : 0;
        else delta = accrual;
        if (delta == 0) return (0, accrual, nonce);
        uint256 cur = EMISSIONS.currentEpoch();
        uint256 r = _rateOf(p.epochSeen);
        for (uint256 e = p.epochSeen + 1; e <= cur; ++e) {
            uint256 re = _rateOf(e);
            if (re < r) r = re;
        }
        credit = (delta * r) / PRECISION;
    }

    /// @dev The rate of a fixed epoch, or what the next one will be fixed at from `pending`, so views are right
    ///      before anyone rolls.
    function _rateOf(uint256 epoch) internal view returns (uint256) {
        if (epoch <= assignedThrough) return rate[epoch];
        if (epoch == assignedThrough + 1) return _rateFor(epoch, pending);
        return 0;
    }

    function _rateFor(uint256 epoch, uint256 amount) internal view returns (uint256) {
        uint256 budget = REWARDS.emissionRate(epoch) * EPOCH;
        return budget == 0 ? 0 : (amount * PRECISION) / budget;
    }

    /// @dev Fix the pot of every epoch that has started since the last roll: the first gets `pending`, later ones
    ///      nothing.
    function _roll() internal {
        uint256 cur = EMISSIONS.currentEpoch();
        while (assignedThrough < cur) {
            uint256 e = ++assignedThrough;
            uint256 amount = pending;
            pending = 0;
            pot[e] = amount;
            rate[e] = _rateFor(e, amount);
            emit PotFixed(e, amount, rate[e]);
        }
    }
}
