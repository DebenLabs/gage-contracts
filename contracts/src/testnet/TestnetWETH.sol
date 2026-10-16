// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @title TestnetWETH
/// @notice Wrapped test ETH for a labeled gage testnet. The V2 cash-out router unwraps through `withdraw`, and
///         the zap router wraps through `deposit`, so the testnet needs the canonical WETH9 surface.
/// @dev NEVER deploy this on chain 4663, which has its own canonical WETH.
contract TestnetWETH is ERC20, TestnetOnly {
    /// @notice Marks this as a test asset, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: no value";

    error TransferFailed();

    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Testnet Wrapped Ether", "WETH") {}

    /// @notice Wrap the ETH sent with the call.
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Burn wrapped ETH and return the same amount of ETH to the caller.
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Withdrawal(msg.sender, amount);
    }

    receive() external payable {
        deposit();
    }
}
