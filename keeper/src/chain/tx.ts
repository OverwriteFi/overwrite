import type { Abi, Address, Hex, PublicClient, TransactionReceipt, WalletClient } from "viem";
import type { PrivateKeyAccount } from "viem/accounts";
import type { Deployment } from "../deployment.js";
import type { Logger } from "../logger.js";
import { describeError, isRetryable, type DecodedRevert } from "./errors.js";

/**
 * The only place in the keeper that signs anything.
 *
 * Two guarantees live here, and nowhere else:
 *
 *  1. **Allowlist.** A send is refused unless its (address, function) pair is one this instance is
 *     supposed to make. The address side is resolved from the deploy's own address book, so a typo in
 *     config cannot aim a call at an arbitrary contract, and the function side is the literal list from
 *     SPEC §3. The keeper's key holds `KEEPER_ROLE` and nothing else; everything on the list bar
 *     `openAuction` is permissionless anyway, so the list is about blast radius, not privilege.
 *
 *  2. **Simulate before send.** Every transaction is `simulateContract`-ed with the keeper as `account`
 *     first. A revert there is decoded and returned; it is never broadcast. `DRY_RUN` stops after this
 *     step, which makes a dry run a real end-to-end exercise of the decision logic rather than a
 *     pretend one.
 */

export type ContractKind =
  | "auctionHouse"
  | "settlementOracle"
  | "vault"
  | "feeRouter"
  | "riskModule"
  | "mockFeed"
  | "mockPool";

/**
 * The 46630 mock externals, admitted only by `buildKeeperAllowTable` with `testnetUpkeep` on **and**
 * the address book's chain id equal to 46630. On mainnet these addresses are real Chainlink proxies and
 * real pools; neither has a `setRound` or a `write`, and the keeper must never try.
 */
const TESTNET_UPKEEP_CALLS: Record<"mockFeed" | "mockPool", readonly string[]> = {
  mockFeed: ["setRound"],
  mockPool: ["write"],
};
export const TESTNET_UPKEEP_CHAIN_ID = 46630;

/** SPEC §3's keeper call graph, minus the things the keeper must never do. */
const FULL_ROLE: Record<
  Exclude<ContractKind, "riskModule" | "mockFeed" | "mockPool">,
  readonly string[]
> = {
  auctionHouse: ["openAuction", "clear", "releaseLocks"],
  settlementOracle: ["settle", "halt", "resolveHaltedByOracle"],
  vault: ["processDeposits", "processRedeems"],
  feeRouter: ["flush"],
};

/** THREAT-MODEL RS-04's second instance: liveness for settlement, no authority of any kind. */
const SETTLE_ONLY_ROLE: Partial<Record<ContractKind, readonly string[]>> = {
  settlementOracle: ["settle", "halt", "resolveHaltedByOracle"],
};

/** The guardian key can pause and unpause. It can do nothing else, by construction. */
const GUARDIAN_ROLE_CALLS: readonly string[] = [
  "pauseDeposits",
  "pauseNewAuctions",
  "unpauseDeposits",
  "unpauseNewAuctions",
];

export interface AllowEntry {
  kind: ContractKind;
  label: string;
  functions: ReadonlySet<string>;
}

export type AllowTable = ReadonlyMap<string, AllowEntry>;

const key = (a: Address): string => a.toLowerCase();

export function buildKeeperAllowTable(
  d: Deployment,
  role: "full" | "settle-only",
  opts: { testnetUpkeep?: boolean } = {},
): AllowTable {
  const table = new Map<string, AllowEntry>();
  const calls = role === "full" ? FULL_ROLE : SETTLE_ONLY_ROLE;

  const add = (address: Address, kind: ContractKind, label: string) => {
    const fns = calls[kind as keyof typeof calls];
    if (!fns || fns.length === 0) return;
    table.set(key(address), { kind, label, functions: new Set(fns) });
  };

  add(d.core.auctionHouse, "auctionHouse", "AuctionHouse");
  add(d.core.settlementOracle, "settlementOracle", "SettlementOracle");
  add(d.core.feeRouter, "feeRouter", "FeeRouter");
  for (const v of d.vaults) add(v.vault, "vault", `${v.symbol} vault`);

  if (opts.testnetUpkeep) {
    if (d.chainId !== TESTNET_UPKEEP_CHAIN_ID) {
      throw new Error(
        `testnet upkeep requested for chain ${d.chainId}; the mock allowlist exists only for ${TESTNET_UPKEEP_CHAIN_ID}`,
      );
    }
    const mock = (address: Address, kind: "mockFeed" | "mockPool", label: string) =>
      table.set(key(address), { kind, label, functions: new Set(TESTNET_UPKEEP_CALLS[kind]) });
    mock(d.external.usdgUsdFeed, "mockFeed", "USDG/USD feed (mock)");
    for (const v of d.vaults) {
      mock(v.feed, "mockFeed", `${v.symbol} feed (mock)`);
      mock(v.pool, "mockPool", `${v.symbol} pool (mock)`);
    }
  }
  return table;
}

export function buildGuardianAllowTable(d: Deployment): AllowTable {
  return new Map([
    [
      key(d.core.riskModule),
      { kind: "riskModule" as const, label: "RiskModule", functions: new Set(GUARDIAN_ROLE_CALLS) },
    ],
  ]);
}

export interface TxOptions {
  maxAttempts: number;
  backoffBaseMs: number;
  backoffCapMs: number;
  confirmations: number;
}

export interface Sender {
  readonly address: Address;
  readonly dryRun: boolean;
  send(req: SendRequest): Promise<SendResult>;
  simulate(req: SendRequest): Promise<SimulateResult>;
}

export interface SendRequest {
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args: readonly unknown[];
  /** Short description for logs, e.g. `openAuction NVDA WEEKDAY`. */
  label: string;
}

export type SimulateResult =
  { ok: true; result: unknown; request: unknown } | { ok: false; error: DecodedRevert };

export type SendResult =
  | { status: "sent"; hash: Hex; receipt: TransactionReceipt; result: unknown }
  | { status: "dry-run"; result: unknown }
  | { status: "failed"; error: DecodedRevert };

class NotAllowedError extends Error {}

export function createSender(args: {
  publicClient: PublicClient;
  wallet: WalletClient;
  account: PrivateKeyAccount;
  allow: AllowTable;
  options: TxOptions;
  dryRun: boolean;
  log: Logger;
}): Sender {
  const { publicClient, wallet, account, allow, options, dryRun, log } = args;

  const check = (req: SendRequest): AllowEntry => {
    const entry = allow.get(key(req.address));
    if (!entry) {
      throw new NotAllowedError(
        `refusing to call ${req.functionName} at ${req.address}: not a contract this instance may write to`,
      );
    }
    if (!entry.functions.has(req.functionName)) {
      throw new NotAllowedError(
        `refusing to call ${entry.label}.${req.functionName}: not on the allowlist ` +
          `(${[...entry.functions].sort().join(", ")})`,
      );
    }
    return entry;
  };

  async function simulate(req: SendRequest): Promise<SimulateResult> {
    check(req);
    try {
      const sim = await publicClient.simulateContract({
        address: req.address,
        abi: req.abi as Abi,
        functionName: req.functionName,
        args: req.args,
        account,
        value: 0n,
      });
      return { ok: true, result: sim.result, request: sim.request };
    } catch (err) {
      if (err instanceof NotAllowedError) throw err;
      if (isRetryable(err)) throw err; // a transport failure is not a simulation verdict
      return { ok: false, error: describeError(err) };
    }
  }

  async function send(req: SendRequest): Promise<SendResult> {
    const entry = check(req);
    const child = log.child({ call: `${entry.label}.${req.functionName}`, label: req.label });

    return withRetry(options, child, async () => {
      const sim = await simulate(req);
      if (!sim.ok) {
        child.warn(
          { revert: sim.error.text, reasons: sim.error.reasons },
          "simulation reverted; not sending",
        );
        return { status: "failed", error: sim.error };
      }

      if (dryRun) {
        child.info({ result: sim.result }, "dry run: simulated ok, not sending");
        return { status: "dry-run", result: sim.result };
      }

      const request = sim.request as Parameters<typeof wallet.writeContract>[0];
      const hash = await wallet.writeContract(request);
      child.info({ hash }, "sent");
      const receipt = await publicClient.waitForTransactionReceipt({
        hash,
        confirmations: options.confirmations,
      });
      if (receipt.status !== "success") {
        // A tx that simulated cleanly and still reverted means the state moved underneath us.
        const error: DecodedRevert = {
          name: "TransactionReverted",
          args: [hash],
          reasons: [],
          text: `transaction ${hash} reverted on chain after a clean simulation`,
        };
        child.error({ hash, gasUsed: receipt.gasUsed }, error.text);
        return { status: "failed", error };
      }
      child.info({ hash, gasUsed: receipt.gasUsed, block: receipt.blockNumber }, "confirmed");
      return { status: "sent", hash, receipt, result: sim.result };
    });
  }

  return { address: account.address, dryRun, send, simulate };
}

/** Exponential backoff with full jitter, for transport-level failures only. */
export async function withRetry<T>(
  options: TxOptions,
  log: Logger,
  fn: () => Promise<T>,
): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= options.maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (!isRetryable(err) || attempt === options.maxAttempts) break;
      const ceiling = Math.min(options.backoffCapMs, options.backoffBaseMs * 2 ** (attempt - 1));
      const delay = Math.floor(Math.random() * ceiling);
      log.warn(
        { attempt, delay, err: describeError(err).text },
        "retrying after a transport failure",
      );
      await sleep(delay);
    }
  }
  throw lastErr;
}

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
