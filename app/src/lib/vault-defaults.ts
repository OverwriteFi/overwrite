/**
 * The keeper's per-vault choices (keeper/config/keeper.46630.json), copied here so the app can show
 * the intended strike distance before an auction exists and price a model estimate at the fallback
 * volatility. These are keeper inputs, not contract state; the live strike always comes from the chain.
 *
 * SPY weekday is 300 bps, not the SPEC's 200: `STRIKE_LO_WEEKDAY = 300` (D-109).
 */

export interface VaultDefaults {
  assetClass: "SINGLE_NAME" | "ETF";
  strikeDistanceBps: { weekday: number; weekend: number };
  fallbackVolAnnualBps: number;
}

const DEFAULTS: Record<string, VaultDefaults> = {
  NVDA: {
    assetClass: "SINGLE_NAME",
    strikeDistanceBps: { weekday: 800, weekend: 500 },
    fallbackVolAnnualBps: 5500,
  },
  SPY: {
    assetClass: "ETF",
    strikeDistanceBps: { weekday: 300, weekend: 100 },
    fallbackVolAnnualBps: 1800,
  },
  TSLA: {
    assetClass: "SINGLE_NAME",
    strikeDistanceBps: { weekday: 800, weekend: 500 },
    fallbackVolAnnualBps: 7000,
  },
  QQQ: {
    assetClass: "ETF",
    strikeDistanceBps: { weekday: 300, weekend: 100 },
    fallbackVolAnnualBps: 2200,
  },
};

const GENERIC: VaultDefaults = {
  assetClass: "SINGLE_NAME",
  strikeDistanceBps: { weekday: 800, weekend: 500 },
  fallbackVolAnnualBps: 5000,
};

export const vaultDefaults = (symbol: string): VaultDefaults =>
  DEFAULTS[symbol.toUpperCase()] ?? GENERIC;

/** Year fractions used by the landing calculator for the two series. */
export const YEARS_WEEKDAY = 4.3 / 365;
export const YEARS_WEEKEND = 2.2 / 365;

/** Protocol constants surfaced in copy. */
export const PROTOCOL = {
  feeBps: 1000,
  fixedCapUsd: 25_000,
  kDefault: 5,
  kMin: 1,
  kMax: 20,
  unstakeCooldownDays: 14,
  unstakeClaimWindowDays: 3,
  maxSlashBps: 3000,
  slashIntervalDays: 14,
  writeDiscountBps: 2000,
  writeBurnShareBps: 5000,
  mmBondUsd: 25_000,
  curatorBondUsd: 10_000,
  bondCooldownDays: 7,
  haltedTimeoutDays: 7,
  auctionMinutes: 15,
  strikeGridBps: 25,
  strikeBounds: { weekday: [300, 1500], weekend: [100, 1000] },
  reserveDefaultBps: { weekday: 10, weekend: 3 },
} as const;
