// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// Exit sizing probe for TIBBIR at the pinned fork, independent of the registry limits: each probe sells through the hooked
// v4 ETH/TIBBIR pool (the hook's 1% sell fee on the ETH output, the 0.3% LP fee) and then native ETH/USDG, from the pinned
// state, and logs (TIBBIR sold, USDG out, bps of the pre-trade spot of both pools). Fees and price impact are included;
// gas is not. testProbe_limits sells the minimum, the per-loan limit, the aggregate and twice the aggregate when the
// limits are in the environment (scripts/tibbir-fork.mjs). Rerun at a cap revisit. Skips without a fork RPC.
import {TibbirForkBase} from "./TibbirAdmissionLiveFork.t.sol";
import {console2} from "forge-std/console2.sol";

contract TibbirDepthProbeTest is TibbirForkBase {
    function setUp() public {
        _fork();
    }

    function _probe(uint256 amount) internal {
        uint256 spot = _spotUSDG(amount);
        uint256 snapshot = vm.snapshotState();
        uint256 out = _sell(amount);
        vm.revertToState(snapshot);
        console2.log("probe tibbir, usdg out, bps of pre-trade spot", amount / 1e18, out, (out * 10_000) / spot);
    }

    function testProbe_001_000() public {
        _probe(1000e18);
    }

    function testProbe_010_000() public {
        _probe(10_000e18);
    }

    function testProbe_025_000() public {
        _probe(25_000e18);
    }

    function testProbe_050_000() public {
        _probe(50_000e18);
    }

    function testProbe_075_000() public {
        _probe(75_000e18);
    }

    function testProbe_100_000() public {
        _probe(100_000e18);
    }

    function testProbe_125_000() public {
        _probe(125_000e18);
    }

    function testProbe_150_000() public {
        _probe(150_000e18);
    }

    function testProbe_200_000() public {
        _probe(200_000e18);
    }

    function testProbe_250_000() public {
        _probe(250_000e18);
    }

    /// The registry limits of limits.json: minimum, per loan, aggregate and twice the aggregate.
    function testProbe_limits() public {
        uint256 aggregate = vm.envOr("GAGE_TIBBIR_AGGREGATE", uint256(0));
        if (aggregate == 0) return;
        console2.log("limits: minimum, per loan, aggregate, twice the aggregate");
        _probe(vm.envUint("GAGE_TIBBIR_MIN"));
        _probe(vm.envUint("GAGE_TIBBIR_PER_DEAL"));
        _probe(aggregate);
        _probe(2 * aggregate);
    }
}
