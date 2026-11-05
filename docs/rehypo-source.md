# The gage rehypo source: plugging a rehypothecation hook into gage

**For DEX partners** whose Uniswap v4 hook lends a pool's idle liquidity.
**Code:**
- `src/rehypo/GageRehypoSource.sol`, the source;
- `src/rehypo/GageRehypoSourceFactory.sol`, its factory;
- the plug test `integrations/lender-amm/test/RehypoSourcePlug.t.sol`;
- the factory's release step and a pool's set-up, one script: `integrations/lender-amm/script/RehypoSource.s.sol`, with the reference hook `integrations/lender-amm/src/UnlockCheckedHook.sol`.

**Status:** live on mainnet. The factory is at `0xab0425C2f5D5bab9867b42EFE3c228BAD2239419`, and checks each partner vault against the GenerationDeployer (`0xcea38204C97e9745f831978357d562E5CcC6834F`), its factory registry. How to plug a hook in: [integrate/dex-partners.md](integrate/dex-partners.md).

## On mainnet (Robinhood Chain, 4663)

| | Address | |
|---|---|---|
| `GageRehypoSourceFactory` | `0xab0425C2f5D5bab9867b42EFE3c228BAD2239419` | Block 106,656,287, tx `0xa7e7c83b24474a556dd91453006a9848f01e6254a2914118fb1688d7f4200780`, from the release signer `0x1Ed0670462cD5AD80C1dd9eE8691F62c47698d98` (`RehypoSource.s.sol` `run()`). Sourcify: runtime and creation match. |
| its `SOURCE_CODE` | `0xc23ea8cE1e150289BdB28519e7D751038b6330a4` | The data contract its constructor wrote: a leading STOP, then `GageRehypoSource`'s creation code, equal to this repository's build byte for byte. Never executed. |
| `POOL_MANAGER()` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Uniswap v4's PoolManager. |
| `REGISTRY()` | `0xcea38204C97e9745f831978357d562E5CcC6834F` | The r13 GenerationDeployer: a source lends only through a vault of an Intent factory it records (2b). |

- The deployment manifest does not name the factory: nothing that reads the manifest needs it. A source is found from the factory's `SourceCreated` events.
- gage's keeper rebalances a source once gage lists it, with the band its set-up prints. For frxUSD/USDG (frxUSD, 18 decimals, is `currency0`; USDG, 6 decimals, `currency1`) the ±0.5% band is `minSqrtPriceX96` `79029843899059723247256` and `maxSqrtPriceX96` `79425985949584624389260` (parity `79228162514264337593543`), for any pool of the pair.

## What it is

One ERC-4626 vault per pool token. The hook deposits and withdraws through it like any yield source. The source:
- keeps a **float** for swaps;
- lends the rest through a **gage partner vault** of that token;
- leaves the hook's code free of anything gage-specific.

```
LPs ──▶ partner's hook ──deposit/withdraw──▶ gage rehypo source ──keeper, outside swaps──▶ gage partner vault ──▶ loans
              ▲  swaps size liquidity by maxWithdraw   │ the float: ERC-6909 claims inside the PoolManager
```

## The plug: what the hook does

Use OpenZeppelin uniswap-hooks' `ReHypothecationHook` with ERC-4626 yield sources, exactly as its own `ReHypothecationERC4626Mock` (`src/mocks/general/`) does. For each currency the hook:

| Hook function | Call on the source |
|---|---|
| `getCurrencyYieldSource(currency)` | the source's address |
| `_depositToYieldSource(currency, amount)` | `approve(source, amount)`, then `source.deposit(amount, address(this))` |
| `_withdrawFromYieldSource(currency, amount)` | `source.withdraw(amount, address(this), address(this))` |
| `_getAmountInYieldSource(currency)` | `source.convertToAssets(source.balanceOf(address(this)))` |
| `_getMaxWithdrawFromYieldSource(currency)` | `source.maxWithdraw(address(this))`. **Required:** OpenZeppelin's default sizes swaps by the whole balance, which would try to pull lent money mid-swap. |
| `seedLiquidity`, `addReHypothecatedLiquidity`, `removeReHypothecatedLiquidity` | Revert while `poolManager.isUnlocked()` (`TransientStateLibrary`), then call the parent. **Required:** anyone can open a PoolManager unlock and call these from its callback, and the source cannot tell an LP entry made there from a swap's input: it would buy at the vault value of the last call outside an unlock and deepen swaps by its whole amount. Swaps never call these functions. |

That is the whole integration. The plug test runs OpenZeppelin's mock on two gage sources, with real swaps, LP entries and exits: unmodified for swaps and exits, and with the unlock check above (`UnlockCheckedHook`) for LP moves from an unlock.

### A hook of the partner's own design: the checklist

OpenZeppelin's hook, with the unlock check in the table (`UnlockCheckedHook`), meets every line below; as it stands it takes an LP entry made inside an unlock, against item 2. A hook built another way (a partner's own ledger, for example) must meet each one; the source cannot check them for it.

1. **The depositor is the hook itself.** `bind` makes the pool's hook (`poolKey.hooks`) the one account that may deposit and withdraw, and inside an unlock the source reads that same account's debt to the PoolManager. The hook contract calls the source itself, with itself as `receiver` and `owner`. A separate contract holding the positions for it is refused: naming the hook as `receiver` or `owner`, with `NotDepositor`; naming itself, by OpenZeppelin's own ERC-4626 limit checks, since `maxDeposit` and `maxWithdraw` are zero for every account but the depositor. A debt opened by another contract does not count.
2. **Inside an unlock, withdraw only the debt a swap left.** In a swap's settlement, withdraw exactly what the hook owes the PoolManager in that token (`-currencyDelta(hook, token)`), as OpenZeppelin's `_resolveHookDelta` does. Never pay an LP from inside an unlock, the hook's own included: a `take` made to pay an LP is a real debt, so the source's `NotASwap` check lets the withdrawal through, priced at the vault value of the last call outside an unlock and blind to the settlement window. In the 28 October 2026 review such an exit was paid 10,000 where the fair amount was 6,363.64, while the vault was settling a loan. LP entries and exits run outside every unlock (the unlock check in the table).
3. **OpenZeppelin's settle order.** Where the hook owes: withdraw from the source first, then `sync`, transfer and `settle`; a withdrawal after the debt is settled reverts `NotASwap`. Where the hook is owed: `take` first, then deposit.
4. **No source call while the pool initializes.** A source binds only to a pool that exists, and refuses every deposit until it is bound. A hook that seeds or deposits in `beforeInitialize` or `afterInitialize` cannot initialize its pool. Seed after `bind` (set-up step 5), in a call of its own, as OpenZeppelin's `seedLiquidity` is.
5. **The exact `PoolKey`.** Bind each source with the key of the pool its hook serves, as the hook stores it (OpenZeppelin's `getPoolKey()`): both currencies, the fee, the tick spacing and the hook. That pool's price decides how far a keeper rebalance opens swaps. `bind` refuses a pool that does not exist, has no hook contract or lacks the token, but it cannot tell which existing pool was meant, and it runs once. One source per pool and token: a hook that serves several pools binds a separate pair of sources to each.

## Set-up: one Safe batch per pool

1. `factory.create(asset, vault, owner, beneficiary, floatBps, salt)`, once per pool token.
   - `vault`: the gage partner vault of that token, or zero for a **float-only** side (frxUSD on day one). It must come from an Intent factory the generation deployer recorded (`IIntentFactoryRegistry.isFactory` of the vault's `PROTOCOL_SOURCE`, and that factory's `isVault`), here and in `proposeVault`; otherwise `NotAGageVault`.
   - `owner`: the partner's Safe.
   - `beneficiary`: where sGAGE and recovered collateral go.
   - `floatBps`: the float target, 1% to 100%.
   - `factory.predict` gives the addresses ahead of time.
2. Deploy the hook naming the two sources (their addresses from `predict`).
3. Initialize the pool.
4. `source.bind(poolKey)` on each source, once. The pool's hook becomes the source's one depositor; `bind` refuses a pool that does not exist, has no hook contract or does not hold the source's token.
5. Seed the pool, as the hook's own rules ask.
6. `source.setKeeper(keeper, true)` for gage's keeper wallet, which runs `rebalance`. gage then adds the source and its pool's price band to its keeper.

The partner's Safe also creates the gage vaults themselves on gage's factories (the pool-vault form), in the same or an earlier batch.

## Running it: one script

`integrations/lender-amm/script/RehypoSource.s.sol` deploys the factory (the release step) and runs the set-up above (a test deployment). It is also the working reference for a partner, whose Safe makes the same calls in the same order. The hook it deploys is `UnlockCheckedHook` (`integrations/lender-amm/src/`): OpenZeppelin's ERC-4626 hook with the unlock check.

Run every command from `integrations/lender-amm`. The keystore asks for its password, so no key goes on the command line.

1. **Build the factory** at the repository root, whose compiler the kit does not share: `forge build src/rehypo/GageRehypoSourceFactory.sol` (once its source is in this repository). The script deploys it from that artifact.
2. **Deploy the factory**, in the release, right after the generation deployer:

   ```bash
   POOL_MANAGER=<PoolManager> GENERATION_DEPLOYER=<generation deployer> forge script script/RehypoSource.s.sol --rpc-url <rpc> --broadcast --slow --keystore <keystore> --sender <deployer>
   ```

   It refuses a `GENERATION_DEPLOYER` that does not answer `isFactory`, and prints the factory's address.
3. **Set a pool up** (on a test network). The script refuses chain 4663, where the partner's Safe makes these calls. The broadcaster plays the partner: it owns both sources, is their beneficiary and seeds the pool.

   ```bash
   REHYPO_FACTORY=<factory> LEND_TOKEN=<USDG> LEND_VAULT=<gage USDG vault> FLOAT_TOKEN=<frxUSD> KEEPER=<gage keeper wallet> SEED_LEND=<raw USDG> SEED_FLOAT=<raw frxUSD> forge script script/RehypoSource.s.sol --sig 'rehearse()' --rpc-url <rpc> --broadcast --slow --keystore <keystore> --sender <partner>
   ```

   - `LEND_VAULT` must come from a factory the generation deployer recorded.
   - `LEND_FLOAT_BPS` is the lent side's float target (default 2000, 20%); the float-only side keeps 100%.
   - `REHYPO_SALT` gives new source addresses: a second run from the same broadcaster needs another, and the script says so.
   - The pool has a static 0.01% fee (the stock hook sets no dynamic fee) and tick spacing 1, and starts at one whole unit for one whole unit.
   - It prints the sources, the hook, the pool id and the keeper entry for the lent side, with a band 0.5% either side of 1:1, which gage adds to its keeper.

`test/RehypoSourceScript.t.sol` runs the same functions on a local PoolManager.

**The emergency lever.** The partner's Safe calls `setFloatBps(10000)` on the lent source. The raise applies at once: the source sweeps nothing more into the vault. gage's keeper then pulls the float back from the vault's free cash on its next passes, whatever the pool's price (past its band, swaps stay thin until the price is back). Until then the vault can still lend that cash, so its curator (the partner's Safe, which created it) also calls the vault's `setPaused(true)`: no new loans, and exits still go through. Money already on loan comes back as its loans repay. Lowering the target again waits `FLOAT_DELAY` (3 hours), then anyone calls `applyFloatBps`.

## How it behaves

The PoolManager's lock tells a swap from everything else.

| | During a swap (PoolManager unlocked) | Otherwise (LP entries and exits, the keeper) |
|---|---|---|
| Deposits | Always accepted; they join the float and the swap float | Accepted, except while the vault settles a finished loan |
| Withdrawals | Up to the swap float, from the float only, and only to settle what the hook already owes the PoolManager (a swap's settlement; otherwise `NotASwap`) | The float and the vault's free cash, the vault paying first what the float cannot spare above the swap float's share of what stays; none while the vault settles |
| The gage vault | Never called, not even read | Called as needed |
| Share price | The vault's value as of the last call outside a swap | The vault's live value |

- **The float lives inside the PoolManager** as the source's ERC-6909 claims on the token. Its tokens never leave the PoolManager. That has two effects:
  - When the hook takes a swap's input before the swapper pays (OpenZeppelin's reserves warning), the PoolManager's reserve includes the float. A token whose liquidity sits mostly in rehypo pools stays tradeable without anyone topping up the PoolManager.
  - A v4 flash borrower still finds the float.
- **The swap float.** It follows each swap exactly, grows only by an LP entry's share of the backing, and resets to the float at each keeper rebalance, never above the float target; past the keeper's band, never above the scaled cap (below), unless it was already higher. A sweep the vault refuses (paused by its curator, or in a purchase second) leaves the float above the target, and swaps still see only the target. An LP exit lowers it by the exit's share when the vault's free cash pays the rest of the exit, so an exit as large as the float leaves swaps open, even at a price past the keeper's band, where a rebalance reopens them only thinly. When the vault cannot pay its part, the float pays it, and the swap float falls by as much more (see "Limits and risks"). The first deposit sets it, whatever the source already holds. A float-only side, whose whole backing is float and which never rebalances, keeps it at its float on every LP entry and exit, so no donation or rounding remainder can narrow its swaps. An LP who adds liquidity cannot deepen swaps by its whole deposit and arbitrage against it.
- **The float target is a setting, not a constant.** The partner picks it at creation (1% to 100%) and its Safe changes it with `setFloatBps`.
  - Raising it, which keeps more for swaps and exits, applies at once.
  - Lowering it, which lends more of the LPs' tokens, waits 3 hours (`FLOAT_DELAY`), as a vault's "Cash kept free" does. Then anyone calls `applyFloatBps`.
  - A raise in the meantime drops the queued lower target.
- **The keeper's `rebalance(minSqrtPrice, maxSqrtPrice)`:**
  - moves the float toward `floatBps` of the backing;
  - sweeps the excess into the vault (at least one whole unit, the vault's minimum) or refills from the vault's free cash;
  - leaves the swap float at the float, never above the target, while the pool's price is inside the keeper's band;
  - past the band, still sweeps or refills (the vault's moves read no price), but leaves the swap float at most at the scaled cap, or where it was if that is more, and never above the float or the target: 1% of the target (`PAST_BAND_BPS`) times the square of the price's ratio to the band's edge it is past ((s)^4 in sqrt prices, rounded down at each step), so the further a price is pushed, the thinner the float it meets;
  - runs only outside swaps, and never while the vault settles.
  - gage's keeper calls it every five minutes, whatever the pool's price, when the float is below half or above one and a half times its target, or the target changed and the float has not reached it (a raise to 100% included), and never for less than one whole unit.
  - It also calls it when the swap float is below half of what a rebalance leaves it at (the float, never above the target; past the band, the scaled cap above) and that is at least one whole unit (past the band, any amount above zero): the rebalance reopens swaps an LP exit stopped or narrowed, and moves nothing through the vault when the float is on its target. Swaps alone call for it only while the swap float trails the float (after an LP entry no sweep followed, or a sweep the vault refused or capped). Past the band, with swaps narrowed under half the target, that reopen is the scaled one, sent again whenever the price comes back far enough to double the cap; the keeper gives traders 10 minutes to bring the price back. Once the price is back inside the band, its next pass opens swaps in full. While swaps stay stopped (the swap float under one whole unit) and no rebalance can reopen them, or past the band they are still narrowed after the 10 minutes, gage is told.
- **The settlement window.** From a loan's end until anyone calls the vault's `settle`, LP entries and exits wait: nobody moves at a price a write-off is about to lower. Swaps go on. gage's keeper settles every vault of its generations every 30 seconds.
- **Rewards and pockets.**
  - `claimPockets` brings pocket proceeds in. What they pay in the token (a repaid loan's earnings, a write-off's backing) is held out of the float and joins it, and the LPs' price, linearly over a day (`RELEASE`).
    - Anyone may claim a pocket and its amount is public. Joining at once, it would go to whoever held LP shares in the claim's second, a flash entrant included.
    - A claim while earlier proceeds release restarts the day for all of them, so nothing joins faster than a day after its own claim.
    - Until then the proceeds stay as claims that no swap, exit or sweep spends; `unreleased()` shows them.
  - `claimRewards` brings the vault shares' sGAGE in.
  - `forward(token)` sends sGAGE and recovered collateral to the beneficiary. These tokens are not the hook's backing, so the partner decides how its LPs get them. The source's own token and the vault's shares never leave through `forward`.
  - Anyone may call these three. gage's keeper keeps successful pocket and reward claims on separate daily clocks;
    pocket claims stay daily because they restart the release. Failed reward work retries on the next maintenance
    pass, and already-held sGAGE or recovered collateral is checked for forwarding every pass without restarting it.
- **A float-only side can start lending later.** The owner proposes a vault (`proposeVault`), and `attachVault` takes it three days later. LPs get three days' notice before their tokens are lent.

## Exit now

An LP whose share of the pool is more than the source can pay now (the float, what the exit desk owes the source and the vault's free cash) can leave at once instead of waiting for loans to repay. Any LP may, up to its own share; what the sales pay is held an hour.

1. **Exit now.** The LP calls `exitNow(id)` on each source whose side it cannot take; a float-only side never needs it.
   - The source reads the LP's share from the hook's own LP token: OpenZeppelin's hook is an ERC-20 of LP shares.
   - It commits, at the exit desk its vault's factory names (`IntentExitDesk`), the vault shares that its float and the desk's debt cannot cover of that share. The desk lists vault holding `id`, falling to book only for what the vault cannot pay. The app picks `id` as a vault page's Exit now does; `0` lists nothing, so a listing still live goes on, or the protocol's keeper lists the next.
   - The commitment is the larger of the one still open and this LP's, never their sum: asking again, or from a second address, commits nothing more, and several LPs leave one after the other.
   - `NothingToExit` when the source can pay the LP now; `NoExitDesk` while the protocol has closed exits.
2. **The sale.** A buyer vault takes the holding once its price has fallen. The sale redeems the source's committed shares in its own transaction, and the desk owes the source what they paid. That debt counts in the source's backing, so no LP's value moves, and in `maxWithdraw`, but not in the float: no swap takes it, no rebalance sweeps it, and no new loan can lend it.
3. **The removal.** The LP removes its liquidity as usual. An exit the float cannot spare collects the desk's whole debt into the float first, before the vault's free cash.

- **The hour.** What the sales pay is held for an hour from the last ask (`EXIT_HOLD`, `exitHeldUntil`). Until then only an LP's withdrawal collects it, and `rebalance` sweeps nothing. After it anyone may call `endExit()`: what is still committed is withdrawn, so no listing sells loans for an LP that has left, and what the desk owes joins the float for the next rebalance to lend. gage's keeper does it on its next pass. An LP who has not removed by then asks again.
- **While exits are closed** (the factory names no desk), no exit starts. A commitment and what the desk owes stay at the desk the factory bound: LP exits still collect it, and `endExit` still ends it.
- **What the LP gives up.** As any holder leaving through the desk, the LP leaves at book and gives up its share of the interest the loans have still to earn. The stayers keep theirs: the commitment never exceeds the LP's share beyond what the float and the desk's debt cover.

## Deviations from ERC-4626, all deliberate

- **One depositor, bound once.** `maxDeposit` and `maxWithdraw` are zero for anyone else, and shares never transfer. The hook holds every share, so price rounding never moves value between holders.
- **`totalAssets` counts only the vault shares the source bought itself.** A vault's shares transfer, and shares sent to the source would let their holder swap lent shares it cannot redeem for the LPs' float around an LP's entry and exit. Shares sent here stay unvalued.
- **During a swap, `totalAssets` values the vault shares as of the last call outside a swap.** A swap never reads the vault. With one holder, a stale value only changes how many shares a swap's deposit mints, never anyone's claim.

## Limits and risks

- **A swap can take at most the swap float.** A sale larger than the float of the token sold needs the PoolManager to hold that much of it. The float is there, and other pools' reserves may add more.
- **An LP exit beyond the float and the vault's free cash waits** until loans repay (up to their term: 7 or 21 days), unless the LP exits now through the desk (above), which sells loans down to book for it.
- **An LP who asks to exit now and never removes** leaves the sales' cash idle for the hour, and the stayers bear their part of the interest the sale gave up, at most that LP's share. An LP can ask again each hour while its share stays more than the source can pay.
  - The share is read when the LP asks. Someone who borrows LP shares for that one transaction (outside an unlock: a v4 flash loan cannot reach `exitNow`) commits as if it held them.
  - Someone who asks and also runs a buyer vault can buy what its own ask listed, near book, and keep the interest still to come that the pool's LPs gave up, less the protocol's share. Today only admitted creators run vaults and only gage's signed plans buy; this matters once vaults open to anyone.
- **The source's code has 1,988 bytes of room.** The factory keeps the source's whole creation code in its data contract, whose runtime counts against EIP-170: on mainnet it holds 22,588 of the 24,576 bytes allowed. Any change to the source means a new factory (the deployed one keeps its code for good), and a change past that room must make room first.
- **An exit the vault cannot pay its part of narrows swaps, and can stop them.** The vault pays an exit's lent part from its free cash. When that cash is gone (on loan, taken first by the vault's other depositors, or closed in a fill's purchase second) or the vault refuses (`RewardsPending`), the float pays instead, because LPs can always take the float, and the swap float falls to what is left.
  - An exit of the whole float and the vault's free cash leaves a swap float of zero, and OpenZeppelin's hook then refuses swaps both ways. Nobody needs a bug for it: a large LP can do it alone, and an LP who also deposits in the vault (taking its free cash first) or who exits in a fill's purchase second needs a stake only the size of the float.
  - An LP entry after it does not reopen swaps: it scales a swap float of zero, so the float can sit on its target with swaps stopped.
  - Inside the keeper's band, gage's keeper reopens swaps on its next pass, on what the float holds or on the vault's free cash, which it refills. With no float and no free cash, swaps stay stopped until loans repay (up to 7 or 21 days) or an LP enters. During a reward outage only a `rebalance` that moves nothing through the vault goes through.
  - Past the band, which is cheap to cross on a stable pool once an exit has thinned the float, a rebalance opens swaps to at most the scaled cap, or leaves them where they were if that is more. OpenZeppelin's hook builds liquidity from the swap float as about `amount / sqrtP` on the side a push favours, so a fixed 1% backed ever more depth the further the price was pushed: in a review a push 99% below the band and a trade back took +12,798 USDG (+72,596 at 99.8%) on a 16,000 USDG target. The square of the price's ratio to the edge holds one round to about a sixteenth of the depth at the edge (160 USDG on that target), on either side and for either token order. gage's keeper sends the scaled reopen and waits 10 minutes for the price to come back. Recovery needs only a trade back toward parity: arbitrage, or anyone's small swap. Once the price is back inside the band, the keeper's next pass opens swaps in full.
    - Measured with OpenZeppelin's hook on that target (`integrations/lender-amm/test/RehypoSourcePlug.t.sol`, `test_aRound*IsBounded`), on about 200, 20 and 1 USDG of float left for the push: at 99% below the pusher nets -1,618.9, -160.7 and -6.8 USDG a round; the best case for a pusher is +9.6 USDG at 75% below on a 1 USDG float, 0.060 of the edge depth. Over a stretch, trading back in steps between the keeper's passes, each reopening to the cap nearer the edge, a pusher takes at most about a quarter of the edge depth (about 40 USDG; `test_aTradeBackAcrossTheKeepersPassesPaysUnderAQuarterOfTheEdgeDepth`). gage accepts that bound rather than limit the keeper to one reopen a stretch.
    - Far out the cap rounds down to zero (on that target, below about 0.008% of the lower edge's price or above about 12,600 times the upper edge's): swaps an exit had stopped stay stopped at that price. The rescue is one batch from the partner's Safe.
    - The band is fixed around a price of about one, so rehypo pools are for stable pairs for now; a pair whose price moves on its own needs a band that follows the market, which is not built.
    - If the price is still out after 10 minutes, gage steps in: in a real depeg swaps stay thin until the price returns, or until gage and the partner agree a new band.
    - gage never sends a rebalance with a widened band. It would reopen the full float at the pushed price, and trading back on it paid the same pusher in the review: 9.14 USDG a round at 5% off, 119.67 at 20%.
- **A reward outage refuses moves through the vault.** While the vault cannot claim a loan's sGAGE in full, every move through it reverts `RewardsPending`: an LP exit larger than the float (one the float can pay goes through from the float, above), and the keeper's sweeps and refills. `maxWithdraw` does not show it. For an active loan (not yet repaid or ended) a harvest (`harvestRewards`) clears it only within its own second: the loan earns sGAGE every second, and the next move must claim it again. The refusal lasts as long as the claim fails and ends with the first move after it works again, harvest or not. A loan the core has closed earns nothing more, whether the vault has booked it yet or keeps its record after a short claim: a harvest that collects it clears the refusal for good. Entries and swaps go on.
- **Gas grows with the vault's open loans.** An LP exit, small ones included, and every keeper move claim the sGAGE of each loan the vault holds (up to 64, whoever's cash funded it). At 64 loans, each claimed for the first time, one exit takes about 7.7M gas on a lend-asset vault and about 20M on USDG's, which sits on the bridged core. The heaviest case is a USDG pool's hook removing both legs in one transaction while every loan is repaid but not yet booked, with USDG's vault keeping all its free cash in its Morpho reserve, as both funded mainnet USDG vaults do: about 28.4M in the tests. The reserve's own reads and one withdrawal from it (19 reads in all) add about 1.4M on mainnet, measured on a fork. That is about 29.9M of the chain's 32M per-transaction cap, leaving about 2.1M for the transaction's own costs (the 21,000 base and Nitro's L1 data charge) and the hook's work; the tests add 1.5M for the reserve and fail if less than 2M is left. If the other leg's vault also held shares in a reserve as costly to read, the removal would need about 1.5M more: about 31.4M, still under the cap but inside the 2M the tests keep free, so such a pool needs its own measurement first. A swap's settlement never calls the vault: about 160k gas at any book.
- **A borrower who walks away lowers the vault's price,** and with it the LPs'. Its collateral reaches LPs only as the partner decides, through the beneficiary.
- **Pocket proceeds go to the LPs who hold while they release.**
  - An LP who leaves inside the day leaves its part of what is still releasing to those who stay.
  - Someone who enters for the day takes its share of it, as any LP does.
  - If every LP leaves, what is still releasing stays in the source with its virtual shares (six decimals of offset), and a new seed keeps what it pays.
- **The source holds LPs' money.** It needs a review and its own testnet rehearsal before mainnet, and it is in the audit scope.
- **The hook is the partner's.** OpenZeppelin marks `ReHypothecationHook` experimental, and the partner audits what it deploys.
