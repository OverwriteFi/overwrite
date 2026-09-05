import "server-only";
import { unstable_cache } from "next/cache";
import type { Address } from "viem";
import {
  aggregatorAbi,
  auctionHouseAbi,
  capControllerAbi,
  erc20Abi,
  feeRouterAbi,
  optionTokenAbi,
  riskModuleAbi,
  settlementOracleAbi,
  stockTokenAbi,
  vaultAbi,
  AuctionState,
  CapMode,
  SeriesState,
  VaultState,
} from "../abi";
import { targetChainId } from "../chains";
import { deployment, vaultName, vaults, type DeployedVault } from "../deployment";
import { estimatePremiumFraction } from "../pricing/estimate";
import { nextEvent } from "../time/schedule";
import { vaultDefaults } from "../vault-defaults";
import { chainNow, multicall, pick, type Call } from "./client";
import type {
  AuctionDto,
  Outcome,
  OverviewDto,
  PremiumFigure,
  SeriesDto,
  SeriesKind,
  SeriesRowDto,
  VaultSnapshotDto,
  VaultStatus,
} from "./types";

const s = (v: unknown): string => String((v as bigint | number | undefined) ?? 0);
const b = (v: unknown): bigint => BigInt((v as bigint | number | string | undefined) ?? 0);
const ZERO = "0x0000000000000000000000000000000000000000";

const HALTED_TIMEOUT = 7n * 86_400n;

function toSeries(id: bigint, v: Record<string, unknown>): SeriesDto {
  return {
    id: s(id),
    kind: Number(v.kind ?? 0) as SeriesKind,
    state: SeriesState[Number(v.state ?? 0)] ?? "NONE",
    settlementPath: Number(v.settlementPath ?? 0),
    expiry: s(v.expiry),
    strike: s(v.strike),
    offeredQty: s(v.offeredQty),
    filledQty: s(v.filledQty),
    settlementPrice: s(v.settlementPrice),
    payoutPerOption: s(v.payoutPerOption),
    multiplierAtOpen: s(v.multiplierAtOpen),
  };
}

function toAuction(id: bigint, v: Record<string, unknown>): AuctionDto {
  return {
    id: s(id),
    vault: v.vault as Address,
    kind: Number(v.kind ?? 0) as SeriesKind,
    state: AuctionState[Number(v.state ?? 0)] ?? "NONE",
    auctionOpen: s(v.auctionOpen),
    auctionClose: s(v.auctionClose),
    expiry: s(v.expiry),
    sRef: s(v.sRef),
    strike: s(v.strike),
    offeredQty: s(v.offeredQty),
    reservePrice: s(v.reservePrice),
    clearingPrice: s(v.clearingPrice),
    filledQty: s(v.filledQty),
    premiumGross: s(v.premiumGross),
    fee: s(v.fee),
    feeBps: Number(v.feeBps ?? 0),
  };
}

/** clearingPrice (USDG 6 dp per 1e18-unit option) over sRef (USD 8 dp) → fraction of spot. */
export function premiumFractionOf(clearingPrice: bigint, sRef: bigint): number | null {
  if (sRef === 0n || clearingPrice === 0n) return null;
  return (Number(clearingPrice) * 100) / Number(sRef);
}

function outcomeOf(a: AuctionDto, se: SeriesDto | null): Outcome {
  if (a.state === "OPEN") return "auction-open";
  if (a.state === "SKIPPED" || se?.state === "SKIPPED") return "skipped";
  if (!se) return "live";
  switch (se.state) {
    case "LIVE":
      return "live";
    case "HALTED":
      return "halted";
    case "RESOLVED":
      return BigInt(se.payoutPerOption) > 0n ? "called-away" : "resolved";
    case "SETTLED":
      return BigInt(se.payoutPerOption) > 0n ? "called-away" : "expired-worthless";
    case "AUCTION":
      return "auction-open";
    default:
      return "live";
  }
}

function toRow(a: AuctionDto, se: SeriesDto | null): SeriesRowDto {
  const sRef = BigInt(a.sRef);
  const offered = BigInt(a.offeredQty);
  return {
    id: a.id,
    kind: a.kind,
    auction: a,
    series: se,
    outcome: outcomeOf(a, se),
    premiumFraction: a.state === "CLEARED" ? premiumFractionOf(BigInt(a.clearingPrice), sRef) : null,
    premiumNet: s(BigInt(a.premiumGross) - BigInt(a.fee)),
    fillFraction: offered > 0n ? Number(BigInt(a.filledQty)) / Number(offered) : null,
    strikeDistanceBps:
      sRef > 0n ? Math.round((Number(BigInt(a.strike) - sRef) * 10_000) / Number(sRef)) : null,
    payoutFraction: se ? Number(BigInt(se.payoutPerOption)) / 1e18 : null,
  };
}

/** Every series ever opened, grouped by vault address, newest first. State reads only — no logs. */
async function readAllSeries(): Promise<Map<Address, SeriesRowDto[]>> {
  const ot = deployment.core.optionToken;
  const ah = deployment.core.auctionHouse;
  const [next] = await multicall([{ address: ot, abi: optionTokenAbi, functionName: "nextSeriesId" }]);
  const nextId = pick<bigint>(next, 1n);
  const ids: bigint[] = [];
  for (let i = 1n; i < nextId; i++) ids.push(i);
  const auctionsRaw = await multicall(
    ids.map((id) => ({ address: ah, abi: auctionHouseAbi, functionName: "auctions", args: [id] })),
  );
  const auctions: AuctionDto[] = [];
  auctionsRaw.forEach((r, i) => {
    if (r.ok) {
      const a = toAuction(ids[i], r.value as Record<string, unknown>);
      if (a.vault && a.vault !== ZERO) auctions.push(a);
    }
  });
  const seriesRaw = await multicall(
    auctions.map((a) => ({
      address: a.vault,
      abi: vaultAbi,
      functionName: "series",
      args: [BigInt(a.id)],
    })),
  );
  const byVault = new Map<Address, SeriesRowDto[]>();
  auctions.forEach((a, i) => {
    const r = seriesRaw[i];
    const se = r && r.ok ? toSeries(BigInt(a.id), r.value as Record<string, unknown>) : null;
    const list = byVault.get(a.vault) ?? [];
    list.push(toRow(a, se));
    byVault.set(a.vault, list);
  });
  for (const list of byVault.values()) list.sort((x, y) => Number(BigInt(y.id) - BigInt(x.id)));
  return byVault;
}

function statusOf(
  state: VaultSnapshotDto["state"],
  sunset: boolean,
  now: bigint,
  auction: AuctionDto | null,
  series: SeriesDto | null,
): VaultStatus {
  switch (state) {
    case "AUCTION":
      return auction && now >= BigInt(auction.auctionClose) ? "clearing" : "auction-open";
    case "LIVE":
      return series && now >= BigInt(series.expiry) ? "settling" : "active";
    case "HALTED":
      return "halted";
    default:
      return sunset ? "sunset" : "idle";
  }
}

async function readVault(
  v: DeployedVault,
  now: bigint,
  history: SeriesRowDto[],
): Promise<VaultSnapshotDto> {
  const { auctionHouse: ah, riskModule: rm, settlementOracle: so, capController: cc, feeRouter: fr } =
    deployment.core;
  const usdg = deployment.external.usdg;

  const base = await multicall([
    { address: v.vault, abi: vaultAbi, functionName: "state" },
    { address: v.vault, abi: vaultAbi, functionName: "totalAssets" },
    { address: v.vault, abi: vaultAbi, functionName: "freeAssets" },
    { address: v.vault, abi: vaultAbi, functionName: "pendingRedeemAssets" },
    { address: v.vault, abi: vaultAbi, functionName: "payoutOwed" },
    { address: v.vault, abi: vaultAbi, functionName: "sunset" },
    { address: v.vault, abi: vaultAbi, functionName: "currentSeriesId" },
    { address: v.vault, abi: vaultAbi, functionName: "queueLengths" },
    { address: v.vault, abi: vaultAbi, functionName: "totalSupply" },
    { address: ah, abi: auctionHouseAbi, functionName: "lastWeekdayExpiry", args: [v.vault] },
    { address: rm, abi: riskModuleAbi, functionName: "depositsPaused", args: [v.vault] },
    { address: rm, abi: riskModuleAbi, functionName: "auctionsPaused", args: [v.vault] },
    { address: so, abi: settlementOracleAbi, functionName: "capPrice", args: [v.vault] },
    { address: cc, abi: capControllerAbi, functionName: "vaultCapUSD", args: [v.vault] },
    { address: fr, abi: feeRouterAbi, functionName: "feeBps", args: [v.vault] },
    { address: v.stock, abi: stockTokenAbi, functionName: "uiMultiplier" },
    { address: v.stock, abi: stockTokenAbi, functionName: "newUIMultiplier" },
    { address: v.stock, abi: stockTokenAbi, functionName: "effectiveAt" },
    { address: v.stock, abi: stockTokenAbi, functionName: "oraclePaused" },
    { address: v.stock, abi: stockTokenAbi, functionName: "decimals" },
    { address: v.stock, abi: stockTokenAbi, functionName: "symbol" },
    { address: usdg, abi: erc20Abi, functionName: "decimals" },
    { address: usdg, abi: erc20Abi, functionName: "symbol" },
    { address: v.feed, abi: aggregatorAbi, functionName: "latestRoundData" },
    { address: v.feed, abi: aggregatorAbi, functionName: "decimals" },
  ] satisfies Call[]);

  const state = VaultState[Number(pick(base[0], 0))] ?? "IDLE";
  const totalAssets = pick<bigint>(base[1], 0n);
  const sunset = pick<boolean>(base[5], false);
  const currentSeriesId = pick<bigint>(base[6], 0n);
  const queue = pick<readonly [bigint, bigint]>(base[7], [0n, 0n]);
  const totalSupply = pick<bigint>(base[8], 0n);
  const cap = pick<readonly [bigint, boolean]>(base[12], [0n, false]);
  const vaultCapUsd = pick<bigint>(base[13], 0n);
  const round = base[23]?.ok ? (base[23].value as readonly [bigint, bigint, bigint, bigint, bigint]) : null;

  const extra = await multicall([
    ...(currentSeriesId > 0n
      ? ([
          { address: v.vault, abi: vaultAbi, functionName: "series", args: [currentSeriesId] },
          { address: ah, abi: auctionHouseAbi, functionName: "auctions", args: [currentSeriesId] },
          { address: so, abi: settlementOracleAbi, functionName: "records", args: [currentSeriesId] },
        ] satisfies Call[])
      : []),
    { address: cc, abi: capControllerAbi, functionName: "remainingDepositAssets", args: [v.vault, totalAssets] },
    { address: v.vault, abi: vaultAbi, functionName: "convertToAssets", args: [10n ** 24n] },
  ] satisfies Call[]);

  let series: SeriesDto | null = null;
  let auction: AuctionDto | null = null;
  let haltedAt: string | null = null;
  let cursor = 0;
  if (currentSeriesId > 0n) {
    const se = extra[cursor++];
    const au = extra[cursor++];
    const rec = extra[cursor++];
    if (se?.ok) series = toSeries(currentSeriesId, se.value as Record<string, unknown>);
    if (au?.ok) auction = toAuction(currentSeriesId, au.value as Record<string, unknown>);
    if (rec?.ok) {
      const r = rec.value as Record<string, unknown>;
      if (r.halted) haltedAt = s(r.haltedAt);
    }
  }
  const rem = extra[cursor++];
  let remainingDepositAssets: string | null = null;
  if (rem?.ok) {
    const [assets, ok] = rem.value as readonly [bigint, boolean];
    remainingDepositAssets = ok ? s(assets) : null;
  }
  const assetsPerShare = s(pick<bigint>(extra[cursor], 0n));

  const sRef = cap[1] ? cap[0] : null;
  // used6 = totalAssets(18) × price(8) / 1e20, the CapController's own arithmetic.
  const tvl6 = sRef !== null ? (totalAssets * sRef) / 10n ** 20n : null;
  const capUsedFraction =
    tvl6 !== null && vaultCapUsd > 0n ? Number(tvl6) / Number(vaultCapUsd) : null;
  const capacityUsd =
    tvl6 !== null ? s(vaultCapUsd > tvl6 ? vaultCapUsd - tvl6 : 0n) : null;

  // Premium figures: last cleared auction per kind, else the model estimate.
  const cleared = history.filter((r) => r.auction.state === "CLEARED" && r.premiumFraction !== null);
  const lastOf = (kind: SeriesKind): PremiumFigure => {
    const hit = cleared.find((r) => r.kind === kind);
    return hit
      ? { fraction: hit.premiumFraction, source: "auction", kind, seriesId: hit.id }
      : { fraction: estimatePremiumFraction(v.symbol, kind), source: "estimate", kind };
  };
  const weekday = lastOf(0);
  const weekend = lastOf(1);
  const latest = cleared[0];
  const current: PremiumFigure = latest
    ? { fraction: latest.premiumFraction, source: "auction", kind: latest.kind, seriesId: latest.id }
    : weekday;
  const annualized = {
    fraction:
      weekday.fraction !== null && weekend.fraction !== null
        ? (weekday.fraction + weekend.fraction) * 52
        : null,
    source:
      weekday.source === weekend.source ? weekday.source : ("mixed" as const),
  };

  const d = vaultDefaults(v.symbol);
  const liveDistance =
    auction && BigInt(auction.sRef) > 0n
      ? Math.round((Number(BigInt(auction.strike) - BigInt(auction.sRef)) * 10_000) / Number(BigInt(auction.sRef)))
      : null;
  const strikeDistance =
    liveDistance !== null && auction
      ? { bps: liveDistance, source: "auction" as const, kind: auction.kind }
      : { bps: d.strikeDistanceBps.weekday, source: "default" as const, kind: 0 as SeriesKind };

  const status = statusOf(state, sunset, now, auction, series);
  const ev = nextEvent({
    now,
    vaultState: state,
    sunset,
    auctionClose: auction ? BigInt(auction.auctionClose) : null,
    expiry: series ? BigInt(series.expiry) : null,
    lastWeekdayExpiry: pick<bigint>(base[9], 0n),
    currentKind: series ? series.kind : null,
    currentExpiry: series ? BigInt(series.expiry) : null,
    haltedAt: haltedAt ? BigInt(haltedAt) : null,
    haltedTimeout: HALTED_TIMEOUT,
  });

  return {
    symbol: v.symbol,
    name: vaultName(v.symbol),
    addresses: v,
    state,
    status,
    totalAssets: s(totalAssets),
    totalSupply: s(totalSupply),
    freeAssets: s(pick(base[2], 0n)),
    pendingRedeemAssets: s(pick(base[3], 0n)),
    payoutOwed: s(pick(base[4], 0n)),
    sunset,
    currentSeriesId: s(currentSeriesId),
    series,
    auction,
    queue: { deposits: s(queue[0]), redeems: s(queue[1]) },
    lastWeekdayExpiry: s(pick(base[9], 0n)),
    depositsPaused: pick<boolean>(base[10], false),
    auctionsPaused: pick<boolean>(base[11], false),
    feeBps: Number(pick(base[14], 1000)),
    sRef: sRef !== null ? s(sRef) : null,
    vaultCapUsd: s(vaultCapUsd),
    remainingDepositAssets,
    capUsedFraction,
    capacityUsd,
    tvlUsd: tvl6 !== null ? s(tvl6) : null,
    stock: {
      symbol: pick<string>(base[20], v.symbol),
      decimals: Number(pick(base[19], 18)),
      uiMultiplier: s(pick(base[15], 10n ** 18n)),
      newUIMultiplier: s(pick(base[16], 0n)),
      effectiveAt: s(pick(base[17], 0n)),
      oraclePaused: pick<boolean>(base[18], false),
    },
    usdg: { decimals: Number(pick(base[21], 6)), symbol: pick<string>(base[22], "USDG") },
    feed: round
      ? { answer: s(round[1]), updatedAt: s(round[3]), decimals: Number(pick(base[24], 8)) }
      : null,
    haltedAt,
    nextEvent: { kind: ev.kind, at: s(ev.at), label: ev.label },
    premium: { current, weekday, weekend, annualized },
    strikeDistance,
    assetsPerShare,
  };
}

async function readOverview(): Promise<OverviewDto> {
  const now = await chainNow();
  const [byVault, capModeRaw] = await Promise.all([
    readAllSeries(),
    multicall([{ address: deployment.core.capController, abi: capControllerAbi, functionName: "capMode" }]),
  ]);
  const history: Record<string, SeriesRowDto[]> = {};
  const snapshots = await Promise.all(
    vaults.map((v) => {
      const rows = byVault.get(v.vault) ?? [];
      history[v.symbol] = rows;
      return readVault(v, now, rows);
    }),
  );
  return {
    chainId: targetChainId,
    chainNow: s(now),
    fetchedAt: new Date().toISOString(),
    vaults: snapshots,
    history,
    capMode: CapMode[Number(pick(capModeRaw[0], 0))] ?? "FIXED",
  };
}

/** Shared, wallet-independent state. One cache entry, revalidated every 30 s. */
export const getOverview = unstable_cache(readOverview, ["overview", String(targetChainId)], {
  revalidate: 30,
  tags: ["overview"],
});

/** Convenience for the vault page. */
export async function getVault(symbol: string) {
  const o = await getOverview();
  const v = o.vaults.find((x) => x.symbol.toUpperCase() === symbol.toUpperCase());
  if (!v) return null;
  return { overview: o, vault: v, history: o.history[v.symbol] ?? [] };
}

export { b as toBigInt };
