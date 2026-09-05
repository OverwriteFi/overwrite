import type { Address, PublicClient } from "viem";
import { settlementOracleAbi } from "../abi/index.js";
import { describeError, type DecodedRevert } from "../chain/errors.js";
import { observationIndexAtOrBefore, readSlot0 } from "./observations.js";
import {
  FeedReader,
  MAX_GARBAGE_SKIP,
  firstAfter,
  isValid,
  lastAtOrBefore,
  lastValidAtOrBefore,
  prevHintFor,
  type Round,
} from "./rounds.js";

/**
 * Building — and classifying the failures of — the `SettlementOracle.Hint`.
 *
 * The port of `SettlementHandler._hint` (test/invariants/SettlementHandler.sol:549-577), which is the
 * repo's own statement of what an honest keeper computes, with two differences that only matter off a
 * test fixture: the handler reads an in-memory array of every round it ever wrote, and we have to find
 * the same rounds by searching the proxy; and the handler cannot fail, while we can.
 *
 * The failure classification is the important part. `previewSettle` does **not** return `ok = false` for
 * a bad hint — `_verifyRefRound` (SettlementOracle.sol:695-701) *reverts* `BadRefRoundHint` or
 * `RefRoundRequired`, and `_path3` reverts `BadAfterRoundHint`. So a hint bug and a policy failure
 * arrive through different channels and must be treated differently: a policy failure is "try the next
 * path, or halt", a hint failure is "the keeper computed the wrong thing, do not retry it identically".
 */

export interface Hint {
  refRoundId: bigint;
  afterRoundId: bigint;
  afterPrevRoundId: bigint;
  obsIndex: number;
}

export const ZERO_HINT: Hint = {
  refRoundId: 0n,
  afterRoundId: 0n,
  afterPrevRoundId: 0n,
  obsIndex: 0,
};

export interface BuiltHint {
  hint: Hint;
  ref: Round | null;
  after: Round | null;
  /**
   * True when no verifiable hint exists at all: the run of zero-answer rounds before expiry is longer
   * than `MAX_GARBAGE_SKIP`, so `_isLastValidAtOrBefore` returns false for every candidate. The only way
   * forward is the §9.6 backstop at `expiry + 7 days`; retrying is pointless and the keeper says so.
   */
  unverifiable: false | "GARBAGE_RUN" | "NO_ROUNDS";
  /** How many round reads this cost, for the RPC-budget log line. */
  reads: number;
}

export async function buildHint(args: {
  client: PublicClient;
  feed: Address;
  pool: Address;
  expiry: bigint;
  /** `vaultConfig(vault).firstRound` — the on-chain proof behind a `refRoundId = 0` claim. */
  firstRound: bigint;
  maxReads?: number;
}): Promise<BuiltHint> {
  const { client, feed, pool, expiry, firstRound } = args;
  const reader = new FeedReader(client, feed, args.maxReads ?? 5_000);

  const ref = await lastValidAtOrBefore(reader, expiry);
  const after = await firstAfter(reader, expiry);
  const afterPrevRoundId = await prevHintFor(reader, after);

  let unverifiable: BuiltHint["unverifiable"] = false;
  if (!ref) {
    // Distinguish "the feed genuinely has nothing at or before expiry" (a legitimate refRoundId = 0,
    // which the contract checks against cfg.firstRound) from "there is something, but every candidate
    // is behind a garbage run longer than the contract will skip".
    const positional = await lastAtOrBefore(reader, expiry);
    if (positional) {
      unverifiable = "GARBAGE_RUN";
    } else {
      const first = await reader.get(firstRound);
      if (first && first.updatedAt <= expiry) unverifiable = "NO_ROUNDS";
    }
  }

  const slot0 = await readSlot0(client, pool);
  const { index } = await observationIndexAtOrBefore(client, pool, expiry, slot0);

  return {
    hint: {
      refRoundId: ref ? ref.id : 0n,
      afterRoundId: after ? after.id : 0n,
      afterPrevRoundId,
      obsIndex: index,
    },
    ref,
    after,
    unverifiable,
    reads: reader.reads,
  };
}

/* ─────────────────────── talking to the preview mirrors ─────────────────────── */

export type PreviewOutcome =
  | { kind: "ok"; price8: bigint; path: number }
  | { kind: "policy"; reason: string }
  | { kind: "hint"; error: DecodedRevert }
  | { kind: "error"; error: DecodedRevert };

/** Custom errors that mean "the hint is wrong", as opposed to "the policy says no". */
const HINT_ERRORS = new Set(["BadRefRoundHint", "RefRoundRequired", "BadAfterRoundHint"]);

function classify(err: unknown): PreviewOutcome {
  const decoded = describeError(err);
  return { kind: HINT_ERRORS.has(decoded.name) ? "hint" : "error", error: decoded };
}

export async function previewSettle(
  client: PublicClient,
  oracle: Address,
  seriesId: bigint,
  hint: Hint,
): Promise<PreviewOutcome> {
  try {
    const [ok, price8, path, reason] = await client.readContract({
      address: oracle,
      abi: settlementOracleAbi,
      functionName: "previewSettle",
      args: [seriesId, hint],
    });
    if (ok) return { kind: "ok", price8, path };
    return { kind: "policy", reason: decodeReason(reason) };
  } catch (err) {
    return classify(err);
  }
}

export async function canHalt(
  client: PublicClient,
  oracle: Address,
  seriesId: bigint,
  hint: Hint,
): Promise<
  | { kind: "ok"; reason: string }
  | { kind: "no"; reason: string }
  | { kind: "hint" | "error"; error: DecodedRevert }
> {
  try {
    const [ok, reason] = await client.readContract({
      address: oracle,
      abi: settlementOracleAbi,
      functionName: "canHalt",
      args: [seriesId, hint],
    });
    return ok
      ? { kind: "ok", reason: decodeReason(reason) }
      : { kind: "no", reason: decodeReason(reason) };
  } catch (err) {
    return classify(err) as never;
  }
}

function decodeReason(reason: `0x${string}`): string {
  let s = "";
  for (let i = 2; i + 1 < reason.length; i += 2) {
    const code = parseInt(reason.slice(i, i + 2), 16);
    if (code === 0) break;
    s += String.fromCharCode(code);
  }
  return s;
}

/* ───────────────── reconstructing the primary path's reason ───────────────── */

/**
 * `previewSettle` returns `e.reasonB` — the *fallback* path's reason — and discards `e.reasonA`
 * (SettlementOracle.sol:352, :439-449). So for a WEEKDAY series the caller learns why the TWAP failed
 * and never why Chainlink did, which is the more interesting half.
 *
 * Path 1 is four comparisons against data the keeper already holds, so it is reconstructed here rather
 * than left blank in the alert. Mirrors `_evaluate`'s weekday arm exactly.
 */
export function weekdayPath1Reason(args: {
  ref: Round | null;
  expiry: bigint;
  weekdayMaxStale: bigint;
  sRef: bigint;
  jumpBps: bigint;
}): string | null {
  const { ref, expiry, weekdayMaxStale, sRef, jumpBps } = args;
  if (!isValid(ref)) return "NO_ROUND";
  if (expiry - ref.updatedAt > weekdayMaxStale) return "STALE";
  if (!jumpOk(ref.answer, sRef, jumpBps)) return "JUMP_GUARD";
  return null; // path 1 should have succeeded
}

/** `_jumpOk`'s plain arm (SettlementOracle.sol:555-564); the multiplier-adjusted arm needs chain state. */
export function jumpOk(price8: bigint, sRef: bigint, jumpBps: bigint): boolean {
  if (sRef === 0n) return false;
  const diff = price8 > sRef ? price8 - sRef : sRef - price8;
  return (diff * 10_000n) / sRef <= jumpBps;
}

export { MAX_GARBAGE_SKIP };
