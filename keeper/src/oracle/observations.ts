import type { Address, PublicClient } from "viem";
import { poolAbi } from "../abi/index.js";
import { multicall } from "../chain/multicall.js";

/**
 * Uniswap v3 observation-ring reads.
 *
 * SPEC §16.2: "the keeper reads `slot0.observationCardinality` and the oldest `pool.observations(i)`
 * directly (no oracle helper, v0.5)". Two jobs here:
 *
 *  - `obsIndex` for the settlement hint — the newest initialised observation at or before expiry. Purely
 *    advisory (D-053): a stale index under-counts the window and fails the TWAP path, it can never make
 *    a failing window pass, which is why `test_path2_observationHintCannotHelp` exists.
 *  - coverage monitoring — SPEC §9.5 asks the keeper to check hourly that the ring still spans
 *    `window + twapGrace`, and to alert when it does not.
 */

export interface Slot0 {
  sqrtPriceX96: bigint;
  tick: number;
  observationIndex: number;
  observationCardinality: number;
  observationCardinalityNext: number;
  unlocked: boolean;
}

export interface Observation {
  index: number;
  blockTimestamp: number;
  tickCumulative: bigint;
  secondsPerLiquidityCumulativeX128: bigint;
  initialized: boolean;
}

export async function readSlot0(client: PublicClient, pool: Address): Promise<Slot0> {
  const r = await client.readContract({ address: pool, abi: poolAbi, functionName: "slot0" });
  return {
    sqrtPriceX96: r[0],
    tick: r[1],
    observationIndex: r[2],
    observationCardinality: r[3],
    observationCardinalityNext: r[4],
    unlocked: r[6],
  };
}

export async function readObservations(
  client: PublicClient,
  pool: Address,
  indices: readonly number[],
): Promise<(Observation | null)[]> {
  if (indices.length === 0) return [];
  const results = await multicall<readonly [number, bigint, bigint, boolean]>(
    client,
    indices.map((i) => ({
      address: pool,
      abi: poolAbi,
      functionName: "observations",
      args: [BigInt(i)],
    })),
  );
  return indices.map((index, k) => {
    const r = results[k];
    if (!r || !r.ok) return null;
    const [blockTimestamp, tickCumulative, secondsPerLiquidityCumulativeX128, initialized] =
      r.value;
    return {
      index,
      blockTimestamp,
      tickCumulative,
      secondsPerLiquidityCumulativeX128,
      initialized,
    };
  });
}

/** Index `i` stepped back `n` places around a ring of `cardinality`. */
const back = (i: number, n: number, cardinality: number): number =>
  (((i - n) % cardinality) + cardinality) % cardinality;

const CHUNK = 32;

/**
 * The newest initialised observation with `blockTimestamp <= anchor`, walking backwards from
 * `slot0.observationIndex` and wrapping — the port of `SettlementHandler._obsAtOrBefore`
 * (test/invariants/SettlementHandler.sol:568-577), batched so a 1 000-slot ring costs ~32 calls, not 1 000.
 *
 * Returns index 0 when the whole ring is newer than the anchor, which is what the Solidity does; the
 * contract then simply fails the path.
 */
export async function observationIndexAtOrBefore(
  client: PublicClient,
  pool: Address,
  anchor: bigint,
  slot0?: Slot0,
): Promise<{ index: number; observation: Observation | null; scanned: number }> {
  const s = slot0 ?? (await readSlot0(client, pool));
  const card = s.observationCardinality;
  if (card === 0) return { index: 0, observation: null, scanned: 0 };

  const target = Number(anchor);
  let scanned = 0;
  for (let offset = 0; offset < card; offset += CHUNK) {
    const size = Math.min(CHUNK, card - offset);
    const indices = Array.from({ length: size }, (_, k) =>
      back(s.observationIndex, offset + k, card),
    );
    const obs = await readObservations(client, pool, indices);
    scanned += size;
    for (const o of obs) {
      if (o && o.initialized && o.blockTimestamp <= target) {
        return { index: o.index, observation: o, scanned };
      }
    }
  }
  return { index: 0, observation: null, scanned };
}

export interface CoverageReport {
  cardinality: number;
  cardinalityNext: number;
  /** Timestamp of the oldest initialised observation, or null when the ring is empty. */
  oldest: number | null;
  /** Timestamp of the newest observation at or before `now`. */
  newest: number | null;
  /** How many seconds of history the ring currently spans. */
  spanSeconds: number;
  /** Observations inside `[now - window, now]`. */
  inWindow: number;
  /** Age of the newest observation, in seconds. */
  newestAgeSeconds: number;
}

/**
 * Ring health for the `pool.coverage` monitor check. `oldest` is the slot just after the write index,
 * which is the ring's tail once it has wrapped; before it wraps, index 0 is the tail.
 */
export async function coverage(
  client: PublicClient,
  pool: Address,
  now: bigint,
  window: number,
): Promise<CoverageReport> {
  const s = await readSlot0(client, pool);
  const card = s.observationCardinality;
  const tailCandidates = card > 0 ? [(s.observationIndex + 1) % card, 0] : [];
  const tail = await readObservations(client, pool, tailCandidates);
  const initialisedTails = tail.filter((o): o is Observation => o !== null && o.initialized);
  const oldest = initialisedTails.length
    ? Math.min(...initialisedTails.map((o) => o.blockTimestamp))
    : null;

  // Count what falls inside the window by walking back from the head until we leave it.
  const nowSec = Number(now);
  let inWindow = 0;
  let newest: number | null = null;
  outer: for (let offset = 0; offset < card; offset += CHUNK) {
    const size = Math.min(CHUNK, card - offset);
    const indices = Array.from({ length: size }, (_, k) =>
      back(s.observationIndex, offset + k, card),
    );
    const obs = await readObservations(client, pool, indices);
    for (const o of obs) {
      if (!o || !o.initialized) continue;
      if (o.blockTimestamp > nowSec) continue;
      if (newest === null) newest = o.blockTimestamp;
      if (o.blockTimestamp < nowSec - window) break outer;
      inWindow++;
    }
  }

  return {
    cardinality: card,
    cardinalityNext: s.observationCardinalityNext,
    oldest,
    newest,
    spanSeconds: oldest !== null && newest !== null ? newest - oldest : 0,
    inWindow,
    newestAgeSeconds: newest === null ? Number.MAX_SAFE_INTEGER : nowSec - newest,
  };
}
