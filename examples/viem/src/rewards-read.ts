// What it shows: sGAGE rewards on loans, read-only. The USDG core's rewards ledger (bridged through its legacy
// adapter), each lend-asset core's ledger and the rewards bridge its fee processor forwards fees to, the newest live
// loan's allocation on its quadratic clock, and, for a wallet, what it can claim and the calls that claim it (built,
// never sent: no key is used anywhere).
// Run from examples/viem: npx tsx src/rewards-read.ts [wallet address]
import {encodeFunctionData, getAddress, parseAbi, zeroAddress, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

/** Node's own, declared here because the examples carry no @types/node. */
declare const process: {argv: string[]};

const ledgerAbi = parseAbi([
  "struct Allocation { address borrower; uint40 start; uint40 end; uint32 term; uint128 borrowerTotal; uint128 lenderTotal; uint128 borrowerAccounted; address[4] lenders; }",
  "function BRIDGE() view returns (address)",
  "function freeBudget() view returns (uint256)",
  "function funderGate() view returns (address)",
  "function allocation(uint256 id) view returns (Allocation)",
  "function claimable(uint256 id, address account) view returns (uint256)",
  "function claim(uint256 id, address recipient)",
]);
const coreAbi = parseAbi([
  "struct V2Loan { address originator; address account; address token; address collateralBeneficiary; uint8 kind; uint8 state; uint8 filled; uint32 term; uint40 fundingDeadline; uint40 fundedAt; uint40 closedAt; uint128 principal; uint128 cap; uint128 originationFee; uint128 borrowerReward; uint128 lenderReward; uint256 collateral; bytes32 exposureKey; uint256 exposureAmount; }",
  "function REWARDS() view returns (address)",
  "function BRIDGE() view returns (address)",
  "function loanCount() view returns (uint256)",
  "function getLoan(uint256 id) view returns (V2Loan)",
]);
const bridgeAbi = parseAbi([
  "function CORE() view returns (address)",
  "function batchCount() view returns (uint256)",
  "function availableUSDG() view returns (uint256)",
  "function originationFeesMirrored() view returns (uint256)",
  "function usdgMirrored() view returns (uint256)",
  "function borrowerOwed(uint256 batchId, address borrower) view returns (uint256)",
  "function claim(uint256[] batchIds, address to) returns (uint256 total)",
]);
const feeProcessorAbi = parseAbi(["function forwardTo() view returns (address)"]);
const factoryAbi = parseAbi(["function count() view returns (uint256)", "function vaults(uint256 index) view returns (address)"]);
const vaultAbi = parseAbi([
  "function rewardClaimable(address who) view returns (uint256)",
  "function claimRewards() returns (uint256 amount)",
]);

const ACTIVE = 2; // V2State.ACTIVE
const sgage = (raw: bigint) => `${(Number(raw) / 1e18).toFixed(4)} sGAGE`;
const wallet = process.argv[2] ? getAddress(process.argv[2]) : null;
const calls: {to: Address; data: `0x${string}`; what: string}[] = [];

// 1. The USDG core's ledger: created by the core, backed by its legacy adapter, no budget of its own.
const usdgCore = addressOf("intentV1.core");
const usdgLedger = await client.readContract({address: usdgCore, abi: coreAbi, functionName: "REWARDS"});
const [adapter, usdgBudget, usdgGate] = await Promise.all([
  client.readContract({address: usdgLedger, abi: ledgerAbi, functionName: "BRIDGE"}),
  client.readContract({address: usdgLedger, abi: ledgerAbi, functionName: "freeBudget"}),
  client.readContract({address: usdgLedger, abi: ledgerAbi, functionName: "funderGate"}),
]);
console.log(`USDG core ${usdgCore}: ledger ${usdgLedger}, legacy adapter ${adapter}, free budget ${sgage(usdgBudget)}, lenders: vaults of ${usdgGate}`);

// 2. Each lend-asset core's ledger, and the rewards bridge its fee processor forwards fees to.
const assets = (manifest as {intentV1Assets: Record<string, unknown>}).intentV1Assets;
for (const symbol of Object.keys(assets)) {
  const ledger = addressOf(`intentV1Assets.${symbol}.engine.rewards`);
  const [bridged, budget] = await Promise.all([
    client.readContract({address: ledger, abi: ledgerAbi, functionName: "BRIDGE"}),
    client.readContract({address: ledger, abi: ledgerAbi, functionName: "freeBudget"}),
  ]);
  const target = await client.readContract({address: addressOf(`intentV1Assets.${symbol}.feeProcessor`), abi: feeProcessorAbi, functionName: "forwardTo"});
  console.log(`${symbol} core ledger ${ledger}: ${bridged === zeroAddress ? "unbridged" : "bridged"}, free budget ${sgage(budget)}`);
  if (getAddress(target) === addressOf("DealFeeRouter")) {
    console.log("  no rewards bridge: its fees go straight to DealFeeRouter");
    continue;
  }
  const on = {address: target, abi: bridgeAbi} as const;
  const [core, batches, waiting, weights, mirrored] = await Promise.all([
    client.readContract({...on, functionName: "CORE"}),
    client.readContract({...on, functionName: "batchCount"}),
    client.readContract({...on, functionName: "availableUSDG"}),
    client.readContract({...on, functionName: "originationFeesMirrored"}),
    client.readContract({...on, functionName: "usdgMirrored"}),
  ]);
  if (getAddress(core) !== addressOf(`intentV1Assets.${symbol}.core`)) throw new Error(`${symbol}: forward target is not this core's bridge`);
  console.log(`  rewards bridge ${target}: ${batches} batches, ${Number(waiting) / 1e6} USDG waiting to be mirrored`);
  console.log(`  mirrored so far: origination fees ${weights} raw ${symbol}, ${Number(mirrored) / 1e6} USDG of mirror-deal fees`);
  if (!wallet) continue;
  const owed: bigint[] = [];
  for (let id = 1n; id <= batches; id++) {
    const amount = await client.readContract({...on, functionName: "borrowerOwed", args: [id, wallet]});
    if (amount > 0n) owed.push(id);
  }
  if (owed.length) calls.push({to: target, data: encodeFunctionData({abi: bridgeAbi, functionName: "claim", args: [owed, wallet]}), what: `claim ${symbol} borrower rewards of batches ${owed.join(", ")}`});
}

// 3. The newest live loan with a lender reward, on the newest core in nativeV2.engines that has one.
const engines = (manifest as {nativeV2: {engines: {engine: string; rewards: string}[]}}).nativeV2.engines;
search: for (let e = engines.length - 1; e >= 0; e--) {
  const core = getAddress(engines[e]!.engine);
  const count = await client.readContract({address: core, abi: coreAbi, functionName: "loanCount"});
  for (let id = count; id > 0n && id + 64n > count; id--) {
    const loan = await client.readContract({address: core, abi: coreAbi, functionName: "getLoan", args: [id]});
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (loan.state !== ACTIVE || loan.lenderReward === 0n || now >= BigInt(loan.fundedAt) + BigInt(loan.term)) continue;
    const ledger = getAddress(engines[e]!.rewards);
    const a = await client.readContract({address: ledger, abi: ledgerAbi, functionName: "allocation", args: [id]});
    const elapsed = now - BigInt(a.start), term = BigInt(a.term);
    const curve = (total: bigint) => (total * elapsed * elapsed) / (term * term);
    console.log(`loan ${id} on core ${core} (ledger ${ledger}), ${Number(term) / 86400}-day term, ${(Number(elapsed) / 3600).toFixed(1)} hours in`);
    console.log(`  borrower ${a.borrower}: ${sgage(curve(a.borrowerTotal))} of ${sgage(a.borrowerTotal)} accrued`);
    console.log(`  lender quarters ${a.lenders.join(", ")}: ${sgage(curve(a.lenderTotal))} of ${sgage(a.lenderTotal)} accrued`);
    break search;
  }
}

// 4. For a wallet: its loan rewards on each core's newest loans, and its partner vaults' sGAGE.
if (wallet) {
  for (const {engine, rewards} of engines) {
    const core = getAddress(engine), ledger = getAddress(rewards);
    const count = await client.readContract({address: core, abi: coreAbi, functionName: "loanCount"});
    const ids = Array.from({length: Number(count < 64n ? count : 64n)}, (_, k) => count - BigInt(k));
    const amounts = await client.multicall({
      contracts: ids.map((id) => ({address: ledger, abi: ledgerAbi, functionName: "claimable", args: [id, wallet]}) as const),
      allowFailure: false,
    });
    ids.forEach((id, k) => {
      const amount = amounts[k]!;
      if (amount > 0n) calls.push({to: ledger, data: encodeFunctionData({abi: ledgerAbi, functionName: "claim", args: [id, wallet]}), what: `claim ${sgage(amount)} of loan ${id} on core ${core}`});
    });
  }
  const previous = (manifest as {intentV1Previous?: {intentV1: {factory: string}}[]}).intentV1Previous ?? [];
  const factories = [
    addressOf("intentV1.factory"),
    ...previous.map((p) => getAddress(p.intentV1.factory)),
    ...Object.keys(assets).map((s) => addressOf(`intentV1Assets.${s}.factory`)),
  ];
  for (const factory of factories) {
    const n = await client.readContract({address: factory, abi: factoryAbi, functionName: "count"});
    for (let i = 0n; i < n; i++) {
      const vault = await client.readContract({address: factory, abi: factoryAbi, functionName: "vaults", args: [i]});
      const amount = await client.readContract({address: vault, abi: vaultAbi, functionName: "rewardClaimable", args: [wallet]});
      if (amount > 0n) calls.push({to: vault, data: encodeFunctionData({abi: vaultAbi, functionName: "claimRewards"}), what: `claim ${sgage(amount)} from vault ${vault}`});
    }
  }
  console.log(calls.length ? `calls for ${wallet}, each sent from the wallet itself:` : `nothing for ${wallet} to claim now`);
  for (const c of calls) console.log(`  ${c.what}: to ${c.to}, data ${c.data}`);
  // To send one with your own wallet client (not run here):
  //   await walletClient.writeContract({address: vault, abi: vaultAbi, functionName: "claimRewards", account});
  //   await walletClient.writeContract({address: ledger, abi: ledgerAbi, functionName: "claim", args: [loanId, account.address], account});
}
