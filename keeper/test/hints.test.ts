import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildHint } from "../src/oracle/hints.js";
import {
  FeedReader,
  encodeRoundId,
  firstAfter,
  lastAtOrBefore,
  lastValidAtOrBefore,
  prevHintFor,
} from "../src/oracle/rounds.js";
import { FEED, POOL, FakeFeed, FakePool, fakeClient } from "./fakes.js";

/**
 * The hint builder against `SettlementHandler._hint`
 * (contracts/test/invariants/SettlementHandler.sol:549-577), which is the repo's own statement of what
 * an honest keeper computes. Every case below is a shape the contract's verifier actually distinguishes.
 */

const T0 = 1_788_380_418n;
const H4 = 14_400n;

function setup(build: (f: FakeFeed, p: FakePool) => void) {
  const feed = new FakeFeed();
  const pool = new FakePool(64);
  build(feed, pool);
  return { feed, pool, client: fakeClient(feed, pool, FEED, POOL) };
}

describe("round discovery", () => {
  it("picks the RIGHTMOST round when two share a timestamp", async () => {
    // The deployed 46630 NVDA feed is exactly this: rounds 13 and 14 both at 1788553218.
    // `_isLastValidAtOrBefore` (SettlementOracle.sol:616-629) rejects 13 because its successor 14 is
    // also valid and also at or before expiry, so a leftmost search produces BadRefRoundHint.
    const { feed, client } = setup((f) => {
      f.fill(1n, T0, 13, H4, 200_00000000n);
      f.set(1n, 14n, 200_00000000n, T0 + 12n * H4); // duplicate of round 13's timestamp
    });
    const reader = new FeedReader(client, FEED);
    const tie = T0 + 12n * H4;

    const hit = await lastAtOrBefore(reader, tie);
    assert.equal(hit?.agg, 14n, "must pick the later of two rounds sharing a timestamp");
    assert.equal((await lastValidAtOrBefore(reader, tie))?.agg, 14n);
    assert.equal(
      feed.get(encodeRoundId(1n, 13n))?.updatedAt,
      tie,
      "fixture really does have a tie",
    );
  });

  it("finds the boundary between two rounds, and nothing before the feed started", async () => {
    const { client } = setup((f) => f.fill(1n, T0, 14, H4, 200_00000000n));
    const reader = new FeedReader(client, FEED);

    assert.equal((await lastAtOrBefore(reader, T0 + 4n * H4 + 1n))?.agg, 5n);
    assert.equal(
      (await lastAtOrBefore(reader, T0 + 4n * H4))?.agg,
      5n,
      "at-or-before is inclusive",
    );
    assert.equal(await lastAtOrBefore(reader, T0 - 1n), null);
  });

  it("skips a run of zero-answer rounds, and gives up past the contract's 32-round bound", async () => {
    const short = setup((f) => {
      f.fill(1n, T0, 10, H4, 200_00000000n);
      for (let i = 0; i < 5; i++) f.set(1n, 11n + BigInt(i), 0n, T0 + (10n + BigInt(i)) * H4);
    });
    const reader = new FeedReader(short.client, FEED);
    const ref = await lastValidAtOrBefore(reader, T0 + 20n * H4);
    assert.equal(ref?.agg, 10n, "walks back over the garbage to the last priced round");

    const long = setup((f) => {
      f.fill(1n, T0, 5, H4, 200_00000000n);
      for (let i = 0; i < 40; i++) f.set(1n, 6n + BigInt(i), 0n, T0 + (5n + BigInt(i)) * H4);
    });
    const reader2 = new FeedReader(long.client, FEED);
    assert.equal(
      await lastValidAtOrBefore(reader2, T0 + 60n * H4),
      null,
      "a garbage run longer than MAX_GARBAGE_SKIP leaves no verifiable hint at all",
    );
  });

  it("treats afterRoundId as a position claim, garbage included", async () => {
    // test_resolveHaltedByOracle_* proves a hint that pre-skips a zero-answer round is rejected: the
    // contract checks position first and skips garbage itself.
    const { client } = setup((f) => {
      f.fill(1n, T0, 5, H4, 200_00000000n);
      f.set(1n, 6n, 0n, T0 + 5n * H4); // garbage, first after expiry
      f.set(1n, 7n, 210_00000000n, T0 + 6n * H4);
    });
    const reader = new FeedReader(client, FEED);
    const after = await firstAfter(reader, T0 + 4n * H4);
    assert.equal(after?.agg, 6n, "must point at the garbage round, not skip past it");
  });

  it("supplies afterPrevRoundId only at a phase boundary", async () => {
    const { client } = setup((f) => {
      f.fill(1n, T0, 5, H4, 200_00000000n);
      f.set(2n, 1n, 210_00000000n, T0 + 6n * H4); // new phase, aggregator round 1
    });
    const reader = new FeedReader(client, FEED);

    const atBoundary = await firstAfter(reader, T0 + 5n * H4);
    assert.equal(atBoundary?.phase, 2n);
    assert.equal(atBoundary?.agg, 1n);
    assert.equal(
      await prevHintFor(reader, atBoundary),
      encodeRoundId(1n, 5n),
      "the contract needs the previous phase's LAST round, verified with _next(prev) == after",
    );

    const midPhase = await firstAfter(reader, T0 + 2n * H4);
    assert.equal(await prevHintFor(reader, midPhase), 0n, "not needed when agg > 1");
  });

  it("walks back into an earlier phase", async () => {
    const { client } = setup((f) => {
      f.fill(1n, T0, 6, H4, 200_00000000n);
      f.fill(2n, T0 + 20n * H4, 4, H4, 210_00000000n);
    });
    const reader = new FeedReader(client, FEED);
    const hit = await lastAtOrBefore(reader, T0 + 10n * H4);
    assert.equal(hit?.phase, 1n);
    assert.equal(hit?.agg, 6n, "the last round of the previous phase");
  });
});

describe("buildHint", () => {
  it("assembles the four fields and reports an unverifiable feed rather than guessing", async () => {
    const expiry = T0 + 8n * H4;
    const { client } = setup((f, p) => {
      f.fill(1n, T0, 14, H4, 200_00000000n);
      p.seed([
        Number(expiry) - 3600,
        Number(expiry) - 2400,
        Number(expiry) - 1200,
        Number(expiry) - 600,
        Number(expiry) - 120,
        Number(expiry) + 500, // after the anchor: must not be chosen
      ]);
    });

    const built = await buildHint({
      client,
      feed: FEED,
      pool: POOL,
      expiry,
      firstRound: encodeRoundId(1n, 1n),
    });

    assert.equal(built.hint.refRoundId, encodeRoundId(1n, 9n));
    assert.equal(built.hint.afterRoundId, encodeRoundId(1n, 10n));
    assert.equal(built.hint.afterPrevRoundId, 0n);
    assert.equal(
      built.hint.obsIndex,
      4,
      "newest observation at or before expiry, not the one after it",
    );
    assert.equal(built.unverifiable, false);
  });

  it("flags a garbage run as unverifiable so the caller stops retrying", async () => {
    const { client } = setup((f) => {
      f.fill(1n, T0, 2, H4, 200_00000000n);
      for (let i = 0; i < 40; i++) f.set(1n, 3n + BigInt(i), 0n, T0 + (2n + BigInt(i)) * H4);
    });
    const built = await buildHint({
      client,
      feed: FEED,
      pool: POOL,
      expiry: T0 + 50n * H4,
      firstRound: encodeRoundId(1n, 1n),
    });
    assert.equal(built.hint.refRoundId, 0n);
    assert.equal(built.unverifiable, "GARBAGE_RUN");
  });
});
