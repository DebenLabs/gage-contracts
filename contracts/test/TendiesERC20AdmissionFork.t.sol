// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DealVault} from "../src/DealVault.sol";
import {CollateralRegistry} from "../src/CollateralRegistry.sol";
import {Collateral, Kind} from "../src/types/Types.sol";
import {Lane} from "../src/interfaces/ICollateralRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

interface IUniV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

interface IV4State {
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24);
}

/// Normal admission/deposit/settlement/exit rehearsal against EXISTING deployed bytecode.
/// Owner configuration and user funding below are local fork fixtures, never public transactions.
contract TendiesERC20AdmissionForkTest is Test {
    address constant TOKEN = 0x45242320DBB855EeA8Fd36804C6487E10E97FCF9;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant POOL = 0x237609918F330ADD285b8bC5f8f2922283D1C4C5;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    DealVault constant vault = DealVault(0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF);
    CollateralRegistry constant registry = CollateralRegistry(0x67B40102C474BA599Dfa4c58E77f5Bc20b933C2d);
    uint256 constant MIN = 7000e18;
    uint256 constant PER = 148_000e18;
    uint256 constant TOTAL = 740_000e18;
    address borrower;
    address lender;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_EVIDENCE_BLOCK"));
        assertEq(block.chainid, 4663);
        assertEq(address(vault).codehash, 0xf5ef6d2746a95852113bda288d90bfd9e6cfe398c4c37e578b6d19a83f8a3fac);
        assertEq(TOKEN.codehash, 0xf680430391b4ba785aa712118ba59d26166adc3fe06cce93e374bcf059438994);
        assertEq(address(vault.REGISTRY()), address(registry));
        assertFalse(registry.getERC20Config(TOKEN).allowed);
        vm.prank(registry.owner());
        registry.setERC20Allowed(TOKEN, true, Lane.MEME, MIN, PER, TOTAL);
        borrower = makeAddr("token admission borrower");
        lender = makeAddr("token admission lender");
        deal(TOKEN, borrower, 2 * TOTAL);
        deal(USDG, borrower, 10_000e6);
        deal(USDG, lender, 10_000e6);
        vm.startPrank(borrower);
        IERC20(TOKEN).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        IERC20(USDG).approve(address(vault), type(uint256).max);
    }

    function list(uint256 amount) internal returns (uint256 id) {
        vm.prank(borrower);
        return vault.list(Collateral(Kind.ERC20, TOKEN, amount), 100e6, 7 days, 0, 90e6);
    }

    function testFork_ExistingVaultCancelWithdraw() public {
        uint256 beforeBalance = IERC20(TOKEN).balanceOf(borrower);
        uint256 id = list(PER);
        vm.prank(borrower);
        vault.cancel(id);
        vm.prank(borrower);
        vault.withdrawCollateral(id);
        assertEq(IERC20(TOKEN).balanceOf(borrower), beforeBalance);
        assertEq(vault.openRaw(TOKEN), 0);
    }

    function testFork_ExistingVaultRepaymentAndDefault() public {
        for (uint256 i; i < 2; i++) {
            uint256 id = list(PER);
            vm.prank(lender);
            vault.fund(id, lender);
            assertGt(vault.balanceUSDG(borrower), 0);
            vm.prank(borrower);
            vault.withdrawUSDG();
            address receiver = borrower;
            if (i == 0) {
                vm.prank(borrower);
                vault.reclaim(id);
            } else {
                vm.warp(vault.claimableAt(id));
                vm.prank(lender);
                vault.claim(id);
                receiver = lender;
            }
            uint256 beforeBalance = IERC20(TOKEN).balanceOf(receiver);
            vm.prank(receiver);
            vault.withdrawCollateral(id);
            assertEq(IERC20(TOKEN).balanceOf(receiver) - beforeBalance, PER);
            assertEq(vault.openRaw(TOKEN), 0);
        }
    }

    function testFork_ExistingVaultLimitsAndRevocation() public {
        vm.expectRevert();
        list(MIN - 1);
        vm.expectRevert();
        list(PER + 1);
        uint256 id = list(PER);
        for (uint256 i; i < 4; i++) {
            list(PER);
        }
        assertEq(vault.openRaw(TOKEN), TOTAL);
        vm.expectRevert();
        list(MIN);
        vm.startPrank(registry.owner());
        registry.setERC20Allowed(TOKEN, false, Lane.MEME, 0, 0, 0);
        registry.pauseNewDeals(true);
        vm.stopPrank();
        vm.prank(borrower);
        vault.cancel(id);
        vm.prank(borrower);
        vault.withdrawCollateral(id);
        assertEq(vault.openRaw(TOKEN), TOTAL - PER);
    }

    function testFork_ProposedTokenSaleAfterFeesAndGas() public {
        (uint160 s,,,,,,) = IUniV3Pool(POOL).slot0();
        (uint160 e,,,) = IV4State(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b)
            .getSlot0(0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; i++) {
            uint256 amount = i == 0 ? PER : TOTAL;
            uint256 wethSpot = Math.mulDiv(Math.mulDiv(amount, 1 << 96, s), 1 << 96, s);
            uint256 spot = Math.mulDiv(Math.mulDiv(wethSpot, e, 1 << 96), e, 1 << 96);
            deal(TOKEN, address(this), amount);
            IERC20(TOKEN).approve(ROUTER, amount);
            uint256 startGas = gasleft();
            uint256 wethOut = IV3SwapRouter(ROUTER)
                .exactInputSingle(
                    IV3SwapRouter.ExactInputSingleParams(TOKEN, WETH, 10_000, address(this), amount, 0, 0)
                );
            IWETH(WETH).withdraw(wethOut);
            PoolSwapTest swapper = new PoolSwapTest(IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951));
            uint256 beforeBalance = IERC20(USDG).balanceOf(address(this));
            swapper.swap{value: wethOut}(
                PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), 100, 1, IHooks(address(0))),
                SwapParams(true, -int256(wethOut), 4_295_128_740),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            uint256 usedGas = startGas - gasleft() + 100_000;
            // 1 gwei conservative execution allowance, including router deployment overhead.
            uint256 gasUSDG = Math.mulDiv(Math.mulDiv(usedGas * 1 gwei, e, 1 << 96), e, 1 << 96);
            uint256 out = IERC20(USDG).balanceOf(address(this)) - beforeBalance;
            assertGt(out, gasUSDG);
            assertGe((out - gasUSDG) * 10_000 / spot, 9500);
            emit log_named_uint(
                i == 0 ? "perDealExitBpsAfterGas" : "aggregateExitBpsAfterGas", (out - gasUSDG) * 10_000 / spot
            );
            emit log_named_uint("spotUSDG", spot);
            emit log_named_uint("exitUSDG", out);
            emit log_named_uint("gasAllowanceUSDG", gasUSDG);
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
    }
}
