import type { Abi, Address, PublicClient } from "viem";

/**
 * A typed wrapper over `publicClient.multicall`.
 *
 * Two reasons this exists rather than calling viem directly at each site.
 *
 *  - **Failure is normal here.** `allowFailure: true` maps onto Multicall3's `aggregate3`, which returns
 *    `(false, revertData)` per sub-call instead of reverting the batch. The keeper depends on that:
 *    `getRoundData` reverts "No data present" for any round id never written, and the round search has
 *    to probe ids that may not exist. Verified against the live 46630 feed.
 *  - **viem chunks by calldata size.** `batchSize` defaults to 1024 bytes, so a 200-call batch would be
 *    silently split into dozens of `eth_call`s against a rate-limited public RPC. `batchSize: 0`
 *    disables that and we chunk by call count ourselves, which is the unit we actually reason about.
 */

export type CallResult<T> = { ok: true; value: T } | { ok: false; error: unknown };

export interface Call {
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
}

/** Multicall3 sub-calls per `eth_call`. 200 × ~224 bytes ≈ 45 KB of calldata, comfortably servable. */
export const MULTICALL_CHUNK = 200;

export async function multicall<T = unknown>(
  client: PublicClient,
  calls: readonly Call[],
  chunk = MULTICALL_CHUNK,
): Promise<CallResult<T>[]> {
  const out: CallResult<T>[] = [];
  for (let i = 0; i < calls.length; i += chunk) {
    const slice = calls.slice(i, i + chunk);
    const raw = (await client.multicall({
      allowFailure: true,
      batchSize: 0,
      contracts: slice as never,
    })) as unknown as readonly {
      status: "success" | "failure";
      result?: unknown;
      error?: unknown;
    }[];
    for (const r of raw) {
      out.push(
        r.status === "success" ? { ok: true, value: r.result as T } : { ok: false, error: r.error },
      );
    }
  }
  return out;
}
