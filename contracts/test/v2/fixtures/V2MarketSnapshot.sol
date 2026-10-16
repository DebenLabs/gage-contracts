// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {GageV2Registry} from "../../../src/v2/GageV2Registry.sol";
import {Lane} from "../../../src/interfaces/ICollateralRegistry.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
/// @dev Generated from the read-only inventory at Robinhood mainnet block 58110397.

library V2MarketSnapshot {
    uint256 internal constant BLOCK = 58_110_397;

    function configure(GageV2Registry r) internal {
        uint32[] memory terms = new uint32[](2);
        terms[0] = 7 days;
        terms[1] = 21 days;
        r.setTerms(terms);
        r.setInRangeRequired(false);
        r.setMemePairs(7);
        r.setERC20Allowed(
            0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73,
            true,
            Lane(1),
            40_151_162_267_406_354,
            10_033_230_407_028_811_769,
            50_166_152_035_144_058_845
        );
        r.setERC20Allowed(
            0x117cc2133c37B721F49dE2A7a74833232B3B4C0C,
            true,
            Lane(0),
            129_484_359_193_353_593,
            259_562_548_561_047_917_453,
            1_297_812_742_805_239_587_266
        );
        r.setERC20Allowed(
            0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa,
            true,
            Lane(0),
            660_933_382_900_831_979,
            305_241_198_441_536_823_410,
            1_526_205_992_207_684_117_053
        );
        r.setERC20Allowed(
            0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
            true,
            Lane(0),
            311_785_897_193_802_189,
            97_820_785_047_160_062_042,
            489_103_925_235_800_310_214
        );
        r.setERC20Allowed(
            0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
            true,
            Lane(0),
            429_755_429_012_289_364,
            87_988_579_012_144_913_120,
            439_942_895_060_724_565_600
        );
        r.setERC20Allowed(
            0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3,
            true,
            Lane(0),
            294_508_778_220_214_309,
            73_019_910_113_791_099_780,
            365_099_550_568_955_498_901
        );
        r.setERC20Allowed(
            0x322F0929c4625eD5bAd873c95208D54E1c003b2d,
            true,
            Lane(0),
            281_552_177_149_006_563,
            48_400_856_747_997_375_195,
            242_004_283_739_986_875_975
        );
        r.setERC20Allowed(
            0x1D11f0496982706C5e14A514D4E79F2e6BdE4516,
            true,
            Lane(0),
            11_092_698_272_662_448_859,
            1_869_983_614_210_045_195_612,
            9_349_918_071_050_225_978_062
        );
        r.setERC20Allowed(
            0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35,
            true,
            Lane(0),
            163_119_677_897_701_512,
            24_829_701_801_047_415_936,
            124_148_509_005_237_079_683
        );
        r.setERC20Allowed(
            0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A,
            true,
            Lane(0),
            569_637_531_992_407_833,
            82_444_159_606_629_860_294,
            412_220_798_033_149_301_474
        );
        r.setERC20Allowed(
            0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD,
            true,
            Lane(0),
            96_327_801_604_882_110,
            11_598_144_978_462_712_176,
            57_990_724_892_313_560_880
        );
        r.setERC20Allowed(
            0xCceE82fE024c36fA15E1005edE3E9e4787e23D09,
            true,
            Lane(0),
            3_562_498_844_010_369_200,
            416_870_585_904_733_605_409,
            2_084_352_929_523_668_027_047
        );
        r.setERC20Allowed(
            0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18,
            true,
            Lane(2),
            452_771_310_081_863_896_249,
            46_350_437_367_518_644_349_982,
            231_752_186_837_593_221_749_914
        );
        r.setERC20Allowed(
            0x98096d17e191B3dA1d5f99a6D7b3584351b11E18,
            true,
            Lane(2),
            1_778_677_252_811_691_215_972,
            104_067_153_560_158_953_092_963,
            520_335_767_800_794_765_464_816
        );
        r.setERC20Allowed(
            0xD9dB30BB0D2b8d2eae3826A1372117E058791e18,
            true,
            Lane(2),
            4_608_017_248_239_520_731_366,
            174_193_989_936_306_064_133_305,
            870_969_949_681_530_320_666_528
        );
        r.setERC20Allowed(
            0xFe7E19CbCe2f896C6C528BC355bAF5a768291E18,
            true,
            Lane(2),
            13_239_636_395_010_150_687_183,
            273_751_475_067_811_999_207_986,
            1_368_757_375_339_059_996_039_931
        );
        r.setERC20Allowed(
            0x5d6EF090a1461B11c9427aC319260122D1C61e18,
            true,
            Lane(2),
            19_247_997_060_244_023_550_501,
            312_209_331_638_066_943_781_564,
            1_561_046_658_190_334_718_907_820
        );
        r.setERC20Allowed(
            0x6b1d42927B1a84eC28Fa88d4fC6FA7AF404966be,
            true,
            Lane(2),
            6_779_131_116_219_222_694_053,
            87_796_087_146_984_321_836_370,
            438_980_435_734_921_609_181_852
        );
        r.setERC20Allowed(
            0xa9eFe2Fc94dE79734C03051515F48f254Ce61e18,
            true,
            Lane(2),
            70_207_068_823_615_790_149_194,
            622_699_573_015_721_617_296_998,
            3_113_497_865_078_608_086_484_990
        );
        r.setERC20Allowed(
            0xA3b6AEe90017b72c0812dC1e013De70eB2917ba3,
            true,
            Lane(2),
            3_449_085_550_148_571_412_600_048,
            20_739_277_149_057_836_879_998_717,
            103_696_385_745_289_184_399_993_587
        );
        r.setERC20Allowed(
            0x451b42A15100C340CA12F7c66DE06fac5EA2D751,
            true,
            Lane(2),
            13_561_381_920_963_885_696_525,
            84_846_370_406_742_273_882_512,
            424_231_852_033_711_369_412_563
        );
        r.setERC20Allowed(
            0x0fF9072a1EAD154d92C2d2Fef16AFba6028Ce2B2,
            true,
            Lane(2),
            15_741_661_465_311_901_654_760,
            94_615_650_447_814_429_969_230,
            473_078_252_239_072_149_846_151
        );
        r.setERC20Allowed(
            0x39dBED3a2bd333467115dE45665cC57F813C4571,
            true,
            Lane(2),
            200_000_000_000_000_000_000,
            10_000_000_000_000_000_000_000,
            50_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0xab093dEF657F15dF31b33922A95e047aDd645B29,
            true,
            Lane(2),
            5_000_000_000_000_000_000_000,
            25_000_000_000_000_000_000_000,
            125_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0xF6589F11Bc40b669e584073F428B05562F568733,
            true,
            Lane(0),
            18_522_671_862_958_979_683,
            200_000_000_000_000_000_000,
            1_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0xbe98b75361935b18d688409424a869a4C3dC7401,
            true,
            Lane(2),
            6_572_421_705_573_701_134_530,
            20_000_000_000_000_000_000_000,
            100_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0x45242320DBB855EeA8Fd36804C6487E10E97FCF9,
            true,
            Lane(2),
            7_000_000_000_000_000_000_000,
            148_000_000_000_000_000_000_000,
            740_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0x020bfC650A365f8BB26819deAAbF3E21291018b4,
            true,
            Lane(2),
            1_000_000_000_000_000_000_000,
            30_000_000_000_000_000_000_000,
            150_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0x385F4f8ae47651ce5F58F5265395a669f8281e18,
            true,
            Lane(2),
            1_000_000_000_000_000_000_000,
            50_000_000_000_000_000_000_000,
            250_000_000_000_000_000_000_000
        );
        r.setERC20Allowed(
            0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c,
            true,
            Lane(2),
            5_000_000_000_000_000_000_000,
            100_000_000_000_000_000_000_000,
            500_000_000_000_000_000_000_000
        );
        r.setPoolAllowed(0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27, true, 1);
        r.setPoolRemovalHook(
            0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0xcbdfea90430a30ee4469c9902e120a77e7c7e4711d5643671c1d1957f2f1ce27, false);
        r.setPoolAllowed(0x9c89b04303dfa76f3f6fb02c2b77be0e8a00ab8fa00d507119acd54ab3e8640d, true, 1);
        r.setPoolRemovalHook(
            0x9c89b04303dfa76f3f6fb02c2b77be0e8a00ab8fa00d507119acd54ab3e8640d,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0x9c89b04303dfa76f3f6fb02c2b77be0e8a00ab8fa00d507119acd54ab3e8640d, false);
        r.setPoolAllowed(0xc3cc877a8a7d28efdb5dbec9ae71724652431e6411aa1a9fc8928028da554aa1, true, 1);
        r.setPoolRemovalHook(
            0xc3cc877a8a7d28efdb5dbec9ae71724652431e6411aa1a9fc8928028da554aa1,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0xc3cc877a8a7d28efdb5dbec9ae71724652431e6411aa1a9fc8928028da554aa1, false);
        r.setPoolAllowed(0x225cc98f7d66b29fef96377becc7bf89582e2ab7b923a09aee9719fd80eb94ca, true, 1);
        r.setPoolRemovalHook(
            0x225cc98f7d66b29fef96377becc7bf89582e2ab7b923a09aee9719fd80eb94ca,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0x225cc98f7d66b29fef96377becc7bf89582e2ab7b923a09aee9719fd80eb94ca, false);
        r.setPoolAllowed(0xc39187cec78a076c41a4085598b4cc05be2ed9b04a3443167471fa0fc4984188, true, 1);
        r.setPoolRemovalHook(
            0xc39187cec78a076c41a4085598b4cc05be2ed9b04a3443167471fa0fc4984188,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0xc39187cec78a076c41a4085598b4cc05be2ed9b04a3443167471fa0fc4984188, false);
        r.setPoolAllowed(0xf224a070c8626c890a085b258cf562ee4bf052b6d1d59104b3b44d722640c001, true, 1);
        r.setPoolInRangeRequired(0xf224a070c8626c890a085b258cf562ee4bf052b6d1d59104b3b44d722640c001, false);
        r.setPoolAllowed(0x141be60316aeb3aa7c0e0d8e4fbdc0aa78105e6e462cfc03b8a0f0c59f0bf3f8, true, 1);
        r.setPoolRemovalHook(
            0x141be60316aeb3aa7c0e0d8e4fbdc0aa78105e6e462cfc03b8a0f0c59f0bf3f8,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0x141be60316aeb3aa7c0e0d8e4fbdc0aa78105e6e462cfc03b8a0f0c59f0bf3f8, false);
        r.setPoolAllowed(0x1fb9a45079b017a6661016ba7dea29e1c4864b0874c21f63e137a52e71c3395b, true, 1);
        r.setPoolRemovalHook(
            0x1fb9a45079b017a6661016ba7dea29e1c4864b0874c21f63e137a52e71c3395b,
            0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544,
            0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631
        );
        r.setPoolInRangeRequired(0x1fb9a45079b017a6661016ba7dea29e1c4864b0874c21f63e137a52e71c3395b, false);
        r.setPoolAllowed(0xbacecf788d2279f65da62d7bf69f4de28580a88bec56847c8d2ba6fbdd73f6eb, true, 1);
        r.setPoolInRangeRequired(0xbacecf788d2279f65da62d7bf69f4de28580a88bec56847c8d2ba6fbdd73f6eb, false);
        r.setPoolAllowed(0x4be9657ec9002e528f4f17a5c43edc525a07f888f7b180c2afbf75e096c4f38a, true, 1);
        r.setPoolInRangeRequired(0x4be9657ec9002e528f4f17a5c43edc525a07f888f7b180c2afbf75e096c4f38a, true);
        r.setPoolAllowed(0xa92a3df27a00a276183ff7265fd8affa11df1fe8bb23ddfaf13f6c879a3f818b, true, 1);
        r.setPoolInRangeRequired(0xa92a3df27a00a276183ff7265fd8affa11df1fe8bb23ddfaf13f6c879a3f818b, true);
        r.setPoolAllowed(0x4b7c86491df95f366b31217b2950d2c5136a2f19b6879613eac73d0e69092a1a, true, 1);
        r.setPoolInRangeRequired(0x4b7c86491df95f366b31217b2950d2c5136a2f19b6879613eac73d0e69092a1a, true);
        r.setV3PoolAllowed(0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA, true, 2, type(uint128).max, type(uint128).max);
        r.setPoolInRangeRequired(0x00000000000000000000000010cc6bd38112cac182db90b6a71d8bb5939526ba, true);
    }

    function tokens() internal pure returns (address[] memory result) {
        result = new address[](30);
        result[0] = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        result[1] = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
        result[2] = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
        result[3] = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
        result[4] = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
        result[5] = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
        result[6] = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
        result[7] = 0x1D11f0496982706C5e14A514D4E79F2e6BdE4516;
        result[8] = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
        result[9] = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
        result[10] = 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD;
        result[11] = 0xCceE82fE024c36fA15E1005edE3E9e4787e23D09;
        result[12] = 0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18;
        result[13] = 0x98096d17e191B3dA1d5f99a6D7b3584351b11E18;
        result[14] = 0xD9dB30BB0D2b8d2eae3826A1372117E058791e18;
        result[15] = 0xFe7E19CbCe2f896C6C528BC355bAF5a768291E18;
        result[16] = 0x5d6EF090a1461B11c9427aC319260122D1C61e18;
        result[17] = 0x6b1d42927B1a84eC28Fa88d4fC6FA7AF404966be;
        result[18] = 0xa9eFe2Fc94dE79734C03051515F48f254Ce61e18;
        result[19] = 0xA3b6AEe90017b72c0812dC1e013De70eB2917ba3;
        result[20] = 0x451b42A15100C340CA12F7c66DE06fac5EA2D751;
        result[21] = 0x0fF9072a1EAD154d92C2d2Fef16AFba6028Ce2B2;
        result[22] = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
        result[23] = 0xab093dEF657F15dF31b33922A95e047aDd645B29;
        result[24] = 0xF6589F11Bc40b669e584073F428B05562F568733;
        result[25] = 0xbe98b75361935b18d688409424a869a4C3dC7401;
        result[26] = 0x45242320DBB855EeA8Fd36804C6487E10E97FCF9;
        result[27] = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
        result[28] = 0x385F4f8ae47651ce5F58F5265395a669f8281e18;
        result[29] = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    }

    function v4Keys() internal pure returns (PoolKey[] memory result) {
        result = new PoolKey[](12);
        result[0] = PoolKey(
            Currency.wrap(0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18),
            Currency.wrap(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
            8_388_608,
            8,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[1] = PoolKey(
            Currency.wrap(0x98096d17e191B3dA1d5f99a6D7b3584351b11E18),
            Currency.wrap(0xCceE82fE024c36fA15E1005edE3E9e4787e23D09),
            8_388_608,
            8,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[2] = PoolKey(
            Currency.wrap(0xD9dB30BB0D2b8d2eae3826A1372117E058791e18),
            Currency.wrap(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD),
            8_388_608,
            8,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[3] = PoolKey(
            Currency.wrap(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa),
            Currency.wrap(0xFe7E19CbCe2f896C6C528BC355bAF5a768291E18),
            8_388_608,
            8,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[4] = PoolKey(
            Currency.wrap(0x5d6EF090a1461B11c9427aC319260122D1C61e18),
            Currency.wrap(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9),
            8_388_608,
            8,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[5] = PoolKey(
            Currency.wrap(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C),
            Currency.wrap(0x6b1d42927B1a84eC28Fa88d4fC6FA7AF404966be),
            10_000,
            200,
            IHooks(0x16D1560630Ce74af4478d9b8AD46548A092A2000)
        );
        result[6] = PoolKey(
            Currency.wrap(0x322F0929c4625eD5bAd873c95208D54E1c003b2d),
            Currency.wrap(0xa9eFe2Fc94dE79734C03051515F48f254Ce61e18),
            8_388_608,
            8,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[7] = PoolKey(
            Currency.wrap(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C),
            Currency.wrap(0xA3b6AEe90017b72c0812dC1e013De70eB2917ba3),
            8_388_608,
            200,
            IHooks(0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544)
        );
        result[8] = PoolKey(
            Currency.wrap(0xab093dEF657F15dF31b33922A95e047aDd645B29),
            Currency.wrap(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD),
            0,
            200,
            IHooks(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044)
        );
        result[9] = PoolKey(
            Currency.wrap(0x39dBED3a2bd333467115dE45665cC57F813C4571),
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            3000,
            60,
            IHooks(0x0000000000000000000000000000000000000000)
        );
        result[10] = PoolKey(
            Currency.wrap(0x020bfC650A365f8BB26819deAAbF3E21291018b4),
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            2690,
            54,
            IHooks(0x0000000000000000000000000000000000000000)
        );
        result[11] = PoolKey(
            Currency.wrap(0x385F4f8ae47651ce5F58F5265395a669f8281e18),
            Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            6999,
            70,
            IHooks(0x0000000000000000000000000000000000000000)
        );
    }
}
