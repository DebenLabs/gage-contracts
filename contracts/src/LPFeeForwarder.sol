// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDealVault} from "./interfaces/IDealVault.sol";

/// @notice Permissionless collection of V2 deal fees into the existing DealFeeRouter.
/// @dev Only the deployer may bind a vault, once. The destination is immutable. No user collateral is held here.
contract LPFeeForwarder is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDG;
    address public immutable PROCESSOR;
    address public immutable DEPLOYER;
    IDealVault public vault;

    error InvalidBinding();

    event VaultBound(address indexed vault);
    event Forwarded(uint256 amount);

    constructor(IERC20 usdg, address processor) {
        if (address(usdg).code.length == 0 || processor.code.length == 0) revert InvalidBinding();
        (bool ok, bytes memory result) = processor.staticcall(abi.encodeWithSignature("USDG()"));
        if (!ok || abi.decode(result, (address)) != address(usdg)) revert InvalidBinding();
        USDG = usdg;
        PROCESSOR = processor;
        DEPLOYER = msg.sender;
    }

    function bind(IDealVault next) external {
        if (msg.sender != DEPLOYER || address(vault) != address(0) || address(next).code.length == 0) {
            revert InvalidBinding();
        }
        (bool ok, bytes memory result) = address(next).staticcall(abi.encodeWithSignature("FEE_SINK()"));
        if (!ok || abi.decode(result, (address)) != address(this)) revert InvalidBinding();
        (ok, result) = address(next).staticcall(abi.encodeWithSignature("USDG()"));
        if (!ok || abi.decode(result, (address)) != address(USDG)) revert InvalidBinding();
        vault = next;
        emit VaultBound(address(next));
    }

    function availableUSDG() external view returns (uint256) {
        return USDG.balanceOf(address(this)) + (address(vault) == address(0) ? 0 : vault.balanceUSDG(address(this)));
    }

    /// @notice Transfers fees only. The existing processor retains its threshold, slippage and floor policy.
    function forward() external nonReentrant returns (uint256 amount) {
        if (address(vault) == address(0)) revert InvalidBinding();
        if (vault.balanceUSDG(address(this)) != 0) vault.withdrawUSDG();
        amount = USDG.balanceOf(address(this));
        if (amount != 0) USDG.safeTransfer(PROCESSOR, amount);
        emit Forwarded(amount);
    }
}
