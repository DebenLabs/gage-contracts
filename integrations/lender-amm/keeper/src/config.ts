import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";
import type { Level } from "./log.js";
import type { Thresholds } from "./plan.js";

/** The kit's root (`integrations/lender-amm`), where the deploy script writes `deployments/<chainId>.json`. */
const KIT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export interface Config {
  chainId: number;
  rpcUrl: string;
  hook: Address;
  stateView: Address;
  /** The pool whose price the band is built around; null builds it around the hook pool's own price, which the keeper
   * then moves the float on only with `allowSelfReference` (r12 review C45). */
  referencePoolId: Hex | null;
  /** Move the float with no reference pool, on the hook pool's own price, which a swap can push (ALLOW_SELF_REFERENCE). */
  allowSelfReference: boolean;
  /** The most the keeper pays per gas, in wei (MAX_FEE_PER_GAS_WEI): above it a pass sends nothing. */
  maxFeePerGas: bigint;
  /** gage's indexer, for settleable loans, the free-cash schedule and claimable pockets; null skips all three. */
  indexerUrl: string | null;
  thresholds: Thresholds;
  maxDeviationBps: bigint;
  intervalMs: number;
  dryRun: boolean;
  settleDue: boolean;
  claimPockets: boolean;
  logLevel: Level;
}

export interface Loaded {
  config: Config;
  /** Kept out of `config`, which is logged. */
  keeperKey: Hex | null;
}

type Env = Record<string, string | undefined>;

function readJson(path: string): Record<string, unknown> | null {
  return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>) : null;
}

function bool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value === "") return fallback;
  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

function bps(env: Env, name: string, fallback: bigint): bigint {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name} must be a whole number of basis points`);
  return BigInt(raw);
}

/** INTERVAL_MS: whole milliseconds, at least one second; a malformed value would remove the pause between passes. */
export function interval(raw: string | undefined): number {
  if (raw === undefined || raw === "") return 60_000;
  if (!/^\d+$/.test(raw) || Number(raw) < 1000) throw new Error("INTERVAL_MS must be a whole number of milliseconds, at least 1000");
  return Number(raw);
}

function wei(raw: string | undefined, fallback: bigint): bigint {
  if (raw === undefined || raw === "") return fallback;
  if (!/^\d+$/.test(raw) || BigInt(raw) === 0n) throw new Error("MAX_FEE_PER_GAS_WEI must be a positive whole number of wei");
  return BigInt(raw);
}

function address(value: unknown, name: string): Address {
  if (typeof value !== "string" || !isAddress(value)) throw new Error(`${name} must be an address, got ${String(value)}`);
  return getAddress(value);
}

/**
 * Environment first; otherwise the kit's deployment record for the hook and its reference pool, and gage's manifest
 * (`deployments/manifest/<chainId>.json` in this repository) for StateView and the indexer.
 */
export function loadConfig(env: Env = process.env): Loaded {
  const chainId = Number(env.CHAIN_ID ?? 46630);
  const deployment = readJson(env.DEPLOYMENT ?? resolve(KIT, "deployments", `${chainId}.json`)) ?? {};
  const manifest = readJson(env.GAGE_MANIFEST ?? resolve(KIT, "../../deployments/manifest", `${chainId}.json`)) ?? {};
  const reference = env.REFERENCE_POOL_ID ?? (deployment.referencePoolId as string | undefined);
  const indexer = env.INDEXER_URL ?? (manifest.intentV1IndexerUrl as string | undefined);
  const key = env.KEEPER_KEY;
  if (key !== undefined && key !== "" && !(isHex(key) && key.length === 66)) throw new Error("KEEPER_KEY must be a 32-byte hex key");
  const keeperKey = key ? (key as Hex) : null;
  const refillBelowBps = bps(env, "REFILL_BELOW_BPS", 5000n);
  const sweepAboveBps = bps(env, "SWEEP_ABOVE_BPS", 15_000n);
  if (refillBelowBps > 10_000n || sweepAboveBps < 10_000n) {
    throw new Error("REFILL_BELOW_BPS must be at most 10000 and SWEEP_ABOVE_BPS at least 10000");
  }
  const config: Config = {
    chainId,
    rpcUrl: env.RPC_URL ?? "https://rpc.testnet.chain.robinhood.com",
    hook: address(env.HOOK ?? deployment.hook, "HOOK"),
    stateView: address(env.STATE_VIEW ?? manifest.StateView, "STATE_VIEW"),
    referencePoolId: reference && reference !== "none" ? (reference as Hex) : null,
    indexerUrl: indexer && indexer !== "none" ? indexer : null,
    thresholds: { refillBelowBps, sweepAboveBps },
    maxDeviationBps: bps(env, "MAX_DEVIATION_BPS", 100n),
    intervalMs: interval(env.INTERVAL_MS),
    allowSelfReference: bool(env.ALLOW_SELF_REFERENCE, false),
    maxFeePerGas: wei(env.MAX_FEE_PER_GAS_WEI, 1_000_000_000n),
    dryRun: bool(env.DRY_RUN, keeperKey === null) || keeperKey === null,
    settleDue: bool(env.SETTLE_DUE, true),
    claimPockets: bool(env.CLAIM_POCKETS, true),
    logLevel: (env.LOG_LEVEL as Level | undefined) ?? "info",
  };
  return { config, keeperKey };
}
