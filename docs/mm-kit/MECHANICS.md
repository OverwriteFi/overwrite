# Overwrite auctions and settlement, on one page

For market makers. Every statement here is contract behaviour, not policy; the section numbers point at [SPEC.md](../SPEC.md).

## 1. What is being sold

One option = a European call on **one Stock Token** (1e18 raw units), physically collateralised, expiring at a fixed timestamp, cash-settled **in the Stock Token** (§7.1). Two series a week per vault:

| Series | Auction opens | Duration | Expiry | Strike distance (bps of reference) |
|---|---|---|---|---|
| WEEKDAY | Monday 14:00 UTC (±2 h tolerance) | 15 min | Friday 16:00 ET (20:00 or 21:00 UTC) | 300–1500 |
| WEEKEND | Friday, 10 min after weekday expiry | 15 min | Sunday 23:59:00 UTC | 100–1000 |

The strike is `S_ref × (1 + distance)` rounded **up** to a 0.25 % grid of `S_ref` (§7.2). `S_ref` is read on-chain from the vault's Chainlink feed at open; the keeper cannot supply it. Expiry timestamps never move for NYSE holidays or early closes.

Offered quantity is 100 % of the vault's unencumbered balance net of queued redeems (D-009), so the vault can never write more calls than tokens it holds (invariant I-1). There is no leverage anywhere.

## 2. Batch auction, uniform clearing price (§8)

- **Open-bid.** Bids are public on-chain the moment they land. No sealed phase.
- **Eligibility.** `bid(seriesId, qty, price)` requires an active MM bond (see [BOND-FAQ.md](BOND-FAQ.md)), `qty ≥ 0.1` option, `price ≥ reservePrice`, at most 64 bids per auction and 8 per bidder. Price is USDG (6 dec) **per option**; qty is 18 dec.
- **Escrow before clear.** `qty × price / 1e18` USDG is pulled by `safeTransferFrom` inside `bid`. A bid that cannot fund itself is never stored. There is no cancellation and no amendment; a new bid is a new escrow.
- **Clearing** is permissionless at `auctionClose` (open + 900 s) and inside a grace of 1 h after close. Bids are sorted price-descending, ties by earlier bidId. The book is walked from the top until the offered quantity is exhausted. **The clearing price is the price of the last bid that received any fill.** Everyone above it fills fully at that price; the marginal price group fills pro-rata by quantity, rounding dust to the earliest bid. A single bid clears at its own price.
- **What you pay.** `floor(filledQty × clearingPrice / 1e18)`. The difference to your escrow, plus the whole escrow of any unfilled bid, is credited to `refundable[you]`. Pull it any time with `withdrawRefund(to)`. Refunds never expire.
- **Skip path.** If there are no bids, the coverable quantity is zero, expiry has passed, the clear arrives after the 1 h grace, or every vault share is queued for redeem, the series is SKIPPED: every escrow is refundable, every bond lock is released, the vault keeps its tokens. `previewClear(seriesId)` tells you in advance.

Premium net of a 10 % performance fee goes to the vault's depositors at clear. The protocol earns nothing from settlement.

## 3. Reserve floor (§8.3)

The keeper supplies a reserve per auction from a Black-Scholes floor at trailing realised volatility, deliberately below fair value: it exists so a careless keeper cannot give the upside away, not to price the option. The contract bounds it into `[S_ref × minReserveBpsOfSpot, S_ref]`; defaults are 10 bps of spot for weekday and 3 bps for weekend, set per vault by the curator through the 48 h timelock. Bids below the reserve revert rather than being stored. Read it from `auctions(seriesId).reservePrice`.

## 4. Options and physical collateral

Fills are booked, not pushed. After clear you hold an **allocation** `claimableOptions[seriesId][you]`, which is already an option in every economic sense. Two ways to realise it:

| | `claimOptions(seriesId, to)` | `claimPayout(seriesId, to)` |
|---|---|---|
| When | any time after clear, while the series is LIVE, HALTED, SETTLED or RESOLVED | only once the series is SETTLED or RESOLVED |
| What happens | the vault mints your allocation as ERC-1155 tokens (id = seriesId) to `to` | the vault mints to the AuctionHouse and immediately burns for the payout, all in one transaction, paid to `to` |
| Use it when | you want to transfer, hedge or sell the option, or hold it in a custody wallet | you just want the settlement in one call |
| After settlement | call `OptionToken.claim(seriesId, qty, to)` on the tokens yourself | done |

Option tokens are freely transferable (D-012). Whoever holds them at claim time receives the payout. Claims never expire. Transferring the tokens away does **not** release your bond lock; only settlement does.

The vault reserves the payout in `payoutOwed` at settlement, so it can never be paid to depositors. The only way the vault falls short is an issuer burn or freeze of the vault's own tokens, in which case the payout is scaled pro-rata and the shortfall goes to the safety-module flow (§9.7 step 5, §14).

## 5. Settlement, both paths (§9)

Settlement is `SettlementOracle.settle(seriesId, hint)`, permissionless. The keeper supplies a hint (a Chainlink round id or a pool observation index); the contract verifies the hint and never trusts it. The payout is

```
payoutPerOption = S > K ? (S − K) × 1e18 / S : 0      // raw Stock-Token units per option, rounded down
```

Every candidate `S` on every path must pass the **jump guard**: within 30 % of the `S_ref` stored at open (unless a corporate-action multiplier explains the move).

**Path A: settle on a verified price.**

| Series | Primary | Fallback |
|---|---|---|
| WEEKDAY | the last valid Chainlink round at or before expiry, no older than 26 h (path 1) | 30-min Uniswap v3 TWAP anchored at expiry, within 3 % of that round, with liquidity and activity checks (path 2) |
| WEEKEND | 60-min TWAP anchored at Sunday 23:59 UTC, within 15 % of Friday's last Chainlink round, 250k USDG < 1 % impact liquidity, ≥ 3 observations, called within 30 min of expiry (path 2) | first fresh Chainlink round after expiry, published by Monday 15:00 UTC (path 3); in practice within an hour of expiry |

A weekend series never settles on a Chainlink answer older than 2 h, which is why the TWAP is primary there.

**Path B: halt, then resolve.** If every path fails, anyone calls `halt(seriesId)`. The vault pauses new auctions, deposits stop, and the series is resolved inside a hard band of **±25 % around the last valid Chainlink round at or before expiry**:

- `resolveHalted(seriesId, price, evidenceURI)`: timelock only, 48 h public delay, reverts outside the band (path 4). You can see the proposed price in the timelock queue before it executes.
- `resolveHaltedByOracle(seriesId, roundHint)`: **permissionless after 7 days past expiry**, takes the first valid Chainlink round after expiry and clamps it into the band (path 5). No key is needed to resolve a halted series.

Both paths end the same way: `payoutPerOption` is written, the series is SETTLED (A) or RESOLVED (B), `claimPayout` and `OptionToken.claim` work, and `AuctionHouse.releaseLocks(seriesId)` frees every filled bidder's bond. While a vault is halted, refunds and claims for earlier series keep working.

## 6. Your timeline for one weekday series

```
Mon 14:00 UTC   auction opens          read auctions(seriesId); bond must be active
Mon 14:00-14:15 bid                    USDG escrow moves now; bond locked on your first bid
Mon 14:15+      clear (anyone)         allocation and refund booked; unfilled bidders' locks released
any time        withdrawRefund         pull what you did not pay
any time        claimOptions           optional: mint the ERC-1155 to hedge or transfer
Fri 16:00 ET    expiry                 keeper calls settle (or anyone)
after settle    claimPayout / claim    Stock Tokens arrive; releaseLocks frees the bond
Fri +10 min     weekend auction opens  same vault, strike off a fresh S_ref
```

## 7. Numbers to keep on a sticky note

| | |
|---|---|
| Auction length | 900 s |
| Clear grace after close | 1 h (5 min to 4 h by timelock) |
| Min bid | 0.1 option |
| Max bids | 64 per auction, 8 per bidder |
| Strike grid | 0.25 % of `S_ref`, rounded up |
| Reserve floor defaults | 10 bps of spot (weekday), 3 bps (weekend) |
| Performance fee on premium | 10 % (bound 0–20 %) |
| Jump guard | ±30 % of `S_ref` |
| Resolution band | ±25 % of the last pre-expiry Chainlink round, contract constant |
| MM bond | 25,000 USDG, 7-day withdrawal cooldown |
| Admin | one hardware wallet behind a 48 h TimelockController; guardian can only pause |
| Upgradeability | none, no proxies, no delegatecall in fund-holding contracts |
