# Bidding guide

Hands-on, against the live testnet deployment (chainId 46630). Commands use Foundry's `cast`; the same calls are wrapped in the [TypeScript SDK](sdk/). Read [MECHANICS.md](MECHANICS.md) first if you have not.

Addresses (from [contracts/deployments/46630.json](../../contracts/deployments/46630.json)):

```bash
export RPC=https://rpc.testnet.chain.robinhood.com
export AH=0xEFE287cE0761813e642B6df5D6A08637E97E9B93      # AuctionHouse
export BM=0x920F79DF191899934a04269B2280B2A1B2391266      # BondManager
export OT=0x56009D85b2318A3B3aDbE5764f602C0F26555eA6      # OptionToken (ERC-1155)
export USDG=0x640c46710A5C075292655e8602EC1D4BA844A930    # mock USDG, 6 dec, open mint
export NVDA_VAULT=0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0
export SPY_VAULT=0x7b242611B7C490BC5F571095ef511d60E89bf914
export ME=<your address>
```

Sign with whatever you normally use: `--ledger`, `--keystore`, `--account`, or a throwaway `--private-key` on testnet only. Never paste a mainnet key into a shell.

## Try it on testnet in 10 minutes

1. **Add the chain to your wallet or RPC config.** chainId `46630`, RPC `https://rpc.testnet.chain.robinhood.com`, currency ETH, explorer `https://explorer.testnet.chain.robinhood.com`. Robinhood's own connection page: https://docs.robinhood.com/chain/connecting

2. **Get testnet ETH for gas.** A bid costs well under 0.001 ETH.
   - Robinhood testnet faucet: `https://faucet.testnet.chain.robinhood.com` (referenced by Robinhood's docs and third parties; it refused a scripted fetch, so open it in a browser).
   - QuickNode multi-chain faucet: https://faucet.quicknode.com, pick Robinhood Chain testnet.
   - Chainlink faucet: https://faucets.chain.link/robinhood-testnet (verified page; it drips LINK, and on some chains ETH as well, so check the drop-down).
   - If all three are dry, mail the address in [OUTREACH-EMAIL.md](OUTREACH-EMAIL.md) and we will send gas.

3. **Mint testnet USDG.** USDG on 46630 is a mock with an open `mint`. You need 25,000 for the bond plus whatever you want to escrow.

   ```bash
   cast send $USDG "mint(address,uint256)" $ME 100000000000 --rpc-url $RPC --private-key $PK   # 100,000 USDG
   cast call $USDG "balanceOf(address)(uint256)" $ME --rpc-url $RPC
   ```

4. **Post the bond** (approve 25,000 USDG, then `postBond(1)` where `1` is `BondKind.MM`):

   ```bash
   cast send $USDG "approve(address,uint256)" $BM 25000000000 --rpc-url $RPC --private-key $PK
   cast send $BM "postBond(uint8)" 1 --rpc-url $RPC --private-key $PK
   cast call $BM "hasActiveMMBond(address)(bool)" $ME --rpc-url $RPC        # true
   ```

5. **Approve the AuctionHouse to pull escrow** once, for as much as you are prepared to escrow:

   ```bash
   cast send $USDG "approve(address,uint256)" $AH 50000000000 --rpc-url $RPC --private-key $PK
   ```

6. **Find the open auction** (Monday 14:00–14:15 UTC, or Friday from ten minutes after NYSE close). `currentAuction(vault)` is the latest seriesId for that vault; `auctions(seriesId).state` is `1` while OPEN.

   ```bash
   cast call $AH "currentAuction(address)(uint256)" $NVDA_VAULT --rpc-url $RPC
   cast call $AH "auctions(uint256)((address,uint8,uint8,uint64,uint64,uint64,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint128,uint16))" <seriesId> --rpc-url $RPC
   ```

   Field order: `vault, kind, state, auctionOpen, auctionClose, expiry, sRef, strike, offeredQty, reservePrice, clearingPrice, filledQty, premiumGross, fee, feeBps`. `sRef` and `strike` are USD with 8 decimals; `reservePrice` is USDG (6 dec) per option; `offeredQty` is 18 dec.

7. **Bid.** `qty` in 1e18 units, `price` in USDG per option (6 dec), at or above the reserve. Escrow moves in this transaction.

   ```bash
   cast send $AH "bid(uint256,uint256,uint256)" <seriesId> 10000000000000000000 280000 --rpc-url $RPC --private-key $PK
   #                                                       ^ 10 options            ^ 0.28 USDG each  → escrow 2.80 USDG
   ```

8. **After close, read the result.** Anyone may `clear`; the keeper does it within seconds. You can call it yourself if you like paying gas.

   ```bash
   cast call $AH "previewClear(uint256)(uint256,uint256,uint256,bool)" <seriesId> --rpc-url $RPC   # cp, filled, gross, willSkip
   cast call $AH "claimableOptions(uint256,address)(uint256)" <seriesId> $ME --rpc-url $RPC
   cast call $AH "refundable(address)(uint256)" $ME --rpc-url $RPC
   cast send $AH "withdrawRefund(address)" $ME --rpc-url $RPC --private-key $PK
   ```

9. **After expiry, take the payout.** Either one call (`claimPayout`) or mint then claim.

   ```bash
   cast send $AH "claimPayout(uint256,address)" <seriesId> $ME --rpc-url $RPC --private-key $PK
   # or
   cast send $AH "claimOptions(uint256,address)" <seriesId> $ME --rpc-url $RPC --private-key $PK
   cast send $OT "claim(uint256,uint256,address)" <seriesId> <qty> $ME --rpc-url $RPC --private-key $PK
   cast send $AH "releaseLocks(uint256)" <seriesId> --rpc-url $RPC --private-key $PK              # frees the bond; keeper also does this
   ```

10. **Watch it on the explorer**: `https://explorer.testnet.chain.robinhood.com/address/0xEFE287cE0761813e642B6df5D6A08637E97E9B93`.

Testnet caveat: the public RPC keeps roughly 19 minutes of state, so `eth_getLogs` over older ranges fails. Read state, not history, or run your own node.

## Worked example: one weekday series on NVDA

Numbers from the September 2026 rehearsal ([REHEARSAL-1.md](../REHEARSAL-1.md)); your live seriesId will differ.

| Step | Value |
|---|---|
| `S_ref` at open | 230.00 USD |
| Strike distance | 800 bps: `K_raw = 248.40`, grid = 0.25 % × 230 = 0.575, `K = ceilDiv(248.40, 0.575) × 0.575 = 248.40` (already on the grid) |
| Offered | 90 NVDA-tokens' worth of calls |
| Reserve | 0.23 USDG per option (10 bps of spot) |
| Black-Scholes fair value at 55 % vol | ≈ 0.72 USDG per option (the SDK's `fairValue`) |
| Bids | MM-A: 60 @ 0.80; MM-B: 60 @ 0.70 |
| Clearing | 90 filled; A gets 60, B gets 30 at the marginal price **0.70** |
| A pays | 60 × 0.70 = 42.00 USDG, refund 6.00 |
| B pays | 30 × 0.70 = 21.00 USDG, refund 21.00 |
| Premium to vault | 63.00 gross, 6.30 fee, 56.70 net |
| Settlement (Friday, Chainlink round) | S = 265.00, above K |
| `payoutPerOption` | `(265 − 248.40) / 265 = 0.062642` tokens per option |
| A claims | 60 × 0.062642 = 3.7585 NVDA tokens (worth 996 USD at 265; A paid 42 USDG premium) |

If the Friday round had printed below the strike, `payoutPerOption` is zero, `claimPayout` still succeeds (it burns and pays nothing) and your bond is released the same way.

## Reading the book during the 15 minutes

```bash
cast call $AH "bids(uint256)((address,uint128,uint128,uint128)[])" <seriesId> --rpc-url $RPC
cast call $AH "bidders(uint256)(address[])" <seriesId> --rpc-url $RPC
cast call $AH "bidCount(uint256,address)(uint256)" <seriesId> $ME --rpc-url $RPC
```

The auction is open-bid, so everyone sees every bid. `previewClear` runs the real clearing routine as a view, so "what would I get if it cleared now" is one RPC call. With ~100 ms blocks and 8 bids per bidder, you can ladder and react; see the strategies in [sdk/strategies.ts](sdk/strategies.ts).

## Unit cheat-sheet

| Quantity | Unit | Example |
|---|---|---|
| `qty` | 1e18 = one option on one token | `10e18` = 10 options |
| `price`, `reservePrice`, `clearingPrice` | USDG per option, 6 dec | `280000` = 0.28 USDG |
| escrow, refund, premium | USDG 6 dec | `2800000` = 2.80 USDG |
| `sRef`, `strike`, `settlementPrice` | USD 8 dec | `23000000000` = 230.00 |
| `payoutPerOption` | raw token units per option, < 1e18 | `60500000000000000` = 0.0605 |
| `BondKind` | `0` CURATOR, `1` MM | |
| `SeriesKind` | `0` WEEKDAY, `1` WEEKEND | |
| `AuctionState` | `0` NONE, `1` OPEN, `2` CLEARED, `3` SKIPPED | |
| `SeriesState` (vault) | `0` NONE, `1` AUCTION, `2` SKIPPED, `3` LIVE, `4` SETTLED, `5` HALTED, `6` RESOLVED | |

## Reverts you will meet and what they mean

| Error | Cause | Fix |
|---|---|---|
| `NoActiveBond` | no MM bond, or a withdrawal request is pending | `postBond(1)` or `cancelWithdraw(1)` |
| `BelowReserve(price, reserve)` | price under the floor | read `auctions(id).reservePrice` |
| `AuctionClosed` / `WrongAuctionState` | past `auctionClose`, or not OPEN | wait for the next series |
| `BidTooSmall` | qty under `minBidQty` (0.1) | |
| `TooManyBidsPerBidder` | 9th bid | you have 8 |
| `ZeroEscrow` | qty × price rounds to 0 USDG | |
| ERC-20 `insufficient allowance` | AuctionHouse not approved for the escrow | approve USDG to `$AH` |
| `NothingToClaim` | nothing allocated or already claimed | |
| `NotSettled` (OptionToken) / `WrongSeriesState` | series not yet SETTLED or RESOLVED | wait for `settle`; use `claimOptions` if you only want the tokens |
| `Locked(n)` (BondManager) | withdrawal requested with live series | wait for settlement and `releaseLocks` |
| `CooldownActive(unlockAt)` | 7 days not elapsed | |
