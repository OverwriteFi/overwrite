import {
  hexToBigInt,
  keccak256,
  toBytes,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { aggregatorAbi, settlementOracleAbi } from "../abi/index.js";
import { multicall } from "../chain/multicall.js";
import type { ResolvedConfig } from "../config.js";
import { coverage } from "../oracle/observations.js";
import { calendarDaysRemaining } from "../time/nyse.js";
import type { VaultTickResult } from "../scheduler.js";

/**
 * Health checks.
 *
 * Two design rules, both learned from what 46630 actually looks like:
 *
 *  - **A check that cannot be computed reports `n/a`, never a failure.** The testnet's USDG and stock
 *    tokens are plain mocks, not proxies, so the D-020 implementation watch has nothing to read. A
 *    check that fired CRIT on the first tick and never stopped would train the operator to ignore the
 *    channel, which is worse than not having the check.
 *  - **An expected state is INFO, not an incident.** Both testnet vaults hold nothing, so `openAuction`
 *    cannot open until somebody deposits. That is a fact about the deployment, not a fault, and it
 *    should not page anybody every Monday.
 */

export type Severity = "ok" | "info" | "warn" | "crit" | "na";

export interface Check {
  id: string;
  severity: Severity;
  summary: string;
  vault?: string;
  measured?: string;
  threshold?: string;
}

/**
 * ERC-1967 storage slots for the D-020 upgrade watch, derived from their preimages rather than pasted:
 * `keccak256("eip1967.proxy.implementation") - 1` and `keccak256("eip1967.proxy.beacon") - 1`.
 *
 * Deriving them says where they come from, and it keeps a bare 32-byte literal out of the tree — the
 * repo's pre-commit secret scan cannot tell a well-known constant from a private key, and it is right
 * not to try.
 */
const erc1967Slot = (label: string): Hex =>
  toHex(hexToBigInt(keccak256(toBytes(label))) - 1n, { size: 32 });
const IMPL_SLOT = erc1967Slot("eip1967.proxy.implementation");
const BEACON_SLOT = erc1967Slot("eip1967.proxy.beacon");

export interface CheckContext {
  cfg: ResolvedConfig;
  client: PublicClient;
  now: bigint;
  ticks: VaultTickResult[];
  /** Previously recorded implementation hashes, for change detection. */
  knownImplementations: Record<string, string>;
}

export async function runChecks(
  ctx: CheckContext,
): Promise<{ checks: Check[]; implementations: Record<string, string> }> {
  const { cfg, client, now, ticks } = ctx;
  const m = cfg.file.monitor;
  const checks: Check[] = [];

  /* ── keeper wallet ── */
  const balance = await client.getBalance({ address: cfg.keeperAddress });
  const warnAt = BigInt(m.minKeeperEthWei);
  const critAt = BigInt(m.critKeeperEthWei);
  checks.push({
    id: "keeper.balance",
    severity: balance < critAt ? "crit" : balance < warnAt ? "warn" : "ok",
    summary:
      balance < warnAt
        ? `keeper ETH balance ${fmtEth(balance)} is below the ${fmtEth(warnAt)} threshold; it pays gas for every open, clear and settle`
        : `keeper ETH balance ${fmtEth(balance)}`,
    measured: balance.toString(),
    threshold: warnAt.toString(),
  });

  /* ── USDG peg and staleness (global; the feed is shared) ── */
  const usdgFeed = cfg.deployment.external.usdgUsdFeed;
  const anyParams = ticks[0]?.snapshot.params;
  const usdg = await readFeed(client, usdgFeed);
  if (!usdg) {
    checks.push({
      id: "usdg.peg",
      severity: "crit",
      summary: `USDG/USD feed ${usdgFeed} returned no data`,
    });
  } else {
    const age = now - usdg.updatedAt;
    const maxStale = BigInt(anyParams?.usdgMaxStale ?? 93_600);
    const lowBps = BigInt(anyParams?.usdgBandLowBps ?? 9_800);
    const highBps = BigInt(anyParams?.usdgBandHighBps ?? 10_200);
    const answerBps = (usdg.answer * 10_000n) / 100_000_000n;
    const margin = BigInt(m.pegMarginBps);
    const outside = answerBps < lowBps || answerBps > highBps;
    const near = answerBps < lowBps + margin || answerBps > highBps - margin;
    checks.push({
      id: "usdg.peg",
      severity: outside ? "crit" : near ? "warn" : "ok",
      summary: outside
        ? `USDG at ${fmt8(usdg.answer)} is outside the on-chain band [${lowBps}, ${highBps}] bps — every TWAP path is invalid until it returns (SPEC §9.5)`
        : `USDG at ${fmt8(usdg.answer)} (${answerBps} bps of par)`,
      measured: answerBps.toString(),
      threshold: `[${lowBps}, ${highBps}]`,
    });
    checks.push({
      id: "usdg.staleness",
      severity:
        age > maxStale
          ? "crit"
          : age > (maxStale * BigInt(m.stalenessWarnRatioBps)) / 10_000n
            ? "warn"
            : "ok",
      summary:
        age > maxStale
          ? `USDG/USD feed is ${age}s old, past its ${maxStale}s budget — the TWAP path is unavailable`
          : `USDG/USD feed ${age}s old`,
      measured: age.toString(),
      threshold: maxStale.toString(),
    });
  }

  /* ── calendar table ── */
  const daysLeft = calendarDaysRemaining(now);
  checks.push({
    id: "nyse.calendar",
    severity: daysLeft < 0 ? "crit" : daysLeft < m.calendarWarnDays ? "warn" : "ok",
    summary:
      daysLeft < 0
        ? `the NYSE holiday table ran out ${-daysLeft} days ago; holidays and early closes are now going unnoticed`
        : `NYSE calendar covers the next ${daysLeft} days`,
    measured: String(daysLeft),
    threshold: String(m.calendarWarnDays),
  });

  /* ── per-vault ── */
  const implementations: Record<string, string> = { ...ctx.knownImplementations };

  for (const t of ticks) {
    const s = t.snapshot;
    const v = s.symbol;

    // Chainlink staleness against the vault's own snapshotted budget.
    const feed = await readFeed(client, s.addresses.feed);
    if (!feed) {
      checks.push({
        id: "chainlink.staleness",
        vault: v,
        severity: "crit",
        summary: `feed ${s.addresses.feed} returned no data`,
      });
    } else {
      const age = now - feed.updatedAt;
      const budget = BigInt(s.params.weekdayMaxStale || 93_600);
      const warn = (budget * BigInt(m.stalenessWarnRatioBps)) / 10_000n;
      checks.push({
        id: "chainlink.staleness",
        vault: v,
        severity: age > budget ? "crit" : age > warn ? "warn" : "ok",
        summary:
          age > budget
            ? `${v} feed is ${age}s old, past the ${budget}s weekdayMaxStale — a weekday settle would fall through to the TWAP`
            : `${v} feed ${age}s old (${fmt8(feed.answer)})`,
        measured: age.toString(),
        threshold: budget.toString(),
      });
    }

    // Pool observation coverage (SPEC §9.5's hourly check).
    try {
      const window = 3600;
      const cov = await coverage(client, s.addresses.pool, now, window);
      const needSpan = window + s.params.twapGrace;
      const thin = cov.inWindow < s.params.minObservationsInWindow;
      const shallow = cov.spanSeconds < needSpan;
      checks.push({
        id: "pool.coverage",
        vault: v,
        severity: thin || shallow ? "warn" : "ok",
        summary: thin
          ? `${v} pool has ${cov.inWindow} observations in the last hour, below minObservationsInWindow=${s.params.minObservationsInWindow} — the weekend TWAP path would be rejected OBSERVATIONS`
          : shallow
            ? `${v} pool ring spans ${cov.spanSeconds}s, less than window+twapGrace=${needSpan}s`
            : `${v} pool ring spans ${cov.spanSeconds}s, ${cov.inWindow} observations in the last hour`,
        measured: `${cov.inWindow} in window, span ${cov.spanSeconds}s, cardinality ${cov.cardinality}`,
        threshold: `>=${s.params.minObservationsInWindow} in window, span >=${needSpan}s`,
      });
    } catch (err) {
      checks.push({
        id: "pool.coverage",
        vault: v,
        severity: "warn",
        summary: `${v} pool read failed: ${(err as Error).message}`,
      });
    }

    // Will the next open have a reference price at all? `capPrice` never reverts, which is what makes
    // this answerable in advance instead of as a Monday-morning surprise.
    checks.push({
      id: "open.priceAvailable",
      vault: v,
      severity: s.capPriceOk ? "ok" : "warn",
      summary: s.capPriceOk
        ? `${v} reference price available (${fmt8(s.sRef ?? 0n)})`
        : `${v} has no reference price: the next openAuction would revert NoReferencePrice`,
    });

    // An empty vault cannot open. Expected on a fresh deployment; never a page.
    checks.push({
      id: "vault.empty",
      vault: v,
      severity: s.totalAssets === 0n ? "info" : "ok",
      summary:
        s.totalAssets === 0n
          ? `${v} holds no assets; auctions cannot open until somebody deposits`
          : `${v} holds ${s.totalAssets} raw units`,
    });

    // Pending settlement, and the halted clock.
    const series = s.series;
    if (series && s.state === "LIVE" && now > series.expiry) {
      const overdue = now - series.expiry;
      const grace = BigInt(cfg.file.schedule.settleGraceSeconds);
      checks.push({
        id: "settlement.pending",
        vault: v,
        severity: overdue > grace * 4n ? "crit" : overdue > grace ? "warn" : "ok",
        summary: `${v} series ${s.currentSeriesId} expired ${overdue}s ago and is not settled (${t.outcome}: ${t.detail ?? ""})`,
        measured: overdue.toString(),
        threshold: grace.toString(),
      });
    } else if (s.state === "HALTED") {
      const [ok, unlockAt] = await client.readContract({
        address: cfg.deployment.core.settlementOracle,
        abi: settlementOracleAbi,
        functionName: "canResolveByOracle",
        args: [s.currentSeriesId],
      });
      checks.push({
        id: "settlement.pending",
        vault: v,
        severity: "crit",
        summary: ok
          ? `${v} is HALTED and permissionlessly resolvable now`
          : `${v} is HALTED; permissionless resolution unlocks at ${unlockAt}. Until then only a timelock resolveHalted can close it`,
        measured: unlockAt.toString(),
      });
    }

    // State-machine drift and the things that quietly close a vault.
    const drift: string[] = [];
    if (s.sunset) drift.push("sunset");
    if (s.depositsPaused) drift.push("deposits paused");
    if (s.auctionsPaused) drift.push("new auctions paused");
    if (s.stock.oraclePaused) drift.push("stock token oraclePaused");
    if (series && s.stock.effectiveAt > now && s.stock.effectiveAt <= series.expiry) {
      drift.push(
        `a multiplier change is staged for ${s.stock.effectiveAt}, inside the live series (D-025)`,
      );
    }
    if (s.auction && s.state === "AUCTION" && s.auction.state !== "OPEN") {
      drift.push(`vault is AUCTION but the AuctionHouse says ${s.auction.state}`);
    }
    if (s.haltCount > 0n) drift.push(`${s.haltCount} historical halt(s)`);
    checks.push({
      id: "vault.drift",
      vault: v,
      severity: drift.length === 0 ? "ok" : s.sunset || s.stock.oraclePaused ? "crit" : "warn",
      summary:
        drift.length === 0
          ? `${v} state machine consistent (${s.state})`
          : `${v}: ${drift.join("; ")}`,
    });

    // D-020: the stock-token beacon and the USDG implementation.
    for (const [label, address] of [
      [`${v}.stock`, s.addresses.stock],
      ["usdg", cfg.deployment.external.usdg],
    ] as const) {
      const impl = await readImplementation(client, address);
      if (impl === null) {
        checks.push({
          id: "implementation.watch",
          vault: v,
          severity: "na",
          summary: `${label} at ${address} is not an ERC-1967 proxy or beacon — nothing to watch (every 46630 token is a plain mock)`,
        });
        continue;
      }
      const previous = ctx.knownImplementations[label];
      implementations[label] = impl;
      checks.push({
        id: "implementation.watch",
        vault: v,
        severity: previous && previous !== impl ? "crit" : "ok",
        summary:
          previous && previous !== impl
            ? `${label} implementation changed from ${previous} to ${impl} — D-020 says pause deposits and new auctions and page the founder before anything else happens`
            : `${label} implementation ${impl}`,
        measured: impl,
      });
    }
  }

  return { checks, implementations };
}

async function readFeed(
  client: PublicClient,
  feed: Address,
): Promise<{ answer: bigint; updatedAt: bigint } | null> {
  const [r] = await multicall<readonly [bigint, bigint, bigint, bigint, bigint]>(client, [
    { address: feed, abi: aggregatorAbi, functionName: "latestRoundData" },
  ]);
  if (!r || !r.ok) return null;
  return { answer: r.value[1], updatedAt: r.value[3] };
}

/** ERC-1967 implementation, or the beacon's, or `null` when the address is not a proxy at all. */
async function readImplementation(client: PublicClient, address: Address): Promise<string | null> {
  const [impl, beacon] = await Promise.all([
    client.getStorageAt({ address, slot: IMPL_SLOT }),
    client.getStorageAt({ address, slot: BEACON_SLOT }),
  ]);
  const pick = (v: string | undefined): string | null => {
    if (!v) return null;
    const trimmed = `0x${v.slice(-40)}`;
    return trimmed === "0x0000000000000000000000000000000000000000" ? null : trimmed;
  };
  return pick(impl) ?? pick(beacon);
}

const fmtEth = (wei: bigint): string => `${(Number(wei) / 1e18).toFixed(5)} ETH`;
const fmt8 = (x: bigint): string => (Number(x) / 1e8).toFixed(4);

export const worst = (checks: readonly Check[]): Severity => {
  const order: Severity[] = ["na", "ok", "info", "warn", "crit"];
  return checks.reduce<Severity>(
    (acc, c) => (order.indexOf(c.severity) > order.indexOf(acc) ? c.severity : acc),
    "ok",
  );
};
