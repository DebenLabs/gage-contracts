# gage contracts

Smart contracts of [gage](https://gage.cash): cash against your stocks and memes. No liquidation. Fixed-cost, peer-to-peer deals on Robinhood Chain (chain id 4663).

> **No liquidation** means: nothing can touch your collateral before expiry; at expiry you choose.

A borrower pledges tokenised stocks, memes or other admitted tokens and borrows against them. The cost is fixed and the date is fixed. On the date the borrower either pays the cap and takes the collateral back, or walks away and the lenders keep it.

Documentation: [docs.gage.cash](https://docs.gage.cash) · [Contracts for developers](https://docs.gage.cash/developers/contracts) · [Security invariants](https://docs.gage.cash/protocol/invariants) · [Bug bounty](https://docs.gage.cash/protocol/bug-bounty)

## Layout

| Path | What it holds |
|---|---|
| `contracts/src/intent/` | Intent V1, live on mainnet since 15 October 2026: `IntentFactory` and the `IntentVault`, `IntentAssetPolicy` and `IntentLenderMarket` each factory creates; `IntentQuoteVerifier` and `IntentFillRouter` for quotes and fills; `IntentAssetFeeProcessor` and `IntentClosedReserve` for lend-asset generations; `MorphoV2ReserveLens` |
| `contracts/src/v2/` | The deal engine (`GageV2Vault`), its token registry, per-loan collateral accounts, rewards, cash-out router and the bridge to the first engine |
| `contracts/src/loop/` | `LoopRouter`, one-click leverage |
| `contracts/src/private/` | `PrivateBorrowRouter`, the private lane over 0xbow Privacy Pools |
| `contracts/src/token/` | The GAGE/sGAGE token layer: emissions, deal and LP rewards, drip, seed timelock, fee floor, reinvest router |
| `contracts/src/` (root), `earn/`, `libraries/`, `interfaces/`, `types/` | The launch contracts of 7 September 2026, earlier Earn designs and shared code |
| `contracts/src/testnet/` | Fixtures for Robinhood Chain testnet only; never deployed on mainnet |
| `contracts/test/` | Unit, fuzz, invariant and fork tests |
| `contracts/script/` | Deployment and end-to-end scripts |
| `docs/intent-v1/evidence/` | Test vectors the Intent tests read |

## Deployed contracts

Every contract below is verified on [Sourcify](https://sourcify.dev) with creation and runtime bytecode matches, so its deployed bytecode can be compared with this source. Any address can be checked at `https://repo.sourcify.dev/4663/<address>`. The full directory, with owners and earlier releases, is at [docs.gage.cash/protocol/addresses](https://docs.gage.cash/protocol/addresses).

Intent V1 release `intent-v1-r9-20261015` (Robinhood Chain mainnet):

| Contract | Address |
|---|---|
| IntentFactory | [`0x20A908D82885cF4E990A9F8F3F5A483687660822`](https://repo.sourcify.dev/4663/0x20A908D82885cF4E990A9F8F3F5A483687660822) |
| IntentQuoteVerifier | [`0x80eC8893Cec448Cd43578C9d1E5a4Bee71A7dB53`](https://repo.sourcify.dev/4663/0x80eC8893Cec448Cd43578C9d1E5a4Bee71A7dB53) |
| IntentFillRouter | [`0xF8560439d914Fe1Fc2C1A2fAA5b19Ed46F73208d`](https://repo.sourcify.dev/4663/0xF8560439d914Fe1Fc2C1A2fAA5b19Ed46F73208d) |
| GageV2Vault (engine) | [`0x856E4232469b957150Cb29a8Ce9b60059449E87e`](https://repo.sourcify.dev/4663/0x856E4232469b957150Cb29a8Ce9b60059449E87e) |
| GageV2TokenRegistry | [`0x09c52d590BD9c764FBE58E6fF8b6E31Bae892670`](https://repo.sourcify.dev/4663/0x09c52d590BD9c764FBE58E6fF8b6E31Bae892670) |
| GageV2CashoutRouter | [`0x3E7Dc9bd908f5bA5AAe43238C915e4F28A073EA7`](https://repo.sourcify.dev/4663/0x3E7Dc9bd908f5bA5AAe43238C915e4F28A073EA7) |
| GageLegacyAdapter (bridge) | [`0x789637f1F3fde2760D66b365F2Cf7e30d2c7f6Ca`](https://repo.sourcify.dev/4663/0x789637f1F3fde2760D66b365F2Cf7e30d2c7f6Ca) |
| GradeRegistry | [`0x897B15EA30923f9AdbEa4637AAee98722480Cb3d`](https://repo.sourcify.dev/4663/0x897B15EA30923f9AdbEa4637AAee98722480Cb3d) |
| MorphoV2ReserveLens | [`0x653a22564C7ae7c37511DeE025342afEC2c20A16`](https://repo.sourcify.dev/4663/0x653a22564C7ae7c37511DeE025342afEC2c20A16) |
| LoopRouter | [`0xaCfFFd412DD838D3EdE489BC4B79E19505769baD`](https://repo.sourcify.dev/4663/0xaCfFFd412DD838D3EdE489BC4B79E19505769baD) |
| PrivateBorrowRouter | [`0xc62DA1872bf3C9922e8C22Be4b29b5317b4bAa21`](https://repo.sourcify.dev/4663/0xc62DA1872bf3C9922e8C22Be4b29b5317b4bAa21) |

Each `IntentVault` the factory creates, with its `IntentAssetPolicy` and `IntentLenderMarket`, is verified the same way. The private lane runs 0xbow's [Privacy Pools](https://github.com/0xbow-io/privacy-pools-core) v1.3.0 unchanged; its Entrypoint, verifiers and pools are verified on Sourcify from 0xbow's pinned source.

Source verification is not a security audit. It lets anyone compare source code with deployed bytecode.

## Build and test

Requires [Foundry](https://book.getfoundry.sh). Solidity 0.8.28 is fetched automatically.

```bash
git clone --recursive https://github.com/DebenLabs/gage-contracts
cd gage-contracts/contracts
forge build
forge test
```

Some tests deploy Uniswap v4 and Permit2 from their own builds. Build those once, in place, before the first `forge test`:

```bash
(cd lib/v4-periphery && forge build --skip test --skip script)
(cd lib/v4-periphery/lib/v4-core && forge build --skip test --skip script)
(cd lib/v4-periphery/lib/permit2 && forge build --skip test --skip script)
```

Fork tests read Robinhood Chain and skip themselves without `ROBINHOOD_RPC_URL`; copy `.env.example` to `.env` to run them. `forge build --skip test --skip script` reproduces the creation code deployed in the Intent V1 release: the build settings live in `foundry.toml` (Solidity 0.8.28, via-IR where it is configured, no metadata hash).

## License

gage's contracts are licensed under the [GNU General Public License v3.0 or later](LICENSE). The libraries under `contracts/lib` keep their own licenses.
