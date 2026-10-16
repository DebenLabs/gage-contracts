// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @title TestnetToken
/// @notice A test asset for a labeled gage testnet: USDG, Stock Tokens and memes all use this one contract.
///         Minting is open so the faucet, the counterparty bots and anyone trying the app can obtain balances.
/// @dev NEVER deploy this on chain 4663. It carries no value, no supply cap and no access control on `mint`.
///      The pause and blocklist switches mirror the behaviour the real assets may have, so the app's screening
///      and failure paths can be exercised on testnet.
contract TestnetToken is ERC20, TestnetOnly {
    /// @notice Marks every asset this deployment hands out as a test asset, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: no value";

    uint8 private immutable _DECIMALS;

    /// @notice Whoever may pause the token or block an account. Set once at deployment.
    address public immutable ADMIN;

    bool public paused;

    mapping(address account => bool) public blocked;

    error EnforcedPause();
    error BlockedAccount(address account);
    error NotAdmin();

    event PausedSet(bool paused);
    event BlockedSet(address indexed account, bool blocked);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address admin) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
        ADMIN = admin;
    }

    /// @notice The token's display precision, fixed at deployment (USDG uses 6, most stocks 18).
    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Create test balances. Open on purpose: this is a faucet asset.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Stop every transfer, modelling an issuer pause.
    function setPaused(bool paused_) external {
        if (msg.sender != ADMIN) revert NotAdmin();
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Block one account, modelling an issuer blocklist.
    function setBlocked(address account, bool blocked_) external {
        if (msg.sender != ADMIN) revert NotAdmin();
        blocked[account] = blocked_;
        emit BlockedSet(account, blocked_);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert EnforcedPause();
        if (blocked[from]) revert BlockedAccount(from);
        if (blocked[to]) revert BlockedAccount(to);
        super._update(from, to, value);
    }
}
