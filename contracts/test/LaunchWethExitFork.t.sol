// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {V4Fixture} from "./utils/V4Fixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IWethExit {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ILaunchState {
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24);
}

contract LaunchWethExitForkTest is V4Fixture {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    receive() external payable {}

    function testFork_wethDepthAndMaximumExit() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_EVIDENCE_BLOCK"));
        assertEq(block.chainid, 4663);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        swapRouter = new PoolSwapTest(poolManager);
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0)));
        (uint160 sqrt,,,) = ILaunchState(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b).getSlot0(_poolId(key));
        uint256 snap = vm.snapshotState();
        vm.deal(address(this), 1e24);
        swapRouter.swap{value: 1e24}(
            key, SwapParams(true, -int256(1e24), sqrt / 2), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 reserveUsdg = IERC20(USDG).balanceOf(address(this));
        assertTrue(vm.revertToState(snap));
        deal(USDG, address(this), 1e15);
        IERC20(USDG).approve(address(swapRouter), type(uint256).max);
        uint256 beforeEth = address(this).balance;
        swapRouter.swap(key, SwapParams(false, -int256(1e15), sqrt * 2), PoolSwapTest.TestSettings(false, false), "");
        uint256 reserveEth = address(this).balance - beforeEth;
        assertTrue(vm.revertToState(snap));
        uint256 depth = reserveUsdg + Math.mulDiv(reserveEth, uint256(sqrt) * sqrt, 1 << 192);
        uint256 capRaw = Math.mulDiv(depth * 2 / 100, 1 << 192, uint256(sqrt) * sqrt);
        vm.deal(address(this), capRaw);
        IWethExit(WETH).deposit{value: capRaw}();
        assertEq(IERC20(WETH).balanceOf(address(this)), capRaw);
        IWethExit(WETH).withdraw(capRaw);
        swapRouter.swap{value: capRaw}(
            key, SwapParams(true, -int256(capRaw), sqrt / 2), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 output = IERC20(USDG).balanceOf(address(this));
        assertGe(output, depth * 2 / 100 * 95 / 100, "WETH cap exit loses over 5 percent");
        emit log_named_uint("depthUSDGRaw", depth);
        emit log_named_uint("capPerDeal", capRaw);
        emit log_named_uint("capTotal", capRaw * 5);
        emit log_named_uint("minimum", Math.mulDiv(100e6, 1 << 192, uint256(sqrt) * sqrt, Math.Rounding.Ceil));
        emit log_named_uint("exitUSDGRaw", output);
    }
}
