# gage contracts

Deployed on Robinhood Chain mainnet (chain ID 4663).

The smart contracts of [gage](https://gage.cash), release **intent-v1-r13-20261103** (Intent V1, r13): fixed-cost, peer-to-peer lending on Robinhood Chain. No liquidation: a loan's collateral is never sold because its price moves. The borrower repays by the end of the term, or the lender keeps the collateral.

This repository is generated from gage's private source at each release. It holds the deployed contracts and the files they import, nothing else. **Pull requests are not merged here: open an issue instead** ([CONTRIBUTING.md](CONTRIBUTING.md)). Report a vulnerability privately through [SECURITY.md](SECURITY.md). List a token through [LISTING.md](LISTING.md). Integrate through [PARTNERS.md](PARTNERS.md).

## Layout

| Path | What | Licence |
| --- | --- | --- |
| `src/` | The contracts this release deployed, and every source file they import | BUSL-1.1 ([LICENSE](LICENSE)); `src/interfaces/` MIT |
| `interfaces/` | What partners call: a partner vault (ERC-4626), the Intent factory, the factory registry, the rehypo source | MIT ([LICENSE-MIT](LICENSE-MIT)) |
| `integrations/lender-amm/` | The lender-AMM reference kit: a Uniswap v4 hook that lends a pool's idle liquidity through gage vaults, its keeper, and the rehypo plug example (`test/RehypoSourcePlug.t.sol`, `script/RehypoSource.s.sol`) | MIT |
| `deployments/4663.json` | Each deployed contract: source, address, ABI file, source-match record | |
| `deployments/manifest/4663.json` | The addresses of gage's public deployment manifest, at their keys | |
| `abi/` | One ABI per deployed contract | |
| `docs/` | Partner guides | |
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

| Contract | Source | Address |
| --- | --- | --- |
| GageV2TokenRegistry | `src/v2/GageV2TokenRegistry.sol` | `0x732fb25c6905d0cbeb639f1226398ab317189ba0` |
| GageLegacyAdapter | `src/v2/GageLegacyAdapter.sol` | `0x6c9661b2d0c2fab991097f4c3332f61d28b71891` |
| GageLegacyParty | `src/v2/GageLegacyParty.sol` | `0x7e1e8cb3c19b4f0f91e353e3c76d55a61ac79893` |
| GageV2Vault | `src/v2/GageV2Vault.sol` | `0x0086ec1540719d4199432797e2b6068e6ae5a0e5` |
| GageV2Rewards | `src/v2/GageV2Rewards.sol` | `0x614e087972d49dfe6fedbac1333192313af36ad9` |
| GageV2TokenCollateralAccount | `src/v2/GageV2TokenCollateralAccount.sol` | `0x7fc263591f3ff2412b99ed7365e502b7c86350c8` |
| GageV2CashoutRouter | `src/v2/GageV2CashoutRouter.sol` | `0xfa91ee9221300e034916400da4c4fc556633ae15` |
| MorphoV2ReserveLens | `src/intent/MorphoV2ReserveLens.sol` | `0x6a702eaea4f3b45ab352c4f3d5bf721bd0110ced` |
| IntentFactory | `src/intent/IntentFactory.sol` | `0xb086944b140758b33694220d4fe93c9a8d8618a1` |
| IntentVaultViews | `src/intent/IntentVaultViews.sol` | `0x3c2b782ffd62034c4f02346fedcbd1f567ede4ab` |
| IntentQuoteVerifier | `src/intent/IntentQuoteVerifier.sol` | `0x6a42924c195c6a38427320c1b49130998a7e75e1` |
| IntentFillRouter | `src/intent/IntentFillRouter.sol` | `0xae9607acb7e14bd37cb714cff8f35b30443133c8` |
| IntentExitDesk | `src/intent/IntentExitDesk.sol` | `0x0c7e23f245377551a7fac3b3d05238ac2e9eefc2` |
| LoopRouter | `src/loop/LoopRouter.sol` | `0xa46b62d5277465a885de5f2dc518d369199aa93c` |
| PrivateBorrowRouter | `src/private/PrivateBorrowRouter.sol` | `0xdbb8e949659d0d0d2edb075b9ec84c9e479baa45` |
| IntentVault | `src/intent/IntentVault.sol` | created by the factory; creation code at `0xdddaa2b15647a4d3b127afe40e0d272b4269391b`, `0xea1c433f6d303cc27d59c3257c56d58ddff413f7` |

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

- `src/`, except `src/interfaces/`: Business Source License 1.1 ([LICENSE](LICENSE)). It becomes MIT on 2027-11-04.
- `src/interfaces/`, `interfaces/`, `integrations/` and `script/`: MIT ([LICENSE-MIT](LICENSE-MIT)).
- Dependencies under `lib/` keep their own licences.

Each file's SPDX line names its licence.

Source commit: `f19f3be0a21d4a6159a78a2ef81a53c9c840c3bb`.
