import Link from "next/link";
import { CapMeter, Tag } from "@/components/site/Bits";
import { Empty } from "@/components/site/States";
import { fmtBps, fmtDateUtc, fmtPct, fmtUsdCompact } from "@/lib/format";
import type { OverviewDto, PremiumSource, VaultSnapshotDto } from "@/lib/reads/types";
import { STATUS_BLUE, STATUS_LABEL } from "./status";

const sourceTag = (s: PremiumSource | "mixed") =>
  s === "auction" ? "last auction" : s === "estimate" ? "model estimate" : "last auction + estimate";

function StatusCell({ v }: { v: VaultSnapshotDto }) {
  const blue = STATUS_BLUE[v.status];
  const when = v.nextEvent.at !== "0" ? fmtDateUtc(v.nextEvent.at) : null;
  return (
    <span className="whitespace-nowrap">
      <span className={blue ? "text-blue font-bold" : "font-bold"}>{STATUS_LABEL[v.status]}</span>
      {when ? (
        <span className="k">
          {v.status === "idle" ? when : `${v.nextEvent.label} ${when}`}
        </span>
      ) : null}
    </span>
  );
}

export function VaultTable({ overview }: { overview: OverviewDto }) {
  if (overview.vaults.length === 0) {
    return (
      <Empty title="No vaults on this deployment yet.">
        The vault list comes from contracts/deployments/{overview.chainId}.json. Add a vault there and
        redeploy.
      </Empty>
    );
  }
  return (
    <div className="scroll-x">
      <table className="tbl min-w-[860px]">
        <caption>
          Premium figures marked <em>last auction</em> are what market makers actually paid, as a
          share of the token price. <em>Model estimate</em> means no auction has cleared yet for that
          series; real premium is set at auction.
        </caption>
        <thead>
          <tr>
            <th scope="col">Vault</th>
            <th scope="col">This week&apos;s premium</th>
            <th scope="col">Annualised</th>
            <th scope="col">Strike distance</th>
            <th scope="col">Cap used</th>
            <th scope="col" className="num">
              Capacity
            </th>
            <th scope="col">Series</th>
            <th scope="col" />
          </tr>
        </thead>
        <tbody>
          {overview.vaults.map((v) => (
            <tr key={v.symbol} className="row-link">
              <td>
                <Link href={`/vaults/${v.symbol}`} className="no-underline block">
                  <span className="sym">{v.symbol}</span>
                  <span className="k mt-1">{v.name}</span>
                </Link>
              </td>
              <td>
                <span className="pct">{fmtPct(v.premium.current.fraction)}</span>
                <Tag>{sourceTag(v.premium.current.source)}</Tag>
                <span className="k">{v.premium.current.kind === 0 ? "weekday series" : "weekend series"}</span>
              </td>
              <td>
                <span className="pct">{fmtPct(v.premium.annualized.fraction, 1)}</span>
                <Tag>{sourceTag(v.premium.annualized.source)}</Tag>
                <span className="k">both series × 52</span>
              </td>
              <td>
                <span className="font-bold">{fmtBps(v.strikeDistance.bps)}</span>
                <span className="k">
                  {v.strikeDistance.source === "auction" ? "current series" : "keeper default"} ·{" "}
                  {v.strikeDistance.kind === 0 ? "weekday" : "weekend"}
                </span>
              </td>
              <td>
                <CapMeter fraction={v.capUsedFraction} />
                {v.capUsedFraction === null ? <span className="k">price feed unavailable</span> : null}
              </td>
              <td className="num font-bold">
                {v.capacityUsd !== null ? fmtUsdCompact(v.capacityUsd) : "—"}
                <span className="k font-normal">of {fmtUsdCompact(v.vaultCapUsd)} cap</span>
              </td>
              <td>
                <StatusCell v={v} />
              </td>
              <td className="num">
                <Link href={`/vaults/${v.symbol}`} className="link">
                  {v.status === "idle" ? "Deposit" : "Open"}
                </Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
