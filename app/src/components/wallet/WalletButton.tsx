"use client";

import { useState } from "react";
import { useConnect, useDisconnect } from "wagmi";
import { targetChain } from "@/lib/chains";
import { short } from "@/lib/format";
import { useTargetChain } from "@/hooks/useTargetChain";

export function WalletButton() {
  const { address, isConnected, mounted, wrongChain, switchOrAdd, switching } = useTargetChain();
  const { connectors, connectAsync, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const [open, setOpen] = useState(false);

  if (!mounted) {
    return <span className="btn btn-blue btn-sm opacity-0">Connect wallet</span>;
  }

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-3">
        {wrongChain ? (
          <button type="button" className="btn btn-blue btn-sm" onClick={() => void switchOrAdd()} disabled={switching}>
            {switching ? "Switching…" : `Switch to ${targetChain.name}`}
          </button>
        ) : (
          <span className="text-[13px] text-gray hidden sm:inline">{targetChain.name}</span>
        )}
        <button
          type="button"
          className="btn btn-plain btn-sm"
          onClick={() => disconnect()}
          title="Disconnect"
        >
          {short(address)}
        </button>
      </div>
    );
  }

  return (
    <div className="relative">
      <button type="button" className="btn btn-blue btn-sm" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        Connect wallet
      </button>
      {open ? (
        <div className="absolute right-0 mt-2 z-20 bg-white border-[1.5px] border-ink rounded-[4px] p-3 min-w-[240px]">
          <span className="k mb-2">Choose a wallet</span>
          <div className="flex flex-col gap-2">
            {connectors.map((c) => (
              <button
                key={c.uid}
                type="button"
                disabled={isPending}
                className="btn btn-plain btn-sm text-left"
                onClick={async () => {
                  try {
                    await connectAsync({ connector: c, chainId: targetChain.id });
                    setOpen(false);
                  } catch {
                    /* error surfaces below */
                  }
                }}
              >
                {c.name}
              </button>
            ))}
            {connectors.length === 0 ? (
              <p className="note">No wallet found. Install a browser wallet such as Rabby or MetaMask.</p>
            ) : null}
          </div>
          {error ? <p className="note mt-2 text-ink">{error.message}</p> : null}
          {!process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ? (
            <p className="note mt-2">WalletConnect appears once NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID is set.</p>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
