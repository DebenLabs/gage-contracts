// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The two views the Intent factory asks of a protocol recipient, as `DealFeeRouter` answers them.
contract MockFeeProcessor {
    IERC20 public immutable USDG;

    constructor(address usdg) {
        USDG = IERC20(usdg);
    }

    function availableUSDG() external view returns (uint256) {
        return USDG.balanceOf(address(this));
    }
}

/// @notice Names the right token and nothing else: like the floor, it could never process a USDG balance.
contract MockTokenOnlyRecipient {
    address public immutable USDG;

    constructor(address usdg) {
        USDG = usdg;
    }
}
