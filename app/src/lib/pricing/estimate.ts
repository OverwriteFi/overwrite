import { callPrice } from "./blackScholes";
import { YEARS_WEEKDAY, YEARS_WEEKEND, vaultDefaults } from "../vault-defaults";

/**
 * Model estimate of one series' premium as a fraction of spot, for a vault with no cleared auction.
 * Always labelled "model estimate" in the UI; never a promise.
 */
export function estimatePremiumFraction(symbol: string, kind: 0 | 1): number {
  const d = vaultDefaults(symbol);
  const distBps = kind === 0 ? d.strikeDistanceBps.weekday : d.strikeDistanceBps.weekend;
  const years = kind === 0 ? YEARS_WEEKDAY : YEARS_WEEKEND;
  const spot = 100;
  const strike = spot * (1 + distBps / 10_000);
  const sigma = d.fallbackVolAnnualBps / 10_000;
  return callPrice({ spot, strike, years, sigma, rate: 0 }) / spot;
}
