import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import type { Address, Hex } from "viem";

/**
 * On-disk state.
 *
 * **Authoritative for nothing about the protocol.** Every decision the keeper makes is derived from
 * chain state each tick, and every action is gated by a simulation, so deleting this directory loses no
 * correctness — the contract refuses a second `openAuction` with `NOT_IDLE`, a second `clear` with
 * `WrongAuctionState`, a second `settle` with `NOT_LIVE`. That is the design, and it is why there is no
 * "what did I do last week" ledger here.
 *
 * It is authoritative for exactly three things chain state cannot answer:
 *
 *  1. **In-flight transaction recovery.** A tx broadcast whose receipt was never seen is invisible to
 *     `latest`, so on restart a naive re-derive would simulate cleanly, reuse the same nonce and collide
 *     with its own pending transaction. The record is written *before* the send.
 *  2. **Single-instance enforcement.** Two keepers sharing one key interleave nonces on every
 *     permissionless call. A heartbeat lock makes that a refusal to start rather than a mystery.
 *  3. **The volatility audit trail.** The reserve is the one keeper input the contract cannot verify
 *     (SPEC §8.3), so the rounds behind each estimate are kept to reconstruct, after the fact, why a
 *     given week's auction opened at the price it did.
 */

export interface InflightRecord {
  action: string;
  label: string;
  address: Address;
  functionName: string;
  nonce: number;
  hash: Hex | null;
  sentAt: number;
}

export interface LockInfo {
  pid: number;
  startedAt: number;
  heartbeatAt: number;
  keeper: Address;
}

export class StateDir {
  constructor(readonly dir: string) {
    mkdirSync(dir, { recursive: true });
  }

  private path(name: string): string {
    return join(this.dir, name);
  }

  /**
   * Atomic write. The temp file goes in the **same directory** as the target, not `/tmp`: a container
   * with a read-only rootfs gives `EROFS`, and one with a `tmpfs` gives `EXDEV` on the rename because
   * the two paths are on different filesystems.
   */
  writeAtomic(name: string, contents: string): void {
    const target = this.path(name);
    mkdirSync(dirname(target), { recursive: true });
    const tmp = `${target}.${process.pid}.${Math.random().toString(36).slice(2, 8)}.tmp`;
    writeFileSync(tmp, contents, "utf8");
    renameSync(tmp, target);
  }

  readJson<T>(name: string): T | null {
    const p = this.path(name);
    if (!existsSync(p)) return null;
    try {
      return JSON.parse(readFileSync(p, "utf8")) as T;
    } catch {
      return null;
    }
  }

  writeJson(name: string, value: unknown): void {
    this.writeAtomic(name, `${JSON.stringify(value, jsonBigint, 2)}\n`);
  }

  remove(name: string): void {
    rmSync(this.path(name), { force: true });
  }

  /* ── in-flight ── */

  inflightAll(): Record<string, InflightRecord> {
    return this.readJson<Record<string, InflightRecord>>("inflight.json") ?? {};
  }

  inflightPut(keyName: string, rec: InflightRecord): void {
    const all = this.inflightAll();
    all[keyName] = rec;
    this.writeJson("inflight.json", all);
  }

  inflightClear(keyName: string): void {
    const all = this.inflightAll();
    if (keyName in all) {
      delete all[keyName];
      this.writeJson("inflight.json", all);
    }
  }

  /* ── single-instance lock ── */

  /**
   * Refuses to start when another process heartbeated recently. `O_EXCL` is the primitive rather than
   * `flock` because it behaves the same on a bind-mounted volume, which is how the Docker deployment
   * shares this directory.
   */
  acquireLock(keeper: Address, staleAfterMs: number): LockInfo {
    const p = this.path("keeper.lock");
    const existing = this.readJson<LockInfo>("keeper.lock");
    if (existing && Date.now() - existing.heartbeatAt < staleAfterMs) {
      throw new Error(
        `another keeper is running (pid ${existing.pid}, last heartbeat ` +
          `${Math.round((Date.now() - existing.heartbeatAt) / 1000)}s ago). Two instances sharing one key ` +
          `interleave nonces on every permissionless call. Stop it first, or point STATE_DIR elsewhere.`,
      );
    }
    const info: LockInfo = {
      pid: process.pid,
      startedAt: Date.now(),
      heartbeatAt: Date.now(),
      keeper,
    };
    if (!existing) {
      // Best-effort exclusive create; a lost race falls through to the heartbeat check above.
      try {
        closeSync(openSync(p, "wx"));
      } catch {
        /* already there — the staleness check above governs */
      }
    }
    this.writeJson("keeper.lock", info);
    return info;
  }

  heartbeat(info: LockInfo): void {
    this.writeJson("keeper.lock", { ...info, heartbeatAt: Date.now() });
  }

  releaseLock(): void {
    this.remove("keeper.lock");
  }
}

/** `JSON.stringify` replacer: bigint is pervasive here and would otherwise throw. */
export function jsonBigint(_key: string, value: unknown): unknown {
  return typeof value === "bigint" ? value.toString() : value;
}
