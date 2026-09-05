import "server-only";
import { unstable_cache } from "next/cache";
import { auctionHouseAbi } from "../abi";
import { targetChainId } from "../chains";
import { deployment, vaultBySymbol, vaultName } from "../deployment";
import { vaultDefaults } from "../vault-defaults";
import { multicall, pick, type Call } from "./client";
import { getOverview } from "./overview";
import type { CalcVaultDto, OverviewDto, SeriesKind } from "./types";

/** The five tickers the landing shows, in its order. Deployed ones get chain data. */
export const LANDING_TICKERS = ["NVDA", "TSLA", "GME", "QQQ", "SPY"] as const;

const bpsPair = (v: unknown): [number, number] | null => {
  if (!v) return null;
  const [lo, hi] = v as readonly [number | bigint, number | bigint];
  return [Number(lo), Number(hi)];
};

async function readCalcVaults(overview: OverviewDto): Promise<CalcVaultDto[]> {
  const ah = deployment.core.auctionHouse;
  const deployed = LANDING_TICKERS.map((s) => vaultBySymbol(s)).filter((v) => v !== undefined);
  const bounds = await multicall(
    deployed.flatMap(
      (v) =>
        [
          { address: ah, abi: auctionHouseAbi, functionName: "strikeDistanceBounds", args: [v.vault, 0] },
          { address: ah, abi: auctionHouseAbi, functionName: "strikeDistanceBounds", args: [v.vault, 1] },
        ] satisfies Call[],
    ),
  );

  return LANDING_TICKERS.map((symbol) => {
    const d = vaultDefaults(symbol);
    const v = vaultBySymbol(symbol);
    const snap = v ? overview.vaults.find((x) => x.symbol === v.symbol) : undefined;
    if (!v || !snap) {
      return {
        symbol,
        name: vaultName(symbol),
        deployed: false,
        volBps: d.fallbackVolAnnualBps,
        capBps: { ...d.strikeDistanceBps },
        capSource: "default",
        bounds: null,
        lastAuction: null,
        capUsedFraction: null,
        href: null,
      };
    }
    const i = deployed.indexOf(v);
    const wk = bpsPair(pick<unknown>(bounds[i * 2], null));
    const we = bpsPair(pick<unknown>(bounds[i * 2 + 1], null));

    // Cap the model starts at: the strike distance of the current/last auction, else the keeper default.
    const capBps = { ...d.strikeDistanceBps };
    let capSource: CalcVaultDto["capSource"] = "default";
    const rows = overview.history[v.symbol] ?? [];
    const lastOfKind = (kind: SeriesKind) =>
      rows.find((r) => r.kind === kind && r.strikeDistanceBps !== null && r.strikeDistanceBps > 0);
    const wkRow = lastOfKind(0);
    const weRow = lastOfKind(1);
    if (wkRow) {
      capBps.weekday = wkRow.strikeDistanceBps as number;
      capSource = "auction";
    }
    if (weRow) {
      capBps.weekend = weRow.strikeDistanceBps as number;
      capSource = "auction";
    }

    const cleared = rows.find((r) => r.auction.state === "CLEARED" && r.premiumFraction !== null);
    return {
      symbol,
      name: vaultName(symbol),
      deployed: true,
      volBps: d.fallbackVolAnnualBps,
      capBps,
      capSource,
      bounds: wk && we ? { weekday: wk, weekend: we } : null,
      lastAuction: cleared
        ? {
            fraction: cleared.premiumFraction as number,
            kind: cleared.kind,
            seriesId: cleared.id,
            closedAt: cleared.auction.auctionClose,
          }
        : null,
      capUsedFraction: snap.capUsedFraction,
      href: `/vaults/${v.symbol}`,
    };
  });
}

async function readLanding() {
  const overview = await getOverview();
  const calc = await readCalcVaults(overview);
  return { overview, calc };
}

export const getLanding = unstable_cache(readLanding, ["landing", String(targetChainId)], {
  revalidate: 30,
  tags: ["overview", "landing"],
});
