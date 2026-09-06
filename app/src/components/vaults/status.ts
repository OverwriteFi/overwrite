import type { AuctionDto, Outcome, SkipReason, VaultStatus } from "@/lib/reads/types";

export const STATUS_LABEL: Record<VaultStatus, string> = {
  "auction-open": "Auction open",
  clearing: "Clearing",
  active: "Active",
  settling: "Settling",
  halted: "Halted",
  idle: "Next auction",
  sunset: "Sunset",
};

export const STATUS_BLUE: Partial<Record<VaultStatus, boolean>> = {
  "auction-open": true,
  clearing: true,
  settling: true,
};

export const OUTCOME_LABEL: Record<Outcome, string> = {
  "auction-open": "Auction open",
  live: "Live",
  "expired-worthless": "Expired below the cap",
  "called-away": "Called away above the cap",
  skipped: "No auction cleared",
  halted: "Halted, awaiting resolution",
  resolved: "Resolved below the cap",
};

/** One sentence per outcome, in the landing's voice: what the depositor got. */
export const OUTCOME_SENTENCE: Record<Outcome, string> = {
  "auction-open": "Bids are coming in. Premium is escrowed before the auction clears.",
  live: "Premium is already in the vault. The options ride until expiry.",
  "expired-worthless": "You kept every token and the premium.",
  "called-away": "You kept the premium and every point of the move up to the cap; the part above it was paid out in tokens.",
  skipped: "The auction did not clear, so the vault kept its upside and sells it next week.",
  halted: "Settlement is waiting for a valid price. A permissionless path opens after seven days.",
  resolved: "Settled on a resolved price. You kept every token and the premium.",
};

/** Label per skip reason (REHEARSAL-1 S-9): read from chain state, never a fixed sentence. */
export const SKIP_LABEL: Record<SkipReason, string> = {
  "no-bids": "No bid met the floor",
  "late-clear": "Not cleared in time",
  "no-assets": "Nothing to cover",
  "all-shares-escrowed": "Every share queued for withdrawal",
};

export const SKIP_SENTENCE: Record<SkipReason, string> = {
  "no-bids": "No bid met the reserve floor, so the vault kept its upside and sells it next week.",
  "late-clear":
    "Bids were placed, but the auction was not cleared inside its clearing window, so every bid was refunded and the vault kept its upside.",
  "no-assets": "The vault had no tokens to cover the calls when it came to clearing, so every bid was refunded.",
  "all-shares-escrowed":
    "Every share was queued for withdrawal, so there was nobody to pay the premium to; every bid was refunded.",
};

/** The outcome label and sentence for a row, using the on-chain skip reason when there is one. */
export function outcomeText(outcome: Outcome, auction: Pick<AuctionDto, "skipReason">): { label: string; sentence: string } {
  if (outcome === "skipped" && auction.skipReason) {
    return { label: SKIP_LABEL[auction.skipReason], sentence: SKIP_SENTENCE[auction.skipReason] };
  }
  return { label: OUTCOME_LABEL[outcome], sentence: OUTCOME_SENTENCE[outcome] };
}
