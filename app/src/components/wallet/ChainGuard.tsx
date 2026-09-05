"use client";

import type { ReactNode } from "react";
import { targetChain } from "@/lib/chains";
import { useTargetChain } from "@/hooks/useTargetChain";
import { WalletButton } from "./WalletButton";

/** Wraps anything that needs a connected wallet on the target chain; explains what to do otherwise. */
export function ChainGuard({ children, what = "act" }: { children: ReactNode; what?: string }) {
  const { mounted, isConnected, wrongChain, switchOrAdd, switching, switchError } = useTargetChain();
  if (!mounted) return null;
  if (!isConnected) {
    return (
      <div className="border-t-[1.5px] border-ink pt-4">
        <p className="mb-3">Connect a wallet to {what}.</p>
        <WalletButton />
      </div>
    );
  }
  if (wrongChain) {
    return (
      <div className="border-t-[1.5px] border-ink pt-4">
        <p className="mb-1">Your wallet is on another chain.</p>
        <p className="note mb-3">
          Overwrite runs on {targetChain.name} (chain id {targetChain.id}). If your wallet does not
          have it yet, this adds it.
        </p>
        <button type="button" className="btn btn-blue btn-sm" onClick={() => void switchOrAdd()} disabled={switching}>
          {switching ? "Waiting for wallet…" : `Add and switch to ${targetChain.name}`}
        </button>
        {switchError ? <p className="note mt-2 text-ink">{switchError.message}</p> : null}
      </div>
    );
  }
  return <>{children}</>;
}
