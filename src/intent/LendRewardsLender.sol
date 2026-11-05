// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDealVault} from "../interfaces/IDealVault.sol";
import {IDrip} from "../interfaces/token/IDrip.sol";

/// @notice The lender of a rewards bridge's mirror deals. DealRewards grants a deal's two shares under one drip id per
///         party, so a deal whose lender is its borrower cannot be registered while both shares pay; the bridge borrows
///         and this contract lends.
/// @dev Created by its bridge and answers to it alone. Between the bridge's calls it holds nothing but vesting drips:
///      the cap it is repaid and the sGAGE it claims go straight back to the bridge.
contract LendRewardsLender {
    using SafeERC20 for IERC20;

    address public immutable BRIDGE;
    IDealVault public immutable VAULT;
    IERC20 public immutable USDG;
    IERC20 public immutable SGAGE;
    IDrip public immutable DRIP;

    error NotBridge(address caller);

    constructor(IDealVault vault, IERC20 usdg, IERC20 sgage, IDrip drip) {
        BRIDGE = msg.sender;
        VAULT = vault;
        USDG = usdg;
        SGAGE = sgage;
        DRIP = drip;
        usdg.forceApprove(address(vault), type(uint256).max);
    }

    modifier onlyBridge() {
        if (msg.sender != BRIDGE) revert NotBridge(msg.sender);
        _;
    }

    /// @notice Funds a mirror deal at its asking price with the USDG the bridge has just sent.
    /// @param dealId The V1 deal the bridge listed.
    function fund(uint256 dealId) external onlyBridge {
        VAULT.fund(dealId, address(this));
    }

    /// @notice Withdraws the repaid cap and returns it to the bridge.
    /// @return amount The USDG returned.
    function collect() external onlyBridge returns (uint256 amount) {
        VAULT.withdrawUSDG();
        amount = USDG.balanceOf(address(this));
        USDG.safeTransfer(BRIDGE, amount);
    }

    /// @notice Claims what a mirror deal's lender drip has unlocked and passes it to the bridge.
    /// @param dripId The drip DealRewards granted this contract for the deal.
    /// @return amount The sGAGE passed on.
    function claim(bytes32 dripId) external onlyBridge returns (uint128 amount) {
        amount = DRIP.claim(dripId);
        SGAGE.safeTransfer(BRIDGE, amount);
    }
}
