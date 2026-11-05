// Builds a listing on gage's USDG core: the WETH approval and the `list` call, checked against the core's registry,
// then simulated with eth_simulateV1 from a wallet given ETH for the simulation only (wrap, approve, list). Nothing is
// signed or sent, and no key is used anywhere. Put your own address in WALLET to simulate for it.
//
//   cd examples/viem && npm install && npx tsx src/cores-list.ts
//
// See docs/integrate/borrowing.md.
import {encodeFunctionData, formatUnits, getAddress, parseAbi, parseEther, type Address} from "viem";
import {addressOf, client} from "./client.js";

// Signatures as in src/v2/GageV2Vault.sol and src/v2/GageV2TokenRegistry.sol.
const coreAbi = parseAbi([
  "struct Collateral { uint8 kind; address token; uint256 amountOrTokenId; }",
  "function list(Collateral c, uint128 principal, uint128 cap, uint32 term, uint40 fundingDeadline, bool withRewards) returns (uint256 id)",
  "function loanCount() view returns (uint256)",
  "function REGISTRY() view returns (address)",
  "function MAX_FUNDING_WINDOW() view returns (uint32)",
]);
const registryAbi = parseAbi([
  "struct ERC20Config { bool allowed; uint8 lane; uint256 minAmount; uint256 maxDealRaw; uint256 maxOpenRaw; }",
  "function getERC20Config(address token) view returns (ERC20Config)",
  "function isTermAllowed(uint32 term) view returns (bool)",
  "function feeBps() view returns (uint16)",
  "function newDealsPaused() view returns (bool)",
]);
const wethAbi = parseAbi(["function approve(address spender, uint256 amount) returns (bool)", "function deposit() payable"]);

const core = addressOf("intentV1.core");
const weth = addressOf("WETH");
/** The borrower: any address simulates. A contract borrower must accept the ERC-721 reclaim right (onERC721Received). */
const WALLET: Address = getAddress("0x000000000000000000000000000000000000bEEF");

const TERM = 7 * 86_400; // seconds, counted from funding
const PRINCIPAL = 100_000_000n; // 100 USDG (6 decimals)
const CAP = 100_500_000n; // 100.50 USDG: a fixed cost of 0.50 USDG, 0.50% for 7 days

// 1. The core's own rules, read from its registry: not paused, the token admitted, the term allowed.
const registry = await client.readContract({address: core, abi: coreAbi, functionName: "REGISTRY"});
const [cfg, termAllowed, feeBps, paused, maxWindow, loanCount] = await client.multicall({
  allowFailure: false,
  contracts: [
    {address: registry, abi: registryAbi, functionName: "getERC20Config", args: [weth]},
    {address: registry, abi: registryAbi, functionName: "isTermAllowed", args: [TERM]},
    {address: registry, abi: registryAbi, functionName: "feeBps"},
    {address: registry, abi: registryAbi, functionName: "newDealsPaused"},
    {address: core, abi: coreAbi, functionName: "MAX_FUNDING_WINDOW"},
    {address: core, abi: coreAbi, functionName: "loanCount"},
  ],
});
if (paused) throw new Error("new loans are paused on this core (list reverts Paused)");
if (!cfg.allowed) throw new Error("WETH is not admitted on this core (list reverts InvalidCollateral)");
if (!termAllowed) throw new Error("7 days is not an allowed term (list reverts InvalidTerms)");

// Twice the minimum, within the per-loan cap: raw units, 18 decimals for WETH.
let amount = cfg.minAmount * 2n;
if (amount > cfg.maxDealRaw) amount = cfg.maxDealRaw;
const now = Number((await client.getBlock()).timestamp);
// Strictly after now and at most MAX_FUNDING_WINDOW (7 days) away; gage's app uses 24 hours.
const fundingDeadline = now + Math.min(86_400, maxWindow);
const fee = (PRINCIPAL * BigInt(feeBps)) / 10_000n;

// 2. The two calls, encoded: approve exactly the collateral to the core, then list it.
const collateral = {kind: 0, token: weth, amountOrTokenId: amount} as const; // kind 0: an ERC-20
const listArgs = [collateral, PRINCIPAL, CAP, TERM, fundingDeadline, false] as const;
const approveData = encodeFunctionData({abi: wethAbi, functionName: "approve", args: [core, amount]});
const listData = encodeFunctionData({abi: coreAbi, functionName: "list", args: listArgs});
console.log(`approve: to ${weth}\n  data ${approveData}`);
console.log(`list:    to ${core}\n  data ${listData}`);

// 3. Simulated in order, as if mined one after the other. Only the simulation gives the wallet ETH, to wrap into
//    the WETH it pledges; your own wallet would already hold the token and skip the wrap.
//    The public RPC rate-limits bursts of eth_simulateV1: retry a few times, waiting longer each time.
const simulate = () =>
  client.simulateCalls({
    account: WALLET,
    stateOverrides: [{address: WALLET, balance: amount + parseEther("0.01")}],
    calls: [
      {to: weth, abi: wethAbi, functionName: "deposit", value: amount},
      {to: weth, abi: wethAbi, functionName: "approve", args: [core, amount]},
      {to: core, abi: coreAbi, functionName: "list", args: listArgs},
    ],
  });
let simulation: Awaited<ReturnType<typeof simulate>> | undefined;
for (let attempt = 1; !simulation; attempt += 1) {
  try {
    simulation = await simulate();
  } catch (error) {
    if (!String(error).includes("Too Many Requests")) throw error;
    if (attempt === 5) throw new Error("the public RPC is refusing eth_simulateV1 for now (429): run again in a few minutes");
    await new Promise((done) => setTimeout(done, attempt * 5_000));
  }
}
const failed = simulation.results.find((r) => r.status !== "success");
if (failed) throw failed.error ?? new Error("the simulation failed");
const id = simulation.results[2]!.result as bigint;
if (id !== loanCount + 1n) throw new Error(`expected loan id ${loanCount + 1n}, simulated ${id}`);

console.log(`Simulated loan #${id}: ${formatUnits(amount, 18)} WETH pledged, ${formatUnits(PRINCIPAL, 6)} USDG asked,`);
console.log(`  ${formatUnits(PRINCIPAL - fee, 6)} USDG to collect once funded (after the ${feeBps} bps origination fee),`);
console.log(`  ${formatUnits(CAP, 6)} USDG to repay within ${TERM / 86_400} days of funding.`);
console.log(`  Open to the partner vaults until ${new Date(fundingDeadline * 1000).toISOString()}; nothing was sent.`);

// To send it with your own wallet (not run here):
//
//   import {createWalletClient, custom} from "viem";
//   import {robinhood} from "viem/chains";
//   const walletClient = createWalletClient({chain: robinhood, transport: custom(window.ethereum)});
//   const [account] = await walletClient.getAddresses();
//   await client.waitForTransactionReceipt({
//     hash: await walletClient.writeContract({account, address: weth, abi: wethAbi, functionName: "approve", args: [core, amount]}),
//   });
//   const {request} = await client.simulateContract({account, address: core, abi: coreAbi, functionName: "list", args: listArgs});
//   const hash = await walletClient.writeContract(request);
//   // The loan id is the `Listed` event's `id` in the receipt; read it back with getLoan(id).
