import { WEEKDAY, WEEKEND, type SeriesKind } from "../abi/index.js";
import { inWeekdayOpenWindow, inWeekendOpenWindow } from "../time/epoch.js";

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

/**
 * Which series kind can be re-opened right after a skip, given chain time and the AuctionHouse's
 * `openTolerance` — the same two window tests `canOpen` applies, so a `WEEKDAY` skipped at 14:20 is
 * re-opened at 14:20, and a skip after the window closed (e.g. a Friday clear of Monday's auction)
 * yields `null`: nothing can be opened until the next window.
 */
export function retryOpenKind(now: bigint, openTolerance: bigint): SeriesKind | null {
  if (inWeekdayOpenWindow(now, openTolerance)) return WEEKDAY;
  if (inWeekendOpenWindow(now, openTolerance)) return WEEKEND;
  return null;
}
