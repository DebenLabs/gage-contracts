# Integrate with gage

gage is fixed-cost, peer-to-peer lending on Robinhood Chain mainnet (chain ID 4663). No liquidation: nothing can touch a loan's collateral before the end of its term; at the end, the borrower repays or the lender keeps the collateral. These guides cover each way to build on the contracts in this repository: what to call, in what order, which events to index, and worked examples you can run against mainnet.

## Pick your path

| You want to | Read |
| --- | --- |
| Read markets, loans and partner vaults, or rebuild them from events | [reading.md](reading.md) |
| Borrow against a token, sell the collateral to repay, or borrow with leverage | [borrowing.md](borrowing.md) |
| Lend by depositing into a partner vault, or create and curate one | [partner-vaults.md](partner-vaults.md) |
| Understand how a listing gets funded, and check a fill on chain | [fills.md](fills.md) |
| Roll a running loan into a new one, now or by standing instruction | [rollover.md](rollover.md) |
| Use the NVDA put router | [puts.md](puts.md) |
| Leave a loan or a vault position before its end through the exit desk | [exit-desk.md](exit-desk.md) |
| Borrow against a concentrated-liquidity LP position, or lend to that lane | [lp-lane.md](lp-lane.md) |
| Recognise a generation, and how the GenerationDeployer builds one | [generations.md](generations.md) |
| Track and claim sGAGE rewards | [rewards.md](rewards.md) |
| Lend a DEX pool's idle liquidity through gage (rehypo source, lender-AMM kit) | [dex-partners.md](dex-partners.md) |
| Find an address | [addresses.md](addresses.md) |

## How gage is put together

- **A generation per lend asset.** USDG, NVDA, HIMS, GLD and frxUSD each have their own set of contracts. Its **core** holds every loan in that asset. Its **registry** sets which collateral is admitted, its minimums, the terms and the fee. Its **factory** creates the **partner vaults** that fund loans. Its **routers** fill, roll, cash out and exit loans. [addresses.md](addresses.md) lists each generation's contracts.
- **Borrowers list, partner vaults fund.** A borrower lists collateral on a core. Partner vaults whose rules take the listing fund it whole, through the generation's fill router, on a plan gage's rates service signs. gage's keeper is the only wallet that fills; gage's own routers (rollover, loop, private borrow) fill inside their own transactions. A wallet or contract lends by depositing into a partner vault, not by funding a listing.
- **Nothing to upgrade.** No contract here has an upgrade function. The cores and the fill routers have no owner either. A partner vault has a manager whose settings the vault bounds; a pause never blocks redemptions. Registries, factories and most routers have an owner, a Safe gage controls, and every setting an owner can change has a compile-time bound.

## Rules every integration follows

- **Pull, never push.** Anything owed to an account is credited to a balance on the contract that owes it, and the account withdraws it. Read the balance views (a core's `cashCredit`, the LP core's `credit`), not incoming transfers: a core's withdrawals emit no event of their own, only the token's `Transfer`.
- **No price in the deal path.** The cores and vaults read no price. A loan ends on time alone: repaid by the end of its term, or the lender keeps the collateral.
- **Raw units.** Amounts are the token's raw units: USDG has 6 decimals; read each token's `decimals()`. Stock Tokens are raw on chain; scale by `uiMultiplier()` for display only.
- **Time is block timestamps.** Deadlines are timestamps; block numbers on this chain are an estimate.
- **The Universal Router is a modified fork.** Its v4 swap struct carries an extra `minHopPriceX36` field, so stock Uniswap SDK calldata reverts. Anything that builds swap calldata must target that ABI.
- **What needs gage's services, and what doesn't.** Funding a new listing needs gage's keeper and a plan gage's rates service signs, and so does a standing roll. Repaying, cancelling an unfilled listing, settling a vault's loans, redeeming and withdrawing need only a wallet and the addresses here.
- **Words.** The borrower's cost is a fixed cost for the term, an amount and a percentage, never interest. Near every lender action: you may end up holding the collateral instead of the asset you lent.

## ABIs, addresses and source

- `abi/<Contract>.json`: one ABI per deployed contract, from the build that matches the chain ([`script/reproduce.mjs`](../../script/reproduce.mjs) proves it).
- [`deployments/4663.json`](../../deployments/4663.json): every deployed contract, with its role, source, address and ABI file.
- [`deployments/manifest/4663.json`](../../deployments/manifest/4663.json): gage's public deployment manifest, addresses only, at the keys the guides use. Read addresses from it in code; the examples do.
- [`src/`](../../src): the deployed source. NatSpec on every external function is the reference for argument meaning and bounds.

## Running the examples

Foundry fork tests, against mainnet through the public RPC:

```bash
cd examples/foundry && forge test
```

viem scripts:

```bash
cd examples/viem && npm install && npx tsx src/cores-read.ts
```

The scripts read and simulate only: no key, no transaction. To send one, give a `walletClient` your own signer.

Questions and integration requests: [CONTRIBUTING.md](../../CONTRIBUTING.md). A DEX partner starts at [PARTNERS.md](../../PARTNERS.md). Never report a vulnerability in an issue: [SECURITY.md](../../SECURITY.md).
