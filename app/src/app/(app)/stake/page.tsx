import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Section, Stat, Tag } from "@/components/site/Bits";
import { StakePanel } from "@/components/stake/StakePanel";
import { fmtDateUtc, fmtDays, fmtTokens, fmtUsd, fmtUsdCompact } from "@/lib/format";
import { getStakeOverview, stakeEnabled } from "@/lib/reads/stake";
import { PROTOCOL } from "@/lib/vault-defaults";

export const metadata: Metadata = { title: "Stake" };
export const dynamic = "force-dynamic";

export default async function StakePage() {
  // Feature flag: the page does not exist until the token launches.
  if (!stakeEnabled) notFound();
  const s = await getStakeOverview();
  if (!s.safetyModule) notFound();
  const k = Number(BigInt(s.k)) / 1e18;

  return (
    <div className="wrap pt-12 sm:pt-16">
      <h1 className="h1">Back the vaults. Grow the caps.</h1>
      <p className="lede">
        Staked WRITE is the backstop that covers shortfalls. It also sets the ceiling: vaults may hold
        at most {k}× its value. More WRITE staked, more capacity, more premium written every week.
      </p>

      <div className="mt-10 grid grid-cols-2 lg:grid-cols-4 gap-x-8 gap-y-6">
        <Stat label="Backstop value" value={s.valueOk ? fmtUsdCompact(s.valueUsd) : "—"} sub={s.valueOk ? "at the WRITE oracle price" : "WRITE price unavailable"} />
        <Stat label="WRITE staked" value={fmtTokens(s.totalStaked, 18, 0)} ink />
        <Stat label="Cap multiple" value={`${k}×`} ink sub={`governance sets k in [${PROTOCOL.kMin}, ${PROTOCOL.kMax}]`} />
        <Stat label="Unstake cooldown" value={fmtDays(Number(s.cooldownSeconds))} ink sub={`then ${fmtDays(Number(s.claimWindowSeconds))} to claim`} />
      </div>

      {!s.wired ? (
        <p className="mt-6 border-t-[1.5px] border-blue pt-3 text-[15px] max-w-[80ch]">
          Caps are still fixed at {fmtUsdCompact(s.vaults[0]?.liveCapUsd ?? "0")} per vault. The switch
          to backstop-derived caps is a governance action behind the 48-hour timelock; the table below
          shows what each cap would be today.
          {!s.emissionsWired ? " Staking rewards begin once emissions are pointed at the safety module." : ""}
        </p>
      ) : null}

      <div className="mt-14 grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-x-14 gap-y-12">
        <Section title="Your stake" className="mt-0">
          <StakePanel s={s} />
        </Section>
        <Section title="Caps from the backstop" className="mt-0" sub={`Per vault: ${k}× backstop value × the vault's weight.`}>
          <div className="scroll-x">
            <table className="tbl">
              <thead>
                <tr>
                  <th scope="col">Vault</th>
                  <th scope="col" className="num">Weight</th>
                  <th scope="col" className="num">Cap from backstop</th>
                  <th scope="col" className="num">Cap today</th>
                </tr>
              </thead>
              <tbody>
                {s.vaults.map((v) => (
                  <tr key={v.symbol}>
                    <td><span className="sym">{v.symbol}</span></td>
                    <td className="num">{(v.weightBps / 100).toFixed(1)}%</td>
                    <td className="num pct">{fmtUsd(v.derivedCapUsd, 6, 0)}</td>
                    <td className="num">
                      {fmtUsd(v.liveCapUsd, 6, 0)}
                      <Tag>{s.capMode === "FIXED" ? "fixed" : "backstop"}</Tag>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="note mt-3">
            Weights are set by governance and sum to at most 100%. A vault can also carry a fixed
            ceiling, in which case the lower of the two applies.
          </p>
        </Section>
      </div>

      <Section title="How unstaking works" sub="Request, wait, claim. Cancel any time before you claim.">
        <ol className="list-none m-0 p-0 border-t-[1.5px] border-ink max-w-[70ch]">
          <li className="py-3 border-b border-rule"><b>1. Request.</b> Choose how much to unstake. Those shares stop earning immediately and the cooldown of {fmtDays(Number(s.cooldownSeconds))} starts.</li>
          <li className="py-3 border-b border-rule"><b>2. Wait.</b> The backstop stays whole through the cooldown, so a shortfall in that window is still covered by everyone, including you.</li>
          <li className="py-3 border-b border-rule"><b>3. Claim.</b> A window of {fmtDays(Number(s.claimWindowSeconds))} opens. Claim inside it and the WRITE is yours. Miss it and you request again.</li>
        </ol>
        <p className="note mt-3">
          Slashing, if governance ever calls it, is capped at {s.maxSlashBps / 100}% of the stake per event
          and at most once every {fmtDays(Number(s.slashIntervalSeconds))}. Read at {fmtDateUtc(s.chainNow)}.
        </p>
      </Section>
    </div>
  );
}
