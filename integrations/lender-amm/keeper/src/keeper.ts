import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { erc20Abi, hookAbi, stateViewAbi, vaultAbi } from "./abi.js";
import type { Config } from "./config.js";
import type { Logger } from "./log.js";
import { band, decide, inBand, type Decision } from "./plan.js";
import { accountingUrl, fetchJson, freeCashSchedule, moreBy, positionUrl, type Accounting, type Position } from "./schedule.js";

export interface Context {
  config: Config;
  log: Logger;
  client: PublicClient;
  wallet: WalletClient | null;
  account: PrivateKeyAccount | null;
}

export function createContext(config: Config, keeperKey: Hex | null, log: Logger): Context {
  const chain = defineChain({
    id: config.chainId,
    name: `chain ${config.chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [config.rpcUrl] } },
  });
  const transport = http(config.rpcUrl, { retryCount: 3 });
  const client = createPublicClient({ chain, transport }) as PublicClient;
  const account = keeperKey ? privateKeyToAccount(keeperKey) : null;
  const wallet = account ? createWalletClient({ chain, transport, account }) : null;
  return { config, log, client, wallet, account };
}

export interface SideReport {
  currency: Address;
  symbol: string;
  float: bigint;
  target: bigint | null;
  decision: Decision["kind"];
  sent: Hex[];
}

/** The pool id v4 derives from a key: keccak256 of its ABI encoding. */
export function poolIdOf(key: { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address }): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

/** The decoded revert name of a failed call, when its ABI names it. */
export function revertName(error: unknown): string | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  return reverted instanceof ContractFunctionRevertedError ? (reverted.data?.errorName ?? null) : null;
}

/**
 * One keeper pass: for each currency, read the float, its target and what the hook would move; refill or sweep past
 * the thresholds, within the price band; settle a vault's due loans when the vault is settling; log when more free
 * cash comes back; claim the hook's pockets. Every send is simulated first, and only simulated in a dry run.
 */
export async function runPass(ctx: Context): Promise<SideReport[]> {
  const { config, client, log } = ctx;
  const hook = config.hook;
  const read = <T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
    client.readContract({ address, abi, functionName, args }) as Promise<T>;

  const [currency0, currency1, vault0, vault1, key] = await Promise.all([
    read<Address>(hook, hookAbi, "CURRENCY0"),
    read<Address>(hook, hookAbi, "CURRENCY1"),
    read<Address>(hook, hookAbi, "VAULT0"),
    read<Address>(hook, hookAbi, "VAULT1"),
    read<{ currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address }>(hook, hookAbi, "getPoolKey"),
  ]);
  if (ctx.account && !(await read<boolean>(hook, hookAbi, "isKeeper", [ctx.account.address]))) {
    log.warn("not_a_keeper", { hook, keeper: ctx.account.address });
  }
  const [poolPrice] = await read<readonly [bigint, number, number, number]>(config.stateView, stateViewAbi, "getSlot0", [poolIdOf(key)]);
  const reference = config.referencePoolId
    ? (await read<readonly [bigint, number, number, number]>(config.stateView, stateViewAbi, "getSlot0", [config.referencePoolId]))[0]
    : poolPrice;
  const priceBand = band(reference, config.maxDeviationBps);
  // Without a reference pool the band follows the hook pool's own price, which a swap can push: the float stays put
  // unless the partner allows that (r12 review C45).
  const referenced = config.referencePoolId !== null || config.allowSelfReference;
  if (!referenced) log.warn("no_reference_pool", { hook, reason: "set REFERENCE_POOL_ID, or ALLOW_SELF_REFERENCE=true, before the float moves" });
  const priceOk = referenced && inBand(poolPrice, priceBand);

  const reports: SideReport[] = [];
  for (const [currency, vault] of [[currency0, vault0], [currency1, vault1]] as const) {
    const symbol = await read<string>(currency, erc20Abi, "symbol");
    const float = await read<bigint>(hook, hookAbi, "floatOf", [currency]);
    let target: bigint | null = null;
    let move = 0n;
    try {
      target = await read<bigint>(hook, hookAbi, "targetFloat", [currency]);
      move = await read<bigint>(hook, hookAbi, "rebalanceAmount", [currency]);
    } catch (error) {
      if (revertName(error) !== "VaultSettling") throw error;
    }
    const decision = decide({ float, target, move }, config.thresholds);
    const report: SideReport = { currency, symbol, float, target, decision: decision.kind, sent: [] };
    const fields = { symbol, currency, vault, float, target, move };

    if (decision.kind === "refill" || decision.kind === "sweep") {
      if (!priceOk) {
        // Arbitrage brings the price back; moving the float at a pushed price would deploy liquidity there.
        log.warn("price_out_of_band", { ...fields, poolPrice, reference, min: priceBand.min, max: priceBand.max });
      } else {
        log.info(decision.kind, { ...fields, amount: decision.amount });
        const hash = await send(ctx, `${symbol} ${decision.kind}`, hook, hookAbi, "rebalance", [currency, priceBand.min, priceBand.max]);
        if (hash) report.sent.push(hash);
      }
    } else if (decision.kind === "settle") {
      await settleDue(ctx, vault, symbol, report);
    } else if (decision.kind === "wait_free_cash") {
      await logSchedule(ctx, vault, symbol, decision.short, fields);
    } else {
      log.debug("idle", fields);
    }
    if (config.claimPockets && config.indexerUrl) await claimPockets(ctx, currency, vault, symbol, report);
    reports.push(report);
  }
  return reports;
}

/** A vault with a loan past its end refuses share moves until someone settles it; anyone may. */
async function settleDue(ctx: Context, vault: Address, symbol: string, report: SideReport): Promise<void> {
  const { config, log } = ctx;
  if (!config.settleDue || !config.indexerUrl) {
    log.info("vault_settling", { symbol, vault, note: "waiting for the vault's settle" });
    return;
  }
  const acc = await fetchJson<Accounting>(accountingUrl(config.indexerUrl, vault));
  const ids = acc.settlement.settleable.slice(0, 32).map((id) => BigInt(id));
  if (ids.length === 0) {
    log.info("vault_settling", { symbol, vault, note: "the indexer lists nothing settleable yet" });
    return;
  }
  const hash = await send(ctx, `${symbol} settle`, vault, vaultAbi, "settle", [ids]);
  if (hash) report.sent.push(hash);
}

/** The float is short and the vault has no free cash to refill it: say when loans bring more back. */
async function logSchedule(ctx: Context, vault: Address, symbol: string, short: bigint, fields: Record<string, unknown>): Promise<void> {
  const { config, log } = ctx;
  if (!config.indexerUrl) {
    log.info("wait_free_cash", { ...fields, short });
    return;
  }
  const schedule = freeCashSchedule(await fetchJson<Accounting>(accountingUrl(config.indexerUrl, vault)));
  const step = moreBy(schedule, short);
  log.info("wait_free_cash", {
    ...fields,
    short,
    free: schedule.free,
    moreBy: step ? new Date(step.at * 1000).toISOString() : null,
    freeBy: step ? step.total : null,
    schedule: schedule.steps.map((s) => ({ at: new Date(s.at * 1000).toISOString(), amount: s.amount, total: s.total })),
  });
}

/** Earnings claims (D51) and write-off backing join the float; recovered collateral waits for the owner. */
async function claimPockets(ctx: Context, currency: Address, vault: Address, symbol: string, report: SideReport): Promise<void> {
  const { config, log } = ctx;
  let position: Position;
  try {
    position = await fetchJson<Position>(positionUrl(config.indexerUrl!, vault, config.hook));
  } catch (error) {
    log.warn("position_unavailable", { symbol, vault, error });
    return;
  }
  const ids = position.pockets.filter((p) => BigInt(p.claimable) > 0n).map((p) => BigInt(p.id)).slice(0, 32);
  if (ids.length === 0) return;
  const hash = await send(ctx, `${symbol} claimPockets`, config.hook, hookAbi, "claimPockets", [currency, ids]);
  if (hash) report.sent.push(hash);
}

/** Simulate, then send and wait unless this is a dry run. A refusal is logged with its name and retried next pass. */
async function send(ctx: Context, label: string, address: Address, abi: Abi, functionName: string, args: readonly unknown[]): Promise<Hex | null> {
  const { client, wallet, account, log, config } = ctx;
  const from = account?.address;
  try {
    const { request } = await client.simulateContract({ address, abi, functionName, args, ...(from ? { account: from } : {}) });
    if (config.dryRun || !wallet || !account) {
      log.info("would_send", { label, address, functionName, args });
      return null;
    }
    // One transaction at a time, at a fee the partner capped (r12 review C46): a pending one waits for the next pass.
    const [pending, latest] = await Promise.all([client.getTransactionCount({ address: account.address, blockTag: "pending" }),
      client.getTransactionCount({ address: account.address, blockTag: "latest" })]);
    if (pending > latest) {
      log.warn("pending_transaction", { label, pending, latest });
      return null;
    }
    const { maxFeePerGas } = await client.estimateFeesPerGas();
    if (maxFeePerGas !== undefined && maxFeePerGas > config.maxFeePerGas) {
      log.warn("fee_above_cap", { label, maxFeePerGas, cap: config.maxFeePerGas });
      return null;
    }
    const hash = await wallet.writeContract({ ...request, account, chain: wallet.chain, maxFeePerGas: config.maxFeePerGas } as Parameters<WalletClient["writeContract"]>[0]);
    const receipt = await client.waitForTransactionReceipt({ hash });
    log.info("sent", { label, hash, status: receipt.status, block: receipt.blockNumber, gasUsed: receipt.gasUsed });
    return receipt.status === "success" ? hash : null;
  } catch (error) {
    // The vault's refusal moments (SettlementDue, SaleTooSoon, RewardsPending) and an empty free cash pass by.
    log.warn("refused", { label, reason: revertName(error) ?? (error instanceof Error ? error.message.split("\n")[0] : String(error)) });
    return null;
  }
}
