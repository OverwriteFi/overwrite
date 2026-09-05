import Link from "next/link";
import { pctText, weekPremium } from "@/lib/pricing/landing-model";
import type { CalcVaultDto } from "@/lib/reads/types";

/** The vault ledger: model figures at each vault's cap, the last auction's figure where one exists. */
export function Ledger({ vaults }: { vaults: CalcVaultDto[] }) {
  return (
    <table className="ledger">
      <caption>Premium figures are model estimates at the default caps. Live figures come from the last auction.</caption>
      <thead>
        <tr>
          <th scope="col">Vault</th>
          <th scope="col">Est. weekly premium</th>
          <th scope="col">Annualised</th>
          <th scope="col">Caps, weekday / weekend</th>
          <th scope="col">Deposits</th>
          <th scope="col"></th>
        </tr>
      </thead>
      <tbody>
        {vaults.map((v) => {
          const wk = v.capBps.weekday / 100;
          const weekend = v.capBps.weekend / 100;
          const p = weekPremium(v.volBps / 10_000, wk, null, weekend);
          const used = v.capUsedFraction !== null ? Math.max(0, Math.min(100, Math.round(v.capUsedFraction * 100))) : null;
          return (
            <tr key={v.symbol} data-t={v.symbol}>
              <td>
                <span className="sym">{v.symbol}</span>
                <span className="name">{v.name}</span>
              </td>
              <td className="pct">
                {v.lastAuction ? (
                  <>
                    {pctText(v.lastAuction.fraction)}
                    <span className="src">last auction</span>
                  </>
                ) : (
                  pctText(p.total)
                )}
              </td>
              <td className="apr">{pctText(p.total * 52, 0)}</td>
              <td className="capv">
                +{wk % 1 === 0 ? wk : wk.toFixed(2)}% / +{weekend % 1 === 0 ? weekend : weekend.toFixed(2)}%
              </td>
              <td>
                {used !== null ? (
                  <span className="cap">
                    <i style={{ "--w": `${used}%` } as React.CSSProperties} />
                    {used}% of cap
                  </span>
                ) : (
                  <span className="cap">—</span>
                )}
              </td>
              <td className="act">
                {v.href ? (
                  <Link href={v.href}>Deposit</Link>
                ) : (
                  <a className="soon" aria-disabled="true">
                    Soon
                  </a>
                )}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
