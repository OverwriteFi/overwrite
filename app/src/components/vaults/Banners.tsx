import { fmtDateUtc } from "@/lib/format";
import type { VaultSnapshotDto } from "@/lib/reads/types";

/** Factual status lines the SPEC asks the frontend to show (§10, §16.2). Not a risk section. */
export function Banners({ v, chainNow }: { v: VaultSnapshotDto; chainNow: string }) {
  const now = BigInt(chainNow);
  const eff = BigInt(v.stock.effectiveAt);
  const pending = eff > now;
  const items: string[] = [];
  if (pending) {
    items.push(
      `${v.symbol} has a corporate action scheduled: its shares-per-token multiplier changes from ${(Number(BigInt(v.stock.uiMultiplier)) / 1e18).toFixed(4)} to ${(Number(BigInt(v.stock.newUIMultiplier)) / 1e18).toFixed(4)} at ${fmtDateUtc(v.stock.effectiveAt)}. Raw balances never change; the shares-equivalent figures will.`,
    );
  }
  if (v.stock.oraclePaused) items.push(`The ${v.symbol} price feed is paused by the issuer. Auctions wait until it resumes.`);
  if (v.depositsPaused) items.push("Deposits are paused by the guardian. Withdrawals are unaffected.");
  if (v.auctionsPaused) items.push("New auctions are paused by the guardian. The current series settles normally.");
  if (v.sunset) items.push("This vault is sunset: no new series will open and withdrawals stay open.");
  if (items.length === 0) return null;
  return (
    <ul className="mt-6 list-none m-0 p-0 border-t-[1.5px] border-blue">
      {items.map((t) => (
        <li key={t} className="py-3 border-b border-rule text-[15px] max-w-[80ch]">
          {t}
        </li>
      ))}
    </ul>
  );
}
