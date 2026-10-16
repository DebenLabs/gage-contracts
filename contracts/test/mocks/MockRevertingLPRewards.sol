// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Every failure mode the hook must survive: revert, out-of-gas loop, and a bare revert with no data.
contract MockRevertingLPRewards {
    uint8 public mode; // 0 revert with reason, 1 burn all gas, 2 revert empty
    uint256 public calls;

    error Boom();

    function setMode(uint8 m) external {
        mode = m;
    }

    function onLiquidityChange(uint256) external {
        calls++;
        if (mode == 0) revert Boom();
        if (mode == 1) {
            uint256 x;
            while (true) {
                x++;
            }
        }
        revert();
    }
}
