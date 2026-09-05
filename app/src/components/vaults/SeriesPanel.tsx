import { Row, Rows, Tag } from "@/components/site/Bits";
import { fmtBps, fmtDateUtc, fmtPct, fmtPrice8, fmtTokens, fmtUsd } from "@/lib/format";
import { premiumFractionOf } from "@/lib/reads/overview";
import type { VaultSnapshotDto } from "@/lib/reads/types";

const SERIES_LABEL: Record<string, string> = {
  AUCTION: "auction open",
  LIVE: "live",
  SETTLED: "settled",
  RESOLVED: "resolved",
  HALTED: "halted",
  SKIPPED: "skipped",
};

export function SeriesPanel({ v }: { v: VaultSnapshotDto }) {
  const a = v.auction;
  const se = v.series;
  if (!a || !se) {
    return (
      <p className="text-gray max-w-[60ch]">
        No series has been opened for this vault yet. The first auction opens Monday 14:00 UTC once
        the keeper has a reference price and the vault holds tokens to offer.
      </p>
    );
  }
  const sRef = BigInt(a.sRef);
  const premium = a.state === "CLEARED" ? premiumFractionOf(BigInt(a.clearingPrice), sRef) : null;
  const dist = sRef > 0n ? Math.round((Number(BigInt(a.strike) - sRef) * 10_000) / Number(sRef)) : null;
  const net = BigInt(a.premiumGross) - BigInt(a.fee);
  const fill = BigInt(a.offeredQty) > 0n ? Number(BigInt(a.filledQty)) / Number(BigInt(a.offeredQty)) : null;

  return (
    <Rows>
      <Row label="Series">
        #{a.id} · {a.kind === 0 ? "Weekday" : "Weekend"}
        <Tag blue={se.state === "AUCTION" || se.state === "LIVE"}>{SERIES_LABEL[se.state] ?? se.state.toLowerCase()}</Tag>
      </Row>
      <Row label="Reference price at open">{fmtPrice8(a.sRef)}</Row>
      <Row label="Strike (the cap)" note="Upside above this is sold; everything below it is yours.">
        {fmtPrice8(a.strike)} <span className="k font-normal">{fmtBps(dist)} above reference</span>
      </Row>
      <Row label="Expires">{fmtDateUtc(a.expiry)}</Row>
      <Row label="Auction window">
        {fmtDateUtc(a.auctionOpen)} <span className="k font-normal">to {fmtDateUtc(a.auctionClose)}</span>
      </Row>
      <Row label="Offered" note="Tokens the vault put up for calls this week.">
        {fmtTokens(a.offeredQty, v.stock.decimals)} {v.symbol}
      </Row>
      {a.state === "CLEARED" ? (
        <>
          <Row label="Filled">
            {fmtTokens(a.filledQty, v.stock.decimals)} {v.symbol}
            <span className="k font-normal">{fill !== null ? fmtPct(fill, 0) + " of offered" : ""}</span>
          </Row>
          <Row label="Clearing price" note="Every winning bid pays the same price per token.">
            <span className="pct">{fmtUsd(a.clearingPrice, v.usdg.decimals)}</span>
            <span className="k font-normal">{fmtPct(premium)} of the token price</span>
          </Row>
          <Row label="Premium paid to depositors" note={`After the ${a.feeBps / 100}% protocol fee.`}>
            <span className="pct">{fmtUsd(net, v.usdg.decimals)}</span>
          </Row>
        </>
      ) : a.state === "OPEN" ? (
        <Row label="Reserve floor" note="Bids below this do not count. Set from live volatility.">
          {fmtUsd(a.reservePrice, v.usdg.decimals)} per token
        </Row>
      ) : (
        <Row label="Result">No bid met the floor; the vault keeps its upside and sells it next week.</Row>
      )}
      {se.state === "SETTLED" || se.state === "RESOLVED" ? (
        <>
          <Row label="Settlement price">{fmtPrice8(se.settlementPrice)}</Row>
          <Row label="Paid out at settlement">
            {fmtPct(Number(BigInt(se.payoutPerOption)) / 1e18)} of each written token
          </Row>
        </>
      ) : null}
    </Rows>
  );
}
