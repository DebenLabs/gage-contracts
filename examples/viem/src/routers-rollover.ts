// SPDX-License-Identifier: MIT
// Rollover: reads gage's RolloverRouter for each generation on Robinhood Chain mainnet, then builds the calls that
// leave and end a standing roll instruction on a loan, and simulates them for the loan's reclaim-right holder.
// Nothing is sent and no key is used. A roll itself carries funding plans signed by gage's rates service, and a
// standing roll is run by gage's keeper (the manifest's `rolloverExecutor`), so this script builds neither.
//
// Run from examples/viem: npm install, then npx tsx src/routers-rollover.ts
import {BaseError, ContractFunctionRevertedError, encodeFunctionData, parseAbi, zeroAddress, type Address, type ContractFunctionArgs, type Hex} from "viem";
import {addressOf, client, manifest} from "./client.js";

const routerAbi = parseAbi([
  "function CORE() view returns (address)",
  "function FILLS() view returns (address)",
  "function FACTORY() view returns (address)",
  "function USDG() view returns (address)",
  "function MAX_WINDOW() view returns (uint32)",
  "function owner() view returns (address)",
  "function paused() view returns (bool)",
  "function autoRolls(uint256 loanId) view returns (address borrower, uint32 term, uint32 window, uint8 rollsLeft, bool withRewards, address executor, uint40 until, uint128 maxCost, uint128 maxTopUp)",
  "function rollableAt(uint256 loanId) view returns (uint256)",
  "function evidenceFor(address borrower, bytes32 pricing) pure returns (bytes32)",
  "function setAutoRoll(uint256 loanId, address executor, uint32 term, uint32 window, uint128 maxCost, uint128 maxTopUp, uint8 rollsLeft, bool withRewards, uint40 until)",
  "function cancelAutoRoll(uint256 loanId)",
  "struct Roll { uint256 loanId; uint256 maxTopUp; bool withRewards; bytes32 pricing; }",
  "struct Allocation { address vault; uint8 units; uint128 principal; uint128 interest; uint128 minimum; uint128 executionFee; uint128 maxReserveShares; uint8 minRateGrade; uint16 capBps; uint16 managerBps; }",
  "struct Plan { address engine; uint256 listingId; address filler; address token; uint8 kind; uint256 collateral; uint128 principal; uint128 cap; uint32 term; uint32 costBps; uint32 feePolicy; uint64 epoch; uint40 issuedAt; uint40 expiry; bytes32 evidence; Allocation[] allocations; }",
  "function roll(Roll r, Plan[] plans, bytes[] signatures, uint256[] maxReserveShares) returns (uint256 id)",
  "event Rolled(uint256 indexed oldId, uint256 indexed newId, address indexed borrower, address caller, uint128 repaid, uint128 principal, uint128 cap, uint32 term, uint256 topUp)",
  "error InvalidAutoRoll()",
  "error NotBorrower()",
  "error NotExecutor()",
  "error NoAutoRoll()",
  "error PlanMismatch()",
]);

const coreAbi = parseAbi([
  "function REGISTRY() view returns (address)",
  "function loanCount() view returns (uint256)",
  "function ownerOf(uint256 id) view returns (address)",
  "function isApprovedForAll(address owner, address operator) view returns (bool)",
  "function setApprovalForAll(address operator, bool approved)",
  "struct V2Loan { address originator; address account; address token; address collateralBeneficiary; uint8 kind; uint8 state; uint8 filled; uint32 term; uint40 fundingDeadline; uint40 fundedAt; uint40 closedAt; uint128 principal; uint128 cap; uint128 originationFee; uint128 borrowerReward; uint128 lenderReward; uint256 collateral; bytes32 exposureKey; uint256 exposureAmount; }",
  "function getLoan(uint256 id) view returns (V2Loan)",
]);
const registryAbi = parseAbi(["function isRouter(address account) view returns (bool)", "function feeBps() view returns (uint16)"]);
const factoryAbi = parseAbi(["function isFiller(address filler) view returns (bool)"]);
const erc20Abi = parseAbi(["function approve(address spender, uint256 amount) returns (bool)"]);

const FUNDING = 1;
const ACTIVE = 2;
const STATES = ["NONE", "FUNDING", "ACTIVE", "REPAID", "DEFAULTED", "CANCELLED"];

/** The generations whose manifest entry names a rollover router. */
function generations(): {name: string; key: string}[] {
  const out = [{name: "USDG", key: "intentV1"}];
  for (const [symbol, entry] of Object.entries(manifest.intentV1Assets as Record<string, Record<string, unknown>>)) {
    if (typeof entry.rolloverRouter === "string") out.push({name: symbol, key: `intentV1Assets.${symbol}`});
    else console.log(`${symbol}: the manifest names no rollover router`);
  }
  return out;
}

async function readRouter(name: string, key: string) {
  const router = addressOf(`${key}.rolloverRouter`);
  const [core, fills, factory, cash, owner, paused] = await Promise.all([
    client.readContract({address: router, abi: routerAbi, functionName: "CORE"}),
    client.readContract({address: router, abi: routerAbi, functionName: "FILLS"}),
    client.readContract({address: router, abi: routerAbi, functionName: "FACTORY"}),
    client.readContract({address: router, abi: routerAbi, functionName: "USDG"}),
    client.readContract({address: router, abi: routerAbi, functionName: "owner"}),
    client.readContract({address: router, abi: routerAbi, functionName: "paused"}),
  ]);
  const registry = await client.readContract({address: core, abi: coreAbi, functionName: "REGISTRY"});
  const [entry, filler, loans] = await Promise.all([
    client.readContract({address: registry, abi: registryAbi, functionName: "isRouter", args: [router]}),
    client.readContract({address: factory, abi: factoryAbi, functionName: "isFiller", args: [router]}),
    client.readContract({address: core, abi: coreAbi, functionName: "loanCount"}),
  ]);
  const wired = core === addressOf(`${key}.core`) && fills === addressOf(`${key}.fillRouter`) && factory === addressOf(`${key}.factory`);
  console.log(`${name}: router ${router}`);
  console.log(`  core ${core}, cash asset ${cash}, wired to the manifest: ${wired}`);
  console.log(`  entry router: ${entry}, filler: ${filler}, paused: ${paused}, owner ${owner}, loans on the core: ${loans}`);
  return {router, core, cash, loans};
}

/** The newest loan on `core` that is funding or running, with the holder of its reclaim right. */
async function newestOpenLoan(core: Address, count: bigint) {
  for (let id = count; id > 0n && id > count - 50n; id--) {
    const loan = await client.readContract({address: core, abi: coreAbi, functionName: "getLoan", args: [id]});
    if (loan.state !== FUNDING && loan.state !== ACTIVE) continue;
    const holder = await client.readContract({address: core, abi: coreAbi, functionName: "ownerOf", args: [id]});
    return {id, loan, holder};
  }
  return null;
}

function revertName(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) return reverted.data?.errorName ?? reverted.shortMessage;
    return error.shortMessage;
  }
  return String(error);
}

/**
 * The calls a borrower sends to leave a standing instruction, close to gage's app's: the loan's own term, four rolls,
 * the last six hours of each loan (never more than an eighth of its term), gage's keeper as the only executor, and a
 * ceiling of twice this loan's own fixed cost and fee (the app starts from twice what a roll costs now, a quote from
 * gage's rates service). Amounts are raw units of the core's cash asset.
 */
function standingInstructionCalls(router: Address, core: Address, cash: Address, id: bigint, loan: {principal: bigint; cap: bigint; term: number; fundedAt: number; state: number}, feeBps: number, now: bigint) {
  const executor = addressOf("rolloverExecutor");
  const fee = (loan.principal * BigInt(feeBps)) / 10_000n;
  const maxCost = 2n * (loan.cap - loan.principal + fee);
  const rolls = 4;
  const window = Math.min(6 * 3600, Math.floor(loan.term / 8));
  const end = loan.state === ACTIVE ? BigInt(loan.fundedAt + loan.term) : now + 86_400n + BigInt(loan.term);
  const until = end + BigInt(rolls * loan.term) + 86_400n;
  // Each roll takes back the old loan's whole repayment: the first one's cap, then at most principal plus the ceiling.
  const allowance = loan.cap + BigInt(rolls - 1) * (loan.principal + maxCost);
  const args = [id, executor, loan.term, window, maxCost, maxCost, rolls, false, Number(until)] as const;
  return {
    args,
    approveRight: {to: core, data: encodeFunctionData({abi: coreAbi, functionName: "setApprovalForAll", args: [router, true]})},
    approveCash: {to: cash, data: encodeFunctionData({abi: erc20Abi, functionName: "approve", args: [router, allowance]})},
    set: {to: router, data: encodeFunctionData({abi: routerAbi, functionName: "setAutoRoll", args})},
    cancel: {to: router, data: encodeFunctionData({abi: routerAbi, functionName: "cancelAutoRoll", args: [id]})},
  };
}

/** The arguments of `roll`, typed from its ABI: the roll, the plans, their signatures and the reserve-share ceilings. */
type RollArgs = ContractFunctionArgs<typeof routerAbi, "nonpayable", "roll">;

/**
 * A roll by hand, once the signed plans are fetched from gage's rates service (gage-sdk's `roll` action and gage.cash
 * do so): `plans`, `signatures` and `pricing` come from that answer, `maxTopUp` is the most the wallet adds, in raw
 * units of the cash asset. The reserve-share ceilings are the first plan's own, as gage-sdk sends them. Not called here.
 */
export function rollCall(router: Address, loanId: bigint, maxTopUp: bigint, withRewards: boolean, pricing: Hex, plans: RollArgs[1], signatures: readonly Hex[]) {
  const args: RollArgs = [{loanId, maxTopUp, withRewards, pricing}, plans, signatures, plans[0]!.allocations.map((a) => a.maxReserveShares)];
  return {to: router, data: encodeFunctionData({abi: routerAbi, functionName: "roll", args})};
}

async function main() {
  const routers = [];
  for (const g of generations()) routers.push({...g, ...(await readRouter(g.name, g.key))});

  const usdg = routers[0]!;
  const block = await client.getBlock();
  const open = await newestOpenLoan(usdg.core, usdg.loans);
  if (!open) {
    console.log("\nNo loan of the USDG generation is funding or running now: nothing to simulate on.");
    return;
  }
  const {id, loan, holder} = open;
  console.log(`\nLoan ${id} (${STATES[loan.state]}), reclaim right held by ${holder}`);
  const standing = await client.readContract({address: usdg.router, abi: routerAbi, functionName: "autoRolls", args: [id]});
  console.log(`  standing instruction: ${standing[0] === zeroAddress ? "none" : `by ${standing[0]}, ${standing[3]} rolls left, at most ${standing[7]} a roll`}`);
  console.log(`  rollableAt: ${await client.readContract({address: usdg.router, abi: routerAbi, functionName: "rollableAt", args: [id]})}`);

  const registry = await client.readContract({address: usdg.core, abi: coreAbi, functionName: "REGISTRY"});
  const feeBps = await client.readContract({address: registry, abi: registryAbi, functionName: "feeBps"});
  const calls = standingInstructionCalls(usdg.router, usdg.core, usdg.cash, id, loan, feeBps, block.timestamp);
  console.log("  approve the right:", calls.approveRight);
  console.log("  approve the cash asset:", calls.approveCash);
  console.log("  setAutoRoll:", calls.set);

  // setAutoRoll moves nothing and reads only the right's holder, so it simulates for the holder as is.
  try {
    await client.simulateContract({address: usdg.router, abi: routerAbi, functionName: "setAutoRoll", args: calls.args, account: holder});
    console.log("  simulated for the holder: setAutoRoll would succeed");
  } catch (error) {
    console.log(`  simulated for the holder: reverts ${revertName(error)}`);
  }
  // Anyone else is refused.
  try {
    await client.simulateContract({address: usdg.router, abi: routerAbi, functionName: "setAutoRoll", args: calls.args, account: addressOf("rolloverExecutor")});
  } catch (error) {
    console.log(`  simulated for another wallet: reverts ${revertName(error)}`);
  }

  // Sending them, with the holder's own wallet client (createWalletClient({account, chain: robinhood, transport: http()})):
  //   await wallet.sendTransaction(calls.approveRight);
  //   await wallet.sendTransaction(calls.approveCash);
  //   await wallet.writeContract({address: usdg.router, abi: routerAbi, functionName: "setAutoRoll", args: calls.args});
  //   ...and later, to end it: await wallet.writeContract({address: usdg.router, abi: routerAbi, functionName: "cancelAutoRoll", args: [id]});
}

await main();
