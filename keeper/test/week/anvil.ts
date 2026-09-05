import {
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  http,
  toHex,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { mnemonicToAccount, privateKeyToAccount } from "viem/accounts";
import { mockAggregatorAbi, mockPoolAbi } from "../../src/abi/index.js";
import { chainWithRpc } from "../../src/chains.js";

/**
 * Anvil helpers for the week simulation.
 *
 * Time is driven with `evm_setNextBlockTimestamp` + `evm_mine`, and writes that need an owner go
 * through `anvil_impersonateAccount` — including the `TimelockController`, which anvil is happy to
 * impersonate even though it is a contract, and which is how the run grants `KEEPER_ROLE` to a local
 * key so the keeper signs for itself exactly as it would in production.
 *
 * The important subtlety is the *stepped* warp. A bare jump to next Friday breaks every oracle at once:
 * `capPrice` has an 80 h bound, `referencePrice` 26 h, `usdgMaxStale` 26 h, and the pool's newest
 * observation must be within 900 s of any TWAP anchor. `contracts/test/DayInTheLife.t.sol:_nextWeek()`
 * solves the same problem the same way — post a round every few hours across the gap — and this is that
 * loop, plus the USDG feed and the pool ring.
 */

export const ANVIL_URL = process.env.ANVIL_URL ?? "http://127.0.0.1:8545";

/**
 * anvil's deterministic accounts, derived rather than pasted.
 *
 * anvil seeds its accounts from the standard Hardhat/Foundry test mnemonic, so deriving them here gives
 * the same four keys without a literal private key anywhere in the repo — which the pre-commit hook
 * rejects on sight, correctly, since it cannot tell a throwaway test key from a real one.
 */
const ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

function anvilAccount(index: number): { address: Address; key: Hex } {
  const account = mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index });
  const privateKey = account.getHdKey().privateKey;
  if (!privateKey) throw new Error(`no private key for anvil account ${index}`);
  return { address: account.address, key: toHex(privateKey) };
}

export const ACCOUNTS = {
  keeper: anvilAccount(0),
  depositor: anvilAccount(1),
  mm1: anvilAccount(2),
  mm2: anvilAccount(3),
} as const;

export const chain = chainWithRpc(46630, ANVIL_URL);
// anvil mines instantly; the default 4 s receipt polling would dominate the run's wall time.
export const publicClient = createPublicClient({
  chain,
  transport: http(ANVIL_URL, { batch: true }),
  pollingInterval: 20,
}) as PublicClient;

export async function rpc<T = unknown>(method: string, params: unknown[] = []): Promise<T> {
  const res = await fetch(ANVIL_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = (await res.json()) as { result?: T; error?: { message: string } };
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result as T;
}

export const now = async (): Promise<bigint> =>
  (await publicClient.getBlock({ blockTag: "latest" })).timestamp;

export async function mine(): Promise<void> {
  await rpc("evm_mine");
}

/** Jumps straight to `ts`. Only safe when nothing oracle-shaped depends on the gap. */
export async function warpRaw(ts: bigint): Promise<void> {
  const current = await now();
  if (ts <= current) return;
  await rpc("evm_setNextBlockTimestamp", [`0x${ts.toString(16)}`]);
  await mine();
}

export async function setBalance(address: Address, wei: bigint): Promise<void> {
  await rpc("anvil_setBalance", [address, `0x${wei.toString(16)}`]);
}

/** Sends a transaction *as* an arbitrary address, contracts included. */
export async function sendAs(
  from: Address,
  call: {
    address: Address;
    abi: Abi | readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
  },
): Promise<Hex> {
  await rpc("anvil_impersonateAccount", [from]);
  try {
    const data = encodeFunctionData({
      abi: call.abi as Abi,
      functionName: call.functionName,
      args: call.args ?? [],
    });
    const hash = await rpc<Hex>("eth_sendTransaction", [
      { from, to: call.address, data, gas: "0x1c9c380" },
    ]);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${call.functionName} reverted (${hash})`);
    return hash;
  } finally {
    await rpc("anvil_stopImpersonatingAccount", [from]);
  }
}

/** Signs with one of the anvil keys, the way the keeper and the market makers do. */
export function walletFor(key: Hex) {
  return createWalletClient({
    chain,
    transport: http(ANVIL_URL),
    account: privateKeyToAccount(key),
  });
}

/* ───────────────────────── oracle upkeep ───────────────────────── */

export interface Feeds {
  stockFeed: Address;
  usdgFeed: Address;
  pool: Address;
  tick: number;
  liquidity: bigint;
}

/**
 * Aggregator rounds must stay **contiguous** within a phase. Real Chainlink aggregators number rounds
 * 1..N with no holes, and the keeper's binary search relies on it — a sparse agg space (the
 * `roundId(1, block.timestamp)` trick some fixtures use) would leave the search converging on the last
 * contiguous round and never seeing the newest one.
 */
export async function nextAgg(feed: Address): Promise<bigint> {
  const latestId = await publicClient.readContract({
    address: feed,
    abi: mockAggregatorAbi,
    functionName: "latestId",
  });
  return (latestId & ((1n << 64n) - 1n)) + 1n;
}

export async function postRound(
  feed: Address,
  answer8: bigint,
  ts: bigint,
  sender: Address,
): Promise<void> {
  const agg = await nextAgg(feed);
  const id = (1n << 64n) | agg;
  await sendAs(sender, {
    address: feed,
    abi: mockAggregatorAbi,
    functionName: "setRound",
    args: [id, answer8, ts],
  });
}

export async function writeObservation(
  pool: Address,
  ts: bigint,
  tick: number,
  liquidity: bigint,
  sender: Address,
): Promise<void> {
  await sendAs(sender, {
    address: pool,
    abi: mockPoolAbi,
    functionName: "write",
    args: [Number(ts), tick, liquidity],
  });
}

/**
 * Warps to `target`, posting a stock round, a USDG round and a pool observation every `stepSeconds`
 * along the way so nothing goes stale across the jump. `priceAt` lets the run drive a moving price,
 * which is what gives the volatility estimator something real to measure by the second auction.
 */
export async function steppedWarp(args: {
  target: bigint;
  feeds: Feeds;
  sender: Address;
  stepSeconds?: bigint;
  priceAt?: (ts: bigint) => bigint;
  onStep?: (ts: bigint) => void;
}): Promise<void> {
  const step = args.stepSeconds ?? 4n * 3600n;
  const price = args.priceAt ?? (() => 200_00000000n);

  // The stock feed goes on every step: `weekdayMaxStale` is 26 h and `REF_MAX_STALE` 26 h, so a 4 h
  // cadence keeps a comfortable margin. USDG and the pool ring only need to stay inside their own
  // budgets — `usdgMaxStale` is also 26 h, and the pool's 900 s rule bites only at a TWAP anchor, which
  // the caller seeds explicitly — so writing those every fourth step keeps the run three times shorter
  // without ever letting anything the keeper reads go stale.
  const SPARSE = 4;
  let t = await now();
  let i = 0;
  while (t + step < args.target) {
    t += step;
    i++;
    await warpRaw(t);
    await postRound(args.feeds.stockFeed, price(t), t, args.sender);
    if (i % SPARSE === 0) {
      await postRound(args.feeds.usdgFeed, 1_00000000n, t, args.sender);
      await writeObservation(
        args.feeds.pool,
        t,
        args.feeds.tick,
        args.feeds.liquidity,
        args.sender,
      );
    }
    args.onStep?.(t);
  }
  await warpRaw(args.target);
  // Always leave both the peg feed and the ring fresh at the destination.
  await postRound(args.feeds.usdgFeed, 1_00000000n, args.target - 60n, args.sender);
}

/**
 * The five-swap window `contracts/test/SettlementBase.t.sol:_seedWindow` uses before any path-2 settle.
 * The offsets are not arbitrary: `minObservationsInWindow = 3` needs three inside the hour, and
 * `MAX_LAST_OBS_AGE = 900` forces the newest within 900 s of the anchor — hence the final 120.
 */
export async function seedTwapWindow(feeds: Feeds, expiry: bigint, sender: Address): Promise<void> {
  for (const offset of [3600n, 2400n, 1200n, 600n, 120n]) {
    await writeObservation(feeds.pool, expiry - offset, feeds.tick, feeds.liquidity, sender);
  }
}
