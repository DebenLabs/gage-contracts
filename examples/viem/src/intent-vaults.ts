// Every gage partner vault on Robinhood Chain mainnet, read from each Intent factory: the USDG generation's
// (`intentV1.factory`) and one per lend asset (`intentV1Assets.<SYMBOL>.factory`). For each vault: its name, the asset
// it lends, `totalAssets()`, `freeLiquidity()` (what withdrawals can take now) and the value of one whole share.
// Read-only.
//
// Run from examples/viem:
//   npx tsx src/intent-vaults.ts
import {formatUnits, parseAbi, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

const factoryAbi = parseAbi([
  "function count() view returns (uint256)",
  "function vaults(uint256 index) view returns (address)",
  "function nameOf(address vault) view returns (string)",
  "function openCreation() view returns (bool)",
]);

const vaultAbi = parseAbi([
  "function asset() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function freeLiquidity() view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function paused() view returns (bool)",
  "function earliestMaturity() view returns (uint40)",
  "function feeBps() view returns (uint16)",
  "function MAX_TERM() view returns (uint32)",
]);

const erc20Abi = parseAbi(["function symbol() view returns (string)", "function decimals() view returns (uint8)"]);

/** The manifest key of every live generation: `intentV1` (USDG) and each `intentV1Assets.<SYMBOL>`. */
function generations(): string[] {
  const assets = (manifest as unknown as {intentV1Assets?: Record<string, unknown>}).intentV1Assets ?? {};
  return ["intentV1", ...Object.keys(assets).map((symbol) => `intentV1Assets.${symbol}`)];
}

const NO_DEADLINE = 2n ** 40n - 1n;

async function listFactory(key: string) {
  const factory = addressOf(`${key}.factory`);
  const [count, open] = await Promise.all([
    client.readContract({address: factory, abi: factoryAbi, functionName: "count"}),
    client.readContract({address: factory, abi: factoryAbi, functionName: "openCreation"}),
  ]);
  console.log(`\n${key}: factory ${factory}, ${count} vault(s), creation ${open ? "open to all" : "admitted creators only"}`);
  for (let i = 0n; i < count; i++) {
    const vault: Address = await client.readContract({address: factory, abi: factoryAbi, functionName: "vaults", args: [i]});
    const at = {address: vault, abi: vaultAbi} as const;
    const [name, asset, totalAssets, totalSupply, free, paused, earliest, feeBps, maxTerm, perShare] = await client.multicall({
      allowFailure: false,
      contracts: [
        {address: factory, abi: factoryAbi, functionName: "nameOf", args: [vault]},
        {...at, functionName: "asset"},
        {...at, functionName: "totalAssets"},
        {...at, functionName: "totalSupply"},
        {...at, functionName: "freeLiquidity"},
        {...at, functionName: "paused"},
        {...at, functionName: "earliestMaturity"},
        {...at, functionName: "feeBps"},
        {...at, functionName: "MAX_TERM"},
        {...at, functionName: "convertToAssets", args: [10n ** 18n]},
      ],
    });
    const [symbol, decimals] = await client.multicall({
      allowFailure: false,
      contracts: [
        {address: asset, abi: erc20Abi, functionName: "symbol"},
        {address: asset, abi: erc20Abi, functionName: "decimals"},
      ],
    });
    const fmt = (raw: bigint) => `${formatUnits(raw, decimals)} ${symbol}`;
    const now = BigInt(Math.floor(Date.now() / 1000));
    const due = BigInt(earliest) !== NO_DEADLINE && now >= BigInt(earliest);
    console.log(`  ${name} ${vault}`);
    console.log(`    lends ${symbol} (${asset}), performance fee ${feeBps / 100}% of each loan's return, longest loan ${maxTerm / 86_400} days`);
    console.log(`    totalAssets ${fmt(totalAssets)}, freeLiquidity ${fmt(free)}, shares ${formatUnits(totalSupply, 18)}`);
    console.log(`    one share is worth ${fmt(perShare)}${paused ? ", paused (withdrawals still open)" : ""}${due ? ", a loan is past its end: settle first" : ""}`);
  }
}

for (const key of generations()) await listFactory(key);
console.log("\nA depositor may end up holding the collateral instead of the asset it lent.");
