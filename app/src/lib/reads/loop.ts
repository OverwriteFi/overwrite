import "server-only";
import { unstable_cache } from "next/cache";
import { parseAbiItem, type Address } from "viem";
import {
  bondManagerAbi,
  capControllerAbi,
  feeRouterAbi,
  safetyModuleAbi,
  writeAbi,
  writePriceOracleAbi,
  BondAsset,
  BondKind,
} from "../abi";
import { targetChainId } from "../chains";
import { deployment, vaults } from "../deployment";
import { chainNow, multicall, pick, publicClient, type Call } from "./client";
import { getOverview } from "./overview";
import type { LoopDto } from "./types";

const s = (v: unknown): string => String((v as bigint | number | undefined) ?? 0);
const ZERO = "0x0000000000000000000000000000000000000000";
const WEEK = 7n * 86_400n;

const WRITE_FEE_PAID = parseAbiItem(
  "event WriteFeePaid(address indexed vault, address indexed curator, uint256 feeUSDG, uint256 writeAmount, uint256 burned, uint256 price8)",
);

/**
 * Σ `burned` over FeeRouter.WriteFeePaid, scanned from `FEE_ROUTER_FROM_BLOCK`. Only attempted when that
 * env is set: the public RPC keeps ~19 minutes of history and rejects wide `eth_getLogs` ranges, so the
 * default figure is the supply delta (WRITE.MAX_SUPPLY − totalSupply, invariant I-31).
 */
async function burnedFromEvents(feeRouter: Address): Promise<bigint | null> {
  const from = process.env.FEE_ROUTER_FROM_BLOCK;
  if (!from) return null;
  try {
    const c = publicClient();
    const latest = await c.getBlockNumber();
    const step = 50_000n;
    let total = 0n;
    for (let b = BigInt(from); b <= latest; b += step) {
      const to = b + step - 1n < latest ? b + step - 1n : latest;
      const logs = await c.getLogs({ address: feeRouter, event: WRITE_FEE_PAID, fromBlock: b, toBlock: to });
      for (const l of logs) total += l.args.burned ?? 0n;
    }
    return total;
  } catch {
    return null;
  }
}

async function readLoop(): Promise<LoopDto> {
  const [now, overview] = await Promise.all([chainNow(), getOverview()]);
  const { feeRouter, bondManager, capController } = deployment.core;
  const t = deployment.token;

  const base = await multicall([
    { address: feeRouter, abi: feeRouterAbi, functionName: "writeToken" },
    { address: bondManager, abi: bondManagerAbi, functionName: "writeToken" },
    { address: bondManager, abi: bondManagerAbi, functionName: "bondAsset" },
    { address: bondManager, abi: bondManagerAbi, functionName: "requiredAmountOf", args: [BondAsset.WRITE, BondKind.MM] },
    { address: capController, abi: capControllerAbi, functionName: "k" },
    ...vaults.map(
      (v) => ({ address: capController, abi: capControllerAbi, functionName: "vaultCapUSD", args: [v.vault] }) satisfies Call,
    ),
    ...(t
      ? ([
          { address: t.safetyModule, abi: safetyModuleAbi, functionName: "safetyModuleValueUSD" },
          { address: t.safetyModule, abi: safetyModuleAbi, functionName: "valueUSDView" },
          { address: t.write, abi: writeAbi, functionName: "MAX_SUPPLY" },
          { address: t.write, abi: writeAbi, functionName: "totalSupply" },
          { address: t.write, abi: writeAbi, functionName: "balanceOf", args: [bondManager] },
          { address: t.writePriceOracle, abi: writePriceOracleAbi, functionName: "writePrice" },
        ] satisfies Call[])
      : []),
  ] satisfies Call[]);

  const routerToken = pick<string>(base[0], ZERO);
  const bondToken = pick<string>(base[1], ZERO);
  const bondAsset = Number(pick(base[2], 0));
  const mmBondWrite = pick<bigint>(base[3], 0n);
  const k = pick<bigint>(base[4], 5n * 10n ** 18n);
  let totalCap = 0n;
  vaults.forEach((_, i) => {
    totalCap += pick<bigint>(base[5 + i], 0n);
  });
  const o = 5 + vaults.length;

  let safetyModuleValueUsd: string | null = null;
  let safetyModuleValueOk = false;
  let burned: LoopDto["burned"] = null;
  let bonded: string | null = null;
  let writePrice8: string | null = null;
  if (t) {
    safetyModuleValueUsd = s(pick(base[o], 0n));
    const view = pick<readonly [bigint, boolean]>(base[o + 1], [0n, false]);
    safetyModuleValueOk = view[1];
    const max = pick<bigint>(base[o + 2], 0n);
    const supply = pick<bigint>(base[o + 3], 0n);
    const fromEvents = await burnedFromEvents(feeRouter);
    burned =
      fromEvents !== null
        ? { amount: s(fromEvents), source: "events" }
        : { amount: s(max > supply ? max - supply : 0n), source: "supply" };
    bonded = s(pick(base[o + 4], 0n));
    const price = pick<readonly [bigint, boolean] | null>(base[o + 5], null);
    writePrice8 = price && price[1] ? s(price[0]) : null;
  }

  let totalDeposits = 0n;
  for (const v of overview.vaults) if (v.tvlUsd) totalDeposits += BigInt(v.tvlUsd);

  let premiumGross = 0n;
  let fee = 0n;
  let auctions = 0;
  for (const rows of Object.values(overview.history)) {
    for (const r of rows) {
      if (r.auction.state !== "CLEARED") continue;
      if (BigInt(r.auction.auctionClose) < now - WEEK) continue;
      premiumGross += BigInt(r.auction.premiumGross);
      fee += BigInt(r.auction.fee);
      auctions++;
    }
  }

  return {
    chainNow: s(now),
    // SPEC §11: the timelock sets FeeRouter.writeToken after the token launches; zero until then.
    launched: routerToken.toLowerCase() !== ZERO,
    safetyModuleValueUsd,
    safetyModuleValueOk,
    totalCapUsd: s(totalCap),
    totalDepositsUsd: s(totalDeposits),
    lastWeek: { premiumGross: s(premiumGross), fee: s(fee), auctions },
    burned,
    bonded,
    mmBondWrite: bondToken !== ZERO && bondAsset === BondAsset.WRITE && mmBondWrite > 0n ? s(mmBondWrite) : null,
    writePrice8,
    k: s(k),
  };
}

export const getLoop = unstable_cache(readLoop, ["loop", String(targetChainId)], {
  revalidate: 30,
  tags: ["loop"],
});
