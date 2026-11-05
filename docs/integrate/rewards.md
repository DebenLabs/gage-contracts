# sGAGE rewards on loans

Both sides of an eligible loan earn sGAGE, gage's reward token. A loan's allocation is fixed when the loan activates and accrues on a quadratic clock over its term. Every core keeps its loans' allocations in its own rewards ledger (`GageV2Rewards`). How sGAGE reaches that ledger depends on the generation: the USDG core's ledger is backed by its legacy adapter; the GLD, NVDA and HIMS cores' ledgers hold no budget, and a **rewards bridge** gives their loans sGAGE from their own fees; the frxUSD core's ledger pays from a budget funded into it. Lenders are partner vaults, so a depositor takes its sGAGE from the vault. Use this page to read a loan's or a vault's rewards and to claim them. Rates and budgets are on [Weekly budgets](https://docs.gage.cash/rewards/weekly-budgets), the unlock curve on [The drip](https://docs.gage.cash/rewards/the-drip).

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| `GageV2Rewards`, the USDG core's ledger | `0x614E087972d49DFe6FEDbaC1333192313aF36aD9` (the core's `REWARDS()`) | [GageV2Rewards.sol](../../src/v2/GageV2Rewards.sol) | [GageV2Rewards.json](../../abi/GageV2Rewards.json) | No owner. Only its core writes allocations; each account claims its own. |
| `GageLegacyAdapter`, the USDG core's adapter | `0x6c9661b2D0C2FAB991097f4c3332F61D28b71891` (the core's `BRIDGE()`) | [GageLegacyAdapter.sol](../../src/v2/GageLegacyAdapter.sol) | [GageLegacyAdapter.json](../../abi/GageLegacyAdapter.json) | Its admin selects the one engine that opens new loans; nothing moves a loan's rewards. |
| `GageV2Rewards`, the GLD core's ledger | `0xa83939Ff28EcdB75D96C653717CF07a638ecA4Af` | same | same | No owner. |
| `GageV2Rewards`, the NVDA core's ledger | `0x25c3976ca28D2B9265050D290a58dF46864A2D5d` | same | same | No owner. |
| `GageV2Rewards`, the HIMS core's ledger | `0x4BEa4A533Ef7463fc67565b9Ac96F7eE1AF93AE2` | same | same | No owner. |
| `LendRewardsBridge (GLD)` | `0x7888fB3330141c1fD9682C753f88F280B41FA458` | [LendRewardsBridge.sol](../../src/intent/LendRewardsBridge.sol) | [LendRewardsBridge.json](../../abi/LendRewardsBridge.json) | gage's Safe (`owner()`: names the keeper, can send held fees to the floor). gage's keeper (`keeper()`) mirrors loans and pays vaults. |
| `LendRewardsBridge (NVDA)` | `0x020B2F852ae8b0Fa83D0C3F0924A63D65EF899D3` | same | same | same |
| `LendRewardsBridge (HIMS)` | `0x1cF5Eb476D5200ceF62c7FBBDf872b31AE3A2E82` | same | same | same |
| `LendRewardsLender`, one per bridge | each bridge's `LENDER()` | [LendRewardsLender.sol](../../src/intent/LendRewardsLender.sol) | | Its bridge alone. |
| `DealRewards` | `0x5B95978dbE6193E9510aff8a8d78A92d84e6340d` | [DealRewards.sol](../../src/token/DealRewards.sol) | | gage posts its weekly rates; it grants each registered deal's drips. |
| `Drip` | `0x3f2b11467C0EAbdc7f0D5910193BA012BbCc08Ff` | [IDrip.sol](../../src/interfaces/token/IDrip.sol) | | No owner. |
| sGAGE | `0x78c88CF8F6E612955526cEB501be82BF3279Bd5d` | | | No owner: an ERC-20 of 18 decimals, 5,000,000,000 minted once, burnable, no mint. |
| Partner vaults (`IntentVault`) | each factory's `vaults(i)` | [IntentVault.sol](../../src/intent/IntentVault.sol) | | Each vault's curator; rewards are each holder's. |

The bridges are not in the [manifest](../../deployments/manifest/4663.json). Each lend-asset generation's fee processor names its bridge: `forwardTo()` on `intentV1Assets.<SYMBOL>.feeProcessor`, checked by the bridge's `CORE()`. The USDG core's ledger and adapter are the `nativeV2.engines` entry whose `engine` is `0x0086EC1540719d4199432797e2b6068E6aE5a0e5`.

## How it works

### A loan's allocation, on every core

- **Fixed at activation.** The funding that buys a loan's fourth lender unit activates it. The core emits `Activated` with the borrower's and the lenders' totals, and the ledger stores them (`allocation(id)`). The lenders' total is split into the loan's four quarters: each quarter takes a quarter, and the first quarters take one raw unit more each while the total does not divide by four.
- **The clock.** What an allocation has earned at time `t` is `total × min(t − start, term)² / term²`: 25% half way through the term, all of it at the end. The repayment or the default that closes the loan stops the clock; what it had not earned is never paid.
- **Sales.** Selling the reclaim right or lender quarters of a running loan keeps what they earned with the seller; the buyer takes only what accrues after.
- **Claims.** Each account claims its own: `claim(id, recipient)` pays `claimable(id, msg.sender)` to `recipient`. A partner vault claims its quarters' sGAGE itself (below).
- **Who lends.** A ledger lets only its generation's partner vaults lend: `funderGate()` is the generation's factory, bound once.

### The USDG core: backed by its legacy adapter

The USDG core is bridged (`BRIDGE()` is its `GageLegacyAdapter`). At activation the adapter opens a matching deal on the V1 `DealVault` (`0x3D979740785ABd8b7Dd5c2Ff7Bf100CBe86fcBDF`), backed by one unit of its own receipt, and registers it with `DealRewards`, which grants that deal's two drips. The loan's allocation is the adapter's quote at activation (`quote(uint32 term, uint128 fee)`): the V1 deal's own allocation at the week's posted rate for the term, plus sGAGE recycled from loans that closed early, within the same rate and cap. Only 1-, 7- and 21-day loans can earn it, a 1-day loan at the 7-day rate. A claim on the ledger is paid through the adapter (`pay`) as those drips unlock, so a claim can pay a few raw units less than `claimable` until the next unlock. This ledger keeps no budget of its own (`freeBudget()` is 0) and refuses donations (`fund` reverts `InvalidTransfer`).

### GLD, NVDA and HIMS: the rewards bridges

Their cores are unbridged and their ledgers hold no budget, so their loans activate with no core allocation. Their sGAGE comes from their own fees, through the generation's `LendRewardsBridge`:

1. **Fees.** The generation's fee processor sells the core's fees for USDG and forwards them to the bridge (`availableUSDG()`).
2. **Mirroring, by gage's keeper.** `mirror(loanIds, minReward)` takes up to 64 loans of the core (`MAX_LOANS`) in up to 3 terms (`MAX_TERMS`). For each term it spends part of the USDG held as the fee of one V1 mirror deal: the principal is a Morpho flash loan, the bridge's `LENDER()` funds the deal, the bridge registers it with `DealRewards`, repays it and returns the flash loan, all in the same call. The whole fee reaches the V1 fee route, and so gage's floor. `DealRewards` grants the deal's two drips as for any funded deal, at that week's rate for the term. Each term's deal is one batch (`getBatch(batchId)`).
3. **The budget of a call.** A call spends at most `mirrorBudget(weight)`: 1.25 times (`MAX_SHARE_BPS`, 12,500) the named loans' share, by origination fee among every loan mirrored so far and them, of all the USDG mirrored or held, and never more than is held. The rest waits for later loans.
4. **Shares.** Within a batch each loan weighs its origination fee. Its borrower takes that share of the batch's borrower drip (`borrowerShare`), and the vault of each of its quarters a quarter of it of the lender drip (`vaultShare`), as the core's ledger named them when the batch was mirrored.
5. **The drips** start when the batch is mirrored and unlock over the loan's term on the same quadratic curve.
6. **Vaults, paid by gage's keeper.** `payVault(batchId, vault)` and `payVaults(batchIds, vaults)` send a vault what its share has unlocked, and the vault indexes it to its holders at once. A depositor shares a payment only by holding through it. A vault with no shares is not paid until it has some.
7. **Borrowers, by themselves.** A borrower calls `claim(batchIds, to)` on the bridge.

The bridge refuses a loan that is not yet activated, has no origination fee, carries a core allocation, was mirrored before, or has a quarter without a lender. It moves no loan, no vault asset and nobody's sGAGE but its own. Its owner can name another keeper and, if V1 stops taking deals, send the held USDG to `DealFeeRouter` without rewards (`sendToFloor()`).

### frxUSD: a funded ledger

The frxUSD core is unbridged and has no rewards bridge. Its ledger pays from its own `freeBudget()`, which `fund(amount)` adds to: anyone may call it, and it is irrevocable. A listing carries sGAGE only when the borrower lists with `withRewards`, at the registry's `quoteRewards(term, fee)` for the core's own fee, from the terms gage's Safe posts per term (`rewardTerms(term)`). `quoteRewards` reads the fee as six-decimal units, so terms for an 18-decimal asset such as frxUSD are posted scaled to its decimals. Activation reserves the allocation from the budget and reverts `InsufficientBudget` above it, with the whole fill. gage's app and gage-sdk list with `withRewards` only while the budget covers the quote. The terms quote nothing until they are posted.

### Partner vaults, the lenders

Depositing, redeeming and the vault's other claims are on [Partner vaults](partner-vaults.md). A partner vault holds every quarter its cash funded, so its quarters' sGAGE is the vault's. Before every share change (deposit, withdrawal, transfer, sale) the vault claims each open loan's sGAGE from the core's ledger and indexes it to the shares that held it, so a new depositor never shares what earlier holders earned. `harvestRewards(ids)`, which anyone may call, claims and indexes without a share change. sGAGE a bridge pays is indexed in the same call. Each holder takes its own with `claimRewards()`. sGAGE is outside the share price: it never moves what a share is worth in the vault's asset.

### sGAGE and the drip

sGAGE is a plain ERC-20 of 18 decimals; amounts here are raw units (1 sGAGE is 10^18). A V1 deal's two drips are held in `Drip` under `keccak256(abi.encode("deal", dealId, party))`: `unlocked(account, dripId)` is `total × min(now − start, length)² / length²`, and only the drip's own account claims it. No one can release a drip early or slow it. sGAGE figures are estimates at the pool price, and the posted rates change week to week; a loan can be allocated nothing.

## Call sequences

**Read a loan's rewards.**

1. On the core, `getLoan(uint256 id) external view returns (V2Loan memory)`: `borrowerReward` and `lenderReward` are its totals (zero on GLD, NVDA and HIMS, whose sGAGE comes through the bridge).
2. On the core's ledger (`REWARDS()`), `allocation(uint256 id) external view returns (Allocation memory)`: the borrower, `start`, `end` (zero while it runs), `term`, the two totals and the four quarters' owners.
3. `claimable(uint256 id, address account) public view returns (uint256)` for any account.

**Claim as a borrower, USDG or frxUSD core.**

1. `claimable(id, you)` on the ledger.
2. From your own wallet, `claim(uint256 id, address recipient) external`. It reverts `NothingToClaim` when nothing is payable now, and `InvalidTransfer` for a zero recipient or the ledger itself.

**Claim as a borrower, GLD, NVDA or HIMS.**

1. Find your batches: `LoanMirrored` events of the bridge with your address as `borrower` (an indexed topic), or `mirroredIn(uint256 loanId)` for each of your loans.
2. `borrowerOwed(uint256 batchId, address borrower) external view returns (uint256)` for each.
3. From your own wallet, `claim(uint256[] calldata batchIds, address to) external returns (uint256 total)`. It reverts `ZeroAddress` for `to` of zero and `UnknownBatch(uint256 batchId)` for a batch that does not exist; a batch with nothing owed is skipped.

**Claim as a depositor of a partner vault.** You may end up holding the collateral instead of USDG (in a GLD, NVDA, HIMS or frxUSD vault: instead of the asset you lent), and sGAGE does not change that.

1. `rewardClaimable(address who) public view returns (uint256)` on the vault. It counts only what the vault has already indexed.
2. Optionally `harvestRewards(uint256[] calldata ids) external` first, with the vault's open loan records (`rewardRecords(address vault)` on the factory's `SHARE_VIEWS()`), to index what they have accrued since the vault last claimed.
3. From your own wallet, `claimRewards() external returns (uint256 amount)`. It reverts `InvalidAmount` when you have nothing to claim.

**Fund a funded ledger (frxUSD).** `approve(ledger, amount)` on sGAGE, then `fund(uint256 amount) external` on the ledger, in raw sGAGE. Irrevocable. A bridged ledger, or an amount of zero, reverts `InvalidTransfer`.

**What only gage's keeper calls**: a bridge's `mirror(uint256[] calldata loanIds, uint256 minReward) external returns (uint256 firstBatch)`, `payVault(uint256 batchId, address vault) external returns (uint256 amount)` and `payVaults(uint256[] calldata batchIds, address[] calldata vaults) external returns (uint256 total)`. Anyone else meets `NotKeeper(address caller)`. `vaultOwed(uint256 batchId, address vault)` says what `payVault` would pay now.

## Events to index

| Contract | Event | Meaning |
| --- | --- | --- |
| Core (`GageV2Vault`) | `Activated(uint256 indexed id, uint40 fundedAt, uint128 fee, uint128 borrowerReward, uint128 lenderReward)` | The allocation is fixed; its clock starts at `fundedAt`. |
| Core | `Closed(uint256 indexed id, V2State state, address beneficiary, uint40 closedAt)` | Repaid or defaulted: the clock stops at `closedAt`. |
| `GageV2Rewards` | `Claimed(uint256 indexed id, address indexed account, address indexed recipient, uint256 amount)` | An account took a loan's sGAGE. |
| `GageV2Rewards` | `Funded(address indexed funder, uint256 amount)` | sGAGE added to a funded ledger's budget. |
| `GageV2Rewards` | `FunderGateBound(address indexed gate)` | Once: the factory whose vaults lend. |
| `GageLegacyAdapter` | `LoanOpened(uint256 indexed id, address indexed engine, uint256 indexed engineId, uint256 legacyId, address account, address borrower, address lender, uint128 borrowerReward, uint128 lenderReward)` | A USDG loan's matching V1 deal; `engineId` is the core's loan id. |
| `GageLegacyAdapter` | `RewardsPaid(uint256 indexed id, address indexed ledger, uint256 amount)`, `RewardsRecycled(uint256 indexed id, uint256 amount)` | sGAGE delivered to the ledger at a claim; a closed loan's unlocked surplus made available to later loans. |
| `LendRewardsBridge` | `Mirrored(uint256 indexed batchId, uint256 indexed dealId, uint32 term, uint256 fee, uint128 lenderReward, uint128 borrowerReward, uint16 loans)` | One batch: its V1 deal, the USDG fee it paid and the sGAGE of its two drips. |
| `LendRewardsBridge` | `LoanMirrored(uint256 indexed batchId, uint256 indexed loanId, address indexed borrower, uint128 originationFee)` | A loan in a batch, its borrower and its weight (raw units of the lend asset). |
| `LendRewardsBridge` | `VaultPaid(uint256 indexed batchId, address indexed vault, uint256 amount)` | gage's keeper paid a vault. |
| `LendRewardsBridge` | `BorrowerClaimed(uint256 indexed batchId, address indexed borrower, address to, uint256 amount)` | A borrower took its share. |
| `LendRewardsBridge` | `KeeperSet(address indexed keeper)`, `SentToFloor(address indexed to, uint256 amount)` | The owner's two levers. |
| `IntentVault` | `RewardsHarvested(uint256 amount)`, `RewardsClaimed(address indexed account, uint256 amount)` | sGAGE indexed to the vault's holders; a holder took its own. |
| `DealRewards` | `Registered(uint256 indexed dealId, uint256 indexed epoch, uint32 term, uint128 fee, uint128 reward, uint128 lenderAmount, uint128 borrowerAmount, bool budgetExhausted)` | A V1 deal's allocation, the adapter's and the bridges' mirror deals included. |
| `Drip` | `Granted(address indexed account, bytes32 indexed dripId, uint128 total, uint40 start, uint32 length, address grantor)`, `Claimed(address indexed account, bytes32 indexed dripId, uint128 amount)` | A drip opened; an unlocked part claimed. |

The ledger emits nothing when it allocates or closes: index the core's `Activated` and `Closed`.

## Errors you will meet

| Contract | Error | When |
| --- | --- | --- |
| `GageV2Rewards` | `NothingToClaim()` | `claim` with nothing payable now. |
| `GageV2Rewards` | `InvalidTransfer()` | `claim` to zero or to the ledger; `fund` of zero or on a bridged ledger. |
| `GageV2Rewards` | `InsufficientBudget()` | A funded ledger's activation above its free budget: the fill reverts. |
| `GageV2Rewards` | `NotFunder()`, `Paused()` | Funding by an account that is not the generation's vault; new deals paused on the registry. |
| `LendRewardsBridge` | `ZeroAddress()`, `UnknownBatch(uint256 batchId)` | A borrower's `claim` to zero, or naming a batch that does not exist. |
| `LendRewardsBridge` | `NotKeeper(address caller)` | `mirror`, `payVault` or `payVaults` from anyone but gage's keeper. |
| `LendRewardsBridge` | `LoanNotActivated(uint256 loanId)`, `LoanWithoutFee(uint256 loanId)`, `LoanRewardedByCore(uint256 loanId)`, `LoanAlreadyMirrored(uint256 loanId, uint256 batchId)`, `LoanWithoutLender(uint256 loanId)`, `LoanCount(uint256 count)`, `TooManyTerms()`, `NoFees()`, `ZeroFee(uint32 term)`, `RewardBelowMinimum(uint256 reward, uint256 minimum)` | The keeper's `mirror`, when a named loan or the call does not qualify. |
| `IntentVault` | `InvalidAmount()` | `claimRewards` with nothing to claim. |
| `IntentVault` | `RewardsPending()` | A share change while one of the vault's loans cannot deliver its owed sGAGE; nothing changes. |
| `Drip` | `NothingClaimable()`, `NoDrip(address account, bytes32 dripId)` | A drip claim with nothing unlocked, or no such drip. |

## Examples

- [`examples/foundry/test/Rewards.t.sol`](../../examples/foundry/test/Rewards.t.sol): reads the USDG core's bridged ledger and each lend-asset ledger, finds each rewards bridge from its fee processor and checks its wiring, shows that only gage's keeper mirrors and pays, follows a live loan's allocation to the end of its term, and claims a partner vault's sGAGE as a depositor of the test's own. `forge test --match-path test/Rewards.t.sol -vv` from `examples/foundry`.
- [`examples/viem/src/rewards-read.ts`](../../examples/viem/src/rewards-read.ts): the same reads with viem and, for a wallet you pass, every claim it can make now, built as calldata and never sent. `npx tsx src/rewards-read.ts [wallet]` from `examples/viem`.

```solidity
// At the end of the term the whole allocation has accrued: the borrower's claimable rises by exactly the rest.
uint256 earned = _curve(a.borrowerTotal, block.timestamp - a.start, a.term);
uint256 now_ = ledger.claimable(id, a.borrower);
vm.warp(uint256(a.start) + a.term);
assertEq(ledger.claimable(id, a.borrower) - now_, a.borrowerTotal - earned);
```

## What not to rely on

- **A reward at all.** A loan can be allocated nothing: a week's rate can be zero, a term's budget can run out, a funded ledger's budget can be empty. sGAGE figures are estimates at the pool price.
- **When a bridge pays.** Mirroring and vault payments run on gage's keeper's clock. A loan's bridge drips start when its batch is mirrored, not when the loan activated.
- **A later buyer's bridge share.** A batch's borrower and vault shares go to the accounts the ledger named when it was mirrored. A reclaim right or quarter sold afterwards keeps its bridge share with the seller.
- **`rewardClaimable` as everything a vault holder has earned.** It counts what the vault has indexed; `harvestRewards` brings in the rest, and bridge sGAGE arrives only when gage's keeper pays.
- **`claimable` on the USDG ledger as exact.** A claim can pay a few raw units less until the adapter's next unlock.
- **The manifest's `nativeV2.engines` order**, or a fee processor's `forwardTo()` naming a bridge for good: gage's Safe can repoint a fee processor. Check a bridge by its `CORE()`.
- **Any of this on earlier generations.** Their ledgers follow the same rules, but their loans and vaults are listed under `intentV1Previous` and `intentV1AssetsPrevious`.
