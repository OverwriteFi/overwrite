// Emits src/abi/generated.ts from the Foundry artifacts in ../contracts/out.
//
// The keeper needs ~40 of the protocol's ~300 external functions. Rather than hand-copying signatures
// (and getting a tuple field order subtly wrong), this pulls the exact fragments out of the compiled
// artifacts and writes them as viem `as const` ABIs. Run it after any contract change:
//
//   npm run gen:abi
//
// The output is committed, so the keeper builds without contracts/out present.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "..", "contracts", "out");

/** Which fragments each ABI slice keeps. `null` means "everything of that kind". */
const SLICES = {
  auctionHouse: {
    artifact: "AuctionHouse.sol/AuctionHouse.json",
    functions: [
      "openAuction",
      "clear",
      "releaseLocks",
      "canOpen",
      "previewClear",
      "scheduledExpiry",
      "strikeDistanceBounds",
      "reserveBounds",
      "referencePrice",
      "computeStrike",
      "auctions",
      "bids",
      "bidders",
      "currentAuction",
      "lastWeekdayExpiry",
      "isVault",
      "openTolerance",
      "minBidQty",
      "maxBidsPerBidder",
      "minStrikeDistanceBps",
      "minReserveBpsOfSpot",
      "priceSource",
      "optionToken",
      "usdg",
      "bondManager",
      "feeRouter",
      "hasRole",
      "KEEPER_ROLE",
      "owner",
      "refundable",
      "claimableOptions",
      "bidCount",
      "AUCTION_DURATION",
      "WEEK",
      "MON_1400",
      "FRI_1930",
      "FRI_2000",
      "FRI_2130",
      "SUN_2359",
      "WEEKEND_GAP",
      "MAX_WEEKEND_LATE",
      "MAX_OPEN_TOLERANCE",
      "GRID_BPS",
      "STRIKE_LO_WEEKDAY",
      "STRIKE_HI_WEEKDAY",
      "STRIKE_LO_WEEKEND",
      "STRIKE_HI_WEEKEND",
      "RESERVE_LO_BPS",
      "RESERVE_HI_BPS",
      "MAX_BIDS",
      // used only by the fork harness, never by the keeper's allowlist
      "bid",
      "claimOptions",
      "withdrawRefund",
      "setKeeper",
    ],
    events: ["AuctionOpened", "AuctionCleared", "AuctionSkipped", "BidPlaced", "BidFilled"],
    errors: null,
  },
  vault: {
    artifact: "CoveredCallVault.sol/CoveredCallVault.json",
    functions: [
      "processDeposits",
      "processRedeems",
      "state",
      "series",
      "currentSeriesId",
      "canOpenAuction",
      "queueLengths",
      "totalAssets",
      "freeAssets",
      "pendingRedeemAssets",
      "encumbered",
      "payoutOwed",
      "totalShortfall",
      "sunset",
      "asset",
      "stock",
      "usdg",
      "optionToken",
      "auctionHouse",
      "settlement",
      "riskModule",
      "capController",
      "owner",
      "totalSupply",
      "decimals",
      "symbol",
      "maxQueueOpsPerOpen",
      "maxQueueOpsPerSettle",
      "escrowedRedeemShares",
      "withdrawalClaimableTotal",
      "queuedDepositTokens",
      "convertToAssets",
      "premiumClaimable",
      // fork harness only
      "deposit",
      "claimPremium",
    ],
    events: [
      "SeriesOpened",
      "SeriesCleared",
      "SeriesSkipped",
      "SeriesSettled",
      "SeriesHalted",
      "VaultStateChanged",
      "PremiumAccrued",
      "ShortfallRecorded",
    ],
    errors: null,
  },
  settlementOracle: {
    artifact: "SettlementOracle.sol/SettlementOracle.json",
    functions: [
      "settle",
      "halt",
      "resolveHaltedByOracle",
      "previewSettle",
      "canHalt",
      "canResolveByOracle",
      "previewResolveByOracle",
      "resolutionBand",
      "records",
      "vaultConfig",
      "twap",
      "referencePrice",
      "capPrice",
      "riskModule",
      "auctionHouse",
      "usdgUsdFeed",
      "owner",
      "HALTED_TIMEOUT",
      "WEEKEND_CL_DEADLINE",
      "TWAP_WINDOW_WEEKDAY",
      "TWAP_WINDOW_WEEKEND",
      "CAP_TWAP_WINDOW",
      "CAP_MAX_STALE",
      "REF_MAX_STALE",
      "MAX_LAST_OBS_AGE",
      "RESOLVE_BOUND_BPS",
      "REF_TWAP_BOUND_BPS",
    ],
    events: [
      "Settled",
      "PathRejected",
      "JumpGuardTripped",
      "SeriesHalted",
      "SeriesResolved",
      "SeriesResolvedByOracle",
    ],
    errors: null,
  },
  riskModule: {
    artifact: "RiskModule.sol/RiskModule.json",
    functions: [
      "currentParams",
      "paramsAt",
      "defaultParams",
      "depositsPaused",
      "auctionsPaused",
      "vaultDepositsPaused",
      "vaultAuctionsPaused",
      "allDepositsPaused",
      "allAuctionsPaused",
      "lastHalt",
      "haltCount",
      "hasRole",
      "GUARDIAN_ROLE",
      "settlementOracle",
      "owner",
      "pauseDeposits",
      "pauseNewAuctions",
      "unpauseDeposits",
      "unpauseNewAuctions",
    ],
    events: [],
    errors: null,
  },
  feeRouter: {
    artifact: "FeeRouter.sol/FeeRouter.json",
    functions: ["flush", "pending"],
    events: [],
    errors: null,
  },
  bondManager: {
    artifact: "BondManager.sol/BondManager.json",
    functions: ["isBonded", "activeLocks", "postBond", "auctionHouse"],
    events: [],
    errors: null,
  },
  optionToken: {
    artifact: "OptionToken.sol/OptionToken.json",
    functions: ["nextSeriesId", "series", "isVault", "vaultOf", "totalSupply", "balanceOf"],
    events: [],
    errors: null,
  },
  capController: {
    artifact: "CapController.sol/CapController.json",
    functions: ["remainingDepositAssets", "capMode"],
    events: [],
    errors: null,
  },
  aggregator: {
    artifact: "MockAggregatorV3.sol/MockAggregatorV3.json",
    functions: ["decimals", "latestRoundData", "getRoundData"],
    events: [],
    errors: [],
  },
  pool: {
    artifact: "MockUniswapV3Pool.sol/MockUniswapV3Pool.json",
    functions: [
      "slot0",
      "observations",
      "observe",
      "liquidity",
      "token0",
      "token1",
      "fee",
      "observationIndex",
      "observationCardinality",
    ],
    events: [],
    errors: [],
  },
  stockToken: {
    artifact: "MockStockToken.sol/MockStockToken.json",
    functions: [
      "uiMultiplier",
      "newUIMultiplier",
      "effectiveAt",
      "oraclePaused",
      "paused",
      "balanceOf",
      "totalSupply",
      "decimals",
      "owner",
    ],
    events: [],
    errors: [],
  },
  erc20: {
    artifact: "MockUSDG.sol/MockUSDG.json",
    functions: ["balanceOf", "decimals", "totalSupply", "allowance", "approve"],
    events: [],
    errors: [],
  },
  // Fork-harness only: the mock write surface. Never reachable from the keeper's send allowlist.
  mockAggregator: {
    artifact: "MockAggregatorV3.sol/MockAggregatorV3.json",
    functions: ["setRound", "setLatest", "roundId", "setDead", "latestId"],
    events: [],
    errors: [],
  },
  mockPool: {
    artifact: "MockUniswapV3Pool.sol/MockUniswapV3Pool.json",
    functions: ["write", "setLiquidity", "setCardinality", "setDead"],
    events: [],
    errors: [],
  },
  mockStockToken: {
    artifact: "MockStockToken.sol/MockStockToken.json",
    functions: ["mint", "setOraclePaused", "stageMultiplier", "approve"],
    events: [],
    errors: [],
  },
  mockUsdg: {
    artifact: "MockUSDG.sol/MockUSDG.json",
    functions: ["mint", "approve", "setPaused"],
    events: [],
    errors: [],
  },
};

const keep = (list, name) => list === null || list.includes(name);

const slices = [];
for (const [key, spec] of Object.entries(SLICES)) {
  const path = join(out, spec.artifact);
  if (!existsSync(path))
    throw new Error("missing artifact: " + path + " (run `forge build` in contracts/)");
  const abi = JSON.parse(readFileSync(path, "utf8")).abi;

  const picked = abi.filter((f) => {
    if (f.type === "function") return keep(spec.functions, f.name);
    if (f.type === "event") return keep(spec.events, f.name);
    if (f.type === "error") return keep(spec.errors, f.name);
    return false;
  });

  const missing = (spec.functions ?? []).filter(
    (n) => !picked.some((f) => f.type === "function" && f.name === n),
  );
  if (missing.length) throw new Error(key + ": not in artifact: " + missing.join(", "));

  // Stable order so a regeneration produces a clean diff.
  picked.sort((a, b) => (a.type + a.name).localeCompare(b.type + b.name));
  slices.push([key, spec.artifact, picked]);
}

const body = slices
  .map(
    ([key, artifact, abi]) =>
      "/** `" +
      artifact +
      "` — " +
      abi.length +
      " fragments. */\nexport const " +
      key +
      "Abi = " +
      JSON.stringify(abi, null, 2) +
      " as const;\n",
  )
  .join("\n");

const header = [
  "// GENERATED by scripts/gen-abi.mjs from contracts/out — do not edit by hand.",
  "// Regenerate with `npm run gen:abi` after any contract change.",
  "//",
  "// Only the fragments the keeper (and its fork harness) actually use are kept; the full ABIs",
  "// would be ~10x this size and every extra entry is one more thing to keep in sync.",
  "",
  "/* eslint-disable */",
  "",
].join("\n");

const dest = join(here, "..", "src", "abi", "generated.ts");
writeFileSync(dest, header + body, "utf8");
console.log(
  "wrote " +
    dest +
    " (" +
    slices.length +
    " slices, " +
    slices.reduce((n, s) => n + s[2].length, 0) +
    " fragments)",
);
