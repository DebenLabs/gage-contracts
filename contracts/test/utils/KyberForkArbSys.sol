// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @dev Arbitrum's ArbSys precompile (0x64), which a local fork lacks and some market makers' contracts read: the L2
///      block number is the fork's. Etched by the KyberSwap mainnet-fork tests (LoopRouterKyber, GageV2CashoutKyber,
///      KyberRouterV3).
contract KyberForkArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}
