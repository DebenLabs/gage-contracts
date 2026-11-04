// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {GageLenderHook} from "../../src/GageLenderHook.sol";
import {IGageVault} from "../../src/interfaces/IGageVault.sol";
import {MockGageVault} from "../mocks/MockGageVault.sol";

/// @notice A lender pool shaped like the testnet's: an 18-decimal stock token (GLDx) as currency0 and 6-decimal USDG as
/// currency1, about 250 USDG a token, each side with its own vault, and a hook at an address carrying its flags.
abstract contract LenderAmmFixture is Test, Deployers {
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    /// @dev About 250.76 USDG per token: 1.0001^-221100 USDG units per token unit.
    int24 internal constant START_TICK = -221_100;
    uint16 internal constant FLOAT_BPS = 2000;
    uint256 internal constant SEED0 = 40e18;

    MockERC20 internal gld;
    MockERC20 internal usdg;
    MockGageVault internal vault0;
    MockGageVault internal vault1;
    GageLenderHook internal hook;
    PoolKey internal poolKey;
    uint160 internal startPrice;

    address internal owner = makeAddr("partner-safe");
    address internal keeper = makeAddr("keeper");
    address internal lp = makeAddr("lp");
    address internal attacker = makeAddr("attacker");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        // Sorted as on the testnet: the stock token's address is below USDG's.
        gld = MockERC20(address(0x1000000000000000000000000000000000000001));
        usdg = MockERC20(address(0x2000000000000000000000000000000000000002));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("GLDx", "GLDx", uint8(18)), address(gld));
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USDG", "USDG", uint8(6)), address(usdg));
        currency0 = Currency.wrap(address(gld));
        currency1 = Currency.wrap(address(usdg));
        vault0 = new MockGageVault(IERC20(address(gld)));
        vault1 = new MockGageVault(IERC20(address(usdg)));

        hook = _deployHook(address(uint160(FLAGS) | (uint160(0x4444) << 144)), owner);
        poolKey = PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(hook)));
        key = poolKey;
        startPrice = TickMath.getSqrtPriceAtTick(START_TICK);
        vm.prank(owner);
        manager.initialize(poolKey, startPrice);
        vm.prank(owner);
        hook.setKeeper(keeper, true);

        // The pool manager's own reserves pay what a swap's after-hook takes before the swapper settles (OpenZeppelin's
        // reserves warning); the testnet's manager holds other pools' tokens.
        gld.mint(address(manager), 1e30);
        usdg.mint(address(manager), 1e30);
        address[5] memory holders = [address(this), owner, lp, attacker, keeper];
        for (uint256 i; i < holders.length; ++i) {
            gld.mint(holders[i], 1e27);
            usdg.mint(holders[i], 1e15);
            vm.startPrank(holders[i]);
            gld.approve(address(hook), type(uint256).max);
            usdg.approve(address(hook), type(uint256).max);
            gld.approve(address(swapRouter), type(uint256).max);
            usdg.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deployHook(address at, address hookOwner) internal returns (GageLenderHook) {
        GageLenderHook.Config memory c = GageLenderHook.Config({
            poolManager: manager,
            vault0: IGageVault(address(vault0)),
            vault1: IGageVault(address(vault1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            floatBps0: FLOAT_BPS,
            floatBps1: FLOAT_BPS,
            owner: hookOwner,
            name: "gage lender GLDx/USDG",
            symbol: "gLP-GLDx-USDG"
        });
        deployCodeTo("GageLenderHook.sol:GageLenderHook", abi.encode(c), at);
        return GageLenderHook(payable(at));
    }

    /// @dev The owner seeds `SEED0` tokens and the USDG worth them at the start price.
    function _seed() internal returns (uint256 shares) {
        vm.prank(owner);
        (shares,) = hook.seedLiquidity(SEED0, _quote(SEED0, startPrice));
    }

    /// @dev Seed, then sweep each float down to its target.
    function _seedAndSweep() internal returns (uint256 shares) {
        shares = _seed();
        _rebalance(currency0);
        _rebalance(currency1);
    }

    function _rebalance(Currency currency) internal returns (int256 moved) {
        vm.prank(keeper);
        moved = hook.rebalance(currency, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
    }

    /// @dev USDG units worth `amount0` token units at `sqrtPriceX96`.
    function _quote(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @dev The hook's backing valued in USDG at `sqrtPriceX96`.
    function _backingValue(uint160 sqrtPriceX96) internal view returns (uint256) {
        return _quote(hook.backingOf(currency0), sqrtPriceX96) + hook.backingOf(currency1);
    }

    function _price() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
    }

    function _swapAs(address who, bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(who, who);
        swap(poolKey, zeroForOne, amountSpecified, ZERO_BYTES);
    }
}
