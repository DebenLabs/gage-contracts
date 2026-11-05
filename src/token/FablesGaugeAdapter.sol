// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {IFablesGaugeAdapter} from "../interfaces/token/IFablesGaugeAdapter.sol";
import {ILPRewards} from "../interfaces/token/ILPRewards.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";

/// @dev The wiring LPRewards exposes as public immutables; the adapter takes it from there, never from its deployer.
interface ILPRewardsWiring {
    function POSM() external view returns (IPositionManager);
    function DRIP() external view returns (IDrip);
    function SGAGE() external view returns (IERC20);
}

/// @dev Permit2 as the PositionManager exposes it (`Permit2Forwarder`'s public immutable).
interface IPermit2Source {
    function permit2() external view returns (address);
}

/// @title FablesGaugeAdapter
/// @notice Opt-in custody for GAGE/sGAGE position NFTs entered in the Fables gauge. The liquidity stays in the
///         same pool and range: only ownership of the NFT moves. While a position is held here, its trading fees go to
///         the fee sink (the gauge's Fables voters) once one is set, and to its depositor until then; its native
///         sGAGE goes to its depositor in full: every lump at once, every 7-day drip as it unlocks, even after the
///         depositor has withdrawn. The depositor withdraws the NFT at any time.
/// @dev A deposit pays the depositor the fees that came before. Each held position records the route epoch of its last
///      settlement (or its deposit), and its next settlement (a harvest anyone sends, a withdrawal) pays that route every
///      fee unpaid, also those earned after a later route change, and only then moves the position to the route in force.
///      A route change is one owner call that touches no position, so no number of held positions can delay or block it:
///      a new sink is accepted between SINK_DELAY and twice SINK_DELAY after its proposal, and a clear takes effect at
///      once. So that each fee reaches the route in force while it was earned, the owner's transaction changes the route
///      and settles the held positions read at execution with harvestRange, as many as one transaction holds (the
///      owner's batch caps them); a position it does not reach keeps paying the route of its last settlement until
///      anyone settles it (the keeper's cutover, on its next read). Fees owed to a sink are paid to it or the withdrawal
///      reverts, even after a clear, and no withdrawal runs inside a PositionManager action batch. Ownership cannot be
///      renounced, so a live sink can always be cleared. Nothing moves an NFT, a drip or a lump anywhere but to its
///      depositor. Positions arrive with `safeTransferFrom`: one sent with a plain `transferFrom` has no depositor and
///      stays here. Holding a position does not change its LPRewards weight; the seed and the floor bands cannot be
///      moved here.
contract FablesGaugeAdapter is IFablesGaugeAdapter, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev A held position: who deposited it, and the route epoch its unpaid fees were earned under.
    struct Holding {
        address depositor;
        uint64 routeEpoch;
    }

    /// @inheritdoc IFablesGaugeAdapter
    uint32 public constant SINK_DELAY = 7 days;

    IPositionManager public immutable POSM;
    ILPRewards public immutable LP_REWARDS;
    IDrip public immutable DRIP;
    IERC20 public immutable SGAGE;
    IERC20 public immutable TOKEN0;
    IERC20 public immutable TOKEN1;
    PoolId public immutable POOL_ID;
    /// @notice Permit2, read from the PositionManager: refused as a fee sink.
    address public immutable PERMIT2;
    /// @notice The chain's Universal Router, given at deployment: refused as a fee sink.
    address public immutable UNIVERSAL_ROUTER;

    /// @inheritdoc IFablesGaugeAdapter
    address public feeSink;
    /// @inheritdoc IFablesGaugeAdapter
    uint64 public routeEpoch;
    /// @inheritdoc IFablesGaugeAdapter
    address public pendingFeeSink;
    /// @inheritdoc IFablesGaugeAdapter
    uint40 public pendingFeeSinkAt;
    /// @inheritdoc IFablesGaugeAdapter
    mapping(bytes32 dripId => address) public dripBeneficiary;
    mapping(uint256 tokenId => Holding) internal _holdings;
    /// @dev The route of every epoch before `routeEpoch`; the current one is `feeSink`.
    mapping(uint64 epoch => address) internal _pastRoute;
    EnumerableSet.UintSet internal _held;
    mapping(address depositor => EnumerableSet.UintSet) internal _deposits;
    mapping(address depositor => bytes32[]) internal _drips;

    /// @param lpRewards The live LPRewards; the PositionManager, Drip, sGAGE and pool are read from it.
    /// @param initialOwner The only account that can propose, switch to and clear a fee sink: gage's Safe, never the
    /// deployment EOA.
    /// @param universalRouter The chain's Universal Router, which would hold fees sent to it: refused as a sink.
    constructor(ILPRewards lpRewards, address initialOwner, address universalRouter) Ownable(initialOwner) {
        if (address(lpRewards) == address(0) || universalRouter == address(0)) revert ZeroAddress();
        ILPRewardsWiring wiring = ILPRewardsWiring(address(lpRewards));
        IPositionManager posm = wiring.POSM();
        IDrip drip = wiring.DRIP();
        IERC20 sgage = wiring.SGAGE();
        if (address(posm) == address(0) || address(drip) == address(0) || address(sgage) == address(0)) {
            revert ZeroAddress();
        }
        PoolKey memory key = lpRewards.poolKey();
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (token0 == address(0) || (token0 != address(sgage) && token1 != address(sgage))) revert InvalidPool();
        POSM = posm;
        LP_REWARDS = lpRewards;
        DRIP = drip;
        SGAGE = sgage;
        TOKEN0 = IERC20(token0);
        TOKEN1 = IERC20(token1);
        POOL_ID = key.toId();
        address permit2 = IPermit2Source(address(posm)).permit2();
        if (permit2 == address(0)) revert ZeroAddress();
        PERMIT2 = permit2;
        UNIVERSAL_ROUTER = universalRouter;
    }

    // ----------------------------------------------------------------- deposit

    /// @notice A position NFT arrives through `safeTransferFrom`: its depositor is the account it came from. Fees and
    ///         native rewards earned before this moment are paid to the depositor here.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(POSM)) revert NotPositionManager();
        (PoolKey memory key, PositionInfo info) = POSM.getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(POOL_ID)) revert WrongPool(tokenId);
        uint128 liquidity = POSM.getPositionLiquidity(tokenId);
        if (liquidity == 0) revert EmptyPosition(tokenId);
        // It earns under the route in force from here; what it earned before is paid to its depositor just below.
        _holdings[tokenId] = Holding({depositor: from, routeEpoch: routeEpoch});
        _held.add(tokenId);
        _deposits[from].add(tokenId);
        _takeFees(tokenId, from);
        _collectNative(tokenId, from);
        emit Deposited(tokenId, from, info.tickLower(), info.tickUpper(), liquidity);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ----------------------------------------------------------------- held positions

    /// @inheritdoc IFablesGaugeAdapter
    function harvest(uint256[] calldata tokenIds) external nonReentrant {
        uint64 epoch = routeEpoch;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            _harvest(tokenIds[i], epoch);
        }
    }

    /// @inheritdoc IFablesGaugeAdapter
    function harvestRange(uint256 start, uint256 count) external nonReentrant {
        uint256 end = _rangeEnd(start, count);
        uint64 epoch = routeEpoch;
        // Nothing here can withdraw (nonReentrant), so the held list keeps its order through the loop.
        for (uint256 i = start; i < end; ++i) {
            _harvest(_held.at(i), epoch);
        }
    }

    /// @inheritdoc IFablesGaugeAdapter
    function collectNative(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            address depositor = _holdings[tokenIds[i]].depositor;
            if (depositor == address(0)) continue;
            if (msg.sender != depositor) revert NotDepositor(tokenIds[i], msg.sender);
            _collectNative(tokenIds[i], depositor);
        }
    }

    /// @inheritdoc IFablesGaugeAdapter
    function claimDrips(bytes32[] calldata dripIds) external nonReentrant returns (uint256 total) {
        for (uint256 i = 0; i < dripIds.length; ++i) {
            bytes32 dripId = dripIds[i];
            address beneficiary = dripBeneficiary[dripId];
            if (beneficiary == address(0)) revert UnknownDrip(dripId);
            if (DRIP.claimable(address(this), dripId) == 0) continue;
            uint256 amount = DRIP.claim(dripId);
            SGAGE.safeTransfer(beneficiary, amount);
            total += amount;
            emit DripClaimed(dripId, beneficiary, amount);
        }
    }

    // ----------------------------------------------------------------- withdraw

    /// @inheritdoc IFablesGaugeAdapter
    function withdraw(uint256 tokenId, address to) external nonReentrant {
        // Inside a PositionManager action batch the fee settlement cannot run while the NFT can still move.
        if (IMsgSender(address(POSM)).msgSender() != address(0)) revert PositionManagerBusy();
        Holding memory holding = _holdings[tokenId];
        address depositor = holding.depositor;
        if (depositor == address(0)) revert NotDeposited(tokenId);
        if (msg.sender != depositor) revert NotDepositor(tokenId, msg.sender);
        // Sent back here with a plain transfer, the NFT would have no depositor and could never leave.
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        address recipient = _recipient(holding);
        if (recipient != depositor) {
            // Fees earned under a sink are paid to it or the withdrawal reverts, cleared since or not.
            _takeFees(tokenId, recipient);
        } else {
            // Fees earned under no sink are the depositor's: a failed settlement leaves them in the NFT it takes.
            try this.settleFees(tokenId, recipient) {}
            catch {
                emit ExitFeesSkipped(tokenId);
            }
        }
        try this.settleNativeOnExit(tokenId, depositor) {}
        catch {
            emit ExitRewardsSkipped(tokenId);
        }
        delete _holdings[tokenId];
        _held.remove(tokenId);
        _deposits[depositor].remove(tokenId);
        IERC721(address(POSM)).transferFrom(address(this), to, tokenId);
        emit Withdrawn(tokenId, depositor, to);
    }

    /// @inheritdoc IFablesGaugeAdapter
    function settleFees(uint256 tokenId, address recipient) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _takeFees(tokenId, recipient);
    }

    /// @inheritdoc IFablesGaugeAdapter
    function settleNativeOnExit(uint256 tokenId, address depositor) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _collectNative(tokenId, depositor);
    }

    // ----------------------------------------------------------------- fee sink

    /// @inheritdoc IFablesGaugeAdapter
    function proposeFeeSink(address sink) external onlyOwner {
        if (_unfitSink(sink)) revert InvalidSink(sink);
        // A proposal this one replaces, or a clear drops, says so.
        address pending = pendingFeeSink;
        if (pending != address(0)) {
            delete pendingFeeSink;
            delete pendingFeeSinkAt;
            emit FeeSinkCancelled(pending);
        }
        if (sink == address(0)) {
            _setRoute(address(0));
            return;
        }
        uint40 effectiveAt = uint40(block.timestamp) + SINK_DELAY;
        pendingFeeSink = sink;
        pendingFeeSinkAt = effectiveAt;
        emit FeeSinkProposed(sink, effectiveAt);
    }

    /// @inheritdoc IFablesGaugeAdapter
    function acceptFeeSink() external onlyOwner {
        address sink = pendingFeeSink;
        uint40 effectiveAt = pendingFeeSinkAt;
        if (sink == address(0)) revert NoPendingSink();
        if (block.timestamp < effectiveAt) revert SinkNotReady(effectiveAt);
        if (block.timestamp > uint256(effectiveAt) + SINK_DELAY) revert SinkProposalExpired(effectiveAt);
        delete pendingFeeSink;
        delete pendingFeeSinkAt;
        _setRoute(sink);
    }

    /// @inheritdoc IFablesGaugeAdapter
    function cancelFeeSink() external onlyOwner {
        address sink = pendingFeeSink;
        if (sink == address(0)) revert NoPendingSink();
        delete pendingFeeSink;
        delete pendingFeeSinkAt;
        emit FeeSinkCancelled(sink);
    }

    /// @notice Disabled: with no owner, a live sink could never be cleared.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ----------------------------------------------------------------- views

    /// @inheritdoc IFablesGaugeAdapter
    function depositorOf(uint256 tokenId) external view returns (address) {
        return _holdings[tokenId].depositor;
    }

    /// @inheritdoc IFablesGaugeAdapter
    function routeEpochOf(uint256 tokenId) external view returns (uint64) {
        return _holdings[tokenId].routeEpoch;
    }

    /// @inheritdoc IFablesGaugeAdapter
    function feeRouteOf(uint256 tokenId) external view returns (address) {
        Holding memory holding = _holdings[tokenId];
        return holding.depositor == address(0) ? address(0) : _recipient(holding);
    }

    /// @inheritdoc IFablesGaugeAdapter
    function depositsOf(address depositor) external view returns (uint256[] memory) {
        return _deposits[depositor].values();
    }

    /// @inheritdoc IFablesGaugeAdapter
    function dripsOf(address depositor) external view returns (bytes32[] memory) {
        return _drips[depositor];
    }

    /// @inheritdoc IFablesGaugeAdapter
    function heldCount() external view returns (uint256) {
        return _held.length();
    }

    /// @inheritdoc IFablesGaugeAdapter
    function heldIds(uint256 start, uint256 count) external view returns (uint256[] memory ids) {
        uint256 end = _rangeEnd(start, count);
        if (end <= start) return ids;
        ids = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) {
            ids[i - start] = _held.at(i);
        }
    }

    // ----------------------------------------------------------------- internal

    /// @dev The end of the held list's range from `start` for `count` (exclusive), never past its end and never
    ///      overflowing: `start` itself when the range is empty.
    function _rangeEnd(uint256 start, uint256 count) internal view returns (uint256) {
        uint256 n = _held.length();
        if (start >= n) return start;
        return count >= n - start ? n : start + count;
    }

    /// @dev One held position's fees to the route of its last settlement, then the position to the route in force.
    function _harvest(uint256 tokenId, uint64 epoch) internal {
        Holding memory holding = _holdings[tokenId];
        if (holding.depositor == address(0)) return;
        address recipient = _recipient(holding);
        if (holding.routeEpoch != epoch) _holdings[tokenId].routeEpoch = epoch;
        _takeFees(tokenId, recipient);
    }

    /// @dev Who a held position's unpaid fees go to: the route of its last settlement or deposit (for every fee unpaid,
    ///      also one earned after a later route change), or its depositor when that route is zero.
    function _recipient(Holding memory holding) internal view returns (address) {
        address route = holding.routeEpoch == routeEpoch ? feeSink : _pastRoute[holding.routeEpoch];
        return route == address(0) ? holding.depositor : route;
    }

    /// @dev A new route epoch when the route changes, and nothing (no event either) when it does not: positions keep
    ///      the old one until their next settlement.
    function _setRoute(address route) internal {
        address current = feeSink;
        if (route == current) return;
        uint64 epoch = routeEpoch;
        _pastRoute[epoch] = current;
        routeEpoch = ++epoch;
        feeSink = route;
        emit FeeSinkSet(route, epoch);
    }

    /// @dev Whether `sink` cannot be proposed: where the PositionManager would send fees elsewhere (its MSG_SENDER and
    ///      ADDRESS_THIS placeholders, itself, the PoolManager, this adapter), the known contracts that would hold them
    ///      for good (the pool's two tokens, LPRewards, Drip, the pool's hook, Permit2, the Universal Router), or the
    ///      sink in force, whose accept would change no route. Best effort: any address that cannot move what it
    ///      receives would hold the fees too, so the owner still picks a sink that can. Zero, the clear, is always fit.
    function _unfitSink(address sink) internal view returns (bool) {
        if (sink == address(0)) return false;
        return sink == feeSink || sink == address(this) || sink == ActionConstants.MSG_SENDER
            || sink == ActionConstants.ADDRESS_THIS || sink == address(POSM) || sink == address(POSM.poolManager())
            || sink == address(TOKEN0) || sink == address(TOKEN1) || sink == address(LP_REWARDS)
            || sink == address(DRIP) || sink == address(LP_REWARDS.poolKey().hooks) || sink == PERMIT2
            || sink == UNIVERSAL_ROUTER;
    }

    /// @dev Fees only: a zero-liquidity decrease, both tokens straight to `to`.
    function _takeFees(uint256 tokenId, address to) internal {
        uint256 before0 = TOKEN0.balanceOf(to);
        uint256 before1 = TOKEN1.balanceOf(to);
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(address(TOKEN0)), Currency.wrap(address(TOKEN1)), to);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesTaken(tokenId, to, TOKEN0.balanceOf(to) - before0, TOKEN1.balanceOf(to) - before1);
    }

    /// @dev LPRewards grants the drip to this adapter (the NFT's owner); it is recorded for `depositor` here.
    function _collectNative(uint256 tokenId, address depositor) internal {
        (uint256 emissions, uint256 lump) = LP_REWARDS.earned(tokenId);
        if (emissions == 0 && lump == 0) return;
        (emissions, lump) = LP_REWARDS.collect(tokenId);
        bytes32 dripId;
        if (emissions > 0) {
            dripId = LP_REWARDS.dripIdOf(tokenId, LP_REWARDS.positionState(tokenId).collectNonce);
            dripBeneficiary[dripId] = depositor;
            _drips[depositor].push(dripId);
        }
        if (lump > 0) SGAGE.safeTransfer(depositor, lump);
        emit NativeCollected(tokenId, depositor, emissions, dripId, lump);
    }
}
