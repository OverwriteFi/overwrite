import type { Address, PublicClient } from "viem";
import {
  auctionHouseAbi,
  capControllerAbi,
  riskModuleAbi,
  settlementOracleAbi,
  stockTokenAbi,
  vaultAbi,
  AuctionState,
  SeriesState,
  VaultState,
  type SeriesKind,
} from "./abi/index.js";
import { multicall } from "./chain/multicall.js";
import type { Deployment, DeployedVault } from "./deployment.js";

/**
 * One batched read of everything the scheduler and the monitor need about a vault.
 *
 * Deliberately one call per tick per vault rather than a read at each decision point: the tick's whole
 * job is to answer "what, if anything, is due", and answering it from a single consistent snapshot
 * means the scheduler cannot see a vault half-way through a state transition.
 */

export interface OracleParams {
  weekdayMaxStale: number;
  twapGrace: number;
  sequencerGrace: number;
  usdgMaxStale: number;
  weekendTwapBoundBps: number;
  weekdayTwapBoundBps: number;
  impactBps: number;
  jumpBps: number;
  usdgBandLowBps: number;
  usdgBandHighBps: number;
  minObservationsInWindow: number;
  swapNotionalUSDG: bigint;
  sequencerFeed: Address;
}

export interface VaultSeries {
  kind: SeriesKind;
  state: (typeof SeriesState)[number];
  settlementPath: number;
  expiry: bigint;
  strike: bigint;
  offeredQty: bigint;
  filledQty: bigint;
  mintedQty: bigint;
  claimedQty: bigint;
  settlementPrice: bigint;
  payoutPerOption: bigint;
  multiplierAtOpen: bigint;
}

export interface AuctionRecord {
  vault: Address;
  kind: SeriesKind;
  state: (typeof AuctionState)[number];
  auctionOpen: bigint;
  auctionClose: bigint;
  expiry: bigint;
  sRef: bigint;
  strike: bigint;
  offeredQty: bigint;
  reservePrice: bigint;
  clearingPrice: bigint;
  filledQty: bigint;
  premiumGross: bigint;
  fee: bigint;
  feeBps: number;
}

export interface VaultSnapshot {
  symbol: string;
  addresses: DeployedVault;
  state: (typeof VaultState)[number];
  totalAssets: bigint;
  freeAssets: bigint;
  pendingRedeemAssets: bigint;
  payoutOwed: bigint;
  sunset: boolean;
  currentSeriesId: bigint;
  series: VaultSeries | null;
  auction: AuctionRecord | null;
  queue: { deposits: bigint; redeems: bigint };
  lastWeekdayExpiry: bigint;
  depositsPaused: boolean;
  auctionsPaused: boolean;
  haltCount: bigint;
  params: OracleParams;
  /** `capPrice` never reverts; `sRef` is null when no reference price is available at all. */
  sRef: bigint | null;
  capPriceOk: boolean;
  remainingDepositAssets: bigint | null;
  stock: { uiMultiplier: bigint; effectiveAt: bigint; oraclePaused: boolean };
}

const asAddress = (v: unknown): Address => v as Address;

export async function readVault(
  client: PublicClient,
  d: Deployment,
  v: DeployedVault,
  symbol: string,
): Promise<VaultSnapshot> {
  const ah = d.core.auctionHouse;
  const rm = d.core.riskModule;
  const so = d.core.settlementOracle;

  const base = await multicall(client, [
    { address: v.vault, abi: vaultAbi, functionName: "state" },
    { address: v.vault, abi: vaultAbi, functionName: "totalAssets" },
    { address: v.vault, abi: vaultAbi, functionName: "freeAssets" },
    { address: v.vault, abi: vaultAbi, functionName: "pendingRedeemAssets" },
    { address: v.vault, abi: vaultAbi, functionName: "payoutOwed" },
    { address: v.vault, abi: vaultAbi, functionName: "sunset" },
    { address: v.vault, abi: vaultAbi, functionName: "currentSeriesId" },
    { address: v.vault, abi: vaultAbi, functionName: "queueLengths" },
    { address: ah, abi: auctionHouseAbi, functionName: "lastWeekdayExpiry", args: [v.vault] },
    { address: rm, abi: riskModuleAbi, functionName: "depositsPaused", args: [v.vault] },
    { address: rm, abi: riskModuleAbi, functionName: "auctionsPaused", args: [v.vault] },
    { address: rm, abi: riskModuleAbi, functionName: "haltCount", args: [v.vault] },
    { address: rm, abi: riskModuleAbi, functionName: "currentParams", args: [v.vault] },
    { address: so, abi: settlementOracleAbi, functionName: "capPrice", args: [v.vault] },
    { address: v.stock, abi: stockTokenAbi, functionName: "uiMultiplier" },
    { address: v.stock, abi: stockTokenAbi, functionName: "effectiveAt" },
    { address: v.stock, abi: stockTokenAbi, functionName: "oraclePaused" },
  ]);

  const val = <T>(i: number, fallback: T): T => {
    const r = base[i];
    return r && r.ok ? (r.value as T) : fallback;
  };

  const stateIdx = Number(val<number>(0, 0));
  const totalAssets = val<bigint>(1, 0n);
  const currentSeriesId = val<bigint>(6, 0n);
  const queue = val<readonly [bigint, bigint]>(7, [0n, 0n]);
  const rawParams = val<Record<string, unknown>>(12, {});
  const cap = val<readonly [bigint, boolean]>(13, [0n, false]);

  const params: OracleParams = {
    weekdayMaxStale: Number(rawParams.weekdayMaxStale ?? 0),
    twapGrace: Number(rawParams.twapGrace ?? 0),
    sequencerGrace: Number(rawParams.sequencerGrace ?? 0),
    usdgMaxStale: Number(rawParams.usdgMaxStale ?? 0),
    weekendTwapBoundBps: Number(rawParams.weekendTwapBoundBps ?? 0),
    weekdayTwapBoundBps: Number(rawParams.weekdayTwapBoundBps ?? 0),
    impactBps: Number(rawParams.impactBps ?? 0),
    jumpBps: Number(rawParams.jumpBps ?? 0),
    usdgBandLowBps: Number(rawParams.usdgBandLowBps ?? 0),
    usdgBandHighBps: Number(rawParams.usdgBandHighBps ?? 0),
    minObservationsInWindow: Number(rawParams.minObservationsInWindow ?? 0),
    swapNotionalUSDG: BigInt((rawParams.swapNotionalUSDG as bigint | undefined) ?? 0n),
    sequencerFeed: asAddress(
      rawParams.sequencerFeed ?? "0x0000000000000000000000000000000000000000",
    ),
  };

  // Series and auction only exist once a series has been opened.
  let series: VaultSeries | null = null;
  let auction: AuctionRecord | null = null;
  let remainingDepositAssets: bigint | null = null;

  const extra = await multicall(client, [
    ...(currentSeriesId > 0n
      ? [
          { address: v.vault, abi: vaultAbi, functionName: "series", args: [currentSeriesId] },
          { address: ah, abi: auctionHouseAbi, functionName: "auctions", args: [currentSeriesId] },
        ]
      : []),
    {
      address: d.core.capController,
      abi: capControllerAbi,
      functionName: "remainingDepositAssets",
      args: [v.vault, totalAssets],
    },
  ]);

  let cursor = 0;
  if (currentSeriesId > 0n) {
    const s = extra[cursor++];
    const a = extra[cursor++];
    if (s && s.ok) series = toSeries(s.value as Record<string, unknown>);
    if (a && a.ok) auction = toAuction(a.value as Record<string, unknown>);
  }
  const capRead = extra[cursor];
  // `remainingDepositAssets` returns (assets, priceOk); a false `priceOk` means the cap is unreadable,
  // which the vault itself treats as "no headroom" rather than as zero (D-041).
  if (capRead && capRead.ok) {
    const [assets, priceOk] = capRead.value as readonly [bigint, boolean];
    remainingDepositAssets = priceOk ? assets : null;
  }

  return {
    symbol,
    addresses: v,
    state: VaultState[stateIdx] ?? "IDLE",
    totalAssets,
    freeAssets: val<bigint>(2, 0n),
    pendingRedeemAssets: val<bigint>(3, 0n),
    payoutOwed: val<bigint>(4, 0n),
    sunset: val<boolean>(5, false),
    currentSeriesId,
    series,
    auction,
    queue: { deposits: queue[0] ?? 0n, redeems: queue[1] ?? 0n },
    lastWeekdayExpiry: val<bigint>(8, 0n),
    depositsPaused: val<boolean>(9, false),
    auctionsPaused: val<boolean>(10, false),
    haltCount: val<bigint>(11, 0n),
    params,
    sRef: cap[1] ? (cap[0] ?? null) : null,
    capPriceOk: Boolean(cap[1]),
    remainingDepositAssets,
    stock: {
      uiMultiplier: val<bigint>(14, 0n),
      effectiveAt: val<bigint>(15, 0n),
      oraclePaused: val<boolean>(16, false),
    },
  };
}

function toSeries(v: Record<string, unknown>): VaultSeries {
  return {
    kind: Number(v.kind ?? 0) as SeriesKind,
    state: SeriesState[Number(v.state ?? 0)] ?? "NONE",
    settlementPath: Number(v.settlementPath ?? 0),
    expiry: BigInt((v.expiry as bigint | undefined) ?? 0n),
    strike: BigInt((v.strike as bigint | undefined) ?? 0n),
    offeredQty: BigInt((v.offeredQty as bigint | undefined) ?? 0n),
    filledQty: BigInt((v.filledQty as bigint | undefined) ?? 0n),
    mintedQty: BigInt((v.mintedQty as bigint | undefined) ?? 0n),
    claimedQty: BigInt((v.claimedQty as bigint | undefined) ?? 0n),
    settlementPrice: BigInt((v.settlementPrice as bigint | undefined) ?? 0n),
    payoutPerOption: BigInt((v.payoutPerOption as bigint | undefined) ?? 0n),
    multiplierAtOpen: BigInt((v.multiplierAtOpen as bigint | undefined) ?? 0n),
  };
}

function toAuction(v: Record<string, unknown>): AuctionRecord {
  return {
    vault: asAddress(v.vault),
    kind: Number(v.kind ?? 0) as SeriesKind,
    state: AuctionState[Number(v.state ?? 0)] ?? "NONE",
    auctionOpen: BigInt((v.auctionOpen as bigint | undefined) ?? 0n),
    auctionClose: BigInt((v.auctionClose as bigint | undefined) ?? 0n),
    expiry: BigInt((v.expiry as bigint | undefined) ?? 0n),
    sRef: BigInt((v.sRef as bigint | undefined) ?? 0n),
    strike: BigInt((v.strike as bigint | undefined) ?? 0n),
    offeredQty: BigInt((v.offeredQty as bigint | undefined) ?? 0n),
    reservePrice: BigInt((v.reservePrice as bigint | undefined) ?? 0n),
    clearingPrice: BigInt((v.clearingPrice as bigint | undefined) ?? 0n),
    filledQty: BigInt((v.filledQty as bigint | undefined) ?? 0n),
    premiumGross: BigInt((v.premiumGross as bigint | undefined) ?? 0n),
    fee: BigInt((v.fee as bigint | undefined) ?? 0n),
    feeBps: Number(v.feeBps ?? 0),
  };
}
