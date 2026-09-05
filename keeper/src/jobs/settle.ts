import type { Address, PublicClient } from "viem";
import { settlementOracleAbi, WEEKDAY, kindName } from "../abi/index.js";
import type { Sender, SendResult } from "../chain/tx.js";
import type { Logger } from "../logger.js";
import {
  buildHint,
  canHalt,
  previewSettle,
  weekdayPath1Reason,
  type Hint,
} from "../oracle/hints.js";
import type { VaultSnapshot } from "../protocol.js";

/**
 * The settle / halt / resolve ladder (SPEC §9).
 *
 * The contract makes a sharp distinction the keeper must preserve. A **policy** failure — the price is
 * stale, the pool was quiet, the peg is off — comes back as a `bytes32` reason from `previewSettle` and
 * means "try the next path, or halt". A **hint** failure reverts: `_verifyRefRound` throws
 * `BadRefRoundHint` / `RefRoundRequired` (SettlementOracle.sol:695-701) and `_path3` throws
 * `BadAfterRoundHint`. That is the keeper having computed the wrong thing, and retrying it unchanged is
 * pointless — which is why the two are separated all the way through to the alert.
 *
 * One more asymmetry worth knowing: `previewSettle` returns `e.reasonB`, the *fallback* path's reason,
 * and discards `reasonA` (SettlementOracle.sol:352). For a WEEKDAY series that means the caller is told
 * why the TWAP failed and never why Chainlink did. Path 1's test is four comparisons against data the
 * keeper already has, so it is reconstructed here rather than left blank in the alert.
 */

export type SettleOutcome =
  | { kind: "settled"; path: number; price8: bigint; result: SendResult }
  | { kind: "halted"; reason: string; result: SendResult }
  | { kind: "resolved"; price8: bigint; result: SendResult }
  | { kind: "waiting"; reason: string; detail: string }
  | { kind: "blocked"; reason: string; detail: string; unverifiable?: boolean };

/** Reasons that mean "not yet, by design" rather than "something is wrong". */
const NOT_YET = new Set([
  "GRACE",
  "TWAP_GRACE_OPEN",
  "DEADLINE_OPEN",
  "PATH_AVAILABLE",
  "NOT_EXPIRED",
]);

export async function settleSeries(args: {
  client: PublicClient;
  sender: Sender;
  oracle: Address;
  snapshot: VaultSnapshot;
  seriesId: bigint;
  log: Logger;
}): Promise<SettleOutcome> {
  const { client, sender, oracle, snapshot, seriesId, log } = args;
  const series = snapshot.series;
  if (!series)
    return { kind: "blocked", reason: "NO_SERIES", detail: "vault reports no current series" };

  const built = await buildHint({
    client,
    feed: snapshot.addresses.feed,
    pool: snapshot.addresses.pool,
    expiry: series.expiry,
    firstRound: await firstRoundOf(client, oracle, snapshot.addresses.vault),
  });

  const child = log.child({
    vault: snapshot.symbol,
    seriesId: seriesId.toString(),
    kind: kindName(series.kind),
  });
  child.debug({ hint: fmtHint(built.hint), reads: built.reads }, "hint built");

  if (built.unverifiable === "GARBAGE_RUN") {
    // Every candidate reference round sits behind a run of zero-answer rounds longer than the contract
    // will skip, so `_isLastValidAtOrBefore` is false for *every* hint. There is nothing to retry; the
    // §9.6 backstop at expiry + 7 days is the only way this series ever closes.
    return {
      kind: "blocked",
      unverifiable: true,
      reason: "HINT_UNVERIFIABLE",
      detail:
        `no reference round is verifiable: the run of invalid rounds before expiry is longer than the ` +
        `contract's 32-round skip bound. The 7-day backstop unlocks at ${series.expiry + 604_800n}.`,
    };
  }

  const preview = await previewSettle(client, oracle, seriesId, built.hint);

  if (preview.kind === "ok") {
    child.info({ path: preview.path, price8: preview.price8.toString() }, "settling");
    const result = await sender.send({
      address: oracle,
      abi: settlementOracleAbi,
      functionName: "settle",
      args: [seriesId, built.hint],
      label: `settle ${snapshot.symbol} #${seriesId}`,
    });
    return { kind: "settled", path: preview.path, price8: preview.price8, result };
  }

  if (preview.kind === "hint") {
    return {
      kind: "blocked",
      unverifiable: true,
      reason: "BAD_HINT",
      detail: `${preview.error.text} — the keeper's hint was rejected by the contract, not the policy`,
    };
  }
  if (preview.kind === "error") {
    return { kind: "blocked", reason: "PREVIEW_FAILED", detail: preview.error.text };
  }

  // A policy failure. Reconstruct the primary path's reason, which previewSettle threw away.
  const primary =
    series.kind === WEEKDAY && snapshot.sRef !== null
      ? weekdayPath1Reason({
          ref: built.ref,
          expiry: series.expiry,
          weekdayMaxStale: BigInt(snapshot.params.weekdayMaxStale),
          sRef: snapshot.sRef,
          jumpBps: BigInt(snapshot.params.jumpBps),
        })
      : null;
  const detail = primary
    ? `path1=${primary} path2=${preview.reason}`
    : `fallback=${preview.reason}`;

  const halt = await canHalt(client, oracle, seriesId, built.hint);
  if (halt.kind === "ok") {
    child.warn({ detail, haltReason: halt.reason }, "no settlement path; halting");
    const result = await sender.send({
      address: oracle,
      abi: settlementOracleAbi,
      functionName: "halt",
      args: [seriesId, built.hint],
      label: `halt ${snapshot.symbol} #${seriesId}`,
    });
    return { kind: "halted", reason: halt.reason, result };
  }
  if (halt.kind === "hint") {
    return { kind: "blocked", unverifiable: true, reason: "BAD_HINT", detail: halt.error.text };
  }

  const haltReason = halt.kind === "no" ? halt.reason : "";
  if (NOT_YET.has(preview.reason) || NOT_YET.has(haltReason)) {
    return { kind: "waiting", reason: preview.reason || haltReason, detail };
  }
  return {
    kind: "blocked",
    reason: preview.reason || "NO_PATH",
    detail: `${detail} halt=${haltReason}`,
  };
}

/**
 * `resolveHaltedByOracle` — the permissionless path-5 backstop, available from `expiry + 7 days`
 * (D-033). `resolveHalted` (path 4) is timelock-only and deliberately absent from the keeper's
 * allowlist: the keeper reports that a human resolution is needed, it never proposes one.
 */
export async function resolveIfPossible(args: {
  client: PublicClient;
  sender: Sender;
  oracle: Address;
  snapshot: VaultSnapshot;
  seriesId: bigint;
  log: Logger;
}): Promise<SettleOutcome> {
  const { client, sender, oracle, snapshot, seriesId, log } = args;
  const series = snapshot.series;
  if (!series) return { kind: "blocked", reason: "NO_SERIES", detail: "" };

  const [ok, unlockAt] = await client.readContract({
    address: oracle,
    abi: settlementOracleAbi,
    functionName: "canResolveByOracle",
    args: [seriesId],
  });

  if (!ok) {
    return {
      kind: "waiting",
      reason: "RESOLVE_LOCKED",
      detail: `permissionless resolution unlocks at ${unlockAt}; until then only the timelock can resolve`,
    };
  }

  const built = await buildHint({
    client,
    feed: snapshot.addresses.feed,
    pool: snapshot.addresses.pool,
    expiry: series.expiry,
    firstRound: await firstRoundOf(client, oracle, snapshot.addresses.vault),
  });
  if (!built.after) {
    return {
      kind: "waiting",
      reason: "NO_ROUND_AFTER_EXPIRY",
      detail: "no Chainlink round after expiry yet",
    };
  }

  const [previewOk, price8] = await client.readContract({
    address: oracle,
    abi: settlementOracleAbi,
    functionName: "previewResolveByOracle",
    args: [seriesId, built.hint.afterRoundId, built.hint.afterPrevRoundId],
  });

  if (!previewOk) {
    return {
      kind: "blocked",
      reason: "RESOLVE_PREVIEW_FAILED",
      detail: `roundId ${built.hint.afterRoundId}`,
    };
  }

  log.warn(
    { vault: snapshot.symbol, seriesId: seriesId.toString(), price8: price8.toString() },
    "resolving by oracle",
  );
  const result = await sender.send({
    address: oracle,
    abi: settlementOracleAbi,
    functionName: "resolveHaltedByOracle",
    args: [seriesId, built.hint.afterRoundId, built.hint.afterPrevRoundId],
    label: `resolveHaltedByOracle ${snapshot.symbol} #${seriesId}`,
  });
  return { kind: "resolved", price8, result };
}

const firstRoundCache = new Map<string, bigint>();

async function firstRoundOf(
  client: PublicClient,
  oracle: Address,
  vault: Address,
): Promise<bigint> {
  const hit = firstRoundCache.get(vault);
  if (hit !== undefined) return hit;
  const cfg = (await client.readContract({
    address: oracle,
    abi: settlementOracleAbi,
    functionName: "vaultConfig",
    args: [vault],
  })) as { firstRound: bigint };
  firstRoundCache.set(vault, cfg.firstRound);
  return cfg.firstRound;
}

const fmtHint = (h: Hint) => ({
  refRoundId: h.refRoundId.toString(),
  afterRoundId: h.afterRoundId.toString(),
  afterPrevRoundId: h.afterPrevRoundId.toString(),
  obsIndex: h.obsIndex,
});
