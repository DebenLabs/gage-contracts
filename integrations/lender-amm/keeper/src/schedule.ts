/**
 * The free-cash schedule of a gage vault, from gage's indexer (`GET /intent/partners/vaults/:address/accounting`,
 * docs/api.md): what is free now and how much more each open loan returns, by its end of term. A loan's cash comes
 * back when it repays, at the latest at the end of its term, and is free once the loan is settled; a default returns
 * collateral instead, so the schedule is what the vault is owed, not a promise.
 */

export interface AccountingLoan {
  id: string;
  state: string;
  principal: string;
  interest: string;
  /** End of the term, unix seconds. */
  maturity: number;
}

export interface Accounting {
  liquidity: { free: string };
  settlement: { earliestMaturity: number | null; due: boolean; settleable: string[] };
  loans: AccountingLoan[];
}

export interface Position {
  withdrawableNow: string;
  pockets: { id: number; claimable: string }[];
}

export interface Step {
  /** Unix seconds: the loan's end of term. */
  at: number;
  /** What the loan returns: its principal and its interest after the manager fee (its execution fee was paid when the
   * vault bought it). An early repayment sets part of the return aside as an earnings pocket (D51). */
  amount: bigint;
  /** Free cash once this and every earlier loan has returned. */
  total: bigint;
}

export interface Schedule {
  free: bigint;
  steps: Step[];
}

/** Loans whose principal is out: performing, or past their end and awaiting settlement. */
const OUT = new Set(["PERFORMING", "AWAITING_SETTLEMENT", "REPAID_RUNNING", "AWAITING_RELEASE"]);

export function freeCashSchedule(acc: Accounting): Schedule {
  const free = BigInt(acc.liquidity.free);
  const loans = acc.loans
    .filter((l) => OUT.has(l.state))
    .map((l) => ({ at: l.maturity, amount: BigInt(l.principal) + BigInt(l.interest) }))
    .sort((a, b) => a.at - b.at);
  let total = free;
  const steps: Step[] = [];
  for (const l of loans) {
    total += l.amount;
    const last = steps[steps.length - 1];
    if (last !== undefined && last.at === l.at) {
      last.amount += l.amount;
      last.total = total;
    } else steps.push({ at: l.at, amount: l.amount, total });
  }
  return { free, steps };
}

/** The first end of term by which the vault's free cash reaches `need`, or null when even every loan is not enough. */
export function moreBy(schedule: Schedule, need: bigint): Step | null {
  if (schedule.free >= need) return null;
  return schedule.steps.find((s) => s.total >= need) ?? null;
}

export async function fetchJson<T>(url: string, timeoutMs = 10_000): Promise<T> {
  const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), headers: { accept: "application/json" } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

export function accountingUrl(indexer: string, vault: string): string {
  return `${indexer.replace(/\/$/, "")}/intent/partners/vaults/${vault.toLowerCase()}/accounting`;
}

export function positionUrl(indexer: string, vault: string, account: string): string {
  return `${indexer.replace(/\/$/, "")}/intent/partners/vaults/${vault.toLowerCase()}/position/${account.toLowerCase()}`;
}
