// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";

/// @title ERC20Adapter
/// @notice Stock Tokens and WETH as collateral (spec 7.1). Compiled into DealVault as an internal library.
/// @dev Amounts are raw units everywhere on-chain. `uiMultiplier()` scaling happens only in the UI and indexer.
library ERC20Adapter {
    using SafeERC20 for IERC20;

    error TokenNotAllowed(address token);
    error BelowMinimum(address token, uint256 amount, uint256 minAmount);
    error AboveDealMax(address token, uint256 amount, uint256 maxDealRaw);
    error OpenCapExceeded(address token, uint256 open, uint256 amount, uint256 maxOpenRaw);
    error TransferAmountMismatch(uint256 expected, uint256 received);

    /// @notice Allowlist, minimum, per-deal maximum and per-asset open cap, all in raw units.
    function validate(ICollateralRegistry.ERC20Config memory cfg, address token, uint256 amount, uint256 currentOpen)
        internal
        pure
    {
        if (!cfg.allowed) revert TokenNotAllowed(token);
        if (amount < cfg.minAmount) revert BelowMinimum(token, amount, cfg.minAmount);
        if (amount > cfg.maxDealRaw) revert AboveDealMax(token, amount, cfg.maxDealRaw);
        if (currentOpen + amount > cfg.maxOpenRaw) revert OpenCapExceeded(token, currentOpen, amount, cfg.maxOpenRaw);
    }

    /// @notice Pull exactly `amount` from `from`. A fee-on-transfer or rebasing token fails the delta check.
    function pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
    }
}
