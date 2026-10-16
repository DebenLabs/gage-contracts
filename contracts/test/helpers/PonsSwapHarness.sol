// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PonsV4Swapper} from "../../src/token/base/PonsV4Swapper.sol";

/// @dev Local-fork test fixture only. Never part of the production deployment.
contract PonsSwapHarness is PonsV4Swapper {
    using SafeERC20 for IERC20;

    constructor(IPoolManager manager, address curve, PoolKey memory launchPool, uint24 hookFee)
        PonsV4Swapper(manager, curve, launchPool, hookFee)
    {}

    function swap(PoolKey calldata key, bool zeroForOne, uint256 amount, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        if (input.isAddressZero()) {
            require(msg.value == amount);
        } else {
            require(msg.value == 0);
            IERC20(Currency.unwrap(input)).safeTransferFrom(msg.sender, address(this), amount);
        }
        out = _swapExactIn(key, zeroForOne, amount, minOut);
        if (output.isAddressZero()) {
            (bool ok,) = recipient.call{value: out}("");
            require(ok);
        } else {
            IERC20(Currency.unwrap(output)).safeTransfer(recipient, out);
        }
    }
}
