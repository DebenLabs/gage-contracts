// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice What the factory asks of the address it pays the protocol's USDG to: the fee processor's own two views.
/// @dev `DealFeeRouter` counts its own USDG balance in `availableUSDG()`, so a plain transfer into it is batched and
/// processed. The floor (`FeeFloor`), a wallet or any other contract could hold the USDG and never move it. Moved
/// verbatim from `IntentFactory.sol` (X-dup-07).
interface IIntentFeeProcessor {
    function USDG() external view returns (address);
    function availableUSDG() external view returns (uint256);
}
