import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { z } from "zod";
import { getAddress } from "viem";

/**
 * The address book written by `contracts/script/Deployment.sol`. It is the deploy's only output file and
 * the keeper's only source of addresses — nothing here is hardcoded, so pointing the keeper at another
 * chain is a config change and not a code change.
 */

const addr = z
  .string()
  .regex(/^0x[0-9a-fA-F]{40}$/, "not a 20-byte address")
  .transform((s) => getAddress(s));

const vaultEntry = z.object({
  symbol: z.string().min(1),
  vault: addr,
  stock: addr,
  feed: addr,
  pool: addr,
});

export const deploymentSchema = z.object({
  chainId: z.number().int().positive(),
  label: z.string(),
  deployedAt: z.number().int().nonnegative(),
  deployer: addr,
  timelock: addr,
  external: z.object({ usdg: addr, usdgUsdFeed: addr }),
  core: z.object({
    riskModule: addr,
    optionToken: addr,
    bondManager: addr,
    feeRouter: addr,
    auctionHouse: addr,
    capController: addr,
    settlementOracle: addr,
  }),
  vaults: z.array(vaultEntry).min(1),
  // present on testnet, absent on a vault-layer-only mainnet deploy
  mocked: z.array(z.string()).default([]),
});

export type Deployment = z.infer<typeof deploymentSchema>;
export type DeployedVault = z.infer<typeof vaultEntry>;

export function loadDeployment(
  path: string,
  expectedChainId: number,
  cwd = process.cwd(),
): Deployment {
  const full = isAbsolute(path) ? path : resolve(cwd, path);
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(full, "utf8"));
  } catch (cause) {
    throw new Error(`cannot read deployment ${full}: ${(cause as Error).message}`);
  }
  const parsed = deploymentSchema.safeParse(raw);
  if (!parsed.success) {
    throw new Error(`invalid deployment ${full}: ${formatIssues(parsed.error)}`);
  }
  if (parsed.data.chainId !== expectedChainId) {
    throw new Error(
      `deployment ${full} is for chain ${parsed.data.chainId}, but CHAIN_ID is ${expectedChainId}`,
    );
  }
  return parsed.data;
}

export function formatIssues(err: z.ZodError): string {
  return err.issues.map((i) => `${i.path.join(".") || "<root>"}: ${i.message}`).join("; ");
}
