// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {GageV2Vault} from "./GageV2Vault.sol";
import {V2Loan, V2State} from "./V2Types.sol";

/// @notice Pay ETH for lender quarters in one transaction through the canonical Universal Router.
/// @dev Refunds only this invocation's surplus. Stray balances cannot subsidize someone else's contribution.
contract GageV2EntryRouter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    GageV2Vault public immutable VAULT;
    IERC20 public immutable USDG;
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    error InvalidConfiguration();
    error InvalidFunding();
    error InsufficientUSDG();
    error RefundFailed();

    event FundedWithETH(
        address indexed lender,
        uint256 indexed id,
        uint8 units,
        uint256 ethIn,
        uint256 contribution,
        uint256 usdgRefund,
        uint256 ethRefund
    );

    constructor(GageV2Vault vault, IUniversalRouter router) {
        if (address(vault).code.length == 0 || address(router).code.length == 0) revert InvalidConfiguration();
        VAULT = vault;
        USDG = vault.USDG();
        UNIVERSAL_ROUTER = router;
    }

    /// @notice Exact USDG required for the next available quarter slots.
    function contribution(uint256 id, uint8 units) public view returns (uint256 amount) {
        V2Loan memory l = VAULT.getLoan(id);
        if (l.state != V2State.FUNDING || block.timestamp >= l.fundingDeadline || units == 0 || units > 4 - l.filled) {
            revert InvalidFunding();
        }
        address[4] memory holders = VAULT.lenders(id);
        for (uint8 i; i < 4 && units != 0; ++i) {
            if (holders[i] == address(0)) {
                amount += uint256(l.principal) / 4 + (i < l.principal % 4 ? 1 : 0);
                --units;
            }
        }
    }

    /// @notice Swap caller ETH, fund exactly the selected units for that caller, then return swap surplus.
    function fundWithETH(
        uint256 id,
        uint8 units,
        uint256 maxContribution,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0 || deadline < block.timestamp || deadline > block.timestamp + 15 minutes) {
            revert InvalidFunding();
        }
        uint256 price = contribution(id, units);
        if (price > maxContribution) revert InvalidFunding();
        uint256 beforeCash = USDG.balanceOf(address(this));
        uint256 beforeETH = address(this).balance - msg.value;
        UNIVERSAL_ROUTER.execute{value: msg.value}(commands, inputs, deadline);
        if (USDG.balanceOf(address(this)) < beforeCash + price) revert InsufficientUSDG();
        USDG.forceApprove(address(VAULT), price);
        VAULT.fundFor(id, units, msg.sender);
        USDG.forceApprove(address(VAULT), 0);
        uint256 cashRefund = USDG.balanceOf(address(this)) - beforeCash;
        uint256 ethRefund = address(this).balance - beforeETH;
        if (cashRefund != 0) USDG.safeTransfer(msg.sender, cashRefund);
        if (ethRefund != 0) {
            (bool ok,) = msg.sender.call{value: ethRefund}("");
            if (!ok) revert RefundFailed();
        }
        emit FundedWithETH(msg.sender, id, units, msg.value, price, cashRefund, ethRefund);
    }

    /// @notice Receive only router refunds or native transfers; accounting protects pre-existing donations.
    receive() external payable {}
}
