import { describe, expect, it } from "vitest";
import { interval, loadConfig } from "../src/config.js";

const base = { HOOK: "0x" + "11".repeat(20), STATE_VIEW: "0x" + "22".repeat(20), DEPLOYMENT: "/nonexistent", GAGE_MANIFEST: "/nonexistent" };

describe("keeper configuration (r12 review C45, C46)", () => {
  it("takes INTERVAL_MS as whole milliseconds of at least a second, and refuses anything else", () => {
    expect(interval(undefined)).toBe(60_000);
    expect(interval("1000")).toBe(1000);
    for (const raw of ["abc", "999", "-5", "1e3", "0"]) expect(() => interval(raw)).toThrow(/INTERVAL_MS/);
  });

  it("moves the float without a reference pool only when the partner allows it, and caps the fee", () => {
    const plain = loadConfig(base).config;
    expect([plain.referencePoolId, plain.allowSelfReference, plain.maxFeePerGas]).toEqual([null, false, 1_000_000_000n]);
    const allowed = loadConfig({ ...base, ALLOW_SELF_REFERENCE: "true", MAX_FEE_PER_GAS_WEI: "50000000" }).config;
    expect([allowed.allowSelfReference, allowed.maxFeePerGas]).toEqual([true, 50_000_000n]);
    expect(() => loadConfig({ ...base, MAX_FEE_PER_GAS_WEI: "0" })).toThrow(/MAX_FEE_PER_GAS_WEI/);
  });
});
