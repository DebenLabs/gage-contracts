/**
 * What the keeper does with one currency's float, as pure functions of what it read. The hook moves the float toward
 * its target and never past it; the keeper only decides when, with hysteresis so it does not chase every swap.
 */

export const BPS = 10_000n;

export interface Thresholds {
  /** Refill when the float is below this share of its target, in basis points (5000: under half the target). */
  refillBelowBps: bigint;
  /** Sweep when the float is above this share of its target, in basis points (15000: over one and a half times). */
  sweepAboveBps: bigint;
}

export interface Side {
  /** The tokens the hook holds for swaps. */
  float: bigint;
  /** The float the hook keeps; null while the vault is settling (the hook's `VaultSettling`). */
  target: bigint | null;
  /** The hook's `rebalanceAmount`: positive a refill (bounded by the vault's free cash), negative a sweep, zero none. */
  move: bigint;
}

export type Decision =
  | { kind: "refill"; amount: bigint }
  | { kind: "sweep"; amount: bigint }
  /** A loan past its end awaits `settle`: the vault refuses share moves, and so does the hook. */
  | { kind: "settle" }
  /** The float is low but the vault has no free cash now: loans must repay first. */
  | { kind: "wait_free_cash"; short: bigint }
  | { kind: "idle" };

export function decide(side: Side, t: Thresholds): Decision {
  if (side.target === null) return { kind: "settle" };
  const low = side.float * BPS < side.target * t.refillBelowBps;
  const high = side.float * BPS > side.target * t.sweepAboveBps;
  if (low && side.move > 0n) return { kind: "refill", amount: side.move };
  if (low) return { kind: "wait_free_cash", short: side.target - side.float };
  if (high && side.move < 0n) return { kind: "sweep", amount: -side.move };
  return { kind: "idle" };
}

export interface Band {
  min: bigint;
  max: bigint;
}

const SCALE = 10n ** 18n;

/** Integer square root, rounded down. */
export function isqrt(x: bigint): bigint {
  if (x < 0n) throw new RangeError("isqrt of a negative number");
  if (x < 2n) return x;
  let y = x;
  let z = (x + 1n) / 2n;
  while (z < y) {
    y = z;
    z = (x / z + z) / 2n;
  }
  return y;
}

/**
 * The sqrt-price band within which the hook may move the float: the reference price, moved by at most
 * `maxDeviationBps` either way in price terms (so by the square root of that in sqrt-price terms). The hook refuses a
 * rebalance whose pool price is outside it, so a price pushed away from the market cannot make it deploy liquidity
 * there, and a price moved between this read and the transaction's inclusion fails it.
 */
export function band(referenceSqrtPriceX96: bigint, maxDeviationBps: bigint): Band {
  if (maxDeviationBps < 0n || maxDeviationBps >= BPS) throw new RangeError("maxDeviationBps must be in [0, 10000)");
  const low = isqrt(((BPS - maxDeviationBps) * SCALE * SCALE) / BPS);
  const high = isqrt(((BPS + maxDeviationBps) * SCALE * SCALE) / BPS);
  return { min: (referenceSqrtPriceX96 * low) / SCALE, max: (referenceSqrtPriceX96 * high + SCALE - 1n) / SCALE };
}

export function inBand(sqrtPriceX96: bigint, b: Band): boolean {
  return sqrtPriceX96 >= b.min && sqrtPriceX96 <= b.max;
}
