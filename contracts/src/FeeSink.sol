// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IDealVault} from "./interfaces/IDealVault.sol";

/// @title FeeSink
/// @notice Receives protocol fees in USDG. Route switch: TREASURY now, BUYBACK from the day GAGE launches (M6).
/// @dev The vault credits fees to this contract's internal balance; `collect` pulls them (pull, never push), so a
///      USDG freeze on this address can never block an `accept`. Owner: the Safe. It controls only where fees go.
///      `vault` is set once after deployment because the vault's constructor needs this address (CREATE2 order).
contract FeeSink is Ownable2Step {
    using SafeERC20 for IERC20;

    enum Route {
        TREASURY,
        BUYBACK
    }

    IERC20 public immutable USDG;

    /// @notice Write-once. Zero until `setVault`.
    IDealVault public vault;
    address public treasury;
    /// @notice Buyback contract (M6). Zero until deployed; the BUYBACK route cannot be selected while it is zero.
    address public buyback;
    Route public route;

    event VaultSet(address indexed vault);
    event Collected(uint256 amount);
    event Swept(Route route, address indexed to, uint256 amount);
    event RouteSet(Route route);
    event TreasurySet(address indexed treasury);
    event BuybackSet(address indexed buyback);

    error ZeroAddress();
    error VaultAlreadySet();
    error VaultNotSet();
    error BuybackNotSet();
    error NothingToSweep();

    constructor(IERC20 usdg, address initialOwner, address initialTreasury) Ownable(initialOwner) {
        if (address(usdg) == address(0) || initialTreasury == address(0)) revert ZeroAddress();
        USDG = usdg;
        treasury = initialTreasury;
        emit TreasurySet(initialTreasury);
        emit RouteSet(Route.TREASURY);
    }

    /// @notice Bind the vault this sink collects from. Once.
    function setVault(IDealVault newVault) external onlyOwner {
        if (address(vault) != address(0)) revert VaultAlreadySet();
        if (address(newVault) == address(0)) revert ZeroAddress();
        vault = newVault;
        emit VaultSet(address(newVault));
    }

    /// @notice Pull the fees the vault has credited to this contract. Permissionless.
    function collect() external returns (uint256 amount) {
        IDealVault v = vault;
        if (address(v) == address(0)) revert VaultNotSet();
        amount = v.balanceUSDG(address(this));
        if (amount == 0) return 0;
        v.withdrawUSDG();
        emit Collected(amount);
    }

    /// @notice Send everything held here down the current route. Permissionless.
    function sweep() external returns (uint256 amount) {
        amount = USDG.balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        address to = route == Route.TREASURY ? treasury : buyback;
        if (to == address(0)) revert BuybackNotSet();
        USDG.safeTransfer(to, amount);
        emit Swept(route, to, amount);
    }

    function setRoute(Route newRoute) external onlyOwner {
        if (newRoute == Route.BUYBACK && buyback == address(0)) revert BuybackNotSet();
        route = newRoute;
        emit RouteSet(newRoute);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    function setBuyback(address newBuyback) external onlyOwner {
        if (newBuyback == address(0)) revert ZeroAddress();
        buyback = newBuyback;
        emit BuybackSet(newBuyback);
    }
}
