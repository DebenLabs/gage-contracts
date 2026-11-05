// A deposit into a gage partner vault, built and simulated on Robinhood Chain mainnet, never sent: the lend asset's
// `approve(vault, amount)`, then the vault's `deposit(assets, minShares)` with a 0.5% slippage bound. Where the wallet
// does not hold the amount (or has not approved it yet), the deposit is simulated with a state override that gives it
// the balance and the allowance for that one call, so any address can try it. `send` at the end shows the two
// transactions as you would send them with your own wallet client; this script never calls it and holds no key.
//
// Run from examples/viem (all three variables are optional):
//   VAULT=0x... WALLET=0x... AMOUNT=100 npx tsx src/intent-deposit.ts
// VAULT defaults to the USDG factory's first vault, AMOUNT is in whole units of the vault's asset.
//
// You may end up holding the collateral instead of USDG (for a lend-asset vault, instead of the asset you lent).
import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodeFunctionData,
  formatUnits,
  getAddress,
  keccak256,
  parseAbi,
  parseUnits,
  toHex,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type StateOverride,
  type Transport,
  type WalletClient,
} from "viem";
import {addressOf, client} from "./client.js";

// Node's environment, typed here because this package installs no Node type definitions.
declare const process: {env: Record<string, string | undefined>};

const erc20Abi = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

const factoryAbi = parseAbi([
  "function vaults(uint256 index) view returns (address)",
  "function isVault(address vault) view returns (bool)",
  "function nameOf(address vault) view returns (string)",
]);

const vaultAbi = parseAbi([
  "function asset() view returns (address)",
  "function paused() view returns (bool)",
  "function earliestMaturity() view returns (uint40)",
  "function maxDeposit(address receiver) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function deposit(uint256 assets, uint256 minShares) returns (uint256 shares)",
  "error InvalidAmount()",
  "error PausedError()",
  "error SettlementDue()",
  "error Impaired()",
  "error Slippage()",
  "error LimitExceeded()",
  "error RewardsPending()",
  "error SaleTooSoon()",
  "error TransferAmountMismatch()",
]);

const factory = addressOf("intentV1.factory");
const vault: Address = process.env.VAULT
  ? getAddress(process.env.VAULT)
  : await client.readContract({address: factory, abi: factoryAbi, functionName: "vaults", args: [0n]});
const wallet: Address = getAddress(process.env.WALLET ?? "0x1111111111111111111111111111111111111111");

const asset = await client.readContract({address: vault, abi: vaultAbi, functionName: "asset"});
const [symbol, decimals, paused, earliest, balance, allowance] = await client.multicall({
  allowFailure: false,
  contracts: [
    {address: asset, abi: erc20Abi, functionName: "symbol"},
    {address: asset, abi: erc20Abi, functionName: "decimals"},
    {address: vault, abi: vaultAbi, functionName: "paused"},
    {address: vault, abi: vaultAbi, functionName: "earliestMaturity"},
    {address: asset, abi: erc20Abi, functionName: "balanceOf", args: [wallet]},
    {address: asset, abi: erc20Abi, functionName: "allowance", args: [wallet, vault]},
  ],
});
// Raw units: 100 USDG is 100_000_000 (6 decimals); 1 NVDA is 10^18. The smallest deposit is one whole unit.
const amount = parseUnits(process.env.AMOUNT ?? "100", decimals);
const fmt = (raw: bigint) => `${formatUnits(raw, decimals)} ${symbol}`;

// What the vault would refuse, read before building anything.
if (amount < 10n ** BigInt(decimals)) throw new Error(`the smallest deposit is 1 ${symbol}`);
if (paused) throw new Error("the vault is paused: it takes no deposit (redemptions stay open)");
if (BigInt(Math.floor(Date.now() / 1000)) >= BigInt(earliest)) {
  throw new Error("a loan of the vault is past its end: call settle(ids) first (anyone may), then deposit");
}
const [maxDeposit, quoted] = await client.multicall({
  allowFailure: false,
  contracts: [
    {address: vault, abi: vaultAbi, functionName: "maxDeposit", args: [wallet]},
    {address: vault, abi: vaultAbi, functionName: "previewDeposit", args: [amount]},
  ],
});
if (amount > maxDeposit) throw new Error(`the vault takes at most ${fmt(maxDeposit)} now`);
const minShares = quoted - (quoted * 50n) / 10_000n; // 0.5%, gage-sdk's default slippage bound

const name = await client.readContract({address: factory, abi: factoryAbi, functionName: "nameOf", args: [vault]}).catch(() => "(another factory's vault)");
console.log(`Deposit ${fmt(amount)} into ${name} ${vault} from ${wallet}`);
console.log(`  previewDeposit: ${formatUnits(quoted, 18)} shares; minShares ${formatUnits(minShares, 18)}`);

// 1. approve(vault, amount) on the lend asset. Any account can simulate it.
const approveData = encodeFunctionData({abi: erc20Abi, functionName: "approve", args: [vault, amount]});
const approved = await client.simulateContract({account: wallet, address: asset, abi: erc20Abi, functionName: "approve", args: [vault, amount]});
console.log(`1. approve: to ${asset}, data ${approveData.slice(0, 10)}..., simulated -> ${approved.result}`);

// 2. deposit(assets, minShares) on the vault, simulated with the balance and allowance the approval and the wallet
//    would give it.
const depositData = encodeFunctionData({abi: vaultAbi, functionName: "deposit", args: [amount, minShares]});
let stateOverride: StateOverride | undefined;
if (balance < amount || allowance < amount) {
  const balanceSlot = await findSlot(asset, (s) => key(wallet, s), encodeFunctionData({abi: erc20Abi, functionName: "balanceOf", args: [wallet]}));
  const allowanceSlot = await findSlot(asset, (s) => keccak256(encodeAbiParameters([{type: "address"}, {type: "bytes32"}], [vault, key(wallet, s)])),
    encodeFunctionData({abi: erc20Abi, functionName: "allowance", args: [wallet, vault]}));
  if (!balanceSlot || !allowanceSlot) throw new Error(`could not find ${symbol}'s storage slots: approve first, then simulate the deposit from a funded wallet`);
  stateOverride = [{address: asset, stateDiff: [{slot: balanceSlot, value: toHex(amount, {size: 32})}, {slot: allowanceSlot, value: toHex(amount, {size: 32})}]}];
}
const deposited = await client.simulateContract({
  account: wallet,
  address: vault,
  abi: vaultAbi,
  functionName: "deposit",
  args: [amount, minShares],
  ...(stateOverride ? {stateOverride} : {}),
});
console.log(`2. deposit: to ${vault}, data ${depositData.slice(0, 10)}..., simulated -> ${formatUnits(deposited.result, 18)} shares${stateOverride ? " (balance and allowance overridden)" : ""}`);
console.log(`You may end up holding the collateral instead of ${symbol}.`);

/** The two transactions, sent with your own wallet client. Not called here. */
export async function send(walletClient: WalletClient<Transport, Chain, Account>) {
  const approval = await walletClient.writeContract({address: asset, abi: erc20Abi, functionName: "approve", args: [vault, amount]});
  await client.waitForTransactionReceipt({hash: approval});
  // A deposit first claims each open loan record's sGAGE for the vault: let the wallet estimate its gas, or add margin.
  const hash = await walletClient.writeContract({address: vault, abi: vaultAbi, functionName: "deposit", args: [amount, minShares]});
  return client.waitForTransactionReceipt({hash});
}

/** The storage key of `mapping(address => …)` entry `owner` at slot index `index`. */
function key(owner: Address, index: number): Hex {
  return keccak256(encodeAbiParameters([{type: "address"}, {type: "uint256"}], [owner, BigInt(index)]));
}

/** The first slot index whose entry, when overridden, is what `data` (a balanceOf or allowance call) reads back. */
async function findSlot(token: Address, slotOf: (index: number) => Hex, data: Hex): Promise<Hex | null> {
  const probe = 0x5eed_0000_0000_0001n;
  for (let i = 0; i < 64; i++) {
    const slot = slotOf(i);
    const {data: out} = await client.call({to: token, data, stateOverride: [{address: token, stateDiff: [{slot, value: toHex(probe, {size: 32})}]}]});
    if (out && decodeAbiParameters([{type: "uint256"}], out)[0] === probe) return slot;
  }
  return null;
}
