// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The reward token. 5,000,000,000 minted once at construction; supply only ever decreases (T1).
interface IsGAGE is IERC20 {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function TOTAL_SUPPLY_AT_MINT() external view returns (uint256);
}
