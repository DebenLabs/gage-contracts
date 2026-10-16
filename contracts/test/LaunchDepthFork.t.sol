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

contract LaunchDepthForkTest is V4Fixture {
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
        if (token == address(bytes20(hex"5fc5360d0400a0fd4f2af552add042d716f1d168"))) amount = 1e15;
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

    function testFork_depth_SPY() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            2_201_764_817_843_362_789_406_767
        );
    }

    function testFork_depth_GLD() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"C9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e"))),
                8_388_608,
                10,
                IHooks(address(bytes20(hex"B608a78761f179f7C56f15E7D13921B92F00a080")))
            ),
            3_905_195_837_464_901_870_889_240_102_216_549
        );
    }

    function testFork_depth_SPCX() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            974_542_401_627_697_639_115_874
        );
    }

    function testFork_depth_AAPL() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            4_423_925_628_154_601_963_986_288_747_967_959
        );
    }

    function testFork_depth_NVDA() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            5_193_860_365_128_127_951_675_985_571_241_276
        );
    }

    function testFork_depth_GOOGL() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"2e0847e8910a9732eb3fb1bb4b70a580adad4fe3"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            1_459_924_718_172_230_649_313_827
        );
    }

    function testFork_depth_TSLA() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            1_493_138_654_873_006_322_177_780
        );
    }

    function testFork_depth_DJT() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"1D11f0496982706C5e14A514D4E79F2e6BdE4516"))),
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                2057,
                21,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            237_881_672_724_730_263_392_881
        );
    }

    function testFork_depth_META() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"c0d6457c16cc70d6790dd43521c899c87ce02f35"))),
                3000,
                60,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            3_199_873_143_122_049_692_001_819_641_855_945
        );
    }

    function testFork_depth_PLTR() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"894e1ec2d74ffe5aef8dc8a9e84686accb964f2a"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            5_979_692_919_047_707_324_629_734_036_247_488
        );
    }

    function testFork_depth_AMD() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"86923f96303d656e4aa86d9d42d1e57ad2023fdc"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            3_603_374_835_406_738_334_432_682_481_074_056
        );
    }

    function testFork_depth_MU() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            2_458_982_331_412_711_439_620_526_165_493_728
        );
    }

    function testFork_depth_HIMS() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5fc5360D0400a0Fd4f2af552ADD042D716F1d168"))),
                Currency.wrap(address(bytes20(hex"CceE82fE024c36fA15E1005edE3E9e4787e23D09"))),
                9000,
                90,
                IHooks(address(bytes20(hex"0000000000000000000000000000000000000000")))
            ),
            14_953_985_313_638_144_881_439_749_408_515_123
        );
    }

    function testFork_depth_AI() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"2e8c31162b855a2ffa90f6f8634643ad6f111e18"))),
                Currency.wrap(address(bytes20(hex"d0601ce157db5bdc3162bbac2a2c8af5320d9eec"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            2_440_904_677_650_370_779_715_551_799
        );
    }

    function testFork_depth_BONER() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"98096d17e191b3da1d5f99a6d7b3584351b11e18"))),
                Currency.wrap(address(bytes20(hex"ccee82fe024c36fa15e1005ede3e9e4787e23d09"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            3_545_752_145_023_247_757_938_130_845
        );
    }

    function testFork_depth_MOO() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"d9db30bb0d2b8d2eae3826a1372117e058791e18"))),
                Currency.wrap(address(bytes20(hex"ff080c8ce2e5feadaca0da81314ae59d232d4afd"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            362_241_630_662_578_038_441_146_333
        );
    }

    function testFork_depth_SPACEHOOD() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"))),
                Currency.wrap(address(bytes20(hex"fe7e19cbce2f896c6c528bc355baf5a768291e18"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            11_213_437_550_551_460_707_226_889_641_240
        );
    }

    function testFork_depth_ICOIN() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"5d6ef090a1461b11c9427ac319260122d1c61e18"))),
                Currency.wrap(address(bytes20(hex"af3d76f1834a1d425780943c99ea8a608f8a93f9"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            318_871_015_954_448_758_377_315_906
        );
    }

    function testFork_depth_PAIR() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"6b1d42927b1a84ec28fa88d4fc6fa7af404966be"))),
                10_000,
                200,
                IHooks(address(bytes20(hex"16d1560630ce74af4478d9b8ad46548a092a2000")))
            ),
            18_128_336_111_047_004_616_921_347_797_151
        );
    }

    function testFork_depth_DOGGIE() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                Currency.wrap(address(bytes20(hex"a9efe2fc94de79734c03051515f48f254ce61e18"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            39_563_122_383_965_063_058_816_102_559_083
        );
    }

    function testFork_depth_EARN() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"a3b6aee90017b72c0812dc1e013de70eb2917ba3"))),
                8_388_608,
                200,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            408_905_461_435_238_708_547_530_133_299_332
        );
    }

    function testFork_depth_SCHIFFY() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"42afa2124ca5a2b83898e46b2da9a190995b1e18"))),
                Currency.wrap(address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e"))),
                8_388_608,
                8,
                IHooks(address(bytes20(hex"4e3468951d49f2eea976ed0d6e75ffcb44a9a544")))
            ),
            140_989_044_651_616_431_757_035_488
        );
    }

    function testFork_depth_BOW() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"117cc2133c37b721f49de2a7a74833232b3b4c0c"))),
                Currency.wrap(address(bytes20(hex"451b42a15100c340ca12f7c66de06fac5ea2d751"))),
                0,
                200,
                IHooks(address(bytes20(hex"e5e702641ea86f4ae6cc3cdaed2b886f976be044")))
            ),
            25_640_288_133_755_150_108_506_447_741_383
        );
    }

    function testFork_depth_OPTIMUS() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"0ff9072a1ead154d92c2d2fef16afba6028ce2b2"))),
                Currency.wrap(address(bytes20(hex"322f0929c4625ed5bad873c95208d54e1c003b2d"))),
                0,
                200,
                IHooks(address(bytes20(hex"e5e702641ea86f4ae6cc3cdaed2b886f976be044")))
            ),
            335_068_610_381_518_849_036_345_583
        );
    }

    function testFork_depth_GG() public {
        _depth(
            PoolKey(
                Currency.wrap(address(bytes20(hex"c9a981fee1f9dec688bb123ccdecc63d0debfc4e"))),
                Currency.wrap(address(bytes20(hex"cacb0e9caccee63ec4d82952e561a291c68bcb68"))),
                0,
                200,
                IHooks(address(bytes20(hex"e5e702641ea86f4ae6cc3cdaed2b886f976be044")))
            ),
            23_761_240_110_070_750_982_813_435_288_376
        );
    }
}
