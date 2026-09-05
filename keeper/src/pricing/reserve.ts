import { callPrice } from "./blackScholes.js";
import type { VolEstimate } from "./realisedVol.js";
import { varianceYears, calendarYears, type VarianceParams } from "../time/tradingTime.js";

/**
 * The auction reserve price.
 *
 * **This is a floor, not a forecast.** Say it out loud because the maths looks like a valuation and is
 * not being used as one. SPEC §8.3 makes the reserve the one number the keeper supplies that the
 * contract cannot verify — it only bounds it into `[sRef · minReserveBpsOfSpot / 1e4, sRef]` — and D-027
 * says why the bound exists: "a rogue or careless keeper cannot sell calls for nothing". The reserve's
 * job is to be a price below which no rational market maker would decline, so that a bad keeper cannot
 * give the vault's upside away, and so that a quiet week clears rather than skips.
 *
 * Trailing realised volatility is the right input for that job precisely because it is biased low.
 * Short-dated OTM equity calls trade at an implied vol above trailing realised essentially always — the
 * variance risk premium is one of the most durable regularities in equity derivatives — so a
 * Black-Scholes price computed at realised vol sits below fair value by construction. That is the
 * desired direction of error for a floor and the wrong direction for a valuation. The keeper never uses
 * this number to accept or reject a bid; the auction's uniform clearing price does that (SPEC §8.2).
 *
 * Two guards the arithmetic needs, both learned the hard way:
 *
 *  - **Order of operations.** The spot cap is applied *before* the contract's own lower bound, never
 *    after. Capping last can push the value under `reserveBounds().lo` and revert
 *    `ReserveOutOfBounds` at simulate, every single week.
 *  - **A margin above `lo`.** `_checkOpen` (AuctionHouse.sol:224-233) re-reads `sRef` at inclusion. The
 *    stock feeds publish on a 0.5 % deviation threshold, so a round landing between simulate and
 *    inclusion lifts `lo` and a reserve submitted at exactly `lo` reverts on chain, after gas, possibly
 *    at the edge of the open window. `reserveMarginBps` buys room for that.
 */

export interface ReserveInput {
  /** `auctionHouse.referencePrice(vault)` — USD, 8 decimals. */
  sRef: bigint;
  /** `auctionHouse.computeStrike(sRef, bps)` — USD, 8 decimals. */
  strike: bigint;
  now: bigint;
  expiry: bigint;
  vol: VolEstimate;
  /** `auctionHouse.reserveBounds(vault, kind, sRef)` — USDG, 6 decimals. */
  lo: bigint;
  hi: bigint;
  /** Keeper-side ceiling as bps of spot, so a vol spike cannot make every auction skip. */
  maxReserveBpsOfSpot: number;
  /** Keeper-side floor as bps of spot, at or above the on-chain `minReserveBpsOfSpot`. */
  minReserveBps: number;
  reserveMarginBps: number;
  riskFreeRateBps: number;
  reserveFactorBps: number;
  variance: VarianceParams;
}

export interface ReserveQuote {
  /** What to pass to `openAuction`. USDG, 6 decimals, per option (one option = 1e18 raw token units). */
  reservePrice: bigint;
  /** The unclamped Black-Scholes floor, same units. */
  modelPrice: bigint;
  lo: bigint;
  hi: bigint;
  spotCap: bigint;
  spotFloor: bigint;
  /** True when the contract's minimum, not the model, decided the number. */
  floorBinds: boolean;
  /**
   * `modelPrice / lo`. Below 1 the model is under the contract's minimum, which means the protocol is
   * asking more for the option than trailing vol says it is worth — a legitimate state (the floor is
   * doing its job) but one worth surfacing, because a vault whose ratio sits far below 1 every week
   * will skip every week. SPEC §8.3 calls the 10/3 bps defaults "placeholders to be tuned against the
   * keeper's implied-vol model"; this ratio is that measurement.
   */
  coverRatio: number;
  decidedBy: "model" | "contract-floor" | "keeper-floor" | "spot-cap" | "contract-ceiling";
  sigma: number;
  volSource: VolEstimate["source"];
  varianceYears: number;
  calendarYears: number;
}

/** USD (8 dec) → USDG (6 dec), the same conversion `reserveBounds` does with `sRef / 1e2`. */
export const usd8ToUsdg6 = (x: bigint): bigint => x / 100n;

export function quoteReserve(input: ReserveInput): ReserveQuote {
  const years = varianceYears(input.now, input.expiry, input.variance);
  const calYears = calendarYears(input.now, input.expiry);

  const spot = Number(input.sRef) / 1e8;
  const strike = Number(input.strike) / 1e8;

  const bsUsd = callPrice({
    spot,
    strike,
    years,
    sigma: input.vol.sigma,
    rate: input.riskFreeRateBps / 1e4,
  });

  const modelPrice =
    (BigInt(Math.max(0, Math.round(bsUsd * 1e6))) * BigInt(input.reserveFactorBps)) / 10_000n;

  const spotCap = (usd8ToUsdg6(input.sRef) * BigInt(input.maxReserveBpsOfSpot)) / 10_000n;
  const spotFloor = (usd8ToUsdg6(input.sRef) * BigInt(input.minReserveBps)) / 10_000n;

  // The contract's own lower bound, lifted by a margin so a feed update between simulate and inclusion
  // cannot invalidate it. Never lifted past `hi`.
  const loWithMargin = min(
    (input.lo * BigInt(10_000 + input.reserveMarginBps)) / 10_000n,
    input.hi,
  );
  const effectiveFloor = max(loWithMargin, min(spotFloor, input.hi));

  // Cap first, floor second, contract ceiling last — see the header.
  let value = max(modelPrice, effectiveFloor);
  let decidedBy: ReserveQuote["decidedBy"] =
    modelPrice >= effectiveFloor
      ? "model"
      : loWithMargin >= spotFloor
        ? "contract-floor"
        : "keeper-floor";

  if (value > spotCap && spotCap >= effectiveFloor) {
    value = spotCap;
    decidedBy = "spot-cap";
  }
  if (value > input.hi) {
    value = input.hi;
    decidedBy = "contract-ceiling";
  }
  if (value < input.lo) value = input.lo; // never below what the contract will accept

  return {
    reservePrice: value,
    modelPrice,
    lo: input.lo,
    hi: input.hi,
    spotCap,
    spotFloor,
    floorBinds: modelPrice < input.lo,
    coverRatio: input.lo === 0n ? Infinity : Number(modelPrice) / Number(input.lo),
    decidedBy,
    sigma: input.vol.sigma,
    volSource: input.vol.source,
    varianceYears: years,
    calendarYears: calYears,
  };
}

const min = (a: bigint, b: bigint): bigint => (a < b ? a : b);
const max = (a: bigint, b: bigint): bigint => (a > b ? a : b);
