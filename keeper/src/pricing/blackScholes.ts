/**
 * Black-Scholes for a European call, used for one purpose only: the reserve **floor** the keeper hands
 * to `openAuction`.
 *
 * Read the header of reserve.ts for what that does and does not claim. Nothing here is a forecast, and
 * the keeper never uses it to accept or reject a bid — the auction's uniform clearing price does that.
 *
 * No dividends: SPEC §10 and D-002 fix the strike convention as PER_TOKEN with no corporate-action
 * adjustment, and under ERC-8056 a dividend or split moves `uiMultiplier`, not the feed price of one raw
 * token, so a dividend yield term would be double-counting.
 */

/**
 * Standard normal CDF via Abramowitz & Stegun 7.1.26 on erf. Max absolute error 1.5e-7, which is four
 * orders of magnitude finer than the 1e-6 USDG the reserve is quantised to.
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
  /** Spot, in the same unit as `strike`. */
  spot: number;
  strike: number;
  /** Year fraction. Use `varianceYears` from time/tradingTime.ts, not calendar time. */
  years: number;
  /** Annualised volatility, e.g. 0.45 for 45 %. */
  sigma: number;
  /** Continuously-compounded risk-free rate. 0 by default; see config `riskFreeRateBps`. */
  rate: number;
}

/** Price of one European call. Degenerate inputs collapse to intrinsic value rather than NaN. */
export function callPrice({ spot, strike, years, sigma, rate }: BlackScholesInput): number {
  if (!Number.isFinite(spot) || !Number.isFinite(strike) || spot <= 0 || strike <= 0) return 0;
  const intrinsic = Math.max(0, spot - strike * Math.exp(-rate * Math.max(0, years)));
  if (!(years > 0) || !(sigma > 0)) return intrinsic;

  const sqrtT = Math.sqrt(years);
  const vol = sigma * sqrtT;
  const d1 = (Math.log(spot / strike) + (rate + 0.5 * sigma * sigma) * years) / vol;
  const d2 = d1 - vol;
  const price = spot * normCdf(d1) - strike * Math.exp(-rate * years) * normCdf(d2);
  // Guard the tails: for deep OTM, d1/d2 underflow and the difference of two tiny numbers can go
  // slightly negative. A negative reserve floor would be nonsense.
  return Number.isFinite(price) ? Math.max(intrinsic, Math.max(0, price)) : intrinsic;
}

/** Price of the matching put. Only used by the put-call-parity unit test. */
export function putPrice(input: BlackScholesInput): number {
  const { spot, strike, years, rate } = input;
  return callPrice(input) - spot + strike * Math.exp(-rate * Math.max(0, years));
}
