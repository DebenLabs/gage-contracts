// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Collateral kinds compiled into DealVault. Adding one means a new vault version, never an upgrade.
enum Kind {
    ERC20,
    UNIV4_POSITION,
    UNIV3_POSITION
}

/// @param kind Adapter that validates and custodies the collateral.
/// @param token ERC-20 address for Kind.ERC20; the PositionManager for Kind.UNIV4_POSITION.
/// @param amountOrTokenId Raw ERC-20 amount, or the position NFT id.
struct Collateral {
    Kind kind;
    address token;
    uint256 amountOrTokenId;
}
