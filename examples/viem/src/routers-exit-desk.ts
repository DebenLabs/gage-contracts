// SPDX-License-Identifier: MIT
// Exit desk: reads gage's IntentExitDesk on Robinhood Chain mainnet, each partner vault's IntentLenderMarket and the
// desk's views of each vault (shortfall, records awaiting a settle, floors), then, for each depositor of the first
// vault, what the desk holds for them; and builds the calls a depositor sends to exit, list, cancel and collect,
// simulating the ones that can run as they stand. Nothing is sent and no key is used. A sale of an exit listing is
// bought by partner vaults through the fill router, on a plan signed by gage's rates service and sent by gage's
// keeper: this script builds no purchase.
//
// Run from examples/viem: npm install, then npx tsx src/routers-exit-desk.ts
import {BaseError, ContractFunctionRevertedError, encodeFunctionData, parseAbi, parseAbiItem, zeroAddress, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

const deskAbi = parseAbi([
  "function CURATOR_FLOOR_BPS() view returns (uint256)",
  "function START_KEEP_BPS() view returns (uint256)",
  "function EXIT_LIFE() view returns (uint256)",
  "function exits(address vault, address owner) view returns (uint256 shares, uint256 id, uint64 nonce)",
  "function committedAt(address vault, address owner) view returns (uint256)",
  "function owed(address asset, address owner) view returns (uint256)",
  "function shortfall(address vault, address owner) view returns (uint256)",
  "function pendingSettlements(address vault) view returns (uint256[] ids)",
  "function floorBps(address vault, uint256 id) view returns (uint256 floor)",
  "function exitNow(address vault, uint256 shares, uint256 id)",
  "function list(address vault, address owner, uint256 id)",
  "function cancel(address vault)",
  "function withdraw(address asset) returns (uint256 amount)",
  "error NotDeskVault()",
  "error NotOwner()",
  "error InvalidAmount()",
  "error NoExit()",
  "error ListingLive()",
  "error NoShortfall()",
  "error AboveAverageYield()",
  "error NothingToPay()",
  "error SettlementPending()",
]);
const vaultAbi = parseAbi([
  "function asset() view returns (address)",
  "function LENDER_MARKET() view returns (address)",
  "function totalAssets() view returns (uint256)",
  "function freeLiquidity() view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function maxRedeem(address owner) view returns (uint256)",
  "function approve(address spender, uint256 shares) returns (bool)",
  "function settle(uint256[] ids)",
]);
const marketAbi = parseAbi([
  "function SELLER() view returns (address)",
  "function CURATOR() view returns (address)",
  "function asks(uint256 id) view returns (uint40 listedAt, uint40 deadline, uint16 maxFeeBps, uint8 slots, uint64 nonce, bool exit)",
  "function keepBps(uint256 id) view returns (uint256)",
]);
const factoryAbi = parseAbi([
  "function exitDesk() view returns (address)",
  "function count() view returns (uint256)",
  "function vaults(uint256 index) view returns (address)",
]);
const deposit = parseAbiItem("event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)");

function revertName(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) return reverted.data?.errorName ?? reverted.shortMessage;
    return error.shortMessage;
  }
  return String(error);
}

async function main() {
  const desk = addressOf("intentV1.exitDesk");
  const [floor, start, life] = await Promise.all([
    client.readContract({address: desk, abi: deskAbi, functionName: "CURATOR_FLOOR_BPS"}),
    client.readContract({address: desk, abi: deskAbi, functionName: "START_KEEP_BPS"}),
    client.readContract({address: desk, abi: deskAbi, functionName: "EXIT_LIFE"}),
  ]);
  console.log(`Exit desk ${desk}: a listing starts at ${start} bps kept, a curator's stops at ${floor}, a commitment lasts ${life} s`);

  // Every generation's factory names the desk it lists through (zero while exits are closed there).
  const gens = [{name: "USDG", key: "intentV1"}, ...Object.keys(manifest.intentV1Assets).map((s) => ({name: s, key: `intentV1Assets.${s}`}))];
  const vaults: Address[] = [];
  for (const g of gens) {
    const factory = addressOf(`${g.key}.factory`);
    const [named, count] = await Promise.all([
      client.readContract({address: factory, abi: factoryAbi, functionName: "exitDesk"}),
      client.readContract({address: factory, abi: factoryAbi, functionName: "count"}),
    ]);
    console.log(`${g.name}: factory names ${named === desk ? "the manifest's desk" : named === zeroAddress ? "no desk (exits closed)" : named}, ${count} partner vaults`);
    for (let i = 0n; i < count && i < 10n; i++) {
      const vault = await client.readContract({address: factory, abi: factoryAbi, functionName: "vaults", args: [i]});
      const [market, total, free, pending] = await Promise.all([
        client.readContract({address: vault, abi: vaultAbi, functionName: "LENDER_MARKET"}),
        client.readContract({address: vault, abi: vaultAbi, functionName: "totalAssets"}),
        client.readContract({address: vault, abi: vaultAbi, functionName: "freeLiquidity"}),
        client.readContract({address: desk, abi: deskAbi, functionName: "pendingSettlements", args: [vault]}),
      ]);
      console.log(`  vault ${vault}: market ${market}, total ${total}, free now ${free} (raw units of its asset)`);
      // Records only a settle books: while one waits the desk lists nothing. Anyone may settle them.
      if (pending.length) {
        console.log(`    awaiting a settle: ${pending.join(", ")};`, {to: vault, data: encodeFunctionData({abi: vaultAbi, functionName: "settle", args: [pending.slice(0, 32)]})});
      }
      vaults.push(vault);
    }
  }
  const vault = vaults[0];
  if (!vault) return;

  // The first vault's depositors, from its ERC-4626 Deposit events, and what the desk holds for each.
  const asset = await client.readContract({address: vault, abi: vaultAbi, functionName: "asset"});
  const logs = await client.getLogs({address: vault, event: deposit, fromBlock: BigInt(manifest.intentV1.startBlock)});
  const holders = [...new Set(logs.map((l) => l.args.owner).filter((o): o is Address => Boolean(o)))];
  console.log(`\n${vault}: ${holders.length} depositors`);
  for (const holder of holders.slice(0, 5)) {
    const [shares, exit, need, owed, payable] = await Promise.all([
      client.readContract({address: vault, abi: vaultAbi, functionName: "balanceOf", args: [holder]}),
      client.readContract({address: desk, abi: deskAbi, functionName: "exits", args: [vault, holder]}),
      client.readContract({address: desk, abi: deskAbi, functionName: "shortfall", args: [vault, holder]}),
      client.readContract({address: desk, abi: deskAbi, functionName: "owed", args: [asset, holder]}),
      client.readContract({address: vault, abi: vaultAbi, functionName: "maxRedeem", args: [holder]}),
    ]);
    console.log(`  ${holder}: ${shares} shares (redeemable now ${payable}), committed ${exit[0]}, shortfall ${need}, owed by the desk ${owed}`);
  }
  const holder = holders[0];
  if (!holder) return;

  // The calls a depositor sends. Exit now is for what the vault cannot pay now: what it can pay is a redemption.
  // `id` is the vault's loan to list (zero commits and lists nothing); gage-sdk's `earnExitNow` chooses it as the app does.
  const shares = await client.readContract({address: vault, abi: vaultAbi, functionName: "balanceOf", args: [holder]});
  const id = 0n;
  const calls = {
    approve: {to: vault, data: encodeFunctionData({abi: vaultAbi, functionName: "approve", args: [desk, shares]})},
    exitNow: {to: desk, data: encodeFunctionData({abi: deskAbi, functionName: "exitNow", args: [vault, shares, id]})},
    list: {to: desk, data: encodeFunctionData({abi: deskAbi, functionName: "list", args: [vault, holder, 1n]})},
    cancel: {to: desk, data: encodeFunctionData({abi: deskAbi, functionName: "cancel", args: [vault]})},
    withdraw: {to: desk, data: encodeFunctionData({abi: deskAbi, functionName: "withdraw", args: [asset]})},
  };
  console.log(calls);

  // Simulated for that depositor as the chain stands: each reverts with the reason the desk gives now.
  const allowance = await client.readContract({address: vault, abi: vaultAbi, functionName: "allowance", args: [holder, desk]});
  const sims = [
    {what: `exitNow (desk approved for ${allowance} shares)`, run: () => client.simulateContract({address: desk, abi: deskAbi, functionName: "exitNow", args: [vault, shares, id], account: holder})},
    {what: "list", run: () => client.simulateContract({address: desk, abi: deskAbi, functionName: "list", args: [vault, holder, 1n], account: holder})},
    {what: "cancel", run: () => client.simulateContract({address: desk, abi: deskAbi, functionName: "cancel", args: [vault], account: holder})},
    {what: "withdraw", run: () => client.simulateContract({address: desk, abi: deskAbi, functionName: "withdraw", args: [asset], account: holder})},
  ];
  for (const s of sims) {
    try {
      await s.run();
      console.log(`  ${s.what}: would succeed`);
    } catch (error) {
      console.log(`  ${s.what}: reverts ${revertName(error)}`);
    }
  }

  // The market's listing of a loan, and the share of its return still to come a sale keeps above book value now.
  const market = await client.readContract({address: vault, abi: vaultAbi, functionName: "LENDER_MARKET"});
  const ask = await client.readContract({address: market, abi: marketAbi, functionName: "asks", args: [1n]});
  console.log(`  market listing of loan 1: listed at ${ask[0]}, exit listing ${ask[5]}, keeps ${await client.readContract({address: market, abi: marketAbi, functionName: "keepBps", args: [1n]})} bps`);

  // Sending them, with the depositor's own wallet client (createWalletClient({account, chain: robinhood, transport: http()})):
  //   await wallet.sendTransaction(calls.approve);   // the desk may redeem only these shares, at a sale
  //   await wallet.sendTransaction(calls.exitNow);   // commit, and list loan `id` for the exit
  //   await wallet.sendTransaction(calls.withdraw);  // after a sale: collect what it redeemed
}

await main();
