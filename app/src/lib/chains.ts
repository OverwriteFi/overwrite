import { defineChain } from "viem";

const rpc = process.env.NEXT_PUBLIC_RPC_URL ?? "";

/** Robinhood Chain mainnet (Arbitrum Orbit L2). Gas is paid in ETH. */
export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});

/** Robinhood Chain testnet (Arbitrum Orbit L2). Gas is paid in ETH. */
export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
  testnet: true,
});

export const targetChainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 46630);
export const targetChain = targetChainId === robinhood.id ? robinhood : robinhoodTestnet;
