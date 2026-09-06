import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildKeeperAllowTable } from "../src/chain/tx.js";
import { assertUpkeepAllowed, loadEnv } from "../src/config.js";
import type { Deployment } from "../src/deployment.js";
import {
  isDue,
  nextPrice8,
  nextRoundId,
  nextUsdg8,
  price8ForTick,
  tickForPrice8,
} from "../src/jobs/testnetUpkeep.js";

/**
 * The 46630 upkeep job (src/jobs/testnetUpkeep.ts). Two things matter here: the arithmetic the mocks
 * are fed must agree with the production oracle math, and the whole feature must be impossible to turn
 * on anywhere but the testnet.
 */

const KEY = `0x${"11".repeat(32)}`;
const A = (n: number): `0x${string}` => `0x${n.toString(16).padStart(40, "0")}`;

const deployment = (chainId: number): Deployment => ({
  chainId,
  label: "t",
  deployedAt: 0,
  deployer: A(1),
  timelock: A(2),
  external: { usdg: A(3), usdgUsdFeed: A(4) },
  core: {
    riskModule: A(5),
    optionToken: A(6),
    bondManager: A(7),
    feeRouter: A(8),
    auctionHouse: A(9),
    capController: A(10),
    settlementOracle: A(11),
  },
  vaults: [{ symbol: "NVDA", vault: A(12), stock: A(13), feed: A(14), pool: A(15) }],
  mocked: ["USDG", "NVDA/USD feed"],
});

describe("tick ↔ price8", () => {
  it("round-trips within one tick for both pool orientations", () => {
    for (const price8 of [20_000_000_000n, 69_000_000_000n, 123_456_789n, 5_000_000_000_000n]) {
      for (const stockIsToken0 of [false, true]) {
        const tick = tickForPrice8(price8, stockIsToken0);
        const back = price8ForTick(tick, stockIsToken0);
        const err = Math.abs(Number(back - price8)) / Number(price8);
        assert.ok(err < 1e-4, `${price8} token0=${stockIsToken0}: tick ${tick} → ${back} (${err})`);
      }
    }
  });

  it("matches the fork harness for USDG = token0 (stock = token1)", () => {
    // keeper/test/week/simulate-week.ts: round(log(1e20 / price8) / log(1.0001))
    const p = 20_000_000_000n;
    assert.equal(
      tickForPrice8(p, false),
      Math.round(Math.log(1e20 / Number(p)) / Math.log(1.0001)),
    );
  });

  it("a higher price is a lower tick when the stock is token1, and a higher tick when it is token0", () => {
    assert.ok(tickForPrice8(21_000_000_000n, false) < tickForPrice8(20_000_000_000n, false));
    assert.ok(tickForPrice8(21_000_000_000n, true) > tickForPrice8(20_000_000_000n, true));
  });
});

describe("random walk", () => {
  it("stays inside the band around the anchor whatever the draws", () => {
    const anchor = 20_000_000_000n;
    let last = anchor;
    let s = 7;
    const rand = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;
    for (let i = 0; i < 5_000; i++) {
      last = nextPrice8(last, anchor, 40, 800, rand);
      assert.ok(last >= 18_400_000_000n && last <= 21_600_000_000n, `step ${i}: ${last}`);
    }
  });

  it("clamps an extreme draw to the band edge instead of overshooting", () => {
    // u1 = 1e-12 gives z ≈ 7.4 (cos(2π·1e-12) ≈ 1); at σ = 500 bps that is a +45 % draw, clamped to +8 %.
    const up = nextPrice8(20_000_000_000n, 20_000_000_000n, 500, 800, () => 1e-12);
    assert.equal(up, 21_600_000_000n);
    // The same draw at σ = 40 bps is only +3 %, inside the band, so it passes through unclamped.
    const mild = nextPrice8(20_000_000_000n, 20_000_000_000n, 40, 800, () => 1e-12);
    assert.ok(mild > 20_000_000_000n && mild < 21_600_000_000n, `${mild}`);
  });

  it("a zero step never moves the price", () => {
    assert.equal(nextPrice8(20_000_000_000n, 20_000_000_000n, 0, 800), 20_000_000_000n);
  });

  it("USDG/USD stays inside the peg band by a wide margin", () => {
    for (let i = 0; i < 1_000; i++) {
      const v = nextUsdg8(5);
      assert.ok(v >= 99_950_000n && v <= 100_050_000n, `${v}`);
    }
    assert.equal(
      nextUsdg8(5, () => 0.5),
      100_000_000n,
    );
  });
});

describe("rounds and cadence", () => {
  it("the next round id stays in the same phase and is contiguous", () => {
    const id = (1n << 64n) | 13n;
    assert.equal(nextRoundId(id), (1n << 64n) | 14n);
    const p3 = (3n << 64n) | 1n;
    assert.equal(nextRoundId(p3) >> 64n, 3n);
  });

  it("isDue is a plain interval check on chain time", () => {
    assert.equal(isDue(1_000n, 600, 1_599n), false);
    assert.equal(isDue(1_000n, 600, 1_600n), true);
  });
});

describe("chain gating", () => {
  it("config refuses upkeep on mainnet and accepts it on testnet", () => {
    assert.throws(() => assertUpkeepAllowed(4663, true), /only allowed on chain 46630/);
    assert.doesNotThrow(() => assertUpkeepAllowed(4663, false));
    assert.doesNotThrow(() => assertUpkeepAllowed(46630, true));
  });

  it("TESTNET_UPKEEP parses as a boolean and is off by default", () => {
    const base = { CHAIN_ID: "46630", KEEPER_PRIVATE_KEY: KEY };
    assert.equal(loadEnv(base).TESTNET_UPKEEP, false);
    assert.equal(loadEnv({ ...base, TESTNET_UPKEEP: "true" }).TESTNET_UPKEEP, true);
    assert.equal(loadEnv({ ...base, TESTNET_UPKEEP: "" }).TESTNET_UPKEEP, false);
  });

  it("the allowlist admits setRound/write only with upkeep on and chain 46630", () => {
    const d = deployment(46630);
    const off = buildKeeperAllowTable(d, "full");
    assert.equal(off.get(A(14).toLowerCase()), undefined);
    assert.equal(off.get(A(15).toLowerCase()), undefined);

    const on = buildKeeperAllowTable(d, "full", { testnetUpkeep: true });
    assert.deepEqual([...on.get(A(14).toLowerCase())!.functions], ["setRound"]);
    assert.deepEqual([...on.get(A(4).toLowerCase())!.functions], ["setRound"]);
    assert.deepEqual([...on.get(A(15).toLowerCase())!.functions], ["write"]);
    // The lifecycle entries are untouched.
    assert.ok(on.get(A(9).toLowerCase())!.functions.has("openAuction"));

    assert.throws(
      () => buildKeeperAllowTable(deployment(4663), "full", { testnetUpkeep: true }),
      /exists only for 46630/,
    );
  });
});
