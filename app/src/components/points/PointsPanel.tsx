"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { vaultAbi } from "@/lib/abi";
import { targetChain } from "@/lib/chains";
import { fmtCountdown, fmtDateUtc } from "@/lib/format";
import { useCountdown } from "@/hooks/useCountdown";
import { useTargetChain } from "@/hooks/useTargetChain";
import { Stat } from "@/components/site/Bits";
import { Empty } from "@/components/site/States";
import { WalletButton } from "@/components/wallet/WalletButton";

interface VaultRef {
  symbol: string;
  vault: Address;
  stock: Address;
  assetsPerShare: string;
  sRef: string | null;
}

const nf = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });

export function PointsPanel({
  vaults,
  epochEnd,
  hasLedger,
  snapshotAt,
  chainNow,
  fetchedAt,
}: {
  vaults: VaultRef[];
  epochEnd: string | null;
  hasLedger: boolean;
  snapshotAt: string | null;
  chainNow: string;
  fetchedAt: string;
}) {
  const { address, mounted, isConnected } = useTargetChain();
  const endUnix = epochEnd ? Math.floor(Date.parse(epochEnd) / 1000) : 0;
  const { remaining, passed } = useCountdown(endUnix, chainNow, fetchedAt);

  const shares = useReadContracts({
    allowFailure: true,
    query: { enabled: !!address },
    contracts: vaults.map((v) => ({
      address: v.vault,
      abi: vaultAbi,
      functionName: "balanceOf" as const,
      args: [address as Address] as const,
      chainId: targetChain.id,
    })),
  });

  const ledger = useQuery({
    queryKey: ["points", address],
    enabled: !!address && hasLedger,
    queryFn: async () => {
      const r = await fetch(`/api/points?address=${address}`);
      if (!r.ok) throw new Error("points API unavailable");
      return (await r.json()) as { total: number | null; byDay: { day: string; points: number }[] };
    },
  });

  // Live rate: Σ shares × assetsPerShare × price, in USD per day = points per day.
  let perDay = 0;
  let priced = true;
  vaults.forEach((v, i) => {
    const r = shares.data?.[i];
    if (!r || r.status !== "success") return;
    const sh = r.result as bigint;
    if (sh === 0n) return;
    if (!v.sRef) {
      priced = false;
      return;
    }
    const assets = (sh * BigInt(v.assetsPerShare)) / 10n ** 24n;
    perDay += Number((assets * BigInt(v.sRef)) / 10n ** 20n) / 1e6;
  });

  const epoch = (
    <Stat
      label="Epoch ends"
      value={endUnix ? (passed ? "Ended" : fmtCountdown(remaining)) : "Not set"}
      ink
      sub={endUnix ? fmtDateUtc(endUnix) : "The first epoch's end date is announced before it closes."}
    />
  );

  if (!mounted) return null;
  if (!isConnected || !address) {
    return (
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-x-8 gap-y-6">
        <div className="sm:col-span-2 border-t-[1.5px] border-ink pt-4">
          <p className="mb-3">Connect a wallet to see your points and today&apos;s rate.</p>
          <WalletButton />
        </div>
        {epoch}
      </div>
    );
  }

  return (
    <div>
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-x-8 gap-y-6">
        <Stat
          label="Your points"
          value={ledger.data?.total != null ? nf.format(ledger.data.total) : "—"}
          sub={
            hasLedger
              ? snapshotAt
                ? `as of the ${fmtDateUtc(Math.floor(Date.parse(snapshotAt) / 1000))} snapshot`
                : "from the latest snapshot"
              : "your ledger appears after the first 00:00 UTC snapshot"
          }
        />
        <Stat
          label="Earning today"
          value={shares.isLoading ? "…" : `${nf.format(perDay)} / day`}
          ink
          sub={priced ? "1 point per USD deposited, at the current reference price" : "a price feed is unavailable; the rate excludes that vault"}
        />
        {epoch}
      </div>
      {!hasLedger ? (
        <div className="mt-8">
          <Empty title="No snapshot yet.">
            Points are tallied once a day at 00:00 UTC. Your total appears here after the first
            snapshot that sees your deposit; the rate above shows what that day will add.
          </Empty>
        </div>
      ) : null}
      {ledger.data && ledger.data.byDay.length > 0 ? (
        <div className="scroll-x mt-8">
          <table className="tbl max-w-[520px]">
            <caption>Daily snapshots, newest first.</caption>
            <thead>
              <tr>
                <th scope="col">Day</th>
                <th scope="col" className="num">Points</th>
              </tr>
            </thead>
            <tbody>
              {[...ledger.data.byDay].reverse().slice(0, 30).map((d) => (
                <tr key={d.day}>
                  <td>{d.day}</td>
                  <td className="num font-bold">{nf.format(d.points)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}
