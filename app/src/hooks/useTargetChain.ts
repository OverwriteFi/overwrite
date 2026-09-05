"use client";

import { useAccount, useSwitchChain } from "wagmi";
import { targetChain } from "@/lib/chains";
import { useMounted } from "./useMounted";

/**
 * `useChainId()` reports the *config* chain, never the wallet's. Every guard here reads
 * `useAccount().chainId`. `switchChain` on the injected connector falls through to
 * `wallet_addEthereumChain` with the chain's rpcUrls/blockExplorers when the wallet does not know it,
 * which is the add-chain prompt.
 */
export function useTargetChain() {
  const { address, isConnected, chainId: walletChainId, connector } = useAccount();
  const { switchChainAsync, isPending, error } = useSwitchChain();
  // Rabby and a few wallets report a chain before hydration; only trust the value once mounted.
  const mounted = useMounted();

  const wrongChain = mounted && isConnected && walletChainId !== targetChain.id;

  async function switchOrAdd() {
    await switchChainAsync({
      chainId: targetChain.id,
      addEthereumChainParameter: {
        chainName: targetChain.name,
        nativeCurrency: targetChain.nativeCurrency,
        rpcUrls: [...targetChain.rpcUrls.default.http],
        blockExplorerUrls: targetChain.blockExplorers
          ? [targetChain.blockExplorers.default.url]
          : undefined,
      },
    });
  }

  return {
    address,
    isConnected: mounted && isConnected,
    mounted,
    walletChainId,
    wrongChain,
    ready: mounted && isConnected && !wrongChain && !!address,
    switchOrAdd,
    switching: isPending,
    switchError: error,
    connectorName: connector?.name,
  };
}
