import type { Address, PublicClient } from "viem";
import { aggregatorAbi } from "../abi/index.js";
import { multicall } from "../chain/multicall.js";

/**
 * Chainlink round discovery, off-chain.
 *
 * D-057 item 9 removed `lastChainlink`, `isLastRoundAtOrBefore` and `isFirstRoundAfter` from
 * `SettlementOracle` to stay under the 24 576-byte limit, so there is no on-chain helper: the keeper
 * reads the aggregator proxy itself and has its answer verified by `previewSettle`.
 *
 * Two facts shape everything below.
 *
 *  - **Ids are `(phase << 64) | aggregatorRound`.** Aggregator rounds are contiguous from 1 inside a
 *    phase; phases are contiguous from 1. `getRoundData` *reverts* ("No data present") for anything
 *    else, which is why every probe goes through Multicall3 `aggregate3(allowFailure: true)` — a
 *    per-call failure is the "does not exist" predicate the search needs, and a plain batch would
 *    revert wholesale.
 *  - **`updatedAt` is non-decreasing, not increasing.** The 46630 NVDA feed has rounds 13 and 14 at the
 *    same second. So "last round at or before `expiry`" is a *rightmost* binary search. Handing the
 *    contract the left-hand twin gets `BadRefRoundHint`, because `_isLastValidAtOrBefore`
 *    (SettlementOracle.sol:616-629) sees a valid successor also at or before expiry.
 */

export const MAX_GARBAGE_SKIP = 32; // SettlementOracle.sol:64 (D-057 raised it from D-053's 8)
const MAX_PHASE_PROBE = 8; // SettlementOracle.sol, phase lookback bound
const AGG_MASK = (1n << 64n) - 1n;

export interface Round {
  id: bigint;
  phase: bigint;
  agg: bigint;
  answer: bigint;
  startedAt: bigint;
  updatedAt: bigint;
}

export const encodeRoundId = (phase: bigint, agg: bigint): bigint => (phase << 64n) | agg;
export const roundPhase = (id: bigint): bigint => id >> 64n;
export const roundAgg = (id: bigint): bigint => id & AGG_MASK;

/** A round the contract would accept as data: it exists and prices something. */
export const isValid = (r: Round | null): r is Round =>
  r !== null && r.answer > 0n && r.updatedAt > 0n;

export class ReadBudgetExceeded extends Error {
  constructor(limit: number) {
    super(`Chainlink round scan exceeded its budget of ${limit} reads`);
    this.name = "ReadBudgetExceeded";
  }
}

/**
 * Batching, caching reader for one aggregator proxy. One instance per (feed, keeper run) — the cache is
 * sound because a written round is immutable, and it is what keeps the twice-weekly vol walk cheap.
 */
export class FeedReader {
  private readonly cache = new Map<string, Round | null>();
  private budget: number;
  reads = 0;

  constructor(
    private readonly client: PublicClient,
    readonly feed: Address,
    maxReads = 20_000,
  ) {
    this.budget = maxReads;
  }

  private spend(n: number): void {
    this.reads += n;
    this.budget -= n;
    if (this.budget < 0) throw new ReadBudgetExceeded(this.reads);
  }

  async latest(): Promise<Round | null> {
    const raw = await this.client.readContract({
      address: this.feed,
      abi: aggregatorAbi,
      functionName: "latestRoundData",
    });
    this.spend(1);
    const round = toRound(raw);
    if (round) this.cache.set(round.id.toString(), round);
    return round;
  }

  async get(id: bigint): Promise<Round | null> {
    const [only] = await this.getMany([id]);
    return only ?? null;
  }

  /** Batched through Multicall3; missing ids come back as `null` rather than throwing. */
  async getMany(ids: readonly bigint[]): Promise<(Round | null)[]> {
    const wanted = ids.filter((id) => !this.cache.has(id.toString()));
    const unique = [...new Set(wanted.map((i) => i.toString()))].map(BigInt);

    if (unique.length > 0) {
      this.spend(unique.length);
      const results = await multicall<readonly [bigint, bigint, bigint, bigint, bigint]>(
        this.client,
        unique.map((id) => ({
          address: this.feed,
          abi: aggregatorAbi,
          functionName: "getRoundData",
          args: [id],
        })),
      );
      unique.forEach((id, i) => {
        const r = results[i];
        this.cache.set(id.toString(), r && r.ok ? toRound(r.value) : null);
      });
    }
    return ids.map((id) => this.cache.get(id.toString()) ?? null);
  }

  exists(id: bigint): boolean | undefined {
    const hit = this.cache.get(id.toString());
    return hit === undefined ? undefined : hit !== null;
  }

  /**
   * `_next` of SettlementOracle.sol:602-611 — `(p, a+1)` if it exists, else `(p+1, 1)`, else none.
   * Mirrored exactly so the keeper's idea of "the next round" is the contract's.
   */
  async next(id: bigint): Promise<Round | null> {
    const p = roundPhase(id);
    const a = roundAgg(id);
    if (a < AGG_MASK) {
      const sameP = await this.get(encodeRoundId(p, a + 1n));
      if (sameP) return sameP;
    }
    return this.get(encodeRoundId(p + 1n, 1n));
  }

  /** Highest aggregator round that exists in `phase`, or null if the phase is empty. */
  async lastAggOf(phase: bigint): Promise<Round | null> {
    if (!(await this.get(encodeRoundId(phase, 1n)))) return null;

    // Double until we miss, then bisect the gap. ~2·log2(n) reads.
    let lo = 1n;
    let hi = 2n;
    for (;;) {
      if (!(await this.get(encodeRoundId(phase, hi)))) break;
      lo = hi;
      hi *= 2n;
      if (hi > AGG_MASK) return this.get(encodeRoundId(phase, lo));
    }
    while (lo + 1n < hi) {
      const mid = (lo + hi) / 2n;
      if (await this.get(encodeRoundId(phase, mid))) lo = mid;
      else hi = mid;
    }
    return this.get(encodeRoundId(phase, lo));
  }

  /**
   * Rightmost round in `phase` with `updatedAt <= ts`, or null when even round 1 is after `ts`.
   * `hiAgg` bounds the search; pass the phase's last round when it is known.
   */
  async lastAtOrBeforeInPhase(phase: bigint, ts: bigint, hiAgg: bigint): Promise<Round | null> {
    const first = await this.get(encodeRoundId(phase, 1n));
    if (!first || first.updatedAt > ts) return null;

    let lo = 1n; // known: updatedAt <= ts
    let hi = hiAgg + 1n; // known (or assumed): updatedAt > ts
    while (lo + 1n < hi) {
      const mid = (lo + hi) / 2n;
      const r = await this.get(encodeRoundId(phase, mid));
      // A hole inside a phase should not happen; treat it as "past the end" so the search still ends.
      if (r && r.updatedAt <= ts) lo = mid;
      else hi = mid;
    }
    return this.get(encodeRoundId(phase, lo));
  }
}

function toRound(raw: readonly [bigint, bigint, bigint, bigint, bigint]): Round | null {
  const [id, answer, startedAt, updatedAt] = raw;
  if (updatedAt === 0n) return null; // Chainlink's own "no data" shape
  return { id, phase: roundPhase(id), agg: roundAgg(id), answer, startedAt, updatedAt };
}

/**
 * The last round positionally at or before `ts`, across phases. Not necessarily *valid* — callers that
 * need a priced round walk back from here with `lastValidAtOrBefore`.
 */
export async function lastAtOrBefore(reader: FeedReader, ts: bigint): Promise<Round | null> {
  const latest = await reader.latest();
  if (!latest) return null;
  if (latest.updatedAt <= ts) return latest;

  let phase = latest.phase;
  let hiAgg = latest.agg;
  for (let i = 0; i < MAX_PHASE_PROBE && phase >= 1n; i++) {
    const hit = await reader.lastAtOrBeforeInPhase(phase, ts, hiAgg);
    if (hit) return hit;
    phase -= 1n;
    if (phase < 1n) return null;
    const prevLast = await reader.lastAggOf(phase);
    if (!prevLast) return null;
    hiAgg = prevLast.agg;
  }
  return null;
}

/**
 * `refRoundId` — the last *valid* round at or before `ts`, matching `_isLastValidAtOrBefore`.
 *
 * Having found the rightmost round at or before `ts`, a run of zero-answer rounds is walked back
 * through; the contract tolerates at most `MAX_GARBAGE_SKIP` of them, so a longer run means no hint is
 * verifiable and the §9.6 backstop is the only way forward. That is reported as `null`, not guessed at.
 */
export async function lastValidAtOrBefore(reader: FeedReader, ts: bigint): Promise<Round | null> {
  const boundary = await lastAtOrBefore(reader, ts);
  if (!boundary) return null;
  if (boundary.answer > 0n) return boundary;

  // The garbage run is bounded at 32, so the whole window is one batch rather than 32 round-trips.
  if (boundary.agg > BigInt(MAX_GARBAGE_SKIP)) {
    const ids: bigint[] = [];
    for (let k = 1n; k <= BigInt(MAX_GARBAGE_SKIP); k++) {
      ids.push(encodeRoundId(boundary.phase, boundary.agg - k));
    }
    const window = await reader.getMany(ids);
    for (const r of window) if (isValid(r)) return r;
    return null;
  }

  // Near the start of a phase the window straddles a boundary; walk it.
  let r: Round | null = boundary;
  for (let skipped = 0; r !== null; skipped++) {
    if (r.answer > 0n) return r;
    if (skipped >= MAX_GARBAGE_SKIP) return null;
    r = await previous(reader, r);
  }
  return null;
}

/** Inverse of `next`: `(p, a-1)`, or the last round of `p-1` when `a == 1`. */
export async function previous(reader: FeedReader, r: Round): Promise<Round | null> {
  if (r.agg > 1n) return reader.get(encodeRoundId(r.phase, r.agg - 1n));
  if (r.phase <= 1n) return null;
  return reader.lastAggOf(r.phase - 1n);
}

/**
 * `afterRoundId` — the first round *positionally* after `ts`, whatever its answer.
 *
 * The contract checks position and then skips garbage itself (`_isFirstAfter`,
 * SettlementOracle.sol:633-650), and `test_resolveHaltedByOracle_*` proves a hint that pre-skips a
 * zero-answer round is rejected. So this deliberately does not filter on `answer`.
 */
export async function firstAfter(reader: FeedReader, ts: bigint): Promise<Round | null> {
  const latest = await reader.latest();
  if (!latest) return null;
  if (latest.updatedAt <= ts) return null; // nothing after ts yet

  const before = await lastAtOrBefore(reader, ts);
  if (!before) {
    // Every round the feed has is after ts: the answer is its very first round.
    let phase = latest.phase;
    while (phase > 1n && (await reader.get(encodeRoundId(phase - 1n, 1n)))) phase -= 1n;
    return reader.get(encodeRoundId(phase, 1n));
  }
  return reader.next(before.id);
}

/**
 * `afterPrevRoundId` — required only when `afterRoundId` is aggregator round 1 of a new phase, where
 * the contract cannot find the predecessor itself. It must be the *adjacent* predecessor: the last
 * round of the previous phase, verified on-chain with `_next(prevHint).id == afterRoundId`.
 */
export async function prevHintFor(reader: FeedReader, after: Round | null): Promise<bigint> {
  if (!after || after.agg !== 1n || after.phase <= 1n) return 0n;
  const prev = await reader.lastAggOf(after.phase - 1n);
  return prev ? prev.id : 0n;
}
