// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Collateral lanes. Informational for the indexer and the screening service: the vault treats every
///         ERC-20 the same way. Memes pass spec 7.4 off-chain before they are allowlisted.
enum Lane {
    STOCK,
    ETH,
    MEME
}

/// @notice Assets a meme's Uniswap v4 pool may be paired with to qualify for the lane (spec open decision 23).
enum PairAsset {
    STOCK,
    USDG,
    ETH
}

/// @title ICollateralRegistry
/// @notice Owner-managed allowlists, minimums, caps, terms, fee and the pause of new deals.
/// @dev The registry can stop new deals. It has no path to any user's collateral or USDG (spec I2, I3).
interface ICollateralRegistry {
    /// @param allowed Token may be listed as collateral.
    /// @param lane Which lane the asset sits in. The LP adapter validates underlying lanes; the ERC-20 adapter ignores it.
    /// @param minAmount Minimum per deal, raw units.
    /// @param maxDealRaw Maximum per deal, raw units (spec 13: per-deal cap; 1% of pool depth for memes).
    /// @param maxOpenRaw Maximum across every LISTED and FUNDED deal, raw units (spec 7.1; 5% of depth for memes).
    struct ERC20Config {
        bool allowed;
        Lane lane;
        uint256 minAmount;
        uint256 maxDealRaw;
        uint256 maxOpenRaw;
    }

    /// @param allowed Positions in this pool may be listed (M2).
    /// @param minLiquidity Position liquidity must exceed this.
    struct PoolConfig {
        bool allowed;
        uint128 minLiquidity;
    }

    event ERC20Set(
        address indexed token, bool allowed, Lane lane, uint256 minAmount, uint256 maxDealRaw, uint256 maxOpenRaw
    );
    event PoolSet(bytes32 indexed poolId, bool allowed, uint128 minLiquidity);
    event TermsSet(uint32[] terms);
    event FeeSet(uint16 bps);
    event InRangeRequiredSet(bool required);
    event NewDealsPausedSet(bool paused);
    event RouterSet(address indexed router, bool allowed);
    event MemePairsSet(uint8 mask);
    event PoolRemovalHookSet(bytes32 indexed poolId, address indexed hook, bytes32 codeHash);

    function getERC20Config(address token) external view returns (ERC20Config memory);
    function getPoolConfig(bytes32 poolId) external view returns (PoolConfig memory);
    /// @notice Exact runtime approved for an observational afterRemoveLiquidity callback in this pool.
    function removalHookCodeHash(bytes32 poolId) external view returns (bytes32);
    function isTermAllowed(uint32 term) external view returns (bool);
    function allowedTerms() external view returns (uint32[] memory);
    function feeBps() external view returns (uint16);
    function inRangeRequired() external view returns (bool);
    function newDealsPaused() external view returns (bool);
    /// @notice Contracts allowed to place a bid on behalf of another lender (EntryRouter).
    function isRouter(address account) external view returns (bool);
    /// @notice Bitmask of PairAsset values a meme pool may be paired with. Bit i = PairAsset(i).
    function memePairMask() external view returns (uint8);
    function isMemePairAllowed(PairAsset pair) external view returns (bool);
}
