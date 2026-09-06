import { privateKeyToAccount } from "viem/accounts";
import { createClients } from "./chain/clients.js";
import { buildKeeperAllowTable, createSender, sleep } from "./chain/tx.js";
import { activeVaults, loadConfig, loadEnv, type Env } from "./config.js";
import { createLogger, type Logger } from "./logger.js";
import { Alerter } from "./monitor/alerts.js";
import { runChecks, worst, type Check } from "./monitor/checks.js";
import { TestnetUpkeep } from "./jobs/testnetUpkeep.js";
import { GuardianModule } from "./monitor/guardian.js";
import { StatusServer } from "./monitor/http.js";
import { buildStatus, writeStatus } from "./monitor/status.js";
import { Scheduler } from "./scheduler.js";
import { StateDir } from "./state.js";
import { verifyStartup } from "./startup.js";

/**
 * Entry point.
 *
 * Order matters: load config, prove the environment before touching a key, take the single-instance
 * lock, then loop. Nothing here reads `Date.now()` for a protocol decision — chain time governs, and
 * wall time only paces the loop.
 */

/**
 * Config has to be read before there is a logger to report a config failure with, so the bootstrap
 * gets its own handler. Without it the commonest misconfiguration of all — `KEEPER_PRIVATE_KEY` not
 * set — throws during module evaluation, escapes `main().catch()` entirely, and greets the operator
 * with a raw V8 stack instead of one line saying which variable is wrong. `loadEnv` never echoes a
 * value, so the message is always safe to print.
 */
function bootstrap(): { env: Env; log: Logger } {
  let env: Env;
  try {
    env = loadEnv();
  } catch (err) {
    process.stderr.write(`keeper: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  }
  return { env, log: createLogger(env.LOG_LEVEL) };
}

const { env, log } = bootstrap();

async function main(): Promise<void> {
  const keeper = privateKeyToAccount(env.KEEPER_PRIVATE_KEY as `0x${string}`);
  const cfg = loadConfig(env, keeper.address);
  const clients = createClients(env);
  const state = new StateDir(cfg.stateDir);

  const vaults = activeVaults(cfg);
  log.info(
    {
      chainId: cfg.deployment.chainId,
      label: cfg.deployment.label,
      role: cfg.file.role,
      keeper: keeper.address,
      vaults: vaults.map((v) => v.symbol),
      tickSeconds: cfg.file.tickSeconds,
      dryRun: env.DRY_RUN,
    },
    "keeper starting",
  );
  if (env.DRY_RUN) log.warn("DRY RUN: every action is simulated and nothing is sent");

  /* ── prove the environment ── */
  const report = await verifyStartup({ cfg, clients, client: clients.publicClient, log });
  for (const n of report.notes) log.info(n);
  if (report.deviations.length > 0) {
    log.warn(
      `╔══ TESTNET DEVIATION (sharedKeysAllowed = true) ${"═".repeat(20)}\n` +
        report.deviations.map((d) => `║  · ${d}`).join("\n") +
        `\n║  These are the separation-of-duties guarantees this run is NOT demonstrating.\n` +
        `╚${"═".repeat(64)}`,
    );
  }
  if (report.fatal.length > 0) {
    for (const f of report.fatal) log.fatal(f);
    throw new Error(`${report.fatal.length} startup assertion(s) failed; refusing to run`);
  }

  /* ── single instance ── */
  const lock = state.acquireLock(keeper.address, Math.max(3 * cfg.file.tickSeconds * 1000, 30_000));
  log.info({ pid: lock.pid }, "acquired the single-instance lock");

  const alerter = new Alerter(
    {
      botToken: env.TELEGRAM_BOT_TOKEN,
      chatId: env.TELEGRAM_CHAT_ID,
      minSeverity: cfg.file.alerts.minSeverity,
      cooldownSeconds: cfg.file.alerts.cooldownSeconds,
      label: `${cfg.deployment.label} keeper`,
      dryRun: env.DRY_RUN,
    },
    log,
  );
  if (!alerter.enabled)
    log.info("Telegram is not configured; alerts go to the log and status.json only");

  const guardian = new GuardianModule(cfg, clients, clients.publicClient, log, alerter);
  log.info(`guardian auto-pause: ${guardian.describe()}`);

  const sender = createSender({
    publicClient: clients.publicClient,
    wallet: clients.keeperWallet,
    account: clients.keeper,
    allow: buildKeeperAllowTable(cfg.deployment, cfg.file.role, {
      testnetUpkeep: cfg.file.testnetUpkeep.enabled,
    }),
    options: cfg.file.tx,
    dryRun: env.DRY_RUN,
    log,
  });

  let upkeep: TestnetUpkeep | null = null;
  if (cfg.file.testnetUpkeep.enabled) {
    upkeep = new TestnetUpkeep(
      cfg.deployment,
      cfg.file.testnetUpkeep,
      clients.publicClient,
      sender,
      state,
      log,
    );
    log.warn(
      `TESTNET UPKEEP ON: this keeper also publishes the mock feed rounds and pool observations ` +
        `(${upkeep.describe()}). On 4663 this cannot be enabled.`,
    );
  }

  const scheduler = new Scheduler(cfg, clients.publicClient, sender, state, log, upkeep);
  const server = new StatusServer(
    { host: env.STATUS_HOST, port: env.STATUS_PORT, staleAfterMs: cfg.file.tickSeconds * 3000 },
    log,
  );
  server.start();

  await alerter.notify(`keeper started on ${cfg.deployment.label} as ${keeper.address}`);

  let running = true;
  let implementations = state.readJson<Record<string, string>>("implementations.json") ?? {};

  const shutdown = (signal: string) => {
    if (!running) return;
    running = false;
    log.info({ signal }, "shutting down");
    void (async () => {
      await server.stop();
      state.releaseLock();
      await alerter.notify(`keeper stopped (${signal})`);
      process.exit(0);
    })();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  while (running) {
    const startedAt = Date.now();
    try {
      const tick = await scheduler.tick(vaults.map((v) => ({ symbol: v.symbol, vault: v.vault })));

      const { checks, implementations: nextImpl } = await runChecks({
        cfg,
        client: clients.publicClient,
        now: tick.now,
        ticks: tick.vaults,
        knownImplementations: implementations,
      });
      if (JSON.stringify(nextImpl) !== JSON.stringify(implementations)) {
        state.writeJson("implementations.json", nextImpl);
        implementations = nextImpl;
      }

      const status = buildStatus({
        cfg,
        tick,
        checks,
        recentActions: scheduler.recentActions,
        generatedAt: new Date(),
      });
      writeStatus(cfg.statusFile, status);
      server.update(status);
      state.heartbeat(lock);

      await alerter.reconcile(checks);
      await guardian.onChecks(checks);

      logTick(tick, checks);
    } catch (err) {
      log.error({ err: (err as Error).message, stack: (err as Error).stack }, "tick failed");
      await alerter.notify(`tick failed: ${(err as Error).message}`);
    }

    const elapsed = Date.now() - startedAt;
    await sleep(Math.max(0, cfg.file.tickSeconds * 1000 - elapsed));
  }
}

function logTick(tick: Awaited<ReturnType<Scheduler["tick"]>>, checks: Check[]): void {
  const failing = checks.filter((c) => c.severity === "warn" || c.severity === "crit");
  log.info(
    {
      blockTime: tick.now.toString(),
      overall: worst(checks),
      vaults: tick.vaults
        .map((v) => `${v.snapshot.symbol}:${v.snapshot.state}/${v.due}=${v.outcome}`)
        .join(" "),
      ...(failing.length
        ? { failing: failing.map((c) => `${c.id}${c.vault ? `:${c.vault}` : ""}`) }
        : {}),
    },
    "tick",
  );
}

main().catch((err: unknown) => {
  log.fatal({ err: err instanceof Error ? err.message : String(err) }, "keeper exited");
  process.exit(1);
});
