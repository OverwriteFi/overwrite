// Emits src/lib/abi/generated.ts from the Foundry artifacts in ../contracts/out.
//
// Same idea as keeper/scripts/gen-abi.mjs: pull the exact fragments the app uses out of the compiled
// artifacts rather than hand-copying signatures. Run after any contract change:
//
//   npm run gen:abi
//
// The output is committed, so the app builds without contracts/out present.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "..", "contracts", "out");

/** Which fragments each ABI slice keeps. `null` means "everything of that kind". */
const SLICES = {
  vault: {
    artifact: "CoveredCallVault.sol/CoveredCallVault.json",
    functions: [
      // state
      "state",
      "series",
      "currentSeriesId",
      "totalAssets",
      "freeAssets",
      "pendingRedeemAssets",
      "encumbered",
      "payoutOwed",
      "totalShortfall",
      "sunset",
      "queueLengths",
      "depositQueueHead",
      "depositQueueLength",
      "redeemQueueHead",
      "redeemQueueLength",
      "queuedDeposit",
      "queuedRedeem",
      "queuedDepositTokens",
      "withdrawalClaimable",
      "withdrawalClaimableTotal",
      "premiumClaimable",
      "accPremiumPerShare",
      // erc-20 / erc-4626
      "asset",
      "stock",
      "usdg",
      "name",
      "symbol",
      "decimals",
      "totalSupply",
      "balanceOf",
      "allowance",
      "approve",
      "convertToAssets",
      "convertToShares",
      "maxDeposit",
      "maxMint",
      "maxWithdraw",
      "maxRedeem",
      "previewDeposit",
      "previewMint",
      "previewWithdraw",
      "previewRedeem",
      // user writes
      "deposit",
      "mint",
      "withdraw",
      "redeem",
      "requestDeposit",
      "cancelDeposit",
      "requestRedeem",
      "cancelRedeem",
      "claimWithdrawal",
      "claimPremium",
      "processDeposits",
      "processRedeems",
    ],
    events: [
      "DepositQueued",
      "DepositQueueCancelled",
      "DepositRequestExpired",
      "DepositExecuted",
      "RedeemQueued",
      "RedeemQueueCancelled",
      "RedeemExecuted",
      "WithdrawalClaimed",
      "PremiumAccrued",
      "PremiumClaimed",
      "Deposit",
      "Withdraw",
    ],
    errors: null,
  },
  auctionHouse: {
    artifact: "AuctionHouse.sol/AuctionHouse.json",
    functions: [
      "auctions",
      "currentAuction",
      "lastWeekdayExpiry",
      "strikeDistanceBounds",
      "minStrikeDistanceBps",
      "minReserveBpsOfSpot",
      "referencePrice",
      "computeStrike",
      "scheduledExpiry",
      "previewClear",
      "canOpen",
      "openTolerance",
      "isVault",
      "bids",
      "bidders",
      "AUCTION_DURATION",
      "WEEK",
      "MON_1400",
      "FRI_2000",
      "SUN_2359",
      "WEEKEND_GAP",
      "GRID_BPS",
      "STRIKE_LO_WEEKDAY",
      "STRIKE_HI_WEEKDAY",
      "STRIKE_LO_WEEKEND",
      "STRIKE_HI_WEEKEND",
    ],
    events: ["AuctionOpened", "AuctionCleared", "AuctionSkipped"],
    errors: null,
  },
  optionToken: {
    artifact: "OptionToken.sol/OptionToken.json",
    functions: ["nextSeriesId", "series", "vaultOf", "balanceOf"],
    events: [],
    errors: [],
  },
  capController: {
    artifact: "CapController.sol/CapController.json",
    functions: [
      "capMode",
      "capUSD",
      "capWeightBps",
      "totalWeightBps",
      "k",
      "K_MIN",
      "K_MAX",
      "safetyModule",
      "vaultCapUSD",
      "remainingDepositAssets",
    ],
    events: [],
    errors: null,
  },
  settlementOracle: {
    artifact: "SettlementOracle.sol/SettlementOracle.json",
    functions: [
      "capPrice",
      "referencePrice",
      "vaultConfig",
      "records",
      "usdgUsdFeed",
      "canResolveByOracle",
      "resolutionBand",
      "HALTED_TIMEOUT",
      "WEEKEND_CL_DEADLINE",
    ],
    events: [],
    errors: [],
  },
  riskModule: {
    artifact: "RiskModule.sol/RiskModule.json",
    functions: ["depositsPaused", "auctionsPaused", "haltCount"],
    events: [],
    errors: [],
  },
  feeRouter: {
    artifact: "FeeRouter.sol/FeeRouter.json",
    functions: ["feeBps", "mode", "writeDiscountBps", "writeBurnShareBps", "writeToken"],
    events: [],
    errors: [],
  },
  safetyModule: {
    artifact: "SafetyModule.sol/SafetyModule.json",
    functions: [
      "COOLDOWN",
      "CLAIM_WINDOW",
      "MAX_SLASH_BPS",
      "SLASH_INTERVAL",
      "writeToken",
      "totalShares",
      "totalStaked",
      "sharesOf",
      "stakedOf",
      "cooldowns",
      "unstakeWindow",
      "pendingRewards",
      "claimableRewards",
      "valueUSD",
      "valueUSDView",
      "safetyModuleValueUSD",
      "previewStake",
      "previewUnstake",
      "lastSlashAt",
      "stake",
      "requestUnstake",
      "cancelUnstake",
      "unstake",
      "claimRewards",
    ],
    events: ["Staked", "UnstakeRequested", "UnstakeCancelled", "Unstaked", "RewardsClaimed"],
    errors: null,
  },
  writePriceOracle: {
    artifact: "WritePriceOracle.sol/WritePriceOracle.json",
    functions: ["writePrice", "previewPrice"],
    events: [],
    errors: [],
  },
  emissionsController: {
    artifact: "EmissionsController.sol/EmissionsController.json",
    functions: ["rate", "sink", "startTime", "endTime"],
    events: [],
    errors: [],
  },
  pointsDistributor: {
    artifact: "PointsDistributor.sol/PointsDistributor.json",
    functions: ["rounds", "isClaimed", "claim", "allocation"],
    events: [],
    errors: null,
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
      "decimals",
      "symbol",
      "name",
      "allowance",
      "approve",
    ],
    events: [],
    errors: [],
  },
  erc20: {
    artifact: "MockUSDG.sol/MockUSDG.json",
    functions: ["balanceOf", "decimals", "symbol", "allowance", "approve", "totalSupply"],
    events: [],
    errors: [],
  },
  aggregator: {
    artifact: "MockAggregatorV3.sol/MockAggregatorV3.json",
    functions: ["decimals", "latestRoundData"],
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
  "",
  "/* eslint-disable */",
  "// prettier-ignore",
  "",
].join("\n");

const dest = join(here, "..", "src", "lib", "abi", "generated.ts");
mkdirSync(dirname(dest), { recursive: true });
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
