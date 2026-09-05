"use client";

import { useState } from "react";
import { moneyText } from "@/lib/pricing/landing-model";
import type { LoopDto } from "@/lib/reads/types";

/** The landing's illustrative loop model, unchanged. */
const STEPS = [250000, 500000, 1000000, 2000000, 5000000, 10000000, 25000000, 50000000, 100000000];
const K = 5,
  UTIL = 0.75,
  WEEKLY = 0.007,
  FEE = 0.1,
  IN_WRITE = 0.6,
  BURN = 0.5,
  MM_PER = 2000000,
  BOND = 50000;

const usd6 = (v: string | null | undefined) => (v ? Number(BigInt(v)) / 1e6 : 0);
const wad = (v: string | null | undefined) => (v ? Number(BigInt(v)) / 1e18 : 0);
const writeText = (tokens: number) => {
  const t = tokens >= 1e6 ? (tokens / 1e6).toFixed(1) + "M" : tokens >= 1e3 ? (tokens / 1e3).toFixed(1) + "k" : Math.round(tokens).toString();
  return t + " WRITE";
};

function Wheel({ seconds }: { seconds: number }) {
  return (
    <svg className="wheel" viewBox="0 0 80 80" aria-hidden="true" style={{ "--spin": `${seconds.toFixed(1)}s` } as React.CSSProperties}>
      <g>
        <circle cx="40" cy="40" r="34" fill="none" stroke="#2A3BFF" strokeWidth="6" />
        <circle cx="40" cy="40" r="7" fill="#2A3BFF" />
        <path d="M40 9v24M40 47v24M9 40h24M47 40h24" stroke="#2A3BFF" strokeWidth="4" strokeLinecap="round" />
      </g>
    </svg>
  );
}

function Model({ onSpin }: { onSpin: (s: number) => void }) {
  const [i, setI] = useState(3);
  const st = STEPS[i];
  const cap = st * K,
    dep = cap * UTIL,
    prem = dep * WEEKLY,
    fee = prem * FEE;
  const burn = fee * IN_WRITE * BURN,
    mms = Math.max(2, Math.round(cap / MM_PER)),
    bond = mms * BOND;
  return (
    <div className="loop">
      <div className="ctl">
        <label htmlFor="stake">WRITE staked in the backstop, at market value</label>
        <div className="val" id="stakeVal">
          {moneyText(st)}
        </div>
        <input
          id="stake"
          type="range"
          min={0}
          max={8}
          step={1}
          value={i}
          aria-valuemin={0}
          aria-valuemax={8}
          onChange={(e) => {
            const n = parseInt(e.target.value, 10);
            setI(n);
            onSpin(Math.max(2.5, 24 / (n + 1)));
          }}
        />
        <div className="ticks">
          <span>$250k</span>
          <span>$100M</span>
        </div>
        <p className="note model-note">Model. Live after launch.</p>
      </div>

      <ol className="stations">
        <li>
          <span className="k">Backstop</span>
          <span className="v" id="lStake">
            {moneyText(st)}
          </span>
          <p>Staked WRITE covers shortfalls. It also sets the ceiling: vaults may hold at most 5 times this.</p>
        </li>
        <li>
          <span className="k">Vault capacity</span>
          <span className="v" id="lCap">
            {moneyText(cap)}
          </span>
          <p>Depositors fill it with Stock Tokens. This model assumes 75% of the cap is used.</p>
        </li>
        <li>
          <span className="k">Premium written each week</span>
          <span className="v" id="lPrem">
            {moneyText(prem)}
          </span>
          <p>At an average 0.7% a week. Depositors keep 90%; the protocol keeps 10% as its fee.</p>
        </li>
        <li>
          <span className="k">WRITE burned and bonded</span>
          <span className="v" id="lBurn">
            {moneyText(burn)}
            <small> a week</small>
          </span>
          <p>
            Fees paid in WRITE get a discount, so most are; half of that WRITE is burned. Market makers each bond $50k of
            WRITE to bid: <b id="lBond">{moneyText(bond)}</b> locked.
          </p>
        </li>
      </ol>

      <div className="ret" aria-hidden="true"></div>
      <p className="ret-label">
        Less supply, more locked, a larger backstop. Next week&apos;s ceiling is higher, and the loop runs again.{" "}
        <b id="lYear">
          About {moneyText(burn * 52)} of WRITE burned a year at this size, with {mms} market makers bonded.
        </b>
      </p>
    </div>
  );
}

function Live({ loop }: { loop: LoopDto }) {
  const sm = usd6(loop.safetyModuleValueUsd);
  const cap = usd6(loop.totalCapUsd);
  const dep = usd6(loop.totalDepositsUsd);
  const prem = usd6(loop.lastWeek.premiumGross);
  const fee = usd6(loop.lastWeek.fee);
  const k = wad(loop.k) || 5;
  const price = loop.writePrice8 ? Number(BigInt(loop.writePrice8)) / 1e8 : null;
  const burned = wad(loop.burned?.amount);
  const bonded = wad(loop.bonded);
  const inUsd = (tokens: number) => (price !== null ? ` (${moneyText(tokens * price)})` : "");
  const kText = k % 1 === 0 ? String(k) : k.toFixed(1);
  return (
    <div className="loop">
      <div className="ctl">
        <label>WRITE staked in the backstop, at market value</label>
        <div className="val" id="stakeVal">
          {loop.safetyModuleValueOk ? moneyText(sm) : "—"}
        </div>
        <p className="note model-note">Live. Read from Robinhood Chain; refreshes every 30 seconds.</p>
      </div>

      <ol className="stations">
        <li>
          <span className="k">Backstop</span>
          <span className="v" id="lStake">
            {loop.safetyModuleValueOk ? moneyText(sm) : "—"}
          </span>
          <p>Staked WRITE covers shortfalls. It also sets the ceiling: vaults may hold at most {kText} times this.</p>
        </li>
        <li>
          <span className="k">Vault capacity</span>
          <span className="v" id="lCap">
            {moneyText(cap)}
          </span>
          <p>
            Depositors fill it with Stock Tokens. <b>{moneyText(dep)}</b> deposited today, {cap > 0 ? Math.round((dep / cap) * 100) : 0}% of
            the cap.
          </p>
        </li>
        <li>
          <span className="k">Premium written last week</span>
          <span className="v" id="lPrem">
            {moneyText(prem)}
          </span>
          <p>
            Across {loop.lastWeek.auctions} cleared {loop.lastWeek.auctions === 1 ? "auction" : "auctions"}. Depositors kept{" "}
            {moneyText(prem - fee)}; the protocol&apos;s fee was <b>{moneyText(fee)}</b>.
          </p>
        </li>
        <li>
          <span className="k">WRITE burned and bonded</span>
          <span className="v" id="lBurn">
            {writeText(burned)}
            <small> burned to date</small>
          </span>
          <p>
            Fees paid in WRITE get a discount; half of that WRITE is burned{inUsd(burned)}. Market makers bond WRITE to bid:{" "}
            <b id="lBond">{writeText(bonded)}</b> locked{inUsd(bonded)}
            {loop.mmBondWrite ? `, ${writeText(wad(loop.mmBondWrite))} each` : ""}.
          </p>
        </li>
      </ol>

      <div className="ret" aria-hidden="true"></div>
      <p className="ret-label">
        Less supply, more locked, a larger backstop. Next week&apos;s ceiling is higher, and the loop runs again.{" "}
        <b id="lYear">
          {writeText(burned)} burned so far
          {loop.burned?.source === "events" ? ", summed from FeeRouter burn events" : ", from the token's supply"}.
        </b>
      </p>
    </div>
  );
}

export function WriteLoop({ loop }: { loop: LoopDto }) {
  const [spin, setSpin] = useState(6);
  const liveSpin = loop.launched ? Math.max(2.5, 24 / (STEPS.findIndex((s) => s >= usd6(loop.safetyModuleValueUsd)) + 1 || 1)) : spin;
  return (
    <>
      <div className="loop-head">
        <div>
          <h2>The WRITE loop.</h2>
          <p className="sub">
            WRITE is the protocol&apos;s token. Every arrow below is a rule in the contracts, not a roadmap.{" "}
            {loop.launched
              ? "The figures are read from the chain."
              : "Move the slider to see how the vaults and the token pull on each other."}
          </p>
        </div>
        <Wheel seconds={liveSpin} />
      </div>
      {loop.launched ? <Live loop={loop} /> : <Model onSpin={setSpin} />}
    </>
  );
}
