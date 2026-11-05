// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IFablesLedger} from "../interfaces/IFablesLedger.sol";

/// @title FablesShareHolder
/// @notice One wrapped Fables position's own account: an EIP-1167 clone that holds that position's receipts, so the
/// hook books its fees to it alone, and calls the hook only as its wrapper says. The wrapper deploys the implementation
/// and is written into its code, so every clone answers to that wrapper from its first byte, with nothing to set up and
/// nothing anyone else could claim.
contract FablesShareHolder {
    /// @notice The wrapper this holder answers to: the deployer of the implementation every clone runs.
    address public immutable WRAPPER;

    error NotWrapper(address caller);

    constructor() {
        WRAPPER = msg.sender;
    }

    modifier onlyWrapper() {
        if (msg.sender != WRAPPER) revert NotWrapper(msg.sender);
        _;
    }

    /// @notice Withdraws `liquidity` of this holder's receipts to `to` within the minimums.
    function withdraw(
        IFablesLedger hook,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        uint128 min0,
        uint128 min1,
        uint256 deadline
    ) external onlyWrapper {
        hook.withdraw(key, tickLower, tickUpper, liquidity, to, min0, min1, deadline);
    }

    /// @notice Pays this holder's accrued fees to `to`.
    function claimFees(
        IFablesLedger hook,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        address to,
        uint16 maxFeeBps
    ) external onlyWrapper {
        hook.claimFees(key, tickLower, tickUpper, to, maxFeeBps);
    }

    /// @notice Moves `amount` of this holder's receipts of range `id` to `to`.
    function transferShares(IFablesLedger hook, address to, uint256 id, uint256 amount) external onlyWrapper {
        hook.transfer(to, id, amount);
    }
}
