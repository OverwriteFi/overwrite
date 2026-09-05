import { nyDate, nyLocalTimeUtc, sessionKind } from "./nyse.js";

/**
 * Variance time.
 *
 * The reserve model needs a time-to-expiry to put under a square root, and using calendar time is
 * wrong in a way that matters here rather than in the usual academic way. Two series, same vault:
 *
 *  - WEEKDAY runs Monday 14:00 UTC → Friday 16:00 ET: 4.25 calendar days, of which ~4.5 are sessions.
 *  - WEEKEND runs Friday 16:10 ET → Sunday 23:59 UTC: 2.16 calendar days, of which **zero** are sessions.
 *
 * Under calendar time the weekend option looks like half the weekday option's risk. It is not: the
 * underlying does not trade at all in that window, and the only thing being sold is gap risk over one
 * weekend. Pricing it on 2.16/365 of a year produces a reserve several times too high, every weekend
 * auction skips, and the vault earns nothing — a failure that would have looked like "no MM demand".
 *
 * So variance accrues on a session clock: a full NYSE session is 1.0 variance-day, a partial session is
 * pro-rated, and each non-trading gap contributes a fixed weight (overnight and weekend weighted
 * separately, because a weekend gap carries more jump risk than an overnight one but nothing like the
 * 2.5x its length would imply). Annualisation is then `sqrt(252)` on a matching 252-session year — the
 * estimator and the clock share one convention instead of contradicting each other.
 *
 * The gap weights are the model's one judgement call. They are config, they are logged with every
 * reserve, and the RUNBOOK says what moving them does.
 */

export interface VarianceParams {
  /** Variance-days attributed to one close→open gap on consecutive session days. */
  overnightVarianceDays: number;
  /** Variance-days attributed to a Friday-close → Monday-open gap (or one spanning a holiday). */
  weekendVarianceDays: number;
  /** Sessions per year, matching the estimator's annualiser. */
  sessionsPerYear: number;
}

export const DEFAULT_VARIANCE_PARAMS: VarianceParams = {
  overnightVarianceDays: 0.15,
  weekendVarianceDays: 0.3,
  sessionsPerYear: 252,
};

const DAY = 86_400n;

interface Session {
  date: string;
  open: bigint;
  close: bigint;
}

/** The NYSE session on the UTC calendar day containing `utcMidnight`, or null when there isn't one. */
export function sessionOn(utcMidnight: bigint): Session | null {
  const date = nyDate(utcMidnight + 12n * 3600n); // midday, safely inside the ET date
  const dow = new Date(Number(utcMidnight) * 1000).getUTCDay(); // 0 = Sunday
  if (dow === 0 || dow === 6) return null;
  const kind = sessionKind(utcMidnight + 12n * 3600n);
  if (kind === "holiday") return null;
  const open = nyLocalTimeUtc(utcMidnight, 9, 30);
  const close = nyLocalTimeUtc(utcMidnight, kind === "early-close" ? 13 : 16);
  return { date, open, close };
}

const overlap = (aFrom: bigint, aTo: bigint, bFrom: bigint, bTo: bigint): bigint => {
  const lo = aFrom > bFrom ? aFrom : bFrom;
  const hi = aTo < bTo ? aTo : bTo;
  return hi > lo ? hi - lo : 0n;
};

/**
 * Variance-days accruing over `[from, to)`. A regular session is 1.0; an early close is 0.538 (3.5 h of
 * 6.5 h), which is exactly the point of tracking half-days.
 */
export function varianceDays(from: bigint, to: bigint, params = DEFAULT_VARIANCE_PARAMS): number {
  if (to <= from) return 0;

  // Look five days either side, not one. A gap is only counted when both of the sessions bracketing it
  // are enumerated, and a holiday weekend can put four idle days between two sessions — Labor Day 2026
  // (Mon 7 Sep) is exactly that, and a one-day lookback silently dropped the gap that carries the
  // weekend's jump risk.
  const PAD = 5n * DAY;
  const firstDay = (from / DAY) * DAY - PAD;
  const lastDay = (to / DAY) * DAY + PAD;

  const sessions: Session[] = [];
  for (let d = firstDay; d <= lastDay; d += DAY) {
    const s = sessionOn(d);
    if (s) sessions.push(s);
  }

  let total = 0;

  // Session time, pro-rated against a full 6.5 h day so a half-day counts as a half-day.
  const FULL = 6.5 * 3600;
  for (const s of sessions) {
    const inside = overlap(from, to, s.open, s.close);
    if (inside > 0n) total += Number(inside) / FULL;
  }

  // Gaps between consecutive sessions, pro-rated by how much of the gap the interval covers.
  for (let i = 0; i + 1 < sessions.length; i++) {
    const prev = sessions[i];
    const next = sessions[i + 1];
    if (!prev || !next) continue;
    const gapLen = next.open - prev.close;
    if (gapLen <= 0n) continue;
    const inside = overlap(from, to, prev.close, next.open);
    if (inside === 0n) continue;
    // Anything longer than a single night is a weekend or a holiday bridge.
    const weight = gapLen > 20n * 3600n ? params.weekendVarianceDays : params.overnightVarianceDays;
    total += weight * (Number(inside) / Number(gapLen));
  }

  return total;
}

/** Variance-days expressed as a year fraction, on the same session year the vol estimator annualises to. */
export function varianceYears(from: bigint, to: bigint, params = DEFAULT_VARIANCE_PARAMS): number {
  return varianceDays(from, to, params) / params.sessionsPerYear;
}

/** Plain calendar year fraction, kept for logging the comparison the RUNBOOK explains. */
export const calendarYears = (from: bigint, to: bigint): number =>
  to <= from ? 0 : Number(to - from) / 31_557_600;
