// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Collateral, Kind} from "../types/Types.sol";

/// @notice One isolated collateral account per loan, for engines that lend against individual tokens only (D35).
/// @dev `GageV2CollateralAccount` without its liquidity-position paths, with the same views and vault calls. A
/// position kind is refused at initialization, so the engine cannot take custody of one.
/// It has no reentrancy guard of its own: every write is `onlyVault`, and every core function that calls `release`,
/// `recover` or `payRecovery` holds the core's `nonReentrant` lock.
contract GageV2TokenCollateralAccount {
    using SafeERC20 for IERC20;

    address public vault;
    Collateral public collateral;
    bool public released;
    bool public recovered;
    address[2] public recoveryTokens;
    uint256[2] public recoveryAmounts;

    error NotVault();
    error AlreadyInitialized();
    error InvalidState();
    error InsufficientRecovery();

    constructor() {
        vault = address(1);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    /// @notice Atomically initialize a fresh clone before custody is transferred to it. Token collateral only.
    function initialize(Collateral calldata c) external {
        if (vault != address(0)) revert AlreadyInitialized();
        if (c.kind != Kind.ERC20) revert InvalidState();
        vault = msg.sender;
        collateral = c;
    }

    /// @notice Release the entire original collateral on borrower withdrawal or cancellation.
    function release(address recipient) external onlyVault {
        if (released || recovered || recipient == address(0) || recipient == address(this)) revert InvalidState();
        released = true;
        IERC20(collateral.token).safeTransfer(recipient, collateral.amountOrTokenId);
    }

    /// @notice Record the collateral token as the default recovery, once. The second asset slot stays empty.
    function recover(uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyVault
        returns (address[2] memory tokens, uint256[2] memory amounts)
    {
        if (released || recovered || block.timestamp > deadline) revert InvalidState();
        recovered = true;
        tokens[0] = collateral.token;
        amounts[0] = collateral.amountOrTokenId;
        if (amounts[0] < min0 || amounts[1] < min1) revert InsufficientRecovery();
        recoveryTokens = tokens;
        recoveryAmounts = amounts;
    }

    /// @notice Send one recorded asset entitlement, authorized and accounted by the vault.
    function payRecovery(uint8 asset, address recipient, uint256 amount) external onlyVault {
        if (!recovered || asset > 1 || recipient == address(0) || recipient == address(this)) revert InvalidState();
        IERC20(recoveryTokens[asset]).safeTransfer(recipient, amount);
    }
}
