# Addresses

The entry points of gage on Robinhood Chain mainnet (chain ID 4663), by generation. Every address on these pages comes from this release's records at export, so it matches the contracts in [`src/`](../../src). Read them in code from [`deployments/manifest/4663.json`](../../deployments/manifest/4663.json) at the key shown, never from a copy. [`deployments/4663.json`](../../deployments/4663.json) lists every deployed contract with its ABI.

A generation is one lend asset's set of contracts: its core holds the loans, its factory creates the partner vaults that fund them, and its routers move loans in and out. Loans are in the generation's asset: USDG, NVDA, HIMS, GLD or frxUSD.

## USDG generation (Intent V1)

| Role | Contract | Manifest key | Address |
| --- | --- | --- | --- |
| Core: the loans | GageV2Vault | `intentV1.core` | 0x0086EC1540719d4199432797e2b6068E6aE5a0e5 |
| Registry: collateral, terms, fee | GageV2TokenRegistry | | 0x732fB25C6905d0cbeB639F1226398aB317189bA0 |
| Rewards ledger | GageV2Rewards | | 0x614E087972d49DFe6FEDbaC1333192313aF36aD9 |
| Partner vault factory | IntentFactory | `intentV1.factory` | 0xB086944b140758b33694220d4Fe93C9A8D8618a1 |
| Vault reads | IntentVaultViews | | 0x3c2b782ffd62034C4F02346fEdcBd1f567eDE4aB |
| Quote verifier | IntentQuoteVerifier | `intentV1.quoteVerifier` | 0x6a42924C195C6a38427320C1b49130998a7E75E1 |
| Fill router | IntentFillRouter | `intentV1.fillRouter` | 0xAE9607acb7e14bD37cB714cFf8f35B30443133c8 |
| Cash-out router | GageV2CashoutRouter | | 0xFA91Ee9221300E034916400DA4c4Fc556633aE15 |
| Rollover router | RolloverRouter | `intentV1.rolloverRouter` | 0x3bee806F87386e71713516bA0b91dAE21D576f72 |
| Loop router (leverage) | LoopRouter | `intentV1.loopRouter` | 0xa46B62d5277465A885De5f2dc518d369199AA93c |
| Private borrow router | PrivateBorrowRouter | `intentV1.privateRouter` | 0xDbb8e949659D0d0d2EDB075b9eC84C9E479bAA45 |
| One-day settlement price | NuntiusPriceSource | `intentV1.oneDayPriceSource` | 0xbF042AE7216Ed5176790e19F463DbAB878f5caE8 |
| Reserve | ERC-4626 | `intentV1.reserve` | 0xBeEff033F34C046626B8D0A041844C5d1A5409dd |
| Exit desk (every generation) | IntentExitDesk | `intentV1.exitDesk` | 0x0c7e23f245377551A7fac3b3D05238Ac2E9Eefc2 |

## NVDA generation

| Role | Contract | Manifest key | Address |
| --- | --- | --- | --- |
| Core | GageV2Vault | `intentV1Assets.NVDA.core` | 0xe0dDd6869677d3F5A2BC48375FC899B10A6848E1 |
| Registry | GageV2TokenRegistry | `intentV1Assets.NVDA.engine.registry` | 0x1897cb1bfC61507259073086810F94BCFb609955 |
| Rewards ledger | GageV2Rewards | `intentV1Assets.NVDA.engine.rewards` | 0x25c3976ca28D2B9265050D290a58dF46864A2D5d |
| Partner vault factory | IntentFactory | `intentV1Assets.NVDA.factory` | 0xd1Fc8951289372C7260Ac0F7BC830bAbA49F109c |
| Quote verifier | IntentQuoteVerifier | `intentV1Assets.NVDA.quoteVerifier` | 0xDF320f2FD7D6075571E0f083ff04571D9ACdeb46 |
| Fill router | IntentFillRouter | `intentV1Assets.NVDA.fillRouter` | 0x9c748Ebd8f7691E1aC9E670E0dE96920791D9932 |
| Cash-out router | GageV2CashoutRouter | `intentV1Assets.NVDA.engine.cashoutRouter` | 0xF30ad2ED957e74d36774168c63DfC43C8B025e91 |
| Grade registry | GradeRegistry | `intentV1Assets.NVDA.gradeRegistry` | 0xCA7e4819383f1842f42E64d7E12E066551Ac4757 |
| Fee processor | IntentAssetFeeProcessor | `intentV1Assets.NVDA.feeProcessor` | 0x5eF8697a5fD43d4c593c6E087d0F2a2B8ff2E584 |
| Rollover router | RolloverRouter | `intentV1Assets.NVDA.rolloverRouter` | 0xB47D90C6af419353536E023Ae00D132c68226c40 |
| Loop router | LoopRouter | `intentV1Assets.NVDA.loopRouter` | 0xe5A69a1DEd8437bbFDe19263B626aAE4Ec1f09cf |
| Put router | PutRouter | `intentV1Assets.NVDA.putRouter` | 0x93D6665D881a2DB7d054dBD271dF513dAa52ec99 |
| Rewards bridge | LendRewardsBridge | | 0x020B2F852ae8b0Fa83D0C3F0924A63D65EF899D3 |

## HIMS generation

| Role | Contract | Manifest key | Address |
| --- | --- | --- | --- |
| Core | GageV2Vault | `intentV1Assets.HIMS.core` | 0xc64C71f1A989E1830948D1ADCB43a2b5f5a8DbA1 |
| Registry | GageV2TokenRegistry | `intentV1Assets.HIMS.engine.registry` | 0xA077B4D108544EFe90e9d6D1348C3E6c3E071BB1 |
| Rewards ledger | GageV2Rewards | `intentV1Assets.HIMS.engine.rewards` | 0x4BEa4A533Ef7463fc67565b9Ac96F7eE1AF93AE2 |
| Partner vault factory | IntentFactory | `intentV1Assets.HIMS.factory` | 0x76030f3fd8631a2839D79fEfBf5EFf124229734a |
| Quote verifier | IntentQuoteVerifier | `intentV1Assets.HIMS.quoteVerifier` | 0x6260cd08D8aE6d635b58966Ac3B2EcfA3e4dC2A7 |
| Fill router | IntentFillRouter | `intentV1Assets.HIMS.fillRouter` | 0x3C472D54D5c51cFFa682e85A86F7562fF368e53D |
| Cash-out router | GageV2CashoutRouter | `intentV1Assets.HIMS.engine.cashoutRouter` | 0xf092DA59586b0bBDF9eb9B9C68234887C83eD473 |
| Grade registry | GradeRegistry | `intentV1Assets.HIMS.gradeRegistry` | 0x37Ce0efc2013a5054BE561B9cEeb1D25C4574Ea1 |
| Fee processor | IntentAssetFeeProcessor | `intentV1Assets.HIMS.feeProcessor` | 0x53f952a05Ac750aca7591DBa2D386762EfBA637A |
| Rollover router | RolloverRouter | `intentV1Assets.HIMS.rolloverRouter` | 0xa27F40174B6293252E0FDbCFf8c3B50868156EE0 |
| Rewards bridge | LendRewardsBridge | | 0x1cF5Eb476D5200ceF62c7FBBDf872b31AE3A2E82 |

## GLD generation

| Role | Contract | Manifest key | Address |
| --- | --- | --- | --- |
| Core | GageV2Vault | `intentV1Assets.GLD.core` | 0x1E8bd7348C84Ab0A0faBE61DCA1249f75B4e9275 |
| Registry | GageV2TokenRegistry | `intentV1Assets.GLD.engine.registry` | 0x79e64d21F0514BC5aaAFc332D1A1096F0368Ae4c |
| Rewards ledger | GageV2Rewards | `intentV1Assets.GLD.engine.rewards` | 0xa83939Ff28EcdB75D96C653717CF07a638ecA4Af |
| Partner vault factory | IntentFactory | `intentV1Assets.GLD.factory` | 0x2a09498f11A70c4F2AB0a4e1B3323699bF7cC143 |
| Quote verifier | IntentQuoteVerifier | `intentV1Assets.GLD.quoteVerifier` | 0x619781E2aF98973FE8200E70fd77bdd782dfc673 |
| Fill router | IntentFillRouter | `intentV1Assets.GLD.fillRouter` | 0x6E07B640af910B8eF1c7E2e6B24a417558061F53 |
| Cash-out router | GageV2CashoutRouter | `intentV1Assets.GLD.engine.cashoutRouter` | 0x2d89e340e2ef83729fb6Dc9da61E425fa0e46D70 |
| Grade registry | GradeRegistry | `intentV1Assets.GLD.gradeRegistry` | 0xf15D75520bcebd6a1A9ffcdcFDcABa6F9474c0B3 |
| Fee processor | IntentAssetFeeProcessor | `intentV1Assets.GLD.feeProcessor` | 0xcAB24b35F7A3B4FcC958ac56422F0D86A77C84f2 |
| Rewards bridge | LendRewardsBridge | | 0x7888fB3330141c1fD9682C753f88F280B41FA458 |

## frxUSD generation

Built in one transaction by the GenerationDeployer ([generations.md](generations.md)).

| Role | Contract | Address |
| --- | --- | --- |
| Core | GageV2Vault | 0x7511F3a302481eEa40982510f2B23D8fCA8C24BA |
| Registry | GageV2TokenRegistry | 0x6337D154b172BAEaA8c85C20444BCD2F4f91716E |
| Rewards ledger | GageV2Rewards | 0xFcb084a63ffe04Bb757fdffa9841132abFBB4F83 |
| Partner vault factory | IntentFactory | 0xb8aa2f7e1448220D8503262ACED7ecF94231828A |
| Vault reads | IntentVaultViews | 0x916465ff07248eC162985f80c0F46daef4A3948d |
| Quote verifier | IntentQuoteVerifier | 0xa1003C2A15202bdE3f099DDf5B167cbd773C10d1 |
| Fill router | IntentFillRouter | 0x44Efb32BeC421dc8D47d38007702D527a0FF6975 |
| Cash-out router | V4CashoutRouter | 0xB7d2861e0269941e552E1eBa1cA195044516Cf2e |
| Grade registry | GradeRegistry | 0x8d5a12ff8865bA3652A5FD53d08Bd1ef6ad7F619 |
| Fee processor | IntentAssetV4FeeProcessor | 0x426137090eA84C24E2093fB3cF1c4c0AdBa32d00 |
| Reserve | IntentClosedReserve | 0x6dc768b5b59929308De13795a10A2432e61CcEB8 |
| Rollover router | RolloverRouter | 0x31060bF34E8755750bb52Ae91c44AD8a70e41E15 |

## Shared by every generation

| Role | Contract | Manifest key | Address |
| --- | --- | --- | --- |
| Generation deployer and factory registry | GenerationDeployer | `generationDeployer.address` | 0xcea38204C97e9745f831978357d562E5CcC6834F |
| Standing-roll executor (gage's keeper wallet) | | `rolloverExecutor` | 0xCB14554904b86b3472F960740aE377b5b711A659 |
| LP lane core | LPCore | `lpLane.core` | 0x8EDedDadA6be6C81cD838a028910ADDA29365c50 |
| LP lane registry | LPRegistry | `lpLane.registry` | 0xdFCFe33eB08E63dD1f8B7cBCd49f5E960BC85bBC |
| LP lane vault factory | LPVaultFactory | `lpLane.vaultFactory` | 0xDDd6afeA325F20Bba4Df0A5a7DB307524bbcbF77 |
| Rehypo source factory | GageRehypoSourceFactory | | 0xab0425C2f5D5bab9867b42EFE3c228BAD2239419 |
| Fables gauge adapter of the GAGE/sGAGE pool | FablesGaugeAdapter | `fablesGaugeAdapter` | 0xeE83C8e5A453cE582C90F487F0E050B69425D291 |
| USDG | ERC-20, 6 decimals | `USDG` | 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 |
| sGAGE | ERC-20 | `sGAGE` | 0x78c88CF8F6E612955526cEB501be82BF3279Bd5d |
| Drip | | `Drip` | 0x3f2b11467C0EAbdc7f0D5910193BA012BbCc08Ff |
| Uniswap v4 PoolManager | | `PoolManager` | 0x8366a39CC670B4001A1121B8F6A443A643e40951 |
| Permit2 | | `Permit2` | 0x000000000022D473030F116dDEE9F6B43aC78BA3 |

Earlier generations keep their own loans until they close; their contracts are in the manifest (`intentV1Previous`, `intentV1AssetsPrevious`, `nativeV2.engines`) and take no new loans.
