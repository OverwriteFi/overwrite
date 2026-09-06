import { defineChain, type Address } from "viem";

/**
 * Address book for the 46630 (Robinhood Chain testnet) deployment, copied from
 * contracts/deployments/46630.json. Mainnet (4663) is added here once it ships.
 */
export interface Deployment {
  chainId: 4663 | 46630;
  auctionHouse: Address;
  bondManager: Address;
  optionToken: Address;
  usdg: Address;
  vaults: Record<string, { vault: Address; stock: Address; feed: Address }>;
  /** Only on testnet: USDG is a mock with an open mint. */
  usdgIsMock: boolean;
}

export const TESTNET: Deployment = {
  chainId: 46630,
  auctionHouse: "0xEFE287cE0761813e642B6df5D6A08637E97E9B93",
  bondManager: "0x920F79DF191899934a04269B2280B2A1B2391266",
  optionToken: "0x56009D85b2318A3B3aDbE5764f602C0F26555eA6",
  usdg: "0x640c46710A5C075292655e8602EC1D4BA844A930",
  vaults: {
    NVDA: {
      vault: "0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0",
      stock: "0xc2D152ebE42be2c65d86c50b410231e5271634fb",
      feed: "0x2d4e84FBaE927EcF2CCc924808E593BA48F1b72F",
    },
    SPY: {
      vault: "0x7b242611B7C490BC5F571095ef511d60E89bf914",
      stock: "0x3c37fE477079789cA80b0F20A6585d96894f2006",
      feed: "0x301dd8371eD858A77474c5506236B8EBA5F5961b",
    },
  },
  usdgIsMock: true,
};

export const deployments: Record<number, Deployment> = { 46630: TESTNET };

const MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";

export const robinhoodTestnet = defineChain({
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.chain.robinhood.com"] } },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://explorer.testnet.chain.robinhood.com" },
  },
  contracts: { multicall3: { address: MULTICALL3 } },
  testnet: true,
});

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
  contracts: { multicall3: { address: MULTICALL3 } },
});

export const chainById = { 4663: robinhood, 46630: robinhoodTestnet } as const;
