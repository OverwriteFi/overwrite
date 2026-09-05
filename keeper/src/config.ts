import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { z } from "zod";
import { getAddress } from "viem";
import { formatIssues, loadDeployment, type Deployment } from "./deployment.js";

/* ────────────────────────────── environment ────────────────────────────── */

const hexKey = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "must be 0x + 64 hex characters");
const bool = z
  .enum(["true", "false", "1", "0", "yes", "no"])
  .transform((v) => v === "true" || v === "1" || v === "yes");

const envSchema = z.object({
  // 4663 = Robinhood Chain mainnet, 46630 = testnet
  CHAIN_ID: z.coerce.number().pipe(z.union([z.literal(4663), z.literal(46630)])),
  ROBINHOOD_RPC_URL: z.string().url().optional(),
  ROBINHOOD_TESTNET_RPC_URL: z.string().url().optional(),
  /** Overrides both of the above. The fork harness points this at anvil. */
  KEEPER_RPC_URL: z.string().url().optional(),

  /** Holds KEEPER_ROLE. Never logged; see logger.ts redaction. */
  KEEPER_PRIVATE_KEY: hexKey,
  /** A *different* key holding GUARDIAN_ROLE. Only loaded when GUARDIAN_AUTOPAUSE is on. */
  GUARDIAN_PRIVATE_KEY: hexKey.optional(),
  GUARDIAN_AUTOPAUSE: bool.default("false"),

  KEEPER_CONFIG: z.string().optional(),
  DEPLOYMENT_PATH: z.string().optional(),

  LOG_LEVEL: z.enum(["trace", "debug", "info", "warn", "error", "fatal"]).default("info"),
  DRY_RUN: bool.default("false"),

  STATE_DIR: z.string().default("./state"),
  STATUS_FILE: z.string().optional(),
  STATUS_HOST: z.string().default("127.0.0.1"),
  STATUS_PORT: z.coerce.number().int().min(0).max(65535).default(8787),

  TELEGRAM_BOT_TOKEN: z.string().min(1).optional(),
  TELEGRAM_CHAT_ID: z.string().min(1).optional(),

  /** Legacy scaffold field; the scheduler polls instead of firing on a cron. Ignored, kept for .env compat. */
  KEEPER_CRON: z.string().optional(),
});

export type Env = z.infer<typeof envSchema>;

export function loadEnv(source: NodeJS.ProcessEnv = process.env): Env {
  const parsed = envSchema.safeParse(source);
  if (!parsed.success) {
    // Never echo values — one of these fields is a private key.
    throw new Error(`invalid environment: ${formatIssues(parsed.error)}`);
  }
  const env = parsed.data;
  if (env.GUARDIAN_AUTOPAUSE && !env.GUARDIAN_PRIVATE_KEY) {
    throw new Error("GUARDIAN_AUTOPAUSE=true requires GUARDIAN_PRIVATE_KEY");
  }
  return env;
}

/* ─────────────────────────── keeper JSON config ─────────────────────────── */

const bps = z.number().int().min(0).max(10_000);
const perKind = <T extends z.ZodTypeAny>(inner: T) => z.object({ weekday: inner, weekend: inner });

const vaultConfigSchema = z.object({
  enabled: z.boolean().default(true),
  assetClass: z.enum(["SINGLE_NAME", "ETF"]),

  /**
   * SPEC §7.2 keeper defaults: SINGLE_NAME 800/500, ETF 200/100. The ETF *weekday* 200 is below the
   * protocol floor `STRIKE_LO_WEEKDAY = 300` and reverts `DistanceOutOfBounds` — see DECISIONS D-109.
   * Every value here is checked against `strikeDistanceBounds()` at startup, and the keeper refuses to
   * start rather than clamping, so a bad number can never become a silently-different auction.
   */
  strikeDistanceBps: perKind(z.number().int().min(1).max(10_000)),

  /** Floor for the reserve, as bps of `sRef`. Never below the on-chain `minReserveBpsOfSpot`. */
  minReserveBps: perKind(bps),
  /** Ceiling for the reserve, as bps of `sRef`, so a vol spike cannot make every auction skip. */
  maxReserveBpsOfSpot: perKind(bps),

  /** Annualised vol used when the Chainlink history is too short or degenerate. See pricing/realisedVol.ts. */
  fallbackVolAnnualBps: z.number().int().min(1).max(100_000),
});

export type VaultConfig = z.infer<typeof vaultConfigSchema>;

const keeperConfigSchema = z.object({
  chainId: z.number().int().positive(),
  label: z.string().default(""),

  /** "full" runs the whole lifecycle. "settle-only" is THREAT-MODEL RS-04's second instance. */
  role: z.enum(["full", "settle-only"]).default("full"),

  /**
   * Relaxes the key-separation startup assertions to warnings. Mirrors `deployerIsAdmin` in
   * contracts/config/*.json: on 46630 one funded key is admin, guardian, treasury *and* keeper (D-105),
   * so the assertions are all false there by design. Must be false on 4663.
   */
  sharedKeysAllowed: z.boolean().default(false),

  deploymentPath: z.string().default("../contracts/deployments/46630.json"),
  tickSeconds: z.number().int().min(1).max(3600).default(30),

  schedule: z
    .object({
      /** Extra delay after `auctionClose` before attempting `clear`, to avoid racing the boundary block. */
      clearDelaySeconds: z.number().int().min(0).max(3600).default(5),
      /** How long past expiry a settle may fail before it becomes an alert rather than a retry. */
      settleGraceSeconds: z.number().int().min(0).max(86_400).default(600),
      /** Queue entries processed per call. Contract bound is `MAX_QUEUE_OPS = 100`. */
      queueOpsPerCall: z.number().int().min(1).max(100).default(50),
    })
    .default({}),

  pricing: z
    .object({
      riskFreeRateBps: z.number().int().min(-1000).max(2000).default(0),
      volWindowDays: z.number().int().min(2).max(365).default(30),
      minVolSamples: z.number().int().min(2).max(365).default(10),
      volFloorBps: z.number().int().min(1).max(100_000).default(500),
      volCapBps: z.number().int().min(1).max(100_000).default(20_000),
      /** Multiplier on the Black-Scholes price before the floor is applied. 10000 = 1.0×. */
      reserveFactorBps: z.number().int().min(1).max(100_000).default(10_000),
      /** Hard bound on how many `getRoundData` reads one vol estimate may cost. */
      maxRoundScan: z.number().int().min(10).max(100_000).default(4_000),
      /**
       * Room above the contract's `reserveBounds().lo`, because `_checkOpen` re-reads `sRef` at
       * inclusion and the feeds publish on a 0.5 % deviation threshold. Submitting exactly `lo`
       * reverts `ReserveOutOfBounds` whenever a round lands between simulate and inclusion.
       */
      reserveMarginBps: z.number().int().min(0).max(5_000).default(200),
      /** Variance-days for one overnight gap (see time/tradingTime.ts). */
      overnightVarianceDays: z.number().min(0).max(2).default(0.15),
      /** Variance-days for a weekend or holiday gap. */
      weekendVarianceDays: z.number().min(0).max(5).default(0.3),
      sessionsPerYear: z.number().int().min(200).max(366).default(252),
    })
    .default({}),

  monitor: z
    .object({
      minKeeperEthWei: z.string().default("20000000000000000"), // 0.02 ETH
      critKeeperEthWei: z.string().default("5000000000000000"), // 0.005 ETH
      /** WARN once a feed has used this fraction of its staleness budget. */
      stalenessWarnRatioBps: bps.default(8_000),
      /** WARN when the USDG peg is within this many bps of the on-chain band edge. */
      pegMarginBps: bps.default(50),
      /** WARN when the calendar table has fewer than this many days left. */
      calendarWarnDays: z.number().int().min(0).max(3650).default(90),
      /** Poll interval for the D-020 beacon / USDG implementation watch. */
      implementationPollSeconds: z.number().int().min(30).max(86_400).default(300),
      /** Poll interval for the SPEC §9.5 observation-coverage check. */
      coveragePollSeconds: z.number().int().min(30).max(86_400).default(3_600),
    })
    .default({}),

  alerts: z
    .object({
      cooldownSeconds: z.number().int().min(0).max(86_400).default(900),
      /** Minimum severity that reaches Telegram. Everything is always logged and in status.json. */
      minSeverity: z.enum(["info", "warn", "crit"]).default("warn"),
    })
    .default({}),

  tx: z
    .object({
      maxAttempts: z.number().int().min(1).max(20).default(5),
      backoffBaseMs: z.number().int().min(100).max(60_000).default(1_000),
      backoffCapMs: z.number().int().min(1_000).max(600_000).default(60_000),
      /** How many times a failed *simulation* may be retried after re-deriving its inputs. */
      maxRederive: z.number().int().min(0).max(10).default(2),
      confirmations: z.number().int().min(1).max(20).default(1),
    })
    .default({}),

  vaults: z.record(z.string(), vaultConfigSchema),
});

export type KeeperFileConfig = z.infer<typeof keeperConfigSchema>;

export interface ResolvedConfig {
  env: Env;
  file: KeeperFileConfig;
  deployment: Deployment;
  keeperAddress: `0x${string}`;
  statusFile: string;
  stateDir: string;
}

export function loadFileConfig(
  path: string,
  expectedChainId: number,
  cwd = process.cwd(),
): KeeperFileConfig {
  const full = isAbsolute(path) ? path : resolve(cwd, path);
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(full, "utf8"));
  } catch (cause) {
    throw new Error(`cannot read keeper config ${full}: ${(cause as Error).message}`);
  }
  const parsed = keeperConfigSchema.safeParse(raw);
  if (!parsed.success)
    throw new Error(`invalid keeper config ${full}: ${formatIssues(parsed.error)}`);
  if (parsed.data.chainId !== expectedChainId) {
    throw new Error(
      `keeper config ${full} is for chain ${parsed.data.chainId}, but CHAIN_ID is ${expectedChainId}`,
    );
  }
  if (parsed.data.chainId === 4663 && parsed.data.sharedKeysAllowed) {
    throw new Error("sharedKeysAllowed must be false on mainnet 4663");
  }
  return parsed.data;
}

/** Resolves env + JSON config + the deploy's address book into the one object the rest of the bot reads. */
export function loadConfig(
  env: Env,
  keeperAddress: `0x${string}`,
  cwd = process.cwd(),
): Omit<ResolvedConfig, "env" | "keeperAddress"> & { env: Env; keeperAddress: `0x${string}` } {
  const configPath = env.KEEPER_CONFIG ?? `./config/keeper.${env.CHAIN_ID}.json`;
  const file = loadFileConfig(configPath, env.CHAIN_ID, cwd);
  const deployment = loadDeployment(env.DEPLOYMENT_PATH ?? file.deploymentPath, env.CHAIN_ID, cwd);

  const unknown = Object.keys(file.vaults).filter(
    (s) => !deployment.vaults.some((v) => v.symbol === s),
  );
  if (unknown.length) {
    throw new Error(`keeper config names vaults absent from the deployment: ${unknown.join(", ")}`);
  }

  const stateDir = isAbsolute(env.STATE_DIR) ? env.STATE_DIR : resolve(cwd, env.STATE_DIR);
  const statusFile = env.STATUS_FILE
    ? isAbsolute(env.STATUS_FILE)
      ? env.STATUS_FILE
      : resolve(cwd, env.STATUS_FILE)
    : resolve(stateDir, "status.json");

  return { env, file, deployment, keeperAddress: getAddress(keeperAddress), statusFile, stateDir };
}

/** The vaults this instance actually manages, in deployment order. */
export function activeVaults(
  cfg: ResolvedConfig,
): { symbol: string; vault: VaultConfig; addresses: Deployment["vaults"][number] }[] {
  return cfg.deployment.vaults
    .map((addresses) => {
      const vault = cfg.file.vaults[addresses.symbol];
      return vault && vault.enabled ? { symbol: addresses.symbol, vault, addresses } : null;
    })
    .filter((v): v is NonNullable<typeof v> => v !== null);
}
