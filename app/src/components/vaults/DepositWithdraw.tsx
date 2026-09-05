"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { parseEventLogs, parseUnits, type Address } from "viem";
import { stockTokenAbi, vaultAbi } from "@/lib/abi";
import { fmtTokens, fmtUsdCompact } from "@/lib/format";
import type { VaultSnapshotDto } from "@/lib/reads/types";
import { useQueuedRequests, rememberRequest } from "@/hooks/useQueuedRequests";
import { useTx } from "@/hooks/useTx";
import { useVaultUser } from "@/hooks/useVaultUser";
import { useTargetChain } from "@/hooks/useTargetChain";
import { ChainGuard } from "@/components/wallet/ChainGuard";
import { SharesEq } from "@/components/wallet/SharesEq";
import { TxNote } from "./TxNote";
import { QueuedRequests } from "./QueuedRequests";

type Mode = "deposit" | "withdraw";

function parseAmount(s: string, decimals: number): bigint | null {
  const t = s.trim().replace(/,/g, "");
  if (!t || !/^\d*\.?\d*$/.test(t)) return null;
  try {
    const v = parseUnits(t, decimals);
    return v > 0n ? v : null;
  } catch {
    return null;
  }
}

export function DepositWithdraw({ v }: { v: VaultSnapshotDto }) {
  return (
    <ChainGuard what="deposit or withdraw">
      <Form v={v} />
    </ChainGuard>
  );
}

function Form({ v }: { v: VaultSnapshotDto }) {
  const { address } = useTargetChain();
  const me = address as Address;
  const u = useVaultUser(v.addresses.vault, v.addresses.stock, v.assetsPerShare);
  const q = useQueuedRequests(v.addresses.vault);
  const router = useRouter();
  const [mode, setMode] = useState<Mode>("deposit");
  const [amount, setAmount] = useState("");
  const approve = useTx();
  const tx = useTx();

  const idle = v.state === "IDLE";
  const dec = v.stock.decimals;
  const amt = parseAmount(amount, dec);
  const aps = BigInt(v.assetsPerShare || "0");
  const toShares = (assets: bigint) => (aps > 0n ? (assets * 10n ** 24n) / aps : 0n);

  const done = () => {
    setAmount("");
    u.refetch();
    q.refetch();
    router.refresh();
  };

  // ── deposit ────────────────────────────────────────────────────────────────────────────────────
  const needsApproval = mode === "deposit" && amt !== null && u.stockAllowance < amt;
  const overBalance = mode === "deposit" && amt !== null && amt > u.stockBalance;
  const overCap =
    mode === "deposit" && amt !== null && idle && u.ready && !u.loading && amt > u.maxDeposit;
  const depositBlocked = v.sunset || v.depositsPaused || (idle && !v.remainingDepositAssets && v.sRef === null);

  async function doApprove() {
    if (!amt) return;
    const r = await approve.send({
      address: v.addresses.stock,
      abi: stockTokenAbi,
      functionName: "approve",
      args: [v.addresses.vault, amt],
    });
    if (r) u.refetch();
  }

  async function doDeposit() {
    if (!amt) return;
    if (idle) {
      const r = await tx.send({ address: v.addresses.vault, abi: vaultAbi, functionName: "deposit", args: [amt, me] });
      if (r) done();
    } else {
      const r = await tx.send({ address: v.addresses.vault, abi: vaultAbi, functionName: "requestDeposit", args: [amt, me] });
      if (r) {
        for (const l of parseEventLogs({ abi: vaultAbi, logs: r.logs, eventName: "DepositQueued" })) {
          rememberRequest(v.addresses.vault, me, "deposit", l.args.requestId);
        }
        done();
      }
    }
  }

  // ── withdraw ───────────────────────────────────────────────────────────────────────────────────
  const overPosition = mode === "withdraw" && amt !== null && amt > u.positionAssets;
  const wantAll = mode === "withdraw" && amt !== null && u.positionAssets > 0n && amt >= u.positionAssets;

  async function doWithdraw() {
    if (!amt) return;
    if (idle) {
      const r = wantAll
        ? await tx.send({ address: v.addresses.vault, abi: vaultAbi, functionName: "redeem", args: [u.maxRedeem, me, me] })
        : await tx.send({ address: v.addresses.vault, abi: vaultAbi, functionName: "withdraw", args: [amt, me, me] });
      if (r) done();
    } else {
      const shares = wantAll ? u.shares : toShares(amt);
      const r = await tx.send({ address: v.addresses.vault, abi: vaultAbi, functionName: "requestRedeem", args: [shares, me] });
      if (r) {
        for (const l of parseEventLogs({ abi: vaultAbi, logs: r.logs, eventName: "RedeemQueued" })) {
          rememberRequest(v.addresses.vault, me, "redeem", l.args.requestId);
        }
        done();
      }
    }
  }

  const busy = approve.busy || tx.busy;

  return (
    <div>
      <div className="seg" role="group" aria-label="Deposit or withdraw">
        <button type="button" aria-pressed={mode === "deposit"} onClick={() => { setMode("deposit"); tx.reset(); }}>
          Deposit
        </button>
        <button type="button" aria-pressed={mode === "withdraw"} onClick={() => { setMode("withdraw"); tx.reset(); }}>
          Withdraw
        </button>
      </div>

      <div className="field mt-5">
        <label htmlFor="amt">
          {mode === "deposit" ? `${v.symbol} to deposit` : `${v.symbol} to withdraw`}
        </label>
        <div className="flex gap-2">
          <input
            id="amt"
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            disabled={busy}
          />
          <button
            type="button"
            className="btn btn-plain btn-sm"
            disabled={busy || u.loading}
            onClick={() =>
              setAmount(
                mode === "deposit"
                  ? fmtTokens(u.stockBalance, dec, 18).replace(/,/g, "")
                  : fmtTokens(u.positionAssets, dec, 18).replace(/,/g, ""),
              )
            }
          >
            Max
          </button>
        </div>
        <p className="note mt-2">
          {mode === "deposit" ? (
            <>
              Wallet: {fmtTokens(u.stockBalance, dec)} {v.symbol}{" "}
              <SharesEq raw={u.stockBalance} uiMultiplier={u.uiMultiplier} />
              {idle && u.ready ? <> · Room in the cap: {fmtTokens(u.maxDeposit, dec)} {v.symbol}</> : null}
            </>
          ) : (
            <>
              Deposited: {fmtTokens(u.positionAssets, dec)} {v.symbol}{" "}
              <SharesEq raw={u.positionAssets} uiMultiplier={u.uiMultiplier} />
            </>
          )}
        </p>
      </div>

      {/* What will happen, in plain words, before the user clicks. */}
      <div className="mt-4 border-t border-rule pt-3 text-[15px] max-w-[60ch]">
        {mode === "deposit" ? (
          idle ? (
            <p>
              The vault is idle, so your tokens become shares now. They are offered in the next auction and
              premium lands in your claimable balance the moment it clears.
            </p>
          ) : (
            <p>
              A series is live, so deposits wait in a queue. Your tokens are held by the vault and turn
              into shares at the next settlement, at the share price after that settlement. Cancel any
              time before then and the tokens come straight back.
            </p>
          )
        ) : idle ? (
          <p>
            The vault is idle, so tokens come straight back to your wallet. Any premium you have not
            claimed stays claimable.
          </p>
        ) : (
          <p>
            A series is live and your tokens are covering it, so withdrawals queue until it settles. Your
            shares are escrowed now (escrowed shares earn no further premium), redeemed at the settlement
            share price, and the tokens then wait under <b>Claim</b> on this page. Cancel any time before
            settlement to get the shares back.
          </p>
        )}
      </div>

      {overBalance ? <p className="note mt-2 text-ink">More than your wallet holds.</p> : null}
      {overCap ? (
        <p className="note mt-2 text-ink">
          Above the remaining capacity ({fmtTokens(u.maxDeposit, dec)} {v.symbol},{" "}
          {v.capacityUsd ? fmtUsdCompact(v.capacityUsd) : "—"}). Capacity fills in order; deposit the
          remainder or queue it for after the next settlement.
        </p>
      ) : null}
      {overPosition ? <p className="note mt-2 text-ink">More than you have deposited.</p> : null}
      {depositBlocked && mode === "deposit" ? (
        <p className="note mt-2 text-ink">
          {v.sunset
            ? "This vault is sunset and takes no new deposits. Withdrawals stay open."
            : v.depositsPaused
              ? "Deposits are paused by the guardian right now."
              : "The price feed is unavailable, so the cap cannot be checked. Try again shortly."}
        </p>
      ) : null}

      <div className="mt-5 flex flex-wrap gap-3">
        {mode === "deposit" ? (
          needsApproval ? (
            <button type="button" className="btn btn-blue" disabled={!amt || overBalance || busy || depositBlocked} onClick={doApprove}>
              {approve.busy ? "Approving…" : `1. Approve ${v.symbol}`}
            </button>
          ) : (
            <button
              type="button"
              className="btn btn-blue"
              disabled={!amt || overBalance || overCap || busy || depositBlocked}
              onClick={doDeposit}
            >
              {tx.busy ? "Sending…" : idle ? "Deposit" : "Queue deposit"}
            </button>
          )
        ) : (
          <button type="button" className="btn btn-blue" disabled={!amt || overPosition || busy} onClick={doWithdraw}>
            {tx.busy ? "Sending…" : idle ? (wantAll ? "Withdraw everything" : "Withdraw") : "Queue withdrawal"}
          </button>
        )}
        {needsApproval && amt ? (
          <span className="note self-center">then 2. {idle ? "Deposit" : "Queue deposit"}</span>
        ) : null}
      </div>
      <TxNote status={approve.status} hash={approve.hash} error={approve.error} successText="Approved. Now deposit." />
      <TxNote
        status={tx.status}
        hash={tx.hash}
        error={tx.error}
        successText={
          mode === "deposit"
            ? idle
              ? "Deposited. Your shares are in."
              : "Queued. It executes at the next settlement."
            : idle
              ? "Withdrawn. Tokens are back in your wallet."
              : "Queued. It executes at the next settlement; claim the tokens here afterwards."
        }
      />

      <QueuedRequests v={v} q={q} onChanged={done} />
    </div>
  );
}
