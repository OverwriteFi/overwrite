/**
 * Sample bid strategies. These are illustrations of how to turn a view on the option into a ladder the
 * AuctionHouse accepts, not trading advice. Each function is pure: it takes the auction and your inputs
 * and returns `{ qty, price }[]` for `OverwriteClient.bidLadder`.
 *
 * Facts about the mechanism every strategy leans on (SPEC §8):
 *
 *  - Uniform price. You pay the marginal bid's price, not your own. Bidding your full valuation costs you
 *    nothing extra when someone else sets the margin, and only bites when *you* are the marginal bid. So
 *    the classic uniform-auction shading is: bid close to value on the size you want, and shade only the
 *    last tranche that might turn out marginal.
 *  - Open book. Every bid is visible the moment it lands; `previewClear` runs the actual clearing routine
 *    as a view. Blocks are ~100 ms and the window is 900 s. You can and should re-read the book before
 *    each tranche.
 *  - No cancel, no amend. A bid is a commitment funded on the spot. Ladders are built tranche by tranche,
 *    at most 8 per bidder per auction, 64 per auction.
 *  - Ties at the clearing price fill pro-rata by qty, dust to the earliest bidId. Earlier is better at
 *    equal price; a tick above is better still.
 *  - Reserve is a floor from realised vol, deliberately below fair. Clearing at reserve happens in quiet
 *    books; a bid one tick above reserve wins those weeks outright.
 *  - Price granularity is 1e-6 USDG per option. A "tick" here is whatever you choose; 0.0001 USDG is
 *    plenty.
 */

import type { OpenAuction, BookEntry } from "./client.js";
import { WAD, fromUsd8, fromUsdg, usdg } from "./units.js";

export interface Tranche {
  qty: bigint; // 1e18 = one option
  price: bigint; // USDG 6 dec per option
}

// ───────────────────────────── pricing helpers ─────────────────────────────

/** Standard normal CDF (Abramowitz–Stegun 7.1.26). */
export function normCdf(x: number): number {
  const sign = x < 0 ? -1 : 1;
  const z = Math.abs(x) / Math.SQRT2;
  const t = 1 / (1 + 0.3275911 * z);
  const erf =
    1 -
    ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-z * z);
  return 0.5 * (1 + sign * erf);
}

/** Black-Scholes European call, no dividends (the strike is PER_TOKEN and never adjusted, SPEC §10). */
export function bsCall(spot: number, strike: number, years: number, sigma: number, rate = 0): number {
  if (years <= 0 || sigma <= 0) return Math.max(0, spot - strike);
  const v = sigma * Math.sqrt(years);
  const d1 = (Math.log(spot / strike) + (rate + 0.5 * sigma * sigma) * years) / v;
  const d2 = d1 - v;
  return Math.max(0, spot * normCdf(d1) - strike * Math.exp(-rate * years) * normCdf(d2));
}

/**
 * Time to expiry in years. Calendar time is a reasonable first cut; the keeper's reserve model uses
 * trading-time variance (weekends carry less variance for the weekday series, but the weekend series
 * is priced *entirely* on non-exchange hours where the token still trades, so do not zero it out).
 */
export function yearsToExpiry(a: OpenAuction, now = Date.now() / 1000): number {
  return Math.max(0, a.expiry - now) / (365 * 86400);
}

/** Your fair value of one option in USDG, from an annualised vol you believe in. */
export function fairValue(a: OpenAuction, sigma: number, now?: number): number {
  return bsCall(fromUsd8(a.sRef), fromUsd8(a.strike), yearsToExpiry(a, now), sigma);
}

// ───────────────────────────── strategy 1: value ladder ─────────────────────────────

/**
 * Bid most of your size at (1 − shade) × fair and the rest stepping down toward the reserve.
 *
 * Why: under uniform pricing the top tranche almost never sets the price, so shading it buys nothing
 * and risks losing the fill. The lower tranches are the ones that may be marginal; they carry the
 * discount. Sizes are in options (1e18). Anything below the reserve is clamped up to reserve + 1 tick,
 * because a bid under the reserve reverts rather than resting.
 *
 * Example: NVDA, sRef 230, strike 248.40 (+8 %), 4.5 days, sigma 0.55 → fair ≈ 0.7226 USDG per option.
 *   valueLadder(a, { totalQty: options(60), sigma: 0.55, topShade: 0.03, steps: 4, floorShade: 0.35 })
 *   → 30 @ 0.7009, 10 @ 0.6238, 10 @ 0.5467, 10 @ 0.4697   (reserve 0.23, so nothing is clamped)
 */
export function valueLadder(
  a: OpenAuction,
  p: { totalQty: bigint; sigma: number; topShade?: number; floorShade?: number; steps?: number; topShare?: number; tick?: bigint },
): Tranche[] {
  const fair = fairValue(a, p.sigma);
  const steps = Math.max(1, p.steps ?? 4);
  const tick = p.tick ?? usdg("0.0001");
  const topShare = p.topShare ?? 0.5;
  const topShade = p.topShade ?? 0.03;
  const floorShade = p.floorShade ?? 0.35;
  const minPrice = a.reservePrice + tick;

  const topQty = (p.totalQty * BigInt(Math.round(topShare * 1e6))) / 1_000_000n;
  const restQty = p.totalQty - topQty;
  const out: Tranche[] = [{ qty: topQty, price: clampPrice(usdg(fair * (1 - topShade)), minPrice) }];
  const lower = steps - 1;
  if (lower > 0 && restQty > 0n) {
    const per = restQty / BigInt(lower);
    for (let i = 1; i <= lower; i++) {
      const shade = topShade + ((floorShade - topShade) * i) / lower;
      out.push({ qty: i === lower ? restQty - per * BigInt(lower - 1) : per, price: clampPrice(usdg(fair * (1 - shade)), minPrice) });
    }
  }
  return dedupePrices(out, tick);
}

// ───────────────────────────── strategy 2: reserve sweep ─────────────────────────────

/**
 * Quiet-book strategy: one bid a hair above the reserve for the whole offer.
 *
 * Why: the reserve is set from trailing realised vol, which sits below implied essentially always. In a
 * week when no other desk shows up, this fills at your own price (a single bid clears at itself) and
 * you own the whole series at a floor price. In a contested week it simply does not fill and the escrow
 * comes straight back. Pair it with strategy 1: the reserve sweep is the last rung of the ladder.
 *
 * Risk you are taking: a bid you cannot cancel for 15 minutes plus up to an hour of clearing grace. If
 * the stock gaps during the window the option is worth more than you bid, which is fine, or less, which
 * you eat. Size accordingly.
 */
export function reserveSweep(a: OpenAuction, p: { maxQty?: bigint; tick?: bigint } = {}): Tranche[] {
  const tick = p.tick ?? usdg("0.0001");
  const qty = p.maxQty && p.maxQty < a.offeredQty ? p.maxQty : a.offeredQty;
  return [{ qty, price: a.reservePrice + tick }];
}

// ───────────────────────────── strategy 3: book-aware top-up ─────────────────────────────

/**
 * Read the live book and place exactly what it takes to sit above the current marginal bid on the size
 * you still want, capped by your fair value.
 *
 * Why: the book is public and `previewClear` is exact, so there is no need to guess. Compute the
 * cumulative quantity from the top; the bid at which cumulative qty crosses `offeredQty` is the current
 * clearing price. Bidding one tick above it for `wantQty` displaces that much of the margin. Re-run it
 * every few seconds until close; each run yields at most one new tranche, so you spend your 8 bids
 * where they matter. Returns [] when the book already clears above your value.
 *
 * Note the subtlety: raising the marginal price raises what *everyone* pays, including you on your
 * earlier tranches. `maxPrice` is the value above which you stop pushing.
 */
export function topUp(
  a: OpenAuction,
  book: BookEntry[],
  p: { wantQty: bigint; maxPrice: bigint; me: `0x${string}`; tick?: bigint },
): Tranche[] {
  const tick = p.tick ?? usdg("0.0001");
  const sorted = [...book].sort((x, y) => (y.price === x.price ? x.bidId - y.bidId : y.price > x.price ? 1 : -1));
  let cum = 0n;
  let marginal = a.reservePrice;
  let mine = 0n;
  for (const b of sorted) {
    if (b.bidder.toLowerCase() === p.me.toLowerCase()) mine += b.qty;
    cum += b.qty;
    marginal = b.price;
    if (cum >= a.offeredQty) break;
  }
  const need = p.wantQty - mine;
  if (need <= 0n) return [];
  const price = cum < a.offeredQty ? a.reservePrice + tick : marginal + tick; // book not full: reserve wins
  if (price > p.maxPrice) return [];
  return [{ qty: need, price }];
}

// ───────────────────────────── strategy 4: delta-sized bid ─────────────────────────────

/**
 * Size the bid to the hedge you can actually run, not to the offer.
 *
 * Why: you are buying calls, so your hedge is short delta in the Stock Token (or a correlated listed
 * instrument during exchange hours; the weekend series has no listed hedge, which is exactly why it
 * pays). If you can carry at most `maxHedgeTokens` short, bid `maxHedgeTokens / delta` options at your
 * value. Delta comes from the same Black-Scholes call at your sigma. The payout is in the token itself,
 * so a short-token hedge also matches the settlement asset.
 */
export function deltaSized(a: OpenAuction, p: { sigma: number; maxHedgeTokens: number; shade?: number; tick?: bigint }): Tranche[] {
  const spot = fromUsd8(a.sRef);
  const strike = fromUsd8(a.strike);
  const t = yearsToExpiry(a);
  const v = p.sigma * Math.sqrt(Math.max(t, 1e-9));
  const d1 = (Math.log(spot / strike) + 0.5 * p.sigma * p.sigma * t) / v;
  const delta = normCdf(d1);
  if (delta <= 0.01) return [];
  const qtyOptions = p.maxHedgeTokens / delta;
  const qty = BigInt(Math.floor(qtyOptions * 1e6)) * (WAD / 1_000_000n);
  const price = clampPrice(usdg(fairValue(a, p.sigma) * (1 - (p.shade ?? 0.05))), a.reservePrice + (p.tick ?? usdg("0.0001")));
  return [{ qty: qty < a.offeredQty ? qty : a.offeredQty, price }];
}

// ───────────────────────────── strategy 5: last-look ─────────────────────────────

/**
 * Wait until the last N seconds, read the book once, then place strategy 3's top-up.
 *
 * Why it works: bids are irrevocable, so early bidders have shown their hand and cannot react to yours
 * once the window shuts. Why it can fail: blocks are ~100 ms but the public RPC is rate-limited and
 * `auctionClose` is checked with `block.timestamp >= auctionClose` at inclusion. Leave 5–10 s, not 1.
 * Also note that a clear may not land for up to `clearGrace` (1 h) after close; the stock can move in
 * that hour and you are committed either way (D-113 F-2 explains why the grace is short).
 *
 * This is a scheduler around `topUp`, shown as pseudo-code because it depends on your event loop:
 *
 *   const a = await client.auction("NVDA");
 *   const fireAt = a.auctionClose - 8;                      // seconds
 *   await sleepUntil(fireAt);
 *   const book = await client.book(a.seriesId);
 *   const ladder = topUp(a, book, { wantQty: options(40), maxPrice: usdg(fairValue(a, 0.55) * 0.97), me });
 *   if (ladder.length) await client.bidLadder(a.seriesId, ladder);
 */

// ───────────────────────────── helpers ─────────────────────────────

function clampPrice(p: bigint, min: bigint): bigint {
  return p < min ? min : p;
}

/** Merge tranches that landed on the same price after clamping, so each price uses one of your 8 bids. */
function dedupePrices(ts: Tranche[], _tick: bigint): Tranche[] {
  const byPrice = new Map<bigint, bigint>();
  for (const t of ts) byPrice.set(t.price, (byPrice.get(t.price) ?? 0n) + t.qty);
  return [...byPrice.entries()].map(([price, qty]) => ({ qty, price })).sort((x, y) => (y.price > x.price ? 1 : -1));
}

/** Human summary of a ladder for logs. */
export function describe(ts: Tranche[]): string {
  return ts.map((t) => `${(Number(t.qty) / 1e18).toFixed(2)} @ ${fromUsdg(t.price).toFixed(4)}`).join(", ");
}
