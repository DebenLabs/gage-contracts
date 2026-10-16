// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IReserveLens} from "../../src/intent/IntentVault.sol";
import {HybridReserveMock} from "./HybridReserveMock.sol";

/// @notice Local test lens for HybridReserveMock while it reports zero max views the way Morpho Vault V2 does: what
/// the mock would actually pay, from its own limits. Not Morpho, and never a live integration.
contract ReserveLensMock is IReserveLens {
    function withdrawable(address reserve, address owner) external view returns (uint256) {
        HybridReserveMock r = HybridReserveMock(reserve);
        uint256 held = r.balanceOf(owner);
        return
            Math.min(
                Math.min(r.previewRedeem(held), r.withdrawLimit()), r.previewRedeem(Math.min(held, r.redeemLimit()))
            );
    }
}
