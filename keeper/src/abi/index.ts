export {
  auctionHouseAbi,
  vaultAbi,
  settlementOracleAbi,
  riskModuleAbi,
  feeRouterAbi,
  bondManagerAbi,
  optionTokenAbi,
  capControllerAbi,
  aggregatorAbi,
  poolAbi,
  stockTokenAbi,
  erc20Abi,
  // fork-harness only — never reachable from the send allowlist
  mockAggregatorAbi,
  mockPoolAbi,
  mockStockTokenAbi,
  mockUsdgAbi,
} from "./generated.js";

/** `SeriesKind` (contracts/src/Types.sol). */
export const WEEKDAY = 0;
export const WEEKEND = 1;
export type SeriesKind = typeof WEEKDAY | typeof WEEKEND;
export const kindName = (k: SeriesKind): "WEEKDAY" | "WEEKEND" =>
  k === WEEKDAY ? "WEEKDAY" : "WEEKEND";

/** `VaultState` (contracts/src/Types.sol). */
export const VaultState = ["IDLE", "AUCTION", "LIVE", "HALTED"] as const;
export type VaultStateName = (typeof VaultState)[number];

/** `SeriesState` (contracts/src/Types.sol). */
export const SeriesState = [
  "NONE",
  "AUCTION",
  "SKIPPED",
  "LIVE",
  "SETTLED",
  "HALTED",
  "RESOLVED",
] as const;
export type SeriesStateName = (typeof SeriesState)[number];

/** `AuctionState` (contracts/src/interfaces/IAuctionHouse.sol). */
export const AuctionState = ["NONE", "OPEN", "CLEARED", "SKIPPED"] as const;
export type AuctionStateName = (typeof AuctionState)[number];

/** Canonical Multicall3, verified present on 46630 (7 619 bytes of code). */
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
