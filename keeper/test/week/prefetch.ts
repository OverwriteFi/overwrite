/**
 * Warms anvil's fork cache before the week runs.
 *
 * Anvil fetches forked state lazily and caches what it fetches for the life of the process. The
 * upstream testnet keeps only ~9 000 blocks — about 19 minutes — of historical state, so any slot the
 * run touches for the first time after that window has closed fails with "metadata is not found".
 * Touching everything up front, while the fork block is still served, removes the deadline from the
 * rest of the run.
 *
 * (`anvil_dumpState` does not help here: it serialises only anvil's own locally-modified accounts, not
 * the forked state it has cached, so a dump taken after forking comes back essentially empty.)
 */
import { loadDeployment } from "../../src/deployment.js";
import {
  auctionHouseAbi,
  bondManagerAbi,
  capControllerAbi,
  erc20Abi,
  feeRouterAbi,
  mockAggregatorAbi,
  optionTokenAbi,
  poolAbi,
  riskModuleAbi,
  settlementOracleAbi,
  stockTokenAbi,
  vaultAbi,
} from "../../src/abi/index.js";
import { multicall } from "../../src/chain/multicall.js";
import { ACCOUNTS, publicClient } from "./anvil.js";

const DEPLOYMENT = process.env.WEEK_DEPLOYMENT ?? "../contracts/deployments/46630.json";
/** Only the vault the week actually drives; prefetching the other one doubles the upstream cost. */
const SYMBOL = process.env.WEEK_SYMBOL ?? "NVDA";
/**
 * How much of the observation ring to warm. The ring has cardinality 1000 but only ~49 slots are
 * initialised, and both readers walk *backwards* from `slot0.observationIndex`, so they never reach the
 * far side. Warming all 1000 meant ~2 000 upstream storage fetches and turned a 45-second prefetch into
 * a seven-minute one — long enough to matter against the RPC's ~19-minute state retention.
 */
const RING_WARM = 160;

async function main(): Promise<void> {
  const d = loadDeployment(DEPLOYMENT, 46630, process.cwd());
  let reads = 0;

  const vaults = d.vaults.filter((v) => v.symbol === SYMBOL);
  if (vaults.length === 0) throw new Error(`no ${SYMBOL} vault in ${DEPLOYMENT}`);

  const everyAddress = [
    d.timelock,
    d.deployer,
    d.external.usdg,
    d.external.usdgUsdFeed,
    ...Object.values(d.core),
    ...vaults.flatMap((v) => [v.vault, v.stock, v.feed, v.pool]),
    ...Object.values(ACCOUNTS).map((a) => a.address),
  ];
  for (const a of everyAddress) {
    await publicClient.getBytecode({ address: a });
    await publicClient.getBalance({ address: a });
    reads += 2;
  }

  for (const v of vaults) {
    const calls = [
      // vault
      ...(
        [
          "state",
          "totalAssets",
          "freeAssets",
          "pendingRedeemAssets",
          "payoutOwed",
          "sunset",
          "currentSeriesId",
          "queueLengths",
          "totalSupply",
          "decimals",
          "asset",
          "stock",
          "usdg",
          "optionToken",
          "auctionHouse",
          "settlement",
          "riskModule",
          "capController",
          "owner",
          "maxQueueOpsPerOpen",
          "maxQueueOpsPerSettle",
          "escrowedRedeemShares",
          "withdrawalClaimableTotal",
          "queuedDepositTokens",
        ] as const
      ).map((fn) => ({ address: v.vault, abi: vaultAbi, functionName: fn })),
      // auction house
      ...(
        [
          "openTolerance",
          "minBidQty",
          "maxBidsPerBidder",
          "priceSource",
          "optionToken",
          "usdg",
          "bondManager",
          "feeRouter",
          "owner",
          "KEEPER_ROLE",
        ] as const
      ).map((fn) => ({
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: fn,
      })),
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "isVault",
        args: [v.vault],
      },
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "lastWeekdayExpiry",
        args: [v.vault],
      },
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "referencePrice",
        args: [v.vault],
      },
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "strikeDistanceBounds",
        args: [v.vault, 0],
      },
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "strikeDistanceBounds",
        args: [v.vault, 1],
      },
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "minReserveBpsOfSpot",
        args: [v.vault, 0],
      },
      {
        address: d.core.auctionHouse,
        abi: auctionHouseAbi,
        functionName: "minReserveBpsOfSpot",
        args: [v.vault, 1],
      },
      // risk module, oracle, cap, fee, bond, option token
      {
        address: d.core.riskModule,
        abi: riskModuleAbi,
        functionName: "currentParams",
        args: [v.vault],
      },
      {
        address: d.core.riskModule,
        abi: riskModuleAbi,
        functionName: "depositsPaused",
        args: [v.vault],
      },
      {
        address: d.core.riskModule,
        abi: riskModuleAbi,
        functionName: "auctionsPaused",
        args: [v.vault],
      },
      {
        address: d.core.riskModule,
        abi: riskModuleAbi,
        functionName: "haltCount",
        args: [v.vault],
      },
      { address: d.core.riskModule, abi: riskModuleAbi, functionName: "GUARDIAN_ROLE" },
      {
        address: d.core.settlementOracle,
        abi: settlementOracleAbi,
        functionName: "vaultConfig",
        args: [v.vault],
      },
      {
        address: d.core.settlementOracle,
        abi: settlementOracleAbi,
        functionName: "capPrice",
        args: [v.vault],
      },
      {
        address: d.core.settlementOracle,
        abi: settlementOracleAbi,
        functionName: "twap",
        args: [v.vault, 3600],
      },
      { address: d.core.settlementOracle, abi: settlementOracleAbi, functionName: "owner" },
      {
        address: d.core.capController,
        abi: capControllerAbi,
        functionName: "remainingDepositAssets",
        args: [v.vault, 0n],
      },
      { address: d.core.feeRouter, abi: feeRouterAbi, functionName: "pending", args: [v.vault] },
      { address: d.core.bondManager, abi: bondManagerAbi, functionName: "auctionHouse" },
      { address: d.core.optionToken, abi: optionTokenAbi, functionName: "nextSeriesId" },
      // token, feed and pool state
      ...(
        [
          "uiMultiplier",
          "newUIMultiplier",
          "effectiveAt",
          "oraclePaused",
          "totalSupply",
          "decimals",
          "owner",
        ] as const
      ).map((fn) => ({ address: v.stock, abi: stockTokenAbi, functionName: fn })),
      { address: v.feed, abi: mockAggregatorAbi, functionName: "latestRoundData" },
      { address: v.feed, abi: mockAggregatorAbi, functionName: "latestId" },
      { address: v.feed, abi: mockAggregatorAbi, functionName: "decimals" },
      { address: d.external.usdgUsdFeed, abi: mockAggregatorAbi, functionName: "latestRoundData" },
      { address: d.external.usdgUsdFeed, abi: mockAggregatorAbi, functionName: "latestId" },
      { address: d.external.usdg, abi: erc20Abi, functionName: "decimals" },
      { address: d.external.usdg, abi: erc20Abi, functionName: "totalSupply" },
      ...(["slot0", "liquidity", "token0", "token1", "fee"] as const).map((fn) => ({
        address: v.pool,
        abi: poolAbi,
        functionName: fn,
      })),
    ];
    await multicall(publicClient, calls);
    reads += calls.length;

    // The feed's whole round history and the pool's whole observation ring.
    const roundIds = Array.from({ length: 40 }, (_, i) => (1n << 64n) | BigInt(i + 1));
    await multicall(
      publicClient,
      roundIds.map((id) => ({
        address: v.feed,
        abi: mockAggregatorAbi,
        functionName: "getRoundData",
        args: [id],
      })),
    );
    await multicall(
      publicClient,
      roundIds.map((id) => ({
        address: d.external.usdgUsdFeed,
        abi: mockAggregatorAbi,
        functionName: "getRoundData",
        args: [id],
      })),
    );
    const slot0 = await publicClient.readContract({
      address: v.pool,
      abi: poolAbi,
      functionName: "slot0",
    });
    const head = slot0[2];
    const card = slot0[3];
    const obs = Array.from({ length: Math.min(RING_WARM, card) }, (_, i) =>
      BigInt((((head - i) % card) + card) % card),
    );
    await multicall(
      publicClient,
      obs.map((i) => ({ address: v.pool, abi: poolAbi, functionName: "observations", args: [i] })),
    );
    reads += roundIds.length * 2 + obs.length;
  }

  process.stdout.write(`prefetched ${reads} reads across ${everyAddress.length} accounts\n`);
}

main().catch((err: unknown) => {
  process.stderr.write(`prefetch failed: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
