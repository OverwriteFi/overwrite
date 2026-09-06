import type { Address, PublicClient } from "viem";
import { aggregatorAbi, mockAggregatorAbi, mockPoolAbi, poolAbi } from "../abi/index.js";
import type { Sender } from "../chain/tx.js";
import type { Deployment } from "../deployment.js";
import type { Logger } from "../logger.js";
import type { ActionRecord } from "../scheduler.js";
import type { StateDir } from "../state.js";

/**
 * Testnet upkeep: keeps the 46630 mocks alive so the public demo runs unattended.
 *
 * On 46630 every external is a mock (SPEC §1.8, D-014): nobody publishes Chainlink rounds there and
 * nobody swaps in the pools. Left alone, the stock feeds go past `weekdayMaxStale` (26 h) within a
 * day, `referencePrice` reverts `NoReferencePrice` at the next Monday open, and the weekend TWAP fails
 * the §9.3 minimum-observations rule for want of a single swap. So on this chain, and only on this
 * chain, the keeper also plays the market:
 *
 *  - a stock-feed round every `feedIntervalSeconds` (4 h, matching `MockDeployLib.FEED_PERIOD`), on a
 *    small random walk around the last answer, held inside a band around an anchor so the walk can
 *    never drift toward the 30 % jump guard or the 15 % weekend TWAP bound;
 *  - a USDG/USD round on the same cadence, at par with a few bps of jitter, well inside the ±2 % band;
 *  - a pool observation every `poolIntervalSeconds` (10 min) at the tick that prices the stock at the
 *    feed's latest answer, so a Sunday 23:59 window always holds ≥ 3 observations, the newest within
 *    900 s, and the TWAP agrees with Friday's Chainlink round.
 *
 * Everything is derived from chain state each tick — "is the newest round older than the interval" —
 * so a restart costs nothing and two ticks never double-post. The one thing kept on disk is the anchor
 * price per feed, because the walk needs a centre that does not itself walk.
 *
 * Refuses to construct on any chain but 46630, and the allowlist in chain/tx.ts only admits the mock
 * functions under the same condition, so this file cannot be turned on against mainnet by config alone.
 */

export interface UpkeepConfig {
  enabled: boolean;
  feedIntervalSeconds: number;
  usdgIntervalSeconds: number;
  poolIntervalSeconds: number;
  /** σ of one step of the walk, in bps of the last price. */
  walkStepBps: number;
  /** Half-width of the band around the anchor the walk is clamped into, in bps. */
  walkBandBps: number;
  /** Half-width of the USDG/USD jitter around 1.00, in bps. */
  usdgJitterBps: number;
}

export const TESTNET_CHAIN_ID = 46630;
const ONE_USD_8 = 100_000_000n;
const PHASE_MASK = (1n << 64n) - 1n;

/* ───────────────────────────── pure helpers (unit-tested) ───────────────────────────── */

/** `price8 → tick` for the production 18-dec stock / 6-dec USDG pair, inverse of `OracleMath.quotePrice8`. */
export function tickForPrice8(price8: bigint, stockIsToken0: boolean): number {
  const ratio = Number(price8) / 1e20; // 1.0001^tick when the stock is token0, its inverse otherwise
  const t = Math.log(ratio) / Math.log(1.0001);
  return Math.round(stockIsToken0 ? t : -t);
}

/** `tick → price8`, for the tests and for logging what a written observation means. */
export function price8ForTick(tick: number, stockIsToken0: boolean): bigint {
  const ratio = 1.0001 ** (stockIsToken0 ? tick : -tick);
  return BigInt(Math.round(ratio * 1e20));
}

/**
 * One step of a geometric random walk around `anchor8`: `last × exp(σ·z)` with `z ~ N(0,1)` from a
 * Box-Muller draw, clamped into `anchor × (1 ± band)`. `rand` is injectable so the tests are exact.
 */
export function nextPrice8(
  last8: bigint,
  anchor8: bigint,
  stepBps: number,
  bandBps: number,
  rand: () => number = Math.random,
): bigint {
  const u1 = Math.max(rand(), 1e-12);
  const u2 = rand();
  const z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
  const sigma = stepBps / 10_000;
  let next = Number(last8) * Math.exp(sigma * z);
  const lo = Number(anchor8) * (1 - bandBps / 10_000);
  const hi = Number(anchor8) * (1 + bandBps / 10_000);
  next = Math.min(hi, Math.max(lo, next));
  return BigInt(Math.round(next));
}

/** USDG/USD at par with `±jitterBps` of uniform noise. */
export function nextUsdg8(jitterBps: number, rand: () => number = Math.random): bigint {
  const bps = (rand() * 2 - 1) * jitterBps;
  return ONE_USD_8 + BigInt(Math.round((Number(ONE_USD_8) * bps) / 10_000));
}

/** The round id that follows `latestId` in the same phase; rounds must stay contiguous (see test/week/anvil.ts). */
export function nextRoundId(latestId: bigint): bigint {
  const phase = latestId >> 64n;
  const agg = latestId & PHASE_MASK;
  return (phase << 64n) | (agg + 1n);
}

export const isDue = (lastAt: bigint, intervalSeconds: number, now: bigint): boolean =>
  now - lastAt >= BigInt(intervalSeconds);

/* ───────────────────────────── the job ───────────────────────────── */

interface FeedTarget {
  label: string;
  feed: Address;
  pool?: Address;
  stock?: Address;
}

export class TestnetUpkeep {
  private readonly targets: FeedTarget[];
  private readonly orientation = new Map<string, boolean>(); // pool → stockIsToken0

  constructor(
    private readonly deployment: Deployment,
    private readonly cfg: UpkeepConfig,
    private readonly client: PublicClient,
    private readonly sender: Sender,
    private readonly state: StateDir,
    private readonly log: Logger,
  ) {
    if (deployment.chainId !== TESTNET_CHAIN_ID) {
      throw new Error(
        `testnet upkeep is only for chain ${TESTNET_CHAIN_ID}; refusing on ${deployment.chainId}`,
      );
    }
    if (deployment.mocked.length === 0) {
      throw new Error(
        "testnet upkeep enabled but the address book lists no mocks; nothing to keep alive",
      );
    }
    this.targets = deployment.vaults.map((v) => ({
      label: v.symbol,
      feed: v.feed,
      pool: v.pool,
      stock: v.stock,
    }));
  }

  describe(): string {
    return (
      `feeds every ${this.cfg.feedIntervalSeconds}s (walk σ ${this.cfg.walkStepBps} bps, band ±${this.cfg.walkBandBps} bps), ` +
      `USDG/USD every ${this.cfg.usdgIntervalSeconds}s (±${this.cfg.usdgJitterBps} bps), ` +
      `pool observation every ${this.cfg.poolIntervalSeconds}s`
    );
  }

  /** Runs whatever is due at chain time `now`. Never throws: a failed upkeep is a warning, not a dead tick. */
  async tick(now: bigint): Promise<ActionRecord[]> {
    const out: ActionRecord[] = [];
    for (const t of this.targets) {
      try {
        out.push(...(await this.stockFeed(t, now)));
        if (t.pool && t.stock) out.push(...(await this.pool(t, now)));
      } catch (err) {
        this.log.warn({ vault: t.label, err: (err as Error).message }, "testnet upkeep failed");
      }
    }
    try {
      out.push(...(await this.usdgFeed(now)));
    } catch (err) {
      this.log.warn({ err: (err as Error).message }, "testnet upkeep (USDG/USD) failed");
    }
    return out;
  }

  private async latest(feed: Address): Promise<{ id: bigint; answer: bigint; updatedAt: bigint }> {
    const [round, latestId] = await Promise.all([
      this.client.readContract({
        address: feed,
        abi: aggregatorAbi,
        functionName: "latestRoundData",
      }),
      this.client.readContract({ address: feed, abi: mockAggregatorAbi, functionName: "latestId" }),
    ]);
    return { id: latestId, answer: round[1], updatedAt: round[3] };
  }

  private async stockFeed(t: FeedTarget, now: bigint): Promise<ActionRecord[]> {
    const last = await this.latest(t.feed);
    if (!isDue(last.updatedAt, this.cfg.feedIntervalSeconds, now)) return [];

    const marker = `upkeep-anchor-${t.label}.json`;
    let anchor = this.state.readJson<{ anchor8: string }>(marker);
    if (!anchor) {
      anchor = { anchor8: last.answer.toString() };
      this.state.writeJson(marker, anchor);
    }
    const answer = nextPrice8(
      last.answer,
      BigInt(anchor.anchor8),
      this.cfg.walkStepBps,
      this.cfg.walkBandBps,
    );
    const id = nextRoundId(last.id);
    const r = await this.sender.send({
      address: t.feed,
      abi: mockAggregatorAbi,
      functionName: "setRound",
      args: [id, answer, now],
      label: `upkeep ${t.label} feed round ${id & PHASE_MASK} @ ${fmt8(answer)}`,
    });
    return [
      {
        at: now.toString(),
        vault: t.label,
        action: "upkeep:feedRound",
        outcome: r.status === "failed" ? `failed: ${r.error.text}` : r.status,
        detail: `${fmt8(last.answer)} → ${fmt8(answer)} (round ${id & PHASE_MASK})`,
      },
    ];
  }

  private async usdgFeed(now: bigint): Promise<ActionRecord[]> {
    const feed = this.deployment.external.usdgUsdFeed;
    const last = await this.latest(feed);
    if (!isDue(last.updatedAt, this.cfg.usdgIntervalSeconds, now)) return [];
    const answer = nextUsdg8(this.cfg.usdgJitterBps);
    const id = nextRoundId(last.id);
    const r = await this.sender.send({
      address: feed,
      abi: mockAggregatorAbi,
      functionName: "setRound",
      args: [id, answer, now],
      label: `upkeep USDG/USD round ${id & PHASE_MASK} @ ${fmt8(answer)}`,
    });
    return [
      {
        at: now.toString(),
        vault: "USDG",
        action: "upkeep:usdgRound",
        outcome: r.status === "failed" ? `failed: ${r.error.text}` : r.status,
        detail: `${fmt8(answer)} (round ${id & PHASE_MASK})`,
      },
    ];
  }

  private async stockIsToken0(pool: Address, stock: Address): Promise<boolean> {
    const cached = this.orientation.get(pool);
    if (cached !== undefined) return cached;
    const token0 = await this.client.readContract({
      address: pool,
      abi: poolAbi,
      functionName: "token0",
    });
    const is0 = token0.toLowerCase() === stock.toLowerCase();
    this.orientation.set(pool, is0);
    return is0;
  }

  private async pool(t: FeedTarget, now: bigint): Promise<ActionRecord[]> {
    const pool = t.pool as Address;
    const slot0 = await this.client.readContract({
      address: pool,
      abi: poolAbi,
      functionName: "slot0",
    });
    const newest = await this.client.readContract({
      address: pool,
      abi: poolAbi,
      functionName: "observations",
      args: [BigInt(slot0[2])],
    });
    if (!isDue(BigInt(newest[0]), this.cfg.poolIntervalSeconds, now)) return [];

    const [liquidity, feed, is0] = await Promise.all([
      this.client.readContract({ address: pool, abi: poolAbi, functionName: "liquidity" }),
      this.latest(t.feed),
      this.stockIsToken0(pool, t.stock as Address),
    ]);
    const tick = tickForPrice8(feed.answer, is0);
    const r = await this.sender.send({
      address: pool,
      abi: mockPoolAbi,
      functionName: "write",
      args: [Number(now), tick, liquidity],
      label: `upkeep ${t.label} pool observation tick ${tick}`,
    });
    return [
      {
        at: now.toString(),
        vault: t.label,
        action: "upkeep:poolObservation",
        outcome: r.status === "failed" ? `failed: ${r.error.text}` : r.status,
        detail: `tick ${tick} (≈ ${fmt8(price8ForTick(tick, is0))}), liquidity ${liquidity}`,
      },
    ];
  }
}

const fmt8 = (x: bigint): string => (Number(x) / 1e8).toFixed(2);
