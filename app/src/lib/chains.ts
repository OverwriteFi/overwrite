import { defineChain } from "viem";
import { MULTICALL3 } from "./abi";

/**
 * Robinhood Chain is an Arbitrum Orbit L2 with ~100 ms blocks and gas paid in ETH.
 *
 * `multicall3` lets viem batch reads through `aggregate3` (per-call failures instead of a reverting
 * batch). `blockExplorers` and `rpcUrls` are what wagmi hands to `wallet_addEthereumChain` when the
 * user's wallet does not know the chain yet, so both must be populated for the add-chain prompt.
 */

const DEFAULT_RPC: Record<number, string> = {
  4663: "https://rpc.mainnet.chain.robinhood.com",
  46630: "https://rpc.testnet.chain.robinhood.com",
};

const common = {
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  contracts: { multicall3: { address: MULTICALL3 } },
} as const;

export type SupportedChainId = 4663 | 46630;
const envChain = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 46630);
export const targetChainId: SupportedChainId = envChain === 4663 ? 4663 : 46630;

/** Public RPC for the target chain. `NEXT_PUBLIC_RPC_URL` overrides (e.g. an anvil fork). */
export const rpcUrl: string =
  process.env.NEXT_PUBLIC_RPC_URL || DEFAULT_RPC[targetChainId] || DEFAULT_RPC[46630];

export const robinhood = defineChain({
  ...common,
  id: 4663,
  name: "Robinhood Chain",
  rpcUrls: { default: { http: [targetChainId === 4663 ? rpcUrl : DEFAULT_RPC[4663]] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
  },
});

export const robinhoodTestnet = defineChain({
  ...common,
  id: 46630,
  name: "Robinhood Chain Testnet",
  rpcUrls: { default: { http: [targetChainId === 46630 ? rpcUrl : DEFAULT_RPC[46630]] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://explorer.testnet.chain.robinhood.com" },
  },
  testnet: true,
});

export const chainById = { 4663: robinhood, 46630: robinhoodTestnet } as const;

export const targetChain = chainById[targetChainId];

export const explorerBase =
  process.env.NEXT_PUBLIC_EXPLORER_URL || targetChain.blockExplorers?.default.url || "";

export const explorerUrl = (kind: "address" | "tx", value: string) =>
  `${explorerBase}/${kind}/${value}`;
