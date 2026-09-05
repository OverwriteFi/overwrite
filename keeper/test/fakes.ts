import type { PublicClient } from "viem";

/**
 * An in-memory Chainlink proxy and Uniswap v3 observation ring, with the same failure shapes the real
 * ones have: `getRoundData` *reverts* for an id that was never written, ids are `(phase << 64) | agg`,
 * and `updatedAt` may repeat. Those three facts are what the hint builder has to survive, so a fake
 * that returned `undefined` instead of throwing would test nothing.
 */

export interface FakeRound {
  phase: bigint;
  agg: bigint;
  answer: bigint;
  updatedAt: bigint;
}

export class FakeFeed {
  private readonly rounds = new Map<string, FakeRound>();
  private latestId = 0n;

  static id(phase: bigint, agg: bigint): bigint {
    return (phase << 64n) | agg;
  }

  set(phase: bigint, agg: bigint, answer: bigint, updatedAt: bigint): bigint {
    const id = FakeFeed.id(phase, agg);
    this.rounds.set(id.toString(), { phase, agg, answer, updatedAt });
    if (id > this.latestId) this.latestId = id;
    return id;
  }

  /** `n` rounds every `period` seconds from `start`, in phase `phase`, at a constant answer. */
  fill(
    phase: bigint,
    from: bigint,
    count: number,
    period: bigint,
    answer: bigint,
    startAgg = 1n,
  ): void {
    for (let i = 0; i < count; i++) {
      this.set(phase, startAgg + BigInt(i), answer, from + BigInt(i) * period);
    }
  }

  get(id: bigint): FakeRound | undefined {
    return this.rounds.get(id.toString());
  }

  get latest(): FakeRound | undefined {
    return this.rounds.get(this.latestId.toString());
  }

  tuple(r: FakeRound): readonly [bigint, bigint, bigint, bigint, bigint] {
    const id = FakeFeed.id(r.phase, r.agg);
    return [id, r.answer, r.updatedAt, r.updatedAt, id];
  }
}

export interface FakeObservation {
  blockTimestamp: number;
  initialized: boolean;
}

export class FakePool {
  readonly ring: FakeObservation[];
  index = 0;

  constructor(readonly cardinality: number) {
    this.ring = Array.from({ length: cardinality }, () => ({
      blockTimestamp: 0,
      initialized: false,
    }));
  }

  write(ts: number): void {
    this.index = (this.index + 1) % this.cardinality;
    const slot = this.ring[this.index];
    if (slot) {
      slot.blockTimestamp = ts;
      slot.initialized = true;
    }
  }

  /** Seeds the ring so slot 0 is the oldest and `index` the newest, without wrapping. */
  seed(timestamps: readonly number[]): void {
    timestamps.forEach((ts, i) => {
      const slot = this.ring[i];
      if (slot) {
        slot.blockTimestamp = ts;
        slot.initialized = true;
      }
    });
    this.index = Math.max(0, timestamps.length - 1);
  }
}

class Reverted extends Error {}

/** A `PublicClient` shim covering exactly the reads the oracle modules make. */
export function fakeClient(
  feed: FakeFeed,
  pool: FakePool,
  feedAddress: string,
  poolAddress: string,
): PublicClient {
  const call = (address: string, functionName: string, args: readonly unknown[] = []): unknown => {
    if (address.toLowerCase() === feedAddress.toLowerCase()) {
      if (functionName === "latestRoundData") {
        const l = feed.latest;
        if (!l) throw new Reverted("No data present");
        return feed.tuple(l);
      }
      if (functionName === "getRoundData") {
        const r = feed.get(args[0] as bigint);
        if (!r) throw new Reverted("No data present");
        return feed.tuple(r);
      }
      if (functionName === "decimals") return 8;
    }
    if (address.toLowerCase() === poolAddress.toLowerCase()) {
      if (functionName === "slot0") {
        return [0n, 223338, pool.index, pool.cardinality, pool.cardinality, 0, true] as const;
      }
      if (functionName === "observations") {
        const o = pool.ring[Number(args[0])];
        if (!o) throw new Reverted("out of range");
        return [o.blockTimestamp, 0n, 0n, o.initialized] as const;
      }
    }
    throw new Reverted(`unexpected call ${functionName} at ${address}`);
  };

  /* eslint-disable @typescript-eslint/require-await -- the shim must be async to match viem's shape */
  return {
    readContract: async ({ address, functionName, args }: never) =>
      call(address, functionName, args ?? []),
    multicall: async ({ contracts }: never) =>
      (contracts as { address: string; functionName: string; args?: readonly unknown[] }[]).map(
        (c) => {
          try {
            return {
              status: "success" as const,
              result: call(c.address, c.functionName, c.args ?? []),
            };
          } catch (error) {
            return { status: "failure" as const, error };
          }
        },
      ),
  } as unknown as PublicClient;
}

export const FEED = "0x2d4e84FBaE927EcF2CCc924808E593BA48F1b72F";
export const POOL = "0x8e1CFC19D17EC56CB6C6b545596637F60376B3c9";
