// Reads every gage core on Robinhood Chain mainnet in a few multicalls: its asset, loan count, registry and grace,
// then the latest loans of each core that has some, then its registry's terms, fee and pause. Read-only.
//
//   cd examples/viem && npm install && npx tsx src/cores-read.ts
//
// See docs/integrate/reading.md.
import {formatUnits, parseAbi, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

// Signatures as in src/v2/GageV2Vault.sol and src/v2/GageV2TokenRegistry.sol.
const coreAbi = parseAbi([
  "struct V2Loan { address originator; address account; address token; address collateralBeneficiary; uint8 kind; uint8 state; uint8 filled; uint32 term; uint40 fundingDeadline; uint40 fundedAt; uint40 closedAt; uint128 principal; uint128 cap; uint128 originationFee; uint128 borrowerReward; uint128 lenderReward; uint256 collateral; bytes32 exposureKey; uint256 exposureAmount; }",
  "function loanCount() view returns (uint256)",
  "function getLoan(uint256 id) view returns (V2Loan)",
  "function USDG() view returns (address)",
  "function REGISTRY() view returns (address)",
  "function GRACE() view returns (uint32)",
]);
const registryAbi = parseAbi([
  "function allowedTerms() view returns (uint32[])",
  "function feeBps() view returns (uint16)",
  "function newDealsPaused() view returns (bool)",
]);
const erc20Abi = parseAbi(["function decimals() view returns (uint8)", "function symbol() view returns (string)"]);

/** `V2State`: index 0 is a loan id never issued. */
const STATE = ["NONE", "FUNDING", "ACTIVE", "REPAID", "DEFAULTED", "CANCELLED"] as const;
/** How many of each core's newest loans to read. */
const LATEST = 5n;

// Every core: the USDG core and each lend asset's, which take new loans, then the earlier cores, which only settle
// the loans they hold: the older USDG engines (the newest entry of `nativeV2.engines` is the USDG core itself) and
// each lend asset's earlier generations.
const cores: {name: string; core: Address; current: boolean}[] = [{name: "USDG core", core: addressOf("intentV1.core"), current: true}];
for (const symbol of Object.keys(manifest.intentV1Assets)) {
  cores.push({name: `${symbol} core`, core: addressOf(`intentV1Assets.${symbol}.core`), current: true});
}
manifest.nativeV2.engines.forEach((_, i) => {
  const core = addressOf(`nativeV2.engines.${i}.engine`);
  if (core !== cores[0]!.core) cores.push({name: `earlier USDG engine ${i}`, core, current: false});
});
for (const [symbol, entries] of Object.entries(manifest.intentV1AssetsPrevious)) {
  entries.forEach((_, i) => {
    cores.push({name: `earlier ${symbol} core ${i}`, core: addressOf(`intentV1AssetsPrevious.${symbol}.${i}.entry.core`), current: false});
  });
}

// One multicall for the four facts of every core. viem's Robinhood Chain definition names the chain's Multicall3.
const facts = await client.multicall({
  allowFailure: false,
  contracts: cores.flatMap(({core}) => [
    {address: core, abi: coreAbi, functionName: "USDG"},
    {address: core, abi: coreAbi, functionName: "loanCount"},
    {address: core, abi: coreAbi, functionName: "REGISTRY"},
    {address: core, abi: coreAbi, functionName: "GRACE"},
  ] as const),
});
const read = cores.map((c, i) => ({
  ...c,
  asset: facts[i * 4] as Address,
  loanCount: facts[i * 4 + 1] as bigint,
  registry: facts[i * 4 + 2] as Address,
  grace: facts[i * 4 + 3] as number,
}));

// The asset each core lends, for its amounts' decimals: USDG has 6, a stock token 18.
const assets = [...new Set(read.map((c) => c.asset))];
const meta = await client.multicall({
  allowFailure: false,
  contracts: assets.flatMap((a) => [
    {address: a, abi: erc20Abi, functionName: "symbol"},
    {address: a, abi: erc20Abi, functionName: "decimals"},
  ] as const),
});
const assetMeta = new Map(assets.map((a, i) => [a, {symbol: meta[i * 2] as string, decimals: meta[i * 2 + 1] as number}]));

for (const c of read) {
  const {symbol, decimals} = assetMeta.get(c.asset)!;
  console.log(`${c.name} ${c.core}: lends ${symbol}, ${c.loanCount} loans, grace ${c.grace} s, registry ${c.registry}`);
  if (c.loanCount === 0n) continue;

  // The newest loans in one multicall. Ids run from 1 to loanCount, closed and cancelled loans included.
  const ids: bigint[] = [];
  for (let id = c.loanCount; id > 0n && id > c.loanCount - LATEST; id -= 1n) ids.push(id);
  const loans = await client.multicall({
    allowFailure: false,
    contracts: ids.map((id) => ({address: c.core, abi: coreAbi, functionName: "getLoan", args: [id]} as const)),
  });
  loans.forEach((l, n) => {
    const ends = l.fundedAt === 0 ? "not funded" : `repayment closes ${new Date((l.fundedAt + l.term + c.grace) * 1000).toISOString()}`;
    console.log(
      `  #${ids[n]} ${STATE[l.state]}: ${formatUnits(l.principal, decimals)} ${symbol} borrowed, ` +
        `${formatUnits(l.cap, decimals)} to repay, ${l.term / 86_400} days, ${ends}`,
    );
  });
}

// The settings of the cores that take new loans: their registries' terms, fee and pause.
const open = read.filter((c) => c.current);
const settings = await client.multicall({
  allowFailure: false,
  contracts: open.flatMap(({registry}) => [
    {address: registry, abi: registryAbi, functionName: "allowedTerms"},
    {address: registry, abi: registryAbi, functionName: "feeBps"},
    {address: registry, abi: registryAbi, functionName: "newDealsPaused"},
  ] as const),
});
open.forEach((c, i) => {
  const terms = (settings[i * 3] as readonly number[]).map((t) => `${t / 86_400}d`).join(", ");
  console.log(`${c.name} registry: terms ${terms}, fee ${settings[i * 3 + 1]} bps, new loans paused: ${settings[i * 3 + 2]}`);
});
