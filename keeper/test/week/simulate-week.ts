/**
 * One full simulated week against an anvil fork of 46630.
 *
 * Weekday auction → clear → settle → weekend auction → clear → settle, driven by the keeper's own
 * scheduler, jobs, hint builder and pricing — nothing here reimplements a decision. The harness only
 * does what the outside world would do: deposit, post a bond, bid, publish oracle data, and move time.
 *
 * Run it with `npm run week` (see scripts/fork-week.sh, which boots anvil first).
 */
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { formatEther } from "viem";
import {
  auctionHouseAbi,
  bondManagerAbi,
  erc20Abi,
  mockStockTokenAbi,
  mockUsdgAbi,
  vaultAbi,
} from "../../src/abi/index.js";
import { buildKeeperAllowTable, createSender } from "../../src/chain/tx.js";
import { loadConfig, loadEnv } from "../../src/config.js";
import { createLogger } from "../../src/logger.js";
import { runChecks, worst } from "../../src/monitor/checks.js";
import { buildStatus } from "../../src/monitor/status.js";
import { Scheduler } from "../../src/scheduler.js";
import { StateDir } from "../../src/state.js";
import { WEEK, describe as describeTs, iso, weekStart } from "../../src/time/epoch.js";
import { loadDeployment } from "../../src/deployment.js";
import { createClients } from "../../src/chain/clients.js";
import {
  ACCOUNTS,
  ANVIL_URL,
  now,
  postRound,
  publicClient,
  seedTwapWindow,
  sendAs,
  setBalance,
  steppedWarp,
  warpRaw,
  writeObservation,
  type Feeds,
} from "./anvil.js";

const DEPLOYMENT = process.env.WEEK_DEPLOYMENT ?? "../contracts/deployments/46630.json";
const SYMBOL = process.env.WEEK_SYMBOL ?? "NVDA";
const POOL_LIQUIDITY = 10_000_000_000_000_000_000n; // 1e19, the seeded mock depth (passes the §9.3 rule)
const DEPOSIT = 100_000_000_000_000_000_000n; // 100 NVDA; the $25 000 cap allows 125 at $200
const MM_USDG = 10_000_000_000_000n; // 10 M USDG
const BOND_MM = 1; // IBondManager.BondKind.MM

const log = createLogger(process.env.LOG_LEVEL ?? "info");
const line = (s = "") => process.stdout.write(`${s}\n`);
const rule = (title: string) => {
  line();
  line(`══ ${title} ${"═".repeat(Math.max(0, 76 - title.length))}`);
};

/** price8 → the Uniswap tick that `OracleMath.quotePrice8` inverts to it, for USDG = token0. */
const tickForPrice8 = (price8: bigint): number =>
  Math.round(Math.log(1e20 / Number(price8)) / Math.log(1.0001));

/** A deterministic walk, so two runs of this script produce the same week. */
function priceWalk(seed: number) {
  let s = seed;
  const rand = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;
  let price = 200;
  return (): bigint => {
    price *= Math.exp(0.006 * (rand() * 2 - 1) * 1.7);
    price = Math.min(215, Math.max(185, price)); // keep well inside the jump guard and the TWAP bound
    return BigInt(Math.round(price * 1e8));
  };
}

async function main(): Promise<void> {
  const deployment = loadDeployment(DEPLOYMENT, 46630, process.cwd());
  const vaultEntry = deployment.vaults.find((v) => v.symbol === SYMBOL);
  if (!vaultEntry) throw new Error(`no ${SYMBOL} vault in ${DEPLOYMENT}`);
  const admin = deployment.deployer; // on 46630 this key is admin, guardian, treasury and keeper (D-105)

  const feeds: Feeds = {
    stockFeed: vaultEntry.feed,
    usdgFeed: deployment.external.usdgUsdFeed,
    pool: vaultEntry.pool,
    tick: tickForPrice8(20_000_000_000n),
    liquidity: POOL_LIQUIDITY,
  };

  rule("0 · fork");
  const chainId = await publicClient.getChainId();
  line(`anvil        ${ANVIL_URL}  chainId ${chainId}`);
  line(`deployment   ${DEPLOYMENT}  (${deployment.label})`);
  line(`vault        ${SYMBOL} ${vaultEntry.vault}`);
  line(`block time   ${await now()}  ${iso(await now())}`);
  if (chainId !== 46630) throw new Error(`expected a fork of 46630, got ${chainId}`);

  /* ── 1 · seed the world the keeper acts in ───────────────────────────── */
  rule("1 · seed");

  // The timelock is funded too: it is a contract, but anvil impersonates it to grant KEEPER_ROLE and
  // that transaction still needs gas.
  for (const a of [
    admin,
    deployment.timelock,
    ACCOUNTS.keeper.address,
    ACCOUNTS.depositor.address,
    ACCOUNTS.mm1.address,
    ACCOUNTS.mm2.address,
  ]) {
    await setBalance(a, 100_000_000_000_000_000_000n);
  }

  // Grant KEEPER_ROLE to a local key so the keeper signs for itself, exactly as in production. The
  // AuctionHouse's owner is the TimelockController; anvil impersonates contracts as happily as EOAs.
  await sendAs(deployment.timelock, {
    address: deployment.core.auctionHouse,
    abi: auctionHouseAbi,
    functionName: "setKeeper",
    args: [ACCOUNTS.keeper.address, true],
  });
  line(`KEEPER_ROLE  granted to ${ACCOUNTS.keeper.address} via the timelock`);

  // Deposit. `canOpen` does not look at the balance — `openSeries` reverts NothingToOffer — so an empty
  // vault would fail only at simulate.
  await sendAs(admin, {
    address: vaultEntry.stock,
    abi: mockStockTokenAbi,
    functionName: "mint",
    args: [ACCOUNTS.depositor.address, DEPOSIT * 2n],
  });
  await sendAs(ACCOUNTS.depositor.address, {
    address: vaultEntry.stock,
    abi: mockStockTokenAbi,
    functionName: "approve",
    args: [vaultEntry.vault, DEPOSIT * 2n],
  });
  await sendAs(ACCOUNTS.depositor.address, {
    address: vaultEntry.vault,
    abi: vaultAbi,
    functionName: "deposit",
    args: [DEPOSIT, ACCOUNTS.depositor.address],
  });
  line(`deposit      ${formatEther(DEPOSIT)} ${SYMBOL} from ${ACCOUNTS.depositor.address}`);

  // Two bonded market makers.
  for (const mm of [ACCOUNTS.mm1, ACCOUNTS.mm2]) {
    await sendAs(mm.address, {
      address: deployment.external.usdg,
      abi: mockUsdgAbi,
      functionName: "mint",
      args: [mm.address, MM_USDG],
    });
    await sendAs(mm.address, {
      address: deployment.external.usdg,
      abi: erc20Abi,
      functionName: "approve",
      args: [deployment.core.bondManager, MM_USDG],
    });
    await sendAs(mm.address, {
      address: deployment.external.usdg,
      abi: erc20Abi,
      functionName: "approve",
      args: [deployment.core.auctionHouse, MM_USDG],
    });
    await sendAs(mm.address, {
      address: deployment.core.bondManager,
      abi: bondManagerAbi,
      functionName: "postBond",
      args: [BOND_MM],
    });
  }
  line(`bonds        posted by ${ACCOUNTS.mm1.address} and ${ACCOUNTS.mm2.address}`);

  /* ── 2 · wire the keeper ─────────────────────────────────────────────── */
  const stateDir = mkdtempSync(join(tmpdir(), "overwrite-week-"));
  process.env.CHAIN_ID = "46630";
  process.env.KEEPER_RPC_URL = ANVIL_URL;
  process.env.KEEPER_PRIVATE_KEY = ACCOUNTS.keeper.key;
  process.env.KEEPER_CONFIG = process.env.WEEK_CONFIG ?? "./config/keeper.week.json";
  process.env.DEPLOYMENT_PATH = DEPLOYMENT;
  process.env.STATE_DIR = stateDir;
  process.env.STATUS_PORT = "0";
  process.env.GUARDIAN_AUTOPAUSE = "false";
  delete process.env.TELEGRAM_BOT_TOKEN;

  const env = loadEnv();
  const cfg = loadConfig(env, ACCOUNTS.keeper.address);
  const clients = createClients(env);
  const state = new StateDir(stateDir);
  const sender = createSender({
    publicClient: clients.publicClient,
    wallet: clients.keeperWallet,
    account: clients.keeper,
    allow: buildKeeperAllowTable(cfg.deployment, cfg.file.role),
    options: cfg.file.tx,
    dryRun: false,
    log,
  });
  const scheduler = new Scheduler(cfg, clients.publicClient, sender, state, log);
  const vaults = [{ symbol: SYMBOL, vault: cfg.file.vaults[SYMBOL]! }];

  let sent = 0;
  const countSends = async <T>(fn: () => Promise<T>): Promise<{ value: T; sent: number }> => {
    const before = await publicClient.getTransactionCount({ address: ACCOUNTS.keeper.address });
    const value = await fn();
    const after = await publicClient.getTransactionCount({ address: ACCOUNTS.keeper.address });
    sent += after - before;
    return { value, sent: after - before };
  };

  const lastOpen = () => scheduler.recentActions.find((a) => a.action.startsWith("openAuction"));
  const tick = async (label: string) => {
    const r = await countSends(() => scheduler.tick(vaults));
    const v = r.value.vaults[0];
    line(
      `  keeper tick  ${label.padEnd(22)} state=${(v?.snapshot.state ?? "?").padEnd(7)} ` +
        `due=${(v?.due ?? "?").padEnd(8)} → ${v?.outcome}${v?.detail ? `  (${v.detail})` : ""}`,
    );
    return { result: r.value, txs: r.sent };
  };

  /**
   * Runs the tick, then re-runs it until nothing more is due, and asserts two things:
   *
   *  - the lifecycle action never repeats (a second `openAuction`, `clear` or `settle` for the same
   *    series would mean the keeper does not read its own effect), and
   *  - the loop converges.
   *
   * It deliberately does not assert "the re-run sends zero transactions". After a `clear` the FeeRouter
   * has a pending fee, so the next tick legitimately flushes it — a *different* action becoming due, not
   * the same one repeating.
   */
  const tickIdempotent = async (label: string) => {
    const before = new Set(scheduler.recentActions.map((a) => `${a.vault}/${a.action}/${a.at}`));
    const first = await tick(label);
    const primary = scheduler.recentActions
      .filter((a) => !before.has(`${a.vault}/${a.action}/${a.at}`))
      .map((a) => a.action);

    for (let round = 1; round <= 3; round++) {
      const again = await tick(`${label} (re-run ${round})`);
      const repeated = scheduler.recentActions
        .slice(0, again.txs || 1)
        .filter((a) => primary.includes(a.action) && !before.has(`${a.vault}/${a.action}/${a.at}`));
      if (again.txs === 0) {
        line(`               ↳ idempotent: settled after ${round} re-run(s), nothing further due`);
        return first;
      }
      if (repeated.length > 0 && round > 1) {
        throw new Error(
          `NOT IDEMPOTENT: "${label}" repeated ${repeated.map((r) => r.action).join(", ")}`,
        );
      }
      line(
        `               ↳ re-run ${round} sent ${again.txs} tx for a different, newly-due action`,
      );
    }
    throw new Error(`"${label}" never quiesced: still sending after 3 re-runs`);
  };

  const nextPrice = priceWalk(7);
  const upkeep = (target: bigint) =>
    steppedWarp({ target, feeds, sender: admin, priceAt: () => nextPrice() });

  const bid = async (
    mm: (typeof ACCOUNTS)["mm1"],
    seriesId: bigint,
    qty: bigint,
    price: bigint,
  ) => {
    await sendAs(mm.address, {
      address: deployment.core.auctionHouse,
      abi: auctionHouseAbi,
      functionName: "bid",
      args: [seriesId, qty, price],
    });
    line(
      `  bid          ${mm.address.slice(0, 10)}…  qty ${formatEther(qty)}  price ${Number(price) / 1e6} USDG`,
    );
  };

  const seriesId = async (): Promise<bigint> =>
    await publicClient.readContract({
      address: vaultEntry.vault,
      abi: vaultAbi,
      functionName: "currentSeriesId",
    });
  const auction = async (id: bigint) =>
    (await publicClient.readContract({
      address: deployment.core.auctionHouse,
      abi: auctionHouseAbi,
      functionName: "auctions",
      args: [id],
    })) as {
      auctionClose: bigint;
      reservePrice: bigint;
      strike: bigint;
      sRef: bigint;
      expiry: bigint;
      offeredQty: bigint;
    };
  const series = async (id: bigint) =>
    (await publicClient.readContract({
      address: vaultEntry.vault,
      abi: vaultAbi,
      functionName: "series",
      args: [id],
    })) as {
      state: number;
      settlementPrice: bigint;
      settlementPath: number;
      payoutPerOption: bigint;
      filledQty: bigint;
      expiry: bigint;
    };

  /* ── 3 · Monday: the weekday auction ─────────────────────────────────── */
  const t0 = await now();
  const monday =
    weekStart(t0) + 396_000n >= t0 ? weekStart(t0) + 396_000n : weekStart(t0) + WEEK + 396_000n;

  rule(`2 · Monday 14:00 UTC — open the weekday auction`);
  line(`  warping to   ${monday}  ${iso(monday)}  (${describeTs(monday)})`);
  await upkeep(monday);
  line(
    `  oracle upkeep posted a stock round, a USDG round and a pool observation every 4 h across the gap`,
  );

  await tickIdempotent("open WEEKDAY");
  const id1 = await seriesId();
  const a1 = await auction(id1);
  line(
    `  series ${id1}     sRef ${fmt8(a1.sRef)}  strike ${fmt8(a1.strike)}  offered ${formatEther(a1.offeredQty)}  ` +
      `reserve ${Number(a1.reservePrice) / 1e6} USDG  expiry ${iso(a1.expiry)}`,
  );
  line(`  pricing      ${lastOpen()?.detail ?? "?"}`);

  rule("3 · Monday 14:05 — market makers bid");
  await bid(ACCOUNTS.mm1, id1, 60_000_000_000_000_000_000n, a1.reservePrice * 3n);
  await bid(ACCOUNTS.mm2, id1, 60_000_000_000_000_000_000n, a1.reservePrice * 2n);

  rule("4 · Monday 14:15 — clear");
  await warpRaw(a1.auctionClose + 10n);
  await tickIdempotent("clear WEEKDAY");
  const s1 = await series(id1);
  line(`  series ${id1}     state=${s1.state} (3 = LIVE)  filled ${formatEther(s1.filledQty)}`);

  /* ── 4 · Friday: settle the weekday series ───────────────────────────── */
  rule("5 · Friday 16:00 ET — settle the weekday series (path 1, Chainlink at expiry)");
  const expiry1 = s1.expiry;
  line(`  warping to   ${expiry1}  ${iso(expiry1)}  (${describeTs(expiry1)})`);
  await upkeep(expiry1 - 3_600n);
  const settlePrice = nextPrice();
  await postRound(feeds.stockFeed, settlePrice, expiry1 - 1_800n, admin);
  await postRound(feeds.usdgFeed, 1_00000000n, expiry1 - 1_800n, admin);
  await writeObservation(
    feeds.pool,
    expiry1 - 1_800n,
    tickForPrice8(settlePrice),
    POOL_LIQUIDITY,
    admin,
  );
  await warpRaw(expiry1);
  line(
    `  last round   ${fmt8(settlePrice)} at expiry − 1800 s, inside the 26 h weekdayMaxStale budget`,
  );

  await tickIdempotent("settle WEEKDAY");
  const settled1 = await series(id1);
  line(
    `  series ${id1}     state=${settled1.state} (4 = SETTLED)  path ${settled1.settlementPath}  ` +
      `price ${fmt8(settled1.settlementPrice)}  payoutPerOption ${formatEther(settled1.payoutPerOption)}`,
  );
  assert(settled1.state === 4, `weekday series should be SETTLED, got state ${settled1.state}`);
  assert(settled1.settlementPath === 1, `expected path 1, got ${settled1.settlementPath}`);

  /* ── 5 · Friday +10 min: the weekend auction ─────────────────────────── */
  rule("6 · Friday 16:10 ET — open the weekend auction");
  await warpRaw(expiry1 + 600n);
  await tickIdempotent("open WEEKEND");
  const id2 = await seriesId();
  const a2 = await auction(id2);
  line(
    `  series ${id2}     sRef ${fmt8(a2.sRef)}  strike ${fmt8(a2.strike)}  offered ${formatEther(a2.offeredQty)}  ` +
      `reserve ${Number(a2.reservePrice) / 1e6} USDG  expiry ${iso(a2.expiry)}`,
  );
  line(`  pricing      ${lastOpen()?.detail ?? "?"}`);
  assert(id2 !== id1, "the weekend auction must be a new series");

  rule("7 · Friday 16:15 ET — bid and clear the weekend auction");
  await bid(ACCOUNTS.mm1, id2, 50_000_000_000_000_000_000n, a2.reservePrice * 4n);
  await warpRaw(a2.auctionClose + 10n);
  await tickIdempotent("clear WEEKEND");
  const s2 = await series(id2);
  line(`  series ${id2}     state=${s2.state} (3 = LIVE)  filled ${formatEther(s2.filledQty)}`);

  /* ── 6 · Sunday 23:59 UTC: settle the weekend series on the TWAP ─────── */
  rule("8 · Sunday 23:59 UTC — settle the weekend series (path 2, 60-minute TWAP)");
  const expiry2 = s2.expiry;
  line(`  warping to   ${expiry2}  ${iso(expiry2)}  (${describeTs(expiry2)})`);
  await upkeep(expiry2 - 4n * 3_600n);
  await postRound(feeds.usdgFeed, 1_00000000n, expiry2 - 600n, admin);
  await seedTwapWindow({ ...feeds, tick: tickForPrice8(20_000_000_000n) }, expiry2, admin);
  line(`  seeded       five pool observations at expiry −{3600, 2400, 1200, 600, 120} s`);
  line(
    `               (minObservationsInWindow = 3, and MAX_LAST_OBS_AGE = 900 forces the final 120)`,
  );
  await warpRaw(expiry2 + 60n);

  await tickIdempotent("settle WEEKEND");
  const settled2 = await series(id2);
  line(
    `  series ${id2}     state=${settled2.state} (4 = SETTLED)  path ${settled2.settlementPath}  ` +
      `price ${fmt8(settled2.settlementPrice)}  payoutPerOption ${formatEther(settled2.payoutPerOption)}`,
  );
  assert(settled2.state === 4, `weekend series should be SETTLED, got state ${settled2.state}`);
  assert(settled2.settlementPath === 2, `expected path 2 (TWAP), got ${settled2.settlementPath}`);

  /* ── 7 · health ──────────────────────────────────────────────────────── */
  rule("9 · health");
  const final = await scheduler.tick(vaults);
  const { checks } = await runChecks({
    cfg,
    client: clients.publicClient,
    now: final.now,
    ticks: final.vaults,
    knownImplementations: {},
  });
  for (const c of checks) {
    if (c.severity === "ok") continue;
    line(
      `  ${c.severity.toUpperCase().padEnd(5)} ${(c.vault ? `${c.id}:${c.vault}` : c.id).padEnd(32)} ${c.summary}`,
    );
  }
  const status = buildStatus({
    cfg,
    tick: final,
    checks,
    recentActions: scheduler.recentActions,
    generatedAt: new Date(),
  });
  line(`  overall      ${worst(checks)}`);
  line(
    `  status.json  ${status.vaults.length} vault(s), ${status.checks.length} checks, ${status.recentActions.length} recorded actions`,
  );

  rule("10 · summary");
  line(`  keeper transactions sent: ${sent}`);
  for (const a of [...scheduler.recentActions].reverse()) {
    line(
      `    ${a.vault.padEnd(5)} ${a.action.padEnd(22)} ${a.outcome}${a.detail ? `  — ${a.detail}` : ""}`,
    );
  }
  line();
  line(
    "  weekday auction → clear → settle (path 1) → weekend auction → clear → settle (path 2): complete.",
  );
  line();
}

function assert(cond: boolean, message: string): void {
  if (!cond) throw new Error(message);
}

const fmt8 = (x: bigint): string => (Number(x) / 1e8).toFixed(4);

main().catch((err: unknown) => {
  line();
  line(`FAILED: ${err instanceof Error ? err.message : String(err)}`);
  if (err instanceof Error && err.stack) line(err.stack.split("\n").slice(1, 6).join("\n"));
  process.exit(1);
});
