# Borrowing and lending against a core

A wallet or a contract borrows by listing collateral on a core (`GageV2Vault`): it approves the token, calls `list` with its terms, and the loan waits for the partner vaults. gage's keeper funds it whole, through the generation's fill router, on a plan gage's rates service signs; otherwise it stays unfunded until its funding deadline and the borrower takes the collateral back. A funded loan runs for a fixed term at a fixed cost. No liquidation: nothing can touch the collateral before the end of the term. Before it ends, the holder of the loan's reclaim right repays the cap and withdraws the collateral, or sells the collateral to repay through the cash-out router; if the cap is not paid by the end, the lenders keep the collateral. This page gives each call with its exact parameters, plus leverage through the LoopRouter and the private borrow router. Lending does not go through `fund`: see [Lending](#lending).

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| USDG core (`GageV2Vault`) | `0x0086EC1540719d4199432797e2b6068E6aE5a0e5` | [GageV2Vault.sol](../../src/v2/GageV2Vault.sol) | [GageV2Vault.json](../../abi/GageV2Vault.json) | Nobody: no owner, no upgrade. |
| Lend-asset cores (`GageV2Vault`) | GLD `0x1E8bd7348C84Ab0A0faBE61DCA1249f75B4e9275`, NVDA `0xe0dDd6869677d3F5A2BC48375FC899B10A6848E1`, HIMS `0xc64C71f1A989E1830948D1ADCB43a2b5f5a8DbA1` | [GageV2Vault.sol](../../src/v2/GageV2Vault.sol) | [GageV2Vault.json](../../abi/GageV2Vault.json) | Nobody. Loans are paid out and repaid in the core's asset, its `USDG()`. |
| Registries (`GageV2TokenRegistry`) | USDG `0x732fB25C6905d0cbeB639F1226398aB317189bA0`; GLD, NVDA, HIMS `intentV1Assets.<SYMBOL>.engine.registry`; each core's `REGISTRY()` | [GageV2TokenRegistry.sol](../../src/v2/GageV2TokenRegistry.sol) | [GageV2TokenRegistry.json](../../abi/GageV2TokenRegistry.json) | Its owner (`owner()`, `Ownable2Step`), a Safe gage controls. Gates new listings and fundings only. |
| Rewards ledgers (`GageV2Rewards`) | USDG `0x614E087972d49DFe6FEDbaC1333192313aF36aD9`; each core's `REWARDS()` | [GageV2Rewards.sol](../../src/v2/GageV2Rewards.sol) | [GageV2Rewards.json](../../abi/GageV2Rewards.json) | Nobody. Its funder gate, bound once, decides who may lend. |
| Cash-out routers (`GageV2CashoutRouter`) | USDG `0xFA91Ee9221300E034916400DA4c4Fc556633aE15`; GLD `0x2d89e340e2ef83729fb6Dc9da61E425fa0e46D70`, NVDA `0xF30ad2ED957e74d36774168c63DfC43C8B025e91`, HIMS `0xf092DA59586b0bBDF9eb9B9C68234887C83eD473` | [GageV2CashoutRouter.sol](../../src/v2/GageV2CashoutRouter.sol) | [GageV2CashoutRouter.json](../../abi/GageV2CashoutRouter.json) | Its owner, a Safe gage controls: admits sale routes and executors, names the one-day keeper and price source. |
| frxUSD cash-out router (`V4CashoutRouter`) | `0xB7d2861e0269941e552E1eBa1cA195044516Cf2e` | [V4CashoutRouter.sol](../../src/intent/V4CashoutRouter.sol) | [V4CashoutRouter.json](../../abi/V4CashoutRouter.json) | Its owner: admits sale routes and executors. |
| `LoopRouter` (USDG) | `0xa46B62d5277465A885De5f2dc518d369199AA93c` | [LoopRouter.sol](../../src/loop/LoopRouter.sol) | [LoopRouter.json](../../abi/LoopRouter.json) | Its owner, a Safe gage controls: pauses new loops, admits executors. Never touches an open loan. |
| `LoopRouter` (NVDA) | `0xe5A69a1DEd8437bbFDe19263B626aAE4Ec1f09cf` | [LoopRouter.sol](../../src/loop/LoopRouter.sol) | [LoopRouter.json](../../abi/LoopRouter.json) | As above, on the NVDA core. |
| `PrivateBorrowRouter` | `0xDbb8e949659D0d0d2EDB075b9eC84C9E479bAA45` | [PrivateBorrowRouter.sol](../../src/private/PrivateBorrowRouter.sol) | [PrivateBorrowRouter.json](../../abi/PrivateBorrowRouter.json) | Its owner, a Safe gage controls: the screener's attester key and per-token caps. |
| Fill router (`IntentFillRouter`, USDG) | `0xAE9607acb7e14bD37cB714cFf8f35B30443133c8`; each lend asset's `intentV1Assets.<SYMBOL>.fillRouter` | [IntentFillRouter.sol](../../src/intent/IntentFillRouter.sol) | [IntentFillRouter.json](../../abi/IntentFillRouter.json) | Nobody. Fills only for a filler its factory admits, on a plan its quote verifier accepts ([fills.md](fills.md)). |

## How it works

```
list ──▶ FUNDING ──(fill: all four quarters, one transaction)──▶ ACTIVE ──(reclaim before the end)──▶ REPAID ──▶ withdrawCollateral
            │                                                       │
            └──(cancelFunding)──▶ CANCELLED ──▶ withdrawCollateral   └──(finalizeDefault, from the end)──▶ DEFAULTED: the lenders keep the collateral
```

- **Listing escrows the collateral.** `list` moves exactly the pledged amount into a new account for this loan and mints the reclaim right (ERC-721, token id = loan id) to the borrower. No USDG moves yet.
- **Only partner vaults fund.** The core asks its rewards ledger before it records any lender: once its funder gate is bound, only the generation's partner vaults (`IntentFactory.isVault`) may take a quarter. They buy only through the fill router, which takes all four quarters in one transaction on a plan signed by gage's rates service and submitted by an admitted filler. gage's keeper is that filler for ordinary listings; gage's loop, private and rollover routers fill the loans they open themselves, in the same transaction. If no partner vault's rules take the listing, nothing funds it.
- **Funding pays the borrower by credit.** On the fourth quarter the loan is ACTIVE, `fundedAt` is set and the borrower's `cashCredit` grows by the principal less the origination fee (1% today). The borrower withdraws it.
- **The reclaim right is the repayment right.** Its holder, or an account it approves, may repay. It moves only by sale on the core (`setAskWithMaxFee`, `buy`); `transferFrom` and both `safeTransferFrom` revert `UseMarketplace()`.
- **The end of the term.** At `fundedAt + term + GRACE` repayment closes and default finalization opens, in the same second. `GRACE()` is 0 on every current core, so that is the end of the term.
- **Pull, never push.** Principal, refunds and repayments are credits; collateral waits in its account until its beneficiary withdraws it.

## Call sequences

### Borrow

1. **Pick terms partner vaults fund.** A listing is funded only if a partner vault's rules accept its exact collateral, principal, cap and term. gage's public API quotes them: `GET https://mcp.gage.cash/v1/borrow-quote?token=<token>&term=<seconds>&maxCollateral=<raw>` answers the largest loan the vaults fund whole now (`principal`, `repay`, `costBps`, `expiresAt`), and with `collateral` and `principal` it prices one exact loan. `POST https://mcp.gage.cash/v1/prepare` with `{"action":"borrow","wallet":…,"token":…,"collateral":…,"principal":…,"cap":…,"term":…}` returns the unsigned approval and listing ([docs.gage.cash/ai-agents/transactions](https://docs.gage.cash/ai-agents/transactions)). gage-sdk prepares the same calls.
2. **Check the core's own rules** on its registry (`REGISTRY()`, see [reading.md](reading.md#read-a-cores-registry)): `newDealsPaused()` false; `getERC20Config(token).allowed`, and the pledge within `minAmount` and `maxDealRaw`; `openExposure(keccak256(abi.encode(uint8(0), token))) + amount <= maxOpenRaw` on the core; `isTermAllowed(term)`.
3. **Approve the collateral** to the core, for exactly the pledge: `IERC20(token).approve(core, amount)`. The core pulls with `transferFrom` and checks the account received exactly `amount`, so a fee-on-transfer token reverts.
4. **List:**

   ```solidity
   function list(
       Collateral calldata c,       // (Kind kind, address token, uint256 amountOrTokenId): kind 0 (ERC-20), the token, the raw amount
       uint128 principal,           // what the lenders fund, raw units of the core's asset (USDG: 6 decimals; GLD, NVDA, HIMS: 18)
       uint128 cap,                 // what repaying takes, same units: principal + the fixed cost for the term
       uint32 term,                 // seconds from funding; one of allowedTerms()
       uint40 fundingDeadline,      // unix seconds: after now, at most now + MAX_FUNDING_WINDOW (7 days)
       bool withRewards
   ) external returns (uint256 id);
   ```

   - `principal >= 4` and `cap >= principal`. A cap equal to the principal is accepted on chain, but it pays the lenders nothing; gage's app and gage-sdk never list one. The fixed cost is `cap − principal`, shown as an amount and a percent of the principal for the term: `0.50 USDG, 0.50% for 7 days`.
   - gage's app and API set the funding deadline 24 hours out.
   - `withRewards`: pass `false`, as gage-sdk does on every current core. On the USDG core the adapter allocates the loan's sGAGE at funding whatever this says; `true` there only records the listing-time quote as a floor, and a funding that would allocate less reverts. On a lend-asset core, `true` asks the registry's quote and the funding reverts `InsufficientBudget()` when its ledger's `freeBudget()` cannot pay it.
   - The fee is fixed at listing: `originationFee = principal × feeBps / 10,000`, from the registry's `feeBps()` at that moment.
   - The reclaim right is minted with `_safeMint`: a contract borrower must implement `IERC721Receiver.onERC721Received`, or `list` reverts `ERC721InvalidReceiver(address)`.
   - The id is `loanCount()` after the call, and the `Listed` event's `id`.
5. **Wait.** Read `getLoan(id).state`, or watch for `Activated(id, …)`. Partner vaults can fund it until `fundingDeadline`; from that second `fund` reverts `Deadline()`. A listing is not closed by itself: past its deadline it stays FUNDING, collateral in escrow, until someone calls `cancelFunding`.
6. **Collect the principal** once ACTIVE. It is credited to the originator: `withdrawUSDG(address recipient)`, called by the originator, pays its whole `cashCredit` on that core, in the core's asset. `withdrawUSDGFor(address account)` lets anyone deliver an account's credit to that same account.

### Cancel an unfunded listing

```solidity
function cancelFunding(uint256 id) external;
function withdrawCollateral(uint256 id, address recipient) external;
```

1. `cancelFunding(id)` while the loan is FUNDING: the originator at any time, anyone from `fundingDeadline`. Every lender quarter already bought is credited back to its lender (on these cores there are none: fills are whole). The state becomes CANCELLED, `collateralBeneficiary` the originator, and the right is burnt.
2. `withdrawCollateral(id, recipient)`, called by the `collateralBeneficiary`, sends the whole collateral to `recipient`.

A funded loan cannot be cancelled; repay it instead.

### Repay and take the collateral back

```solidity
function reclaim(uint256 id, address recipient) external;
```

1. Read `getLoan(id)`: state ACTIVE and `block.timestamp < fundedAt + term + GRACE`. The deadline is exclusive: at that second `reclaim` reverts `Deadline()`. Repay early; a sequencer outage in the last hours can block the transaction.
2. Approve the core's asset to the core for exactly `cap`, from the account that will call: `IERC20(core.USDG()).approve(core, cap)`. On a lend-asset core this is the lend asset, NVDA on the NVDA core.
3. Call `reclaim(id, recipient)` as the right's holder (`ownerOf(id)`) or an account it approved (`approve(operator, id)` or `setApprovalForAll`). The core pulls exactly the cap from the caller, credits each lender its quarter of it, closes the loan as REPAID and makes `recipient` the collateral beneficiary.
4. `recipient` calls `withdrawCollateral(id, to)`. If a contract repays with `recipient` set to another account, that account must make this call.

Partial repayment does not exist: the whole cap, or nothing.

### The end of the term

```solidity
function finalizeDefault(uint256 id) external;
```

From `fundedAt + term + GRACE`, anyone may call `finalizeDefault(id)`: the loan is DEFAULTED and the lenders keep the collateral. The borrower keeps the principal it received and owes nothing else. Then one lender records the recovery (`recoverDefault(id, min0, min1, deadline)`) and each lender withdraws its share (`withdrawRecovery(id, asset, recipient)`); on these cores the lenders are partner vaults, whose `settle` does it ([partner-vaults.md](partner-vaults.md)).

### Claim the loan's sGAGE

On the core's rewards ledger (`REWARDS()`): `claimable(uint256 id, address account)` and `claim(uint256 id, address recipient)`. The borrower's side accrues to the right's holder; a sale moves only what is still to accrue. On the USDG core a claim is paid through the adapter, which may pay part now and the rest later. See [rewards.md](rewards.md).

### Sell the reclaim right

The holder may post an ask in the core's asset while the loan is ACTIVE and before its end: `setAskWithMaxFee(uint256 id, uint128 price, uint40 deadline, uint16 maxFeeBps)` (the ask's fee is the registry's `tradeFeeBps()` at posting, refused above `maxFeeBps`; `deadline` at most the loan's end), `cancelAsk(uint256 id)`. A buyer approves `price` to the core and calls `buy(uint256 id, address seller, uint256 nonce, uint128 price, uint16 maxFeeBps, address recipient)`, with `nonce` and `price` read from `getAsk(id)`. The seller is credited the price less the fee; sGAGE already earned stays with the seller.

### Sell the collateral to repay: cash-out

The cash-out router repays a running loan from a flash loan of its cap, sells the whole collateral, repays the flash loan and pays the holder what is left, less a 0.5% fee (`CASHOUT_FEE_BPS` = 50) on the remainder after the cap and the flash fee, to the core's `FEE_RECIPIENT()`. All of it happens in one transaction, or nothing does. It closes the loan as repaid; no collateral comes back.

Which router: a generation's cash-out router is its engine entry's `cashoutRouter` in the manifest (for a generation not in the manifest yet, its `GenerationDeployed` event). The USDG, GLD, NVDA and HIMS cores use `GageV2CashoutRouter`, which borrows the cap from `FLASH_POOL()`, a Uniswap v3 pool of the asset and WETH, for that pool's fee. The frxUSD core uses `V4CashoutRouter`, which takes it from the Uniswap v4 PoolManager inside one `unlock`, with no flash fee. Tell them apart by `FLASH_POOL()`: only `GageV2CashoutRouter` has it.

1. **Approve the reclaim right** to the router, for this loan: `core.approve(router, id)`. No USDG approval is needed.
2. **Call as the right's holder** (`ownerOf(id) == msg.sender`), while the loan is ACTIVE and before its end. Both entries return `(uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net)` and can be run first as an `eth_call` to read the outcome.

**`cashOutVia`**, through an aggregator's router the owner admits (KyberSwap's routers on mainnet):

```solidity
function cashOutVia(ExitVia calldata exit) external returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net);

struct ExitVia {
    uint256 loanId;
    address recipient;      // not zero, not the router
    uint256 minimumNet;     // the least the recipient accepts, raw units of the core's asset; must be > 0
    uint256 maxFinanceFee;  // the most the flash loan may charge
    uint256 deadline;       // unix seconds, from now to now + MAX_EXECUTION_WINDOW (15 minutes)
    address executor;       // executorAllowed(executor) must be true
    bytes data;             // the call made on the executor
    address flashToken;     // with flashFee: the V3 factory pool of the asset, flashToken and flashFee lends the cap
    uint24 flashFee;
    uint256 minUsdgOut;     // the least of the asset the sale must return to the router
}
```

- The executor's call must take exactly the loan's whole collateral from the router (`transferFrom`) and pay the core's asset to the router. Build it as a KyberSwap swap of `collateral` of `token` for the asset, with the router as recipient; every unit must be sold.
- Pick a lending pool the swap route does not use: a pool cannot be swapped through while it lends.
- The flash fee is `ceil(cap × flashFee / 1,000,000)`; set `maxFinanceFee` to it.
- Slippage: `minUsdgOut` bounds the swap, `minimumNet` what you receive. gage-sdk sets `minimumNet` at most 0.5% under the quoted net by default.
- A loan whose collateral is the core's asset itself (USDG pledged on the NVDA core) reverts `InvalidExit()`: repay it instead.

**`cashOutDetailed`**, through routes the owner admits, up to `MAX_ROUTES` (8):

```solidity
function cashOutDetailed(Exit calldata exit) external returns (uint256 gross, uint256 financeFee, uint256 platformFee, uint256 net);

struct Exit {
    uint256 loanId;
    address recipient;
    uint256 minimumNet;
    uint256 maxFinanceFee;
    uint256 minUnderlying0;  // ignored on the token-only cores
    uint256 minUnderlying1;  // ignored on the token-only cores
    uint256 deadline;        // at most 15 minutes ahead
    Route[] routes;
}
struct Route {
    RouteKind kind;          // 0 V4, 1 V3, 2 UNWRAP_WETH
    address tokenIn;
    address tokenOut;
    uint24 v3Fee;            // V3: the pool's fee tier
    PoolKey key;             // V4: the pool's key; v4Allowed(keccak256(abi.encode(key))) must be true
    uint256 minOut;          // > 0: the least this hop returns
}
```

Each route sells the router's whole balance of `tokenIn` gained in the sale; every non-asset token must be consumed by the end, or it reverts `InvalidExit()`. A V3 route's pool must be `v3Allowed`, never the flash pool.

`V4CashoutRouter` keeps `cashOutDetailed(Exit)` with the same encoding (`maxFinanceFee` ignored, `financeFee` always 0), and its `cashOutVia` takes `ExitVia(uint256 loanId, address recipient, uint256 minimumNet, uint256 deadline, address executor, bytes data, address tokenOut, uint256 minOut, Route[] tail)`: the executor pays `tokenOut`, and the admitted routes in `tail` finish the sale into the asset.

**One-day loans.** For a loan of exactly one day (`ONE_DAY_TERM`), the same approval also lets the router's keeper, gage's keeper, sell it for the holder in the last 15 minutes before repayment closes (`settleOneDay`, `settleOneDayVia`), paying the net to the holder. The sale must return at least `floorBps()` of the collateral's value from an independent price source (`priceSource()`, `0xbF042AE7216Ed5176790e19F463DbAB878f5caE8` on the USDG router): 98% today, never under 95% (`MIN_FLOOR_BPS`).

### Leverage: LoopRouter

The LoopRouter opens one loan whose collateral is the borrower's own tokens plus tokens the loan itself buys, in one transaction: it buys an exact amount of the token with the core's asset it does not yet have, lists the whole pledge for the borrower (`listFor`), funds all four quarters through the fill router on a signed plan, pays the principal out to the borrower and takes the purchase's cost back. The result is one ordinary loan, owned by the caller, with one cap and one end. If any part fails, nothing moves.

```solidity
function loop(Loop calldata l, IntentQuoteVerifier.Plan calldata plan, bytes calldata signature, uint256[] calldata maxReserveShares)
    external returns (uint256 id, uint256 cost);      // a hookless Uniswap v4 pool
function loopV3(LoopV3 calldata l, IntentQuoteVerifier.Plan calldata plan, bytes calldata signature, uint256[] calldata maxReserveShares)
    external returns (uint256 id, uint256 cost);      // the V3 factory's pool of the token, the asset and l.fee
function loopVia(LoopVia calldata l, IntentQuoteVerifier.Plan calldata plan, bytes calldata signature, uint256[] calldata maxReserveShares)
    external returns (uint256 id, uint256 cost);      // an executor the owner admits (KyberSwap's routers), with the asset flash-borrowed

struct Loop {
    PoolKey key;            // a pool pairing the asset with the plan's token, no hooks
    uint256 own;            // the borrower's own tokens, raw units; may be 0
    uint256 buy;            // tokens bought, exactly; > 0
    uint256 maxCost;        // the most the purchase may cost, raw units of the core's asset
    uint40 fundingDeadline;
    bool withRewards;
    bytes32 pricing;        // the rates service's pricing commitment
}
// LoopV3 replaces `key` with `uint24 fee`. LoopVia replaces it with `address executor, bytes data, address flashToken,
// uint24 flashFee, uint256 spend` (spend: the asset the executor may take), and its `buy` is the least the executor must
// return; the surplus goes to the borrower. Its `maxCost` bounds what the executor spent plus the flash fee.
```

1. **Get the plan from gage.** The plan and its signature come from gage's rates service: it names this router as filler, the id the core will issue next, the terms, and `evidence = keccak256(abi.encode(borrower, pricing))`, so it funds no other wallet and no other listing. It lives 30 seconds. gage's public API quotes and prepares the whole call: `GET https://mcp.gage.cash/v1/leverage-quote?token=&own=&multiple=&term=` then `POST /v1/prepare` with `{"action":"leverage", …, "maxCostBps": …}`; gage-sdk does the same.
2. **Approve the router** for `own` of the token and for `maxCost` of the core's asset. The router pays the borrower's whole credit on the core out to the borrower (`withdrawUSDGFor`), then takes the purchase's cost from the borrower's wallet; your wallet needs no USDG of its own when the principal less the fee covers the cost.
3. **Call** `loop`, `loopV3` or `loopVia` from the borrower. `plan.collateral` must equal `own + buy`. If another listing takes the planned id first, it reverts `ListingMismatch` and nothing moves: ask for a new plan.

gage's app offers leverage on USDG loans only. NVDA's generation has a LoopRouter of its own (`0xe5A69a1DEd8437bbFDe19263B626aAE4Ec1f09cf`), the same contract on the NVDA core: its `USDG()` is NVDA, so the principal, the purchase and `maxCost` are in NVDA, and it buys a token the NVDA core admits with NVDA. gage uses it to open puts on NVDA ([puts.md](puts.md)).

### Borrow privately: PrivateBorrowRouter

The private lane lets a borrower pledge a piece of a screened Privacy Pools deposit without the loan pointing to the wallet that deposited it. In one transaction the router withdraws that piece from the pool the Privacy Pools Entrypoint (`0xde0140E41656aB6BB8D5a5a86f6c12e0f8a23C58`) registers for the token, lists it on the USDG core for the borrower the withdrawal proof names (`listFor`), and funds it on a signed plan.

```solidity
function borrow(
    IPrivacyPool pool,
    IPrivacyPool.WithdrawProof calldata proof,     // names this router as processooor and abi.encode(terms) as data
    Terms calldata terms,                          // (address borrower, uint128 principal, uint128 cap, uint32 term, uint40 fundingDeadline, bool withRewards)
    RootAttestation calldata attestation,          // the attester's EIP-712 statement that the association-set root is current, at most 2 minutes long
    IntentQuoteVerifier.Plan calldata plan,        // signed by gage's rates service for this router and the next id
    bytes calldata planSignature,
    uint256[] calldata maxReserveShares
) external returns (uint256 id);
```

- The proof binds the borrower and the terms, so anyone may submit the call. The proof's withdrawn value is the collateral.
- Besides the proof it needs a signed attestation from the router's `attester()` that the root is the Entrypoint's latest, a plan from gage's rates service, and room under the token's cap: `tokenCap(token)` minus `openPrincipal(token)`, in USDG raw units, at most `MAX_TOKEN_CAP` (10,000,000 USDG). A token without a cap is closed (`TokenClosed()`); gage opens only memecoins and Robinhood Chain ecosystem tokens that have a pool, never Stock Tokens.
- The loan is then an ordinary loan of `terms.borrower`, repaid and withdrawn as above. `opened(id)` marks it; `release(uint256[] ids)`, callable by anyone, returns a closed loan's principal to its token's cap.

## Lending

On these cores only partner vaults lend. `fund(uint256 id, uint8 units)` exists, but the core first asks its rewards ledger, whose funder gate is the generation's `IntentFactory`: any account that is not one of its partner vaults gets `NotFunder()`. The partner vaults buy only through the fill router, on plans gage's rates service signs and an admitted filler submits. So a wallet or a contract lends by depositing into a partner vault (`deposit(assets, minShares)`, later `redeem(shares, minAssets)`), which lends across many loans within its manager's mandate: see [partner-vaults.md](partner-vaults.md). You may end up holding the collateral instead of USDG; in a lend-asset generation, the collateral instead of the asset you lent.

The earlier engines (`nativeV2.engines` other than `intentV1.core`, `intentV1Previous`, `intentV1AssetsPrevious`) take no new loans: their registries pause new listings and funding, and `list` reverts `Paused()`. Their loans still repay, cancel, default and withdraw as above.

## Events to index

On the core (the full list, with what each means, is on [reading.md](reading.md#events-to-index)):

```solidity
event Listed(uint256 indexed id, address indexed borrower, address account, Collateral collateral, uint128 principal, uint128 cap, uint32 term, uint40 fundingDeadline);
event Activated(uint256 indexed id, uint40 fundedAt, uint128 fee, uint128 borrowerReward, uint128 lenderReward);
event Closed(uint256 indexed id, V2State state, address beneficiary, uint40 closedAt);
event CollateralWithdrawn(uint256 indexed id, address indexed recipient);
event AskPosted(uint256 indexed id, address indexed seller, uint128 price, uint40 deadline, uint16 feeBps, uint256 nonce);
event AskCancelled(uint256 indexed id, uint256 nonce);
event RightSold(uint256 indexed id, address indexed seller, address indexed buyer, address recipient, uint128 price, uint256 fee, uint256 nonce);
```

`withdrawUSDG` emits no core event: read `cashCredit(account)`, or the asset's `Transfer` from the core.

On the cash-out routers:

```solidity
// GageV2CashoutRouter
event CashedOut(uint256 indexed loanId, address indexed owner, address indexed recipient, uint256 gross, uint256 cap, uint256 financeFee, uint256 platformFee, uint256 net);
event SoldVia(uint256 indexed loanId, address indexed executor, address indexed lender, uint256 sold, uint256 usdgOut, uint256 financeFee);
event SettledOneDay(uint256 indexed loanId, address indexed keeper, address indexed source, uint256 value, uint256 observedAt, uint256 floor);
// V4CashoutRouter: the same CashedOut (financeFee always 0), and
event SoldVia(uint256 indexed loanId, address indexed executor, address indexed tokenOut, uint256 sold, uint256 amountOut);
```

`CashedOut` closes every cash-out with its payout; `SoldVia` precedes it for an aggregator sale; `SettledOneDay` precedes it for a keeper settlement of a one-day loan.

On the LoopRouter:

```solidity
event Looped(uint256 indexed id, address indexed borrower, address indexed token, uint256 own, uint256 bought, uint256 cost, uint128 principal, uint128 cap, uint32 term);
event BoughtVia(uint256 indexed id, address indexed executor, address flashPool, uint256 spent, uint256 flashFee, uint256 surplus);
```

On the PrivateBorrowRouter:

```solidity
event PrivateBorrow(uint256 indexed id, address indexed borrower, address indexed token, uint256 collateral, uint128 principal, uint128 cap, uint32 term);
event Released(uint256 indexed id, address indexed token, uint128 principal);
```

On the rewards ledger: `event Claimed(uint256 indexed id, address indexed account, address indexed recipient, uint256 amount);`.

## Errors you will meet

The core (`GageV2Vault`), in the order `list` checks them:

| Error | When |
| --- | --- |
| `Paused()` | The registry pauses new loans (`list`, `fund`). Nothing else pauses. |
| `InvalidTerms()` | `principal < 4`, `cap < principal`, or a term the registry does not allow; at funding, a term the registry dropped since. |
| `Deadline()` | `list`: `fundingDeadline` not after now or more than 7 days out. `fund`: from the funding deadline. `reclaim`, `setAskWithMaxFee`, `buy`: from the end of the term. `finalizeDefault`: before it. |
| `InvalidCollateral()` | Not an ERC-20, the zero token or sGAGE, not admitted, under `minAmount` or over `maxDealRaw`. |
| `ExposureCap()` | The token's open exposure would pass `maxOpenRaw`, at listing or at funding. |
| `ExactTransferRequired()` | The token delivered other than the exact amount (fee-on-transfer, rebasing). |
| `WrongState()` | The call does not fit the loan's state: `cancelFunding` after funding, `reclaim` on a closed loan, `finalizeDefault` twice. |
| `NotAuthorized()` | `cancelFunding` by another account before the deadline; `reclaim` by an account neither holding nor approved for the right; `withdrawCollateral` by anyone but the beneficiary; `listFor` and `fundFor` by a non-router. |
| `InvalidRecipient()` | A zero recipient, or the core itself. |
| `NothingToClaim()` | `withdrawUSDG` with no credit; `withdrawRecovery` with nothing owed. |
| `UseMarketplace()` | Any `transferFrom` or `safeTransferFrom` of a reclaim right. |
| `StaleAsk()` | `buy` with a nonce, price or fee that no longer matches the ask. |
| `InvalidUnits()` | `fund` with 0 or more units than are left. |

From elsewhere on the same path: `NotFunder()` from the rewards ledger when a wallet calls `fund`; `ERC721InvalidReceiver(address)` when a contract borrower cannot receive the right; `ERC721NonexistentToken(uint256)` from `ownerOf` on a closed loan; the token's own allowance error when the approval is short (WETH reverts with "ERC20: insufficient allowance").

Cash-out routers: `InvalidExit()` (caller not the holder, a bad recipient, a zero `minimumNet`, a deadline outside 15 minutes, too many or unadmitted routes, a loan not ACTIVE, collateral equal to the asset, a token left unsold), `InvalidExecutor()` (executor not admitted), `InsufficientOutput()` (net under `minimumNet`, a hop under its `minOut`, a flash fee over `maxFinanceFee`, a sale that cannot cover the cap), `BadCallback()`; the core's `NotAuthorized()` if the right is not approved to the router, and `Deadline()` once the term has ended.

LoopRouter: `NothingToBuy()`, `CollateralMismatch(uint256 planned, uint256 looped)`, `NotBorrowersPlan()` (the plan was signed for another wallet), `InvalidPool()`, `InvalidExecutor()`, `PartialPurchase(uint256 bought, uint256 wanted)`, `TooExpensive(uint256 cost, uint256 maxCost)`, `InexactTransfer(uint256 expected, uint256 received)`, `ListingMismatch(uint256 listed, uint256 planned)`, `StrayBalance()`, `EnforcedPause()` while new loops are paused; and the quote verifier's `Refused(Refusal reason)` for an expired, used or mismatched plan ([fills.md](fills.md)).

PrivateBorrowRouter: `AttesterDisabled()`, `TokenClosed()`, `CapExceeded(uint256 open, uint256 cap)`, `UnknownPool()`, `AttestationRootMismatch()`, `AttestationTokenMismatch()`, `AttestationNotCurrent()`, `AttestationTooLong()`, `BadAttestation()`, `ZeroCollateral()`, `InexactTransfer(uint256 expected, uint256 received)`, `ListingMismatch(uint256 listed, uint256 planned)`, `StrayBalance()`.

## Examples

- Foundry: [Borrowing.t.sol](../../examples/foundry/test/Borrowing.t.sol). Lists WETH on the USDG core, checks the listing waits in FUNDING with the right minted to the borrower, shows a wallet's `fund` refused with `NotFunder()`, cancels, and withdraws the collateral. Then, where a loan is running on the USDG core or the earlier one, repays it as the holder of its right and checks the lenders were credited the whole cap.

  ```solidity
  vm.startPrank(borrower);
  IERC20(weth).approve(address(core), amount);
  uint256 id = core.list(Collateral(0, weth, amount), principal, cap, 7 days, deadline, false);
  core.cancelFunding(id);
  core.withdrawCollateral(id, borrower);
  vm.stopPrank();
  ```

- viem: [cores-list.ts](../../examples/viem/src/cores-list.ts). Checks the registry, encodes the approval and the listing, and simulates wrap, approve and list in order with `eth_simulateV1` (viem's `simulateCalls`), from an address given ETH for the simulation only. It shows the `walletClient.writeContract` calls for your own wallet without running them.

  ```ts
  const simulation = await client.simulateCalls({
    account: WALLET,
    stateOverrides: [{address: WALLET, balance: amount + parseEther("0.01")}],
    calls: [
      {to: weth, abi: wethAbi, functionName: "deposit", value: amount},
      {to: weth, abi: wethAbi, functionName: "approve", args: [core, amount]},
      {to: core, abi: coreAbi, functionName: "list", args: listArgs},
    ],
  });
  ```

## What not to rely on

- **Being funded.** A listing is funded only when gage's keeper fills it on a plan gage's rates service signs, for terms some partner vault's rules accept. Quote first; a listing can wait out its deadline.
- **A listing closing by itself.** Past its funding deadline it stays FUNDING, collateral in escrow, until someone calls `cancelFunding`.
- **gage's services to settle.** Repaying, cancelling, `finalizeDefault`, `withdrawUSDG`, `withdrawCollateral` and claims need only the chain. Funding, loops, private borrows and the sale data for `cashOutVia` need gage's keeper or rates service.
- **Repaying in the last second.** The end is exclusive and there is no grace on the current cores. Leave room for congestion.
- **Push transfers.** The principal, refunds and repayments are credits; the collateral waits in its account. A contract that borrows must call `withdrawUSDG` and `withdrawCollateral` itself and be able to receive the reclaim right.
- **An approval to a router meaning one thing.** Approving the cash-out router for a one-day loan's right also opts that loan into the keeper's settlement in its last 15 minutes.
- **The originator receiving everything.** The principal is credited to the originator; the collateral after repayment goes to the `recipient` of `reclaim`; the right, and with it repayment, may have been sold.
- **A price.** The core reads none. Value the collateral yourself; the outcome at the end depends only on whether the cap was paid in time.
