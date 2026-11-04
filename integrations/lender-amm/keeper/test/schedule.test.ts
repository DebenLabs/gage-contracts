import { describe, expect, it } from "vitest";
import { accountingUrl, freeCashSchedule, moreBy, positionUrl, type Accounting } from "../src/schedule.js";
import { poolIdOf } from "../src/keeper.js";

const accounting = (free: string, loans: Accounting["loans"]): Accounting => ({
  liquidity: { free },
  settlement: { earliestMaturity: null, due: false, settleable: [] },
  loans,
});

describe("freeCashSchedule", () => {
  const acc = accounting("100", [
    { id: "3", state: "PERFORMING", principal: "500", interest: "5", maturity: 2_000 },
    { id: "1", state: "PERFORMING", principal: "200", interest: "2", maturity: 1_000 },
    { id: "2", state: "FUNDING", principal: "900", interest: "9", maturity: 1_500 },
    { id: "4", state: "AWAITING_SETTLEMENT", principal: "50", interest: "1", maturity: 1_000 },
  ]);

  it("adds each lent loan's return at its end of term, in order, merging loans that end together", () => {
    const s = freeCashSchedule(acc);
    expect(s.free).toBe(100n);
    expect(s.steps).toEqual([
      { at: 1_000, amount: 253n, total: 353n },
      { at: 2_000, amount: 505n, total: 858n },
    ]);
  });

  it("names the first date by which the free cash covers a need", () => {
    const s = freeCashSchedule(acc);
    expect(moreBy(s, 50n)).toBeNull(); // already free
    expect(moreBy(s, 300n)?.at).toBe(1_000);
    expect(moreBy(s, 800n)?.at).toBe(2_000);
    expect(moreBy(s, 10_000n)).toBeNull(); // more than every loan returns
  });
});

describe("indexer routes", () => {
  it("are the partner API's, lowercase", () => {
    expect(accountingUrl("https://indexer.example/", "0xABC")).toBe("https://indexer.example/intent/partners/vaults/0xabc/accounting");
    expect(positionUrl("https://indexer.example", "0xABC", "0xDEF")).toBe(
      "https://indexer.example/intent/partners/vaults/0xabc/position/0xdef",
    );
  });
});

describe("poolIdOf", () => {
  it("matches v4's id of the testnet's hookless GLDx/USDG pool", () => {
    expect(
      poolIdOf({
        currency0: "0x2b4066a52F7A844d810f402c21B3543c62BcD18c",
        currency1: "0x445b73572C94287D0334375E4589A5d9EEd81b7f",
        fee: 3000,
        tickSpacing: 60,
        hooks: "0x0000000000000000000000000000000000000000",
      }),
    ).toBe("0x2c29c57d77507b18a9aa378cffb45ec35f53956601a6da6e591f61ac853d3b55");
  });
});
