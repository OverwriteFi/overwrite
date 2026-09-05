"use client";

import Link from "next/link";
import { useState } from "react";
import { pctText, usdText, weekPremium } from "@/lib/pricing/landing-model";
import { fmtDateShort } from "@/lib/format";
import type { CalcVaultDto } from "@/lib/reads/types";
import { PayoffChart } from "./PayoffChart";

/**
 * "What a week could pay". The landing's Black-Scholes model, with each vault's cap and slider range read
 * from the chain (last auction strike, `strikeDistanceBounds`) and the last auction's clearing premium
 * shown next to the estimate once a vault has one.
 */
export function Calculator({ vaults }: { vaults: CalcVaultDto[] }) {
  const [ticker, setTicker] = useState(vaults[0]?.symbol ?? "NVDA");
  const [amt, setAmt] = useState("10000");
  const v = vaults.find((x) => x.symbol === ticker) ?? vaults[0];
  const capPct = Math.round(v.capBps.weekday / 100);
  const [dist, setDist] = useState(capPct);
  const min = v.bounds ? Math.ceil(v.bounds.weekday[0] / 100) : 1;
  const max = v.bounds ? Math.floor(v.bounds.weekday[1] / 100) : 15;
  const d = Math.min(Math.max(dist, min), max);
  // At the vault's own cap the weekend cap is the vault's too; once the slider moves, the 0.6× rule applies.
  const p = weekPremium(
    v.volBps / 10_000,
    d,
    v.bounds ? [v.bounds.weekend[0] / 100, v.bounds.weekend[1] / 100] : null,
    d === capPct ? v.capBps.weekend / 100 : undefined,
  );
  const a = Math.max(0, parseFloat(amt) || 0);

  const pickTicker = (sym: string) => {
    const nv = vaults.find((x) => x.symbol === sym);
    if (!nv) return;
    setTicker(sym);
    setDist(Math.round(nv.capBps.weekday / 100));
  };

  return (
    <div className="calc" id="calc">
      <div className="calc-head">
        <h2>What a week could pay</h2>
        <small>Model estimate from recent volatility. Real premium is set at auction.</small>
      </div>
      <div className="seg" role="group" aria-label="Stock Token">
        {vaults.map((x) => (
          <button key={x.symbol} type="button" aria-pressed={x.symbol === ticker} onClick={() => pickTicker(x.symbol)}>
            {x.symbol}
          </button>
        ))}
      </div>
      <div className="row">
        <div className="field">
          <label htmlFor="amt">Deposit, in USDG</label>
          <input
            id="amt"
            type="number"
            min={100}
            step={100}
            value={amt}
            inputMode="numeric"
            onChange={(e) => setAmt(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor="strike">Upside you keep before the cap</label>
          <div className="val">
            <span id="strikeVal">{d}</span>% above today&apos;s price
          </div>
          <input
            id="strike"
            type="range"
            min={min}
            max={max}
            step={1}
            value={d}
            aria-valuemin={min}
            aria-valuemax={max}
            onChange={(e) => setDist(parseInt(e.target.value, 10))}
          />
        </div>
      </div>
      <div className="out">
        <div>
          <div className="k">Premium this week</div>
          <div className="v" id="oPct">
            {pctText(p.total)}
          </div>
          {v.lastAuction && v.href ? (
            <div className="last">
              <Link href={v.href}>
                Last auction paid {pctText(v.lastAuction.fraction)}
              </Link>{" "}
              · {v.lastAuction.kind === 0 ? "weekday" : "weekend"}, {fmtDateShort(v.lastAuction.closedAt)}
            </div>
          ) : null}
        </div>
        <div>
          <div className="k">In USDG</div>
          <div className="v ink" id="oUsd">
            {usdText(a * p.total)}
          </div>
        </div>
        <div>
          <div className="k">Annualised</div>
          <div className="v" id="oApr">
            {pctText(p.total * 52, 0)}
          </div>
        </div>
      </div>
      <div className="chart" aria-label="Chart comparing holding the token with the vault over one week of price changes">
        <PayoffChart dist={d} prem={p.total} />
      </div>
      <p className="note" id="oNote">
        {ticker} at {(v.volBps / 100).toFixed(0)}% annualised volatility. Weekday series capped at +{d}% pays about{" "}
        {pctText(p.wk)}; weekend series capped at +{p.weDist}% pays about {pctText(p.we)}. Premium is paid up front at
        auction, and you keep every point of upside to +{d}% on top of it.
        {v.capSource === "auction" ? " Caps are the last auction's strikes, read from the chain." : ""}
      </p>
    </div>
  );
}
