// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {CommodityAdmissionLiveForkBase} from "./CommodityAdmissionLiveFork.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {V4Swapper} from "../../src/token/base/V4Swapper.sol";
import {GageV2CashoutRouter} from "../../src/v2/GageV2CashoutRouter.sol";
import {ILegacyCashoutRoutes} from "./fixtures/LegacyCashoutRouter.sol";
import {Collateral, Kind} from "../../src/types/Types.sol";
import {console2} from "forge-std/console2.sol";

interface IExpansionStateView {
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24);
    function getLiquidity(bytes32) external view returns (uint128);
}

// Same deployed-engine lifecycle suite for all eight approved tokens. No production contract changes.
abstract contract StockExpansionBase is CommodityAdmissionLiveForkBase {
    function testExpansion_minimumDepositAndCancellation() public {
        uint256 beforeBalance = IERC20(_token()).balanceOf(borrower);
        uint256 id = _list(Collateral(Kind.ERC20, _token(), _min()));
        vm.startPrank(borrower);
        vault.cancelFunding(id);
        vault.withdrawCollateral(id, borrower);
        vm.stopPrank();
        assertEq(IERC20(_token()).balanceOf(borrower), beforeBalance);
    }

    function testExpansion_exitEvidence() public {
        uint256 snap = vm.snapshotState();
        uint256 spot = _spotUSDG(_perDeal());
        uint256 out = _sell(_pools()[0], _perDeal());
        console2.log("perDeal input/spot/output/bps", _perDeal(), spot, out);
        console2.log("perDeal recovery bps", out * 10_000 / spot);
        assertGe(out * 100, spot * 95);
        vm.revertToState(snap);
        spot = _spotUSDG(_aggregate());
        out = _sell(_pools()[0], _aggregate());
        console2.log("aggregate input/spot/output/bps", _aggregate(), spot, out);
        console2.log("aggregate recovery bps", out * 10_000 / spot);
        assertGe(out * 100, spot * 95);
    }
}

abstract contract StockExpansionV4Base is StockExpansionBase, V4Swapper {
    constructor() V4Swapper(IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951)) {}
    function _key() internal pure virtual returns (PoolKey memory);
    function _poolId() internal pure virtual returns (bytes32);

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1); // One v4 route; no v3 address is used by the overrides.
    }

    function _configureRoutes() internal override {
        PoolKey memory k = _key();
        assertEq(keccak256(abi.encode(k)), _poolId());
        assertEq(address(k.hooks), address(0));
        assertTrue(
            (Currency.unwrap(k.currency0) == _token() && Currency.unwrap(k.currency1) == USDG)
                || (Currency.unwrap(k.currency1) == _token() && Currency.unwrap(k.currency0) == USDG)
        );
        assertGt(IExpansionStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b).getLiquidity(_poolId()), 0);
        assertFalse(registry.getPoolConfig(_poolId()).allowed);
        assertFalse(ILegacyCashoutRoutes(address(cashout)).v4Allowed(k));
        _setRouteAllowed(0, true);
        assertFalse(registry.getPoolConfig(_poolId()).allowed); // Routing never admits LP collateral.
    }

    function _setRouteAllowed(uint256, bool allowed) internal override {
        vm.prank(cashout.owner());
        cashout.setV4Route(_key(), allowed);
    }

    function _routeFee(uint256) internal pure override returns (uint24) {
        return _key().fee;
    }

    function _spotUSDG(uint256 amount) internal view override returns (uint256) {
        (uint160 sqrtPrice,,,) = IExpansionStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b).getSlot0(_poolId());
        uint256 square = uint256(sqrtPrice) * sqrtPrice;
        return Currency.unwrap(_key().currency0) == _token()
            ? FullMath.mulDiv(amount, square, 1 << 192)
            : FullMath.mulDiv(amount, 1 << 192, square);
    }

    function _sell(address, uint256 amount) internal override returns (uint256 out) {
        deal(_token(), address(this), amount);
        uint256 beforeBalance = IERC20(USDG).balanceOf(address(this));
        _swapExactIn(_key(), Currency.unwrap(_key().currency0) == _token(), amount, 1);
        assertEq(IERC20(_token()).balanceOf(address(this)), 0, "Partial v4 fill");
        out = IERC20(USDG).balanceOf(address(this)) - beforeBalance;
    }

    function _exit(uint256 id, uint24 fee) internal view override returns (GageV2CashoutRouter.Exit memory x) {
        x = super._exit(id, fee);
        x.routes[0] = GageV2CashoutRouter.Route(GageV2CashoutRouter.RouteKind.V4, _token(), USDG, 0, _key(), 1);
    }
}

contract SgovExpansionForkTest is StockExpansionBase {
    function _token() internal pure override returns (address) {
        return 0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0xfAb520051f96F4D2a32c22B6a3dD7fFfdf231bFe;
    }

    function _min() internal pure override returns (uint256) {
        return 1e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 400e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 2000e18;
    }
}

contract QqqExpansionForkTest is StockExpansionBase {
    function _token() internal pure override returns (address) {
        return 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0xD60A5d14dB690B7Afad71F76B108071D7175597d;
    }

    function _min() internal pure override returns (uint256) {
        return 0.14e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 32e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 160e18;
    }
}

contract RddtExpansionForkTest is StockExpansionBase {
    function _token() internal pure override returns (address) {
        return 0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0xa8744E76aED23B05F0126335E7BD38f7935D19fe;
    }

    function _min() internal pure override returns (uint256) {
        return 0.7e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 140e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 700e18;
    }
}

contract AmznExpansionForkTest is StockExpansionBase {
    function _token() internal pure override returns (address) {
        return 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef;
    }

    function _min() internal pure override returns (uint256) {
        return 0.42e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 60e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 300e18;
    }
}

contract CoinExpansionForkTest is StockExpansionV4Base {
    function _token() internal pure override returns (address) {
        return 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    }

    function _key() internal pure override returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            Currency.wrap(0x6330D8C3178a418788dF01a47479c0ce7CCF450b),
            10_000,
            200,
            IHooks(address(0))
        );
    }

    function _poolId() internal pure override returns (bytes32) {
        return 0x007a13fa152f6dc383cad20a8eaab4e1e2538b606936eae2a424f8aa47d6db31;
    }

    function _min() internal pure override returns (uint256) {
        return 0.53e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 60e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 300e18;
    }
}

contract IntcExpansionForkTest is StockExpansionV4Base {
    function _token() internal pure override returns (address) {
        return 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681;
    }

    function _key() internal pure override returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            Currency.wrap(0xc72b96e0E48ecd4DC75E1e45396e26300BC39681),
            10_000,
            200,
            IHooks(address(0))
        );
    }

    function _poolId() internal pure override returns (bytes32) {
        return 0xf2e329e631d0fb315a5c563ee3a9120f24822b5ef6c502a91cb56b174d5d8c22;
    }

    function _min() internal pure override returns (uint256) {
        return 0.9e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 100e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 500e18;
    }
}

contract MsftExpansionForkTest is StockExpansionBase {
    function _token() internal pure override returns (address) {
        return 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0xeb60bCD1D920ad6E102690CCFC6fB488899E1510;
    }

    function _min() internal pure override returns (uint256) {
        return 0.2e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 20e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 100e18;
    }
}

contract CostExpansionForkTest is StockExpansionBase {
    function _token() internal pure override returns (address) {
        return 0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2;
    }

    function _pools() internal pure override returns (address[] memory pools) {
        pools = new address[](1);
        pools[0] = 0x0a2121A50A09eD0796ae81F9c53fF9398355a398;
    }

    function _min() internal pure override returns (uint256) {
        return 0.11e18;
    }

    function _perDeal() internal pure override returns (uint256) {
        return 12e18;
    }

    function _aggregate() internal pure override returns (uint256) {
        return 60e18;
    }
}
