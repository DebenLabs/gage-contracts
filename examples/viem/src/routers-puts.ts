// SPDX-License-Identifier: MIT
// Puts: reads the NVDA generation's PutRouter and LoopRouter on Robinhood Chain mainnet, the pools a close may buy
// NVDA through, and USDG's admission as collateral; then builds the calls that close a running put out of its own
// USDG and simulates them for the put's borrower when one runs. Nothing is sent and no key is used. Opening a put
// (the loop router) and rolling one carry funding plans signed by gage's rates service; this script builds neither.
//
// Run from examples/viem: npm install, then npx tsx src/routers-puts.ts
import {BaseError, ContractFunctionRevertedError, encodeFunctionData, parseAbi, zeroAddress, type Address} from "viem";
import {addressOf, client, manifest} from "./client.js";

const putAbi = parseAbi([
  "function CORE() view returns (address)",
  "function FILLS() view returns (address)",
  "function FACTORY() view returns (address)",
  "function V3_FACTORY() view returns (address)",
  "function USDG() view returns (address)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function autoRolls(uint256 loanId) view returns (address borrower, uint32 term, uint32 window, uint8 rollsLeft, bool withRewards, address executor, uint40 until, uint128 maxCost, uint128 maxSpend)",
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct Swap { uint8 venue; PoolKey key; uint24 v3Fee; }",
  "struct Close { uint256 loanId; Swap swap; uint256 maxSpend; uint256 minBack; address recipient; }",
  "function close(Close c) returns (uint256 spent, uint256 returned)",
  "event Closed(uint256 indexed loanId, address indexed borrower, address recipient, uint128 repaid, uint256 spent, uint256 returned)",
  "error NotBorrower()",
  "error NotActive()",
  "error InvalidSwap()",
  "error InvalidRecipient()",
  "error SpendTooHigh(uint256 spent, uint256 maxSpend)",
  "error ReturnTooLow(uint256 returned, uint256 minBack)",
  "error PartialPurchase(uint256 bought, uint256 wanted)",
  "error CollateralMismatch()",
  "error NotAuthorized()",
]);
const loopAbi = parseAbi([
  "function CORE() view returns (address)",
  "function USDG() view returns (address)",
  "function V3_FACTORY() view returns (address)",
  "function paused() view returns (bool)",
]);
const coreAbi = parseAbi([
  "function REGISTRY() view returns (address)",
  "function loanCount() view returns (uint256)",
  "function ownerOf(uint256 id) view returns (address)",
  "function getApproved(uint256 id) view returns (address)",
  "function approve(address to, uint256 id)",
  "struct V2Loan { address originator; address account; address token; address collateralBeneficiary; uint8 kind; uint8 state; uint8 filled; uint32 term; uint40 fundingDeadline; uint40 fundedAt; uint40 closedAt; uint128 principal; uint128 cap; uint128 originationFee; uint128 borrowerReward; uint128 lenderReward; uint256 collateral; bytes32 exposureKey; uint256 exposureAmount; }",
  "function getLoan(uint256 id) view returns (V2Loan)",
]);
const registryAbi = parseAbi([
  "function isRouter(address account) view returns (bool)",
  "function feeBps() view returns (uint16)",
  "function allowedTerms() view returns (uint32[])",
  "struct ERC20Config { bool allowed; uint8 lane; uint256 minAmount; uint256 maxDealRaw; uint256 maxOpenRaw; }",
  "function getERC20Config(address token) view returns (ERC20Config)",
]);
const factoryAbi = parseAbi(["function isFiller(address filler) view returns (bool)"]);
const v3FactoryAbi = parseAbi(["function getPool(address tokenA, address tokenB, uint24 fee) view returns (address)"]);
const v3PoolAbi = parseAbi(["function liquidity() view returns (uint128)"]);
const stateViewAbi = parseAbi(["function getLiquidity(bytes32 poolId) view returns (uint128)"]);

const ACTIVE = 2;
const emptyPoolKey = {currency0: zeroAddress, currency1: zeroAddress, fee: 0, tickSpacing: 0, hooks: zeroAddress};

function revertName(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) return reverted.data?.errorName ?? reverted.shortMessage;
    return error.shortMessage;
  }
  return String(error);
}

async function main() {
  const puts = addressOf("intentV1Assets.NVDA.putRouter");
  const loops = addressOf("intentV1Assets.NVDA.loopRouter");
  const core = addressOf("intentV1Assets.NVDA.core");
  const factory = addressOf("intentV1Assets.NVDA.factory");
  const usdg = addressOf("USDG");
  const nvda = addressOf("intentV1Assets.NVDA.lendAsset.token");

  const [putCore, putFactory, putCash, v3Factory, owner, paused] = await Promise.all([
    client.readContract({address: puts, abi: putAbi, functionName: "CORE"}),
    client.readContract({address: puts, abi: putAbi, functionName: "FACTORY"}),
    client.readContract({address: puts, abi: putAbi, functionName: "USDG"}),
    client.readContract({address: puts, abi: putAbi, functionName: "V3_FACTORY"}),
    client.readContract({address: puts, abi: putAbi, functionName: "owner"}),
    client.readContract({address: puts, abi: putAbi, functionName: "paused"}),
  ]);
  const [loopCore, loopCash, loopPaused] = await Promise.all([
    client.readContract({address: loops, abi: loopAbi, functionName: "CORE"}),
    client.readContract({address: loops, abi: loopAbi, functionName: "USDG"}),
    client.readContract({address: loops, abi: loopAbi, functionName: "paused"}),
  ]);
  const registry = await client.readContract({address: core, abi: coreAbi, functionName: "REGISTRY"});
  const [putEntry, loopEntry, putFiller, loopFiller, pledge, feeBps, terms] = await Promise.all([
    client.readContract({address: registry, abi: registryAbi, functionName: "isRouter", args: [puts]}),
    client.readContract({address: registry, abi: registryAbi, functionName: "isRouter", args: [loops]}),
    client.readContract({address: factory, abi: factoryAbi, functionName: "isFiller", args: [puts]}),
    client.readContract({address: factory, abi: factoryAbi, functionName: "isFiller", args: [loops]}),
    client.readContract({address: registry, abi: registryAbi, functionName: "getERC20Config", args: [usdg]}),
    client.readContract({address: registry, abi: registryAbi, functionName: "feeBps"}),
    client.readContract({address: registry, abi: registryAbi, functionName: "allowedTerms"}),
  ]);
  console.log(`PutRouter ${puts}: core ${putCore === core}, factory ${putFactory === factory}, pays in NVDA ${putCash === nvda}, paused ${paused}, owner ${owner}`);
  console.log(`  entry router ${putEntry}, filler ${putFiller}`);
  console.log(`LoopRouter ${loops}: core ${loopCore === core}, pays in NVDA ${loopCash === nvda}, paused ${loopPaused}, entry router ${loopEntry}, filler ${loopFiller}`);
  console.log(`USDG as collateral on the NVDA core: allowed ${pledge.allowed}, at least ${pledge.minAmount} and at most ${pledge.maxDealRaw} raw (6 decimals) a loan`);
  console.log(`  origination fee ${feeBps} bps, terms ${terms.map((t) => `${t / 86_400} days`).join(", ")}`);

  // The venues a close or a roll may buy NVDA through: the V3 factory's pools of the pair, and hookless v4 pools.
  for (const fee of [100, 500, 3000, 10_000]) {
    const pool = await client.readContract({address: v3Factory, abi: v3FactoryAbi, functionName: "getPool", args: [usdg, nvda, fee]});
    if (pool === zeroAddress) continue;
    const liquidity = await client.readContract({address: pool, abi: v3PoolAbi, functionName: "liquidity"});
    console.log(`  V3 pool, fee ${fee}: ${pool}, liquidity ${liquidity}`);
  }
  const v4 = (manifest.pools as Record<string, {currency0: string; currency1: string; fee: number; tickSpacing: number; hooks: string; poolId: `0x${string}`}>).nvdaUsdg;
  if (v4) {
    const liquidity = await client.readContract({address: addressOf("StateView"), abi: stateViewAbi, functionName: "getLiquidity", args: [v4.poolId]});
    console.log(`  v4 pool, fee ${v4.fee}, tick spacing ${v4.tickSpacing}, hooks ${v4.hooks}: liquidity ${liquidity}`);
  }

  // A running put: a loan on the NVDA core that pledges USDG.
  const count = await client.readContract({address: core, abi: coreAbi, functionName: "loanCount"});
  let running: {id: bigint; holder: Address; collateral: bigint; cap: bigint} | null = null;
  for (let id = count; id > 0n && id > count - 50n && !running; id--) {
    const loan = await client.readContract({address: core, abi: coreAbi, functionName: "getLoan", args: [id]});
    if (loan.state !== ACTIVE || loan.token !== usdg) continue;
    const holder = await client.readContract({address: core, abi: coreAbi, functionName: "ownerOf", args: [id]});
    running = {id, holder, collateral: loan.collateral, cap: loan.cap};
  }
  if (!running) {
    console.log(`\nNo put runs on the NVDA core now (${count} loans): the close below is built for loan 1 and not simulated.`);
  }
  const id = running?.id ?? 1n;
  const holder = running?.holder ?? zeroAddress;
  // The close: buy exactly the NVDA repayment back through the V3 pool at 0.05%, spend at most `maxSpend` USDG of the
  // pledge, return at least `minBack`. A real close sets maxSpend just above a quote of that exact-output purchase.
  const collateral = running?.collateral ?? 0n;
  const maxSpend = collateral;
  const minBack = 0n;
  const close = {loanId: id, swap: {venue: 1, key: emptyPoolKey, v3Fee: 500}, maxSpend, minBack, recipient: holder} as const;
  const approveRight = {to: core, data: encodeFunctionData({abi: coreAbi, functionName: "approve", args: [puts, id]})};
  const closeCall = {to: puts, data: encodeFunctionData({abi: putAbi, functionName: "close", args: [close]})};
  console.log("approve the reclaim right:", approveRight);
  console.log("close:", closeCall);

  if (running) {
    const approved = await client.readContract({address: core, abi: coreAbi, functionName: "getApproved", args: [id]});
    if (approved !== puts) console.log("  the right is not approved to the put router yet: the simulation reverts until it is");
    try {
      const {result} = await client.simulateContract({address: puts, abi: putAbi, functionName: "close", args: [close], account: holder});
      console.log(`  simulated for the borrower: spends ${result[0]} USDG of the pledge, returns ${result[1]}`);
    } catch (error) {
      console.log(`  simulated for the borrower: reverts ${revertName(error)}`);
    }
  }

  // Sending them, with the borrower's own wallet client (createWalletClient({account, chain: robinhood, transport: http()})):
  //   await wallet.sendTransaction(approveRight);
  //   await wallet.writeContract({address: puts, abi: putAbi, functionName: "close", args: [close]});
}

await main();
