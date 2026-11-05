// Recent fills of gage's partner vaults on Robinhood Chain mainnet, read from each Intent fill router's events: the
// USDG generation's (`intentV1.fillRouter`), each lend asset's (`intentV1Assets.<SYMBOL>.fillRouter`) and the USDG
// generation the current one replaced (`intentV1Previous`), whose loans run until they close. For each fill: the
// signed plan's EIP-712 digest, the listing, the filler, each vault's part and the execution fee, and whether the quote
// verifier records the digest as used. Read-only.
//
// Run from examples/viem:
//   npx tsx src/intent-fills.ts
import {formatUnits, parseAbi, parseAbiItem, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

const filled = parseAbiItem(
  "event Filled(bytes32 indexed digest, uint256 indexed listingId, address indexed filler, uint40 activatedAt, uint256 principal, uint256 executionFee, address protocolRecipient)",
);
const contribution = parseAbiItem(
  "event Contribution(bytes32 indexed digest, address indexed vault, uint8 units, uint256 principal, uint256 interest, uint256 fee)",
);
const routerAbi = parseAbi(["function VERIFIER() view returns (address)", "function USDG() view returns (address)"]);
const verifierAbi = parseAbi(["function consumed(bytes32 digest) view returns (bool)"]);
const erc20Abi = parseAbi(["function symbol() view returns (string)", "function decimals() view returns (uint8)"]);

/** How many fills to show per router, and the block span of one log request (the public RPC serves this for one address). */
const RECENT = 5;
const WINDOW = 2_000_000n;

type Entry = {key: string; label: string};

function routers(): Entry[] {
  const m = manifest as unknown as {intentV1Assets?: Record<string, unknown>; intentV1Previous?: unknown[]};
  const out: Entry[] = [{key: "intentV1", label: "USDG"}];
  for (const symbol of Object.keys(m.intentV1Assets ?? {})) out.push({key: `intentV1Assets.${symbol}`, label: symbol});
  (m.intentV1Previous ?? []).forEach((_, i) => out.push({key: `intentV1Previous.${i}.intentV1`, label: "USDG, previous generation"}));
  return out;
}

function startBlock(key: string): bigint {
  const value = key.split(".").reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], manifest);
  if (typeof value !== "number") throw new Error(`no start block at ${key}`);
  return BigInt(value);
}

async function recentFills(router: Address, from: bigint) {
  const found = [];
  for (let to = await client.getBlockNumber(); to >= from && found.length < RECENT; ) {
    const lo = to > from + WINDOW ? to - WINDOW : from;
    const logs = await client.getLogs({address: router, event: filled, fromBlock: lo, toBlock: to});
    found.unshift(...logs);
    if (lo === from) break;
    to = lo - 1n;
  }
  return found.slice(-RECENT).reverse();
}

for (const {key, label} of routers()) {
  const router = addressOf(`${key}.fillRouter`);
  const [verifier, asset] = await Promise.all([
    client.readContract({address: router, abi: routerAbi, functionName: "VERIFIER"}),
    client.readContract({address: router, abi: routerAbi, functionName: "USDG"}),
  ]);
  const [symbol, decimals] = await Promise.all([
    client.readContract({address: asset, abi: erc20Abi, functionName: "symbol"}),
    client.readContract({address: asset, abi: erc20Abi, functionName: "decimals"}),
  ]);
  const fmt = (raw: bigint) => `${formatUnits(raw, decimals)} ${symbol}`;
  const fills = await recentFills(router, startBlock(`${key}.startBlock`));
  console.log(`\n${label}: fill router ${router}, ${fills.length === 0 ? "no fill yet" : `latest ${fills.length} fill(s)`}`);
  for (const f of fills) {
    const {digest, listingId, filler, activatedAt, principal, executionFee, protocolRecipient} = f.args;
    if (digest === undefined || principal === undefined || executionFee === undefined || activatedAt === undefined) continue;
    const [used, parts] = await Promise.all([
      client.readContract({address: verifier, abi: verifierAbi, functionName: "consumed", args: [digest]}),
      client.getLogs({address: router, event: contribution, args: {digest}, fromBlock: f.blockNumber, toBlock: f.blockNumber}),
    ]);
    console.log(`  listing ${listingId} at block ${f.blockNumber}, ${new Date(activatedAt * 1000).toISOString()}, tx ${f.transactionHash}`);
    console.log(`    plan digest ${digest} (consumed on the verifier: ${used}), filler ${filler}`);
    console.log(`    principal ${fmt(principal)}, execution fee ${fmt(executionFee)} owed to ${protocolRecipient}`);
    for (const p of parts) {
      if (p.transactionHash !== f.transactionHash || p.args.principal === undefined || p.args.fee === undefined || p.args.interest === undefined) continue;
      console.log(`    vault ${p.args.vault}: ${p.args.units} quarter(s), ${fmt(p.args.principal)} lent at a fixed cost of ${fmt(p.args.interest)} (repaid on top if the borrower repays), execution fee ${fmt(p.args.fee)}`);
    }
  }
}
console.log("\nA lender may end up holding the collateral instead of the asset it lent.");
