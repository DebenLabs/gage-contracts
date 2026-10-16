// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Swaps ETH to USDG at a fixed rate, ignoring commands. `consumeBps` < 10_000 refunds part of the ETH,
///         the way the real router refunds unused input.
contract MockUniversalRouter is IUniversalRouter {
    MockERC20 public immutable USDG;
    /// @notice USDG raw units per 1e18 wei.
    uint256 public rate;
    uint16 public consumeBps = 10_000;

    error DeadlinePassed();
    error RefundFailed();

    constructor(MockERC20 usdg, uint256 rate_) {
        USDG = usdg;
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setConsumeBps(uint16 bps) external {
        consumeBps = bps;
    }

    function execute(bytes calldata, bytes[] calldata, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert DeadlinePassed();
        uint256 spend = (msg.value * consumeBps) / 10_000;
        USDG.mint(msg.sender, (spend * rate) / 1e18);
        uint256 refund = msg.value - spend;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }
}
