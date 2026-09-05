import { cookieStorage, createConfig, createStorage, http } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { robinhood, robinhoodTestnet, rpcUrl, targetChainId } from "./chains";

const wcProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

export function getConfig() {
  // Target chain first so wagmi's default chain (and the add-chain prompt) is the one we deploy to.
  const chains =
    targetChainId === robinhood.id
      ? ([robinhood, robinhoodTestnet] as const)
      : ([robinhoodTestnet, robinhood] as const);
  return createConfig({
    chains,
    connectors: [
      injected(),
      // WalletConnect is only registered when a project id is configured.
      ...(wcProjectId
        ? [
            walletConnect({
              projectId: wcProjectId,
              showQrModal: true,
              metadata: {
                name: "Overwrite",
                description: "Make your Stock Tokens pay you every week.",
                url: typeof window === "undefined" ? "https://overwrite.finance" : window.location.origin,
                icons: [],
              },
            }),
          ]
        : []),
    ],
    transports: {
      [robinhood.id]: http(targetChainId === robinhood.id ? rpcUrl : undefined, { batch: true }),
      [robinhoodTestnet.id]: http(targetChainId === robinhoodTestnet.id ? rpcUrl : undefined, {
        batch: true,
      }),
    },
    ssr: true,
    storage: createStorage({ storage: cookieStorage }),
  });
}

declare module "wagmi" {
  interface Register {
    config: ReturnType<typeof getConfig>;
  }
}
