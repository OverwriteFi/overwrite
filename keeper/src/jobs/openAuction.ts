import type { Address, PublicClient } from "viem";
import { auctionHouseAbi, WEEKDAY, WEEKEND, kindName, type SeriesKind } from "../abi/index.js";
import { reasonToString } from "../chain/errors.js";
import type { Sender } from "../chain/tx.js";
import type { KeeperFileConfig, VaultConfig } from "../config.js";
import type { Logger } from "../logger.js";
import { estimateVol, type VolEstimate } from "../pricing/realisedVol.js";
import { quoteReserve, type ReserveQuote } from "../pricing/reserve.js";
import type { VaultSnapshot } from "../protocol.js";
import { WEEK, weekStart, weekendExpiryFor } from "../time/epoch.js";
import { expiryCalendarNote, fridayCloseUtc } from "../time/nyse.js";
import type { StateDir } from "../state.js";

/**
 * `openAuction` — the one privileged call in the protocol (`KEEPER_ROLE`, D-028).
 *
 * The keeper supplies three numbers and the contract derives everything else. `expiry` because the
 * DST offset is off-chain knowledge (D-046); `strikeDistanceBps` because the strike itself is read from
 * `sRef` on chain and never keeper-supplied (SPEC §7.2); and `reservePrice`, which is the only value the
 * contract cannot verify and merely bounds (SPEC §8.3).
 *
 * Everything here is therefore about getting those three right and proving it before signing.
 */

export interface OpenPlan {
  kind: SeriesKind;
  expiry: bigint;
  strikeDistanceBps: number;
  strike: bigint;
  sRef: bigint;
  reserve: ReserveQuote;
  vol: VolEstimate;
  calendarNote: string | null;
}

/** WEEKDAY expiry: 16:00 ET on the Friday of the *next* epoch week (epoch weeks start Thursday). */
export const weekdayExpiryFor = (now: bigint): bigint => fridayCloseUtc(weekStart(now) + WEEK);

/**
 * WEEKEND expiry: Sunday 23:59:00 UTC of the epoch week containing *this* Friday. Derived from the
 * Friday, never from `now` via the contract's `scheduledExpiry(WEEKEND, ·)` — called with a Monday that
 * returns a Sunday which has already passed.
 */
export const weekendExpiryAt = (now: bigint): bigint => weekendExpiryFor(now);

export async function planOpen(args: {
  client: PublicClient;
  auctionHouse: Address;
  snapshot: VaultSnapshot;
  vaultCfg: VaultConfig;
  file: KeeperFileConfig;
  kind: SeriesKind;
  now: bigint;
  state: StateDir;
  log: Logger;
}): Promise<{ ok: true; plan: OpenPlan } | { ok: false; reason: string }> {
  const { client, auctionHouse, snapshot, vaultCfg, file, kind, now, log } = args;
  const vault = snapshot.addresses.vault;

  const expiry = kind === WEEKDAY ? weekdayExpiryFor(now) : weekendExpiryAt(now);

  // The contract's own pre-flight: schedule window, expiry band, weekday gap, then every vault-side
  // check (IDLE, sunset, pauses, oracle pause, staged multiplier).
  const [ok, reasonWord] = await client.readContract({
    address: auctionHouse,
    abi: auctionHouseAbi,
    functionName: "canOpen",
    args: [vault, kind, expiry, now],
  });
  if (!ok) return { ok: false, reason: reasonToString(reasonWord) };

  // `canOpen` does not look at the balance; `openSeries` reverts `NothingToOffer` on an empty vault.
  // Catching it here keeps an empty vault an INFO line rather than a weekly simulated revert.
  if (snapshot.totalAssets === 0n) return { ok: false, reason: "NO_ASSETS" };

  const sRef = await client.readContract({
    address: auctionHouse,
    abi: auctionHouseAbi,
    functionName: "referencePrice",
    args: [vault],
  });

  const strikeDistanceBps =
    kind === WEEKDAY ? vaultCfg.strikeDistanceBps.weekday : vaultCfg.strikeDistanceBps.weekend;

  const [bounds, strike, reserveBounds] = await Promise.all([
    client.readContract({
      address: auctionHouse,
      abi: auctionHouseAbi,
      functionName: "strikeDistanceBounds",
      args: [vault, kind],
    }),
    client.readContract({
      address: auctionHouse,
      abi: auctionHouseAbi,
      functionName: "computeStrike",
      args: [sRef, strikeDistanceBps],
    }),
    client.readContract({
      address: auctionHouse,
      abi: auctionHouseAbi,
      functionName: "reserveBounds",
      args: [vault, kind, sRef],
    }),
  ]);

  // Startup already validated this, but `setMinStrikeDistanceBps` is a live timelock call, so a floor
  // can move under a running keeper. Refuse rather than clamp: silently selling a different option than
  // the operator configured is the failure D-027 exists to prevent.
  if (strikeDistanceBps < bounds[0] || strikeDistanceBps > bounds[1]) {
    return {
      ok: false,
      reason: `STRIKE_OUT_OF_BOUNDS: configured ${strikeDistanceBps} bps is outside the live [${bounds[0]}, ${bounds[1]}]`,
    };
  }

  const vol = await estimateVol({
    client,
    feed: snapshot.addresses.feed,
    now,
    params: {
      windowDays: file.pricing.volWindowDays,
      minSamples: file.pricing.minVolSamples,
      floor: file.pricing.volFloorBps / 1e4,
      cap: file.pricing.volCapBps / 1e4,
      fallback: vaultCfg.fallbackVolAnnualBps / 1e4,
      maxRoundScan: file.pricing.maxRoundScan,
    },
  });

  args.state.writeJson(`vol-${snapshot.symbol}.json`, {
    computedAt: now.toString(),
    kind: kindName(kind),
    ...vol,
  });

  const reserve = quoteReserve({
    sRef,
    strike,
    now,
    expiry,
    vol,
    lo: reserveBounds[0],
    hi: reserveBounds[1],
    maxReserveBpsOfSpot:
      kind === WEEKDAY
        ? vaultCfg.maxReserveBpsOfSpot.weekday
        : vaultCfg.maxReserveBpsOfSpot.weekend,
    minReserveBps:
      kind === WEEKDAY ? vaultCfg.minReserveBps.weekday : vaultCfg.minReserveBps.weekend,
    reserveMarginBps: file.pricing.reserveMarginBps,
    riskFreeRateBps: file.pricing.riskFreeRateBps,
    reserveFactorBps: file.pricing.reserveFactorBps,
    variance: {
      overnightVarianceDays: file.pricing.overnightVarianceDays,
      weekendVarianceDays: file.pricing.weekendVarianceDays,
      sessionsPerYear: file.pricing.sessionsPerYear,
    },
  });

  if (vol.source === "fallback") {
    log.warn(
      { vault: snapshot.symbol, kind: kindName(kind), sigma: vol.sigma, why: vol.reason },
      "using the configured fallback volatility",
    );
  }
  if (reserve.floorBinds) {
    log.warn(
      {
        vault: snapshot.symbol,
        kind: kindName(kind),
        modelPrice: reserve.modelPrice.toString(),
        contractFloor: reserve.lo.toString(),
        coverRatio: Number(reserve.coverRatio.toFixed(3)),
      },
      "the contract's minimum reserve is above the model price; the floor, not the model, set this auction's reserve",
    );
  }

  return {
    ok: true,
    plan: {
      kind,
      expiry,
      strikeDistanceBps,
      strike,
      sRef,
      reserve,
      vol,
      calendarNote: expiryCalendarNote(expiry),
    },
  };
}

export async function openAuction(args: {
  sender: Sender;
  auctionHouse: Address;
  snapshot: VaultSnapshot;
  plan: OpenPlan;
  deploymentVaults: readonly Address[];
  log: Logger;
}) {
  const { sender, auctionHouse, snapshot, plan, deploymentVaults, log } = args;

  // The allowlist gates (contract, function); the target vault arrives as an *argument*, so it is
  // checked here. A config typo must not be able to aim a correctly-allowlisted call at another vault.
  if (!deploymentVaults.some((v) => v.toLowerCase() === snapshot.addresses.vault.toLowerCase())) {
    throw new Error(
      `refusing to open an auction on ${snapshot.addresses.vault}: not in the deployment`,
    );
  }
  if (plan.kind !== WEEKDAY && plan.kind !== WEEKEND) {
    throw new Error(`refusing to open an auction of unknown kind ${String(plan.kind)}`);
  }

  if (plan.calendarNote) log.info({ vault: snapshot.symbol }, plan.calendarNote);
  log.info(
    {
      vault: snapshot.symbol,
      kind: kindName(plan.kind),
      expiry: plan.expiry.toString(),
      sRef: plan.sRef.toString(),
      strike: plan.strike.toString(),
      strikeDistanceBps: plan.strikeDistanceBps,
      reservePrice: plan.reserve.reservePrice.toString(),
      reserveDecidedBy: plan.reserve.decidedBy,
      sigma: Number(plan.vol.sigma.toFixed(4)),
      volSource: plan.vol.source,
      varianceYears: Number(plan.reserve.varianceYears.toFixed(6)),
    },
    "opening auction",
  );

  return sender.send({
    address: auctionHouse,
    abi: auctionHouseAbi,
    functionName: "openAuction",
    args: [
      snapshot.addresses.vault,
      plan.kind,
      plan.expiry,
      plan.strikeDistanceBps,
      plan.reserve.reservePrice,
    ],
    label: `openAuction ${snapshot.symbol} ${kindName(plan.kind)}`,
  });
}
