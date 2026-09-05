import type { Address, PublicClient } from "viem";
import { sessionOn } from "../time/tradingTime.js";
import { FeedReader, encodeRoundId, isValid, type Round } from "../oracle/rounds.js";

/**
 * Trailing realised volatility from the vault's own Chainlink feed.
 *
 * Close-to-close on **session** closes, not UTC calendar days. The distinction is not pedantry: the
 * stock feeds are 24/5, so a calendar-day bucketing produces a Saturday and a Sunday bucket that repeat
 * Friday's round, two log returns of exactly zero enter the sample every week, and `sqrt(252)` on top of
 * that understates σ by about 17 %. Since the reserve floor sits close to the contract's own minimum,
 * a 17 % error is the difference between the model binding and the floor binding.
 *
 * So: one observation per NYSE session, being the last round at or before that session's close; log
 * returns between consecutive session closes (a Friday→Monday return is one observation, which is what
 * a 252-session year means); `σ_annual = stdev · sqrt(252)`, matching the variance clock in
 * time/tradingTime.ts exactly.
 *
 * Cost is not the problem the RPC budget suggests: SPEC §1.3 measures NVDA at ~15 rounds/day and SPY at
 * ~1.8, so a 30-day window is ~450 and ~55 rounds. A binary search for the window's first round plus a
 * few batched range reads is ~5 calls per vault, twice a week.
 */

export type VolSource = "realised" | "fallback";

export interface VolEstimate {
  /** Annualised, as a decimal (0.45 = 45 %). Always inside [volFloor, volCap]. */
  sigma: number;
  source: VolSource;
  /** Why the fallback was used, when it was. */
  reason: string | null;
  /** Session closes that produced a usable return. */
  samples: number;
  /** Before clamping, for the audit trail. */
  rawSigma: number | null;
  windowFrom: bigint;
  windowTo: bigint;
  roundsScanned: number;
  reads: number;
  /** The session closes actually used, oldest first — the audit artifact. */
  closes: { date: string; ts: string; answer: string }[];
}

export interface VolParams {
  windowDays: number;
  minSamples: number;
  floor: number; // decimal
  cap: number; // decimal
  fallback: number; // decimal
  maxRoundScan: number;
}

const CHUNK = 200;

/** Collects every round in `[from, to]`, cheaply: bisect for the start, then read the range in batches. */
export async function collectRounds(
  reader: FeedReader,
  from: bigint,
  to: bigint,
  maxScan: number,
): Promise<Round[]> {
  const latest = await reader.latest();
  if (!latest) return [];

  const phase = latest.phase;
  const first = await reader.get(encodeRoundId(phase, 1n));
  if (!first) return [];

  // Smallest agg in this phase with updatedAt >= from. Lower bound, so ties resolve to the earliest.
  let lo = 1n;
  let hi = latest.agg;
  if (first.updatedAt >= from) {
    hi = 1n;
  } else {
    while (lo < hi) {
      const mid = (lo + hi) / 2n;
      const r = await reader.get(encodeRoundId(phase, mid));
      if (r && r.updatedAt >= from) hi = mid;
      else lo = mid + 1n;
    }
    hi = lo;
  }

  const startAgg = hi;
  const count = Number(latest.agg - startAgg) + 1;
  if (count <= 0) return [];
  if (count > maxScan) {
    // Budget bound: take the most recent `maxScan` rounds and let the sample count speak for itself.
    return collectRange(reader, phase, latest.agg - BigInt(maxScan) + 1n, latest.agg, to);
  }
  return collectRange(reader, phase, startAgg, latest.agg, to);
}

async function collectRange(
  reader: FeedReader,
  phase: bigint,
  fromAgg: bigint,
  toAgg: bigint,
  maxTs: bigint,
): Promise<Round[]> {
  const out: Round[] = [];
  for (let a = fromAgg; a <= toAgg; a += BigInt(CHUNK)) {
    const ids: bigint[] = [];
    for (let k = a; k <= toAgg && k < a + BigInt(CHUNK); k++) ids.push(encodeRoundId(phase, k));
    const got = await reader.getMany(ids);
    for (const r of got) if (isValid(r) && r.updatedAt <= maxTs) out.push(r);
  }
  out.sort((x, y) =>
    x.updatedAt === y.updatedAt ? Number(x.agg - y.agg) : Number(x.updatedAt - y.updatedAt),
  );
  return out;
}

/** One observation per session: the last round at or before that session's close. */
export function sessionCloses(
  rounds: readonly Round[],
  from: bigint,
  to: bigint,
): { date: string; round: Round }[] {
  const out: { date: string; round: Round }[] = [];
  const DAY = 86_400n;
  for (let d = (from / DAY) * DAY; d <= to; d += DAY) {
    const session = sessionOn(d);
    if (!session) continue;
    if (session.close > to || session.close < from) continue;
    let best: Round | null = null;
    for (const r of rounds) {
      if (r.updatedAt > session.close) break;
      best = r;
    }
    // Only count a session whose close is backed by a round inside this session's own day; otherwise a
    // quiet stretch would repeat one price and inject zero returns, which is the bias we are avoiding.
    if (best && best.updatedAt >= session.open - 18n * 3600n)
      out.push({ date: session.date, round: best });
  }
  // Consecutive sessions must not share the same round, or the return is a spurious zero.
  return out.filter((x, i) => i === 0 || x.round.id !== out[i - 1]?.round.id);
}

export async function estimateVol(args: {
  client: PublicClient;
  feed: Address;
  now: bigint;
  params: VolParams;
}): Promise<VolEstimate> {
  const { client, feed, now, params } = args;
  const from = now - BigInt(Math.round(params.windowDays * 86_400));
  const reader = new FeedReader(client, feed, Math.max(params.maxRoundScan + 200, 500));

  const fallback = (reason: string, extra: Partial<VolEstimate> = {}): VolEstimate => ({
    sigma: clamp(params.fallback, params.floor, params.cap),
    source: "fallback",
    reason,
    samples: 0,
    rawSigma: null,
    windowFrom: from,
    windowTo: now,
    roundsScanned: 0,
    reads: reader.reads,
    closes: [],
    ...extra,
  });

  let rounds: Round[];
  try {
    rounds = await collectRounds(reader, from, now, params.maxRoundScan);
  } catch (err) {
    return fallback(`round scan failed: ${(err as Error).message}`);
  }

  const closes = sessionCloses(rounds, from, now);
  const audit = closes.map((c) => ({
    date: c.date,
    ts: c.round.updatedAt.toString(),
    answer: c.round.answer.toString(),
  }));

  if (closes.length - 1 < params.minSamples) {
    return fallback(
      `only ${Math.max(0, closes.length - 1)} session returns in the last ${params.windowDays}d, need ${params.minSamples}`,
      {
        samples: Math.max(0, closes.length - 1),
        roundsScanned: rounds.length,
        reads: reader.reads,
        closes: audit,
      },
    );
  }

  const returns: number[] = [];
  for (let i = 1; i < closes.length; i++) {
    const a = closes[i - 1]?.round.answer;
    const b = closes[i]?.round.answer;
    if (a === undefined || b === undefined || a <= 0n || b <= 0n) continue;
    returns.push(Math.log(Number(b) / Number(a)));
  }

  const rawSigma = stdev(returns) * Math.sqrt(252);

  if (!Number.isFinite(rawSigma) || rawSigma <= 0) {
    // The 46630 mock feed is exactly this case: 14 rounds all answering 200.00, so every log return is
    // zero. A count-only guard would hand Black-Scholes sigma = 0, which prices an OTM call at its
    // intrinsic value of zero and produces a reserve of zero on a parameter SPEC §8.3 exists to protect.
    return fallback("degenerate estimate (sigma = 0: the feed has not moved in the window)", {
      samples: returns.length,
      rawSigma,
      roundsScanned: rounds.length,
      reads: reader.reads,
      closes: audit,
    });
  }
  if (rawSigma < params.floor) {
    return fallback(
      `estimate ${(rawSigma * 100).toFixed(2)}% is below the ${(params.floor * 100).toFixed(2)}% floor`,
      {
        samples: returns.length,
        rawSigma,
        roundsScanned: rounds.length,
        reads: reader.reads,
        closes: audit,
      },
    );
  }

  return {
    sigma: clamp(rawSigma, params.floor, params.cap),
    source: "realised",
    reason: rawSigma > params.cap ? `clamped down from ${(rawSigma * 100).toFixed(2)}%` : null,
    samples: returns.length,
    rawSigma,
    windowFrom: from,
    windowTo: now,
    roundsScanned: rounds.length,
    reads: reader.reads,
    closes: audit,
  };
}

export function stdev(xs: readonly number[]): number {
  if (xs.length < 2) return 0;
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
  const variance = xs.reduce((a, b) => a + (b - mean) ** 2, 0) / (xs.length - 1);
  return Math.sqrt(variance);
}

export const clamp = (x: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, x));
