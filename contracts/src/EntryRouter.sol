// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDealVault} from "./interfaces/IDealVault.sol";
import {IUniversalRouter} from "./interfaces/IUniversalRouter.sol";

/// @title EntryRouter
/// @notice Stateless. ETH in, a funded deal (or a USDG bid) out, in one transaction. Holds nothing between transactions.
/// @dev The front end encodes the Universal Router `commands` and `inputs` (route, minimum out, recipient = this
///      contract) and passes them through; this contract enforces that at least `price` USDG arrived, places the
///      bid with the caller as lender, and refunds every leftover USDG and ETH to the caller.
///      DealVault accepts a bid whose lender is not `msg.sender` only from a registry-allowlisted router.
contract EntryRouter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IDealVault public immutable VAULT;
    IERC20 public immutable USDG;
    IUniversalRouter public immutable UNIVERSAL_ROUTER;

    event BidWithETH(
        address indexed lender,
        uint256 indexed dealId,
        uint256 indexed bidId,
        uint256 ethIn,
        uint256 usdgOut,
        uint256 usdgRefunded,
        uint256 ethRefunded
    );

    event FundedWithETH(
        address indexed lender,
        uint256 indexed dealId,
        uint256 indexed bidId,
        uint256 ethIn,
        uint256 usdgOut,
        uint256 usdgRefunded,
        uint256 ethRefunded
    );

    error ZeroAddress();
    error NoETH();
    error InsufficientUSDG(uint256 received, uint256 required);
    error RefundFailed();

    constructor(IDealVault vault, IERC20 usdg, IUniversalRouter universalRouter) {
        if (address(vault) == address(0) || address(usdg) == address(0) || address(universalRouter) == address(0)) {
            revert ZeroAddress();
        }
        VAULT = vault;
        USDG = usdg;
        UNIVERSAL_ROUTER = universalRouter;
    }

    /// @notice Swap `msg.value` ETH to USDG through the Universal Router and bid `price` on `dealId`.
    /// @param commands Universal Router command bytes, encoded by the front end.
    /// @param inputs Universal Router inputs, encoded by the front end. The swap recipient must be this contract.
    /// @param deadline Universal Router deadline.
    function bidWithETH(
        uint256 dealId,
        uint128 price,
        uint40 bidExpiry,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 bidId) {
        if (msg.value == 0) revert NoETH();

        uint256 before = USDG.balanceOf(address(this));
        UNIVERSAL_ROUTER.execute{value: msg.value}(commands, inputs, deadline);
        uint256 received = USDG.balanceOf(address(this)) - before;
        if (received < price) revert InsufficientUSDG(received, price);

        USDG.forceApprove(address(VAULT), price);
        bidId = VAULT.bid(dealId, price, bidExpiry, msg.sender);

        uint256 usdgLeft = USDG.balanceOf(address(this));
        if (usdgLeft > 0) USDG.safeTransfer(msg.sender, usdgLeft);
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) {
            (bool ok,) = msg.sender.call{value: ethLeft}("");
            if (!ok) revert RefundFailed();
        }

        emit BidWithETH(msg.sender, dealId, bidId, msg.value, received, usdgLeft, ethLeft);
    }

    /// @notice Swap `msg.value` ETH to USDG through the Universal Router and fund `dealId` at its asking price (D43).
    ///         The price is read from the deal, so the front end only sizes the swap.
    function fundWithETH(uint256 dealId, bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 bidId)
    {
        if (msg.value == 0) revert NoETH();
        uint128 price = VAULT.getDeal(dealId).minPrice;

        uint256 before = USDG.balanceOf(address(this));
        UNIVERSAL_ROUTER.execute{value: msg.value}(commands, inputs, deadline);
        uint256 received = USDG.balanceOf(address(this)) - before;
        if (received < price) revert InsufficientUSDG(received, price);

        USDG.forceApprove(address(VAULT), price);
        bidId = VAULT.fund(dealId, msg.sender);

        uint256 usdgLeft = USDG.balanceOf(address(this));
        if (usdgLeft > 0) USDG.safeTransfer(msg.sender, usdgLeft);
        uint256 ethLeft = address(this).balance;
        if (ethLeft > 0) {
            (bool ok,) = msg.sender.call{value: ethLeft}("");
            if (!ok) revert RefundFailed();
        }

        emit FundedWithETH(msg.sender, dealId, bidId, msg.value, received, usdgLeft, ethLeft);
    }

    /// @dev Universal Router refunds unused ETH here.
    receive() external payable {}
}
