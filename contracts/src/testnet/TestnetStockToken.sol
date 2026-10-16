// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {TestnetToken} from "./TestnetToken.sol";

/// @title TestnetStockToken
/// @notice A Stock Token for a labeled gage testnet. On top of the plain test asset it carries the display
///         multiplier a real Stock Token publishes, including a scheduled change, so a split can be exercised.
/// @dev NEVER deploy this on chain 4663. On-chain amounts are always raw units; the multiplier is read by the
///      app and the indexer only, and nothing in the deal path reads it (spec: no oracle in the deal path).
contract TestnetStockToken is TestnetToken {
    uint256 private _uiMultiplier;
    uint256 private _pending;
    uint64 private _effectiveAt;

    error InvalidMultiplier();
    error InvalidSchedule();

    event UIMultiplierUpdated(uint256 multiplier);
    event UIMultiplierScheduled(uint256 multiplier, uint64 effectiveAt);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address admin, uint256 multiplier)
        TestnetToken(name_, symbol_, decimals_, admin)
    {
        if (multiplier == 0) revert InvalidMultiplier();
        _uiMultiplier = multiplier;
        emit UIMultiplierUpdated(multiplier);
    }

    /// @notice The display multiplier in effect now, 1e18-scaled. A scheduled change applies once its time passes.
    function uiMultiplier() external view returns (uint256) {
        return (_effectiveAt != 0 && block.timestamp >= _effectiveAt) ? _pending : _uiMultiplier;
    }

    /// @notice The multiplier waiting to take effect, or zero when none is scheduled.
    function pendingUIMultiplier() external view returns (uint256) {
        return (_effectiveAt != 0 && block.timestamp < _effectiveAt) ? _pending : 0;
    }

    /// @notice When the pending multiplier takes effect, or zero when none is scheduled.
    function effectiveAt() external view returns (uint64) {
        return (_effectiveAt != 0 && block.timestamp < _effectiveAt) ? _effectiveAt : 0;
    }

    /// @notice Schedule a display-multiplier change, the way a split is announced before it lands.
    function scheduleUIMultiplier(uint256 multiplier, uint64 when) external {
        if (msg.sender != ADMIN) revert NotAdmin();
        if (multiplier == 0) revert InvalidMultiplier();
        if (when <= block.timestamp) revert InvalidSchedule();
        _settle();
        _pending = multiplier;
        _effectiveAt = when;
        emit UIMultiplierScheduled(multiplier, when);
    }

    /// @notice Fold a matured scheduled change into the current multiplier. Anyone may call it.
    function settleUIMultiplier() external {
        _settle();
    }

    function _settle() private {
        if (_effectiveAt != 0 && block.timestamp >= _effectiveAt) {
            _uiMultiplier = _pending;
            _pending = 0;
            _effectiveAt = 0;
            emit UIMultiplierUpdated(_uiMultiplier);
        }
    }
}
