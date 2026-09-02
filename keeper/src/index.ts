import cron from "node-cron";
import { chainById } from "./chains.js";
import { loadEnv } from "./config.js";
import { createLogger } from "./logger.js";

const env = loadEnv();
const log = createLogger(env.LOG_LEVEL);
const chain = chainById[env.CHAIN_ID];

log.info({ chainId: chain.id, chain: chain.name, cron: env.KEEPER_CRON }, "keeper scaffold ready");

// Protocol tasks are intentionally not implemented yet (see docs/SPEC.md).
const task = cron.schedule(env.KEEPER_CRON, () => {
  log.debug("tick (no-op)");
});

const shutdown = (signal: string) => {
  log.info({ signal }, "shutting down");
  task.stop();
  process.exit(0);
};
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
