// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Records what Emissions sends it. Stands in for LPRewards while the supply side is tested alone.
contract MockLPRewards {
    IERC20 public immutable SGAGE;
    uint256 public lastEpoch;
    uint256 public lastEmissions;
    uint256 public emissionsTotal;
    uint256 public lumpsTotal;
    uint256 public notifyCount;

    constructor(IERC20 sgage) {
        SGAGE = sgage;
    }

    function notifyEmissions(uint256 epoch, uint256 amount) external {
        lastEpoch = epoch;
        lastEmissions = amount;
        emissionsTotal += amount;
        notifyCount++;
    }

    function notifyLump(uint256 amount) external {
        SGAGE.transferFrom(msg.sender, address(this), amount);
        lumpsTotal += amount;
    }
}
