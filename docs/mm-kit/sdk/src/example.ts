/**
 * End-to-end on testnet: mint USDG, post the bond, wait for an open auction, bid a value ladder, and
 * after settlement collect everything.
 *
 *   cp .env.example .env   # fill MM_PRIVATE_KEY with a throwaway testnet key
 *   npm install && npm run example
 */
import { privateKeyToAccount } from "viem/accounts";
import { OverwriteClient } from "./client.js";
import { fromUsd8, fromUsdg, options, usdg } from "./units.js";
import { valueLadder, describe, fairValue } from "./strategies.js";

const rpcUrl = process.env.RPC_URL ?? "https://rpc.testnet.chain.robinhood.com";
const pk = process.env.MM_PRIVATE_KEY;
if (!pk) throw new Error("set MM_PRIVATE_KEY (testnet only)");

const client = new OverwriteClient({ rpcUrl, chainId: 46630, account: privateKeyToAccount(pk as `0x${string}`) });
const me = client.me;
console.log("MM address", me);

// 1. Funds. Testnet USDG is a mock with an open mint.
if ((await client.usdgBalance()) < usdg(30_000)) {
  console.log("minting 100,000 test USDG");
  await client.mintTestUsdg(usdg(100_000));
}

// 2. Bond: 25,000 USDG, once per address.
const tx = await client.postBond();
console.log(tx ? `bond posted ${tx}` : "bond already active");
console.log("bond", await client.bondStatus());

// 3. Find an open auction (Mon 14:00–14:15 UTC, or Fri ~10 min after NYSE close).
const open = await client.openAuctions();
if (open.length === 0) {
  const nvda = await client.auction("NVDA");
  console.log(`no auction open. NVDA's latest series #${nvda.seriesId} is ${nvda.state}; next window is Monday 14:00 UTC.`);
  process.exit(0);
}
const a = open[0];
console.log(
  `series #${a.seriesId} ${a.kind} on ${a.vault}: sRef ${fromUsd8(a.sRef)} strike ${fromUsd8(a.strike)} ` +
    `offered ${Number(a.offeredQty) / 1e18} reserve ${fromUsdg(a.reservePrice)} closes in ${a.secondsLeft}s`,
);

// 4. Bid. Sigma is your own view; 0.55 is a plausible single-name number, 0.18 for SPY.
const sigma = a.vault === client.vaultAddress("SPY") ? 0.18 : 0.55;
console.log("fair value at sigma", sigma, "=", fairValue(a, sigma).toFixed(4), "USDG per option");
const ladder = valueLadder(a, { totalQty: options(10), sigma, steps: 3 });
console.log("ladder:", describe(ladder));
const hashes = await client.bidLadder(a.seriesId, ladder);
console.log("bids landed", hashes);

// 5. What would clear right now?
console.log("preview", await client.previewClear(a.seriesId));

// 6. Later (after expiry + settle): one call collects payout, refund and releases the bond.
//    await client.settleUp(a.seriesId);
