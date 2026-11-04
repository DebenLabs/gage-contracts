import { parseAbi } from "viem";

/** The hook's surface the keeper reads and calls, with the errors a simulation decodes. */
export const hookAbi = parseAbi([
  "function CURRENCY0() view returns (address)",
  "function CURRENCY1() view returns (address)",
  "function VAULT0() view returns (address)",
  "function VAULT1() view returns (address)",
  "function getPoolKey() view returns ((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks))",
  "function isKeeper(address) view returns (bool)",
  "function floatOf(address currency) view returns (uint256)",
  "function targetFloat(address currency) view returns (uint256)",
  "function rebalanceAmount(address currency) view returns (int256)",
  "function rebalance(address currency, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96) returns (int256)",
  "function claimPockets(address currency, uint256[] pocketIds)",
  "event Refilled(address indexed currency, uint256 assets, uint256 shares)",
  "event Swept(address indexed currency, uint256 assets, uint256 shares)",
  "error NotKeeper()",
  "error Swapping()",
  "error VaultSettling(address currency)",
  "error PriceOutOfBand(uint160 sqrtPriceX96, uint160 minSqrtPriceX96, uint160 maxSqrtPriceX96)",
  "error NothingToMove()",
  "error NotInitialized()",
  // The vault's own refusals, which a refill or a sweep bubbles up unchanged.
  "error SettlementDue()",
  "error SaleTooSoon()",
  "error RewardsPending()",
  "error InsufficientLiquidity()",
  "error OutstandingLoans()",
  "error InvalidAmount()",
  "error PausedError()",
]);

/** A gage partner vault (IntentVault): what the keeper reads, and its permissionless `settle`. */
export const vaultAbi = parseAbi([
  "function maxWithdraw(address owner) view returns (uint256)",
  "function freeLiquidity() view returns (uint256)",
  "function earliestMaturity() view returns (uint40)",
  "function settle(uint256[] ids)",
  "error SettlementDue()",
  "error InvalidAmount()",
]);

export const erc20Abi = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

/** Uniswap v4 StateView: the pool's price without calling the hook. */
export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
]);
