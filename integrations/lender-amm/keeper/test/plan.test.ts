import { describe, expect, it } from "vitest";
import { band, decide, inBand, isqrt } from "../src/plan.js";

const t = { refillBelowBps: 5000n, sweepAboveBps: 15_000n };

describe("decide", () => {
  it("refills a float under half its target, by what the hook would move", () => {
    expect(decide({ float: 40n, target: 100n, move: 60n }, t)).toEqual({ kind: "refill", amount: 60n });
  });

  it("waits for free cash when the vault has none to refill with", () => {
    expect(decide({ float: 40n, target: 100n, move: 0n }, t)).toEqual({ kind: "wait_free_cash", short: 60n });
  });

  it("sweeps a float over one and a half times its target", () => {
    expect(decide({ float: 160n, target: 100n, move: -60n }, t)).toEqual({ kind: "sweep", amount: 60n });
  });

  it("leaves an excess under one whole unit, which the hook reports as no move", () => {
    expect(decide({ float: 160n, target: 100n, move: 0n }, t)).toEqual({ kind: "idle" });
  });

  it("does not chase a float between the thresholds", () => {
    expect(decide({ float: 60n, target: 100n, move: 40n }, t)).toEqual({ kind: "idle" });
    expect(decide({ float: 140n, target: 100n, move: -40n }, t)).toEqual({ kind: "idle" });
  });

  it("settles first while the vault is settling", () => {
    expect(decide({ float: 0n, target: null, move: 0n }, t)).toEqual({ kind: "settle" });
  });
});

describe("band", () => {
  const ref = 1_372_272_028_650_297_976_024_856n; // the testnet GLDx/USDG pool, about 300 USDG a token

  it("bounds the price within the deviation either way", () => {
    const b = band(ref, 100n);
    const price = (x: bigint) => (x * x * 10_000n) / (ref * ref);
    // Within a basis point of 1% either way, never wider: both roots round down.
    expect(price(b.min)).toBe(9899n);
    expect(price(b.max)).toBe(10_099n);
    expect(inBand(ref, b)).toBe(true);
    expect(inBand(b.min - 1n, b)).toBe(false);
    expect(inBand(b.max + 1n, b)).toBe(false);
  });

  it("collapses to the reference at zero deviation", () => {
    const b = band(ref, 0n);
    expect(b.min).toBe(ref);
    expect(b.max).toBe(ref);
  });

  it("refuses a deviation of the whole price", () => {
    expect(() => band(ref, 10_000n)).toThrow(RangeError);
  });
});

describe("isqrt", () => {
  it("rounds down", () => {
    expect(isqrt(0n)).toBe(0n);
    expect(isqrt(15n)).toBe(3n);
    expect(isqrt(16n)).toBe(4n);
    expect(isqrt(10n ** 36n)).toBe(10n ** 18n);
  });
});
