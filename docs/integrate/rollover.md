# Rollover

`RolloverRouter` rolls a running loan into a new one on the same collateral, in one transaction: it repays the old loan in full with flash liquidity from the Uniswap v4 PoolManager, takes the collateral back, lists that same collateral for the same borrower and funds the new loan from partner vaults on signed plans. The borrower's wallet pays only the difference between the old repayment and the new loan's payout, or keeps what the payout leaves over. A borrower can roll by hand (`roll`), or leave a standing instruction (`setAutoRoll`) that a named executor runs near the end of the loan (`rollFor`), inside limits the router checks on chain. Use it to keep a position open past its date without selling the collateral. Each generation has its own router: a loan rolls only through the router of the core it lives on.

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| RolloverRouter (USDG generation) | `0x3bee806F87386e71713516bA0b91dAE21D576f72` | [`src/rollover/RolloverRouter.sol`](../../src/rollover/RolloverRouter.sol) | [`abi/RolloverRouter.json`](../../abi/RolloverRouter.json) | Its owner (`owner()`), who can only pause and unpause `roll` and `rollFor` |
| RolloverRouter (NVDA generation) | `0xB47D90C6af419353536E023Ae00D132c68226c40` | same | same | same |
| RolloverRouter (HIMS generation) | `0xa27F40174B6293252E0FDbCFf8c3B50868156EE0` | same | same | same |
| Standing-roll executor | `0xCB14554904b86b3472F960740aE377b5b711A659` | (a wallet) | | gage's keeper |

Each router reads its own core, fill router and factory as immutables: `CORE()`, `FILLS()`, `FACTORY()`, `POOL_MANAGER()` and `USDG()`. `USDG()` is the core's cash asset: USDG on the USDG generation, the lent token on a lend generation (NVDA, HIMS). Every amount the router takes or bounds is in raw units of that asset: 6 decimals for USDG, 18 for NVDA and HIMS (the manifest's `intentV1Assets.<SYMBOL>.lendAsset.decimals`).

A generation whose manifest entry has no `rolloverRouter` key has no router this manifest names: check the key rather than assume every generation has one. Earlier generations keep their own routers under `intentV1Previous` and `intentV1AssetsPrevious`; gage's rates service and keeper roll no loan of a generation that has been replaced, so on those routers only `cancelAutoRoll` and `rescueCollateral` are of use.

The router works only while the core's registry admits it as an entry router (`isRouter(router)`, so it may call `listFor`) and the factory admits it as a filler (`isFiller(router)`, so plans may name it). Those admissions belong to the registry's and factory's owners, who can withdraw them.

## How it works

A roll is one `PoolManager.unlock`. Inside the callback the router:

1. takes the old loan's whole repayment (its `cap`) from the PoolManager;
2. repays the old loan on the core (`reclaim(oldId, router)`), so its lenders are credited their whole repayment on time, and asks each partner vault that lent it to book the repayment (`settle`, skipped for a vault that cannot settle now);
3. withdraws the collateral and checks it is exactly the plans' amount;
4. lists the same collateral for the borrower (`listFor`, funding deadline the next second) on the plans' principal, cap and term, and funds all four quarters with the plan whose `listingId` is the id the core issued (`IntentFillRouter.fill`);
5. delivers the borrower's cash credit on the core (the new loan's payout, principal less the origination fee) to their wallet (`withdrawUSDGFor`), then pulls the old repayment from the borrower's wallet back into the PoolManager and settles.

What the payout does not cover is the top-up, drawn from the wallet, at most the caller's `maxTopUp`. A payout above the old repayment leaves the rest in the wallet. If anything fails, everything reverts and nothing moves. The router holds nothing between calls (`StrayBalance` otherwise).

The new loan is an ordinary loan of the core: its fixed cost is what the plans price at that moment, it pays the registry's origination fee (`feeBps()` on the core's registry), and at its end the borrower repays it or walks away as with any other. No liquidation: nothing can touch the collateral before the end of the term; at the end the borrower repays, or the lenders keep the collateral.

### What needs gage's services

- **Signed plans: gage's rates service.** Every roll, by hand or standing, carries one to eight funding plans signed by the factory's quote signer (`IntentFactory.quoteSigner()`), each naming this router as filler, priced and screened for this borrower (its `evidence` is `evidenceFor(borrower, pricing)`) and for a listing id in a row (`listingId`, `listingId + 1`, …), all on the same terms. Another listing landing first moves the id, and the plan for the id the core issues is the one used. A plan lives at most `IntentQuoteVerifier.MAX_QUOTE_LIFE` (5 minutes); gage-sdk asks for plans signed for 30 seconds and sends at once.
- **Running standing rolls: gage's keeper.** gage's app and gage-sdk name `0xCB14554904b86b3472F960740aE377b5b711A659`, the keeper's wallet, as the only executor. The keeper calls `rollFor` with plans from gage's rates service inside the instruction's limits. It is best effort: if no partner vault funds the roll within the limits, the loan ends as any other.

Nothing else needs gage's services: setting, reading and cancelling an instruction, approvals, and repaying the loan on the core directly.

## Call sequences

### Roll by hand

The caller holds the loan's reclaim right (the core's ERC-721 token for the loan, `ownerOf(loanId)`), and the loan is ACTIVE and inside its term (the core's `reclaim` refuses otherwise).

1. Approve the router for the reclaim right on the core: `approve(router, loanId)`, or `setApprovalForAll(router, true)`.
2. Approve the router for the old loan's whole repayment in the cash asset: `IERC20(router.USDG()).approve(router, cap)`, with `cap` from `getLoan(loanId).cap`. The router pulls exactly `cap` after the payout has reached the wallet, so the wallet must hold the top-up, `cap - (principal - originationFee)` of the new loan when positive.
3. Get signed plans for the roll from gage's rates service: gage-sdk's `roll` action fetches and checks them when it builds the transaction, as gage.cash does. The answer carries the plans, their signatures, the `pricing` commitment and the wallet figures (payout, top-up, surplus).
4. Call `roll`:

```solidity
struct Roll {
    uint256 loanId;
    uint256 maxTopUp;
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

- `maxTopUp`: the most the wallet may add beyond the new payout, raw units of the cash asset. Set it to the top-up you were quoted; the router reverts `TopUpTooHigh(topUp, maxTopUp)` above it.
- `withRewards`: whether the new listing asks for rewards.
- `pricing`: the signer's pricing commitment that came with the plans.
- `maxReserveShares`: one entry per allocation of the plan used, a caller ceiling that can only tighten each allocation's signed `maxReserveShares`. gage-sdk passes the first plan's own values.

The new loan's principal, cap and term are the plans'; gage's rates service quotes a roll of the same principal, and gage-sdk refuses any other. `roll` returns the new loan's id, ACTIVE on return. A standing instruction on the old loan ends with a roll by hand (`AutoRollCancelled`). A roll before the old loan's last day repays it early: its lenders are paid the whole cap, and the new loan's term starts at the roll.

### Leave a standing instruction

```solidity
function setAutoRoll(
    uint256 loanId,
    address executor,
    uint32 term,
    uint32 window,
    uint128 maxCost,
    uint128 maxTopUp,
    uint8 rollsLeft,
    bool withRewards,
    uint40 until
) external;
```

Only the holder of the loan's reclaim right, for a loan that is funding or running. Setting one replaces any instruction already on that loan. The parameters:

| Parameter | Meaning | Router's limit |
| --- | --- | --- |
| `executor` | The only account that may run it; zero lets anyone | none |
| `term` | Each new loan's term, in seconds | nonzero; `rollFor` refuses plans on any other term (`TermMismatch`) |
| `window` | How long before the end of the loan a roll may run, in seconds | 1 to `MAX_WINDOW` (1 day); a roll opens at `fundedAt + term - min(window, MAX_WINDOW, term / 8)` |
| `maxCost` | The most each new loan may cost in total, `cap - principal + originationFee`, raw units of the cash asset | nonzero, and at least the origination fee on the loan's principal (`principal * feeBps / 10_000`); held to the unit after each roll (`TooExpensive`) |
| `maxTopUp` | The most each roll may draw from the wallet beyond the payout | `TopUpTooHigh` above it |
| `rollsLeft` | How many rolls it may make | at least 1; one fewer after each roll |
| `withRewards` | Whether each new listing asks for rewards | the borrower's choice, never the executor's |
| `until` | No roll after this time (Unix seconds) | in the future, and not before the first window opens |

Every roll it makes keeps the old loan's principal (`PrincipalMismatch` otherwise), so `maxCost` is what each roll of this loan may cost.

The instruction moves nothing by itself. Each roll still needs the same approvals as a roll by hand, standing:

1. `setApprovalForAll(router, true)` on the core, so the router can repay each new loan it makes (an `approve` for one id covers only that loan).
2. An allowance of the cash asset that covers every roll still to come: the next roll takes back the current `cap`, each later one at most `principal + maxCost`. gage-sdk approves `cap + (rollsLeft - 1) * (principal + maxCost)`, plus what the wallet's other standing rolls through the same router still need, since a new approval replaces the old one.
3. The wallet must hold each roll's top-up when it runs.

gage-sdk's `auto_roll` sets: the loan's own term, `window` six hours (at most an eighth of the term), four rolls, `until` four terms and a day after the loan's end, `withRewards` false, `maxCost` twice what a roll of the loan costs now and never above four times this loan's own fixed cost and fee (twice this loan's own for a loan still funding, which cannot be quoted yet), `maxTopUp` the larger of `maxCost` and this loan's own fixed cost and fee, and `0xCB14554904b86b3472F960740aE377b5b711A659` as executor.

The instruction holds only while the borrower who set it still holds the reclaim right: a sold right carries none.

### Run a standing instruction (the executor)

```solidity
function rollFor(
    uint256 loanId,
    bytes32 pricing,
    IntentQuoteVerifier.Plan[] calldata plans,
    bytes[] calldata signatures,
    uint256[] calldata maxReserveShares
) external returns (uint256 id);
```

The router checks, in order: an instruction exists (`NoAutoRoll`), the caller is its executor unless it named none (`NotExecutor`), the borrower still holds the right (`NotBorrower`), `until` has not passed and rolls are left (`AutoRollEnded`), the loan is ACTIVE (`NotActive`), the window is open (`TooEarly(opensAt)`), the plans' term is the instruction's (`TermMismatch`) and their principal is the old loan's (`PrincipalMismatch`). After the roll, the new loan's cost is held to `maxCost` (`TooExpensive`). The instruction then moves to the new loan with one roll fewer (`AutoRollCarried(fromId, toId, rollsLeft)`), or ends with its last roll (`rollsLeft` 0 in that event).

### Read and cancel

- `autoRolls(loanId)` returns the stored instruction (`borrower`, `term`, `window`, `rollsLeft`, `withRewards`, `executor`, `until`, `maxCost`, `maxTopUp`); `borrower` is zero for none.
- `rollableAt(loanId)` returns the first second the instruction may roll the loan, or zero when none could run (no instruction, loan not ACTIVE, another holder, date or rolls spent, or a window that opens after `until`). It does not read the pause.
- `cancelAutoRoll(uint256 loanId)`: only the borrower who set it. The approvals stay; withdraw them in the wallet once nothing rolls by itself.
- `evidenceFor(address borrower, bytes32 pricing)` returns `keccak256(abi.encode(borrower, pricing))`, the evidence a plan for that borrower must carry.

### Collateral sent to the router by mistake

`rescueCollateral(uint256 loanId)`: anyone may call it for a REPAID loan whose collateral the core assigned to the router and which is still in the loan's account; the collateral goes to the holder the core's rewards ledger records for the loan. A roll never leaves collateral there: only a repayment on the core that named the router as recipient does.

### The owner

The owner (`Ownable2Step`) can `pause()` and `unpause()`. A pause stops `roll` and `rollFor` alike (`EnforcedPause`); loans already open are the core's and untouched, and every loan stays repayable on the core. A loan relying on a standing instruction is not rolled while the router is paused: if the pause lasts through the rest of its window, the loan reaches its end and, with no grace period, the lenders keep the collateral unless the borrower repays.

## Events to index

From the router:

- `event Rolled(uint256 indexed oldId, uint256 indexed newId, address indexed borrower, address caller, uint128 repaid, uint128 principal, uint128 cap, uint32 term, uint256 topUp)`: `oldId` was repaid (`repaid`, its whole cap) and `newId` opened on `principal`, `cap` and `term`; `topUp` is what the wallet added; `caller` is the borrower for `roll` or the executor for `rollFor`.
- `event AutoRollSet(uint256 indexed loanId, address indexed borrower, AutoRoll autoRoll)`: an instruction set or replaced, with all its fields.
- `event AutoRollCancelled(uint256 indexed loanId, address indexed borrower)`: ended by `cancelAutoRoll`, or by a roll by hand of that loan.
- `event AutoRollCarried(uint256 indexed fromId, uint256 indexed toId, uint8 rollsLeft)`: a standing roll ran; the instruction moved to `toId` with `rollsLeft` rolls, or ended (`rollsLeft` 0).
- `event CollateralRescued(uint256 indexed loanId, address indexed holder)`.

The same transaction carries the core's events for the old loan (`Closed` with state REPAID) and the new one (`Listed`, `Activated`), and the fill router's `Filled`.

## Errors you will meet

| Error | When |
| --- | --- |
| `NotBorrower()` | `roll` or `setAutoRoll` by a wallet that does not hold the reclaim right; `rollFor` once the right has another holder; `cancelAutoRoll` by anyone but the borrower who set it |
| `InvalidAutoRoll()` | `setAutoRoll` with a zero term, window, `maxCost` or `rollsLeft`, a window above `MAX_WINDOW`, `until` not in the future, a window opening after `until`, or `maxCost` under the origination fee |
| `NoAutoRoll()`, `NotExecutor()`, `AutoRollEnded()`, `NotActive()`, `TooEarly(uint256 opensAt)` | `rollFor` checks, above |
| `TermMismatch(uint32 planned, uint32 wanted)`, `PrincipalMismatch(uint128 planned, uint128 old)`, `TooExpensive(uint256 cost, uint256 maxCost)` | `rollFor`: plans outside the instruction |
| `TopUpTooHigh(uint256 topUp, uint256 maxTopUp)` | the payout leaves more to pay than the caller allowed |
| `PlanMismatch()` | no plans, more than `MAX_PLANS` (8), a signature count that differs, or plans not on the same terms for ids in a row |
| `NotBorrowersPlan()` | a plan's evidence is not `evidenceFor(borrower, pricing)` |
| `CollateralMismatch()` | the plans' token, kind or amount is not the loan's collateral, or the collateral is the cash asset itself |
| `ListingMismatch(uint256 listed, uint256 planned)` | the core issued an id none of the plans covers (other listings landed first): ask again |
| `InexactTransfer(uint256 expected, uint256 received)` | the collateral did not come back exactly |
| `StrayBalance()` | a balance was left on the router |
| `NothingToRescue()` | `rescueCollateral` on a loan with nothing to send |
| `EnforcedPause()` | `roll` or `rollFor` while paused |
| `Refused(uint8 reason)` | from `IntentQuoteVerifier` through the fill: the plan is unsigned, expired, already used, or no longer matches the listing or a vault |
| `WrongState()`, `Deadline()`, `NotAuthorized()`, `Paused()` | from the core: the loan is not running, its term has ended, the router is not approved for the right, or new loans are paused on the registry |

## Examples

- [`examples/foundry/test/Rollover.t.sol`](../../examples/foundry/test/Rollover.t.sol) checks every generation's router against the manifest and its admissions, then, as a borrower, approves the router, sets a standing instruction, reads it back, shows what the router refuses without gage's plans, and cancels it.
- [`examples/viem/src/routers-rollover.ts`](../../examples/viem/src/routers-rollover.ts) reads the routers, builds the approvals and `setAutoRoll` for the newest open loan, and simulates it for the loan's holder.

```solidity
vm.startPrank(borrower);
core.setApprovalForAll(address(router), true);
IERC20(router.USDG()).approve(address(router), allowance);
router.setAutoRoll(id, addressOf("rolloverExecutor"), l.term, window, maxCost, maxCost, 4, false, until);
vm.stopPrank();
```

## What not to rely on

- **A standing roll running.** It runs only while gage's keeper finds plans inside the limits, the router is not paused, the approvals stand and the wallet holds the top-up. The end date of each loan stays the borrower's to keep.
- **The listing id.** Plans name ids; another listing can take the one you planned for. Carry several plans, and expect `ListingMismatch` when the core issued an id past them.
- **The same price twice.** Each roll is priced when it is made. `maxCost` and `maxTopUp` are the only bounds; a plan that would cost more reverts rather than rolls.
- **`rollableAt` as a promise.** It ignores the pause and the approvals.
- **Every generation having a router.** Read the manifest key; a generation without one cannot roll its loans here.
