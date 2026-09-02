import { defineChain } from "viem";

/** Robinhood Chain mainnet (Arbitrum Orbit L2). Gas is paid in ETH. */
export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.ROBINHOOD_RPC_URL ?? ""] } },
});

/** Robinhood Chain testnet (Arbitrum Orbit L2). Gas is paid in ETH. */
export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.ROBINHOOD_TESTNET_RPC_URL ?? ""] } },
  testnet: true,
});

export const chainById = { 4663: robinhood, 46630: robinhoodTestnet } as const;
export type SupportedChainId = keyof typeof chainById;
