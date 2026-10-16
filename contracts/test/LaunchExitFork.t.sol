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

contract LaunchExitForkTest is V4Fixture {
    uint160 limit0;
    uint160 limit1;

    function _fork() internal {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("GAGE_EVIDENCE_BLOCK"));
        assertEq(block.chainid, 4663);
        poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        swapRouter = new PoolSwapTest(poolManager);
    }

    function _swap(PoolKey memory key, address token, uint256 amount) internal returns (uint256 received) {
        bool z = token == Currency.unwrap(key.currency0);
        address output = Currency.unwrap(z ? key.currency1 : key.currency0);
        uint256 beforeBalance = IERC20(output).balanceOf(address(this));

        deal(token, address(this), amount);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key, SwapParams(z, -int256(amount), z ? limit0 : limit1), PoolSwapTest.TestSettings(false, false), ""
        );
        received = IERC20(output).balanceOf(address(this)) - beforeBalance;
    }

    function _depth(PoolKey memory key, uint160 startPrice) internal {
        limit0 = startPrice / 2;
        limit1 = startPrice * 2;
        _fork();
        uint256 snap = vm.snapshotState();
        uint256 reserve1 = _swap(key, Currency.unwrap(key.currency0), 1e24);
        vm.revertToState(snap);
        uint256 reserve0 = _swap(key, Currency.unwrap(key.currency1), 1e24);
        vm.revertToState(snap);
        assertGt(reserve0 + reserve1, 0);
        emit log_named_uint("reserve0", reserve0);
        emit log_named_uint("reserve1", reserve1);
    }

    function testFork_exit_SPY() public {
        _fork();
        limit0 = uint160(2_201_764_817_843_362_789_406_767) / 2;
        limit1 = 2_201_764_817_843_362_789_406_767 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")),
            259_562_548_561_047_917_453
        );
        emit log_named_uint("inputSpotUSDGRaw", 200_458_611_509);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(200_458_611_509) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_GLD() public {
        _fork();
        limit0 = uint160(3_905_195_837_464_901_870_889_240_102_216_549) / 2;
        limit1 = 3_905_195_837_464_901_870_889_240_102_216_549 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"C9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e"))),
                8_388_608,
                10,
                IHooks(address(bytes20(hex"B608a78761f179f7C56f15E7D13921B92F00a080")))
            ),
            address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e")),
            127_172_552_929_634_293_717
        );
        emit log_named_uint("inputSpotUSDGRaw", 52_344_001_732);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(52_344_001_732) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_SPCX() public {
        _fork();
        limit0 = uint160(974_542_401_627_697_639_115_874) / 2;
        limit1 = 974_542_401_627_697_639_115_874 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea")),
            305_241_198_441_536_823_410
        );
        emit log_named_uint("inputSpotUSDGRaw", 46_183_353_169);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(46_183_353_169) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_AAPL() public {
        _fork();
        limit0 = uint160(4_423_925_628_154_601_963_986_288_747_967_959) / 2;
        limit1 = 4_423_925_628_154_601_963_986_288_747_967_959 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9")),
            97_820_785_047_160_062_042
        );
        emit log_named_uint("inputSpotUSDGRaw", 31_374_345_641);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(31_374_345_641) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_NVDA() public {
        _fork();
        limit0 = uint160(5_193_860_365_128_127_951_675_985_571_241_276) / 2;
        limit1 = 5_193_860_365_128_127_951_675_985_571_241_276 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec")),
            87_988_579_012_144_913_120
        );
        emit log_named_uint("inputSpotUSDGRaw", 20_474_105_286);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(20_474_105_286) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_GOOGL() public {
        _fork();
        limit0 = uint160(1_459_924_718_172_230_649_313_827) / 2;
        limit1 = 1_459_924_718_172_230_649_313_827 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"2e0847e8910a9732eb3fb1bb4b70a580adad4fe3"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"2e0847e8910a9732eb3fb1bb4b70a580adad4fe3")),
            73_019_910_113_791_099_780
        );
        emit log_named_uint("inputSpotUSDGRaw", 24_793_797_507);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(24_793_797_507) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_TSLA() public {
        _fork();
        limit0 = uint160(1_493_138_654_873_006_322_177_780) / 2;
        limit1 = 1_493_138_654_873_006_322_177_780 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d")),
            48_400_856_747_997_375_195
        );
        emit log_named_uint("inputSpotUSDGRaw", 17_190_723_665);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(17_190_723_665) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_DJT() public {
        _fork();
        limit0 = uint160(237_881_672_724_730_263_392_881) / 2;
        limit1 = 237_881_672_724_730_263_392_881 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"1D11f0496982706C5e14A514D4E79F2e6BdE4516"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                2057,
                21,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"1d11f0496982706c5e14a514d4e79f2e6bde4516")),
            1_869_983_614_210_045_195_612
        );
        emit log_named_uint("inputSpotUSDGRaw", 16_857_788_504);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(16_857_788_504) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_META() public {
        _fork();
        limit0 = uint160(3_199_873_143_122_049_692_001_819_641_855_945) / 2;
        limit1 = 3_199_873_143_122_049_692_001_819_641_855_945 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"c0d6457c16cc70d6790dd43521c899c87ce02f35"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"c0d6457c16cc70d6790dd43521c899c87ce02f35")),
            24_829_701_801_047_415_936
        );
        emit log_named_uint("inputSpotUSDGRaw", 15_221_769_758);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(15_221_769_758) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_PLTR() public {
        _fork();
        limit0 = uint160(5_979_692_919_047_707_324_629_734_036_247_488) / 2;
        limit1 = 5_979_692_919_047_707_324_629_734_036_247_488 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"894e1ec2d74ffe5aef8dc8a9e84686accb964f2a"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"894e1ec2d74ffe5aef8dc8a9e84686accb964f2a")),
            82_444_159_606_629_860_294
        );
        emit log_named_uint("inputSpotUSDGRaw", 14_473_091_216);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(14_473_091_216) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_AMD() public {
        _fork();
        limit0 = uint160(3_603_374_835_406_738_334_432_682_481_074_056) / 2;
        limit1 = 3_603_374_835_406_738_334_432_682_481_074_056 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"86923f96303d656e4aa86d9d42d1e57ad2023fdc"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"86923f96303d656e4aa86d9d42d1e57ad2023fdc")),
            28_136_443_734_983_420_876
        );
        emit log_named_uint("inputSpotUSDGRaw", 13_602_210_438);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(13_602_210_438) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_MU() public {
        _fork();
        limit0 = uint160(2_458_982_331_412_711_439_620_526_165_493_728) / 2;
        limit1 = 2_458_982_331_412_711_439_620_526_165_493_728 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd")),
            11_598_144_978_462_712_176
        );
        emit log_named_uint("inputSpotUSDGRaw", 12_040_288_250);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(12_040_288_250) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_HIMS() public {
        _fork();
        limit0 = uint160(14_953_985_313_638_144_881_439_749_408_515_123) / 2;
        limit1 = 14_953_985_313_638_144_881_439_749_408_515_123 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"CceE82fE024c36fA15E1005edE3E9e4787e23D09"))),
                9000,
                90,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09")),
            416_870_585_904_733_605_409
        );
        emit log_named_uint("inputSpotUSDGRaw", 11_701_634_278);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(11_701_634_278) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_AI() public {
        _fork();
        limit0 = uint160(2_440_904_677_650_370_779_715_551_799) / 2;
        limit1 = 2_440_904_677_650_370_779_715_551_799 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"2e8c31162b855a2ffa90f6f8634643ad6f111e18"))),
                Currency.wrap(address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"2e8c31162b855a2ffa90f6f8634643ad6f111e18")),
            46_350_437_367_518_644_349_982
        );
        limit0 = uint160(5_193_860_365_128_127_951_675_985_571_241_276) / 2;
        limit1 = 5_193_860_365_128_127_951_675_985_571_241_276 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 10_237_052_643);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(10_237_052_643) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_BONER() public {
        _fork();
        limit0 = uint160(3_545_752_145_023_247_757_938_130_845) / 2;
        limit1 = 3_545_752_145_023_247_757_938_130_845 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"98096d17e191b3da1d5f99a6d7b3584351b11e18"))),
                Currency.wrap(address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"98096d17e191b3da1d5f99a6d7b3584351b11e18")),
            104_067_153_560_158_953_092_963
        );
        limit0 = uint160(14_953_985_313_638_144_881_439_749_408_515_123) / 2;
        limit1 = 14_953_985_313_638_144_881_439_749_408_515_123 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"CceE82fE024c36fA15E1005edE3E9e4787e23D09"))),
                9000,
                90,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 5_850_817_139);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(5_850_817_139) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_MOO() public {
        _fork();
        limit0 = uint160(362_241_630_662_578_038_441_146_333) / 2;
        limit1 = 362_241_630_662_578_038_441_146_333 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"d9db30bb0d2b8d2eae3826a1372117e058791e18"))),
                Currency.wrap(address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"d9db30bb0d2b8d2eae3826a1372117e058791e18")),
            174_193_989_936_306_064_133_305
        );
        limit0 = uint160(2_458_982_331_412_711_439_620_526_165_493_728) / 2;
        limit1 = 2_458_982_331_412_711_439_620_526_165_493_728 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 3_780_237_367);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(3_780_237_367) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_SPACEHOOD() public {
        _fork();
        limit0 = uint160(11_213_437_550_551_460_707_226_889_641_240) / 2;
        limit1 = 11_213_437_550_551_460_707_226_889_641_240 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"))),
                Currency.wrap(address(bytes20(hex"fe7e19cbce2f896c6c528bc355baf5a768291e18"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"fe7e19cbce2f896c6c528bc355baf5a768291e18")),
            273_751_475_067_811_999_207_986
        );
        limit0 = uint160(974_542_401_627_697_639_115_874) / 2;
        limit1 = 974_542_401_627_697_639_115_874 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 2_067_666_111);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(2_067_666_111) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_ICOIN() public {
        _fork();
        limit0 = uint160(318_871_015_954_448_758_377_315_906) / 2;
        limit1 = 318_871_015_954_448_758_377_315_906 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5d6ef090a1461b11c9427ac319260122d1c61e18"))),
                Currency.wrap(address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"5d6ef090a1461b11c9427ac319260122d1c61e18")),
            312_209_331_638_066_943_781_564
        );
        limit0 = uint160(4_423_925_628_154_601_963_986_288_747_967_959) / 2;
        limit1 = 4_423_925_628_154_601_963_986_288_747_967_959 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 1_622_035_428);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(1_622_035_428) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_PAIR() public {
        _fork();
        limit0 = uint160(18_128_336_111_047_004_616_921_347_797_151) / 2;
        limit1 = 18_128_336_111_047_004_616_921_347_797_151 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"6b1d42927b1a84ec28fa88d4fc6fa7af404966be"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"16d1560630ce74af4478d9b8ad46548a092a2000")))
            ),
            address(bytes20(hex"6b1d42927b1a84ec28fa88d4fc6fa7af404966be")),
            87_796_087_146_984_321_836_370
        );
        limit0 = uint160(2_201_764_817_843_362_789_406_767) / 2;
        limit1 = 2_201_764_817_843_362_789_406_767 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 1_295_093_510);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(1_295_093_510) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_DOGGIE() public {
        _fork();
        limit0 = uint160(39_563_122_383_965_063_058_816_102_559_083) / 2;
        limit1 = 39_563_122_383_965_063_058_816_102_559_083 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                Currency.wrap(address(bytes20(hex"a9efe2fc94de79734c03051515f48f254ce61e18"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"a9efe2fc94de79734c03051515f48f254ce61e18")),
            622_699_573_015_721_617_296_998
        );
        limit0 = uint160(1_493_138_654_873_006_322_177_780) / 2;
        limit1 = 1_493_138_654_873_006_322_177_780 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 886_947_117);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(886_947_117) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_EARN() public {
        _fork();
        limit0 = uint160(408_905_461_435_238_708_547_530_133_299_332) / 2;
        limit1 = 408_905_461_435_238_708_547_530_133_299_332 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"a3b6aee90017b72c0812dc1e013de70eb2917ba3"))),
                8_388_608,
                200,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"a3b6aee90017b72c0812dc1e013de70eb2917ba3")),
            20_739_277_149_057_836_879_998_717
        );
        limit0 = uint160(2_201_764_817_843_362_789_406_767) / 2;
        limit1 = 2_201_764_817_843_362_789_406_767 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 601_297_846);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(601_297_846) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_SCHIFFY() public {
        _fork();
        limit0 = uint160(140_989_044_651_616_431_757_035_488) / 2;
        limit1 = 140_989_044_651_616_431_757_035_488 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"42afa2124ca5a2b83898e46b2da9a190995b1e18"))),
                Currency.wrap(address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            address(bytes20(hex"42afa2124ca5a2b83898e46b2da9a190995b1e18")),
            537_494_350_155_575_070_004_844
        );
        limit0 = uint160(3_905_195_837_464_901_870_889_240_102_216_549) / 2;
        limit1 = 3_905_195_837_464_901_870_889_240_102_216_549 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"C9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e"))),
                8_388_608,
                10,
                IHooks(address(bytes20(hex"B608a78761f179f7C56f15E7D13921B92F00a080")))
            ),
            address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 700_582_046);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(700_582_046) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_BOW() public {
        _fork();
        limit0 = uint160(25_640_288_133_755_150_108_506_447_741_383) / 2;
        limit1 = 25_640_288_133_755_150_108_506_447_741_383 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"451b42a15100c340ca12f7c66de06fac5ea2d751"))),
                0,
                200,
                IHooks(address(bytes20(hex"e5e702641ea86f4ae6cc3cdaed2b886f976be044")))
            ),
            address(bytes20(hex"451b42a15100c340ca12f7c66de06fac5ea2d751")),
            84_846_370_406_742_273_882_512
        );
        limit0 = uint160(2_201_764_817_843_362_789_406_767) / 2;
        limit1 = 2_201_764_817_843_362_789_406_767 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 625_646_935);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(625_646_935) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_OPTIMUS() public {
        _fork();
        limit0 = uint160(335_068_610_381_518_849_036_345_583) / 2;
        limit1 = 335_068_610_381_518_849_036_345_583 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"0ff9072a1ead154d92c2d2fef16afba6028ce2b2"))),
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                0,
                200,
                IHooks(address(bytes20(hex"e5e702641ea86f4ae6cc3cdaed2b886f976be044")))
            ),
            address(bytes20(hex"0ff9072a1ead154d92c2d2fef16afba6028ce2b2")),
            94_615_650_447_814_429_969_230
        );
        limit0 = uint160(1_493_138_654_873_006_322_177_780) / 2;
        limit1 = 1_493_138_654_873_006_322_177_780 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 601_052_504);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(601_052_504) * 95 / 100, "Exit loses more than 5 percent including fees");
    }

    function testFork_exit_GG() public {
        _fork();
        limit0 = uint160(23_761_240_110_070_750_982_813_435_288_376) / 2;
        limit1 = 23_761_240_110_070_750_982_813_435_288_376 * 2;
        uint256 output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e"))),
                Currency.wrap(address(bytes20(hex"cacb0e9caccee63ec4d82952e561a291c68bcb68"))),
                0,
                200,
                IHooks(address(bytes20(hex"e5e702641ea86f4ae6cc3cdaed2b886f976be044")))
            ),
            address(bytes20(hex"cacb0e9caccee63ec4d82952e561a291c68bcb68")),
            114_205_805_911_728_292_576_182
        );
        limit0 = uint160(3_905_195_837_464_901_870_889_240_102_216_549) / 2;
        limit1 = 3_905_195_837_464_901_870_889_240_102_216_549 * 2;
        output = _swap(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"C9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e"))),
                8_388_608,
                10,
                IHooks(address(bytes20(hex"B608a78761f179f7C56f15E7D13921B92F00a080")))
            ),
            address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e")),
            output
        );
        emit log_named_uint("inputSpotUSDGRaw", 522_615_969);
        emit log_named_uint("outputUSDGRaw", output);
        assertGe(output, uint256(522_615_969) * 95 / 100, "Exit loses more than 5 percent including fees");
    }
}
