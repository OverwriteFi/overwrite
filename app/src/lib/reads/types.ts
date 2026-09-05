import type { Address } from "viem";
import type { AuctionStateName, SeriesStateName, VaultStateName } from "../abi";
import type { DeployedVault } from "../deployment";
import type { NextEventKind } from "../time/schedule";

/**
 * Everything that crosses the server cache or the RSC boundary is a plain JSON object: bigints are
 * decimal strings, enums are their names. Client code parses with `BigInt(x)` where it does math.
 */

export type SeriesKind = 0 | 1;

export interface SeriesDto {
  id: string;
  kind: SeriesKind;
  state: SeriesStateName;
  settlementPath: number;
  expiry: string;
  strike: string;
  offeredQty: string;
  filledQty: string;
  settlementPrice: string;
  payoutPerOption: string;
  multiplierAtOpen: string;
}

export interface AuctionDto {
  id: string;
  vault: Address;
  kind: SeriesKind;
  state: AuctionStateName;
  auctionOpen: string;
  auctionClose: string;
  expiry: string;
  sRef: string;
  strike: string;
  offeredQty: string;
  reservePrice: string;
  clearingPrice: string;
  filledQty: string;
  premiumGross: string;
  fee: string;
  feeBps: number;
}

export type Outcome =
  | "auction-open"
  | "live"
  | "expired-worthless"
  | "called-away"
  | "skipped"
  | "halted"
  | "resolved";

/** One row of a vault's history: auction record + vault series + a plain-English outcome. */
export interface SeriesRowDto {
  id: string;
  kind: SeriesKind;
  auction: AuctionDto;
  series: SeriesDto | null;
  outcome: Outcome;
  /** clearingPrice / sRef, as a fraction of spot. null when not cleared. */
  premiumFraction: number | null;
  /** premiumGross - fee, USDG 6 dp. */
  premiumNet: string;
  /** filledQty / offeredQty. */
  fillFraction: number | null;
  /** strike / sRef - 1, bps. */
  strikeDistanceBps: number | null;
  /** payoutPerOption / 1e18 — share of each written token paid out at settlement. */
  payoutFraction: number | null;
}

export type VaultStatus =
  | "auction-open"
  | "clearing"
  | "active"
  | "settling"
  | "halted"
  | "idle"
  | "sunset";

export type PremiumSource = "auction" | "estimate";

export interface PremiumFigure {
  fraction: number | null;
  source: PremiumSource;
  kind: SeriesKind;
  seriesId?: string;
}

export interface VaultSnapshotDto {
  symbol: string;
  name: string;
  addresses: DeployedVault;
  state: VaultStateName;
  status: VaultStatus;
  totalAssets: string;
  totalSupply: string;
  freeAssets: string;
  pendingRedeemAssets: string;
  payoutOwed: string;
  sunset: boolean;
  currentSeriesId: string;
  series: SeriesDto | null;
  auction: AuctionDto | null;
  queue: { deposits: string; redeems: string };
  lastWeekdayExpiry: string;
  depositsPaused: boolean;
  auctionsPaused: boolean;
  feeBps: number;
  /** Reference/cap price (USD 8 dp) or null when the oracle has no usable price. */
  sRef: string | null;
  vaultCapUsd: string;
  remainingDepositAssets: string | null;
  /** totalAssets × sRef / cap. null when the cap price is unreadable. */
  capUsedFraction: number | null;
  /** Remaining capacity in USDG (6 dp) or null. */
  capacityUsd: string | null;
  /** Value of what the vault holds, USDG 6 dp, or null. */
  tvlUsd: string | null;
  stock: {
    symbol: string;
    decimals: number;
    uiMultiplier: string;
    newUIMultiplier: string;
    effectiveAt: string;
    oraclePaused: boolean;
  };
  usdg: { decimals: number; symbol: string };
  feed: { answer: string; updatedAt: string; decimals: number } | null;
  haltedAt: string | null;
  nextEvent: { kind: NextEventKind; at: string; label: string };
  premium: {
    /** The figure shown in the vault table: latest cleared auction, else the weekday estimate. */
    current: PremiumFigure;
    weekday: PremiumFigure;
    weekend: PremiumFigure;
    /** (weekday + weekend) × 52. */
    annualized: { fraction: number | null; source: PremiumSource | "mixed" };
  };
  strikeDistance: { bps: number; source: "auction" | "default"; kind: SeriesKind };
  /** Share price: assets per 1e24 shares, 18 dp stock units. */
  assetsPerShare: string;
}

export interface OverviewDto {
  chainId: number;
  chainNow: string;
  fetchedAt: string;
  vaults: VaultSnapshotDto[];
  /** History rows per vault symbol, newest first. */
  history: Record<string, SeriesRowDto[]>;
  capMode: "FIXED" | "SAFETY_MODULE";
}

export interface StakeOverviewDto {
  chainNow: string;
  enabled: boolean;
  safetyModule: Address | null;
  writeToken: Address | null;
  capMode: "FIXED" | "SAFETY_MODULE";
  wired: boolean;
  totalStaked: string;
  totalShares: string;
  valueUsd: string;
  valueOk: boolean;
  writePrice8: string | null;
  k: string;
  cooldownSeconds: string;
  claimWindowSeconds: string;
  maxSlashBps: number;
  slashIntervalSeconds: string;
  emissionsRate: string;
  emissionsWired: boolean;
  vaults: Array<{
    symbol: string;
    vault: Address;
    weightBps: number;
    fixedCapUsd: string;
    /** k × valueUsd × weight — what the cap would be under SAFETY_MODULE mode. */
    derivedCapUsd: string;
    liveCapUsd: string;
  }>;
}
