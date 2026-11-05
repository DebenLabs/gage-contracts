// What it shows: the GenerationDeployer, read-only. Its shared contracts, its record of Intent factories (the
// release's, then each one `deploy` built), every generation it built from its `GenerationDeployed` events with
// whether the owner listed it, and the check a rehypo source makes of a partner vault (`isFactory` of the vault's
// `PROTOCOL_SOURCE()`, then that factory's `isVault`).
// Run from examples/viem: npx tsx src/generations-read.ts [vault address]
import {getAddress, parseAbi, parseAbiItem, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

/** Node's own, declared here because the examples carry no @types/node. */
declare const process: {argv: string[]};

const deployerAbi = parseAbi([
  "function isFactory(address factory) view returns (bool recorded)",
  "function factoryCount() view returns (uint256)",
  "function factories(uint256 index) view returns (address)",
  "function factoryOf(bytes32 id) view returns (address)",
  "function listed(bytes32 id) view returns (bool)",
  "function RELEASE_FACTORY_COUNT() view returns (uint256)",
  "function USDG() view returns (address)",
  "function SGAGE() view returns (address)",
  "function POOL_MANAGER() view returns (address)",
  "function EXIT_DESK() view returns (address)",
]);
const generationDeployed = parseAbiItem(
  "event GenerationDeployed(bytes32 indexed id, address indexed asset, address factory, address core, address registry, address rewards, address reserve, address feeProcessor, address quoteVerifier, address fillRouter, address gradeRegistry, address cashoutRouter, address rolloverRouter, string name)",
);
const factoryAbi = parseAbi([
  "function CORE() view returns (address)",
  "function isVault(address vault) view returns (bool)",
  "function quoteSigner() view returns (address)",
  "function count() view returns (uint256)",
  "function vaults(uint256 index) view returns (address)",
]);
const coreAbi = parseAbi(["function USDG() view returns (address)"]);
const vaultAbi = parseAbi(["function PROTOCOL_SOURCE() view returns (address)"]);
const erc20Abi = parseAbi(["function symbol() view returns (string)", "function decimals() view returns (uint8)"]);

const deployer = addressOf("generationDeployer.address");
const onDeployer = {address: deployer, abi: deployerAbi} as const;

const [usdg, sgage, poolManager, exitDesk] = await Promise.all([
  client.readContract({...onDeployer, functionName: "USDG"}),
  client.readContract({...onDeployer, functionName: "SGAGE"}),
  client.readContract({...onDeployer, functionName: "POOL_MANAGER"}),
  client.readContract({...onDeployer, functionName: "EXIT_DESK"}),
]);
console.log(`GenerationDeployer ${deployer}`);
console.log(`  USDG ${usdg}, sGAGE ${sgage}, PoolManager ${poolManager}, exit desk ${exitDesk}`);

// 1. The record: the release's factories first, then each one `deploy` built.
const releaseCount = await client.readContract({...onDeployer, functionName: "RELEASE_FACTORY_COUNT"});
const count = await client.readContract({...onDeployer, functionName: "factoryCount"});
for (let i = 0n; i < count; i++) {
  const factory = await client.readContract({...onDeployer, functionName: "factories", args: [i]});
  const core = await client.readContract({address: factory, abi: factoryAbi, functionName: "CORE"});
  const asset = await client.readContract({address: core, abi: coreAbi, functionName: "USDG"});
  const [symbol, decimals, quoteSigner] = await Promise.all([
    client.readContract({address: asset, abi: erc20Abi, functionName: "symbol"}),
    client.readContract({address: asset, abi: erc20Abi, functionName: "decimals"}),
    client.readContract({address: factory, abi: factoryAbi, functionName: "quoteSigner"}),
  ]);
  const origin = i < releaseCount ? "given at construction" : "built by deploy";
  const funding = BigInt(quoteSigner) === 0n ? "closed (no quote signer)" : "open";
  console.log(`factory ${i}: ${factory} lends ${symbol} (${decimals} decimals) on core ${core}, ${origin}, funding ${funding}`);
}

// 2. The generations `deploy` built, from its events, read from the deployer's start block in steps (the public RPC
// answers at most 10,000,000 blocks a query).
const start = BigInt((manifest as {generationDeployer: {startBlock: number}}).generationDeployer.startBlock);
const head = await client.getBlockNumber();
const STEP = 5_000_000n;
for (let from = start; from <= head; from += STEP) {
  const to = from + STEP - 1n > head ? head : from + STEP - 1n;
  const logs = await client.getLogs({address: deployer, event: generationDeployed, fromBlock: from, toBlock: to, strict: true});
  for (const log of logs) {
    const {id, asset, factory, core, rewards, feeProcessor, name} = log.args;
    const [listed, recorded] = await Promise.all([
      client.readContract({...onDeployer, functionName: "listed", args: [id]}),
      client.readContract({...onDeployer, functionName: "factoryOf", args: [id]}),
    ]);
    console.log(`generation ${name} at block ${log.blockNumber}: id ${id}, asset ${asset}`);
    console.log(`  factory ${factory} (factoryOf(id) matches: ${getAddress(recorded) === getAddress(factory)}), core ${core}`);
    console.log(`  rewards ledger ${rewards}, fee processor ${feeProcessor}, listed by the owner: ${listed}`);
  }
}

// 3. The check a rehypo source makes of the partner vault it lends through: by default the USDG factory's first vault.
const usdgFactory = addressOf("intentV1.factory");
let vault: Address | null = process.argv[2] ? getAddress(process.argv[2]) : null;
if (!vault && (await client.readContract({address: usdgFactory, abi: factoryAbi, functionName: "count"})) > 0n) {
  vault = await client.readContract({address: usdgFactory, abi: factoryAbi, functionName: "vaults", args: [0n]});
}
if (vault) {
  const source = await client.readContract({address: vault, abi: vaultAbi, functionName: "PROTOCOL_SOURCE"});
  const recorded = await client.readContract({...onDeployer, functionName: "isFactory", args: [source]});
  const created = recorded && (await client.readContract({address: source, abi: factoryAbi, functionName: "isVault", args: [vault]}));
  console.log(`vault ${vault}: factory ${source}, recorded ${recorded}, created by it ${created}; a rehypo source ${created ? "accepts" : "refuses"} it`);
}
