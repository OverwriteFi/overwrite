"use client";

import { vaultAbi } from "@/lib/abi";
import { fmtTokens } from "@/lib/format";
import type { VaultSnapshotDto } from "@/lib/reads/types";
import { useTx } from "@/hooks/useTx";
import type { useQueuedRequests } from "@/hooks/useQueuedRequests";
import { TxNote } from "./TxNote";

const STATUS_TEXT = {
  QUEUED: "Waiting for the next settlement",
  EXECUTED: "Executed",
  CANCELLED: "Cancelled",
  EXPIRED: "Expired: the cap was full when it was its turn. Cancel to get the tokens back.",
  NONE: "",
} as const;

export function QueuedRequests({
  v,
  q,
  onChanged,
}: {
  v: VaultSnapshotDto;
  q: ReturnType<typeof useQueuedRequests>;
  onChanged: () => void;
}) {
  const cancel = useTx();
  const aps = BigInt(v.assetsPerShare || "0");
  if (q.loading && q.requests.length === 0) return <p className="note mt-6">Checking the queue…</p>;
  if (q.requests.length === 0) return null;

  return (
    <div className="mt-8">
      <h3 className="h3">Your queued requests</h3>
      <p className="note mt-1">
        {q.pendingDeposits} deposit{q.pendingDeposits === 1 ? "" : "s"} and {q.pendingRedeems} withdrawal
        {q.pendingRedeems === 1 ? "" : "s"} are queued across all depositors. Queues execute in order at the
        next settlement.
      </p>
      <div className="scroll-x mt-4">
        <table className="tbl">
          <thead>
            <tr>
              <th scope="col">Request</th>
              <th scope="col" className="num">Amount</th>
              <th scope="col">Status</th>
              <th scope="col" />
            </tr>
          </thead>
          <tbody>
            {q.requests.map((r) => {
              const cancellable = r.status === "QUEUED" || (r.kind === "deposit" && r.status === "EXPIRED");
              const tokens = r.kind === "deposit" ? r.amount : aps > 0n ? (r.amount * aps) / 10n ** 24n : 0n;
              return (
                <tr key={`${r.kind}-${r.id}`}>
                  <td>
                    <b>{r.kind === "deposit" ? "Deposit" : "Withdrawal"}</b>
                    <span className="k">#{r.id.toString()}{r.position ? ` · position ${r.position}` : ""}</span>
                  </td>
                  <td className="num">
                    {fmtTokens(tokens, v.stock.decimals)} {v.symbol}
                    {r.kind === "redeem" ? <span className="k font-normal">{fmtTokens(r.amount, 24)} shares</span> : null}
                  </td>
                  <td>{STATUS_TEXT[r.status]}</td>
                  <td className="num">
                    {cancellable ? (
                      <button
                        type="button"
                        className="btn btn-plain btn-sm"
                        disabled={cancel.busy}
                        onClick={async () => {
                          const res = await cancel.send({
                            address: v.addresses.vault,
                            abi: vaultAbi,
                            functionName: r.kind === "deposit" ? "cancelDeposit" : "cancelRedeem",
                            args: [r.id],
                          });
                          if (res) onChanged();
                        }}
                      >
                        Cancel
                      </button>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <TxNote status={cancel.status} hash={cancel.hash} error={cancel.error} successText="Cancelled." />
    </div>
  );
}
