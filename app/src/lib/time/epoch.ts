/**
 * Epoch-week arithmetic, mirroring `contracts/src/AuctionHouse.sol` exactly (port of keeper/src/time/epoch.ts).
 *
 * Unix epoch 0 is a Thursday, so `t - (t % 604800)` is Thursday 00:00 UTC and every offset below is
 * measured from there. Inside one epoch week Friday is day 1 and Monday is day 4, so a Monday's Friday
 * expiry is in the *next* epoch week while a Friday's Sunday expiry is in the *same* one.
 */

export const WEEK = 604_800n;
export const MON_1400 = 396_000n;
export const FRI_1930 = 156_600n;
export const FRI_2000 = 158_400n; // weekday expiry under EDT; 21:00 UTC (162 000) under EST
export const FRI_2130 = 163_800n;
export const SUN_2359 = 345_540n;
export const WEEKEND_GAP = 600n;
export const AUCTION_DURATION = 900n;
export const MAX_WEEKEND_LATE = 7_200n; // 2 hours
export const MAX_OPEN_TOLERANCE = 14_400n; // 4 hours

/** Thursday 00:00 UTC of the epoch week containing `t`. */
export const weekStart = (t: bigint): bigint => t - (t % WEEK);

/** Seconds since Thursday 00:00 UTC. */
export const weekOffset = (t: bigint): bigint => t % WEEK;

/** The next Monday 14:00 UTC at or after `t`. */
export function nextMonday1400(t: bigint): bigint {
  const m = weekStart(t) + MON_1400;
  return m >= t ? m : m + WEEK;
}

/** The next Friday 20:10 UTC (the weekend-auction opening instant under EDT) at or after `t`. */
export function nextWeekendOpen(t: bigint): bigint {
  const f = weekStart(t) + FRI_2000 + WEEKEND_GAP;
  return f >= t ? f : f + WEEK;
}

/** Sunday 23:59:00 UTC for a series whose weekday expiry was `fridayExpiry`. */
export const weekendExpiryFor = (fridayExpiry: bigint): bigint =>
  weekStart(fridayExpiry) + SUN_2359;

/** Friday expiry (20:00 UTC, EDT convention) of the epoch week *after* the one containing `t`. */
export const weekdayExpiryAfter = (t: bigint): bigint => weekStart(t) + WEEK + FRI_2000;
