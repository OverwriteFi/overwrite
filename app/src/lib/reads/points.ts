import "server-only";
import { readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { z } from "zod";

/**
 * Points are computed off-chain (SPEC §16.3, D-013) by the daily snapshot job in points/. Until that
 * job writes a ledger, this reader returns nulls and the page shows an honest empty state.
 *
 * Ledger format (JSON, path from POINTS_LEDGER_PATH):
 * {
 *   "epochEnd": "2026-12-31T00:00:00Z",           // optional, overrides NEXT_PUBLIC_POINTS_EPOCH_END
 *   "snapshotAt": "2026-09-05T00:00:00Z",         // last snapshot
 *   "accounts": { "0xabc…": { "total": 1234.5, "byDay": [{ "day": "2026-09-04", "points": 12.3 }] } }
 * }
 */

const ledgerSchema = z.object({
  epochEnd: z.string().optional(),
  snapshotAt: z.string().optional(),
  accounts: z.record(
    z.string(),
    z.object({
      total: z.number(),
      byDay: z.array(z.object({ day: z.string(), points: z.number() })).default([]),
    }),
  ),
});

export type Ledger = z.infer<typeof ledgerSchema>;

let cache: { at: number; ledger: Ledger | null } | undefined;

export async function readLedger(): Promise<Ledger | null> {
  const p = process.env.POINTS_LEDGER_PATH;
  if (!p) return null;
  if (cache && Date.now() - cache.at < 30_000) return cache.ledger;
  try {
    const full = isAbsolute(p) ? p : resolve(/*turbopackIgnore: true*/ process.cwd(), p);
    const raw = JSON.parse(await readFile(/*turbopackIgnore: true*/ full, "utf8"));
    const parsed = ledgerSchema.safeParse(raw);
    cache = { at: Date.now(), ledger: parsed.success ? parsed.data : null };
  } catch {
    cache = { at: Date.now(), ledger: null };
  }
  return cache.ledger;
}

export function epochEnd(ledger: Ledger | null): string | null {
  return ledger?.epochEnd ?? process.env.NEXT_PUBLIC_POINTS_EPOCH_END ?? null;
}

export async function pointsFor(address: string) {
  const ledger = await readLedger();
  const row = ledger?.accounts[address.toLowerCase()] ?? ledger?.accounts[address] ?? null;
  return {
    hasLedger: ledger !== null,
    snapshotAt: ledger?.snapshotAt ?? null,
    epochEnd: epochEnd(ledger),
    total: row?.total ?? null,
    byDay: row?.byDay ?? [],
  };
}
