// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Interfaces bound to the selected Pons deployment's verified sources.
interface IPonsCurve {
    function token() external view returns (address);
    function pairToken() external view returns (address);
    function factory() external view returns (address);
    function deployer() external view returns (address);
    function feeEscrow() external view returns (address);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function buybackEnabled() external view returns (bool);
    function graduated() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function sellableTokens() external view returns (uint256);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
}

interface IPonsFeeEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function claim() external returns (uint256);
}

interface IPonsMemeHookFees {
    function sweepPoolFees(PoolId poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}
