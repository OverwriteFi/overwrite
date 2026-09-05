import "server-only";
import { createPublicClient, http, type PublicClient } from "viem";
import { rpcUrl, targetChain } from "../chains";

let client: PublicClient | undefined;

/** One server-side client per process. Reads batch through Multicall3 (declared on the chain). */
export function publicClient(): PublicClient {
  if (!client) {
    client = createPublicClient({
      chain: targetChain,
      transport: http(rpcUrl, { batch: true, timeout: 20_000, retryCount: 1 }),
    });
  }
  return client;
}

export type Call = {
  address: `0x${string}`;
  abi: readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
};

export type CallResult = { ok: true; value: unknown } | { ok: false; error: string };

/** `aggregate3` semantics: one failed call never fails the batch. Chunked so big series scans stay under RPC limits. */
export async function multicall(calls: Call[], chunk = 120): Promise<CallResult[]> {
  if (calls.length === 0) return [];
  const c = publicClient();
  const out: CallResult[] = [];
  for (let i = 0; i < calls.length; i += chunk) {
    const slice = calls.slice(i, i + chunk);
    const res = await c.multicall({
      allowFailure: true,
      // viem's generic typing cannot follow a heterogeneous list; the callers narrow each value.
      contracts: slice as never,
    });
    for (const r of res as Array<{ status: "success" | "failure"; result?: unknown; error?: Error }>) {
      out.push(
        r.status === "success"
          ? { ok: true, value: r.result }
          : { ok: false, error: r.error?.message ?? "call failed" },
      );
    }
  }
  return out;
}

export const pick = <T>(r: CallResult | undefined, fallback: T): T =>
  r && r.ok ? (r.value as T) : fallback;

/** Chain time, never `Date.now()`: the fork harness warps time and the UI must follow the chain. */
export async function chainNow(): Promise<bigint> {
  const b = await publicClient().getBlock({ blockTag: "latest" });
  return b.timestamp;
}
