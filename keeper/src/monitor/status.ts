import { basename, dirname } from "node:path";
import type { ResolvedConfig } from "../config.js";
import { kindName } from "../abi/index.js";
import type { ActionRecord, TickResult } from "../scheduler.js";
import { StateDir, jsonBigint } from "../state.js";
import { expiryCalendarNote } from "../time/nyse.js";
import { worst, type Check, type Severity } from "./checks.js";

/**
 * `status.json` — the file the frontend reads and the operator greps.
 *
 * Contains an address and never a key: no private key, no RPC URL, nothing that could carry a
 * credential. Written atomically into its own directory (see StateDir.writeAtomic for why the temp file
 * cannot live in /tmp under a read-only rootfs).
 */

export const STATUS_SCHEMA_VERSION = 1;

export interface StatusFile {
  schemaVersion: number;
  generatedAt: string;
  chainId: number;
  label: string;
  role: string;
  dryRun: boolean;
  blockTimestamp: string;
  overall: Severity;
  keeper: { address: string };
  checks: Check[];
  vaults: StatusVault[];
  recentActions: ActionRecord[];
}

export interface StatusVault {
  symbol: string;
  address: string;
  state: string;
  totalAssets: string;
  freeAssets: string;
  payoutOwed: string;
  sunset: boolean;
  due: string;
  outcome: string;
  detail?: string;
  series: null | {
    id: string;
    kind: string;
    state: string;
    expiry: string;
    strike: string;
    offeredQty: string;
    filledQty: string;
    settlementPrice: string;
    settlementPath: number;
    calendarNote: string | null;
  };
  auction: null | {
    state: string;
    auctionOpen: string;
    auctionClose: string;
    sRef: string;
    reservePrice: string;
    clearingPrice: string;
  };
  nextEvents: { what: string; at: string }[];
}

export function buildStatus(args: {
  cfg: ResolvedConfig;
  tick: TickResult;
  checks: Check[];
  recentActions: readonly ActionRecord[];
  generatedAt: Date;
}): StatusFile {
  const { cfg, tick, checks, recentActions, generatedAt } = args;

  return {
    schemaVersion: STATUS_SCHEMA_VERSION,
    generatedAt: generatedAt.toISOString(),
    chainId: cfg.deployment.chainId,
    label: cfg.deployment.label,
    role: cfg.file.role,
    dryRun: cfg.env.DRY_RUN,
    blockTimestamp: tick.now.toString(),
    overall: worst(checks),
    keeper: { address: cfg.keeperAddress },
    checks,
    vaults: tick.vaults.map((t) => {
      const s = t.snapshot;
      return {
        symbol: s.symbol,
        address: s.addresses.vault,
        state: s.state,
        totalAssets: s.totalAssets.toString(),
        freeAssets: s.freeAssets.toString(),
        payoutOwed: s.payoutOwed.toString(),
        sunset: s.sunset,
        due: t.due,
        outcome: t.outcome,
        ...(t.detail ? { detail: t.detail } : {}),
        series: s.series
          ? {
              id: s.currentSeriesId.toString(),
              kind: kindName(s.series.kind),
              state: s.series.state,
              expiry: s.series.expiry.toString(),
              strike: s.series.strike.toString(),
              offeredQty: s.series.offeredQty.toString(),
              filledQty: s.series.filledQty.toString(),
              settlementPrice: s.series.settlementPrice.toString(),
              settlementPath: s.series.settlementPath,
              calendarNote: expiryCalendarNote(s.series.expiry),
            }
          : null,
        auction: s.auction
          ? {
              state: s.auction.state,
              auctionOpen: s.auction.auctionOpen.toString(),
              auctionClose: s.auction.auctionClose.toString(),
              sRef: s.auction.sRef.toString(),
              reservePrice: s.auction.reservePrice.toString(),
              clearingPrice: s.auction.clearingPrice.toString(),
            }
          : null,
        nextEvents: t.nextEvents.map((e) => ({ what: e.what, at: e.at.toString() })),
      };
    }),
    recentActions: [...recentActions],
  };
}

export function writeStatus(statusFile: string, status: StatusFile): void {
  const dir = new StateDir(dirname(statusFile));
  dir.writeAtomic(basename(statusFile), `${JSON.stringify(status, jsonBigint, 2)}\n`);
}
