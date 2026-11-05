# gage lender AMM: reference kit

A Uniswap v4 hook whose idle LP liquidity is lent through gage partner vaults, for DEX partners to copy, audit and deploy.
`GageLenderHook` is OpenZeppelin's `ReHypothecationHook` (uniswap-hooks v1.3.0-rc.0, a release candidate with no published audit) with a gage tier. Each pool currency has
its own gage vault. Swaps draw on a float the hook holds, and a keeper refills the float from the vault's free cash and
sweeps the excess back, outside swaps. The hook never calls a vault inside a swap. Design, partner rules, onboarding,
parameters and risks: [`docs/lender-amm.md`](../../docs/lender-amm.md).

**Unaudited reference code**, like the OpenZeppelin contract it extends, which OpenZeppelin marks experimental. A partner
audits its own deployment. gage deploys none on mainnet, and the deploy script refuses chain 4663 unless
`LENDER_AMM_ALLOW_MAINNET=true`.

## Layout

| Path | What |
|---|---|
| `src/GageLenderHook.sol` | The hook. |
| `src/interfaces/IGageVault.sol`, `IIntentFactory.sol` | The parts of gage's `IntentVault` and `IntentFactory` the kit uses. |
| `script/DeployLenderAmm.s.sol` | One command: both vaults, the hook at a mined address, the pool, the keeper, the seed. |
| `script/LenderAmmSetup.sol` | The network from gage's manifest, the two mandates and the hook's mined address, shared with the fork suite. |
| `script/rehearse.sh` | The testnet rehearsal: deploy, provide liquidity, swap both ways, sweep, refill, exit. |
| `script/RehypoSource.s.sol`, `src/UnlockCheckedHook.sol` | gage's rehypo source: the factory's release step, a pool's set-up (the testnet rehearsal) and the reference hook it deploys. Guide: `docs/rehypo-source.md`, "Running it". |
| `test/` | Unit and rounding suites against a stand-in vault (`test/mocks/MockGageVault.sol`), the two mandates' collateral read from a manifest (`LenderAmmSetup.t.sol`), and `test/fork/` against the live testnet (and the rehypo source against mainnet). |
| `keeper/` | The TypeScript keeper: refill and sweep thresholds, the price band, the free-cash schedule, settling and pockets. |
| `deployments/` | Each deployment's record (`<chainId>.json`) and the rehearsal's transactions. |

## Setup

In the gage repository, the kit builds on gage's own pins of Uniswap v4, OpenZeppelin Contracts and forge-std
(`lib/` at the repository root). Those are the versions gage's testnet v4 deployment was built from. Only uniswap-hooks is pinned here,
as a submodule CI's recursive checkouts skip:

```bash
git submodule update --init --recursive contracts/lib/forge-std contracts/lib/openzeppelin-contracts contracts/lib/v4-periphery
```

```bash
git submodule update --init --checkout integrations/lender-amm/lib/uniswap-hooks
```

To use it outside the gage repository, install the same commits under `lib/` and point the remappings in `foundry.toml`
at them:

| Library | Commit |
|---|---|
| OpenZeppelin/uniswap-hooks | `b5f10574f943911635754dd76ed6ce95858b7d93` (tagged `v1.3.0-rc.0`, a release candidate: no published audit; a partner audits the diff from the audited v1.1.0 with its own copy) |
| Uniswap/v4-periphery | `dce236d4e2057422d0791d9a973a58765eb46f65`, with its v4-core at `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` |
| OpenZeppelin/openzeppelin-contracts | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` (v5.7.0) |
| foundry-rs/forge-std | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |

## Build and test

From `integrations/lender-amm`:

```bash
forge build
```

```bash
forge test --no-match-path 'test/fork/*'
```

```bash
LENDER_AMM_FORK_RPC=https://rpc.testnet.chain.robinhood.com forge test --match-path 'test/fork/*'
```

The fork suite creates real vaults on the testnet's USDG and GLDx generations, admitting its curator as the factory owner
would. It then runs the whole cycle on the testnet's own PoolManager. It forces the vault's refusal moments by rewriting
its clock word (slot 31, pinned by gage's `IntentVaultSettingsLayout.t.sol`).

```bash
LENDER_AMM_MAINNET_FORK_RPC=<a chain 4663 RPC> forge test --match-path test/fork/RehypoSource.fork.t.sol
```

The rehypo source's fork test runs gage's rehypo source on mainnet's live PoolManager with real USDG and frxUSD:
the factory built at the repository root (`forge build src/rehypo/GageRehypoSourceFactory.sol` there first), `UnlockCheckedHook`
on a new pool at one for one, set up as `script/RehypoSource.s.sol` does. The gage vault and the generation deployer's
record are the plug test's stand-ins: neither is on chain 4663 yet. `LENDER_AMM_MAINNET_FORK_BLOCK` pins the block; the
RPC must still serve that block's state (the public node keeps only about the last ten minutes, so pin a recent block
there, or use an archive RPC). CI sets no RPC for the kit, so this test runs only by hand.

## Deploy

The broadcaster must be an admitted creator on both generations' factories. It becomes both vaults' curator and the hook's owner.

```bash
KEEPER=<keeper> SEED_ASSET=<raw GLDx> SEED_USDG=<raw USDG> forge script script/DeployLenderAmm.s.sol --rpc-url <rpc> --broadcast --slow --keystore <curator keystore> --sender <curator>
```

| Variable | Default | Meaning |
|---|---|---|
| `LEND_ASSET` | `GLDx` | The lend asset paired with USDG: a key of the manifest's `intentV1Assets`. |
| `ASSET_FLOAT_BPS`, `USDG_FLOAT_BPS` | 2000 | Each side's float target, in basis points of its backing. |
| `ASSET_BUFFER_BPS`, `USDG_BUFFER_BPS` | 3000 | Each vault's "Cash kept free". |
| `ASSET_MAX_LOAN`, `USDG_MAX_LOAN` | 5 units, 1,500 USDG | Each vault's largest loan. |
| `ASSET_TERM`, `USDG_TERM` | 604800 | Each vault's longest term. |
| `ASSET_FEE_BPS`, `USDG_FEE_BPS` | 1000 | Each vault's performance fee. |
| `USDG_COLLATERAL` | `GLDx,NVDAx,TSLAx,MSFTx`, less the lend asset | Manifest keys of what the USDG vault lends against; the asset vault takes its generation's collateral, less USDG. Neither vault lends against a currency of its own pool, so a list that names one stops the script (rule 8 in `docs/lender-amm.md`). |
| `POOL_FEE`, `POOL_TICK_SPACING` | 3000, 60 | The pool key. |
| `START_SQRT_PRICE` | the hookless pool's price | Where the pool starts. |
| `USDG_VAULT`, `ASSET_VAULT` | | Reuse an earlier run's vaults. |

## Keeper

A standalone package with its own lockfile, outside gage's pnpm workspace:

```bash
cd keeper && pnpm install --ignore-workspace --frozen-lockfile
```

```bash
pnpm --ignore-workspace once
```

Without `KEEPER_KEY` every send is only simulated (`would_send`). It reads the hook from `deployments/<chainId>.json` and
StateView and the indexer from gage's manifest. Every one of these is an environment variable; the list is in
`docs/lender-amm.md`. Logs are JSON lines.

## Rehearse on the testnet

```bash
KEYSTORES=<dir with curator.json, lp.json, swapper.json, keeper.json and pw> script/rehearse.sh
```

It refuses any chain but 46630 and writes its transactions to `deployments/46630.rehearsal.md`. Run it against a local
fork first with `RPC_URL`.
