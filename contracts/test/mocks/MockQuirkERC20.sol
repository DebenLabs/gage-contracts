// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice MockERC20's storage layout plus one transfer quirk aimed at one address, so its code can be etched over a
///         fixture token that is already admitted everywhere. Each quirk moves 1% of the transfer:
///         - INTO_TAX: a transfer into `target` arrives 1% short (a taxed first leg);
///         - FROM_SURCHARGE: a transfer out of `target` also burns 1% more from it (a sender-side fee);
///         - INTO_BONUS: a transfer into `target` arrives with 1% more (a reward or rebase on receipt).
contract MockQuirkERC20 is ERC20 {
    enum Quirk {
        NONE,
        INTO_TAX,
        FROM_SURCHARGE,
        INTO_BONUS
    }

    uint8 private immutable _decimals;
    bool public paused;
    mapping(address account => bool) public blocked;
    address public target;
    Quirk public quirk;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setQuirk(address target_, Quirk quirk_) external {
        target = target_;
        quirk = quirk_;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = value / 100;
        if (from != address(0) && to == target && quirk == Quirk.INTO_TAX) {
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else if (from == target && to != address(0) && quirk == Quirk.FROM_SURCHARGE) {
            super._update(from, address(0), fee);
            super._update(from, to, value);
        } else if (from != address(0) && to == target && quirk == Quirk.INTO_BONUS) {
            super._update(from, to, value);
            super._update(address(0), to, fee);
        } else {
            super._update(from, to, value);
        }
    }
}
