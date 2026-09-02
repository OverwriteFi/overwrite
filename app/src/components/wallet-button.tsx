"use client";

import { useAccount, useChainId, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { targetChain } from "@/lib/chains";

function short(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function WalletButton() {
  const { address, isConnected, chainId: walletChainId } = useAccount();
  const configChainId = useChainId();
  const { connectors, connect, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  if (isConnected && address) {
    // Note: useChainId() reports the config chain, not the wallet's. Use useAccount().chainId for guards.
    const wrongChain = walletChainId !== targetChain.id;
    return (
      <div className="flex items-center gap-3">
        <span className="font-mono text-sm">{short(address)}</span>
        {wrongChain ? (
          <button
            className="rounded-md border border-amber-500 px-3 py-1 text-sm"
            onClick={() => switchChain({ chainId: targetChain.id })}
          >
            switch to {targetChain.name}
          </button>
        ) : (
          <span className="text-xs text-emerald-500">{targetChain.name}</span>
        )}
        <button className="rounded-md border px-3 py-1 text-sm" onClick={() => disconnect()}>
          disconnect
        </button>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap gap-2">
        {connectors.map((c) => (
          <button
            key={c.uid}
            disabled={isPending}
            className="rounded-md border px-3 py-1 text-sm disabled:opacity-50"
            onClick={() => connect({ connector: c })}
          >
            {c.name}
          </button>
        ))}
      </div>
      {error ? <p className="text-xs text-red-500">{error.message}</p> : null}
      <p className="text-xs opacity-60">config chain id: {configChainId}</p>
    </div>
  );
}
