import {
  AUCTION_DURATION,
  MAX_WEEKEND_LATE,
  WEEKEND_GAP,
  nextMonday1400,
  weekStart,
} from "./epoch";

/**
 * "What happens next for this vault" derived from state alone (D-108: derive, never remember).
 * All timestamps are unix seconds. Mirrors keeper/src/scheduler.ts's nextEvents at the granularity a
 * countdown needs.
 */

export type NextEventKind =
  | "auction-closes"
  | "clearing"
  | "expires"
  | "settlement-due"
  | "weekend-auction-opens"
  | "weekday-auction-opens"
  | "resolution"
  | "none";

export interface NextEvent {
  kind: NextEventKind;
  /** Unix seconds; 0 when there is nothing scheduled (sunset). */
  at: bigint;
  label: string;
}

export interface ScheduleInput {
  now: bigint;
  vaultState: "IDLE" | "AUCTION" | "LIVE" | "HALTED";
  sunset: boolean;
  auctionClose: bigint | null;
  expiry: bigint | null;
  /** `auctionHouse.lastWeekdayExpiry(vault)` — 0 before the first weekday series. */
  lastWeekdayExpiry: bigint;
  /** Kind + expiry of the current series, to tell whether this week's weekend series already ran. */
  currentKind: 0 | 1 | null;
  currentExpiry: bigint | null;
  haltedAt: bigint | null;
  haltedTimeout: bigint;
}

export function nextEvent(i: ScheduleInput): NextEvent {
  const { now } = i;
  switch (i.vaultState) {
    case "AUCTION": {
      const close = i.auctionClose ?? now + AUCTION_DURATION;
      return now < close
        ? { kind: "auction-closes", at: close, label: "Auction closes" }
        : { kind: "clearing", at: close, label: "Clearing" };
    }
    case "LIVE": {
      const exp = i.expiry ?? now;
      return now < exp
        ? { kind: "expires", at: exp, label: "Series expires" }
        : { kind: "settlement-due", at: exp, label: "Settlement due" };
    }
    case "HALTED": {
      const at = (i.haltedAt ?? now) + i.haltedTimeout;
      return { kind: "resolution", at, label: "Permissionless resolution opens" };
    }
    case "IDLE":
    default: {
      if (i.sunset) return { kind: "none", at: 0n, label: "Vault is sunset" };
      // Between a weekday settlement and its weekend auction (10 min gap, up to 2 h late), the next
      // event is the weekend auction — unless this week's weekend series already ran.
      const lw = i.lastWeekdayExpiry;
      if (lw > 0n) {
        const weekendOpen = lw + WEEKEND_GAP;
        const latest = weekendOpen + MAX_WEEKEND_LATE;
        const weekendDone =
          i.currentKind === 1 && i.currentExpiry !== null && weekStart(i.currentExpiry) === weekStart(lw);
        if (!weekendDone && now >= lw && now <= latest) {
          return {
            kind: "weekend-auction-opens",
            at: weekendOpen > now ? weekendOpen : now,
            label: "Weekend auction opens",
          };
        }
      }
      return { kind: "weekday-auction-opens", at: nextMonday1400(now), label: "Weekday auction opens" };
    }
  }
}
