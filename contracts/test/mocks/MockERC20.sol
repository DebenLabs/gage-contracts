// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 with the pause and blocklist behaviour we assume Stock Tokens and USDG may have.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;
    bool public paused;
    mapping(address account => bool) public blocked;

    error EnforcedPause();
    error BlockedAccount(address account);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlocked(address account, bool blocked_) external {
        blocked[account] = blocked_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert EnforcedPause();
        if (blocked[from]) revert BlockedAccount(from);
        if (blocked[to]) revert BlockedAccount(to);
        super._update(from, to, value);
    }
}
