/**
 * NYSE close in UTC, and the 2026/2027 exchange calendar.
 *
 * SPEC §5's fixed-timestamp rule: expiry never moves for a holiday or an early close. It is always
 * 16:00 America/New_York on the Friday — 20:00 UTC under EDT, 21:00 UTC under EST — and the contract
 * enforces `expiry ∈ [Fri 19:30, Fri 21:30] UTC`, which a 13:00 ET half-day close (18:00 UTC) could not
 * satisfy even if we wanted it to. So the calendar below drives **alerts only**: it tells the operator
 * that a given week's settlement price will be Thursday's last round (full holiday) or a post-market
 * print (early close), neither of which is a fault.
 *
 * DST comes from the runtime's own tz database via Intl — Node 22 ships full ICU, verified to report
 * GMT-4/GMT-5 correctly across both 2026 transitions. No date library.
 */

const NY = "America/New_York";

const partsFmt = new Intl.DateTimeFormat("en-US", {
  timeZone: NY,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

function nyParts(unixSeconds: bigint): {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
} {
  const parts = partsFmt.formatToParts(new Date(Number(unixSeconds) * 1000));
  const get = (t: Intl.DateTimeFormatPartTypes): number => {
    const p = parts.find((x) => x.type === t);
    if (!p) throw new Error(`Intl did not return a ${t} part for ${NY}`);
    return Number(p.value);
  };
  return {
    y: get("year"),
    mo: get("month"),
    d: get("day"),
    h: get("hour"),
    mi: get("minute"),
    s: get("second"),
  };
}

/** UTC offset of America/New_York at `unixSeconds`, in seconds (−14400 EDT, −18000 EST). */
export function nyOffsetSeconds(unixSeconds: bigint): number {
  const p = nyParts(unixSeconds);
  const asIfUtc = Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s) / 1000;
  return asIfUtc - Number(unixSeconds);
}

/** `"2026-09-11"` for the New York calendar date containing `unixSeconds`. */
export function nyDate(unixSeconds: bigint): string {
  const p = nyParts(unixSeconds);
  return `${p.y}-${String(p.mo).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`;
}

/**
 * The UTC instant at which New York local time is `hour:00:00` on the UTC calendar day containing
 * `utcMidnight`. Two passes: guess with the offset at a probe instant, then re-solve with the offset at
 * the guess, which converges for any transition that is not itself inside the trading day (US DST
 * changes happen at 02:00 local on a Sunday, so a Friday 16:00 target never straddles one).
 */
export function nyLocalTimeUtc(utcMidnight: bigint, hour: number, minute = 0): bigint {
  const target = BigInt(hour) * 3600n + BigInt(minute) * 60n;
  let t = utcMidnight + target + 4n * 3600n; // probe: assume EDT
  for (let i = 0; i < 2; i++) {
    t = utcMidnight + target - BigInt(nyOffsetSeconds(t));
  }
  return t;
}

/**
 * 16:00 ET on the Friday of the epoch week starting at `weekStartThursday`.
 * Verified against the deployed `AuctionHouse.scheduledExpiry(WEEKDAY, ·)`.
 */
export const fridayCloseUtc = (weekStartThursday: bigint): bigint =>
  nyLocalTimeUtc(weekStartThursday + 86_400n, 16);

/* ────────────────────────── exchange calendar ────────────────────────── */

/**
 * Full-day NYSE closures. Source: https://www.nyse.com/markets/hours-calendars, and SPEC §1.9 for the
 * subset the schedule actually cares about (the Fridays).
 *
 * This table has an expiry date of its own — see `CALENDAR_KNOWN_THROUGH` and the `nyse.calendar`
 * health check, which warns before the keeper starts silently treating unknown holidays as normal days.
 */
export const NYSE_HOLIDAYS: readonly string[] = [
  // 2026
  "2026-01-01", // New Year's Day (Thu)
  "2026-01-19", // MLK Jr. Day (Mon)
  "2026-02-16", // Washington's Birthday (Mon)
  "2026-04-03", // Good Friday                          ← Friday
  "2026-05-25", // Memorial Day (Mon)
  "2026-06-19", // Juneteenth                           ← Friday
  "2026-07-03", // Independence Day observed            ← Friday
  "2026-09-07", // Labor Day (Mon)
  "2026-11-26", // Thanksgiving (Thu)
  "2026-12-25", // Christmas                            ← Friday
  // 2027
  "2027-01-01", // New Year's Day                       ← Friday
  "2027-01-18", // MLK Jr. Day (Mon)
  "2027-02-15", // Washington's Birthday (Mon)
  "2027-03-26", // Good Friday                          ← Friday
  "2027-05-31", // Memorial Day (Mon)
  "2027-06-18", // Juneteenth observed                  ← Friday
  "2027-07-05", // Independence Day observed (Mon)
  "2027-09-06", // Labor Day (Mon)
  "2027-11-25", // Thanksgiving (Thu)
  "2027-12-24", // Christmas observed                   ← Friday
];

/** Sessions closing at 13:00 ET instead of 16:00. */
export const NYSE_EARLY_CLOSES: readonly string[] = [
  "2026-11-27", // day after Thanksgiving               ← Friday (SPEC §1.9)
  "2026-12-24", // Christmas Eve (Thu)
  "2027-11-26", // day after Thanksgiving               ← Friday
];

/** The last date the two tables above are known to be complete for. */
export const CALENDAR_KNOWN_THROUGH = "2027-12-31";

const holidaySet = new Set(NYSE_HOLIDAYS);
const earlySet = new Set(NYSE_EARLY_CLOSES);

export type SessionKind = "regular" | "early-close" | "holiday";

/** What kind of NYSE session the New York date containing `unixSeconds` is. */
export function sessionKind(unixSeconds: bigint): SessionKind {
  const d = nyDate(unixSeconds);
  if (holidaySet.has(d)) return "holiday";
  if (earlySet.has(d)) return "early-close";
  return "regular";
}

/**
 * A human note for the log and the status file when an expiry lands on a non-regular session. `null`
 * when there is nothing to say. Never changes the expiry — see the file header.
 */
export function expiryCalendarNote(expiry: bigint): string | null {
  const d = nyDate(expiry);
  switch (sessionKind(expiry)) {
    case "holiday":
      return `${d} is a full NYSE closure; the 16:00 ET expiry stands (SPEC §5 fixed-timestamp rule) and settlement will use the last Chainlink round before it, normally Thursday's close`;
    case "early-close":
      return `${d} is a 13:00 ET early close; the 16:00 ET expiry stands and the settlement price will be a post-market print (the 24/5 feed runs to 17:00 ET)`;
    default:
      return null;
  }
}

/** Days of calendar table left at `unixSeconds`; negative once the tables are exhausted. */
export function calendarDaysRemaining(unixSeconds: bigint): number {
  const end = Date.parse(`${CALENDAR_KNOWN_THROUGH}T00:00:00Z`) / 1000;
  return Math.floor((end - Number(unixSeconds)) / 86_400);
}
