import {
  createPublicClient,
  createWalletClient,
  http,
  type Chain,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { PrivateKeyAccount } from "viem/accounts";
import { chainWithRpc } from "../chains.js";
import type { Env } from "../config.js";

export interface Clients {
  chain: Chain;
  rpcUrl: string;
  publicClient: PublicClient;
  keeper: PrivateKeyAccount;
  keeperWallet: WalletClient;
  /** Present only when GUARDIAN_AUTOPAUSE is on and a distinct key is configured. */
  guardian: PrivateKeyAccount | null;
  guardianWallet: WalletClient | null;
}

export function resolveRpcUrl(env: Env): string {
  const url =
    env.KEEPER_RPC_URL ??
    (env.CHAIN_ID === 4663 ? env.ROBINHOOD_RPC_URL : env.ROBINHOOD_TESTNET_RPC_URL);
  if (!url) {
    throw new Error(
      `no RPC URL for chain ${env.CHAIN_ID}: set KEEPER_RPC_URL, or ` +
        (env.CHAIN_ID === 4663 ? "ROBINHOOD_RPC_URL" : "ROBINHOOD_TESTNET_RPC_URL"),
    );
  }
  return url;
}

export function createClients(env: Env): Clients {
  const rpcUrl = resolveRpcUrl(env);
  const chain = chainWithRpc(env.CHAIN_ID, rpcUrl);
  // batch:true lets viem coalesce concurrent eth_calls into Multicall3 aggregate3 automatically.
  const transport = http(rpcUrl, { batch: true, retryCount: 0, timeout: 20_000 });

  // Robinhood Chain produces ~100 ms blocks. viem's 4 s default polling would make every
  // `waitForTransactionReceipt` cost multiple seconds for no reason, which matters most in the fork
  // harness where one simulated week is a few hundred transactions.
  const publicClient = createPublicClient({
    chain,
    transport,
    pollingInterval: 250,
  }) as PublicClient;
  const keeper = privateKeyToAccount(env.KEEPER_PRIVATE_KEY as `0x${string}`);
  const keeperWallet = createWalletClient({ account: keeper, chain, transport });

  let guardian: PrivateKeyAccount | null = null;
  let guardianWallet: WalletClient | null = null;
  if (env.GUARDIAN_AUTOPAUSE && env.GUARDIAN_PRIVATE_KEY) {
    guardian = privateKeyToAccount(env.GUARDIAN_PRIVATE_KEY as `0x${string}`);
    if (guardian.address.toLowerCase() === keeper.address.toLowerCase()) {
      throw new Error(
        "GUARDIAN_PRIVATE_KEY is the same key as KEEPER_PRIVATE_KEY — D-029 requires two distinct keys",
      );
    }
    guardianWallet = createWalletClient({ account: guardian, chain, transport });
  }

  return { chain, rpcUrl, publicClient, keeper, keeperWallet, guardian, guardianWallet };
}

/** Chain time. The scheduler never reads `Date.now()`; see the plan's "chain time, not wall time". */
export async function chainNow(publicClient: PublicClient): Promise<bigint> {
  const block = await publicClient.getBlock({ blockTag: "latest" });
  return block.timestamp;
}
