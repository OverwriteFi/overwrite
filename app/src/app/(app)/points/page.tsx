import type { Metadata } from "next";
import { Section } from "@/components/site/Bits";
import { PointsPanel } from "@/components/points/PointsPanel";
import { getOverview } from "@/lib/reads/overview";
import { epochEnd, readLedger } from "@/lib/reads/points";
import { PROTOCOL } from "@/lib/vault-defaults";

export const metadata: Metadata = { title: "Points" };
export const dynamic = "force-dynamic";

export default async function PointsPage() {
  const [overview, ledger] = await Promise.all([getOverview(), readLedger()]);
  const end = epochEnd(ledger);

  return (
    <div className="wrap pt-12 sm:pt-16">
      <h1 className="h1">Points for showing up first.</h1>
      <p className="lede">
        Every dollar you keep in a vault earns a point a day. Market makers earn on their bonds.
        Points are counted at midnight UTC from the chain itself, nothing to register.
      </p>

      <div className="mt-10">
        <PointsPanel
          vaults={overview.vaults.map((v) => ({
            symbol: v.symbol,
            vault: v.addresses.vault,
            stock: v.addresses.stock,
            assetsPerShare: v.assetsPerShare,
            sRef: v.sRef,
          }))}
          epochEnd={end}
          hasLedger={ledger !== null}
          snapshotAt={ledger?.snapshotAt ?? null}
          chainNow={overview.chainNow}
          fetchedAt={overview.fetchedAt}
        />
      </div>

      <Section title="How points are earned" sub="Read straight from the chain at each snapshot. No sign-up, no referral codes.">
        <div className="scroll-x">
          <table className="tbl">
            <thead>
              <tr>
                <th scope="col">Who</th>
                <th scope="col">Rate</th>
                <th scope="col">Counted how</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td><b>Depositors</b></td>
                <td className="pct">1 point per USD per day</td>
                <td>Your vault shares × the vault&apos;s token value × the Chainlink price at the 00:00 UTC snapshot. Queued deposits count from the moment they execute; queued withdrawals count until they execute.</td>
              </tr>
              <tr>
                <td><b>Market makers</b></td>
                <td className="pct">2 × bond value per day</td>
                <td>USDG bonds at par ({PROTOCOL.mmBondUsd.toLocaleString("en-US")} USDG to bid). A bond in withdrawal cooldown earns nothing.</td>
              </tr>
              <tr>
                <td><b>Stakers</b></td>
                <td>After the token launch</td>
                <td>Safety-module staking points are added once WRITE is live.</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="note mt-3">
          Points are informational until governance decides otherwise. Any distribution runs through
          the on-chain PointsDistributor in Merkle rounds, each with its own claim deadline.
        </p>
      </Section>
    </div>
  );
}
