// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V4Swapper} from "../../src/token/base/V4Swapper.sol";

/// @notice Testnet fixture: buys GAGE with ETH in the GAGE/ETH pool, swaps part of it for sGAGE in the GAGE/sGAGE
///         pool, and hands both to `to`. Neither token can be minted, so this is how the faucet restocks.
contract TestnetFaucetRestocker is V4Swapper {
    using SafeERC20 for IERC20;

    constructor(IPoolManager poolManager) V4Swapper(poolManager) {
        require(block.chainid == 46_630, "TESTNET ONLY");
    }

    /// @param gageEth ETH (currency0) / GAGE pool; @param gageSgage GAGE (currency0) / sGAGE pool.
    function restock(
        PoolKey calldata gageEth,
        PoolKey calldata gageSgage,
        uint256 minGage,
        uint256 gageToSwap,
        uint256 minSgage,
        address to
    ) external payable returns (uint256 gageKept, uint256 sgage) {
        require(Currency.unwrap(gageEth.currency0) == address(0), "ETH IS NOT CURRENCY0");
        require(Currency.unwrap(gageEth.currency1) == Currency.unwrap(gageSgage.currency0), "GAGE MISMATCH");
        uint256 gage = _swapExactIn(gageEth, true, msg.value, minGage);
        require(gage > gageToSwap, "TOO LITTLE GAGE");
        sgage = _swapExactIn(gageSgage, true, gageToSwap, minSgage);
        gageKept = gage - gageToSwap;
        IERC20(Currency.unwrap(gageSgage.currency0)).safeTransfer(to, gageKept);
        IERC20(Currency.unwrap(gageSgage.currency1)).safeTransfer(to, sgage);
    }
}

/// @notice Env: FAUCET_RESTOCK_KEY (the faucet wallet, passed by scripts/testnet-faucet-restock.py, never printed),
///         POOL_MANAGER, GAGE, SGAGE, SGAGE_HOOK, RESTOCK_ETH_WEI, RESTOCK_MIN_GAGE, RESTOCK_GAGE_TO_SWAP, RESTOCK_MIN_SGAGE.
contract FaucetRestock is Script {
    function run() external {
        require(block.chainid == 46_630, "TESTNET ONLY");
        uint256 key = vm.envUint("FAUCET_RESTOCK_KEY");
        address faucet = vm.addr(key);
        require(faucet == vm.envAddress("FAUCET_ADDRESS"), "NOT THE FAUCET WALLET");
        IERC20 gage = IERC20(vm.envAddress("GAGE"));
        IERC20 sgage = IERC20(vm.envAddress("SGAGE"));
        uint256 gageBefore = gage.balanceOf(faucet);
        uint256 sgageBefore = sgage.balanceOf(faucet);
        vm.startBroadcast(key);
        (uint256 kept, uint256 got) = _restock(address(gage), address(sgage), faucet);
        vm.stopBroadcast();
        require(
            gage.balanceOf(faucet) == gageBefore + kept && sgage.balanceOf(faucet) == sgageBefore + got, "NOT RECEIVED"
        );
        console2.log("faucet", faucet);
        console2.log("gageKept", kept);
        console2.log("sgageReceived", got);
    }

    function _restock(address gage, address sgage, address faucet) internal returns (uint256 kept, uint256 got) {
        TestnetFaucetRestocker restocker = new TestnetFaucetRestocker(IPoolManager(vm.envAddress("POOL_MANAGER")));
        console2.log("restocker", address(restocker));
        PoolKey memory gageEth = PoolKey(Currency.wrap(address(0)), Currency.wrap(gage), 3000, 60, IHooks(address(0)));
        PoolKey memory gageSgage =
            PoolKey(Currency.wrap(gage), Currency.wrap(sgage), 30_000, 60, IHooks(vm.envAddress("SGAGE_HOOK")));
        return restocker.restock{value: vm.envUint("RESTOCK_ETH_WEI")}(
            gageEth,
            gageSgage,
            vm.envUint("RESTOCK_MIN_GAGE"),
            vm.envUint("RESTOCK_GAGE_TO_SWAP"),
            vm.envUint("RESTOCK_MIN_SGAGE"),
            faucet
        );
    }
}
