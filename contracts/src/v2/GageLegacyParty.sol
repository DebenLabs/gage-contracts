// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDealVault} from "../interfaces/IDealVault.sol";
import {DealRewards} from "../token/DealRewards.sol";
import {Collateral, Kind} from "../types/Types.sol";

/// @notice Fixed adapter-controlled identity for one side of one legacy loan.
/// @dev Clones share immutable authority. There is no initializer, arbitrary call or user approval path.
contract GageLegacyParty {
    using SafeERC20 for IERC20;

    address public immutable ADAPTER;
    IDealVault public immutable VAULT;
    DealRewards public immutable REWARDS;
    IERC20 public immutable USDG;
    IERC20 public immutable SGAGE;

    error NotAdapter();

    constructor(IDealVault vault, DealRewards rewards, IERC20 usdg) {
        ADAPTER = msg.sender;
        VAULT = vault;
        REWARDS = rewards;
        USDG = usdg;
        SGAGE = rewards.SGAGE();
    }

    modifier onlyAdapter() {
        if (msg.sender != ADAPTER) revert NotAdapter();
        _;
    }

    /// @notice Deposit the adapter's restricted receipt at fixed terms.
    function list(uint128 principal, uint128 cap, uint32 term) external onlyAdapter returns (uint256) {
        IERC20(ADAPTER).forceApprove(address(VAULT), 1);
        return VAULT.list(Collateral(Kind.ERC20, ADAPTER, 1), cap, term, uint40(block.timestamp + 1), principal);
    }

    /// @notice Fund this clone's loan with exactly the supplied principal.
    function fund(uint256 id, uint128 principal) external onlyAdapter {
        USDG.forceApprove(address(VAULT), principal);
        VAULT.fund(id, address(this));
    }

    /// @notice Return credited USDG to the adapter, which binds the original engine.
    /// @dev Never zero where the adapter calls it: the borrower clone holds principal less a fee of at most 2% (the
    ///      engine lists at least 4 units with a cap at or above the principal), the lender clone the full cap. The
    ///      legacy vault's `withdrawUSDG` reverts on a zero balance.
    function withdrawCash() external onlyAdapter returns (uint256 amount) {
        amount = VAULT.balanceUSDG(address(this));
        VAULT.withdrawUSDG();
        USDG.safeTransfer(ADAPTER, amount);
    }

    /// @notice Pay the recorded full cap and withdraw this borrower's receipt.
    function repay(uint256 id, uint128 cap) external onlyAdapter {
        USDG.forceApprove(address(VAULT), cap);
        VAULT.reclaim(id);
        VAULT.withdrawERC20(ADAPTER);
    }

    /// @notice Claim the receipt for a defaulted loan under the legacy maturity rule.
    function finalizeDefault(uint256 id) external onlyAdapter {
        VAULT.claim(id);
        VAULT.withdrawERC20(ADAPTER);
    }

    /// @notice Harvest only this loan's grant; unrelated token donations do not enter the reward accounting.
    /// @dev Forwards the amount `Drip.claim` reports: the owner-less Drip transfers exactly that much sGAGE, a plain
    ///      ERC-20, to this clone, and reverts rather than return zero. The claimable pre-check keeps a clone with no
    ///      grant, or nothing unlocked yet, from reverting the adapter's harvest.
    function harvest(uint256 id) external onlyAdapter returns (uint256 amount) {
        bytes32 key = REWARDS.dripIdOf(id, address(this));
        if (REWARDS.DRIP().claimable(address(this), key) == 0) return 0;
        amount = REWARDS.DRIP().claim(key);
        SGAGE.safeTransfer(ADAPTER, amount);
    }
}
