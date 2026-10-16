// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @title TestnetReserve
/// @notice The idle-cash reserve a testnet Earn strategy parks USDG in: a plain ERC-4626 vault over test USDG.
///         It stands in for the curated Morpho vault the mainnet strategy uses, because no such vault exists on
///         testnet. It is NOT Morpho, shares no code with Morpho, and must never be presented as one.
/// @dev NEVER deploy this on chain 4663. Yield is not earned here; `accrue` pulls USDG from a caller that chooses
///      to donate it, so a testnet can show a share price that moves. Deposits and withdrawals are otherwise
///      unrestricted, which is the behaviour HybridVault's happy path assumes.
///      Anyone can move this reserve's share price, by `accrue` or by a bare transfer, because the test USDG it
///      holds is free to mint. That is inherent to a faucet testnet and is not a finding: no balance here is worth
///      anything. Never read a share price from this contract as evidence about the mainnet reserve.
contract TestnetReserve is ERC4626, TestnetOnly {
    using SafeERC20 for IERC20;

    /// @notice Marks this as a testnet stand-in, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: not Morpho, no value";

    event Accrued(address indexed from, uint256 amount);

    constructor(IERC20 usdg) ERC20("Testnet USDG Reserve", "tUSDGr") ERC4626(usdg) {}

    /// @notice Eighteen-decimal shares over six-decimal USDG, matching the decimal offset of the reviewed reserve.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    /// @notice The virtual-share denominator, exposed for parity with the reviewed reserve's conversion inputs.
    function virtualShares() external pure returns (uint256) {
        return 1e12;
    }

    /// @notice Total assets, with no reserve-level fee or pending interest, for parity with the reviewed reserve.
    function accrueInterestView() external view returns (uint256, uint256, uint256) {
        return (totalAssets(), 0, 0);
    }

    /// @notice Donate USDG to every share holder, so a testnet share price can move. Anyone may call it.
    function accrue(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit Accrued(msg.sender, amount);
    }
}
