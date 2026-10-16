// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IsGAGE} from "../interfaces/token/IsGAGE.sol";

/// @title sGAGE
/// @notice gage's reward token. 5,000,000,000 minted once: 4.0B to Emissions, 1.0B to the seed transaction.
///         No mint function exists after construction; supply only ever decreases (T1).
contract SGAGE is ERC20Burnable, IsGAGE {
    uint256 public constant TOTAL_SUPPLY_AT_MINT = 5_000_000_000e18;
    uint256 public constant EMISSIONS_ALLOCATION = 4_000_000_000e18;
    uint256 public constant SEED_ALLOCATION = 1_000_000_000e18;

    error ZeroAddress();

    constructor(address emissions, address seedRecipient) ERC20("sGAGE", "sGAGE") {
        if (emissions == address(0) || seedRecipient == address(0)) revert ZeroAddress();
        _mint(emissions, EMISSIONS_ALLOCATION);
        _mint(seedRecipient, SEED_ALLOCATION);
    }

    function burn(uint256 amount) public override(ERC20Burnable, IsGAGE) {
        ERC20Burnable.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override(ERC20Burnable, IsGAGE) {
        ERC20Burnable.burnFrom(account, amount);
    }
}
