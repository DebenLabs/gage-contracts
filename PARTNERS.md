# Integrate with gage

For a DEX whose Uniswap v4 hook lends a pool's idle liquidity through gage. Your hook deposits into a **gage rehypo source**, one ERC-4626 vault per pool token. The source keeps a float for swaps and lends the rest through a **gage partner vault** your Safe creates and manages. Your hook needs no gage-specific code.

- How the source works and what your hook must do: [docs/rehypo-source.md](docs/rehypo-source.md)
- The reference kit (hook, keeper, scripts, the plug suite): [integrations/lender-amm/](integrations/lender-amm/) and [docs/lender-amm.md](docs/lender-amm.md)
- What you call: [interfaces/](interfaces/)

**Status:** partner vaults are live on mainnet. The rehypo source factory is not deployed yet: steps 4 to 7 below wait for it.

## The steps

| # | Who | What |
| --- | --- | --- |
| 1 | You | **Open an issue** with the [Integrate with gage](../../issues/new?template=integration.yml) form, kind "Hook or rehypothecation source": your hook (repository, commit, audit), your pool and your Safe. |
| 2 | gage | **Reviews your hook on a mainnet fork** with the plug suite (`integrations/lender-amm/test/RehypoSourcePlug.t.sol`) and the hook checklist in [docs/rehypo-source.md](docs/rehypo-source.md). We answer in the issue. |
| 3 | gage | **Admits your Safe as a creator** on the Intent factory of each token you lend (`IntentFactory.setCreator(yourSafe, true)`). Check it with `isCreator(yourSafe)`. |
| 4 | Your Safe | **Creates its partner vaults**: `IntentFactory.create(mandate, ...)`, with your Safe as the curator, one vault per lent token. Your Safe manages each vault for good. |
| 5 | Your Safe | **Creates the sources**: on the rehypo source factory, `create(asset, vault, owner, beneficiary, floatBps, salt)` once per pool token. `vault` is your partner vault of that token, or zero for a float-only side. `predict` gives the addresses ahead of time. |
| 6 | Your Safe | **Deploys and starts the pool**: deploy your hook naming the two sources, initialize the pool, `bind(poolKey)` on each source, seed the pool, then `setKeeper(gageKeeper, true)` on each source with the keeper address we give in the issue. |
| 7 | gage | **Turns on the keeper** for your sources and your pool's price band. We confirm in the issue and close it. |

Steps 4 to 6 can be one Safe batch per pool. `integrations/lender-amm/script/RehypoSource.s.sol` makes the same calls in the same order on a test network: use it as your reference.

## Before you open the issue

- [ ] Your hook meets each item of the checklist in [docs/rehypo-source.md](docs/rehypo-source.md) ("A hook of the partner's own design").
- [ ] It passes the plug suite on your own fork: `forge test --match-path test/RehypoSourcePlug.t.sol` from `integrations/lender-amm`, with your hook in place of `UnlockCheckedHook`.
- [ ] Your hook is audited, or will be before it holds liquidity on mainnet. gage reviews the integration, not your whole hook.
- [ ] You know who signs for your Safe, and which address receives sGAGE and recovered collateral (the source's `beneficiary`).

## The emergency lever

Your Safe calls `setFloatBps(10000)` on the lent source: nothing more goes to the vault, and gage's keeper pulls the float back from the vault's free cash. Your Safe also pauses the vault (`setPaused(true)`): no new loans, and exits still go through. Details in [docs/rehypo-source.md](docs/rehypo-source.md).

**Found a vulnerability?** Do not open an issue: see [SECURITY.md](SECURITY.md).
