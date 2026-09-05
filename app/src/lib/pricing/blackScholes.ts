/**
 * Black-Scholes for a European call (port of keeper/src/pricing/blackScholes.ts).
 *
 * Used for one thing in the app: the "model estimate" shown for a vault that has no cleared auction
 * yet. Nothing here is a forecast; real premium is set at auction.
 *
 * No dividends: SPEC §10 / D-002 fix the strike as PER_TOKEN, and under ERC-8056 a dividend or split
 * moves `uiMultiplier`, not the feed price of one raw token.
 */

export function normCdf(x: number): number {
  return 0.5 * (1 + erf(x / Math.SQRT2));
}

export function erf(x: number): number {
  const sign = x < 0 ? -1 : 1;
  const z = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * z);
  const y =
    1 -
    ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
      t *
      Math.exp(-z * z);
  return sign * y;
}

export interface BlackScholesInput {
  spot: number;
  strike: number;
  years: number;
  sigma: number;
  rate: number;
}

export function callPrice({ spot, strike, years, sigma, rate }: BlackScholesInput): number {
  if (!Number.isFinite(spot) || !Number.isFinite(strike) || spot <= 0 || strike <= 0) return 0;
  const intrinsic = Math.max(0, spot - strike * Math.exp(-rate * Math.max(0, years)));
  if (!(years > 0) || !(sigma > 0)) return intrinsic;
  const sqrtT = Math.sqrt(years);
  const vol = sigma * sqrtT;
  const d1 = (Math.log(spot / strike) + (rate + 0.5 * sigma * sigma) * years) / vol;
  const d2 = d1 - vol;
  const price = spot * normCdf(d1) - strike * Math.exp(-rate * years) * normCdf(d2);
  return Number.isFinite(price) ? Math.max(intrinsic, Math.max(0, price)) : intrinsic;
}
