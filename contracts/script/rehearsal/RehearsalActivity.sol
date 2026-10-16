// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IDealVault} from "../../src/interfaces/IDealVault.sol";
import {V4Swapper} from "../../src/token/base/V4Swapper.sol";

interface IMockMint {
    function mint(address to, uint256 amount) external;
}

/// @notice Testnet-only counterparty and swap fixture used to exercise the hosted keeper.
contract RehearsalActivity is V4Swapper {
    address public immutable OWNER;

    error TestnetOnly();
    error NotOwner();

    constructor(IPoolManager manager, address owner) V4Swapper(manager) {
        if (block.chainid != 46_630) revert TestnetOnly();
        OWNER = owner;
    }
    /// @notice Mint mock USDG and fund a rehearsal deal as a separate lender contract.

    function fund(IDealVault vault, IERC20 usdg, uint256 id, uint256 amount) external {
        if (msg.sender != OWNER) revert NotOwner();
        IMockMint(address(usdg)).mint(address(this), amount);
        usdg.approve(address(vault), amount);
        vault.fund(id, address(this));
    }
    /// @notice Produce swap fees in both seed currencies, retaining the purchased test tokens in this fixture.

    function trade(PoolKey calldata gageEth, PoolKey calldata seed, address gage) external payable {
        if (msg.sender != OWNER) revert NotOwner();
        uint256 bought = _swapExactIn(gageEth, true, msg.value, 1);
        bool gageIs0 = Currency.unwrap(seed.currency0) == gage;
        uint256 sgage = _swapExactIn(seed, gageIs0, bought / 2, 1);
        _swapExactIn(seed, !gageIs0, sgage / 2, 1);
    }
}
