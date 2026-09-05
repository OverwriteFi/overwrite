"use client";

import { explorerUrl } from "@/lib/chains";
import type { TxStatus } from "@/hooks/useTx";

/** One line under a form: what the transaction is doing, or why it did not happen. */
export function TxNote({
  status,
  hash,
  error,
  successText = "Done.",
}: {
  status: TxStatus;
  hash: string | null;
  error: string | null;
  successText?: string;
}) {
  if (status === "idle") return null;
  const link = hash ? (
    <a href={explorerUrl("tx", hash)} target="_blank" rel="noreferrer" className="link">
      View on Blockscout
    </a>
  ) : null;
  return (
    <p className={`note mt-3 ${status === "error" ? "text-ink" : ""}`} role={status === "error" ? "alert" : "status"}>
      {status === "confirming" ? "Confirm in your wallet…" : null}
      {status === "pending" ? <>Sent. Waiting for the chain… {link}</> : null}
      {status === "success" ? <>{successText} {link}</> : null}
      {status === "error" ? <>{error} {link}</> : null}
    </p>
  );
}
