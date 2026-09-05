import type { Outcome, VaultStatus } from "@/lib/reads/types";

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
  skipped: "No bid met the floor, so the vault kept its upside and sells it next week.",
  halted: "Settlement is waiting for a valid price. A permissionless path opens after seven days.",
  resolved: "Settled on a resolved price. You kept every token and the premium.",
};
