// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {BaseTest} from "../Base.t.sol";
import {SGAGE} from "../../src/token/SGAGE.sol";
import {Drip} from "../../src/token/Drip.sol";
import {Emissions} from "../../src/token/Emissions.sol";
import {DealRewards} from "../../src/token/DealRewards.sol";
import {ILPRewards} from "../../src/interfaces/token/ILPRewards.sol";
import {MockLPRewards} from "../mocks/MockLPRewards.sol";

/// @notice The supply side of the token layer on top of the M1 fixture, with LPRewards mocked.
abstract contract TokenBaseTest is BaseTest {
    Emissions internal emissions;
    SGAGE internal sgage;
    Drip internal drip;
    MockLPRewards internal lpMock;
    DealRewards internal dealRewards;

    uint128 internal constant RATE7 = 50e18; // sGAGE per USDG of fee
    uint128 internal constant RATE21 = 100e18;
    uint128 internal constant PRICE = 1e4; // 0.01 USDG per sGAGE, in USDG raw units per 1e18 sGAGE
    uint16 internal constant LENDER_SHARE = 5000;
    uint256 internal constant RESERVE = 4_000_000_000e18;

    function setUp() public virtual override {
        super.setUp();
        emissions = new Emissions(safe, address(this));
        sgage = new SGAGE(address(emissions), treasury);
        drip = new Drip(sgage, address(this));
        lpMock = new MockLPRewards(sgage);
        dealRewards = new DealRewards(vault, emissions, drip, sgage, 6, safe);
        emissions.wire(sgage, ILPRewards(address(lpMock)), address(dealRewards));
        drip.setGrantors(address(dealRewards), address(lpMock));
        vm.startPrank(safe);
        emissions.launch(uint40(block.timestamp));
        dealRewards.setEpochRates(0, RATE7, RATE21, PRICE, LENDER_SHARE);
        vm.stopPrank();
        vm.label(address(emissions), "Emissions");
        vm.label(address(sgage), "sGAGE");
        vm.label(address(drip), "Drip");
        vm.label(address(dealRewards), "DealRewards");
    }

    /// @dev 80% of the fee valued at PRICE, in sGAGE.
    function _cap(uint128 fee) internal pure returns (uint256) {
        return (uint256(fee) * 1e18 * 8000) / 10_000 / PRICE;
    }
}
