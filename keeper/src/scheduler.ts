import type { PublicClient } from "viem";
import { auctionHouseAbi, WEEKDAY, WEEKEND, kindName, type SeriesKind } from "./abi/index.js";
import { chainNow } from "./chain/clients.js";
import type { Sender } from "./chain/tx.js";
import type { ResolvedConfig, VaultConfig } from "./config.js";
import { clearAuction, flushFees, processQueues, releaseLocks } from "./jobs/clear.js";
import { retryOpenKind } from "./jobs/clearWindow.js";
import { openAuction, planOpen } from "./jobs/openAuction.js";
import { resolveIfPossible, settleSeries } from "./jobs/settle.js";
import type { Logger } from "./logger.js";
import { readVault, type VaultSnapshot } from "./protocol.js";
import type { StateDir } from "./state.js";
import {
  AUCTION_DURATION,
  describe,
  inWeekdayOpenWindow,
  inWeekendOpenWindow,
} from "./time/epoch.js";
import { weekdayExpiryFor, weekendExpiryAt } from "./jobs/openAuction.js";

/**
 * The tick.
 *
 * Deliberately *not* a set of cron callbacks that each own a deadline. Every tick re-derives, from
 * chain state and epoch-week arithmetic, what is due right now, and fires it. A missed tick, a restart,
 * a clock skew or an RPC outage costs nothing but latency, and idempotency is a property of the
 * contract rather than of anything the keeper remembers: a second `openAuction` inside the 2-hour
 * tolerance window is refused `NOT_IDLE`, a second `clear` `WrongAuctionState`, a second `settle`
 * `NOT_LIVE` — and each is caught at simulate, before a transaction is signed.
 *
 * `now` is chain time, never `Date.now()`. Every contract check is against `block.timestamp`, so
 * reasoning in wall time would mean reasoning in the wrong units — and it is what lets the fork harness
 * drive a whole week through this same code by warping the chain.
 */

export interface ActionRecord {
  at: string;
  vault: string;
  action: string;
  outcome: string;
  detail?: string;
}

export interface TickResult {
  now: bigint;
  vaults: VaultTickResult[];
  actions: ActionRecord[];
}

export interface VaultTickResult {
  snapshot: VaultSnapshot;
  due: string;
  outcome: string;
  detail?: string;
  nextEvents: { what: string; at: bigint }[];
}

export class Scheduler {
  private readonly recent: ActionRecord[] = [];
  private openTolerance: bigint | null = null;

  constructor(
    private readonly cfg: ResolvedConfig,
    private readonly client: PublicClient,
    private readonly sender: Sender,
    private readonly state: StateDir,
    private readonly log: Logger,
  ) {}

  get recentActions(): readonly ActionRecord[] {
    return this.recent;
  }

  private record(rec: ActionRecord): void {
    this.recent.unshift(rec);
    if (this.recent.length > 50) this.recent.length = 50;
  }

  private async tolerance(): Promise<bigint> {
    if (this.openTolerance === null) {
      this.openTolerance = await this.client.readContract({
        address: this.cfg.deployment.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "openTolerance",
      });
    }
    return this.openTolerance;
  }

  async tick(vaults: { symbol: string; vault: VaultConfig }[]): Promise<TickResult> {
    const now = await chainNow(this.client);
    const results: VaultTickResult[] = [];
    const actions: ActionRecord[] = [];

    for (const { symbol, vault } of vaults) {
      const addresses = this.cfg.deployment.vaults.find((v) => v.symbol === symbol);
      if (!addresses) continue;
      const snapshot = await readVault(this.client, this.cfg.deployment, addresses, symbol);
      const before = this.recent.length;
      const r = await this.stepVault(snapshot, vault, now);
      results.push(r);
      actions.push(...this.recent.slice(0, this.recent.length - before));
    }

    return { now, vaults: results, actions };
  }

  private async stepVault(
    snapshot: VaultSnapshot,
    vaultCfg: VaultConfig,
    now: bigint,
  ): Promise<VaultTickResult> {
    const { deployment, file } = this.cfg;
    const settleOnly = file.role === "settle-only";
    const nextEvents = this.nextEvents(snapshot, now);
    const done = (due: string, outcome: string, detail?: string): VaultTickResult => ({
      snapshot,
      due,
      outcome,
      detail,
      nextEvents,
    });
    const at = now.toString();

    // Housekeeping that applies in any state, and never blocks the main transition.
    if (!settleOnly) await this.housekeeping(snapshot, now);

    switch (snapshot.state) {
      case "AUCTION": {
        if (settleOnly) return done("clear", "skipped: settle-only instance");
        const a = snapshot.auction;
        if (!a) return done("clear", "waiting", "auction record not readable yet");
        const readyAt = a.auctionClose + BigInt(file.schedule.clearDelaySeconds);
        if (now < readyAt) {
          return done(
            "clear",
            "waiting",
            `auction closes at ${a.auctionClose} (${describe(a.auctionClose)})`,
          );
        }
        const { result, willSkip } = await clearAuction({
          client: this.client,
          sender: this.sender,
          auctionHouse: deployment.core.auctionHouse,
          snapshot,
          seriesId: snapshot.currentSeriesId,
          log: this.log,
        });
        const outcome =
          result.status === "failed"
            ? `failed: ${result.error.text}`
            : willSkip
              ? "skipped"
              : "cleared";
        this.record({ at, vault: snapshot.symbol, action: "clear", outcome });
        if (willSkip && result.status !== "failed" && !settleOnly) {
          // REHEARSAL-1 S-1: a SKIPPED series hands the vault back IDLE. `canOpen` (D-046) accepts another
          // open anywhere inside the same window, so re-open now instead of losing the week to one skip.
          const kind = retryOpenKind(now, await this.tolerance());
          if (kind !== null) {
            const fresh = await readVault(
              this.client,
              deployment,
              snapshot.addresses,
              snapshot.symbol,
            );
            if (fresh.state === "IDLE") {
              const retry = await this.tryOpen(fresh, vaultCfg, kind, now, at, "retry after skip");
              return done("clear", `${outcome}; re-open ${retry.outcome}`, retry.detail);
            }
          }
        }
        return done("clear", outcome);
      }

      case "LIVE": {
        const series = snapshot.series;
        if (!series) return done("settle", "waiting", "series not readable yet");
        if (now < series.expiry) {
          return done(
            "settle",
            "waiting",
            `expires at ${series.expiry} (${describe(series.expiry)})`,
          );
        }
        const out = await settleSeries({
          client: this.client,
          sender: this.sender,
          oracle: deployment.core.settlementOracle,
          snapshot,
          seriesId: snapshot.currentSeriesId,
          log: this.log,
        });
        this.record({
          at,
          vault: snapshot.symbol,
          action: "settle",
          outcome: out.kind,
          detail: describeOutcome(out),
        });
        return done("settle", out.kind, describeOutcome(out));
      }

      case "HALTED": {
        const out = await resolveIfPossible({
          client: this.client,
          sender: this.sender,
          oracle: deployment.core.settlementOracle,
          snapshot,
          seriesId: snapshot.currentSeriesId,
          log: this.log,
        });
        if (out.kind !== "waiting") {
          this.record({
            at,
            vault: snapshot.symbol,
            action: "resolve",
            outcome: out.kind,
            detail: describeOutcome(out),
          });
        }
        return done("resolve", out.kind, describeOutcome(out));
      }

      case "IDLE": {
        if (settleOnly) return done("open", "skipped: settle-only instance");
        const kind = await this.openKindDue(snapshot, now);
        if (kind === null) return done("open", "waiting", "outside every opening window");
        const r = await this.tryOpen(snapshot, vaultCfg, kind, now, at);
        return done("open", r.outcome, r.detail);
      }

      default:
        return done("none", "idle");
    }
  }

  /** Plan and send one `openAuction`; the IDLE step and the post-skip retry share it. */
  private async tryOpen(
    snapshot: VaultSnapshot,
    vaultCfg: VaultConfig,
    kind: SeriesKind,
    now: bigint,
    at: string,
    tag?: string,
  ): Promise<{ outcome: string; detail?: string }> {
    const { deployment, file } = this.cfg;
    const plan = await planOpen({
      client: this.client,
      auctionHouse: deployment.core.auctionHouse,
      snapshot,
      vaultCfg,
      file,
      kind,
      now,
      state: this.state,
      log: this.log,
    });
    if (!plan.ok) {
      // "NO_ASSETS" on a fresh vault is the expected state, not an incident.
      const level = plan.reason === "NO_ASSETS" ? "info" : "warn";
      this.log[level](
        { vault: snapshot.symbol, kind: kindName(kind), reason: plan.reason, tag },
        "cannot open this cycle",
      );
      return { outcome: "blocked", detail: plan.reason };
    }
    const result = await openAuction({
      sender: this.sender,
      auctionHouse: deployment.core.auctionHouse,
      snapshot,
      plan: plan.plan,
      deploymentVaults: deployment.vaults.map((v) => v.vault),
      log: this.log,
    });
    const outcome = result.status === "failed" ? `failed: ${result.error.text}` : result.status;
    const detail =
      `strike ${plan.plan.strike} reserve ${plan.plan.reserve.reservePrice} ` +
      `(${plan.plan.reserve.decidedBy}; sigma ${plan.plan.vol.sigma.toFixed(4)} ${plan.plan.vol.source}, ` +
      `model ${plan.plan.reserve.modelPrice} vs floor ${plan.plan.reserve.lo})`;
    this.record({
      at,
      vault: snapshot.symbol,
      action: `openAuction ${kindName(kind)}${tag ? ` (${tag})` : ""}`,
      outcome,
      detail,
    });
    return { outcome, detail };
  }

  /** Which opening window, if any, `now` sits in. Mirrors `AuctionHouse.canOpen`'s two branches. */
  private async openKindDue(snapshot: VaultSnapshot, now: bigint): Promise<SeriesKind | null> {
    const tol = await this.tolerance();
    if (inWeekdayOpenWindow(now, tol)) return WEEKDAY;
    if (inWeekendOpenWindow(now, tol)) return WEEKEND;
    return null;
  }

  /** Queue processing, bond-lock release and fee flush. Each is permissionless and gated by simulate. */
  private async housekeeping(snapshot: VaultSnapshot, now: bigint): Promise<void> {
    const at = now.toString();
    try {
      if (
        snapshot.state === "IDLE" &&
        (snapshot.queue.deposits > 0n || snapshot.queue.redeems > 0n)
      ) {
        await processQueues({
          sender: this.sender,
          snapshot,
          opsPerCall: this.cfg.file.schedule.queueOpsPerCall,
          log: this.log,
        });
        this.record({ at, vault: snapshot.symbol, action: "processQueues", outcome: "sent" });
      }

      const s = snapshot.series;
      const settled = s && (s.state === "SETTLED" || s.state === "RESOLVED");
      if (settled && snapshot.currentSeriesId > 0n) {
        const marker = `released-${snapshot.symbol}.json`;
        const seen = this.state.readJson<{ seriesId: string }>(marker);
        if (seen?.seriesId !== snapshot.currentSeriesId.toString()) {
          const r = await releaseLocks({
            sender: this.sender,
            auctionHouse: this.cfg.deployment.core.auctionHouse,
            snapshot,
            seriesId: snapshot.currentSeriesId,
          });
          if (r.status !== "failed") {
            this.state.writeJson(marker, { seriesId: snapshot.currentSeriesId.toString() });
            this.record({ at, vault: snapshot.symbol, action: "releaseLocks", outcome: r.status });
          }
        }
      }

      const flushed = await flushFees({
        client: this.client,
        sender: this.sender,
        feeRouter: this.cfg.deployment.core.feeRouter,
        snapshot,
        log: this.log,
      });
      if (flushed)
        this.record({ at, vault: snapshot.symbol, action: "flush", outcome: flushed.status });
    } catch (err) {
      // Housekeeping must never take the tick down: the lifecycle transitions matter more.
      this.log.warn(
        { vault: snapshot.symbol, err: (err as Error).message },
        "housekeeping failed this tick",
      );
    }
  }

  /** What the frontend and the status file show as "next". Pure arithmetic, no RPC. */
  private nextEvents(snapshot: VaultSnapshot, now: bigint): { what: string; at: bigint }[] {
    const out: { what: string; at: bigint }[] = [];
    if (snapshot.state === "AUCTION" && snapshot.auction) {
      out.push({ what: "clear", at: snapshot.auction.auctionClose });
      out.push({ what: "expiry", at: snapshot.auction.expiry });
    } else if (snapshot.state === "LIVE" && snapshot.series) {
      out.push({ what: "settle", at: snapshot.series.expiry });
      if (snapshot.series.kind === WEEKDAY) {
        out.push({ what: "openWeekend", at: snapshot.series.expiry + 600n });
      }
    } else if (snapshot.state === "IDLE") {
      const weekday = weekdayExpiryFor(now);
      out.push({ what: "weekdayExpiryIfOpenedNow", at: weekday });
      out.push({ what: "weekendExpiryIfOpenedNow", at: weekendExpiryAt(now) });
      out.push({ what: "auctionCloseIfOpenedNow", at: now + AUCTION_DURATION });
    }
    return out;
  }
}

function describeOutcome(out: {
  kind: string;
  reason?: string;
  detail?: string;
  path?: number;
}): string {
  const bits = [out.reason, out.detail].filter(Boolean);
  if (out.path !== undefined) bits.unshift(`path ${out.path}`);
  return bits.join(" — ");
}
