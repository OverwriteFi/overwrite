"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { parseUnits, type Address } from "viem";
import { useReadContracts } from "wagmi";
import { erc20Abi, safetyModuleAbi } from "@/lib/abi";
import { targetChain } from "@/lib/chains";
import { fmtCountdown, fmtDateUtc, fmtTokens } from "@/lib/format";
import type { StakeOverviewDto } from "@/lib/reads/types";
import { useChainClock } from "@/hooks/useCountdown";
import { useTargetChain } from "@/hooks/useTargetChain";
import { useTx } from "@/hooks/useTx";
import { ChainGuard } from "@/components/wallet/ChainGuard";
import { Row, Rows } from "@/components/site/Bits";
import { TxNote } from "@/components/vaults/TxNote";

export function StakePanel({ s }: { s: StakeOverviewDto }) {
  return (
    <ChainGuard what="stake WRITE">
      <Panel s={s} />
    </ChainGuard>
  );
}

function parse(v: string): bigint | null {
  const t = v.trim().replace(/,/g, "");
  if (!t || !/^\d*\.?\d*$/.test(t)) return null;
  try {
    const n = parseUnits(t, 18);
    return n > 0n ? n : null;
  } catch {
    return null;
  }
}

function Panel({ s }: { s: StakeOverviewDto }) {
  const { address } = useTargetChain();
  const me = address as Address;
  const sm = s.safetyModule as Address;
  const write = s.writeToken as Address;
  const router = useRouter();
  const now = useChainClock(s.chainNow, new Date().toISOString());
  const [mode, setMode] = useState<"stake" | "unstake">("stake");
  const [amount, setAmount] = useState("");
  const approve = useTx();
  const tx = useTx();

  const q = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: write, abi: erc20Abi, functionName: "balanceOf", args: [me], chainId: targetChain.id },
      { address: write, abi: erc20Abi, functionName: "allowance", args: [me, sm], chainId: targetChain.id },
      { address: sm, abi: safetyModuleAbi, functionName: "sharesOf", args: [me], chainId: targetChain.id },
      { address: sm, abi: safetyModuleAbi, functionName: "stakedOf", args: [me], chainId: targetChain.id },
      { address: sm, abi: safetyModuleAbi, functionName: "cooldowns", args: [me], chainId: targetChain.id },
      { address: sm, abi: safetyModuleAbi, functionName: "unstakeWindow", args: [me], chainId: targetChain.id },
      { address: sm, abi: safetyModuleAbi, functionName: "pendingRewards", args: [me], chainId: targetChain.id },
    ],
  });
  const g = <T,>(i: number, d: T): T => {
    const r = q.data?.[i];
    return r && r.status === "success" ? (r.result as T) : d;
  };
  const balance = g<bigint>(0, 0n);
  const allowance = g<bigint>(1, 0n);
  const shares = g<bigint>(2, 0n);
  const staked = g<bigint>(3, 0n);
  const cd = g<readonly [bigint, bigint]>(4, [0n, 0n]);
  const win = g<readonly [bigint, bigint]>(5, [0n, 0n]);
  const rewards = g<bigint>(6, 0n);
  const cdShares = cd[0];
  const opensAt = Number(win[0]);
  const closesAt = Number(win[1]);
  const inWindow = cdShares > 0n && now >= opensAt && now <= closesAt;
  const expired = cdShares > 0n && now > closesAt;

  const amt = parse(amount);
  const done = () => {
    setAmount("");
    void q.refetch();
    router.refresh();
  };
  const busy = approve.busy || tx.busy;
  // Unstake amounts are entered in WRITE and converted to shares pro rata.
  const toShares = (w: bigint) => (staked > 0n ? (w * shares) / staked : 0n);

  return (
    <div>
      <Rows>
        <Row label="Staked" note={`${fmtTokens(shares, 24, 4)} safety-module shares`}>
          {fmtTokens(staked, 18, 2)} WRITE
        </Row>
        <Row label="In your wallet">{fmtTokens(balance, 18, 2)} WRITE</Row>
        <Row label="Rewards waiting" note="Emissions stream to stakers; claim any time.">
          <span className="pct">{fmtTokens(rewards, 18, 2)} WRITE</span>
        </Row>
        {cdShares > 0n ? (
          <Row
            label="Unstake in progress"
            note={
              inWindow
                ? `Claim window closes ${fmtDateUtc(closesAt)}`
                : expired
                  ? "The claim window has closed. Cancel and request again."
                  : `Claimable from ${fmtDateUtc(opensAt)}`
            }
          >
            {fmtTokens(cdShares, 24, 4)} shares
            <span className="k font-normal">{inWindow ? "claim now" : expired ? "expired" : `${fmtCountdown(opensAt - now)} left`}</span>
          </Row>
        ) : null}
      </Rows>

      {cdShares > 0n ? (
        <div className="mt-4 flex flex-wrap gap-3">
          <button
            type="button"
            className="btn btn-blue btn-sm"
            disabled={!inWindow || busy}
            onClick={async () => {
              const r = await tx.send({ address: sm, abi: safetyModuleAbi, functionName: "unstake" });
              if (r) done();
            }}
          >
            {inWindow ? "Claim unstaked WRITE" : "Waiting for cooldown"}
          </button>
          <button
            type="button"
            className="btn btn-plain btn-sm"
            disabled={busy}
            onClick={async () => {
              const r = await tx.send({ address: sm, abi: safetyModuleAbi, functionName: "cancelUnstake" });
              if (r) done();
            }}
          >
            Cancel and keep staking
          </button>
        </div>
      ) : null}

      <div className="seg mt-8" role="group" aria-label="Stake or unstake">
        <button type="button" aria-pressed={mode === "stake"} onClick={() => { setMode("stake"); tx.reset(); }}>Stake</button>
        <button type="button" aria-pressed={mode === "unstake"} onClick={() => { setMode("unstake"); tx.reset(); }} disabled={cdShares > 0n}>
          Request unstake
        </button>
      </div>
      <div className="field mt-4">
        <label htmlFor="stake-amt">{mode === "stake" ? "WRITE to stake" : "WRITE to unstake"}</label>
        <div className="flex gap-2">
          <input id="stake-amt" type="text" inputMode="decimal" placeholder="0.0" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={busy} />
          <button type="button" className="btn btn-plain btn-sm" disabled={busy} onClick={() => setAmount(fmtTokens(mode === "stake" ? balance : staked, 18, 18).replace(/,/g, ""))}>
            Max
          </button>
        </div>
      </div>
      <div className="mt-4 flex flex-wrap gap-3">
        {mode === "stake" ? (
          amt && allowance < amt ? (
            <button type="button" className="btn btn-blue" disabled={!amt || amt > balance || busy} onClick={async () => {
              const r = await approve.send({ address: write, abi: erc20Abi, functionName: "approve", args: [sm, amt] });
              if (r) void q.refetch();
            }}>
              {approve.busy ? "Approving…" : "1. Approve WRITE"}
            </button>
          ) : (
            <button type="button" className="btn btn-blue" disabled={!amt || amt > balance || busy} onClick={async () => {
              const r = await tx.send({ address: sm, abi: safetyModuleAbi, functionName: "stake", args: [amt] });
              if (r) done();
            }}>
              {tx.busy ? "Sending…" : "Stake"}
            </button>
          )
        ) : (
          <button type="button" className="btn btn-blue" disabled={!amt || amt > staked || busy || cdShares > 0n} onClick={async () => {
            const sh = amt && amt >= staked ? shares : toShares(amt ?? 0n);
            const r = await tx.send({ address: sm, abi: safetyModuleAbi, functionName: "requestUnstake", args: [sh] });
            if (r) done();
          }}>
            {tx.busy ? "Sending…" : "Start cooldown"}
          </button>
        )}
        <button type="button" className="btn btn-plain" disabled={rewards === 0n || busy} onClick={async () => {
          const r = await tx.send({ address: sm, abi: safetyModuleAbi, functionName: "claimRewards" });
          if (r) done();
        }}>
          Claim rewards
        </button>
      </div>
      {amt && mode === "stake" && amt > balance ? <p className="note mt-2 text-ink">More than your wallet holds.</p> : null}
      {amt && mode === "unstake" && amt > staked ? <p className="note mt-2 text-ink">More than you have staked.</p> : null}
      <TxNote status={approve.status} hash={approve.hash} error={approve.error} successText="Approved. Now stake." />
      <TxNote status={tx.status} hash={tx.hash} error={tx.error} successText="Done." />
    </div>
  );
}
