import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { callPrice, normCdf, putPrice } from "../src/pricing/blackScholes.js";
import { estimateVol, sessionCloses, stdev } from "../src/pricing/realisedVol.js";
import { quoteReserve } from "../src/pricing/reserve.js";
import { DEFAULT_VARIANCE_PARAMS } from "../src/time/tradingTime.js";
import type { VolEstimate } from "../src/pricing/realisedVol.js";
import { FEED, POOL, FakeFeed, FakePool, fakeClient } from "./fakes.js";

const utc = (iso: string): bigint => BigInt(Date.parse(iso) / 1000);
const close = (x: number, y: number, tol: number, what = "") =>
  assert.ok(Math.abs(x - y) <= tol, `${what} expected ~${y}, got ${x}`);

describe("black-scholes", () => {
  it("matches known reference values", () => {
    close(normCdf(0), 0.5, 1e-9);
    close(normCdf(1.96), 0.975, 1e-4);
    close(normCdf(-1.96), 0.025, 1e-4);
    // S=100, K=100, T=1, sigma=0.2, r=0.05 -> 10.4506 (Hull, standard textbook figure)
    close(
      callPrice({ spot: 100, strike: 100, years: 1, sigma: 0.2, rate: 0.05 }),
      10.4506,
      1e-3,
      "ATM call",
    );
    // S=42, K=40, T=0.5, sigma=0.2, r=0.1 -> 4.76
    close(
      callPrice({ spot: 42, strike: 40, years: 0.5, sigma: 0.2, rate: 0.1 }),
      4.7594,
      2e-3,
      "Hull 15.6",
    );
  });

  it("satisfies put-call parity", () => {
    const input = { spot: 200, strike: 216, years: 0.02, sigma: 0.4, rate: 0.03 };
    const lhs = callPrice(input) - putPrice(input);
    const rhs = input.spot - input.strike * Math.exp(-input.rate * input.years);
    close(lhs, rhs, 1e-9, "parity");
  });

  it("is monotone in sigma and in time, and collapses to intrinsic at the limits", () => {
    const base = { spot: 200, strike: 216, years: 0.02, rate: 0 };
    const cheap = callPrice({ ...base, sigma: 0.2 });
    const dear = callPrice({ ...base, sigma: 0.6 });
    assert.ok(dear > cheap, "more vol is worth more");
    assert.ok(
      callPrice({ ...base, sigma: 0.4, years: 0.1 }) > callPrice({ ...base, sigma: 0.4 }),
      "more time is worth more",
    );

    assert.equal(callPrice({ ...base, sigma: 0.4, years: 0 }), 0, "OTM at expiry is worthless");
    close(
      callPrice({ spot: 250, strike: 216, years: 0, sigma: 0.4, rate: 0 }),
      34,
      1e-9,
      "ITM at expiry is intrinsic",
    );
  });

  it("never returns a negative price for a deep out-of-the-money call", () => {
    const p = callPrice({ spot: 200, strike: 10_000, years: 0.001, sigma: 0.1, rate: 0 });
    assert.ok(p >= 0 && Number.isFinite(p), `got ${p}`);
  });
});

describe("realised vol", () => {
  const feedFor = (build: (f: FakeFeed) => void) => {
    const feed = new FakeFeed();
    build(feed);
    return fakeClient(feed, new FakePool(8), FEED, POOL);
  };

  const params = {
    windowDays: 30,
    minSamples: 10,
    floor: 0.05,
    cap: 2,
    fallback: 0.55,
    maxRoundScan: 4000,
  };

  it("recovers sigma from a synthetic random walk", async () => {
    // A deterministic pseudo-random walk with a known per-session sigma, sampled at each session close.
    const sigmaDaily = 0.02; // ~31.7 % annualised
    let seed = 42;
    const rand = () => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed / 2147483648;
    };
    const gauss = () => Math.sqrt(-2 * Math.log(rand() || 1e-12)) * Math.cos(2 * Math.PI * rand());

    const now = utc("2026-09-11T20:00:00Z");
    const start = now - 60n * 86_400n;
    let price = 200;
    const client = feedFor((f) => {
      // Four rounds per day for 60 days, so every session has a close.
      let agg = 1n;
      for (let d = 0; d < 60; d++) {
        price *= Math.exp(sigmaDaily * gauss());
        for (const hour of [14n, 17n, 19n, 20n]) {
          f.set(
            1n,
            agg++,
            BigInt(Math.round(price * 1e8)),
            start + BigInt(d) * 86_400n + hour * 3600n,
          );
        }
      }
    });

    const est = await estimateVol({ client, feed: FEED, now, params });
    assert.equal(est.source, "realised", est.reason ?? "");
    assert.ok(est.samples >= 15, `expected a full window of samples, got ${est.samples}`);
    const expected = sigmaDaily * Math.sqrt(252);
    assert.ok(
      est.sigma > expected * 0.6 && est.sigma < expected * 1.6,
      `sigma ${est.sigma.toFixed(3)} is not within a reasonable band of ${expected.toFixed(3)}`,
    );
  });

  it("falls back when the feed has not moved — the 46630 case", async () => {
    // The deployed mock: 14 rounds, 4 h apart, all answering exactly 200.00. Every log return is zero,
    // so a count-only guard would hand Black-Scholes sigma = 0 and price an OTM call at zero.
    const now = utc("2026-09-04T20:20:18Z");
    const client = feedFor((f) => f.fill(1n, now - 13n * 14_400n, 14, 14_400n, 200_00000000n));
    const est = await estimateVol({ client, feed: FEED, now, params });

    assert.equal(est.source, "fallback");
    assert.equal(est.sigma, params.fallback);
    assert.ok(est.reason, "the fallback must say why");
  });

  it("falls back when there is not enough history", async () => {
    const now = utc("2026-09-11T20:00:00Z");
    const client = feedFor((f) => f.fill(1n, now - 3n * 86_400n, 4, 86_400n, 200_00000000n));
    const est = await estimateVol({ client, feed: FEED, now, params });
    assert.equal(est.source, "fallback");
    assert.match(String(est.reason), /session returns/);
  });

  it("clamps a wild estimate into the configured band", async () => {
    const now = utc("2026-09-11T20:00:00Z");
    const start = now - 40n * 86_400n;
    let agg = 1n;
    const client = feedFor((f) => {
      for (let d = 0; d < 40; d++) {
        // Alternating +-40 % daily moves: an absurd but finite sigma.
        const p = d % 2 === 0 ? 200 : 280;
        for (const hour of [14n, 20n]) {
          f.set(1n, agg++, BigInt(p) * 100_000_000n, start + BigInt(d) * 86_400n + hour * 3600n);
        }
      }
    });
    const est = await estimateVol({ client, feed: FEED, now, params });
    assert.ok(est.sigma <= params.cap, `sigma ${est.sigma} exceeded the cap`);
    assert.equal(est.sigma, params.cap);
    assert.match(String(est.reason), /clamped down/);
  });

  it("never counts the same round twice as two session closes", () => {
    // A quiet stretch must not inject zero returns by repeating one price across several sessions.
    const f = new FakeFeed();
    f.set(1n, 1n, 200_00000000n, utc("2026-09-08T19:00:00Z"));
    const rounds = [
      {
        id: FakeFeed.id(1n, 1n),
        phase: 1n,
        agg: 1n,
        answer: 200_00000000n,
        startedAt: 0n,
        updatedAt: utc("2026-09-08T19:00:00Z"),
      },
    ];
    const closes = sessionCloses(rounds, utc("2026-09-07T00:00:00Z"), utc("2026-09-11T21:00:00Z"));
    assert.equal(closes.length, 1, "one round can back at most one session close");
  });

  it("stdev is the sample standard deviation", () => {
    close(stdev([2, 4, 4, 4, 5, 5, 7, 9]), 2.13809, 1e-4);
    assert.equal(stdev([1]), 0);
  });
});

describe("reserve", () => {
  const vol = (sigma: number): VolEstimate => ({
    sigma,
    source: "realised",
    reason: null,
    samples: 20,
    rawSigma: sigma,
    windowFrom: 0n,
    windowTo: 0n,
    roundsScanned: 0,
    reads: 0,
    closes: [],
  });

  const nvda = (sigma: number, now: bigint, expiry: bigint, kindMin: number, kindMax: number) =>
    quoteReserve({
      sRef: 200_00000000n,
      strike: 216_00000000n,
      now,
      expiry,
      vol: vol(sigma),
      lo: (200_00000000n * BigInt(kindMin)) / 1_000_000n,
      hi: 200_00000000n / 100n,
      maxReserveBpsOfSpot: kindMax,
      minReserveBps: kindMin,
      reserveMarginBps: 200,
      riskFreeRateBps: 0,
      reserveFactorBps: 10_000,
      variance: DEFAULT_VARIANCE_PARAMS,
    });

  const MON = utc("2026-09-14T14:00:00Z");
  const FRI = utc("2026-09-18T20:00:00Z");
  const SUN = utc("2026-09-20T23:59:00Z");

  it("stays inside the contract's bounds and above its floor", () => {
    for (const sigma of [0.05, 0.2, 0.4, 0.8, 1.5]) {
      const q = nvda(sigma, MON, FRI, 10, 150);
      assert.ok(q.reservePrice >= q.lo, `sigma ${sigma}: ${q.reservePrice} below lo ${q.lo}`);
      assert.ok(q.reservePrice <= q.hi, `sigma ${sigma}: ${q.reservePrice} above hi ${q.hi}`);
    }
  });

  it("leaves room above the contract floor so a feed tick cannot invalidate it", () => {
    // `_checkOpen` re-reads sRef at inclusion; submitting exactly `lo` reverts ReserveOutOfBounds when
    // a 0.5 % deviation round lands between simulate and inclusion.
    const q = nvda(0.01, MON, FRI, 10, 150);
    assert.ok(
      q.reservePrice > q.lo,
      "the submitted reserve must sit strictly above the contract floor",
    );
    assert.ok(
      q.reservePrice >= (q.lo * 10_200n) / 10_000n,
      "at least the configured 200 bps of margin",
    );
  });

  it("prices the weekend below the weekday for the same vault", () => {
    // The failure this pins down: calendar time makes a 2.16-day weekend look like half a 4.25-day
    // week, so the weekend reserve comes out several times too high and every weekend auction skips.
    const weekday = nvda(0.45, MON, FRI, 10, 150);
    const weekend = quoteReserve({
      sRef: 200_00000000n,
      strike: 210_00000000n,
      now: utc("2026-09-18T20:10:00Z"),
      expiry: SUN,
      vol: vol(0.45),
      lo: (200_00000000n * 3n) / 1_000_000n,
      hi: 200_00000000n / 100n,
      maxReserveBpsOfSpot: 60,
      minReserveBps: 3,
      reserveMarginBps: 200,
      riskFreeRateBps: 0,
      reserveFactorBps: 10_000,
      variance: DEFAULT_VARIANCE_PARAMS,
    });
    assert.ok(
      weekend.modelPrice < weekday.modelPrice,
      `weekend model ${weekend.modelPrice} should be below weekday ${weekday.modelPrice}`,
    );
    assert.ok(
      weekend.varianceYears < weekday.varianceYears / 5,
      "a weekend is a fraction of a trading week",
    );
  });

  it("reports when the contract floor, not the model, set the price", () => {
    const cheap = nvda(0.05, MON, FRI, 10, 150);
    assert.ok(cheap.floorBinds, "at 5 % vol an 8 % OTM weekly is worth less than 10 bps of spot");
    assert.ok(cheap.coverRatio < 1);
    assert.match(cheap.decidedBy, /floor/);

    const rich = nvda(0.6, MON, FRI, 10, 150);
    assert.ok(!rich.floorBinds, "at 60 % vol the model should clear the floor");
    assert.ok(rich.coverRatio > 1);
    assert.equal(rich.decidedBy, "model");
  });

  it("applies the spot cap before the floor, never producing a value below lo", () => {
    // A cap tighter than the contract's own minimum must not push the reserve under it.
    const q = nvda(1.5, MON, FRI, 10, 5);
    assert.ok(q.reservePrice >= q.lo, "the contract floor wins over a too-tight keeper cap");
  });
});
