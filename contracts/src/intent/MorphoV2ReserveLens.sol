// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IReserveLens} from "./IntentVault.sol";
import {IMorphoBlue, IMorphoMarketAdapter, IMorphoVaultV2, MarketParams} from "../interfaces/IMorphoV2.sol";

/// @notice What a Morpho Vault V2 reserve can pay out now. Its ERC-4626 max views return zero by design ("gross
/// underestimation"), so they measure nothing; a withdrawal is served from the vault's idle balance and then from
/// its liquidity adapter's Morpho Blue market, and this reads exactly those two sources.
/// @dev Stateless and ownerless. It counts the idle balance, and the adapter's own supply in the liquidity market
/// up to what that market has not lent out. Interest that has accrued but is not yet written raises the market's
/// supply and borrow alike, so their difference is exact without an accrual. Other adapters are left out: the vault
/// never pulls from them on a plain withdrawal. A liquidity adapter it cannot read (another kind, one that reverts,
/// one whose Morpho has no code, answers that do not decode) or liquidity data that does not decode into a market adds
/// nothing, so the idle balance is counted alone: an understatement, never an overstatement, and never a revert that
/// would stop exits the vault's cash covers (Pashov M-31, M-56, M-57). A gate that refuses the withdrawal is not
/// modelled; the withdrawal itself stays the final word and reverts with every balance intact.
contract MorphoV2ReserveLens is IReserveLens {
    /// @inheritdoc IReserveLens
    function withdrawable(address reserve, address) external view returns (uint256 assets) {
        IMorphoVaultV2 vault = IMorphoVaultV2(reserve);
        assets = IERC20(vault.asset()).balanceOf(reserve);
        address adapter = vault.liquidityAdapter();
        if (adapter == address(0)) return assets;
        try this.marketLiquidity(adapter, vault.liquidityData()) returns (uint256 market) {
            assets += market;
        } catch {}
    }

    /// @notice What `adapter` can take back now from the Morpho Blue market that `data` names: its supply there, up to
    /// what the market has not lent.
    /// @dev The market id is derived as the adapter derives it, from the five parameters `data` decodes to, so bytes
    /// after them are ignored as the adapter ignores them (Pashov M-56). External so that `withdrawable` runs it in a
    /// frame of its own, where any failure, including data that does not decode, a `morpho()` without code or return
    /// data that does not decode, reverts into the caller's `catch`.
    function marketLiquidity(address adapter, bytes calldata data) external view returns (uint256) {
        bytes32 marketId = keccak256(abi.encode(abi.decode(data, (MarketParams))));
        uint256 supplied = IMorphoMarketAdapter(adapter).expectedSupplyAssets(marketId);
        (uint256 supply,, uint256 borrow,,,) = IMorphoBlue(IMorphoMarketAdapter(adapter).morpho()).market(marketId);
        uint256 unlent = supply > borrow ? supply - borrow : 0;
        return supplied < unlent ? supplied : unlent;
    }
}
