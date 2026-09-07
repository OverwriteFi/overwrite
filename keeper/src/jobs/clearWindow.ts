import { WEEKDAY, WEEKEND, type SeriesKind } from "../abi/index.js";
import {
  inWeekdayOpenWindow,
  inWeekendOpenWindow,
  MON_1400,
  WEEKEND_GAP,
  weekOffset,
  weekStart,
} from "../time/epoch.js";
import { fridayCloseUtc } from "../time/nyse.js";

/**
 * The clearing window and what to do when it is missed (REHEARSAL-1 S-1, D-113 F-2).
 *
 * Since the audit `AuctionHouse.clear` takes the skip path once `auctionClose + clearGrace` has passed:
 * every bid is refunded, the series is SKIPPED and the vault is IDLE again. Two consequences for the
 * keeper, both pure functions here so they can be tested without a chain:
 *
 *  - a clear that is *about* to miss the window is an alert, not a log line (`clearWindowSeverity`);
 *  - a SKIPPED series is not the end of the week. `AuctionHouse.canOpen` (D-046) accepts another
 *    `openAuction` anywhere inside the same opening window, so after a skip the keeper re-opens at once
 *    instead of waiting for the next window (`retryOpenKind`).
 */

/** Seconds before the deadline at which the alert goes to WARN. */
export const CLEAR_WARN_BEFORE = 900n;

export const clearDeadline = (auctionClose: bigint, clearGrace: bigint): bigint =>
  auctionClose + clearGrace;

export type ClearWindowSeverity = "ok" | "warn" | "crit";

/**
 * `ok` while more than `warnBefore` seconds of the window remain, `warn` inside the last `warnBefore`
 * seconds, `crit` once the deadline has passed (the next `clear` will skip the series). Before
 * `auctionClose` the window has not started and the answer is `ok`.
 */
export function clearWindowSeverity(
  now: bigint,
  auctionClose: bigint,
  clearGrace: bigint,
  warnBefore: bigint = CLEAR_WARN_BEFORE,
): ClearWindowSeverity {
  const deadline = clearDeadline(auctionClose, clearGrace);
  if (now >= deadline) return "crit";
  if (now + warnBefore >= deadline) return "warn";
  return "ok";
}

/** Seconds left to clear before the skip path; 0 once passed. */
export function clearSecondsLeft(now: bigint, auctionClose: bigint, clearGrace: bigint): bigint {
  const deadline = clearDeadline(auctionClose, clearGrace);
  return now >= deadline ? 0n : deadline - now;
}

/* ───────────────────────────── the scheduled open ───────────────────────────── */

/**
 * `AuctionHouse.canOpen` accepts a WEEKDAY open anywhere in Monday 14:00 ± `openTolerance`, but that
 * symmetry is the contract's allowance for a *late* keeper (a Sunday settlement that runs past 14:00,
 * SPEC §9.4), not a licence to open early. SPEC §5 (a) says 14:00:00, the mm-kit says 14:00, and a
 * market maker who set an alarm for 14:00 must not find the book already closed. So the keeper opens at
 * the scheduled instant or after it, never before: the early half of the window is unused on purpose.
 */
export function weekdayOpenDue(now: bigint, openTolerance: bigint): boolean {
  const off = weekOffset(now);
  return off >= MON_1400 && off - MON_1400 <= openTolerance;
}

/**
 * The WEEKEND opening instant for the week containing `now` (SPEC §5 (d)): 600 s after the weekday
 * expiry when this week had a weekday series, else 600 s after the Friday close — the two agree unless
 * the keeper opened the weekday series with a non-default expiry inside the [19:30, 21:30] band. The
 * Friday close is DST-aware (`fridayCloseUtc`), so this is 20:10 UTC under EDT and 21:10 under EST.
 */
export function weekendOpenAt(now: bigint, lastWeekdayExpiry: bigint | null = null): bigint {
  const ws = weekStart(now);
  const base =
    lastWeekdayExpiry !== null && weekStart(lastWeekdayExpiry) === ws
      ? lastWeekdayExpiry
      : fridayCloseUtc(ws);
  return base + WEEKEND_GAP;
}

/** WEEKEND open is due from `scheduledAt` for as long as the contract's window still admits it. */
export function weekendOpenDue(now: bigint, openTolerance: bigint, scheduledAt: bigint): boolean {
  return now >= scheduledAt && inWeekendOpenWindow(now, openTolerance);
}

/**
 * Which series kind the schedule says to open right now, or `null`. Unlike the contract's `canOpen`
 * this is one-sided: at or after the scheduled instant, up to `openTolerance` late.
 */
export function scheduledOpenKind(
  now: bigint,
  openTolerance: bigint,
  weekendScheduledAt: bigint,
): SeriesKind | null {
  if (weekdayOpenDue(now, openTolerance)) return WEEKDAY;
  if (weekendOpenDue(now, openTolerance, weekendScheduledAt)) return WEEKEND;
  return null;
}

/**
 * Which series kind can be re-opened right after a skip, given chain time, the AuctionHouse's
 * `openTolerance` and how many bids the skipped series had.
 *
 * The retry exists for REHEARSAL-1 S-1: bids were on the book and a *late clear* threw them away, so
 * re-opening inside the same window gives those bidders a second chance at the week. It is not for an
 * empty book. With no bid at all, a fresh series 15 minutes later has the same empty book and the same
 * outcome, and on the 46630 demo that loop burnt 24 series ids in one Monday window. So `bidCount === 0`
 * is `null`: the week's series is simply skipped, as SPEC §5 says, and the next open is the next
 * scheduled one. With bids, the same two window tests `canOpen` applies decide — a `WEEKDAY` skipped
 * at 14:20 is re-opened at 14:20, and a skip after the window closed (a Friday clear of Monday's
 * auction) yields `null`.
 */
export function retryOpenKind(
  now: bigint,
  openTolerance: bigint,
  bidCount: number,
): SeriesKind | null {
  if (bidCount <= 0) return null;
  if (inWeekdayOpenWindow(now, openTolerance)) return WEEKDAY;
  if (inWeekendOpenWindow(now, openTolerance)) return WEEKEND;
  return null;
}
