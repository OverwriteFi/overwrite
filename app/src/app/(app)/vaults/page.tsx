import type { Metadata } from "next";
import { Suspense } from "react";
import { VaultTable } from "@/components/vaults/VaultTable";
import { Loading } from "@/components/site/States";
import { getOverview } from "@/lib/reads/overview";
import { fmtDateUtc } from "@/lib/format";

export const metadata: Metadata = { title: "Vaults" };
export const dynamic = "force-dynamic";

async function Table() {
  const overview = await getOverview();
  return (
    <>
      <VaultTable overview={overview} />
      <p className="note mt-4">
        Read from Robinhood Chain at {fmtDateUtc(overview.chainNow)}. Figures refresh every 30 seconds.
      </p>
    </>
  );
}

export default function VaultsPage() {
  return (
    <div className="wrap pt-12 sm:pt-16">
      <h1 className="h1">Make your Stock Tokens pay you every week.</h1>
      <p className="lede">
        One vault per Stock Token, fully covered, no leverage. Market makers bid for your upside
        every week and pay premium in USDG up front. Two paydays a week, including the weekend.
      </p>
      <div className="mt-10">
        <Suspense fallback={<Loading label="Reading the vaults…" />}>
          <Table />
        </Suspense>
      </div>
    </div>
  );
}
