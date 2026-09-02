import { cookieStorage, createConfig, createStorage, http } from "wagmi";
import { injected, walletConnect } from "wagmi/connectors";
import { robinhood, robinhoodTestnet } from "./chains";

const wcProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

export function getConfig() {
  return createConfig({
    chains: [robinhood, robinhoodTestnet],
    connectors: [
      injected(),
      // WalletConnect is only registered when a project id is configured.
      ...(wcProjectId ? [walletConnect({ projectId: wcProjectId, showQrModal: true })] : []),
    ],
    transports: {
      [robinhood.id]: http(),
      [robinhoodTestnet.id]: http(),
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
