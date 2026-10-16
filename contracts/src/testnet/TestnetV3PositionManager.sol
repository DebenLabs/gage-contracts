// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IUniV3PositionManager} from "../interfaces/IUniV3.sol";
import {TestnetOnly} from "./TestnetOnly.sol";

/// @title TestnetV3PositionManager
/// @notice Publishes the factory and WETH identities the V2 collateral validator reads. A labeled gage testnet
///         admits no Uniswap v3 LP position as collateral, so `positions` always reverts.
/// @dev NEVER deploy this on chain 4663. Its only job is to let the validator agree with the cash-out router on
///      one canonical WETH without pretending v3 LP collateral exists on testnet.
contract TestnetV3PositionManager is IUniV3PositionManager, TestnetOnly {
    /// @notice Marks this as a testnet stand-in, for explorers and the app.
    string public constant TESTNET_NOTICE = "gage testnet fixture: not Uniswap";

    address private immutable _FACTORY;
    address private immutable _WETH9;

    /// @notice No v3 LP position is collateral on testnet.
    error NoV3Positions();

    constructor(address factory_, address weth9) {
        _FACTORY = factory_;
        _WETH9 = weth9;
    }

    /// @notice The testnet v3 factory these positions would belong to.
    function factory() external view returns (address) {
        return _FACTORY;
    }

    /// @notice The canonical wrapped ETH of this testnet.
    function WETH9() external view returns (address) {
        return _WETH9;
    }

    /// @notice Always reverts: this testnet admits no v3 LP collateral.
    function positions(uint256) external pure returns (Position memory) {
        revert NoV3Positions();
    }
}
