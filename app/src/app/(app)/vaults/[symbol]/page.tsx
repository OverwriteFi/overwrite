import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Section, Stat } from "@/components/site/Bits";
import { Banners } from "@/components/vaults/Banners";
import { Countdown } from "@/components/vaults/Countdown";
import { DepositWithdraw } from "@/components/vaults/DepositWithdraw";
import { HistoryTable, PremiumHistory } from "@/components/vaults/HistoryTable";
import { Position } from "@/components/vaults/Position";
import { SeriesPanel } from "@/components/vaults/SeriesPanel";
import { STATUS_LABEL } from "@/components/vaults/status";
import { explorerUrl } from "@/lib/chains";
import { vaultBySymbol } from "@/lib/deployment";
import { fmtBps, fmtDateUtc, fmtPct, fmtPrice8, fmtTokens, fmtUsdCompact } from "@/lib/format";
import { getVault } from "@/lib/reads/overview";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: PageProps<"/vaults/[symbol]">): Promise<Metadata> {
  const { symbol } = await params;
  return { title: `${symbol.toUpperCase()} vault` };
}

export default async function VaultPage({ params }: PageProps<"/vaults/[symbol]">) {
  const { symbol } = await params;
  if (!vaultBySymbol(symbol)) notFound();
  const data = await getVault(symbol);
  if (!data) notFound();
  const { overview, vault: v, history } = data;
  const tag = (s: "auction" | "estimate" | "mixed") =>
    s === "auction" ? "last auction" : s === "estimate" ? "model estimate" : "last auction + estimate";

  return (
    <div className="wrap pt-10 sm:pt-14">
      <p className="text-[15px]">
        <Link href="/vaults" className="doc">
          All vaults
        </Link>
      </p>
      <div className="mt-4 flex flex-wrap items-end justify-between gap-6">
        <div>
          <h1 className="h1">{v.symbol}</h1>
          <p className="lede mt-3">
            {v.name}. Market makers compete for your upside every week; premium is paid in USDG
            before the week starts.
          </p>
        </div>
        <div className="sm:text-right">
          <span className="k">Reference price</span>
          <div className="stat-v ink">{v.sRef ? fmtPrice8(v.sRef) : "—"}</div>
          <p className="note">
            {v.feed ? `Chainlink, updated ${fmtDateUtc(v.feed.updatedAt)}` : "price feed unavailable"}
          </p>
        </div>
      </div>

      <Banners v={v} chainNow={overview.chainNow} />

      <div className="mt-10 grid grid-cols-2 lg:grid-cols-4 gap-x-8 gap-y-6">
        <Stat label="This week's premium" value={fmtPct(v.premium.current.fraction)} tag={tag(v.premium.current.source)} />
        <Stat label="Annualised, both series" value={fmtPct(v.premium.annualized.fraction, 1)} tag={tag(v.premium.annualized.source)} />
        <Stat label="Strike distance" value={fmtBps(v.strikeDistance.bps)} ink sub={v.strikeDistance.source === "auction" ? "current series" : "keeper default, weekday"} />
        <Stat
          label="Capacity"
          value={v.capacityUsd !== null ? fmtUsdCompact(v.capacityUsd) : "—"}
          ink
          sub={`${fmtTokens(v.totalAssets, v.stock.decimals, 2)} ${v.symbol} deposited of a ${fmtUsdCompact(v.vaultCapUsd)} cap`}
        />
      </div>

      <div className="mt-14 grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-x-14 gap-y-12">
        <Section title="Your position" className="mt-0">
          <Position v={v} />
        </Section>
        <Section title="Deposit or withdraw" className="mt-0">
          <DepositWithdraw v={v} />
        </Section>
      </div>

      <div className="mt-16 grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-x-14 gap-y-12">
        <Section
          title="Current series"
          className="mt-0"
          sub={
            <>
              Vault status: <b className="text-ink">{STATUS_LABEL[v.status]}</b>
            </>
          }
        >
          <SeriesPanel v={v} />
        </Section>
        <Section title="What happens next" className="mt-0" sub="Two paydays a week. The clock runs on chain time.">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-6">
            <Countdown
              target={v.nextEvent.at}
              chainNow={overview.chainNow}
              fetchedAt={overview.fetchedAt}
              label={v.nextEvent.label}
              passedLabel={v.status === "settling" ? "Settling now" : v.status === "clearing" ? "Clearing now" : "Any moment"}
            />
            <div className="border-t-[1.5px] border-ink pt-3">
              <span className="k">Weekly rhythm</span>
              <ul className="list-none m-0 p-0 mt-1 text-[15px]">
                <li className="py-1 border-b border-rule">Monday 14:00 UTC · weekday auction, 15 minutes</li>
                <li className="py-1 border-b border-rule">Friday 20:00 UTC · weekday series settles on Chainlink</li>
                <li className="py-1 border-b border-rule">Friday 20:10 UTC · weekend auction, 15 minutes</li>
                <li className="py-1 border-b border-rule">Sunday 23:59 UTC · weekend series settles</li>
              </ul>
            </div>
          </div>
        </Section>
      </div>

      <Section title="Settled series" sub="Three outcomes. You get paid in all three.">
        <HistoryTable v={v} rows={history} />
      </Section>

      <Section title="Premium history" sub="What market makers paid for your upside, auction by auction.">
        <PremiumHistory v={v} rows={history} />
      </Section>

      <p className="note mt-10">
        Vault{" "}
        <a href={explorerUrl("address", v.addresses.vault)} target="_blank" rel="noreferrer" className="underline underline-offset-4">
          {v.addresses.vault}
        </a>{" "}
        · Stock Token{" "}
        <a href={explorerUrl("address", v.addresses.stock)} target="_blank" rel="noreferrer" className="underline underline-offset-4">
          {v.addresses.stock}
        </a>{" "}
        · read at {fmtDateUtc(overview.chainNow)}.
      </p>
    </div>
  );
}
