// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {GageV2BridgedForkTest} from "./GageV2BridgedFork.t.sol";
import {IV3Lifecycle} from "./GageV2Fork.t.sol";
import {V2MarketSnapshot} from "./fixtures/V2MarketSnapshot.sol";
import {GageV2CollateralValidator} from "../../src/v2/GageV2CollateralValidator.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {V2Loan, V2State} from "../../src/v2/V2Types.sol";
import {GageV2EntryRouter} from "../../src/v2/GageV2EntryRouter.sol";
import {GageV2ZapRouter, IWrappedETH} from "../../src/v2/GageV2ZapRouter.sol";
import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {GageV2Vault} from "../../src/v2/GageV2Vault.sol";
import {unitsOf} from "../helpers/CoreUnits.sol";

using {unitsOf} for GageV2Vault;

/// @dev Only testMarkets_* uses the exact production inventory. The inherited generic route tests have their own fixture.
contract GageV2AllMarketsForkTest is GageV2BridgedForkTest {
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;

    struct RHSwap {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function _configureRewards() internal override {
        // Remove the generic suite's additional v3 fixture pool: it is not an admitted production collateral.
        registry.setV3PoolAllowed(V3_POOL, false, 0, 0, 0);
        V2MarketSnapshot.configure(registry);
        bridge.setEngine(address(vault));
    }

    function testMarkets_allThirtyTokensCanFundAndReclaim() public {
        address[] memory tokens = V2MarketSnapshot.tokens();
        assertEq(tokens.length, 30);
        for (uint256 i; i < tokens.length; ++i) {
            ICollateralRegistry.ERC20Config memory cfg = registry.getERC20Config(tokens[i]);
            emit log_named_address("ERC20 collateral", tokens[i]);
            deal(tokens[i], borrower, cfg.minAmount);
            uint256 id = _open(Collateral(Kind.ERC20, tokens[i], cfg.minAmount), 100e6);
            assertEq(IERC20(tokens[i]).balanceOf(vault.getLoan(id).account), cfg.minAmount);
            _repay(id, borrower);
            assertEq(IERC20(tokens[i]).balanceOf(borrower), cfg.minAmount);
        }
        _cashBacked();
    }

    function _mintMarket(PoolKey memory key, bool outside) internal returns (uint256 nft) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 amount0 = 1000 * 10 ** IERC20Metadata(token0).decimals();
        uint256 amount1 = 1000 * 10 ** IERC20Metadata(token1).decimals();
        deal(token0, borrower, amount0 * 2);
        deal(token1, borrower, amount1 * 2);
        _approvePosm(borrower, token0);
        _approvePosm(borrower, token1);
        (uint160 sqrtP, int24 tick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(_poolId(key)));
        int24 lower = (TickMath.MIN_TICK / key.tickSpacing) * key.tickSpacing;
        int24 upper = (TickMath.MAX_TICK / key.tickSpacing) * key.tickSpacing;
        if (outside) {
            lower = (tick / key.tickSpacing + 10) * key.tickSpacing;
            upper = lower + 10 * key.tickSpacing;
        }
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        return _mint(key, lower, upper, liquidity / 2, borrower, borrower);
    }

    // Liquidity-position markets (v3 and v4 pools, the range rule, the zap router's NFT listings) were tested here until
    // D44: the release's engine lends against tokens only and its collateral account refuses every position kind.

    function testMarkets_ethEntryFundsUserQuartersAndPreservesDonations() public {
        GageV2EntryRouter entry =
            new GageV2EntryRouter(vault, IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904));
        registry.setRouter(address(entry), true);
        vm.startPrank(borrower);
        IERC20(SPY).approve(address(vault), 1e18);
        uint256 id = vault.list(
            Collateral(Kind.ERC20, SPY, 1e18), 1_000_000_003, 1100e6, 7 days, uint40(block.timestamp + 1 days), false
        );
        vm.stopPrank();
        uint256 amount = entry.contribution(id, 2);
        assertEq(amount, 500_000_002);
        deal(USDG, address(entry), 19e6);
        vm.deal(address(entry), 0.2 ether);
        vm.deal(lender[0], 1 ether);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(RHSwap(cashEthKey, true, 1 ether, uint128(amount), amount * 1e36 / 1e18, ""));
        params[1] = abi.encode(address(0), uint256(1 ether));
        params[2] = abi.encode(USDG, address(entry), uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(hex"060c0e", params);
        vm.prank(lender[0]);
        entry.fundWithETH{value: 1 ether}(id, 2, amount, hex"10", inputs, block.timestamp);
        assertEq(vault.unitsOf(id, lender[0]), 2);
        assertEq(vault.unitsOf(id, address(entry)), 0);
        assertEq(uint256(vault.getLoan(id).state), uint256(V2State.FUNDING));
        assertEq(IERC20(USDG).balanceOf(address(entry)), 19e6);
        assertEq(address(entry).balance, 0.2 ether);
        assertEq(IERC20(USDG).allowance(address(entry), address(vault)), 0);
        vm.prank(lender[1]);
        vault.fund(id, 2);
        assertEq(vault.cashCredit(borrower), 990_000_003);
        _repay(id, borrower);
        _cashBacked();
    }
}
