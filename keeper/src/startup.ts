import type { PublicClient } from "viem";
import {
  auctionHouseAbi,
  erc20Abi,
  riskModuleAbi,
  settlementOracleAbi,
  WEEKDAY,
  WEEKEND,
} from "./abi/index.js";
import { multicall } from "./chain/multicall.js";
import type { Clients } from "./chain/clients.js";
import { activeVaults, type ResolvedConfig } from "./config.js";
import type { Logger } from "./logger.js";
import { nyOffsetSeconds } from "./time/nyse.js";

/**
 * Startup assertions.
 *
 * Split into two groups on purpose.
 *
 * **Always fatal** — things that make the keeper wrong rather than merely unprotected: it does not hold
 * `KEEPER_ROLE`; a configured strike distance is outside the live protocol/curator bounds; the runtime's
 * timezone database is not there.
 *
 * **Fatal only when `sharedKeysAllowed` is false** — the separation-of-duties properties. On 46630 they
 * are *all* false by design: D-105 records that one funded key is admin, guardian, treasury and keeper,
 * and `MockDeployLib` mints it a million USDG. Making these unconditionally fatal would mean the keeper
 * could never start on the only chain it currently targets; making them chain-conditional in code would
 * put an `if (chainId === 46630)` inside the assertion logic, which is exactly the thing D-105 refused
 * to do in `DeployChecks`. So it is a declared config flag, and the deviation is printed rather than
 * hidden.
 */

export interface StartupReport {
  fatal: string[];
  deviations: string[];
  notes: string[];
}

export async function verifyStartup(args: {
  cfg: ResolvedConfig;
  clients: Clients;
  client: PublicClient;
  log: Logger;
}): Promise<StartupReport> {
  const { cfg, clients, client } = args;
  const d = cfg.deployment;
  const report: StartupReport = { fatal: [], deviations: [], notes: [] };
  const strict = !cfg.file.sharedKeysAllowed;

  /* ── the runtime's timezone data, which the whole schedule rests on ── */
  // A container without full ICU silently reports UTC for every zone, which would put every expiry four
  // hours early and make `canOpen` reject it. Two known instants, one in each US offset.
  const edt = nyOffsetSeconds(1_789_156_800n); // 2026-09-11 20:00Z = 16:00 EDT
  const est = nyOffsetSeconds(1_793_998_800n); // 2026-11-06 21:00Z = 16:00 EST
  if (edt !== -14_400 || est !== -18_000) {
    report.fatal.push(
      `this runtime's America/New_York data is wrong (got ${edt}/${est}, expected -14400/-18000). ` +
        `Every expiry would be computed at the wrong hour. Install full ICU.`,
    );
  } else {
    report.notes.push("timezone data verified across both 2026 US offsets");
  }

  /* ── the one positive role assertion, always fatal ── */
  const hasKeeperRole = await client.readContract({
    address: d.core.auctionHouse,
    abi: auctionHouseAbi,
    functionName: "hasRole",
    args: [
      await client.readContract({
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "KEEPER_ROLE",
      }),
      cfg.keeperAddress,
    ],
  });

  if (cfg.file.role === "full" && !hasKeeperRole) {
    report.fatal.push(
      `${cfg.keeperAddress} does not hold KEEPER_ROLE on the AuctionHouse; openAuction would revert every week. ` +
        `Grant it with the timelock (auctionHouse.setKeeper) or run this instance with role: "settle-only".`,
    );
  } else if (cfg.file.role === "settle-only") {
    report.notes.push(
      "settle-only instance: settle, halt and resolveHaltedByOracle are permissionless, so this key needs no role at all",
    );
  } else {
    report.notes.push(`KEEPER_ROLE confirmed for ${cfg.keeperAddress}`);
  }

  /* ── separation of duties ── */
  const guardianRole = await client.readContract({
    address: d.core.riskModule,
    abi: riskModuleAbi,
    functionName: "GUARDIAN_ROLE",
  });

  const owners = await multicall<unknown>(client, [
    {
      address: d.core.riskModule,
      abi: riskModuleAbi,
      functionName: "hasRole",
      args: [guardianRole, cfg.keeperAddress],
    },
    { address: d.core.auctionHouse, abi: auctionHouseAbi, functionName: "owner" },
    { address: d.core.settlementOracle, abi: settlementOracleAbi, functionName: "owner" },
    {
      address: d.external.usdg,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [cfg.keeperAddress],
    },
  ]);

  const keeperIsGuardian = owners[0]?.ok ? Boolean(owners[0].value) : false;
  const ahOwner = String(owners[1]?.ok ? owners[1].value : "");
  const soOwner = String(owners[2]?.ok ? owners[2].value : "");
  const usdgBalance = owners[3]?.ok ? (owners[3].value as bigint) : 0n;

  const push = (msg: string) => (strict ? report.fatal : report.deviations).push(msg);

  if (keeperIsGuardian) {
    push(
      `the keeper key also holds GUARDIAN_ROLE. D-029 requires two distinct keys so a compromised keeper ` +
        `can still be paused by somebody during the 48 h it takes to revoke it.`,
    );
  }
  for (const [what, owner] of [
    ["AuctionHouse", ahOwner],
    ["SettlementOracle", soOwner],
  ] as const) {
    if (owner.toLowerCase() === cfg.keeperAddress.toLowerCase()) {
      push(`the keeper key owns the ${what}; it should own nothing (the timelock does).`);
    }
  }
  if (usdgBalance > 0n) {
    push(
      `the keeper key holds ${usdgBalance} USDG. THREAT-MODEL T-13's residual is "keeper never holds stock ` +
        `tokens or USDG beyond gas ETH".`,
    );
  }
  if (
    clients.guardian &&
    clients.guardian.address.toLowerCase() === cfg.keeperAddress.toLowerCase()
  ) {
    report.fatal.push("GUARDIAN_PRIVATE_KEY and KEEPER_PRIVATE_KEY are the same key");
  }

  /* ── configured numbers against live on-chain bounds ── */
  for (const { symbol, vault, addresses } of activeVaults(cfg)) {
    for (const [kind, bps, label] of [
      [WEEKDAY, vault.strikeDistanceBps.weekday, "weekday"],
      [WEEKEND, vault.strikeDistanceBps.weekend, "weekend"],
    ] as const) {
      const bounds = await client.readContract({
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "strikeDistanceBounds",
        args: [addresses.vault, kind],
      });
      if (bps < bounds[0] || bps > bounds[1]) {
        report.fatal.push(
          `${symbol} ${label} strikeDistanceBps ${bps} is outside the live bounds [${bounds[0]}, ${bounds[1]}]; ` +
            `openAuction would revert DistanceOutOfBounds. (SPEC §7.2's "ETF 200 bps" weekday default is ` +
            `below STRIKE_LO_WEEKDAY = 300 — see DECISIONS D-109.)`,
        );
      }

      const onChainMin = await client.readContract({
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "minReserveBpsOfSpot",
        args: [addresses.vault, kind],
      });
      const cfgMax =
        kind === WEEKDAY ? vault.maxReserveBpsOfSpot.weekday : vault.maxReserveBpsOfSpot.weekend;
      const cfgMin = kind === WEEKDAY ? vault.minReserveBps.weekday : vault.minReserveBps.weekend;
      if (cfgMax < onChainMin) {
        report.fatal.push(
          `${symbol} ${label} maxReserveBpsOfSpot ${cfgMax} is below the on-chain minReserveBpsOfSpot ` +
            `${onChainMin}; the keeper-side ceiling would push every reserve under the contract's floor ` +
            `and revert ReserveOutOfBounds.`,
        );
      }
      if (cfgMin < onChainMin) {
        report.notes.push(
          `${symbol} ${label} minReserveBps ${cfgMin} is below the on-chain floor ${onChainMin}; the ` +
            `contract's floor governs.`,
        );
      }
    }
  }

  return report;
}
