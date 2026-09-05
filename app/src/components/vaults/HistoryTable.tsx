import { Empty } from "@/components/site/States";
import { fmtBps, fmtDateShort, fmtPct, fmtPrice8, fmtUsd } from "@/lib/format";
import type { SeriesRowDto, VaultSnapshotDto } from "@/lib/reads/types";
import { OUTCOME_LABEL, OUTCOME_SENTENCE } from "./status";

const settled = (r: SeriesRowDto) =>
  r.outcome === "expired-worthless" || r.outcome === "called-away" || r.outcome === "resolved" || r.outcome === "skipped";

export function HistoryTable({ v, rows }: { v: VaultSnapshotDto; rows: SeriesRowDto[] }) {
  const done = rows.filter(settled);
  if (done.length === 0) {
    return (
      <Empty title="No settled series yet.">
        Every series that settles lands here with its outcome: what the price did against the cap and
        what you were paid.
      </Empty>
    );
  }
  return (
    <div className="scroll-x">
      <table className="tbl min-w-[760px]">
        <caption>Newest first. Outcomes are read from the vault&apos;s own settlement records.</caption>
        <thead>
          <tr>
            <th scope="col">Series</th>
            <th scope="col">Expired</th>
            <th scope="col" className="num">Cap</th>
            <th scope="col" className="num">Settled at</th>
            <th scope="col" className="num">Premium</th>
            <th scope="col">Outcome</th>
          </tr>
        </thead>
        <tbody>
          {done.map((r) => {
            const se = r.series;
            const price = se && BigInt(se.settlementPrice) > 0n ? fmtPrice8(se.settlementPrice) : "—";
            return (
              <tr key={r.id}>
                <td>
                  <b>#{r.id}</b>
                  <span className="k">{r.kind === 0 ? "Weekday" : "Weekend"}</span>
                </td>
                <td>{fmtDateShort(r.auction.expiry)}</td>
                <td className="num">
                  {fmtPrice8(r.auction.strike)}
                  <span className="k font-normal">{fmtBps(r.strikeDistanceBps)}</span>
                </td>
                <td className="num">{price}</td>
                <td className="num">
                  {r.premiumFraction !== null ? (
                    <>
                      <span className="pct">{fmtPct(r.premiumFraction)}</span>
                      <span className="k font-normal">{fmtUsd(r.premiumNet, v.usdg.decimals)} net</span>
                    </>
                  ) : (
                    "—"
                  )}
                </td>
                <td>
                  <b>{OUTCOME_LABEL[r.outcome]}</b>
                  <span className="k">
                    {r.outcome === "called-away" && r.payoutFraction !== null
                      ? `${fmtPct(r.payoutFraction)} of each written token paid out. `
                      : ""}
                    {OUTCOME_SENTENCE[r.outcome]}
                  </span>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function PremiumHistory({ v, rows }: { v: VaultSnapshotDto; rows: SeriesRowDto[] }) {
  const cleared = rows.filter((r) => r.auction.state === "CLEARED");
  if (cleared.length === 0) {
    return (
      <Empty title="No auction has cleared yet.">
        Premium shows up here the moment the first auction clears, with the clearing price market
        makers paid and what reached depositors after the fee.
      </Empty>
    );
  }
  const totalNet = cleared.reduce((n, r) => n + BigInt(r.premiumNet), 0n);
  return (
    <div className="scroll-x">
      <table className="tbl min-w-[720px]">
        <caption>
          {cleared.length} cleared auction{cleared.length === 1 ? "" : "s"} ·{" "}
          {fmtUsd(totalNet, v.usdg.decimals)} paid to depositors in total.
        </caption>
        <thead>
          <tr>
            <th scope="col">Series</th>
            <th scope="col">Cleared</th>
            <th scope="col" className="num">Clearing price</th>
            <th scope="col" className="num">Of token price</th>
            <th scope="col" className="num">Filled</th>
            <th scope="col" className="num">To depositors</th>
            <th scope="col" className="num">Fee</th>
          </tr>
        </thead>
        <tbody>
          {cleared.map((r) => (
            <tr key={r.id}>
              <td>
                <b>#{r.id}</b>
                <span className="k">{r.kind === 0 ? "Weekday" : "Weekend"}</span>
              </td>
              <td>{fmtDateShort(r.auction.auctionClose)}</td>
              <td className="num">{fmtUsd(r.auction.clearingPrice, v.usdg.decimals)}</td>
              <td className="num pct">{fmtPct(r.premiumFraction)}</td>
              <td className="num">{r.fillFraction !== null ? fmtPct(r.fillFraction, 0) : "—"}</td>
              <td className="num font-bold">{fmtUsd(r.premiumNet, v.usdg.decimals)}</td>
              <td className="num">{fmtUsd(r.auction.fee, v.usdg.decimals)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
