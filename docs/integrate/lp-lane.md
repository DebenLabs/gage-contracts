# LP lane: borrow against LP positions, lend to them

The LP lane lends USDG at a fixed cost against a concentrated-liquidity position: a Uniswap v3 or v4 position NFT, or a position of another format its adapters read, in a pool the lane admits. It has its own contracts, apart from the Intent core and its partner vaults. A borrower pledges one position on a quote gage's rates service signs for that exact position, and gets USDG at once. **No liquidation:** nothing can touch the position before the loan's end; it never closes early because a price moves. Before the end the borrower repays and takes the position back. Not repaid by the end, the position is unwound for the lenders, and the borrower keeps the USDG. Lenders deposit USDG into an LP vault, an ERC-4626 vault a curator runs, which funds loans only in the pools its mandate names. Use this page to build a borrow or lend flow, to read the lane's state, or to settle and index its loans. The product view is [Borrow against LP positions](https://docs.gage.cash/borrow/lp-lane).

## Contracts

| Contract | Address | Source | ABI | Who controls it |
| --- | --- | --- | --- | --- |
| LPCore | `0x8EDedDadA6be6C81cD838a028910ADDA29365c50` | [LPCore.sol](../../src/lp/LPCore.sol) | [LPCore.json](../../abi/LPCore.json) | Nobody: no owner, no upgrade. It reads its settings from the registry. |
| LPRegistry | `0xdFCFe33eB08E63dD1f8B7cBCd49f5E960BC85bBC` | [LPRegistry.sol](../../src/lp/LPRegistry.sol) | [LPRegistry.json](../../abi/LPRegistry.json) | Its owner (`owner()`, `Ownable2Step`): the multisig that owns gage's registries ([Contracts](https://docs.gage.cash/developers/contracts)). Every setting has a compile-time bound. |
| LPEscrow implementation | `0xe19aae63b2A235C807b89Ff32eF7508237B18b86` | [LPEscrow.sol](../../src/lp/LPEscrow.sol) | [LPEscrow.json](../../abi/LPEscrow.json) | The core, written into its code. Each loan gets its own EIP-1167 clone (`LoanOpened.escrow`, `loan(id).escrow`). |
| UniV3PositionAdapter | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` | [UniV3PositionAdapter.sol](../../src/lp/adapters/UniV3PositionAdapter.sol) | [UniV3PositionAdapter.json](../../abi/UniV3PositionAdapter.json) | The core only. Uniswap v3's position manager, `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`. |
| RamsesV3PositionAdapter | `0xdc2001A57912164Ecb8139b7D3121955AE3A9320` | [RamsesV3PositionAdapter.sol](../../src/lp/adapters/RamsesV3PositionAdapter.sol) | [RamsesV3PositionAdapter.json](../../abi/RamsesV3PositionAdapter.json) | The core only. Positions of `0x2eBd7B85a4E08D5B508b04BA147976C94afE6590`; the one adapter that names reward tokens (`rewardTokens()`). |
| UniV3PositionAdapter | `0xd9aF6b4BCf9eE6b0bF84279C8d1FD72071cdF2e8` | [UniV3PositionAdapter.sol](../../src/lp/adapters/UniV3PositionAdapter.sol) | [UniV3PositionAdapter.json](../../abi/UniV3PositionAdapter.json) | The core only. A second position manager with Uniswap v3's interface, `0x51d0e5188afe12d502e29D982d20C190e7816107`. |
| UniV4PositionAdapter | `0xc3dE275A11e0B3783770882F5c4E640eaE45833C` | [UniV4PositionAdapter.sol](../../src/lp/adapters/UniV4PositionAdapter.sol) | [UniV4PositionAdapter.json](../../abi/UniV4PositionAdapter.json) | The core only. Uniswap v4's PositionManager, `0x58daec3116aae6D93017bAAea7749052E8a04fA7`; hookless pools only. |
| FablesPositionAdapter | `0xbaFCd70B060ed26F5a2Cb67e43fe030Cf8981793` | [FablesPositionAdapter.sol](../../src/lp/adapters/FablesPositionAdapter.sol) | [FablesPositionAdapter.json](../../abi/FablesPositionAdapter.json) | The core only. Positions of the wrapper below. |
| FablesPositionWrapper | `0x1a8e8F0aab1C9e58827D86EbAE29Bc3e79CC1B2b` | [FablesPositionWrapper.sol](../../src/lp/fables/FablesPositionWrapper.sol) | [FablesPositionWrapper.json](../../abi/FablesPositionWrapper.json) | Nobody: no owner, no fee, not upgradable. An ERC-721 over the receipts of the hook `0x06a889870C8f83640D6816319f72e2aA579b6080`. |
| FablesShareHolder implementation | `0xa62edA23A8877912fb938Ed1eBD1BCde4465cC68` | [FablesShareHolder.sol](../../src/lp/fables/FablesShareHolder.sol) | [FablesShareHolder.json](../../abi/FablesShareHolder.json) | The wrapper, written into its code. One EIP-1167 clone per wrapped position. |
| LPVaultFactory | `0xDDd6afeA325F20Bba4Df0A5a7DB307524bbcbF77` | [LPVaultFactory.sol](../../src/lp/LPVaultFactory.sol) | [LPVaultFactory.json](../../abi/LPVaultFactory.json) | Nobody: no owner, no fee. Who may open a vault is the registry's `mayOpenVault(account)`. |
| LPVault | One per vault: the factory's `vaultsFrom(start, count)` | [LPVault.sol](../../src/lp/LPVault.sol) | [LPVault.json](../../abi/LPVault.json) | Its curator (`CURATOR()`), for its funding switch, its largest loan and its mandate. The curator never moves depositors' USDG. |
| UniV3SwapExecutor | `0xd5309aB57BdfaEF1491dB0c91D5c4d1D4c8d814F` | [UniV3SwapExecutor.sol](../../src/lp/executors/UniV3SwapExecutor.sol) | [UniV3SwapExecutor.json](../../abi/UniV3SwapExecutor.json) | Nobody; stateless. Sells WETH in `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`, the Uniswap v3 WETH/USDG 0.01% pool. |
| UniV3TwoHopSwapExecutor | `0x8Cd6E727C3679649bae14CE9d223E837B906852b` | [UniV3TwoHopSwapExecutor.sol](../../src/lp/executors/UniV3TwoHopSwapExecutor.sol) | [UniV3TwoHopSwapExecutor.json](../../abi/UniV3TwoHopSwapExecutor.json) | Nobody; stateless. Sells `0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802`, a reward token RamsesV3PositionAdapter names, for WETH in `0x5860dD468B4FC1740EaF80a3b7F22e78D70a076a`, then WETH for USDG in `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`. |
| UniV3SwapExecutor | `0x1035E23DF3ac7bf9693dbB5a9F3C0eFe2C2760ad` | [UniV3SwapExecutor.sol](../../src/lp/executors/UniV3SwapExecutor.sol) | [UniV3SwapExecutor.json](../../abi/UniV3SwapExecutor.json) | Nobody; stateless. Sells NVDA in the Uniswap v3 NVDA/USDG 0.05% pool, `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3`. |
| UniV4SwapExecutor | `0xa26570618E08218BF3fFd5bB96382D72Eb2F2ECe` | [UniV4SwapExecutor.sol](../../src/lp/executors/UniV4SwapExecutor.sol) | [UniV4SwapExecutor.json](../../abi/UniV4SwapExecutor.json) | Nobody; stateless. Sells SPY in the Uniswap v4 SPY/USDG 0.3% pool (`poolKey()`), through the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. |
| UniV3SwapExecutor | `0xEC03f72f59e68b4757c6Ef17295Ae1c18dfD4A46` | [UniV3SwapExecutor.sol](../../src/lp/executors/UniV3SwapExecutor.sol) | [UniV3SwapExecutor.json](../../abi/UniV3SwapExecutor.json) | Nobody; stateless. Sells GLD in the Uniswap v3 GLD/USDG 0.3% pool, `0x7A6A053eCCf1446A2633E05aA6D40D09381997ec`. |

The shared types (`PositionFacts`, `LoanState`, `Loan`, `LoanQuote`, `UnwindQuote`, `SaleQuote`, `PoolConfig`, `PoolRef`) are in [LPTypes.sol](../../src/lp/LPTypes.sol). The manifest key `lpLane.startBlock` is the block the lane's contracts start at.

### Admitted pools

The registry keys a pool by its adapter and its address. A Uniswap v4 pool has no address of its own: the lane names it by the low 160 bits of its pool id (`poolAddress(key)` on the v4 and wrapper adapters), and the manifest gives the id as `poolId`. Names are as gage's public deployment API gives them (`https://gage.cash/api/deployment`, `deployment.lpLane.pools[].name`).

| Manifest entry | Name | Adapter | Pool |
| --- | --- | --- | --- |
| `lpLane.pools.0` | Ramses WETH/USDG | `0xdc2001A57912164Ecb8139b7D3121955AE3A9320` | `0xFAE65eAa11943f45E83D5B45DC7A7C801C51bfB0` |
| `lpLane.pools.1` | Uniswap v3 WETH/USDG 0.05% | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` | `0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a` |
| `lpLane.pools.2` | Uniswap v3 WETH/USDG 0.01% | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` | `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca` |
| `lpLane.pools.3` | SushiSwap v3 WETH/USDG 0.05% | `0xd9aF6b4BCf9eE6b0bF84279C8d1FD72071cdF2e8` | `0x9B050cb1F265094b0977160a2BD7dA8C9E529c3C` |
| `lpLane.pools.4` | Uniswap v4 ETH/USDG 0.05% | `0xc3dE275A11e0B3783770882F5c4E640eaE45833C` | `0x2693Dba1b9B3520f573CABdfe033384a24125982` (pool id's low 160 bits) |
| `lpLane.pools.5` | Fables ETH/USDG | `0xbaFCd70B060ed26F5a2Cb67e43fe030Cf8981793` | `0x99a56756E954e59247E497bad1D25A4334BdE551` (pool id's low 160 bits) |
| `lpLane.pools.6` | Uniswap v3 NVDA/USDG 0.05% | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` | `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` |
| `lpLane.pools.7` | Uniswap v4 SPY/USDG 0.3% | `0xc3dE275A11e0B3783770882F5c4E640eaE45833C` | `0x6d45bf5bA67443dDB1435e28B2E48dF2Fc1526cD` (pool id's low 160 bits) |
| `lpLane.pools.8` | Uniswap v3 GLD/USDG 0.3% | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` | `0x7A6A053eCCf1446A2633E05aA6D40D09381997ec` |
| `lpLane.pools.9` | Uniswap v3 GLD/USDG 0.05% | `0x6cEE9304e8f759Edf6BadCdE1d64b01Fb022872a` | `0xBA2f1ed4cEB2169D538d1e614D847E83C5A55913` |

The two ETH/USDG v4 pools (entries 4 and 5) hold native ETH: their pool key's `currency0` is the zero address, while the manifest's `token0` is WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, because the lane reads, collects and unwinds that ETH as WETH. USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` has 6 decimals; WETH, NVDA, SPY and GLD have 18.

### Settings

Read them on chain: the owner may change any of them within its bound. The values below are the ones the registry held when this release was exported.

| Read | At this release | Bound in the source |
| --- | --- | --- |
| `terms()` | 604,800 s and 1,814,400 s (7 and 21 days) | `MIN_TERM` 1 day to `MAX_TERM` 30 days, at most `MAX_TERMS` (8) |
| `feeBps()`, the origination fee | 35 (0.35% of the principal, taken when the loan opens) | `MAX_FEE_BPS` 200 |
| `ltvCapBps()` | 7,500: the principal is at most 75% of the signed collateral value | `MAX_LTV_BPS` 9,000 |
| `lateUnwindDelay()` | 172,800 s (2 days) | 1 to 14 days |
| `dailyOriginationCap()` | 1,000,000 USDG (raw `1000000000000`) a UTC day | `MAX_DAILY_ORIGINATION` 100,000,000 USDG |
| `poolConfig(adapter, pool)` | Every pool above: `allowed`, `minHalfWidthTicks` 0, a loan from 100 to 100,000 USDG, `maxOutstanding` set per pool | A loan at most 10,000,000 USDG, outstanding at most 100,000,000 USDG |
| `newLoansPaused()` | `false` | Stops `borrow` and `roll` only |
| `openCreation()` | `true`: anyone may open a vault (`mayOpenVault(account)`); `curatorAllowed` names the curators allowed before | |
| `feeRecipient()` | The DealFeeRouter, `0xEaE95cD11e1105BF1E82033c918ff17f931B0245` | |
| `quoteSigner()` | A key of gage's rates service | |

On the core, `MAX_COST_BPS_PER_YEAR` (5,000) bounds every loan's fixed cost to `principal × 5,000 × term / (365 days × 10,000)`, whatever a quote says: on 1,000 USDG, at most about 9.59 USDG (0.959%) for 7 days and about 28.77 USDG (2.877%) for 21 days. That is a ceiling; each quote names its own cost.

Nothing can be borrowed until a curator opens a vault and depositors fund it: read the factory's `vaultCount()` and each vault's `freeCash()`.

## How it works

1. **Quote.** gage's rates service values one exact position (its pool, range and liquidity at the pool's price), and signs a `LoanQuote` (EIP-712, domain `"gage LP lane"`, version `"1"`, the core as verifying contract). The quote names the borrower, the vault, the adapter, the position's id, its least liquidity and its exact range, the collateral value, the principal, the repayment, the term, the fee and a deadline. It is single use (`quoteUsed(digest)`).
2. **Borrow.** The core checks the quote against the registry and against the position as its adapter reads it now, clones a fresh escrow, moves the NFT into it, has the vault send exactly the principal, and credits the borrower the principal less the fee. The core reads no price: the quote carries it.
3. **While it runs.** The position stays in its escrow, with its liquidity in place and its range unchanged. A position that leaves its range still secures the loan as it is. Only the borrower may collect its fees and its adapter's rewards, credited on the core. The borrower may roll the loan into a new one on the same position.
4. **Before the end:** anyone repays the exact `repayment`; the borrower takes the position back with `returnPosition`.
5. **From the end:** the loan can no longer be repaid. It is settled for its vault: the rewards are claimed, all its liquidity is removed and every token (the liquidity, its fees, its rewards) goes to the vault. gage's keeper settles with a signed `UnwindQuote` that sets the least amounts out; from `end + lateUnwindDelay()` anyone may settle with no least amounts. The emptied NFT stays in the escrow. The borrower keeps the USDG, and nothing else is taken.
6. **The vault after a default.** USDG arrives at once; every other token waits as a lot until it is sold for USDG through the registry's executor for that token, on a signed `SaleQuote`. What comes back first restores the loan's book value (principal plus its net return) to the share price; anything above is that loan's bonus, set aside for the lenders who held shares while it ran.

Everything owed to an account is credited and pulled by that account: the core's `credit(account, token)` and `withdraw(token)`, the vault's `feeCredit(account)` and `bonusClaimable(loanId, account)`.

### What needs gage, and what is open to anyone

| Step | Who may call | Needs gage |
| --- | --- | --- |
| `borrow`, `roll` | The quote's borrower | A `LoanQuote` signed by `quoteSigner()`: gage's rates service, which gage's app at https://gage.cash asks |
| `repay` | Anyone, before the end | No |
| `returnPosition`, `collectFees`, `claimRewards` | The borrower | No |
| `withdraw(token)` / `withdrawFor(account, token)` | The account / anyone, paid to the account | No |
| `settleDefault` | Anyone holding a signed `UnwindQuote`; gage's keeper by default | The unwind quote |
| `settleDefaultLate` | Anyone, from `end + lateUnwindDelay()` | No |
| `abandonDefault` | Anyone, from `end + lateUnwindDelay() + ABANDON_DELAY` (14 days) | No |
| `recoverAbandoned` | Anyone holding a signed `UnwindQuote`; gage's keeper by default | The unwind quote |
| Vault `sell` | Anyone holding a signed `SaleQuote`; gage's keeper by default | The sale quote |
| Vault `deposit`, `mint`, `withdraw`, `redeem`, `claimBonus`, `claimBonusFor` | Anyone, for their own shares | No |
| Vault `writeOffRecovery` | The curator from `WRITE_OFF_DELAY` (7 days) after a delivery, anyone from `OPEN_WRITE_OFF_DELAY` (30 days) | No |
| Factory `create` | Anyone while `openCreation()` is true (it is), else a curator the registry allows | No |
| Every registry setting | The registry owner | Yes |

gage's keeper also pays the protocol's credits to the fee recipient (`withdrawFor(feeRecipient, USDG)` on the core, `withdrawFeeFor(feeRecipient)` on each vault).

## Call sequences

Amounts are raw token units: USDG has 6 decimals, so 100 USDG is `100000000`. Times are unix seconds; terms are seconds.

### Borrow against a Uniswap v3, v4 or v3-style position

1. **Check the position.** On its adapter, `facts(uint256 tokenId) returns (PositionFacts)` gives `{ pool, token0, token1, tickLower, tickUpper, liquidity }`. The core will take it only if:
   * `registry.adapterAllowed(adapter)` and `adapter.core()` is the core;
   * `registry.poolConfig(adapter, facts.pool).allowed`;
   * `tickUpper − tickLower ≥ 2 × minHalfWidthTicks` (0 on every pool at this release);
   * `liquidity > 0` and `token0 != token1`.

   `UniV4PositionAdapter.facts` reverts `HookedPool(address hooks)` for a position in a hooked pool.
2. **Get a quote.** gage's rates service signs a `LoanQuote` for this borrower, position, term and vault; gage's app asks it when a wallet borrows. You cannot sign one yourself: the core accepts only `quoteSigner()`'s signature. Check it before you send it: its `tickLower`, `tickUpper` match the position, its `liquidity` is at most the position's, its `feeBps` is `registry.feeBps()`, `principal × 10,000 ≤ collateralValue × ltvCapBps()`, `repayment ≥ principal`, `term` is in `terms()`, and `deadline` is still ahead. `loanQuoteDigest(LoanQuote calldata quote) returns (bytes32)` gives the digest the signer signed.
3. **Approve the position** to the core on its position manager (`adapter.positionManager()`): `approve(address to, uint256 tokenId)` (Uniswap v3), `approve(address spender, uint256 id)` (Uniswap v4), or `setApprovalForAll`. The core moves it with `transferFrom`, never `safeTransferFrom`.
4. **Borrow**, from the borrower's own wallet (`msg.sender` must be `quote.borrower`), no later than `quote.deadline`:

   ```solidity
   function borrow(LoanQuote calldata quote, bytes calldata signature) external returns (uint256 loanId);
   ```

   The position moves into a fresh escrow, and the vault funds the principal. The core credits the borrower `principal − fee`, with `fee = principal × feeBps / 10,000` rounded down. The position must still have the quoted range and at least the quoted liquidity; more only adds collateral. The loan ends at `block.timestamp + term`.
5. **Take the USDG:** `withdraw(address token) returns (uint256 amount)` with USDG pays the caller's whole credit in it. Example: 1,000 USDG lent at 0.35% credits 996.50 USDG; the repayment is the quote's `repayment`.

### Hook receipts: wrap them first

The pool behind FablesPositionAdapter holds its liquidity providers' shares as ERC-6909 receipts of the hook `0x06a889870C8f83640D6816319f72e2aA579b6080`, not as NFTs. FablesPositionWrapper turns the receipts of one range into one position NFT, and the lane borrows against that NFT.

1. Let the wrapper move the receipts, on the hook (ERC-6909): `approve(address spender, uint256 id, uint256 amount)` for the range's id (`rangeId(PoolId poolId, int24 tickLower, int24 tickUpper)`), or `setOperator(address spender, bool approved)` with the wrapper and `true`.
2. On the wrapper:

   ```solidity
   function wrap(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 shares, address to) external returns (uint256 tokenId);
   ```

   `key` is the pool's v4 key, with `hooks` the hook (`WrongHook(address hooks)` otherwise); `shares` are receipts, 1:1 with liquidity. A fresh FablesShareHolder clone holds them, and the NFT is minted to `to` (`Wrapped`).
3. Borrow as above, with the wrapper as the position manager and FablesPositionAdapter as the adapter.

The NFT's owner, or an account it approved, may also call `unwrap(uint256 tokenId, address to)` (receipts and their fees back, the NFT burned), `withdraw(uint256 tokenId, uint128 liquidity, address to, uint128 min0, uint128 min1, uint256 deadline)` and `collectFees(uint256 tokenId, address to, uint16 maxFeeBps)`. `position(uint256 tokenId)` reads `(key, tickLower, tickUpper, shares, holder, rangeId)`. While a loan runs, the escrow owns the NFT, so only the lane operates it. A wrapped position earns its pool's swap fees; the adapter claims nothing else for it.

### While the loan runs (borrower only, before `end`)

* **Fees:** `collectFees(uint256 loanId) returns (uint256 amount0, uint256 amount1)` collects what the position is owed, credited per token on the core; its liquidity stays. Then `withdraw(token0)` and `withdraw(token1)`, one call per token. A native ETH pool's fees come as WETH. From the end on, the fees belong with the position to the vault.
* **Rewards:** `claimRewards(uint256 loanId)` claims the adapter's rewards (`rewardTokens()`; only RamsesV3PositionAdapter names any) and credits them on the core (`RewardCredited`). That adapter skips a claim within `CLAIM_DELAY` (3 minutes) of the position's last liquidity change; the rewards stay owed for a later claim.
* **Roll over:**

  ```solidity
  function roll(uint256 loanId, LoanQuote calldata quote, bytes calldata signature) external returns (uint256 newLoanId);
  ```

  A new quote for the same adapter and position repays the old loan in full; the position stays in its escrow. Only the difference moves: `net = principal − fee − old repayment`. When `net` is positive, it is credited to the borrower; when negative, the core pulls `−net` USDG from the borrower, so approve the core for it first. The old loan becomes `ROLLED`; `Rolled` gives `net`. The day's cap counts only what the new principal adds over the old.

### Repay and take the position back

1. Approve USDG to the core for the loan's `repayment` (`loan(loanId).repayment`).
2. `repay(uint256 loanId)`, by anyone, while `block.timestamp < end`. The core pulls the repayment from the caller to the vault. At `end` or later it reverts `PastTerm(loanId)`.
3. `returnPosition(uint256 loanId)`, by the borrower. The NFT comes back with a plain `transferFrom`, and any reward tokens that reached the escrow are credited to the borrower (`withdraw` them).

### At the end of the term, unpaid

* gage's keeper calls `settleDefault(uint256 loanId, UnwindQuote calldata quote, bytes calldata signature)` from `end`, with the rates service's least amounts out (`UnwindQuote { loanId, min0, min1, deadline }`, digest `unwindQuoteDigest(quote)`).
* Without it, anyone calls `settleDefaultLate(uint256 loanId)` from `end + lateUnwindDelay()`, with no least amounts. Before that it reverts `LateUnwindNotOpen(uint256 opensAt)`.
* Either way, the rewards are claimed (a failed claim never stops it), all the liquidity is removed, its fees collected and every token sent to the vault (`Defaulted`, the vault's `LoanDefaulted`). The loan is `DEFAULTED`.
* A position no unwind can remove (a halted pool, a token that refuses the vault): `abandonDefault(uint256 loanId)` by anyone from `end + lateUnwindDelay() + ABANDON_DELAY` books a full loss in the vault, and the position stays in escrow. `recoverAbandoned(uint256 loanId, UnwindQuote calldata quote, bytes calldata signature)` unwinds it into the vault later, booked as a recovery.

### Lend: deposit into an LP vault

You may end up holding the collateral instead of USDG: a loan not repaid is settled by unwinding its position into the vault, which holds the tokens it delivered until they are sold.

1. **Choose a vault.** `vaultCount()` and `vaultsFrom(uint256 start, uint256 count)` on the factory list them, oldest first; `registry.vaultAllowed(vault)` says whether it may still fund new loans. On the vault: `mandate() returns (PoolRef[] pools, uint40[] activeAt)` names the pools it funds and from when, and `funds(adapter, pool)` says whether it funds a new loan there now. `PERFORMANCE_FEE_BPS()` is its fee on each loan's return, from 500 to 1,500, a tenth of it the protocol's (`PROTOCOL_SHARE_BPS`); `freeCash()`, `outstandingPrincipal()`, `totalAssets()`, `openLoans()`.
2. **Check it takes deposits:** `maxDeposit(receiver)` is 0 while it is `impaired()` or `depositsClosed()`, else unbounded.
3. **Approve** USDG to the vault for `assets`.
4. **Deposit:**

   ```solidity
   function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);
   ```

   Set `minShares` from `previewDeposit(assets)` less your slippage room. Shares are an ERC-20 (`gLP`) with the vault's own `decimals()`, 18: one whole share (10^18) was worth 1 USDG when the vault opened. ERC-4626's `deposit(assets, receiver)` and `mint(shares, receiver)` work too.

Each loan's net return (after the performance fee) accrues into the share price over its term. A loan repaid early keeps accruing until its original end, so a deposit made just before a repayment does not share in it.

### Lend: withdraw, and claim a bonus

You may end up holding the collateral instead of USDG: while a defaulted position's tokens wait to be sold, the vault pays nothing out.

1. `maxRedeem(owner)` is the owner's shares, capped at what the free cash pays; 0 while the vault is impaired. There is no queue: what is lent comes back as loans are repaid.
2. Redeem:

   ```solidity
   function redeem(uint256 shares, address receiver, address owner, uint256 minAssets) external returns (uint256 assets);
   ```

   Set `minAssets` from `previewRedeem(shares)` less your slippage room. ERC-4626's `withdraw(assets, receiver, owner)` and `redeem(shares, receiver, owner)` work too. Paid at once from free cash, or refused whole (`InsufficientLiquidity(requested, available)`).
3. After a default whose recovery brought more than the loan's book value: `bonusClaimable(uint256 loanId, address account)`, then `claimBonus(uint256 loanId)`, or `claimBonusFor(uint256 loanId, address account)` from anyone, paid to the account. A bonus is shared by each holder's share of the vault times the seconds it held it while the loan ran (`exposureIn(loanId, account)`); a lender who left keeps its part, and shares received by transfer carry exposure only from the transfer on.

### Curate a vault

1. `create(string calldata name, uint16 performanceFeeBps, uint128 maxLoanPrincipal, PoolRef[] calldata pools) returns (address vault)` on the factory, from a wallet `registry.mayOpenVault(wallet)` allows. The name is 1 to 64 bytes and is also the share token's `name()`. The performance fee is 500 to 1,500 bps, fixed for good; `maxLoanPrincipal` is at most 10,000,000 USDG; `pools` is 1 to 32 distinct `PoolRef { adapter, pool }`, each funding at once. The vault starts empty.
2. On the vault, curator only: `setFundingPaused(bool paused)`; `setMaxLoanPrincipal(uint128 amount)`; `addPool(address adapter, address pool)`, which funds new loans `MANDATE_DELAY` (3 hours) later; `removePool(address adapter, address pool)`, at once, its open loans running to their ends.
3. After a default: `writeOffRecovery(uint256 loanId, address token)` for a lot no route sold that still blocks the vault (`recoveryBlocks(loanId)`), from 7 days after its delivery (anyone from 30 days), so redemptions resume; it keeps deposits closed while it may still be sold. `releaseWrittenOff(uint256 loanId, address token)` gives it up for good from 60 days, reopening deposits.
4. Fees: `withdrawFee()`, or `withdrawFeeFor(address account)` from anyone.

### Sell a defaulted loan's tokens

`sell(SaleQuote calldata quote, bytes calldata signature) returns (uint256 amountOut)` on the vault sends the lot to the quote's executor, which sells it for USDG along its one route, and checks the USDG against the rates service's `minOut` pro rata. `SaleQuote { vault, loanId, token, amountIn, minOut, executor, deadline }` is EIP-712 under domain `"gage LP vault"`, version `"1"`, the vault as verifying contract (`saleQuoteDigest`). A quote for more than is left sells what is left. Executors hold nothing between calls, and the vault books only what the executor took.

## Events to index

LPCore:

* `LoanOpened(uint256 indexed loanId, address indexed borrower, address indexed vault, address adapter, address pool, uint256 tokenId, uint128 principal, uint128 repayment, uint256 fee, uint40 end, address escrow)`: a loan opened, by `borrow` or `roll`; `escrow` holds the position.
* `Repaid(uint256 indexed loanId, address indexed payer, uint256 amount)`: repaid before its end.
* `Rolled(uint256 indexed loanId, uint256 indexed newLoanId, address indexed borrower, uint256 repaid, int256 net)`: repaid by `newLoanId` on the same position; `net` credited (positive) or paid (negative).
* `PositionReturned(uint256 indexed loanId, address indexed borrower)`: the NFT is back with the borrower.
* `FeesCollected(uint256 indexed loanId, address token0, uint256 amount0, address token1, uint256 amount1)`: fees credited to the borrower.
* `RewardCredited(uint256 indexed loanId, address indexed account, address token, uint256 amount)`: rewards credited, on a claim or a return.
* `Defaulted(uint256 indexed loanId, address[] tokens, uint256[] amounts, bool late)`: settled for the vault; `late` for `settleDefaultLate`.
* `Abandoned(uint256 indexed loanId)` and `AbandonedRecovered(uint256 indexed loanId, address[] tokens, uint256[] amounts)`.
* `Credited(address indexed account, address indexed token, uint256 amount)` and `Withdrawn(address indexed account, address indexed token, uint256 amount)`: the credit ledger.

LPVault (beside ERC-4626's `Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)`, `Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)` and ERC-20's `Transfer`, `Approval`):

* `Funded(uint256 indexed loanId, uint128 principal, uint128 repayment, uint40 end)`, `LoanRepaid(uint256 indexed loanId, uint256 amount, uint256 performanceFee)`, `Refinanced(uint256 indexed loanId, uint256 indexed newLoanId, uint256 repaid, uint128 principal)`.
* `LoanDefaulted(uint256 indexed loanId, address[] tokens, uint256[] amounts)`, `LoanAbandoned(uint256 indexed loanId, uint128 principal)`, `LoanRecovered(uint256 indexed loanId, address[] tokens, uint256[] amounts)`.
* `RecoveryOpened(uint256 indexed loanId, uint256 bookValue, uint256 exposure)`, `RecoverySold(uint256 indexed loanId, address indexed token, uint256 amountIn, uint256 amountOut, address executor)`, `RecoveryWrittenOff(uint256 indexed loanId, address indexed token, uint256 amount)`, `WrittenOffReleased(uint256 indexed loanId, address indexed token, uint256 amount)`.
* `BonusSetAside(uint256 indexed loanId, uint256 amount)`, `BonusClaimed(uint256 indexed loanId, address indexed account, uint256 amount)`.
* `FeeCredited(address indexed account, uint256 amount)`, `FeeWithdrawn(address indexed account, uint256 amount)`.
* `FundingPausedSet(bool paused)`, `MaxLoanPrincipalSet(uint128 amount)`, `PoolAdded(address indexed adapter, address indexed pool, uint40 activeAt)`, `PoolRemoved(address indexed adapter, address indexed pool)`.

LPVaultFactory: `VaultCreated(address indexed vault, address indexed curator, string name, uint16 performanceFeeBps, uint128 maxLoanPrincipal, PoolRef[] pools)`.

LPRegistry: `PoolSet(address indexed adapter, address indexed pool, PoolConfig config)` (the only way to list admitted pools from the chain: the registry has no enumeration), `AdapterSet(address indexed adapter, bool allowed)`, `VaultSet(address indexed vault, bool allowed)`, `VaultFactorySet(address factory)`, `CuratorSet(address indexed curator, bool allowed)`, `OpenCreationSet(bool open)`, `ExecutorSet(address indexed executor, bool allowed)`, `TermSet(uint32 term, bool allowed)`, `FeeSet(uint16 bps)`, `LtvCapSet(uint16 bps)`, `LateUnwindDelaySet(uint32 delay)`, `NewLoansPausedSet(bool paused)`, `QuoteSignerSet(address signer)`, `FeeRecipientSet(address recipient)`, `DailyOriginationCapSet(uint128 amount)`.

FablesPositionWrapper: `Wrapped(uint256 indexed tokenId, address indexed to, uint256 indexed rangeId, uint128 shares, address holder)`, `Unwrapped(uint256 indexed tokenId, address indexed to, uint256 shares)`, and ERC-721's `Transfer`.

## Errors you will meet

`borrow` checks in this order: `NewLoansPaused()`, `NotBorrower(address caller)`, `QuoteExpired(uint64 deadline)`, `TermNotAllowed(uint32 term)`, `AdapterNotAllowed(address adapter)`, `AdapterNotBound(address adapter)`, `VaultNotAllowed(address vault)`, `InvalidTerms()` (no principal, or a repayment below it), `CostAboveCeiling()`, `FeeChanged(uint16 quoted, uint16 current)`, `AboveLtvCap()`, `QuoteUsed(bytes32 digest)`, `InvalidSignature()` (signed by any key but `quoteSigner()`), `EmptyPosition()`, `PositionChanged()` (another range, or less liquidity than quoted), then the pool's terms: `PoolNotAllowed(address pool)`, `IdenticalTokens()`, `RangeTooNarrow()`, `BelowMinimumLoan()`, `AboveLoanCap()`, `AbovePoolCap()`, `AboveDailyCap()`. Then the NFT moves: a position not approved fails in its position manager's `transferFrom`. Then the vault funds the loan, and its own refusals pass through: `FundingPaused()`, `Impaired()`, `AboveMaxLoan(uint128 principal)`, `TooManyOpenLoans()` (64 open), `BelowSlotFloor(uint128 principal, uint256 least)` (from 32 open loans, a loan takes at least half an even share of the free cash over the slots left), `PoolNotInMandate(address adapter, address pool)`, `InsufficientLiquidity(uint256 requested, uint256 available)`; `FundingMismatch(uint256 received)` if the vault sent anything but the principal. A malformed signature reverts in OpenZeppelin's ECDSA (`ECDSAInvalidSignature()`, `ECDSAInvalidSignatureLength(uint256 length)`, `ECDSAInvalidSignatureS(bytes32 s)`).

`roll` first checks `NewLoansPaused()`, `NotActive(uint256 loanId)`, `PastTerm(uint256 loanId)`, `NotBorrower(address caller)` and `NotSamePosition()`, then the quote as `borrow` does, and `FundingMismatch(uint256 balance)` if the money moved does not add up.

The rest of the core: `repay`: `NotActive`, `PastTerm`. `returnPosition`: `NotRepaid(uint256 loanId)`, `AlreadyReturned(uint256 loanId)`, `NotBorrower`. `collectFees`, `claimRewards`: `NotActive`, `PastTerm`, `NotBorrower`. `settleDefault`, `recoverAbandoned`: `QuoteMismatch()` (another loan's quote), `QuoteExpired`, `QuoteUsed`, `InvalidSignature`, then `NotActive`, `BeforeTermEnd(uint256 loanId)` or `NotAbandoned(uint256 loanId)`; the unwind itself reverts in the position manager when the least amounts are not met. `settleDefaultLate`: `LateUnwindNotOpen(uint256 opensAt)`, `NotActive`. `abandonDefault`: `NotActive`, `AbandonNotOpen(uint256 opensAt)`. `withdraw`, `withdrawFor`: `NothingToWithdraw()`.

LPVault: `ZeroAmount()`, `Slippage()` (fewer shares than `minShares`, none at all, or less than `minAssets`), `Impaired()`, `DepositsClosed()`, `InsufficientLiquidity(uint256 requested, uint256 available)`, `NothingToWithdraw()` (no bonus, no fee credit); for another owner's shares, OpenZeppelin's `ERC20InsufficientAllowance`, and for more shares than held, `ERC20InsufficientBalance`. `sell`: `QuoteMismatch()`, `QuoteExpired(uint64 deadline)`, `InvalidToken(address token)`, `ZeroAmount()`, `AboveRecovery(uint256 amountIn, uint256 available)`, `ExecutorNotAllowed(address executor)`, `QuoteUsed(bytes32 digest)`, `InvalidSignature()`, `NothingSold()`, `Slippage()`. Write-offs: `InvalidToken`, `WriteOffTooEarly(uint256 opensAt)`, `ReleaseTooEarly(uint256 opensAt)`. Curator calls: `NotCurator(address caller)`, `MaxLoanAboveLimit(uint128 amount)`, `PoolAlreadyInMandate(address adapter, address pool)`, `PoolNotInMandate(address adapter, address pool)`, `TooManyPools()`, `ZeroAddress()`. The core's hooks answer only the core: `NotCore(address caller)`.

LPVaultFactory `create`: `NotCurator(address caller)`, `InvalidName()`, and the vault constructor's own refusals unchanged: `InvalidPerformanceFee(uint16 bps)`, `MaxLoanAboveLimit(uint128 amount)`, `EmptyMandate()`, `TooManyPools()`, `PoolAlreadyInMandate(address adapter, address pool)`.

Adapters and escrows answer only the core (`NotCore(address caller)`): never call them directly. `UniV4PositionAdapter.facts`: `HookedPool(address hooks)`. FablesPositionWrapper: `ZeroShares()`, `ZeroAddress()`, `WrongHook(address hooks)`, and OpenZeppelin's ERC-721 errors for a caller neither owner nor approved.

## Examples

* [examples/foundry/test/LPLane.t.sol](../../examples/foundry/test/LPLane.t.sol), fork tests: `forge test --match-path test/LPLane.t.sol -vv` from `examples/foundry`.
  * `test_readTheRegistry` reads the terms, the fee, the caps, every adapter, pool and executor of the manifest as the registry sees them.
  * `test_borrowStopsAtTheSignedQuote` mints a Uniswap v3 WETH/USDG 0.05% position, reads it through its adapter, approves the core, and shows `borrow` refused without gage's signature (`VaultNotAllowed` while no vault exists, `InvalidSignature` after); the position never leaves the wallet.
  * `test_loanRepaidAndPositionTakenBack` and `test_endOfTermUnwoundForTheVault` play a loan's whole life. They stand in for gage's parts, labelled in the code: the registry owner allows the test's curator and names a test key as quote signer, and that key signs the loan and sale quotes. Everything else is the reader's own role: open a vault, deposit, borrow, collect, repay, take the position back, redeem; or let the term end, settle it late as anyone, sell the WETH and claim the bonus.

  ```solidity
  // The borrower: approve the position to the core, borrow on the signed quote, take the USDG credit.
  vm.startPrank(borrower);
  nfpm.approve(address(core), tokenId);
  uint256 loanId = core.borrow(q, signature);
  uint256 fee = uint256(q.principal) * q.feeBps / 10_000;
  assertEq(core.credit(borrower, usdg), q.principal - fee, "credited the principal less the origination fee");
  assertEq(core.withdraw(usdg), q.principal - fee);
  vm.stopPrank();

  Loan memory l = core.loan(loanId);
  assertEq(uint8(l.state), uint8(LoanState.ACTIVE));
  assertEq(l.vault, vault);
  assertEq(l.pool, pool);
  assertEq(l.end, block.timestamp + q.term);
  assertEq(nfpm.ownerOf(tokenId), l.escrow, "the position waits in the loan's own escrow");
  ```

* [examples/viem/src/lp-read.ts](../../examples/viem/src/lp-read.ts): the registry's settings, the adapters, each admitted pool with its caps and what is lent against it now, the vaults with their mandates, and the loans still running. Read-only: `npx tsx src/lp-read.ts` from `examples/viem`.

  ```ts
  const [config, out, s0, s1] = await Promise.all([
    client.readContract({address: registry, abi: registryAbi, functionName: "poolConfig", args: [adapter, pool]}),
    client.readContract({address: core, abi: coreAbi, functionName: "outstanding", args: [adapter, pool]}),
    symbolOf(p.token0 as Address),
    symbolOf(p.token1 as Address),
  ]);
  ```

## What not to rely on

* **The settings.** The registry's terms, fee, loan cap, daily cap, pools and their caps, adapters, executors and vault switches can change within their bounds; read them before each quote. A running loan keeps its adapter, vault, terms and fee. The quote signer, the executors and the late-unwind delay also govern how running loans are settled.
* **A quote.** gage's rates service may refuse a position or be unavailable, and every quote expires within minutes and works once. Its cost is its own, under the core's ceiling.
* **A lender being there.** A loan needs a vault whose mandate funds its pool now, with the free cash for it.
* **A v4 pool's address.** For Uniswap v4 positions and wrapped positions, the pool address is the low 160 bits of the pool id, not a contract: read a v4 pool's price from its pool id (the StateView `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b`).
* **The registry listing its pools.** It has no list: use the manifest or its `PoolSet` events.
* **Escrows.** Each is a clone created at `borrow`; its address is known only from `LoanOpened`. Never send it tokens or NFTs: a safe transfer is refused, and anything else it receives may be stranded. A defaulted loan's emptied NFT stays there.
* **What a pledged position does elsewhere.** Moving a Uniswap v4 position into its escrow ends any subscription it has. A native ETH pool's fees and unwound ETH arrive as WETH.
* **Repaying at the last second.** `repay` must land strictly before `end`. At `end` the loan is past its term.
* **The share price through a default.** `totalAssets()` counts tokens waiting to be sold, written-off tokens and abandoned positions as nothing until they are sold. Deposits and redemptions stop while the vault is `impaired()`, and deposits stay closed while `depositsClosed()`. A recovery's bonus is held outside the price, for the lenders who were in.
* **Share decimals.** Read `decimals()` on each vault rather than assume 18.
* **The factory's full list.** `vaults()` is unbounded; page with `vaultCount()` and `vaultsFrom(start, count)`.
