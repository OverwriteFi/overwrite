import "server-only";
import { unstable_cache } from "next/cache";
import {
  capControllerAbi,
  emissionsControllerAbi,
  safetyModuleAbi,
  writePriceOracleAbi,
  CapMode,
} from "../abi";
import { targetChainId } from "../chains";
import { deployment, vaults } from "../deployment";
import { chainNow, multicall, pick, type Call } from "./client";
import type { StakeOverviewDto } from "./types";

const s = (v: unknown): string => String((v as bigint | number | undefined) ?? 0);
const ZERO = "0x0000000000000000000000000000000000000000";

export const stakeEnabled = process.env.NEXT_PUBLIC_STAKE_ENABLED === "true";

async function readStake(): Promise<StakeOverviewDto> {
  const now = await chainNow();
  const t = deployment.token;
  const cc = deployment.core.capController;
  if (!t) {
    return {
      chainNow: s(now),
      enabled: stakeEnabled,
      safetyModule: null,
      writeToken: null,
      capMode: "FIXED",
      wired: false,
      totalStaked: "0",
      totalShares: "0",
      valueUsd: "0",
      valueOk: false,
      writePrice8: null,
      k: "5000000000000000000",
      cooldownSeconds: String(14 * 86_400),
      claimWindowSeconds: String(3 * 86_400),
      maxSlashBps: 3000,
      slashIntervalSeconds: String(14 * 86_400),
      emissionsRate: "0",
      emissionsWired: false,
      vaults: [],
    };
  }
  const sm = t.safetyModule;
  const base = await multicall([
    { address: sm, abi: safetyModuleAbi, functionName: "totalStaked" },
    { address: sm, abi: safetyModuleAbi, functionName: "totalShares" },
    { address: sm, abi: safetyModuleAbi, functionName: "valueUSDView" },
    { address: sm, abi: safetyModuleAbi, functionName: "COOLDOWN" },
    { address: sm, abi: safetyModuleAbi, functionName: "CLAIM_WINDOW" },
    { address: sm, abi: safetyModuleAbi, functionName: "MAX_SLASH_BPS" },
    { address: sm, abi: safetyModuleAbi, functionName: "SLASH_INTERVAL" },
    { address: sm, abi: safetyModuleAbi, functionName: "writeToken" },
    { address: cc, abi: capControllerAbi, functionName: "capMode" },
    { address: cc, abi: capControllerAbi, functionName: "k" },
    { address: cc, abi: capControllerAbi, functionName: "safetyModule" },
    { address: t.writePriceOracle, abi: writePriceOracleAbi, functionName: "writePrice" },
    { address: t.emissionsController, abi: emissionsControllerAbi, functionName: "rate" },
    { address: t.emissionsController, abi: emissionsControllerAbi, functionName: "sink" },
    ...vaults.flatMap(
      (v) =>
        [
          { address: cc, abi: capControllerAbi, functionName: "capWeightBps", args: [v.vault] },
          { address: cc, abi: capControllerAbi, functionName: "capUSD", args: [v.vault] },
          { address: cc, abi: capControllerAbi, functionName: "vaultCapUSD", args: [v.vault] },
        ] satisfies Call[],
    ),
  ] satisfies Call[]);

  const [valueUsd, valueOk] = pick<readonly [bigint, boolean]>(base[2], [0n, false]);
  const k = pick<bigint>(base[9], 5n * 10n ** 18n);
  const capModeName = CapMode[Number(pick(base[8], 0))] ?? "FIXED";
  const ccSafety = pick<string>(base[10], ZERO);
  const price = base[11]?.ok ? (base[11].value as readonly [bigint, boolean]) : null;
  const sink = pick<string>(base[13], ZERO);

  const perVault = vaults.map((v, i) => {
    const o = 14 + i * 3;
    const weightBps = Number(pick(base[o], 0n));
    const fixedCapUsd = pick<bigint>(base[o + 1], 0n);
    const liveCapUsd = pick<bigint>(base[o + 2], 0n);
    const derived = (((valueUsd * k) / 10n ** 18n) * BigInt(weightBps)) / 10_000n;
    return {
      symbol: v.symbol,
      vault: v.vault,
      weightBps,
      fixedCapUsd: s(fixedCapUsd),
      derivedCapUsd: s(derived),
      liveCapUsd: s(liveCapUsd),
    };
  });

  return {
    chainNow: s(now),
    enabled: stakeEnabled,
    safetyModule: sm,
    writeToken: pick<string>(base[7], t.write) as `0x${string}`,
    capMode: capModeName,
    wired: capModeName === "SAFETY_MODULE" && ccSafety.toLowerCase() === sm.toLowerCase(),
    totalStaked: s(pick(base[0], 0n)),
    totalShares: s(pick(base[1], 0n)),
    valueUsd: s(valueUsd),
    valueOk,
    writePrice8: price && price[1] ? s(price[0]) : null,
    k: s(k),
    cooldownSeconds: s(pick(base[3], 14n * 86_400n)),
    claimWindowSeconds: s(pick(base[4], 3n * 86_400n)),
    maxSlashBps: Number(pick(base[5], 3000n)),
    slashIntervalSeconds: s(pick(base[6], 14n * 86_400n)),
    emissionsRate: s(pick(base[12], 0n)),
    emissionsWired: sink.toLowerCase() === sm.toLowerCase(),
    vaults: perVault,
  };
}

export const getStakeOverview = unstable_cache(readStake, ["stake", String(targetChainId)], {
  revalidate: 30,
  tags: ["stake"],
});
