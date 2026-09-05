import { callPrice } from "./blackScholes";
import { YEARS_WEEKDAY, YEARS_WEEKEND } from "../vault-defaults";

/**
 * The landing page's "what a week could pay" model, shared by the calculator and the vault ledger so
 * both show the same number for the same inputs. Black-Scholes at an annualised volatility, r = 0,
 * one weekday series plus one weekend series whose cap is 0.6× the weekday cap (min 1 %).
 *
 * A model estimate, always labelled as such; real premium is set at auction.
 */
export interface WeekPremium {
  /** weekday + weekend, as a fraction of spot. */
  total: number;
  wk: number;
  we: number;
  /** Weekend cap distance, whole percent. */
  weDist: number;
}

/** Weekend cap from a weekday cap, the landing's rule. `bounds` clamps it to the contract's window when known. */
export function weekendDistance(weekdayPct: number, bounds?: readonly [number, number] | null): number {
  let we = Math.max(1, Math.round(weekdayPct * 0.6));
  if (bounds) we = Math.min(Math.max(we, bounds[0]), bounds[1]);
  return we;
}

export function weekPremium(
  volAnnual: number,
  weekdayPct: number,
  weekendBounds?: readonly [number, number] | null,
  /** Explicit weekend cap (the vault's own default or last strike); otherwise the 0.6× rule. */
  weekendPct?: number,
): WeekPremium {
  const wk = callPrice({ spot: 1, strike: 1 + weekdayPct / 100, years: YEARS_WEEKDAY, sigma: volAnnual, rate: 0 });
  const weDist = weekendPct ?? weekendDistance(weekdayPct, weekendBounds);
  const we = callPrice({ spot: 1, strike: 1 + weDist / 100, years: YEARS_WEEKEND, sigma: volAnnual, rate: 0 });
  return { total: wk + we, wk, we, weDist };
}

/** "0.71%" — the landing's `pct()`. */
export function pctText(x: number, d = 2): string {
  return (x * 100).toFixed(d) + "%";
}

/** "$1,234" — the landing's `usd()`. */
export function usdText(x: number): string {
  return "$" + Math.round(x).toLocaleString("en-US");
}

/** "$2.0M" / "$52.5k" — the landing's `money()`. */
export function moneyText(x: number): string {
  if (x >= 1e9) return "$" + (x / 1e9).toFixed(1) + "B";
  if (x >= 1e6) return "$" + (x / 1e6).toFixed(1) + "M";
  if (x >= 1e3) return "$" + (x / 1e3).toFixed(x < 1e4 ? 1 : 0) + "k";
  return "$" + Math.round(x);
}
