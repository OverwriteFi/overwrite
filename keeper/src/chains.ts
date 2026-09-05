import { defineChain } from "viem";
import { MULTICALL3 } from "./abi/index.js";

/**
 * Robinhood Chain is an Arbitrum Orbit L2 with ~100 ms blocks and gas paid in ETH.
 *
 * `multicall3` is declared so viem's `publicClient.multicall` batches through it. Its default
 * `allowFailure: true` maps onto Multicall3's `aggregate3`, which returns per-call failures instead of
 * reverting the batch — the keeper depends on that, because `getRoundData` reverts "No data present"
 * for any round id that was never written and the round search has to probe ids that may not exist.
 * Verified present at the canonical address on 46630.
 */

const common = {
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  contracts: { multicall3: { address: MULTICALL3 } },
} as const;

export const robinhood = defineChain({
  ...common,
  id: 4663,
  name: "Robinhood Chain",
  rpcUrls: { default: { http: [] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
  },
});

export const robinhoodTestnet = defineChain({
  ...common,
  id: 46630,
  name: "Robinhood Chain Testnet",
  rpcUrls: { default: { http: [] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://explorer.testnet.chain.robinhood.com" },
  },
  testnet: true,
});

export const chainById = { 4663: robinhood, 46630: robinhoodTestnet } as const;
export type SupportedChainId = keyof typeof chainById;

/** Binds the chain definition to the URL actually configured, so nothing reads env at import time. */
export function chainWithRpc(chainId: SupportedChainId, url: string) {
  const base = chainById[chainId];
  return defineChain({ ...base, rpcUrls: { default: { http: [url] } } });
}
