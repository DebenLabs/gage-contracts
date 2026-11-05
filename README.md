# gage contracts

Deployed on Robinhood Chain mainnet (chain ID 4663).

The smart contracts of [gage](https://gage.cash), release **mainnet-20261105** (Intent V1 (r13) with its lend-asset generations, the GenerationDeployer, the LP lane, rollover and puts): fixed-cost, peer-to-peer lending on Robinhood Chain. No liquidation: a loan's collateral is never sold because its price moves. The borrower repays by the end of the term, or the lender keeps the collateral.

This repository is generated from gage's private source at each release. It holds the deployed contracts, the files they import, and guides with worked examples for building on them. **Start with [docs/integrate](docs/integrate/README.md).** **Pull requests are not merged here: open an issue instead** ([CONTRIBUTING.md](CONTRIBUTING.md)). Report a vulnerability privately through [SECURITY.md](SECURITY.md). List a token through [LISTING.md](LISTING.md). Integrate through [PARTNERS.md](PARTNERS.md).

## Layout

| Path | What | Licence |
| --- | --- | --- |
| `src/` | The contracts this release deployed, and every source file they import | BUSL-1.1 ([LICENSE](LICENSE)); `src/interfaces/` MIT |
| `interfaces/` | What partners call: a partner vault (ERC-4626), the Intent factory, the factory registry, the rehypo source | MIT ([LICENSE-MIT](LICENSE-MIT)) |
| `integrations/lender-amm/` | The lender-AMM reference kit: a Uniswap v4 hook that lends a pool's idle liquidity through gage vaults, its keeper, and the rehypo plug example (`test/RehypoSourcePlug.t.sol`, `script/RehypoSource.s.sol`) | MIT |
| `deployments/4663.json` | Each deployed contract: source, address, ABI file, source-match record | |
| `deployments/manifest/4663.json` | The addresses of gage's public deployment manifest, at their keys | |
| `abi/` | One ABI per deployed contract | |
| `docs/integrate/` | Integration guides: reading markets and loans, borrowing, partner vaults, fills, rollover, puts, the exit desk, the LP lane, generations, rewards, DEX partners | |
| `docs/` | Partner guides: the rehypo source, the lender-AMM kit | |
| `examples/` | Worked examples against mainnet: Foundry fork tests (`examples/foundry`) and viem scripts (`examples/viem`) | MIT |
| `audits/` | Security reviews | |
| `script/reproduce.mjs` | Builds `src/` and compares the bytecode with the deployed contracts | MIT |

## Build and reproduce

Foundry, with the dependencies pinned as submodules:

```bash
git clone --recursive https://github.com/DebenLabs/gage-contracts
```

```bash
forge build
```

`foundry.toml` carries the compiler settings each contract was deployed with: solc 0.8.28, EVM cancun, the optimizer runs and IR pipeline of its path, and no CBOR metadata. So `forge build` produces the deployed creation and runtime bytecode. To check every deployed contract against Sourcify's verified build:

```bash
node script/reproduce.mjs --tree . --sourcify 4663 --rpc https://rpc.mainnet.chain.robinhood.com
```

CI runs the same check on every push (`.github/workflows/reproduce.yml`).

## Contracts

Every deployed contract of this release, by generation. `deployments/4663.json` lists the same with each ABI file; `deployments/manifest/4663.json` names the entry points at their manifest keys, which the guides use.

### USDG generation (Intent V1, r13)

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| GageV2TokenRegistry | USDG registry | `src/v2/GageV2TokenRegistry.sol` | `0x732fB25C6905d0cbeB639F1226398aB317189bA0` |
| GageLegacyAdapter | USDG core's adapter | `src/v2/GageLegacyAdapter.sol` | `0x6c9661b2D0C2FAB991097f4c3332F61D28b71891` |
| GageLegacyParty | USDG core's adapter, created by GageLegacyAdapter | `src/v2/GageLegacyParty.sol` | `0x7E1e8CB3c19b4F0F91e353E3c76D55A61aC79893` |
| GageV2Vault | USDG core | `src/v2/GageV2Vault.sol` | `0x0086EC1540719d4199432797e2b6068E6aE5a0e5` |
| GageV2Rewards | USDG core, created by GageV2Vault | `src/v2/GageV2Rewards.sol` | `0x614E087972d49DFe6FEDbaC1333192313aF36aD9` |
| GageV2TokenCollateralAccount | USDG core, created by GageV2Vault | `src/v2/GageV2TokenCollateralAccount.sol` | `0x7FC263591f3FF2412B99ed7365E502b7C86350C8` |
| GageV2CashoutRouter | USDG cash-out router | `src/v2/GageV2CashoutRouter.sol` | `0xFA91Ee9221300E034916400DA4c4Fc556633aE15` |
| MorphoV2ReserveLens | USDG reserve lens | `src/intent/MorphoV2ReserveLens.sol` | `0x6a702eAEA4f3b45aB352c4F3d5bf721bd0110ceD` |
| GradeRegistry | USDG grade registry, kept from the previous generation | `src/earn/GradeRegistry.sol` | `0x897B15EA30923f9AdbEa4637AAee98722480Cb3d` |
| IntentFactory | USDG factory | `src/intent/IntentFactory.sol` | `0xB086944b140758b33694220d4Fe93C9A8D8618a1` |
| IntentVaultViews | USDG factory, created by IntentFactory | `src/intent/IntentVaultViews.sol` | `0x3c2b782ffd62034C4F02346fEdcBd1f567eDE4aB` |
| IntentQuoteVerifier | USDG quote verifier | `src/intent/IntentQuoteVerifier.sol` | `0x6a42924C195C6a38427320C1b49130998a7E75E1` |
| IntentFillRouter | USDG fill router | `src/intent/IntentFillRouter.sol` | `0xAE9607acb7e14bD37cB714cFf8f35B30443133c8` |
| IntentExitDesk | exit desk, shared by every generation | `src/intent/IntentExitDesk.sol` | `0x0c7e23f245377551A7fac3b3D05238Ac2E9Eefc2` |
| LoopRouter | USDG loop router | `src/loop/LoopRouter.sol` | `0xa46B62d5277465A885De5f2dc518d369199AA93c` |
| PrivateBorrowRouter | USDG private borrow router | `src/private/PrivateBorrowRouter.sol` | `0xDbb8e949659D0d0d2EDB075b9eC84C9E479bAA45` |
| NuntiusPriceSource | USDG one-day settlement | `src/oneday/NuntiusPriceSource.sol` | `0xbF042AE7216Ed5176790e19F463DbAB878f5caE8` |
| IntentVault | creation code, as data | `src/intent/IntentVault.sol` | `0xDDDAa2b15647A4d3B127aFe40e0d272b4269391B`, `0xEA1C433f6d303Cc27D59c3257C56d58ddFf413F7` |

### NVDA generation

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| IntentAssetFeeProcessor | NVDA fee processor | `src/intent/IntentAssetFeeProcessor.sol` | `0x5eF8697a5fD43d4c593c6E087d0F2a2B8ff2E584` |
| IntentClosedReserve | NVDA reserve | `src/intent/IntentClosedReserve.sol` | `0xB384a8419931703f651d87A02856ced67141139f` |
| GageV2TokenRegistry | NVDA registry | `src/v2/GageV2TokenRegistry.sol` | `0x1897cb1bfC61507259073086810F94BCFb609955` |
| GageV2Vault | NVDA core | `src/v2/GageV2Vault.sol` | `0xe0dDd6869677d3F5A2BC48375FC899B10A6848E1` |
| GageV2Rewards | NVDA core, created by GageV2Vault | `src/v2/GageV2Rewards.sol` | `0x25c3976ca28D2B9265050D290a58dF46864A2D5d` |
| GageV2TokenCollateralAccount | NVDA core, created by GageV2Vault | `src/v2/GageV2TokenCollateralAccount.sol` | `0xb3c7f3EFE112145ad338448F6c4AF4492f9Af233` |
| GageV2CashoutRouter | NVDA cash-out router | `src/v2/GageV2CashoutRouter.sol` | `0xF30ad2ED957e74d36774168c63DfC43C8B025e91` |
| GradeRegistry | NVDA grade registry | `src/earn/GradeRegistry.sol` | `0xCA7e4819383f1842f42E64d7E12E066551Ac4757` |
| IntentFactory | NVDA factory | `src/intent/IntentFactory.sol` | `0xd1Fc8951289372C7260Ac0F7BC830bAbA49F109c` |
| IntentVaultViews | NVDA factory, created by IntentFactory | `src/intent/IntentVaultViews.sol` | `0x5abF84c75cBDDcBc396045E4a683C544809De2BA` |
| IntentQuoteVerifier | NVDA quote verifier | `src/intent/IntentQuoteVerifier.sol` | `0xDF320f2FD7D6075571E0f083ff04571D9ACdeb46` |
| IntentFillRouter | NVDA fill router | `src/intent/IntentFillRouter.sol` | `0x9c748Ebd8f7691E1aC9E670E0dE96920791D9932` |
| LendRewardsBridge | NVDA | `src/intent/LendRewardsBridge.sol` | `0x020B2F852ae8b0Fa83D0C3F0924A63D65EF899D3` |
| LendRewardsLender | NVDA rewards bridge, created by LendRewardsBridge | `src/intent/LendRewardsLender.sol` | `0xf4c708Dc58F14a8BC914b4cB64cDc92da7cF7600` |
| IntentVault | creation code, as data | `src/intent/IntentVault.sol` | `0x9F29354b58799931025613519838f66b3773Bb7F`, `0xCe0CaB5A09C7FB888bb38A2194Dcf81E633f1cdD` |

### HIMS generation

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| IntentAssetFeeProcessor | HIMS fee processor | `src/intent/IntentAssetFeeProcessor.sol` | `0x53f952a05Ac750aca7591DBa2D386762EfBA637A` |
| IntentClosedReserve | HIMS reserve | `src/intent/IntentClosedReserve.sol` | `0x2677299Eaa9Dc7B0dd2Aac972C63B20ffe2C87D8` |
| GageV2TokenRegistry | HIMS registry | `src/v2/GageV2TokenRegistry.sol` | `0xA077B4D108544EFe90e9d6D1348C3E6c3E071BB1` |
| GageV2Vault | HIMS core | `src/v2/GageV2Vault.sol` | `0xc64C71f1A989E1830948D1ADCB43a2b5f5a8DbA1` |
| GageV2Rewards | HIMS core, created by GageV2Vault | `src/v2/GageV2Rewards.sol` | `0x4BEa4A533Ef7463fc67565b9Ac96F7eE1AF93AE2` |
| GageV2TokenCollateralAccount | HIMS core, created by GageV2Vault | `src/v2/GageV2TokenCollateralAccount.sol` | `0x10CDfD654220b008c45A44F89c20FD502e3Bbc5A` |
| GageV2CashoutRouter | HIMS cash-out router | `src/v2/GageV2CashoutRouter.sol` | `0xf092DA59586b0bBDF9eb9B9C68234887C83eD473` |
| GradeRegistry | HIMS grade registry | `src/earn/GradeRegistry.sol` | `0x37Ce0efc2013a5054BE561B9cEeb1D25C4574Ea1` |
| IntentFactory | HIMS factory | `src/intent/IntentFactory.sol` | `0x76030f3fd8631a2839D79fEfBf5EFf124229734a` |
| IntentVaultViews | HIMS factory, created by IntentFactory | `src/intent/IntentVaultViews.sol` | `0x0F57f212F92f5514216e12080489D0D1a5C1B344` |
| IntentQuoteVerifier | HIMS quote verifier | `src/intent/IntentQuoteVerifier.sol` | `0x6260cd08D8aE6d635b58966Ac3B2EcfA3e4dC2A7` |
| IntentFillRouter | HIMS fill router | `src/intent/IntentFillRouter.sol` | `0x3C472D54D5c51cFFa682e85A86F7562fF368e53D` |
| LendRewardsBridge | HIMS | `src/intent/LendRewardsBridge.sol` | `0x1cF5Eb476D5200ceF62c7FBBDf872b31AE3A2E82` |
| LendRewardsLender | HIMS rewards bridge, created by LendRewardsBridge | `src/intent/LendRewardsLender.sol` | `0x25E4739beAD723CB500f7E438C245ab4f6Acc9c9` |
| IntentVault | creation code, as data | `src/intent/IntentVault.sol` | `0xc95FeD047646F9766e1c4D08DE24c9e413453A35`, `0x29e59A3e3B420d457BB291888B1E27dAc0AebB42` |

### GLD generation

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| IntentAssetFeeProcessor | GLD fee processor | `src/intent/IntentAssetFeeProcessor.sol` | `0xcAB24b35F7A3B4FcC958ac56422F0D86A77C84f2` |
| IntentClosedReserve | GLD reserve | `src/intent/IntentClosedReserve.sol` | `0x799BB6b361E1e310D4bC9e31901E5B89Ec3153b2` |
| GageV2TokenRegistry | GLD registry | `src/v2/GageV2TokenRegistry.sol` | `0x79e64d21F0514BC5aaAFc332D1A1096F0368Ae4c` |
| GageV2Vault | GLD core | `src/v2/GageV2Vault.sol` | `0x1E8bd7348C84Ab0A0faBE61DCA1249f75B4e9275` |
| GageV2Rewards | GLD core, created by GageV2Vault | `src/v2/GageV2Rewards.sol` | `0xa83939Ff28EcdB75D96C653717CF07a638ecA4Af` |
| GageV2TokenCollateralAccount | GLD core, created by GageV2Vault | `src/v2/GageV2TokenCollateralAccount.sol` | `0x0fbaC3e2d16b5CF5865fB77B04D83A1aae5b8660` |
| GageV2CashoutRouter | GLD cash-out router | `src/v2/GageV2CashoutRouter.sol` | `0x2d89e340e2ef83729fb6Dc9da61E425fa0e46D70` |
| GradeRegistry | GLD grade registry | `src/earn/GradeRegistry.sol` | `0xf15D75520bcebd6a1A9ffcdcFDcABa6F9474c0B3` |
| IntentFactory | GLD factory | `src/intent/IntentFactory.sol` | `0x2a09498f11A70c4F2AB0a4e1B3323699bF7cC143` |
| IntentVaultViews | GLD factory, created by IntentFactory | `src/intent/IntentVaultViews.sol` | `0x25E5ef391E6d50DECa1D795593dbb90Ab0043cC6` |
| IntentQuoteVerifier | GLD quote verifier | `src/intent/IntentQuoteVerifier.sol` | `0x619781E2aF98973FE8200E70fd77bdd782dfc673` |
| IntentFillRouter | GLD fill router | `src/intent/IntentFillRouter.sol` | `0x6E07B640af910B8eF1c7E2e6B24a417558061F53` |
| LendRewardsBridge | GLD | `src/intent/LendRewardsBridge.sol` | `0x7888fB3330141c1fD9682C753f88F280B41FA458` |
| LendRewardsLender | GLD rewards bridge, created by LendRewardsBridge | `src/intent/LendRewardsLender.sol` | `0xfdAC7EAb0504A24FC5439EBF47d97C08f151F1e9` |
| IntentVault | creation code, as data | `src/intent/IntentVault.sol` | `0x7FC81cc8665664132EdBA623830576b0E0355Db5`, `0xf45e730a058f484dc17Cb9d2692265bA439343cA` |

### frxUSD generation (built by the GenerationDeployer)

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| IntentFactory | frxUSD factory | `src/intent/IntentFactory.sol` | `0xb8aa2f7e1448220D8503262ACED7ecF94231828A` |
| IntentVaultViews | frxUSD factory, created by IntentFactory | `src/intent/IntentVaultViews.sol` | `0x916465ff07248eC162985f80c0F46daef4A3948d` |
| GageV2Vault | frxUSD core | `src/v2/GageV2Vault.sol` | `0x7511F3a302481eEa40982510f2B23D8fCA8C24BA` |
| GageV2Rewards | frxUSD core, created by GageV2Vault | `src/v2/GageV2Rewards.sol` | `0xFcb084a63ffe04Bb757fdffa9841132abFBB4F83` |
| GageV2TokenCollateralAccount | frxUSD core, created by GageV2Vault | `src/v2/GageV2TokenCollateralAccount.sol` | `0x16b992c007ceE8c4041fe395b14940B3d87B52D7` |
| GageV2TokenRegistry | frxUSD registry | `src/v2/GageV2TokenRegistry.sol` | `0x6337D154b172BAEaA8c85C20444BCD2F4f91716E` |
| IntentClosedReserve | frxUSD reserve | `src/intent/IntentClosedReserve.sol` | `0x6dc768b5b59929308De13795a10A2432e61CcEB8` |
| IntentAssetV4FeeProcessor | frxUSD fee processor | `src/intent/IntentAssetV4FeeProcessor.sol` | `0x426137090eA84C24E2093fB3cF1c4c0AdBa32d00` |
| IntentQuoteVerifier | frxUSD quote verifier | `src/intent/IntentQuoteVerifier.sol` | `0xa1003C2A15202bdE3f099DDf5B167cbd773C10d1` |
| IntentFillRouter | frxUSD fill router | `src/intent/IntentFillRouter.sol` | `0x44Efb32BeC421dc8D47d38007702D527a0FF6975` |
| GradeRegistry | frxUSD grade registry | `src/earn/GradeRegistry.sol` | `0x8d5a12ff8865bA3652A5FD53d08Bd1ef6ad7F619` |
| V4CashoutRouter | frxUSD cash-out router | `src/intent/V4CashoutRouter.sol` | `0xB7d2861e0269941e552E1eBa1cA195044516Cf2e` |
| RolloverRouter | frxUSD rollover router | `src/rollover/RolloverRouter.sol` | `0x31060bF34E8755750bb52Ae91c44AD8a70e41E15` |
| IntentVault | creation code, as data | `src/intent/IntentVault.sol` | `0x8dfA2B25D4A888996b3864B2180B99Db0803c45C`, `0xCf97c3aFeBCAE318cEe116f533256c8340C94F30` |

### GenerationDeployer

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| GenerationDeployer |  | `src/intent/GenerationDeployer.sol` | `0xcea38204C97e9745f831978357d562E5CcC6834F` |
| IntentAssetV4FeeProcessor | creation code, as data | `src/intent/IntentAssetV4FeeProcessor.sol` | `0xCb5bB9AA4bf13939F60bb056C2eEb44beE315c2A` |
| IntentClosedReserve | creation code, as data | `src/intent/IntentClosedReserve.sol` | `0x18c0E3C902D015B0C8dd7970d0BE133d46A948e8` |
| GageV2TokenRegistry | creation code, as data | `src/v2/GageV2TokenRegistry.sol` | `0x48Cd041392B49b122CC476883C31742F243382D2` |
| GageV2Vault | creation code, as data | `src/v2/GageV2Vault.sol` | `0x4aCfea89cB7B8cA9B19691319EE6A29E75F4D90b`, `0xA7D042643C7F07ab2f615A75abF424d762D4102b` |
| V4CashoutRouter | creation code, as data | `src/intent/V4CashoutRouter.sol` | `0x5Af47072fDB602b8c19ceFddC5aBD06eEB26b0ed` |
| GradeRegistry | creation code, as data | `src/earn/GradeRegistry.sol` | `0xeB008aEeDcC36a053cfF542f41807dB8794125d1` |
| IntentFactory | creation code, as data | `src/intent/IntentFactory.sol` | `0x22491F2B7A7Cef8225bab8C155601AE636D07bAe` |
| IntentQuoteVerifier | creation code, as data | `src/intent/IntentQuoteVerifier.sol` | `0x26DFd543Ce94591f913D8E40050D8433Ec8734C8` |
| IntentFillRouter | creation code, as data | `src/intent/IntentFillRouter.sol` | `0x1A0DEF32C1C4729E693bD93966150e28f5cEc1fF` |
| RolloverRouter | creation code, as data | `src/rollover/RolloverRouter.sol` | `0xff1a29aB23ACcD76C5e747678b7cce6f42c48389` |
| IntentVault | creation code, as data | `src/intent/IntentVault.sol` | `0x8dfA2B25D4A888996b3864B2180B99Db0803c45C`, `0xCf97c3aFeBCAE318cEe116f533256c8340C94F30` |

### Rollover routers

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| RolloverRouter | USDG, intent-v1-r13-20261103 | `src/rollover/RolloverRouter.sol` | `0x3bee806F87386e71713516bA0b91dAE21D576f72` |
| RolloverRouter | NVDA, lend-nvda-r12-20261103 | `src/rollover/RolloverRouter.sol` | `0xB47D90C6af419353536E023Ae00D132c68226c40` |
| RolloverRouter | HIMS, lend-hims-r12-20261103 | `src/rollover/RolloverRouter.sol` | `0xa27F40174B6293252E0FDbCFf8c3B50868156EE0` |
| RolloverRouter | GLD, lend-gld-r13-20261103 | `src/rollover/RolloverRouter.sol` | `0xb078114872369a5f43E9b8548C501dbb88ef84ac` |

### NVDA puts

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| LoopRouter | NVDA puts, lend-nvda-r12-20261103 | `src/loop/LoopRouter.sol` | `0xe5A69a1DEd8437bbFDe19263B626aAE4Ec1f09cf` |
| PutRouter | NVDA puts, lend-nvda-r12-20261103 | `src/put/PutRouter.sol` | `0x93D6665D881a2DB7d054dBD271dF513dAa52ec99` |

### LP lane

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| LPRegistry | LP lane | `src/lp/LPRegistry.sol` | `0xdFCFe33eB08E63dD1f8B7cBCd49f5E960BC85bBC` |
| LPCore | LP lane | `src/lp/LPCore.sol` | `0x8EDedDadA6be6C81cD838a028910ADDA29365c50` |
| LPEscrow | LP lane, created by LPCore | `src/lp/LPEscrow.sol` | `0xe19aae63b2A235C807b89Ff32eF7508237B18b86` |
| UniV3PositionAdapter | LP lane, uniswap-v3 | `src/lp/adapters/UniV3PositionAdapter.sol` | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` |
| RamsesV3PositionAdapter | LP lane, ramses-v3 | `src/lp/adapters/RamsesV3PositionAdapter.sol` | `0xdc2001A57912164Ecb8139b7D3121955AE3A9320` |
| UniV3PositionAdapter | LP lane, sushiswap-v3 | `src/lp/adapters/UniV3PositionAdapter.sol` | `0xd9aF6b4BCf9eE6b0bF84279C8d1FD72071cdF2e8` |
| UniV4PositionAdapter | LP lane, uniswap-v4 | `src/lp/adapters/UniV4PositionAdapter.sol` | `0xc3dE275A11e0B3783770882F5c4E640eaE45833C` |
| FablesPositionWrapper | LP lane, fables | `src/lp/fables/FablesPositionWrapper.sol` | `0x1a8e8F0aab1C9e58827D86EbAE29Bc3e79CC1B2b` |
| FablesShareHolder | LP lane, fables, created by FablesPositionWrapper | `src/lp/fables/FablesShareHolder.sol` | `0xa62edA23A8877912fb938Ed1eBD1BCde4465cC68` |
| FablesPositionAdapter | LP lane, fables | `src/lp/adapters/FablesPositionAdapter.sol` | `0xbaFCd70B060ed26F5a2Cb67e43fe030Cf8981793` |
| LPVaultFactory | LP lane | `src/lp/LPVaultFactory.sol` | `0xDDd6afeA325F20Bba4Df0A5a7DB307524bbcbF77` |
| UniV3SwapExecutor | LP lane, sells 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 | `src/lp/executors/UniV3SwapExecutor.sol` | `0xd5309aB57BdfaEF1491dB0c91D5c4d1D4c8d814F` |
| UniV3TwoHopSwapExecutor | LP lane, sells 0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802 | `src/lp/executors/UniV3TwoHopSwapExecutor.sol` | `0x8Cd6E727C3679649bae14CE9d223E837B906852b` |
| UniV3SwapExecutor | LP lane, sells 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC | `src/lp/executors/UniV3SwapExecutor.sol` | `0x1035E23DF3ac7bf9693dbB5a9F3C0eFe2C2760ad` |
| UniV4SwapExecutor | LP lane, sells 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C | `src/lp/executors/UniV4SwapExecutor.sol` | `0xa26570618E08218BF3fFd5bB96382D72Eb2F2ECe` |
| UniV3SwapExecutor | LP lane, sells 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e | `src/lp/executors/UniV3SwapExecutor.sol` | `0xEC03f72f59e68b4757c6Ef17295Ae1c18dfD4A46` |
| LPVault | creation code, as data | `src/lp/LPVault.sol` | `0x23780D258feB6a72bc4cBb9aaC277d3e6d0b133c`, `0x362FB273f756fFf32230BDb2FD5A574F7013aBcc` |

### Fables gauge adapter

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| FablesGaugeAdapter | GAGE/sGAGE pool on the Fables gauges | `src/token/FablesGaugeAdapter.sol` | `0xeE83C8e5A453cE582C90F487F0E050B69425D291` |

### Rehypo source factory

| Contract | Role | Source | Address |
| --- | --- | --- | --- |
| GageRehypoSourceFactory |  | `src/rehypo/GageRehypoSourceFactory.sol` | `0xab0425C2f5D5bab9867b42EFE3c228BAD2239419` |
| GageRehypoSource | creation code, as data | `src/rehypo/GageRehypoSource.sol` | `0xc23ea8cE1e150289BdB28519e7D751038b6330a4` |

Contracts a factory creates (each partner vault, each loan's collateral account) are not listed. Read them from their factory: `IntentFactory.count()` and `vaults(i)`.

## Libraries

| Path | Repository | Commit |
| --- | --- | --- |
| `lib/forge-std` | foundry-rs/forge-std | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| `lib/v4-periphery` | uniswap/v4-periphery | `dce236d4e2057422d0791d9a973a58765eb46f65` |
| `integrations/lender-amm/lib/uniswap-hooks` | OpenZeppelin/uniswap-hooks | `b5f10574f943911635754dd76ed6ce95858b7d93` |

The lender-AMM kit also pins OpenZeppelin uniswap-hooks (`integrations/lender-amm/lib/uniswap-hooks`); see its README.

## Licences

- `src/`, except `src/interfaces/`: Business Source License 1.1 ([LICENSE](LICENSE)). It becomes MIT on 2027-11-05.
- `src/interfaces/`, `interfaces/`, `integrations/`, `examples/` and `script/`: MIT ([LICENSE-MIT](LICENSE-MIT)).
- Dependencies under `lib/` keep their own licences.

Each file's SPDX line names its licence.

Source commit: `d3aad8097d5c2837a2cbed0a8c97ecb87e9dc0ff`.
