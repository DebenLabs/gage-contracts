// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// The third-party Morpho ABIs `MorphoV2ReserveLens` reads, moved verbatim from that file (X-dup-07). The return order
// of `IMorphoBlue.market` is load-bearing: the lens takes its first and third values as supply and borrow assets.

/// @dev Morpho Blue's market parameters. The market adapter decodes a vault's liquidity data into them, and the market
/// id is keccak256 of their ABI encoding.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @dev ABI of Morpho Vault V2 at a0ba9df0, the parts a withdrawal reads.
interface IMorphoVaultV2 {
    function asset() external view returns (address);
    function liquidityAdapter() external view returns (address);
    function liquidityData() external view returns (bytes memory);
}

/// @dev ABI of MorphoMarketV1AdapterV2 at the same commit.
interface IMorphoMarketAdapter {
    function morpho() external view returns (address);
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}

/// @dev ABI of Morpho Blue's tuple-typed market getter.
interface IMorphoBlue {
    /// @return totalSupplyAssets
    /// @return totalSupplyShares
    /// @return totalBorrowAssets
    /// @return totalBorrowShares
    /// @return lastUpdate
    /// @return fee
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
}
