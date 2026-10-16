// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice The reserve of an Intent generation whose lent asset has no ERC-4626 vault to hold idle cash (root D249): an
/// ERC-4626 over that asset that nothing can enter. A vault's `investReserve` reverts, so its idle cash stays its own
/// `cash`, and every view the factory, the vaults and the quote verifier read answers, so the factory needs no lens.
/// @dev `maxDeposit` and `maxMint` are zero, so a deposit or mint of any amount above zero reverts and no share is ever
/// minted (a zero one moves nothing); `withdraw` and `redeem` then have nothing to pay. `totalAssets` is zero whatever
/// this contract holds, so every conversion is one to one: a token sent here is lost to its sender and moves no view, and
/// a donation cannot shift the `previewWithdraw` a signed plan's reserve-share bound is checked against. No owner, no
/// setting. Outside the audit scope (D240).
contract IntentClosedReserve is ERC4626 {
    /// @param asset_ The generation's lent asset, the core's `USDG()`: `IntentVault` requires `asset()` to equal it.
    constructor(IERC20 asset_) ERC20("gage closed reserve", "gage-closed") ERC4626(asset_) {}

    /// @notice Zero, whatever this contract holds: nothing is managed here.
    function totalAssets() public pure override returns (uint256) {
        return 0;
    }

    /// @notice Zero: the reserve takes no deposit.
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Zero: the reserve mints no share.
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }
}
