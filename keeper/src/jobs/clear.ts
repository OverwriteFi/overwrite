import type { Address, PublicClient } from "viem";
import { auctionHouseAbi, feeRouterAbi, vaultAbi } from "../abi/index.js";
import type { Sender, SendResult } from "../chain/tx.js";
import type { Logger } from "../logger.js";
import type { VaultSnapshot } from "../protocol.js";

/**
 * The permissionless half of the lifecycle: `clear`, the queue processors, `releaseLocks` and
 * `feeRouter.flush`.
 *
 * None of these needs a role — anyone may call them, and SPEC §3 lists the keeper as the party that
 * does. They are on the keeper's allowlist because somebody has to run them for the protocol to be
 * live, not because the key is entitled to anything by making them.
 */

export async function clearAuction(args: {
  client: PublicClient;
  sender: Sender;
  auctionHouse: Address;
  snapshot: VaultSnapshot;
  seriesId: bigint;
  log: Logger;
}): Promise<{ result: SendResult; willSkip: boolean }> {
  const { client, sender, auctionHouse, snapshot, seriesId, log } = args;

  const [clearingPrice, filledQty, premiumGross, willSkip] = await client.readContract({
    address: auctionHouse,
    abi: auctionHouseAbi,
    functionName: "previewClear",
    args: [seriesId],
  });

  // A skip is a legitimate outcome (SPEC §8.2 step 8) — no bid reached the reserve, the vault returns
  // to IDLE and nothing is sold. Worth an explicit line because it is also what a mispriced reserve
  // looks like, and the two are told apart by the reserve's `coverRatio`, not by this event.
  if (willSkip) {
    log.warn(
      {
        vault: snapshot.symbol,
        seriesId: seriesId.toString(),
        reservePrice: snapshot.auction?.reservePrice.toString(),
      },
      "clearing will SKIP: no bid at or above the reserve",
    );
  } else {
    log.info(
      {
        vault: snapshot.symbol,
        seriesId: seriesId.toString(),
        clearingPrice: clearingPrice.toString(),
        filledQty: filledQty.toString(),
        premiumGross: premiumGross.toString(),
      },
      "clearing auction",
    );
  }

  const result = await sender.send({
    address: auctionHouse,
    abi: auctionHouseAbi,
    functionName: "clear",
    args: [seriesId],
    label: `clear ${snapshot.symbol} #${seriesId}`,
  });
  return { result, willSkip };
}

export async function processQueues(args: {
  sender: Sender;
  snapshot: VaultSnapshot;
  opsPerCall: number;
  log: Logger;
}): Promise<SendResult[]> {
  const { sender, snapshot, opsPerCall, log } = args;
  const out: SendResult[] = [];
  const n = BigInt(opsPerCall);

  if (snapshot.queue.deposits > 0n) {
    log.info(
      { vault: snapshot.symbol, pending: snapshot.queue.deposits.toString() },
      "processing queued deposits",
    );
    out.push(
      await sender.send({
        address: snapshot.addresses.vault,
        abi: vaultAbi,
        functionName: "processDeposits",
        args: [n],
        label: `processDeposits ${snapshot.symbol}`,
      }),
    );
  }
  if (snapshot.queue.redeems > 0n) {
    log.info(
      { vault: snapshot.symbol, pending: snapshot.queue.redeems.toString() },
      "processing queued redeems",
    );
    out.push(
      await sender.send({
        address: snapshot.addresses.vault,
        abi: vaultAbi,
        functionName: "processRedeems",
        args: [n],
        label: `processRedeems ${snapshot.symbol}`,
      }),
    );
  }
  return out;
}

/** Releases MM bond locks once the series is SETTLED or RESOLVED (SPEC §8.1). Permissionless. */
export async function releaseLocks(args: {
  sender: Sender;
  auctionHouse: Address;
  snapshot: VaultSnapshot;
  seriesId: bigint;
}): Promise<SendResult> {
  return args.sender.send({
    address: args.auctionHouse,
    abi: auctionHouseAbi,
    functionName: "releaseLocks",
    args: [args.seriesId],
    label: `releaseLocks ${args.snapshot.symbol} #${args.seriesId}`,
  });
}

/** Moves booked fees from the AuctionHouse to the treasury (SPEC §11, D-049). Permissionless. */
export async function flushFees(args: {
  client: PublicClient;
  sender: Sender;
  feeRouter: Address;
  snapshot: VaultSnapshot;
  log: Logger;
}): Promise<SendResult | null> {
  const pending = await args.client.readContract({
    address: args.feeRouter,
    abi: feeRouterAbi,
    functionName: "pending",
    args: [args.snapshot.addresses.vault],
  });
  if (pending === 0n) return null;

  args.log.info(
    { vault: args.snapshot.symbol, pending: pending.toString() },
    "flushing fees to the treasury",
  );
  return args.sender.send({
    address: args.feeRouter,
    abi: feeRouterAbi,
    functionName: "flush",
    args: [args.snapshot.addresses.vault],
    label: `flush ${args.snapshot.symbol}`,
  });
}
