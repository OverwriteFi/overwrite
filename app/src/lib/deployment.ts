import { z } from "zod";
import { getAddress } from "viem";
import { targetChainId } from "./chains";
import { deploymentsByChain } from "./deployments";

/**
 * The address book written by `contracts/script/Deployment.sol` (`contracts/deployments/<chainId>.json`).
 * Same schema as keeper/src/deployment.ts, extended with the token layer. There is no factory and no
 * on-chain vault enumerator: this file is the vault list.
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
  vaults: z.array(vaultEntry),
  token: z
    .object({
      write: addr,
      liquidityEscrow: addr,
      emissionsController: addr,
      treasuryVesting: addr,
      teamVesting: addr,
      pointsDistributor: addr,
      writePriceOracle: addr,
      safetyModule: addr,
    })
    .optional(),
  mocked: z.array(z.string()).default([]),
});

export type Deployment = z.infer<typeof deploymentSchema>;
export type DeployedVault = z.infer<typeof vaultEntry>;

function load(): Deployment {
  const raw = deploymentsByChain[targetChainId];
  if (!raw) {
    throw new Error(
      `no deployment for chain ${targetChainId}: add contracts/deployments/${targetChainId}.json to src/lib/deployments/index.ts`,
    );
  }
  const parsed = deploymentSchema.safeParse(raw);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join(".") || "<root>"}: ${i.message}`)
      .join("; ");
    throw new Error(`invalid deployment for chain ${targetChainId}: ${issues}`);
  }
  if (parsed.data.chainId !== targetChainId) {
    throw new Error(
      `deployment is for chain ${parsed.data.chainId}, but NEXT_PUBLIC_CHAIN_ID is ${targetChainId}`,
    );
  }
  return parsed.data;
}

export const deployment: Deployment = load();
export const vaults: DeployedVault[] = deployment.vaults;
export const vaultBySymbol = (symbol: string): DeployedVault | undefined =>
  vaults.find((v) => v.symbol.toUpperCase() === symbol.toUpperCase());

/** Display names for the Stock Tokens we know about; falls back to "<SYMBOL> Stock Token". */
const NAMES: Record<string, string> = {
  NVDA: "NVIDIA Stock Token",
  SPY: "SPDR S&P 500 Stock Token",
  TSLA: "Tesla Stock Token",
  QQQ: "Invesco QQQ Stock Token",
  GME: "GameStop Stock Token",
  AAPL: "Apple Stock Token",
};
export const vaultName = (symbol: string) => NAMES[symbol.toUpperCase()] ?? `${symbol} Stock Token`;
