// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {HybridVault} from "./HybridVault.sol";

/// @notice Splits one Earn strategy's performance fees between its curator recipient and the protocol floor.
/// @dev The strategy charges the fee itself, only on realized loan profit that lifts its share price above the vault's
/// high-water mark, at the rate snapshotted when the settling loan was funded. Fees accrue in the strategy and are
/// split here when claimed; both shares are pull-only.
contract HybridFees is ReentrancyGuardTransient {
    HybridVault public immutable STRATEGY;
    IERC20 public immutable USDG;
    address public immutable CURATOR;
    uint16 public immutable PROTOCOL_SHARE_BPS;
    address public immutable PROTOCOL_RECIPIENT;
    address public curatorRecipient;
    uint256 public curatorAccrued;
    uint256 public protocolAccrued;

    event FeesDistributed(uint256 amount, uint256 curatorShare, uint256 protocolShare);
    event CuratorRecipientSet(address indexed recipient);
    event CuratorFeesClaimed(address indexed recipient, uint256 amount);
    event ProtocolFeesClaimed(address indexed recipient, uint256 amount);

    error InvalidConfiguration();
    error InvalidAmount();
    error NotCurator();
    error NotStrategy();
    error TransferAmountMismatch();

    constructor(address strategy, uint16 protocolShareBps, address protocolRecipient, address curatorRecipient_) {
        if (strategy.code.length == 0 || protocolShareBps > 10_000) revert InvalidConfiguration();
        if (protocolShareBps != 0 && protocolRecipient.code.length == 0) revert InvalidConfiguration();
        STRATEGY = HybridVault(payable(strategy));
        USDG = STRATEGY.USDG();
        CURATOR = STRATEGY.CURATOR();
        PROTOCOL_SHARE_BPS = protocolShareBps;
        PROTOCOL_RECIPIENT = protocolRecipient;
        _setCuratorRecipient(curatorRecipient_);
    }

    /// @notice Split fees the strategy has just transferred in; the protocol's share is fixed at deployment.
    function distribute(uint256 amount) external {
        if (msg.sender != address(STRATEGY)) revert NotStrategy();
        if (USDG.balanceOf(address(this)) < curatorAccrued + protocolAccrued + amount) revert TransferAmountMismatch();
        uint256 protocolShare = Math.mulDiv(amount, PROTOCOL_SHARE_BPS, 10_000);
        protocolAccrued += protocolShare;
        curatorAccrued += amount - protocolShare;
        emit FeesDistributed(amount, amount - protocolShare, protocolShare);
    }

    /// @notice Pull the curator's accrued share to its recipient; anyone may trigger the payment.
    function claimCurator() external nonReentrant returns (uint256 amount) {
        amount = curatorAccrued;
        if (amount == 0) revert InvalidAmount();
        curatorAccrued = 0;
        _pay(curatorRecipient, amount);
        emit CuratorFeesClaimed(curatorRecipient, amount);
    }

    /// @notice Forward the protocol's accrued share to the floor route; anyone may trigger the payment.
    function claimProtocol() external nonReentrant returns (uint256 amount) {
        amount = protocolAccrued;
        if (amount == 0) revert InvalidAmount();
        protocolAccrued = 0;
        _pay(PROTOCOL_RECIPIENT, amount);
        emit ProtocolFeesClaimed(PROTOCOL_RECIPIENT, amount);
    }

    /// @notice Change where the curator's share is paid; never the strategy, this contract or nobody.
    function setCuratorRecipient(address recipient) external nonReentrant {
        if (msg.sender != CURATOR) revert NotCurator();
        _setCuratorRecipient(recipient);
    }

    function _setCuratorRecipient(address recipient) internal {
        if (recipient == address(0) || recipient == address(this) || recipient == address(STRATEGY)) {
            revert InvalidConfiguration();
        }
        curatorRecipient = recipient;
        emit CuratorRecipientSet(recipient);
    }

    function _pay(address to, uint256 amount) internal {
        uint256 before_ = USDG.balanceOf(to);
        if (!USDG.transfer(to, amount) || USDG.balanceOf(to) != before_ + amount) revert TransferAmountMismatch();
    }
}
