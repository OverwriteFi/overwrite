# @overwrite/mm-sdk

A small viem client for market makers. Five things: post the bond, read the open auction, bid, claim options, claim payout. Plus refunds, lock release, and a testnet USDG mint.

```bash
cd docs/mm-kit/sdk
npm install
cp .env.example .env        # testnet key only
npm run typecheck
npm run example             # mints test USDG, posts the bond, bids if an auction is open
```

## Usage

```ts
import { privateKeyToAccount } from "viem/accounts";
import { OverwriteClient, options, usdg, strategies } from "./src/index.js";

const client = new OverwriteClient({
  rpcUrl: "https://rpc.testnet.chain.robinhood.com",
  chainId: 46630,
  account: privateKeyToAccount(process.env.MM_PRIVATE_KEY as `0x${string}`),
});

await client.postBond();                              // approve + postBond(MM); no-op if already bonded

const a = await client.auction("NVDA");               // latest series for the vault
if (a.state === "OPEN" && a.secondsLeft > 0) {
  await client.bid(a.seriesId, options(10), usdg("2.10"));   // 10 options at 2.10 USDG each, escrow 21 USDG

  const ladder = strategies.valueLadder(a, { totalQty: options(60), sigma: 0.55 });
  await client.bidLadder(a.seriesId, ladder);
}

console.log(await client.book(a.seriesId));           // every bid, sorted the way clear sorts them
console.log(await client.previewClear(a.seriesId));   // exact result if clear ran now

// after clear
await client.withdrawRefund();                        // escrow you did not pay
await client.claimOptions(a.seriesId);                // optional: mint the ERC-1155 to hedge or transfer

// after settlement
await client.claimPayout(a.seriesId);                 // unminted allocation → Stock Tokens in one tx
await client.settleUp(a.seriesId);                    // or: payout + token claim + refund + releaseLocks
```

Every write is `simulateContract` first, so a revert throws with the decoded custom error (for example `BelowReserve(price, reserve)` or `NoActiveBond(bidder)`) before any gas is spent.

## Files

| File | |
|---|---|
| `src/client.ts` | `OverwriteClient`: bond, auctions, book, bid, claims, refunds, locks |
| `src/strategies.ts` | Five sample strategies with the reasoning in comments: value ladder, reserve sweep, book-aware top-up, delta-sized bid, last-look |
| `src/abi.ts` | Human-readable ABIs for the MM-facing surface |
| `src/addresses.ts` | 46630 address book and viem chain definitions |
| `src/units.ts` | 1e18 / 1e6 / 1e8 conversions, `escrowFor`, `payoutPerOption` |
| `src/example.ts` | End-to-end testnet script |

## Signing

`account` is any viem `Account`: `privateKeyToAccount` for a throwaway testnet key, or a hardware-wallet account via your preferred connector for production. The SDK never reads a key itself.

## Production notes

- Use a provider RPC (Alchemy, QuickNode, dRPC all list Robinhood Chain). The public RPC is rate-limited and keeps ~19 minutes of state, so `getLogs` over history fails.
- `bidLadder` sends tranches sequentially to keep nonces ordered. With ~100 ms blocks, eight tranches land in a couple of seconds.
- Add the mainnet deployment to `addresses.ts` when it ships; nothing else changes.
