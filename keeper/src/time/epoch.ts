/**
 * Epoch-week arithmetic, mirroring `contracts/src/AuctionHouse.sol:44-64` exactly.
 *
 * Unix epoch 0 is a Thursday, so `t - (t % 604800)` is Thursday 00:00 UTC and every offset below is
 * measured from there. The consequence that trips people up: inside one epoch week Friday is day 1 and
 * Monday is day 4, so a Monday's Friday expiry is in the *next* epoch week while a Friday's Sunday
 * expiry is in the *same* one. `AuctionHouse.canOpen` relies on precisely that.
 *
 * These are asserted against the deployed contract's own constants in test/epoch.test.ts.
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

/** Friday 00:00 UTC of the epoch week containing `t`. */
export const fridayMidnight = (t: bigint): bigint => weekStart(t) + 86_400n;

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

/**
 * Sunday 23:59:00 UTC for a series whose weekday expiry was `fridayExpiry`.
 *
 * Derived from the *Friday's* epoch week, never from a Monday: Monday is day 4 of its week, so
 * `weekStart(monday) + SUN_2359` is the Sunday that has already gone. The deployed
 * `scheduledExpiry(WEEKEND, mondayTs)` has the same shape and returns the same past value — this helper
 * exists so the keeper never asks it that question.
 */
export const weekendExpiryFor = (fridayExpiry: bigint): bigint =>
  weekStart(fridayExpiry) + SUN_2359;

/** `AuctionHouse.canOpen`'s weekday window test, so the scheduler can answer it without an RPC call. */
export function inWeekdayOpenWindow(at: bigint, openTolerance: bigint): boolean {
  const off = weekOffset(at);
  const diff = off > MON_1400 ? off - MON_1400 : MON_1400 - off;
  return diff <= openTolerance;
}

/** `AuctionHouse.canOpen`'s weekend window test. */
export function inWeekendOpenWindow(at: bigint, openTolerance: bigint): boolean {
  const late = openTolerance < MAX_WEEKEND_LATE ? openTolerance : MAX_WEEKEND_LATE;
  const off = weekOffset(at);
  return off >= FRI_1930 + WEEKEND_GAP && off <= FRI_2130 + WEEKEND_GAP + late;
}

/** Whether an expiry satisfies the contract's weekday band for an auction opening at `at`. */
export function weekdayExpiryInBand(expiry: bigint, at: bigint): boolean {
  const fri = weekStart(at) + WEEK;
  return expiry >= fri + FRI_1930 && expiry <= fri + FRI_2130;
}

const DAYS = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"] as const;

/** `1789156800` → `"Fri 20:00:00 UTC (off 158400)"`. Log-only. */
export function describe(t: bigint): string {
  const off = Number(weekOffset(t));
  const day = DAYS[Math.floor(off / 86_400)] ?? "???";
  const s = off % 86_400;
  const hh = String(Math.floor(s / 3600)).padStart(2, "0");
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return `${day} ${hh}:${mm}:${ss} UTC (off ${off})`;
}

/** ISO-8601 for a unix second count. Log-only. */
export const iso = (t: bigint): string =>
  new Date(Number(t) * 1000).toISOString().replace(".000Z", "Z");
