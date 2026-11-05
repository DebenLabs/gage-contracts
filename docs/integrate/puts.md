# Puts

A put on gage is an ordinary loan on the NVDA generation's core whose collateral is USDG: the borrower pledges USDG and borrows NVDA. What they repay is fixed in NVDA, so the position gains as NVDA falls. At the end the borrower repays, or walks away and the lenders keep the USDG; for a put opened through the loop router, whose own NVDA bought most of the pledge, the most the borrower can lose is the margin they put in. No liquidation: nothing can touch the collateral before the end of the term; at the end the borrower chooses. A put opens through the NVDA generation's `LoopRouter`, and closes or rolls through its `PutRouter`, which pays only in the collateral token, so the borrower never has to hold NVDA. Use these routers to offer a bounded short position on NVDA without margin calls.

The partner vaults that lend NVDA fund puts. You may end up holding the collateral instead of the asset you lent: a depositor in an NVDA vault can end up holding USDG instead of NVDA.

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| PutRouter (NVDA generation) | `0x93D6665D881a2DB7d054dBD271dF513dAa52ec99` | [`src/put/PutRouter.sol`](../../src/put/PutRouter.sol) | [`abi/PutRouter.json`](../../abi/PutRouter.json) | Its owner (`owner()`), who can only pause and unpause `roll` and `rollFor`; `close` is never paused |
| LoopRouter (NVDA generation) | `0xe5A69a1DEd8437bbFDe19263B626aAE4Ec1f09cf` | [`src/loop/LoopRouter.sol`](../../src/loop/LoopRouter.sol) | [`abi/LoopRouter.json`](../../abi/LoopRouter.json) | Its owner, who can pause new loops and admit or drop the executors `loopVia` may call |
| NVDA core (GageV2Vault) | `0xe0dDd6869677d3F5A2BC48375FC899B10A6848E1` | [`src/v2/GageV2Vault.sol`](../../src/v2/GageV2Vault.sol) | [`abi/GageV2Vault.json`](../../abi/GageV2Vault.json) | No owner |
| Standing-roll executor | `0xCB14554904b86b3472F960740aE377b5b711A659` | (a wallet) | | gage's keeper |

Both routers read the NVDA core and fill router as immutables (`CORE()`, `FILLS()`), with `POOL_MANAGER()` and `V3_FACTORY()`; the put router also reads the NVDA factory (`FACTORY()`). Their `USDG()` is the core's cash asset, which on this generation is NVDA (`0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC`, 18 decimals); the collateral of a put is USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals). Read every name with that in mind: in these two routers "cash" means NVDA. The USDG generation (`intentV1`) names no put router: it lends USDG, so a put there would borrow USDG against USDG.

USDG is admitted as collateral on the NVDA core's registry: read `getERC20Config(USDG)` on `REGISTRY()` for its minimum and per-loan and open caps (raw USDG units), `allowedTerms()` for the terms and `feeBps()` for the origination fee. Both routers are admitted on that registry (`isRouter`) and by the NVDA factory (`isFiller`); the registry's and factory's owners can withdraw those admissions.

## How it works

**Opening.** `LoopRouter` buys an exact amount of USDG with NVDA it does not have yet, lists that USDG plus the borrower's own (the margin) as one loan for the borrower, funds all four quarters with a signed plan, pays the NVDA principal out to the borrower and takes the purchase's cost back from them, in one transaction. The result is one loan, on the core's own terms, whose collateral is the margin and the USDG the loan itself bought. Its size is the pledge over the margin, `(own + buy) / own`; its loan-to-value is about `buy / (own + buy)`. gage-sdk's put sizing (`put_open` in its source) takes the least principal whose payout buys the purchase through the cheapest pool with 25 basis points of it spare, so next to nothing lands besides.

**Closing.** `PutRouter.close` repays the loan out of its own collateral: the PoolManager fronts the NVDA repayment, the loan is repaid on the core and booked in its vaults, the router buys back exactly the repayment with the pledged USDG through the pool the caller names, and sends the rest of the USDG to the recipient. No plan, no signature, no service: only a pool deep enough. A pledge that cannot buy back the repayment cannot close; the borrower then repays in NVDA on the core, or walks away. `close` serves any token collateral on the core, not only USDG.

**Rolling.** `PutRouter.roll` renews the loan on the same collateral as the [rollover router](rollover.md) does: the old repayment is fronted, the same USDG is listed for the same borrower and funded on signed plans. The new loan's NVDA payout passes through the borrower's wallet and straight back towards the old repayment, and the router buys what it leaves short (the top-up) with USDG from the borrower's wallet, at most `maxSpend`. A payout above the old repayment leaves the rest in the wallet. A standing instruction lets the executor the borrower names roll for them near the end of the loan.

**Venues.** A close or a roll buys NVDA with USDG, exact output, through one of:

- `Venue.V4` (0): a hookless Uniswap v4 pool pairing NVDA and USDG, given by its `PoolKey` (currencies sorted, `hooks` zero). The purchase nets inside the same PoolManager unlock as the fronted repayment. The manifest names one at `pools.nvdaUsdg`.
- `Venue.V3` (1): the pool of NVDA and USDG at fee tier `v3Fee` of the V3 factory the router reads (`V3_FACTORY()`, `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`, found with `getPool(USDG, NVDA, v3Fee)`); the router pays the pool from its swap callback.

The pool sets only what the borrower pays, which their own bounds hold (`maxSpend`, `minBack`); it never touches the loan the vaults fund. gage-sdk quotes each pool it knows for the exact amount and sends through the cheapest that simulates. Every `close`, `roll` and `rollFor` names a valid pool, even when there is nothing to buy.

### What needs gage's services

- **Opening and rolling by hand: gage's rates service.** The loop and the roll carry plans signed by the NVDA factory's quote signer, naming the loop router (to open) or the put router (to roll) as filler and priced for this borrower (`evidence` = `evidenceFor(borrower, pricing)`). The borrower sends the transaction; the router is the filler. Without a signature the loop buys the USDG, lists the loan and reverts at the fill (`Refused`), so nothing moves.
- **Standing rolls: gage's keeper.** gage-sdk names `0xCB14554904b86b3472F960740aE377b5b711A659` as the executor. The put router refuses a zero executor, since whoever rolls picks the pool and the plan.
- **Closing: nothing.** A borrower, or any contract holding the reclaim right, closes with the pool alone.

## Call sequences

Amounts: NVDA in raw units with 18 decimals (principal, cap, `maxCost` of the loop and of a standing roll), USDG in raw units with 6 decimals (`own`, `buy`, collateral, `maxSpend`, `minBack`).

### Open a put (LoopRouter)

1. Get a plan from gage's rates service for a loop on the NVDA core: token USDG, collateral `own + buy`, the principal, cap and term, priced for the borrower, `listingId` the next id the core will issue. gage-sdk's `put_open` (in its source; see What not to rely on) does this and returns the steps below.
2. Approve the loop router for the margin: `IERC20(USDG).approve(loopRouter, own)`.
3. Approve the loop router for the purchase's cost in NVDA: `IERC20(NVDA).approve(loopRouter, maxCost)`. It is taken back after the principal has reached the wallet; what the principal does not cover comes from the wallet.
4. Call one of:

```solidity
struct Loop {
    PoolKey key;
    uint256 own;
    uint256 buy;
    uint256 maxCost;
    uint40 fundingDeadline;
    bool withRewards;
    bytes32 pricing;
}

function loop(
    Loop calldata l,
    IntentQuoteVerifier.Plan calldata plan,
    bytes calldata signature,
    uint256[] calldata maxReserveShares
) external returns (uint256 id, uint256 cost);

struct LoopV3 {
    uint24 fee;
    uint256 own;
    uint256 buy;
    uint256 maxCost;
    uint40 fundingDeadline;
    bool withRewards;
    bytes32 pricing;
}

function loopV3(
    LoopV3 calldata l,
    IntentQuoteVerifier.Plan calldata plan,
    bytes calldata signature,
    uint256[] calldata maxReserveShares
) external returns (uint256 id, uint256 cost);
```

`loop` buys through a hookless v4 pool pairing NVDA with USDG (`key`); `loopV3` through the V3 factory's pool at `fee`. `buy` is exact; `maxCost` bounds what it costs in NVDA (`TooExpensive`). The plan's `collateral` must equal `own + buy` and its `listingId` must be the id the core issues (`ListingMismatch` otherwise: another listing landed first, ask again). `maxReserveShares` has one entry per allocation of the plan. A third entry point, `loopVia`, buys through an aggregator's router the owner admits (`executorAllowed(executor)`), with NVDA flash-borrowed from a V3 pool; read the source before using it.

The loan is ACTIVE when the call returns; the borrower holds its reclaim right.

### Close a put (PutRouter)

1. Approve the put router for the reclaim right on the core: `approve(putRouter, loanId)` or `setApprovalForAll(putRouter, true)`.
2. Quote the purchase: the USDG an exact-output swap of the loan's `cap` in NVDA costs through each pool you may use. Set `maxSpend` a little above the cheapest quote (gage-sdk's `put_close` adds 50 basis points by default) and `minBack` to `collateral - maxSpend`, or the least you accept back.
3. Call `close`:

```solidity
enum Venue {
    V4,
    V3
}

struct Swap {
    Venue venue;
    PoolKey key;
    uint24 v3Fee;
}

struct Close {
    uint256 loanId;
    Swap swap;
    uint256 maxSpend;
    uint256 minBack;
    address recipient;
}

function close(Close calldata c) external returns (uint256 spent, uint256 returned);
```

The caller must hold the reclaim right, the loan must be ACTIVE and inside its term, and `recipient` must not be zero or the router. For `Venue.V3`, `key` is ignored; for `Venue.V4`, `v3Fee` is ignored. The router spends at most `min(maxSpend, collateral)` and returns `collateral - spent`, at least `minBack`. A standing instruction on the loan ends with it.

### Roll a put by hand (PutRouter)

1. Approve the right, as for a close.
2. Get signed plans from gage's rates service for a roll through the put router (gage-sdk's `put_roll`). They return the new terms and the wallet figures: the payout, the top-up in NVDA.
3. Approve the put router for the NVDA that passes through the wallet: `min(payout, oldCap)`. The router takes exactly that back after the payout lands.
4. Quote the top-up's cost in USDG through each pool; approve the put router for `maxSpend` USDG.
5. Call `roll`:

```solidity
struct Roll {
    uint256 loanId;
    Swap swap;
    uint256 maxSpend;
    bool withRewards;
    bytes32 pricing;
}

function roll(
    Roll calldata r,
    IntentQuoteVerifier.Plan[] calldata plans,
    bytes[] calldata signatures,
    uint256[] calldata maxReserveShares
) external returns (uint256 id);
```

The plans follow the rollover router's rules: one to eight, for ids in a row, on the same terms, each priced for the borrower and naming the put router as filler. The router reverts `SpendTooHigh(spent, maxSpend)` if the top-up costs more USDG. The new loan's id is returned, ACTIVE.

### Leave, run and cancel a standing roll (PutRouter)

```solidity
function setAutoRoll(
    uint256 loanId,
    address executor,
    uint32 term,
    uint32 window,
    uint128 maxCost,
    uint128 maxSpend,
    uint8 rollsLeft,
    bool withRewards,
    uint40 until
) external;

function rollFor(
    uint256 loanId,
    bytes32 pricing,
    Swap calldata swap,
    IntentQuoteVerifier.Plan[] calldata plans,
    bytes[] calldata signatures,
    uint256[] calldata maxReserveShares
) external returns (uint256 id);

function cancelAutoRoll(uint256 loanId) external;
```

The limits are the rollover router's (see [Rollover](rollover.md)), with two differences: `executor` must not be zero, and `maxSpend`, the most USDG each roll may draw from the wallet, must not be zero; `maxCost` stays in NVDA. `rollFor` takes the pool (`swap`) from the executor, inside the borrower's `maxSpend`; a new loan that costs more than `maxCost` reverts `CostTooHigh`. Standing approvals: `setApprovalForAll(putRouter, true)` on the core, NVDA for each roll's payout that passes through the wallet (gage-sdk approves four times the principal), and USDG for each roll's spend (four times `maxSpend`). `autoRolls(loanId)`, `rollableAt(loanId)` and `evidenceFor(borrower, pricing)` read as on the rollover router, `autoRolls` returning `maxSpend` in the last field.

### Collateral sent to the router by mistake

`rescueCollateral(uint256 loanId)` behaves as on the rollover router.

### The owners

The put router's owner (`Ownable2Step`) can `pause()` and `unpause()`. A pause stops `roll` and `rollFor`; `close` always runs, and every loan stays repayable on the core. A put relying on a standing instruction is not rolled while paused, and with no grace period it ends with the lenders keeping the USDG unless the borrower closes or repays it. The loop router's owner can `pause()` new loops and `setExecutor(executor, allowed)`; neither touches an open loan.

## Events to index

From the put router:

- `event Closed(uint256 indexed loanId, address indexed borrower, address recipient, uint128 repaid, uint256 spent, uint256 returned)`: the loan was repaid (`repaid`, its cap in NVDA), `spent` USDG of its collateral bought that back, and `returned` USDG went to `recipient`.
- `event Rolled(uint256 indexed oldId, uint256 indexed newId, address indexed borrower, address caller, uint128 repaid, uint128 principal, uint128 cap, uint32 term, uint256 topUp, uint256 spent)`: as the rollover router's `Rolled`; `topUp` is the NVDA bought, `spent` the USDG it cost the wallet.
- `event AutoRollSet(uint256 indexed loanId, address indexed borrower, AutoRoll autoRoll)`, `event AutoRollCancelled(uint256 indexed loanId, address indexed borrower)`, `event AutoRollCarried(uint256 indexed fromId, uint256 indexed toId, uint8 rollsLeft)`, `event CollateralRescued(uint256 indexed loanId, address indexed holder)`: as on the rollover router; `AutoRoll` carries `maxSpend` in place of `maxTopUp`.

From the loop router:

- `event Looped(uint256 indexed id, address indexed borrower, address indexed token, uint256 own, uint256 bought, uint256 cost, uint128 principal, uint128 cap, uint32 term)`: a put opened: `token` is USDG, `own` the margin, `bought` the USDG the loan bought, `cost` what that cost in NVDA.
- `event BoughtVia(uint256 indexed id, address indexed executor, address flashPool, uint256 spent, uint256 flashFee, uint256 surplus)`: a `loopVia` purchase.
- `event ExecutorSet(address indexed executor, bool allowed)`.

The core's `Listed`, `Activated` and `Closed` events and the fill router's `Filled` come in the same transactions.

## Errors you will meet

| Error | Contract | When |
| --- | --- | --- |
| `NotBorrower()` | PutRouter | the caller does not hold the reclaim right; `rollFor` once the right has another holder; `cancelAutoRoll` by anyone but the borrower who set it |
| `InvalidRecipient()` | PutRouter | `close` to zero or to the router |
| `NotActive()` | PutRouter | `close`, `roll` or `rollFor` on a loan that is not running |
| `CollateralMismatch()` | PutRouter | the collateral is NVDA itself, or the plans are not on the loan's collateral |
| `InvalidSwap()` | PutRouter | a v4 key that does not pair NVDA with the collateral or has a hook, or no V3 pool at `v3Fee` |
| `SpendTooHigh(uint256 spent, uint256 maxSpend)` | PutRouter | the purchase costs more USDG than allowed (for a close, never more than the collateral) |
| `ReturnTooLow(uint256 returned, uint256 minBack)` | PutRouter | a close returns less than `minBack` |
| `PartialPurchase(uint256 bought, uint256 wanted)` | both | the pool could not deliver the exact amount |
| `InvalidAutoRoll()` | PutRouter | `setAutoRoll` with a zero executor, term, window, `maxCost`, `maxSpend` or `rollsLeft`, a window above one day, a past `until`, a window opening after `until`, or `maxCost` under the origination fee |
| `NoAutoRoll()`, `NotExecutor()`, `AutoRollEnded()`, `TooEarly(uint256 opensAt)`, `TermMismatch(uint32 planned, uint32 wanted)`, `PrincipalMismatch(uint128 planned, uint128 old)`, `CostTooHigh(uint256 cost, uint256 maxCost)` | PutRouter | `rollFor` checks, as on the rollover router |
| `PlanMismatch()`, `NotBorrowersPlan()`, `ListingMismatch(uint256 listed, uint256 planned)` | PutRouter | as on the rollover router |
| `NotBorrowersPlan()`, `CollateralMismatch(uint256 planned, uint256 looped)`, `ListingMismatch(uint256 listed, uint256 planned)` | LoopRouter | the plan was priced for another wallet, its collateral is not `own + buy`, or another listing took its id |
| `InvalidPool()`, `NothingToBuy()`, `TooExpensive(uint256 cost, uint256 maxCost)`, `InvalidExecutor()` | LoopRouter | a pool that does not pair NVDA with the plan's token or has a hook, `buy` zero, a purchase dearer than `maxCost`, an executor not admitted |
| `InexactTransfer(uint256 expected, uint256 received)`, `StrayBalance()`, `NotPoolManager()`, `NotPool()` | both | a transfer that did not arrive exactly, a balance left on the router, a callback from the wrong caller |
| `EnforcedPause()` | both | `roll`/`rollFor` on a paused put router, a loop on a paused loop router |
| `Refused(uint8 reason)` | IntentQuoteVerifier | the plan is unsigned (2), expired, used, or no longer matches |

## Examples

- [`examples/foundry/test/Puts.t.sol`](../../examples/foundry/test/Puts.t.sol) checks both routers' wiring, USDG's admission and the pools, lists a put-shaped loan as a borrower, shows what `close` and `roll` refuse before it runs, sets and cancels a standing roll, and shows a loop reverting at the fill without gage's signature. When a put runs on the NVDA core, it also closes one as its borrower.
- [`examples/viem/src/routers-puts.ts`](../../examples/viem/src/routers-puts.ts) reads the routers and pools, and builds and simulates a close.

```solidity
IPutRouter.Swap memory swap = IPutRouter.Swap(1, noKey, 500); // the V3 factory's pool at 0.05%
vm.startPrank(borrower);
core.approve(address(puts), id);
(uint256 spent, uint256 back) = puts.close(IPutRouter.Close(id, swap, maxSpend, minBack, borrower));
vm.stopPrank();
```

## What not to rely on

- **A close always being possible.** It needs a pool that can sell the whole repayment in NVDA for less USDG than is pledged. If NVDA has risen far enough, the pledge cannot buy it back: repay in NVDA, or walk away.
- **A price from the routers.** They read none. Quote each pool yourself for the exact amount, and bound the call with `maxSpend` and `minBack`.
- **A standing roll running.** It is best effort, as on the rollover router, and it also needs a pool that buys the top-up within `maxSpend`.
- **Names.** `USDG()` on both routers returns NVDA, the core's cash asset; the collateral is USDG.
- **Puts on other generations.** Only an entry that names both `loopRouter` and `putRouter` offers them; today that is NVDA's.
- **gage-sdk's put actions in every release.** `put_open`, `put_close`, `put_roll`, `put_auto_roll` and `put_cancel_auto_roll` are in gage-sdk's source; check that the version you install lists them.
