# Reading markets and loans

Every gage loan is a record on a **core**, a `GageV2Vault`: one core per lend asset and generation. The core holds each loan's collateral in an account of its own, records the loan's terms and state, credits what it owes, and reads no price. Next to it, the core's **registry** decides what may be listed, its **rewards ledger** records each loan's sGAGE, and its **cash-out router** sells a running loan's collateral for its holder. This page shows how to find every core, read a loan and the rules a core lists under, batch those reads, use the public API's lists, and rebuild the same state from events. Partner vaults, which fund the loans, have their own page: [partner-vaults.md](partner-vaults.md).

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| USDG core (`GageV2Vault`) | `0x0086EC1540719d4199432797e2b6068E6aE5a0e5` | [GageV2Vault.sol](../../src/v2/GageV2Vault.sol) | [GageV2Vault.json](../../abi/GageV2Vault.json) | Nobody: no owner, no upgrade, no admin path to collateral or credits. |
| USDG core's registry (`GageV2TokenRegistry`) | `0x732fB25C6905d0cbeB639F1226398aB317189bA0`, the core's `REGISTRY()` | [GageV2TokenRegistry.sol](../../src/v2/GageV2TokenRegistry.sol) | [GageV2TokenRegistry.json](../../abi/GageV2TokenRegistry.json) | Its owner (`owner()`, `Ownable2Step`), a Safe gage controls: admissions and limits, terms, fees, routers, the pause of new loans. Every setting has a compile-time bound and gates new loans only. |
| USDG core's rewards ledger (`GageV2Rewards`) | `0x614E087972d49DFe6FEDbaC1333192313aF36aD9`, the core's `REWARDS()` | [GageV2Rewards.sol](../../src/v2/GageV2Rewards.sol) | [GageV2Rewards.json](../../abi/GageV2Rewards.json) | Nobody. The core created it; the registry's owner bound its funder gate once (`bindFunderGate`). |
| USDG core's adapter (`GageLegacyAdapter`) | `0x6c9661b2D0C2FAB991097f4c3332F61D28b71891`, the core's `BRIDGE()` | [GageLegacyAdapter.sol](../../src/v2/GageLegacyAdapter.sol) | [GageLegacyAdapter.json](../../abi/GageLegacyAdapter.json) | Its admin selects the one engine that opens loans through it. It sources the USDG core's sGAGE rewards. |
| USDG core's cash-out router (`GageV2CashoutRouter`) | `0xFA91Ee9221300E034916400DA4c4Fc556633aE15` | [GageV2CashoutRouter.sol](../../src/v2/GageV2CashoutRouter.sol) | [GageV2CashoutRouter.json](../../abi/GageV2CashoutRouter.json) | Its owner admits sale routes and executors. It acts on a loan only with the holder's approval of the reclaim right. |
| Lend-asset cores (`GageV2Vault`) | GLD `0x1E8bd7348C84Ab0A0faBE61DCA1249f75B4e9275`, NVDA `0xe0dDd6869677d3F5A2BC48375FC899B10A6848E1`, HIMS `0xc64C71f1A989E1830948D1ADCB43a2b5f5a8DbA1` | [GageV2Vault.sol](../../src/v2/GageV2Vault.sol) | [GageV2Vault.json](../../abi/GageV2Vault.json) | Nobody. Same code as the USDG core; `USDG()` returns the asset it lends. |
| Their registries | GLD `0x79e64d21F0514BC5aaAFc332D1A1096F0368Ae4c`, NVDA `0x1897cb1bfC61507259073086810F94BCFb609955`, HIMS `0xA077B4D108544EFe90e9d6D1348C3E6c3E071BB1` | [GageV2TokenRegistry.sol](../../src/v2/GageV2TokenRegistry.sol) | [GageV2TokenRegistry.json](../../abi/GageV2TokenRegistry.json) | Their owner, as above. |
| Their rewards ledgers | GLD `0xa83939Ff28EcdB75D96C653717CF07a638ecA4Af`, NVDA `0x25c3976ca28D2B9265050D290a58dF46864A2D5d`, HIMS `0x4BEa4A533Ef7463fc67565b9Ac96F7eE1AF93AE2` | [GageV2Rewards.sol](../../src/v2/GageV2Rewards.sol) | [GageV2Rewards.json](../../abi/GageV2Rewards.json) | Nobody, as above. No adapter (`BRIDGE()` is zero). |
| Their cash-out routers | GLD `0x2d89e340e2ef83729fb6Dc9da61E425fa0e46D70`, NVDA `0xF30ad2ED957e74d36774168c63DfC43C8B025e91`, HIMS `0xf092DA59586b0bBDF9eb9B9C68234887C83eD473` | [GageV2CashoutRouter.sol](../../src/v2/GageV2CashoutRouter.sol) | [GageV2CashoutRouter.json](../../abi/GageV2CashoutRouter.json) | Their owner, as above. |
| frxUSD core and cash-out router | `0x7511F3a302481eEa40982510f2B23D8fCA8C24BA`, `0xB7d2861e0269941e552E1eBa1cA195044516Cf2e` | [GageV2Vault.sol](../../src/v2/GageV2Vault.sol), [V4CashoutRouter.sol](../../src/intent/V4CashoutRouter.sol) | [GageV2Vault.json](../../abi/GageV2Vault.json), [V4CashoutRouter.json](../../abi/V4CashoutRouter.json) | Built by the GenerationDeployer and not in the manifest's `intentV1Assets` yet ([generations.md](generations.md)). |
| USDG partner vault factory (`IntentFactory`) | `0xB086944b140758b33694220d4Fe93C9A8D8618a1` | [IntentFactory.sol](../../src/intent/IntentFactory.sol) | [IntentFactory.json](../../abi/IntentFactory.json) | Its owner. The core's funder gate: `isVault(account)` says who may lend. |
| `IntentVaultViews` | `0x3c2b782ffd62034C4F02346fEdcBd1f567eDE4aB`, the factory's `SHARE_VIEWS()` | [IntentVaultViews.sol](../../src/intent/IntentVaultViews.sol) | [IntentVaultViews.json](../../abi/IntentVaultViews.json) | Nobody; stateless. |
| Earlier USDG engines | `0x22658055B70b8B09616B1e0953f2A51cc66cF493`, `0x08561C817A5bf5230f91C001800449f047e4c07d`, `0xfee799ade96229C2c128BC5ed9E55F8D9d01A7E9`, `0x856E4232469b957150Cb29a8Ce9b60059449E87e` | Earlier builds of `GageV2Vault` | The loan views below match [GageV2Vault.json](../../abi/GageV2Vault.json) | Nobody. They take no new loans and settle the ones they hold. |
| Earlier lend-asset cores | GLD `0xf2B98F79040b4157373093cdDA2A4F2cb3c838d8`, NVDA `0x380a536b1c8bF9e8C1035413497F767F76D30B6e`, HIMS `0x359bb9751F5c2cfDcE5d034a9742E7A0a3aC8e54` | [GageV2Vault.sol](../../src/v2/GageV2Vault.sol) | [GageV2Vault.json](../../abi/GageV2Vault.json) | Nobody. Paused for new loans; they settle the ones they hold. |

## How it works

- **One core per lend asset and generation.** The USDG core is `intentV1.core`. Each lend asset's core is `intentV1Assets.<SYMBOL>.core`, with the asset at `intentV1Assets.<SYMBOL>.lendAsset` (`token`, `decimals`); its registry, rewards ledger and cash-out router are under `intentV1Assets.<SYMBOL>.engine`. A core's `USDG()` is the asset it lends and is repaid in, whatever the name says: GLD's core reports GLD.
- **Earlier engines settle, they do not lend.** `nativeV2.engines` lists every USDG engine, oldest first, each with its `engine`, `registry`, `rewards`, `cashoutRouter` and `startBlock`. Its newest entry is `intentV1.core` itself. The others, the earlier USDG generation (`intentV1Previous[0].intentV1`) and the earlier lend-asset generations (`intentV1AssetsPrevious.<SYMBOL>[0].entry`) keep their loans until they close: their registries pause new listings and funding (`newDealsPaused()` is true, and `list` reverts `Paused()`), while repaying, cancelling, default finalization and withdrawals still work.
- **A loan is a record, four quarters and one right.** Each listing gets the next id on its core, from 1 to `loanCount()`; ids repeat across cores, so key a loan by (core, id). Its principal is sold in `UNITS = 4` lender quarters, and quarter `i` of an amount `total` is `total / 4`, plus one raw unit while `i < total % 4`. The borrower holds one ERC-721 reclaim right per loan ("Gage V2 Reclaim Right", `GAGE-R`, token id = loan id), minted at listing and burnt when the loan closes. Its collateral sits in a clone of `GageV2TokenCollateralAccount`, one per loan.
- **No liquidation.** Nothing can touch a loan's collateral before the end of its term: no price is read and no one can close the loan early. At the end, the holder of the reclaim right has repaid the cap, or the lenders keep the collateral.
- **Pull, never push.** What a core owes an account is credited to `cashCredit(account)`, or recorded as the account's collateral or recovery to withdraw. Nothing arrives on its own.

## Call sequences

### Find every core

1. Read `deployments/manifest/4663.json` (or the live manifest at `https://gage.cash/api/deployment`, with the same keys for addresses). Take `intentV1.core`, then every `intentV1Assets.<SYMBOL>.core`.
2. For each core, read `USDG()`, `REGISTRY()`, `REWARDS()` and `GRACE()`. Check `USDG()` against `USDG` or `intentV1Assets.<SYMBOL>.lendAsset.token`, and `REGISTRY()` and `REWARDS()` against the manifest, before you act on a core.
3. For history, add the earlier engines: every `nativeV2.engines[i].engine` other than `intentV1.core`, and every `intentV1AssetsPrevious.<SYMBOL>[i].entry.core`. A generation the GenerationDeployer built may be missing from `intentV1Assets` until a release adds it: find it from the deployer's `GenerationDeployed` event ([generations.md](generations.md)).

### Read a loan

```solidity
function loanCount() external view returns (uint256);          // the highest id issued, cancelled and closed loans included
function getLoan(uint256 id) external view returns (V2Loan memory);
```

`getLoan` of an id above `loanCount()` does not revert: it returns an empty record, state `NONE`.

```solidity
struct V2Loan {
    address originator;
    address account;
    address token;
    address collateralBeneficiary;
    Kind kind;
    V2State state;
    uint8 filled;
    uint32 term;
    uint40 fundingDeadline;
    uint40 fundedAt;
    uint40 closedAt;
    uint128 principal;
    uint128 cap;
    uint128 originationFee;
    uint128 borrowerReward;
    uint128 lenderReward;
    uint256 collateral;
    bytes32 exposureKey;
    uint256 exposureAmount;
}
```

| Field | Meaning | Units |
| --- | --- | --- |
| `originator` | The borrower at listing: `msg.sender` of `list`, or the `borrower` a router's `listFor` names. It is credited the principal less the fee, and only it may cancel before the funding deadline. | address |
| `account` | The loan's own collateral account. It holds the collateral; `released()` and `recovered()` say whether it left. | address |
| `token` | The collateral token. | address |
| `collateralBeneficiary` | Zero until the loan is repaid (the `recipient` of `reclaim`) or cancelled (the originator). The only account that may call `withdrawCollateral`. | address |
| `kind` | `0`, an ERC-20: the only kind these cores take. Earlier engines also record `1` (Uniswap v4 position) and `2` (Uniswap v3 position). | enum `Kind` |
| `state` | See the table below. | enum `V2State` |
| `filled` | Lender quarters sold, 0 to 4. | count |
| `term` | Length of the loan, counted from `fundedAt`. | seconds |
| `fundingDeadline` | Funding is possible while `block.timestamp < fundingDeadline`; from that second anyone may cancel. At most `MAX_FUNDING_WINDOW` (7 days) after listing; gage's app sets 24 hours. | unix seconds |
| `fundedAt` | When the fourth quarter sold; 0 before. | unix seconds |
| `closedAt` | When the loan was repaid, defaulted or cancelled; 0 while open. | unix seconds |
| `principal` | What the lenders fund. | raw units of `USDG()`: 6 decimals for USDG, 18 for GLD, NVDA, HIMS and frxUSD |
| `cap` | What repaying takes, the principal plus the fixed cost for the term. | as `principal` |
| `originationFee` | `principal × feeBps / 10,000`, fixed at listing from the registry; taken from the borrower's credit at funding. | as `principal` |
| `borrowerReward`, `lenderReward` | The loan's sGAGE allocation. On the USDG core the adapter sets it at funding; elsewhere it is the registry's quote, asked for at listing. | sGAGE raw units, 18 decimals |
| `collateral` | The pledged amount. Stock Tokens are raw on chain; scale by `uiMultiplier()` for display only. | raw units of `token` |
| `exposureKey`, `exposureAmount` | `keccak256(abi.encode(kind, token))` and the raw amount, counted against the token's open cap (`openExposure(key)`). | bytes32, raw units |

The fixed cost is `cap − principal`. Show it as an amount and a percent of the principal for the term together, `0.50 USDG, 0.50% for 7 days`, never as a yearly rate alone.

| `state` | Value | Entered by | Timestamps |
| --- | --- | --- | --- |
| `NONE` | 0 | Never: no loan with this id | all zero |
| `FUNDING` | 1 | `list` | `fundingDeadline` set |
| `ACTIVE` | 2 | the fourth quarter sold (on these cores, one fill through the fill router) | `fundedAt` |
| `REPAID` | 3 | `reclaim` before `fundedAt + term + GRACE` | `closedAt` |
| `DEFAULTED` | 4 | `finalizeDefault`, by anyone, from `fundedAt + term + GRACE` | `closedAt` |
| `CANCELLED` | 5 | `cancelFunding`: the borrower while funding, anyone from `fundingDeadline` | `closedAt`; `fundedAt` stays 0 |

**The window.** Repayment closes, and default finalization opens, in the same second: `fundedAt + term + GRACE`. `GRACE()` is an immutable of each core: 0 on the USDG, GLD, NVDA, HIMS and frxUSD cores and on the two most recent earlier USDG engines, so repayment closes when the term ends; 172,800 s (48 hours) on `nativeV2.engines[0]` and `[1]`.

Other views on the core:

```solidity
function lenders(uint256 id) external view returns (address[4] memory);          // quarter holders; zero while unsold
function ownerOf(uint256 id) external view returns (address);                    // holder of the reclaim right; reverts once closed
function cashCredit(address account) external view returns (uint256);            // USDG (or the core's asset) to withdraw
function openExposure(bytes32 key) external view returns (uint256);
function claimableRecovery(uint256 id, uint8 asset, address holder) external view returns (uint256);
function getAsk(uint256 id) external view returns (V2Ask memory);                // the reclaim right's sale ask, if any
function getLenderAsk(uint256 id, address seller) external view returns (V2LenderAsk memory);
function accrualEnd(uint256 id) external view returns (uint256);
```

Immutables and constants: `USDG`, `SGAGE`, `REGISTRY`, `REWARDS`, `BRIDGE` (the USDG core's adapter; zero on the lend-asset cores), `ACCOUNT_IMPLEMENTATION`, `FEE_RECIPIENT`, `GRACE`, `MAX_FUNDING_WINDOW` (7 days), `MAX_EXECUTION_WINDOW` (15 minutes), `MAX_GRACE` (7 days), `UNITS` (4). On the USDG core `FEE_RECIPIENT()` is the DealFeeRouter, `0xEaE95cD11e1105BF1E82033c918ff17f931B0245`; on a lend-asset core it is its generation's `feeProcessor`.

Loans the private lane opened are ordinary loans on the USDG core. Its router's `opened(id)` returns a nonzero token for them (`0xDbb8e949659D0d0d2EDB075b9eC84C9E479bAA45`, and `intentV1.previousPrivateLanes` for the earlier core). gage's app and API never show them; the chain does.

### Read a core's registry

The registry is the core's `REGISTRY()`. It decides what a new listing may be; nothing in it moves an open loan.

```solidity
function getERC20Config(address token) external view returns (ICollateralRegistry.ERC20Config memory);
// struct ERC20Config { bool allowed; Lane lane; uint256 minAmount; uint256 maxDealRaw; uint256 maxOpenRaw; }
function allowedTerms() external view returns (uint32[] memory);
function isTermAllowed(uint32 term) external view returns (bool);
function feeBps() external view returns (uint16);            // origination fee, bps of the principal
function tradeFeeBps() external view returns (uint16);       // fee on a sale of a reclaim right or of lender quarters
function newDealsPaused() external view returns (bool);      // stops list and fund, nothing else
function isRouter(address account) external view returns (bool);   // may call listFor and fundFor
function rewardTerms(uint32 term) external view returns (uint128 rate, uint128 referencePrice, uint16 lenderShareBps);
function quoteRewards(uint32 term, uint128 fee) external view returns (uint128 borrower, uint128 lender);
```

- **Admission and minimums.** A token may be listed when `allowed` is true and the pledge is at least `minAmount` and at most `maxDealRaw`, with the token's open exposure staying within `maxOpenRaw`, all in the token's raw units. On the USDG core the caps are `type(uint256).max` today, a minimum only; a lend asset's registry may cap a token.
- **Lane.** `lane` is 0 STOCK, 1 ETH or 2 MEME. It is informational: no core reads it.
- **Categories.** What a partner vault may lend against is decided by its factory's classification, `categoryOf(token)` on the generation's `IntentFactory`, returning `(bool classified, IntentCategory category)` with STOCK 0, MEME 1, RH_ECOSYSTEM 2, COMMODITY 3. The factory's owner assigns it once per token (`CategoryAssigned`). See [partner-vaults.md](partner-vaults.md).
- **Terms and fee.** Each term is 1 to 30 days, at most eight of them. The USDG core allows 1, 7 and 21 days today and the lend-asset cores 7 and 21; gage's app and API offer 7 and 21. `feeBps` is 100 (1%) on every current core; at most `MAX_FEE_BPS`, 200. `tradeFeeBps` is at most `MAX_TRADE_FEE_BPS`, 200.
- **Tokens a lend asset lends against.** `intentV1Assets.<SYMBOL>.collateral` names them; its registry is the reference.

### Read the rewards ledger and the cash-out router

The rewards ledger is the core's `REWARDS()`:

```solidity
function allocation(uint256 id) external view returns (Allocation memory);
// struct Allocation { address borrower; uint40 start; uint40 end; uint32 term; uint128 borrowerTotal;
//                     uint128 lenderTotal; uint128 borrowerAccounted; address[4] lenders; }
function claimable(uint256 id, address account) external view returns (uint256);   // sGAGE, 18 decimals
function funderGate() external view returns (IFunderGate);                          // the generation's IntentFactory
function freeBudget() external view returns (uint256);
```

A loan's allocation accrues on a quadratic clock over its term, `total × elapsed² / term²`, and stops at repayment or default. Claims are covered in [rewards.md](rewards.md).

The cash-out router a core's loans sell through is the manifest's `cashoutRouter` of its engine entry. `VAULT()` is its core, `USDG()` the core's asset, `CASHOUT_FEE_BPS()` 50 (0.5%), `MAX_EXECUTION_WINDOW()` 15 minutes; `v4Allowed(poolId)`, `v3Allowed(pool)` and `executorAllowed(executor)` say which sale paths it admits. A `GageV2CashoutRouter` borrows the cap from `FLASH_POOL()`, a Uniswap v3 pool of the asset and WETH; a `V4CashoutRouter` has no `FLASH_POOL()` and borrows it from the Uniswap v4 PoolManager (`POOL_MANAGER()`). The USDG, GLD, NVDA and HIMS cores use `GageV2CashoutRouter`; the frxUSD core uses `V4CashoutRouter`. How to cash out: [borrowing.md](borrowing.md#sell-the-collateral-to-repay-cash-out).

### IntentVaultViews

There is no separate loan-views contract for the cores: read them directly. `IntentVaultViews` is the stateless helper each `IntentFactory` creates for its partner vaults (`SHARE_VIEWS()`). It reads vault state (ERC-4626 maxima, side-pocket claims, reward records, exposure windows), and from the core only `coreLoan(GageV2Vault core, uint256 id)`, a subset of `getLoan`: `account`, `token`, `state`, `term`, `fundingDeadline`, `fundedAt`, `closedAt`, `cap`, `collateral`. Use it for partner vaults ([partner-vaults.md](partner-vaults.md)), not to read loans.

### Batch reads with multicall

Robinhood Chain has the standard Multicall3; viem's `robinhood` chain definition names it, so `client.multicall` needs no address. One multicall can read every core's `loanCount`, `USDG`, `REGISTRY` and `GRACE`, then each core's newest loans by id ([cores-read.ts](../../examples/viem/src/cores-read.ts)).

- Pin a set of reads to one block (`blockNumber`) when they must agree. The public RPC serves state near the head only: an `eth_call` at an old block fails with "historical state is not available". For history, use events.
- Use `allowFailure: true` around `ownerOf(id)`: it reverts with `ERC721NonexistentToken(uint256)` once a loan has closed and its right is burnt.

### Lists from the public API

gage's public API (`https://mcp.gage.cash`, documented at [docs.gage.cash/ai-agents/api](https://docs.gage.cash/ai-agents/api)) serves the lists gage's own agents use, read from the chain and gage's indexer. Private loans are never in them.

| Route | What it lists |
| --- | --- |
| `GET /v1/capabilities` | The USDG core, factory and loop router (`contracts`), the terms, the origination fee, whether new loans are paused, and `lendAssets`: each lend asset's token, decimals, core, factory and terms. |
| `GET /v1/assets` | Every token taken as collateral now: decimals, lane, `minAmount`, `maxPerLoan` (`null` for no per-loan cap) and `asset`, what a loan against it is paid in. |
| `GET /v1/loans/{id}?engine=<core>` | One loan: state, borrower, `reclaimRightHolder`, collateral, principal, repayment, cost, dates, lenders and what can be done now. Without `engine`, the USDG core. |
| `GET /v1/portfolio/{wallet}` | The loans a wallet borrowed or holds the right of, on every core, with their sGAGE and the wallet's credits. |
| `GET /v1/earn/vaults` | The partner vaults ([partner-vaults.md](partner-vaults.md)). |

No route lists every loan of a core. For that, read `loanCount()` and `getLoan(id)` or index the events below.

### Rebuild state from events

1. **Where to start.** A core's events begin at its engine entry's `startBlock`: `nativeV2.engines[i].startBlock` for a USDG core (the current one is the entry whose `engine` is `intentV1.core`), `intentV1Assets.<SYMBOL>.engine.startBlock` for a lend asset's, `intentV1AssetsPrevious.<SYMBOL>[i].entry.engine.startBlock` for an earlier one. A generation's own `startBlock` (`intentV1.startBlock`, `intentV1Assets.<SYMBOL>.startBlock`) is the block its factory was deployed in, where its partner vaults' events start. Each registry was deployed and configured before its core, and the manifest records no block for it: on mainnet today its first events are up to about 1,000 blocks before the core's `startBlock`, so start a registry scan 2,000 blocks earlier.
2. **Ranges.** The public RPC serves `eth_getLogs` for one address over at most 10,000,000 blocks per request: page through longer spans.
3. **Loans.** Replay the core's events in order (below). `Listed` opens the record; each `UnitsFunded` fills the lowest empty quarters in slot order, so replaying them in order rebuilds `lenders(id)`; `Activated` sets `fundedAt`, the fee and the rewards; `Closed` sets the final state, `closedAt` and the collateral beneficiary; `LenderSplitSold` moves the sold quarters to their recipients; ERC-721 `Transfer` moves the reclaim right (mint at listing, sale, burn at close).
4. **Credits.** They follow from the same events: at `Activated` the originator is credited `principal − fee` (and, on a core without an adapter, `FEE_RECIPIENT` the fee); at `Closed(REPAID)` each lender its quarter of the cap; at `CommitmentWithdrawn` and `Closed(CANCELLED)` each lender its quarter of the principal; at `RightSold` and `LenderSplitSold` the seller the price less the fee. A withdrawal (`withdrawUSDG`, `withdrawUSDGFor`) emits no core event: read `cashCredit(account)`, or follow the asset's `Transfer` from the core.
5. **Registry settings.** Replay `ERC20Set`, `TermsSet`, `FeeSet`, `TradeFeeSet`, `NewDealsPausedSet`, `RouterSet` and `RewardTermsSet`, or read the views at the head.

## Events to index

On each core (`GageV2Vault`):

```solidity
event Listed(uint256 indexed id, address indexed borrower, address account, Collateral collateral, uint128 principal, uint128 cap, uint32 term, uint40 fundingDeadline);
event UnitsFunded(uint256 indexed id, address indexed lender, uint8 units, uint256 amount, uint8 filled);
event CommitmentWithdrawn(uint256 indexed id, address indexed lender, uint8 units, uint256 amount);
event Activated(uint256 indexed id, uint40 fundedAt, uint128 fee, uint128 borrowerReward, uint128 lenderReward);
event Closed(uint256 indexed id, V2State state, address beneficiary, uint40 closedAt);
event AskPosted(uint256 indexed id, address indexed seller, uint128 price, uint40 deadline, uint16 feeBps, uint256 nonce);
event AskCancelled(uint256 indexed id, uint256 nonce);
event RightSold(uint256 indexed id, address indexed seller, address indexed buyer, address recipient, uint128 price, uint256 fee, uint256 nonce);
event CollateralWithdrawn(uint256 indexed id, address indexed recipient);
event DefaultRecovered(uint256 indexed id, address[2] tokens, uint256[2] amounts);
event RecoveryWithdrawn(uint256 indexed id, address indexed lender, uint8 asset, address recipient, uint256 amount);
event LenderAskPosted(uint256 indexed id, address indexed seller, uint8 slots, uint128 price, uint40 deadline, uint16 feeBps, uint256 nonce);
event LenderSplitSold(uint256 indexed id, address indexed seller, address indexed buyer, uint8 slots, uint128 price, uint256 fee, uint256 nonce, address[4] recipients);
// ERC-721, the reclaim right:
event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
```

- `Listed`: a new loan in FUNDING. `Collateral` is `(uint8 kind, address token, uint256 amountOrTokenId)`, so the topic is `keccak256("Listed(uint256,address,address,(uint8,address,uint256),uint128,uint128,uint32,uint40)")`.
- `UnitsFunded`: `units` quarters bought by `lender` for `amount`; `filled` is the new total.
- `Activated`: the loan is ACTIVE; `fee` is the origination fee.
- `Closed`: `state` is REPAID (3, `beneficiary` the reclaim recipient), DEFAULTED (4, `beneficiary` zero) or CANCELLED (5, `beneficiary` the originator).
- `CollateralWithdrawn`, `DefaultRecovered`, `RecoveryWithdrawn`: the collateral leaving its account, to the borrower's side or to the lenders.

On each registry (`GageV2TokenRegistry`; the first five are declared in `ICollateralRegistry`):

```solidity
event ERC20Set(address indexed token, bool allowed, Lane lane, uint256 minAmount, uint256 maxDealRaw, uint256 maxOpenRaw);
event TermsSet(uint32[] terms);
event FeeSet(uint16 bps);
event NewDealsPausedSet(bool paused);
event RouterSet(address indexed router, bool allowed);
event RewardTermsSet(uint32 indexed term, uint128 rate, uint128 referencePrice, uint16 lenderShareBps);
event TradeFeeSet(uint16 feeBps);
```

On each rewards ledger (`GageV2Rewards`):

```solidity
event Funded(address indexed funder, uint256 amount);
event Claimed(uint256 indexed id, address indexed account, address indexed recipient, uint256 amount);
event FunderGateBound(address indexed gate);
```

On the factory (`IntentFactory`), for categories: `event CategoryAssigned(address indexed token, IntentCategory category);`. On the fill router, one per funded listing: `event Filled(bytes32 indexed digest, uint256 indexed listingId, address indexed filler, uint40 activatedAt, uint256 principal, uint256 executionFee, address protocolRecipient);` ([fills.md](fills.md)). The routers' events are on [borrowing.md](borrowing.md#events-to-index).

## Errors you will meet

Reads rarely revert, but these do:

- `ERC721NonexistentToken(uint256 tokenId)` from `ownerOf(id)` on a closed or never-issued loan.
- "historical state is not available" from the public RPC for an `eth_call` at an old block, and a range error from `eth_getLogs` over more than 10,000,000 blocks.
- A read through the wrong ABI: an earlier engine shares the loan views on this page, but the newer sale functions (`setLenderAsk`, `buyLenderSplit`) exist only on some engines. Check the source of the engine you call.

The errors a write meets are on [borrowing.md](borrowing.md#errors-you-will-meet).

## Examples

- Foundry: [Reading.t.sol](../../examples/foundry/test/Reading.t.sol). Finds the cores from the manifest and checks each against its own immutables, reads the latest loan of the USDG core, the NVDA core and the earlier USDG core, and reads a token's admission and the terms on two registries.

  ```solidity
  ICore core = ICore(addressOf("intentV1.core"));
  uint256 id = core.loanCount();
  V2Loan memory l = core.getLoan(id);
  console.log("repayment closes at", uint256(l.fundedAt) + l.term + core.GRACE());
  ERC20Config memory cfg = IRegistry(core.REGISTRY()).getERC20Config(addressOf("WETH"));
  ```

- viem: [cores-read.ts](../../examples/viem/src/cores-read.ts). Lists every core, current and earlier, in one multicall, then each core's newest loans and the open cores' terms, fee and pause.

  ```ts
  const loans = await client.multicall({
    allowFailure: false,
    contracts: ids.map((id) => ({address: core, abi: coreAbi, functionName: "getLoan", args: [id]} as const)),
  });
  ```

## What not to rely on

- **A price.** No core reads one. A loan's outcome depends on the clock and the borrower's choice alone.
- **The originator being the right's holder.** The reclaim right can be sold (`buy`); read `ownerOf(id)` while the loan is open.
- **A loan id meaning one loan.** Ids restart on every core. Always key by (core, id).
- **One core forever.** A new generation adds a core and moves the manifest keys; the previous one moves to `intentV1Previous` or `intentV1AssetsPrevious`. Read the manifest at each start, not a copied address; do not hard-code an index in `nativeV2.engines` for the current core.
- **The registry's settings for an open loan.** They gate new listings and fundings only. A loan keeps the fee, terms and cap it was listed with.
- **Withdrawal events.** The cores emit none for `withdrawUSDG`; credits are a view.
- **The services for settlement.** Every read here needs only the chain. gage's API and indexer are conveniences, and lists can trail the chain by moments.
