# Lender AMM

A DEX can lend the idle part of a Uniswap v4 pool's liquidity through gage. gage gives each partner DEX a reference kit: a
hook built on OpenZeppelin's `ReHypothecationHook` (uniswap-hooks v1.3.0-rc.0, a release candidate), a deploy script and a
keeper. The DEX deploys its own copy and has it audited. gage deploys none, and the kit is unaudited, like the OpenZeppelin contract it builds on,
which OpenZeppelin marks experimental.

## How it works

* **One partner vault per pool token.** A pool pairs USDG with a token gage lends: GLD, NVDA or HIMS today. Each side has
  its own [partner vault](https://docs.gage.cash/earn/partner-vaults), created on that token's loan engine by the DEX's Safe. The Safe
  stays its manager for good. It writes the vault's rules: what it lends against, the term, the performance fee, and the
  "Cash kept free" each loan must leave.
* **A float for swaps.** The hook keeps part of each token itself. A swap's liquidity comes from the float alone, so a
  swap never calls a vault.
* **A keeper.** Outside swaps, the keeper refills the float from the vault's free cash and sweeps the excess back, toward a
  target the Safe sets for each token. It moves tokens only between the float and the vault, and only while the pool's
  price is close to a reference pool's.
* **Shares.** Liquidity providers hold the hook's shares. A share is priced on the float plus the vault shares the hook
  bought itself, at the vault's own price, so each loan's fixed-cost return accrues to the shares as it runs. Vault shares
  sent to the hook count for nothing. Swap fees go to the float.
* **Rebalancing.** Price and arbitrage only. The hook trades nowhere else.

Liquidity providers lend through the vaults. You may end up holding the collateral instead of USDG. A stock-token
vault lends against memes: memes can go to zero, and if the borrower walks away, the vault holds it.

## Providing and removing liquidity

* **Adding** puts the tokens in the float, in the ratio of the hook's holdings; the keeper sweeps what the float does not
  need into the vaults.
* **Removing** is paid from the float first, then from the vaults' free cash. What is lent comes back when its loans repay,
  so a large exit can wait. Early exits empty the float first, and swaps have less depth on that side until the keeper
  refills it.
* **At the end of a loan's term,** until the loan is settled, a vault takes no deposit and pays no withdrawal: its price
  still counts the loan, which a walk-away is about to change. The hook waits with it: adding, removing and the keeper wait
  too, and swaps carry on from the float. Anyone may settle the loan.

## What the hook does and never does

* **Never calls a vault inside a swap.** A vault's own checks and its reward bookkeeping never touch a swap.
* **Only the Safe starts the pool.** Only the hook's owner may initialize the pool, and only with the pool key the hook was
  built for; only the owner seeds the first liquidity. This answers OpenZeppelin's warnings that initialization is
  permissionless and that a seed can be front-run.
* **The keeper cannot take tokens.** It moves them between the float and the vault, and claims the vaults' earnings
  claims into the float.
* **The owner cannot take backing.** It names keepers and sets the float targets within bounds. It passes on what is not
  pool backing, such as sGAGE rewards and a walk-away's collateral.

## Risks

* **Experimental base.** OpenZeppelin publishes `ReHypothecationHook` as experimental software, as is. Have your deployment
  audited.
* **Liquidity at a pushed price.** A price pushed away from the market must not draw a refill, which would deepen the pool
  there. The keeper refills only within its price band, and the hook refuses a move whose pool price is outside it.
* **The pool manager's reserves.** The hook takes a swap's input from the Uniswap v4 pool manager before the swapper pays,
  so a swap larger than the manager's balance of that token waits until the manager holds enough.
* **A custom range.** The kit uses the full range. A range that follows the price lets a cheap swap force liquidity in at
  a poor price.
* **Lent tokens.** A walk-away lowers the vault's price at its settle, and the share price with it.
