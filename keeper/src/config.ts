import { z } from "zod";

const envSchema = z.object({
  // 4663 = Robinhood Chain mainnet, 46630 = testnet
  CHAIN_ID: z.coerce.number().pipe(z.union([z.literal(4663), z.literal(46630)])),
  ROBINHOOD_RPC_URL: z.string().url().optional(),
  ROBINHOOD_TESTNET_RPC_URL: z.string().url().optional(),
  LOG_LEVEL: z.enum(["trace", "debug", "info", "warn", "error", "fatal"]).default("info"),
  KEEPER_CRON: z.string().default("*/1 * * * *"),
});

export type Env = z.infer<typeof envSchema>;

export function loadEnv(source: NodeJS.ProcessEnv = process.env): Env {
  const parsed = envSchema.safeParse(source);
  if (!parsed.success) {
    const detail = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new Error(`invalid environment: ${detail}`);
  }
  return parsed.data;
}
