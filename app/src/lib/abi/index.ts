export {
  vaultAbi,
  auctionHouseAbi,
  optionTokenAbi,
  capControllerAbi,
  settlementOracleAbi,
  riskModuleAbi,
  feeRouterAbi,
  safetyModuleAbi,
  writePriceOracleAbi,
  emissionsControllerAbi,
  pointsDistributorAbi,
  stockTokenAbi,
  erc20Abi,
  aggregatorAbi,
} from "./generated";

/** `SeriesKind` (contracts/src/Types.sol). */
export const WEEKDAY = 0;
export const WEEKEND = 1;
export type SeriesKind = typeof WEEKDAY | typeof WEEKEND;
export const kindName = (k: SeriesKind): "Weekday" | "Weekend" =>
  k === WEEKDAY ? "Weekday" : "Weekend";

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

/** `CapController.CapMode`. */
export const CapMode = ["FIXED", "SAFETY_MODULE"] as const;
export type CapModeName = (typeof CapMode)[number];

/** `CoveredCallVault.RequestStatus`. */
export const RequestStatus = ["NONE", "QUEUED", "EXECUTED", "CANCELLED", "EXPIRED"] as const;
export type RequestStatusName = (typeof RequestStatus)[number];

/** Canonical Multicall3, verified present on 46630. */
export const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;
