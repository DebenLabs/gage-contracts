// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title IFablesGaugeAdapter
/// @notice Opt-in custody for GAGE/sGAGE position NFTs entered in the Fables gauge. The liquidity stays in the
///         same pool and range. While a position is held here, its trading fees go to the fee sink (the gauge's Fables
///         voters) once one is set, and to its depositor until then; its native sGAGE (each 7-day drip and every lump)
///         goes to its depositor in full. The depositor withdraws the NFT at any time.
interface IFablesGaugeAdapter is IERC721Receiver {
    /// @notice A position arrived. Its liquidity cannot change while it is held here.
    event Deposited(
        uint256 indexed tokenId, address indexed depositor, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event Withdrawn(uint256 indexed tokenId, address indexed depositor, address to);
    /// @notice A position's trading fees, taken without touching its principal and sent to `recipient`: the depositor
    ///         (fees earned before the deposit, or while no sink is set) or the fee sink.
    event FeesTaken(uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1);
    /// @notice Native rewards collected for a held position: `emissions` drip under `dripId` for `depositor`, `lump`
    ///         sGAGE paid to it at once.
    event NativeCollected(
        uint256 indexed tokenId, address indexed depositor, uint256 emissions, bytes32 dripId, uint256 lump
    );
    event DripClaimed(bytes32 indexed dripId, address indexed beneficiary, uint256 amount);
    event FeeSinkProposed(address indexed sink, uint40 effectiveAt);
    /// @notice The fee route changed to `sink` (zero: each position's depositor) under `epoch`; emitted only when the
    ///         route changes. Each held position moves to it at its next settlement, which first pays the route of its
    ///         last settlement every fee unpaid.
    event FeeSinkSet(address indexed sink, uint64 epoch);
    /// @notice The proposal of `sink` was dropped: by `cancelFeeSink`, by a new proposal, or by a clear.
    event FeeSinkCancelled(address indexed sink);
    /// @notice A withdrawal with no sink set went ahead without taking the position's fees; they stay in the position,
    ///         which goes to the depositor, whose fees they are.
    event ExitFeesSkipped(uint256 indexed tokenId);
    /// @notice A withdrawal went ahead without collecting the position's native rewards; they stay on its tokenId.
    event ExitRewardsSkipped(uint256 indexed tokenId);

    error InvalidPool();
    error NotPositionManager();
    error PositionManagerBusy();
    error WrongPool(uint256 tokenId);
    error EmptyPosition(uint256 tokenId);
    error NotDeposited(uint256 tokenId);
    error NotDepositor(uint256 tokenId, address caller);
    error UnknownDrip(bytes32 dripId);
    error OnlySelf();
    error ZeroAddress();
    error InvalidRecipient(address to);
    error RenounceDisabled();
    error InvalidSink(address sink);
    error NoPendingSink();
    error SinkNotReady(uint40 effectiveAt);
    error SinkProposalExpired(uint40 effectiveAt);

    /// @notice How long a proposed fee sink waits before the owner can accept it (time for every depositor to
    ///         withdraw), and how long after that the owner has to accept it before the proposal lapses.
    function SINK_DELAY() external view returns (uint32);

    /// @notice The fee route in force: where held positions' trading fees go from their first settlement under it;
    ///         zero sends them to each position's depositor.
    function feeSink() external view returns (address);
    /// @notice Counts the fee routes: one more each time the owner changes `feeSink`.
    function routeEpoch() external view returns (uint64);
    function pendingFeeSink() external view returns (address);
    function pendingFeeSinkAt() external view returns (uint40);
    /// @notice Who deposited a held position (zero when it is not held here).
    function depositorOf(uint256 tokenId) external view returns (address);
    /// @notice The route epoch of a held position's last settlement or deposit; below `routeEpoch` until its first
    ///         settlement after a route change.
    function routeEpochOf(uint256 tokenId) external view returns (uint64);
    /// @notice Where a held position's unsettled fees go at its next settlement, all of them, also those earned after a
    ///         later route change: the route of its last settlement or deposit, or its depositor when that route is zero
    ///         (zero when it is not held here). What an app shows as a position's route, rather than `feeSink`.
    function feeRouteOf(uint256 tokenId) external view returns (address);
    /// @notice Who a drip granted to this adapter belongs to (zero when unknown).
    function dripBeneficiary(bytes32 dripId) external view returns (address);
    /// @notice The positions `depositor` holds here.
    function depositsOf(address depositor) external view returns (uint256[] memory);
    /// @notice Every drip ever collected here for `depositor`, claimed or not.
    function dripsOf(address depositor) external view returns (bytes32[] memory);
    /// @notice How many positions are held here.
    function heldCount() external view returns (uint256);
    /// @notice Up to `count` held positions from index `start`, for keepers that settle in batches. A withdrawal moves
    ///         the last held position into the slot it frees.
    function heldIds(uint256 start, uint256 count) external view returns (uint256[] memory);

    /// @notice Anyone: takes the trading fees of held positions to the route of each one's last settlement
    ///         (`feeRouteOf`), then moves each to the route in force. Never touches principal. Skips a position that is
    ///         no longer held.
    function harvest(uint256[] calldata tokenIds) external;
    /// @notice Anyone: `harvest` of the held positions from index `start`, `count` of them or to the end of the list,
    ///         read when it executes. The owner's route change is followed by `harvestRange` in the same transaction,
    ///         so the positions it settles are those held then, whenever the batch was written, up to what one
    ///         transaction holds (the owner's batch caps them). Past that, later transactions move the rest; pages sent
    ///         in separate transactions can miss a position a withdrawal moved into a page already sent, so a cutover
    ///         re-reads `routeEpochOf`.
    function harvestRange(uint256 start, uint256 count) external;
    /// @notice The depositor: collects its held positions' native rewards; each emission drip is recorded for it and
    ///         each lump is paid to it at once. Skips a position that is no longer held.
    function collectNative(uint256[] calldata tokenIds) external;
    /// @notice Anyone: claims what has unlocked on drips collected here and pays each to its beneficiary, held position
    ///         or not.
    /// @return total sGAGE paid out.
    function claimDrips(bytes32[] calldata dripIds) external returns (uint256 total);
    /// @notice The depositor, outside any PositionManager action batch: takes the position's fees to the route of its
    ///         last settlement and its native rewards to the depositor, then sends the NFT to `to` (never zero or this
    ///         adapter). Fees owed to a sink must reach it or the withdrawal reverts, even once the sink is cleared;
    ///         fees owed to the depositor are its own, and nothing can keep the NFT here for them.
    function withdraw(uint256 tokenId, address to) external;
    /// @notice This contract only: one position's fees to `recipient`, inside `withdraw`.
    function settleFees(uint256 tokenId, address recipient) external;
    /// @notice This contract only, inside `withdraw`.
    function settleNativeOnExit(uint256 tokenId, address depositor) external;
    /// @notice Owner: propose a fee sink, to accept between SINK_DELAY and twice SINK_DELAY later, dropping any pending
    ///         proposal (`FeeSinkCancelled`). Zero clears the route at once; each position still pays the cleared sink
    ///         every fee unpaid at its next settlement, so settle the held positions in the same transaction
    ///         (`harvestRange`), as many as it holds. Never the sink in force, this adapter, the PositionManager, its
    ///         recipient placeholders, the PoolManager, the pool's two tokens, LPRewards, Drip, the pool's hook, Permit2
    ///         or the chain's Universal Router (`InvalidSink`): a best-effort list, so the owner still picks a sink that
    ///         can move what it receives.
    function proposeFeeSink(address sink) external;
    /// @notice Owner: drop a pending proposal and keep the route in force.
    function cancelFeeSink() external;
    /// @notice Owner, once the delay has passed and before the proposal lapses: the proposed sink becomes the route in
    ///         force, at a cost that does not depend on how many positions are held. Each position moves at its next
    ///         settlement, which first pays the route of its last settlement every fee unpaid, so settle the held
    ///         positions in the same transaction (`harvestRange`): then no fee they earned before this call reaches the
    ///         sink, and none earned after it reaches the old route. A position past what one transaction holds keeps
    ///         its old route until settled later (the keeper's cutover).
    function acceptFeeSink() external;
}
