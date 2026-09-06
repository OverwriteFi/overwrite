/**
 * Unit helpers. The protocol mixes three scales:
 *   options / qty      1e18 = one option on one Stock Token
 *   USDG               1e6  (escrow, price per option, refunds, bonds)
 *   USD from Chainlink 1e8  (sRef, strike, settlementPrice)
 * Payout per option is raw token units per 1e18 options, always < 1e18.
 */

export const WAD = 10n ** 18n;
export const USDG = 10n ** 6n;
export const USD8 = 10n ** 8n;

export const options = (n: number | string): bigint => toFixed(n, 18);
export const usdg = (n: number | string): bigint => toFixed(n, 6);
export const usd8 = (n: number | string): bigint => toFixed(n, 8);

export const fromOptions = (x: bigint): number => Number(x) / 1e18;
export const fromUsdg = (x: bigint): number => Number(x) / 1e6;
export const fromUsd8 = (x: bigint): number => Number(x) / 1e8;

/** Escrow the AuctionHouse pulls for a bid: floor(qty × price / 1e18). */
export const escrowFor = (qty: bigint, price: bigint): bigint => (qty * price) / WAD;

/** Stock tokens paid per option at settlement, mirrors SPEC §7.1 (rounded down). */
export function payoutPerOption(settlement8: bigint, strike8: bigint): bigint {
  if (settlement8 <= strike8) return 0n;
  return ((settlement8 - strike8) * WAD) / settlement8;
}

/** Exact decimal string → bigint at `decimals` without float error. */
export function toFixed(n: number | string, decimals: number): bigint {
  const s = typeof n === "number" ? n.toFixed(decimals) : n;
  const neg = s.startsWith("-");
  const [int, frac = ""] = (neg ? s.slice(1) : s).split(".");
  const digits = (int + frac.padEnd(decimals, "0").slice(0, decimals)).replace(/^0+(?=\d)/, "");
  const v = BigInt(digits || "0");
  return neg ? -v : v;
}

export const SeriesKind = { WEEKDAY: 0, WEEKEND: 1 } as const;
export const BondKind = { CURATOR: 0, MM: 1 } as const;
export const AuctionState = ["NONE", "OPEN", "CLEARED", "SKIPPED"] as const;
export const SeriesState = ["NONE", "AUCTION", "SKIPPED", "LIVE", "SETTLED", "HALTED", "RESOLVED"] as const;
