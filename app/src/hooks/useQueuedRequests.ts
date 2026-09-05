"use client";

import { useCallback, useMemo, useState } from "react";
import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { vaultAbi, RequestStatus, type RequestStatusName } from "@/lib/abi";
import { targetChain } from "@/lib/chains";
import { useMounted } from "./useMounted";
import { useTargetChain } from "./useTargetChain";

/**
 * The vault's queues are arrays and request ids are array indexes, so the pending window is
 * `[head, length)` and can be scanned with plain state reads — no event history needed (the public
 * RPC keeps ~19 minutes of it). Ids the user created here are also remembered in localStorage so
 * executed or cancelled requests that have left the window still show up.
 */

export interface QueuedRequest {
  id: bigint;
  kind: "deposit" | "redeem";
  requester: Address;
  receiver: Address;
  amount: bigint; // assets (18 dp) for deposits, shares (24 dp) for redeems
  status: RequestStatusName;
  /** 1-based position among pending requests of the same kind, or null when not pending. */
  position: number | null;
}

const MAX_SCAN = 200;

function storageKey(vault: Address, user: Address, kind: "deposit" | "redeem") {
  return `ow:req:${targetChain.id}:${vault.toLowerCase()}:${user.toLowerCase()}:${kind}`;
}

export function rememberRequest(vault: Address, user: Address, kind: "deposit" | "redeem", id: bigint) {
  try {
    const k = storageKey(vault, user, kind);
    const cur = JSON.parse(localStorage.getItem(k) ?? "[]") as string[];
    if (!cur.includes(id.toString())) localStorage.setItem(k, JSON.stringify([...cur, id.toString()].slice(-50)));
  } catch {
    /* storage unavailable */
  }
}

function readRemembered(vault: Address, user: Address, kind: "deposit" | "redeem"): bigint[] {
  try {
    return (JSON.parse(localStorage.getItem(storageKey(vault, user, kind)) ?? "[]") as string[]).map(BigInt);
  } catch {
    return [];
  }
}

export function useQueuedRequests(vault: Address) {
  const { address, ready } = useTargetChain();
  const mounted = useMounted();
  const [tick, setTick] = useState(0);
  const bump = useCallback(() => setTick((t) => t + 1), []);

  // localStorage is only read after mount (tick re-reads it after a new request is remembered).
  const remembered = useMemo(
    () =>
      mounted && address
        ? { deposit: readRemembered(vault, address, "deposit"), redeem: readRemembered(vault, address, "redeem") }
        : { deposit: [] as bigint[], redeem: [] as bigint[] },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [vault, address, mounted, tick],
  );

  const heads = useReadContracts({
    allowFailure: true,
    query: { enabled: ready },
    contracts: [
      { address: vault, abi: vaultAbi, functionName: "depositQueueHead", chainId: targetChain.id },
      { address: vault, abi: vaultAbi, functionName: "depositQueueLength", chainId: targetChain.id },
      { address: vault, abi: vaultAbi, functionName: "redeemQueueHead", chainId: targetChain.id },
      { address: vault, abi: vaultAbi, functionName: "redeemQueueLength", chainId: targetChain.id },
    ],
  });

  const g = (i: number): bigint => {
    const r = heads.data?.[i];
    return r && r.status === "success" ? (r.result as bigint) : 0n;
  };
  const dHead = g(0);
  const dLen = g(1);
  const rHead = g(2);
  const rLen = g(3);

  const ids = useMemo(() => {
    const dep = new Set<bigint>(remembered.deposit);
    const red = new Set<bigint>(remembered.redeem);
    for (let i = dHead; i < dLen && i < dHead + BigInt(MAX_SCAN); i++) dep.add(i);
    for (let i = rHead; i < rLen && i < rHead + BigInt(MAX_SCAN); i++) red.add(i);
    return { deposit: [...dep].sort((a, b) => Number(a - b)), redeem: [...red].sort((a, b) => Number(a - b)) };
  }, [remembered, dHead, dLen, rHead, rLen]);

  const reqs = useReadContracts({
    allowFailure: true,
    query: { enabled: ready && heads.isSuccess && ids.deposit.length + ids.redeem.length > 0 },
    contracts: [
      ...ids.deposit.map((id) => ({ address: vault, abi: vaultAbi, functionName: "queuedDeposit" as const, args: [id] as const, chainId: targetChain.id })),
      ...ids.redeem.map((id) => ({ address: vault, abi: vaultAbi, functionName: "queuedRedeem" as const, args: [id] as const, chainId: targetChain.id })),
    ],
  });

  const requests = useMemo<QueuedRequest[]>(() => {
    if (!address || !reqs.data) return [];
    const me = address.toLowerCase();
    const out: QueuedRequest[] = [];
    // Positions count *all* pending requests ahead in the queue, not only the user's own.
    const posOf = (kind: "deposit" | "redeem", id: bigint) => {
      const head = kind === "deposit" ? dHead : rHead;
      return id >= head ? Number(id - head) + 1 : null;
    };
    reqs.data.forEach((r, i) => {
      if (r.status !== "success") return;
      const v = r.result as { requester: Address; receiver: Address; assets?: bigint; shares?: bigint; status: number };
      const kind: "deposit" | "redeem" = i < ids.deposit.length ? "deposit" : "redeem";
      const id = kind === "deposit" ? ids.deposit[i] : ids.redeem[i - ids.deposit.length];
      if (v.requester.toLowerCase() !== me && v.receiver.toLowerCase() !== me) return;
      const status = RequestStatus[v.status] ?? "NONE";
      out.push({
        id,
        kind,
        requester: v.requester,
        receiver: v.receiver,
        amount: kind === "deposit" ? (v.assets ?? 0n) : (v.shares ?? 0n),
        status,
        position: status === "QUEUED" ? posOf(kind, id) : null,
      });
    });
    return out.sort((a, b) => Number(b.id - a.id));
  }, [reqs.data, address, ids, dHead, rHead]);

  return {
    requests,
    pendingDeposits: Number(dLen - dHead),
    pendingRedeems: Number(rLen - rHead),
    loading: ready && (heads.isLoading || reqs.isLoading),
    refetch: () => {
      bump();
      void heads.refetch();
      void reqs.refetch();
    },
  };
}
