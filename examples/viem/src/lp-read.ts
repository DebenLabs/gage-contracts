// What this shows: gage's LP lane as it stands on Robinhood Chain mainnet, read from the chain. The registry's
// settings, the position adapters, the admitted pools with their caps and what is lent against each now, the LP vaults
// curators opened through the factory, and the loans still running. Pool names come from gage's public deployment
// API (https://gage.cash/api/deployment) when it answers; everything else is on chain. Read-only: no key, no write.
// Run from examples/viem:  npm install, then  npx tsx src/lp-read.ts
import {formatUnits, parseAbi, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

const registryAbi = parseAbi([
  "function owner() view returns (address)",
  "function feeBps() view returns (uint16)",
  "function ltvCapBps() view returns (uint16)",
  "function lateUnwindDelay() view returns (uint32)",
  "function newLoansPaused() view returns (bool)",
  "function quoteSigner() view returns (address)",
  "function dailyOriginationCap() view returns (uint128)",
  "function terms() view returns (uint32[])",
  "function adapterAllowed(address adapter) view returns (bool)",
  "function executorAllowed(address executor) view returns (bool)",
  "function vaultAllowed(address vault) view returns (bool)",
  "function openCreation() view returns (bool)",
  "function poolConfig(address adapter, address pool) view returns ((bool allowed, uint24 minHalfWidthTicks, uint128 minLoanPrincipal, uint128 maxLoanPrincipal, uint128 maxOutstanding))",
]);
const coreAbi = parseAbi([
  "function nextLoanId() view returns (uint256)",
  "function outstanding(address adapter, address pool) view returns (uint256)",
  "function originated(uint256 day) view returns (uint256)",
  "function loan(uint256 loanId) view returns ((address borrower, address vault, address adapter, address escrow, address pool, uint256 tokenId, uint128 principal, uint128 repayment, uint40 start, uint40 end, uint8 state, bool positionReturned))",
]);
const adapterAbi = parseAbi([
  "function core() view returns (address)",
  "function positionManager() view returns (address)",
  "function rewardTokens() view returns (address[])",
]);
const factoryAbi = parseAbi([
  "function vaultCount() view returns (uint256)",
  "function vaultsFrom(uint256 start, uint256 count) view returns (address[] page)",
]);
const vaultAbi = parseAbi([
  "function name() view returns (string)",
  "function decimals() view returns (uint8)",
  "function CURATOR() view returns (address)",
  "function PERFORMANCE_FEE_BPS() view returns (uint16)",
  "function maxLoanPrincipal() view returns (uint128)",
  "function totalAssets() view returns (uint256)",
  "function freeCash() view returns (uint256)",
  "function outstandingPrincipal() view returns (uint256)",
  "function impaired() view returns (bool)",
  "function depositsClosed() view returns (bool)",
  "function fundingPaused() view returns (bool)",
  "function mandate() view returns ((address adapter, address pool)[] pools, uint40[] activeAt)",
]);
const erc20Abi = parseAbi(["function symbol() view returns (string)"]);

const STATES = ["NONE", "ACTIVE", "REPAID", "DEFAULTED", "ABANDONED", "ROLLED"] as const;
const usdg = (raw: bigint) => `${formatUnits(raw, 6)} USDG`;
const key = (adapter: string, pool: string) => `${adapter}:${pool}`.toLowerCase();

const lane = manifest.lpLane;
const core = addressOf("lpLane.core");
const registry = addressOf("lpLane.registry");
const factory = addressOf("lpLane.vaultFactory");

/** Pool names as gage's public deployment API gives them, by adapter and pool; none if it does not answer. */
async function poolNames(): Promise<Map<string, string>> {
  try {
    const res = await fetch("https://gage.cash/api/deployment");
    const body = (await res.json()) as {deployment?: {lpLane?: {pools?: {adapter: string; pool: string; name?: string}[]}}};
    return new Map((body.deployment?.lpLane?.pools ?? []).flatMap((p) => (p.name ? [[key(p.adapter, p.pool), p.name] as const] : [])));
  } catch {
    return new Map();
  }
}

const symbols = new Map<string, string>();
async function symbolOf(token: Address): Promise<string> {
  const known = symbols.get(token.toLowerCase());
  if (known) return known;
  const symbol = await client.readContract({address: token, abi: erc20Abi, functionName: "symbol"}).catch(() => token);
  symbols.set(token.toLowerCase(), symbol);
  return symbol;
}

async function main() {
  const block = await client.getBlock();
  const read = <const F extends string>(functionName: F) => ({address: registry, abi: registryAbi, functionName}) as const;
  const [owner, feeBps, ltvCapBps, lateUnwindDelay, paused, signer, dailyCap, terms, openCreation] = await Promise.all([
    client.readContract(read("owner")),
    client.readContract(read("feeBps")),
    client.readContract(read("ltvCapBps")),
    client.readContract(read("lateUnwindDelay")),
    client.readContract(read("newLoansPaused")),
    client.readContract(read("quoteSigner")),
    client.readContract(read("dailyOriginationCap")),
    client.readContract(read("terms")),
    client.readContract(read("openCreation")),
  ]);
  const today = block.timestamp / 86_400n;
  const originated = await client.readContract({address: core, abi: coreAbi, functionName: "originated", args: [today]});
  console.log(`LP lane at block ${block.number}: core ${core}, registry ${registry} (owner ${owner})`);
  console.log(`  terms: ${terms.map((t) => `${t / 86_400} days`).join(", ")}; origination fee ${feeBps} bps; loan cap ${ltvCapBps} bps of the signed value`);
  console.log(`  late unwind ${lateUnwindDelay / 3_600} hours after a term's end; new loans ${paused ? "paused" : "open"}; quote signer ${signer}`);
  console.log(`  lent today ${usdg(originated)} of ${usdg(dailyCap)}`);

  console.log("\nAdapters");
  for (const a of lane.adapters) {
    const address = a.address as Address;
    const [allowed, bound, manager, rewards] = await Promise.all([
      client.readContract({address: registry, abi: registryAbi, functionName: "adapterAllowed", args: [address]}),
      client.readContract({address, abi: adapterAbi, functionName: "core"}),
      client.readContract({address, abi: adapterAbi, functionName: "positionManager"}),
      client.readContract({address, abi: adapterAbi, functionName: "rewardTokens"}),
    ]);
    const rewardText = rewards.length ? `, rewards in ${(await Promise.all(rewards.map(symbolOf))).join(", ")}` : "";
    console.log(`  ${address} ${allowed ? "allowed" : "not allowed"}${bound.toLowerCase() === core.toLowerCase() ? "" : " (another core's)"}: positions of ${manager}${rewardText}`);
  }

  console.log("\nPools");
  const names = await poolNames();
  for (const p of lane.pools) {
    const adapter = p.adapter as Address, pool = p.pool as Address;
    const [config, out, s0, s1] = await Promise.all([
      client.readContract({address: registry, abi: registryAbi, functionName: "poolConfig", args: [adapter, pool]}),
      client.readContract({address: core, abi: coreAbi, functionName: "outstanding", args: [adapter, pool]}),
      symbolOf(p.token0 as Address),
      symbolOf(p.token1 as Address),
    ]);
    const name = names.get(key(adapter, pool)) ?? `${s0}/${s1}, fee ${p.fee}`;
    console.log(`  ${name} (${pool}, adapter ${adapter}): ${config.allowed ? "admitted" : "not admitted"}`);
    console.log(`    a loan ${usdg(config.minLoanPrincipal)} to ${usdg(config.maxLoanPrincipal)}; lent now ${usdg(out)} of ${usdg(config.maxOutstanding)}; least half-width ${config.minHalfWidthTicks} ticks`);
  }

  console.log("\nSale executors (what a vault sells recovered tokens through)");
  for (const e of lane.executors) {
    const allowed = await client.readContract({address: registry, abi: registryAbi, functionName: "executorAllowed", args: [e.address as Address]});
    console.log(`  ${e.address} sells ${await symbolOf(e.token as Address)} for USDG: ${allowed ? "allowed" : "not allowed"}`);
  }

  console.log("\nLP vaults");
  const count = await client.readContract({address: factory, abi: factoryAbi, functionName: "vaultCount"});
  console.log(`  the factory opened ${count}; vault creation is ${openCreation ? "open to anyone" : "for the curators the registry allows"}`);
  for (let start = 0n; start < count; start += 50n) {
    const page = await client.readContract({address: factory, abi: factoryAbi, functionName: "vaultsFrom", args: [start, 50n]});
    for (const vault of page) {
      const v = <const F extends string>(functionName: F) => ({address: vault, abi: vaultAbi, functionName}) as const;
      const [name, decimals, curator, perfBps, maxLoan, assets, cash, lent, impaired, closed, fundingPaused, [pools, activeAt], allowed] = await Promise.all([
        client.readContract(v("name")),
        client.readContract(v("decimals")),
        client.readContract(v("CURATOR")),
        client.readContract(v("PERFORMANCE_FEE_BPS")),
        client.readContract(v("maxLoanPrincipal")),
        client.readContract(v("totalAssets")),
        client.readContract(v("freeCash")),
        client.readContract(v("outstandingPrincipal")),
        client.readContract(v("impaired")),
        client.readContract(v("depositsClosed")),
        client.readContract(v("fundingPaused")),
        client.readContract(v("mandate")),
        client.readContract({address: registry, abi: registryAbi, functionName: "vaultAllowed", args: [vault]}),
      ]);
      console.log(`  ${name} (${vault}), curator ${curator}${allowed ? "" : ", removed by the registry"}: shares of ${decimals} decimals`);
      console.log(`    holds ${usdg(assets)}, ${usdg(cash)} free, ${usdg(lent)} lent; performance fee ${perfBps} bps; loans up to ${usdg(maxLoan)}`);
      console.log(`    ${impaired ? "impaired: no deposit, redemption or funding until its settlement and sales" : closed ? "deposits closed" : "takes deposits"}${fundingPaused ? "; funding paused" : ""}`);
      for (let i = 0; i < pools.length; i++) {
        const from = Number(activeAt[i]);
        const when = BigInt(from) <= block.timestamp ? "funds now" : `funds from ${new Date(from * 1000).toISOString()}`;
        console.log(`    mandate: ${names.get(key(pools[i]!.adapter, pools[i]!.pool)) ?? pools[i]!.pool}, ${when}`);
      }
    }
  }

  console.log("\nLoans still running or waiting to be taken back (newest first, at most 100)");
  const next = await client.readContract({address: core, abi: coreAbi, functionName: "nextLoanId"});
  const ids: bigint[] = [];
  for (let id = next - 1n; id >= 1n && ids.length < 100; id--) ids.push(id);
  const loans = await Promise.all(ids.map((id) => client.readContract({address: core, abi: coreAbi, functionName: "loan", args: [id]})));
  let shown = 0;
  loans.forEach((l, n) => {
    const waiting = l.state === 2 && !l.positionReturned;
    if (l.state !== 1 && !waiting) return;
    shown++;
    const past = BigInt(l.end) <= block.timestamp ? ", past its end: waits to be settled for its vault" : "";
    console.log(`  #${ids[n]} ${STATES[l.state]}${waiting ? " (position not taken back yet)" : ""}: ${usdg(l.principal)} lent by ${l.vault}, repay ${usdg(l.repayment)} before ${new Date(Number(l.end) * 1000).toISOString()}${past}`);
    console.log(`    position #${l.tokenId} in ${names.get(key(l.adapter, l.pool)) ?? l.pool}, held by escrow ${l.escrow}`);
  });
  if (!shown) console.log(`  none (${next - 1n} loans opened so far)`);
}

await main();
