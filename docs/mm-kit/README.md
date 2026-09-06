# Overwrite market-maker onboarding kit

Everything an options desk needs to bid in Overwrite auctions on Robinhood Chain, from the first bond to the first payout claim.

| File | What it is | Read it when |
|---|---|---|
| [MECHANICS.md](MECHANICS.md) | One page: the batch auction, uniform clearing price, escrow, reserve floor, both settlement paths, physical collateral, `claimOptions` vs `claimPayout` | first |
| [BIDDING-GUIDE.md](BIDDING-GUIDE.md) | Step by step with real `cast` transactions against the 46630 testnet deployment, plus "try it on testnet in 10 minutes" with faucet links | before your first bid |
| [sdk/](sdk/) | Small TypeScript SDK on viem: post a bond, read the open auction, bid, claim options, claim payout. Sample bid strategies are in [sdk/strategies.ts](sdk/strategies.ts) as commented code | when you automate |
| [BOND-FAQ.md](BOND-FAQ.md) | The 25,000 USDG MM bond: lock rules, the 7-day withdrawal cooldown, slashing | before you wire the bond |
| [OUTREACH-EMAIL.md](OUTREACH-EMAIL.md) | Email template to send to options desks, in the landing page's voice | when you reach out |

Source of truth for anything these pages simplify: [docs/SPEC.md](../SPEC.md) §5, §7, §8, §9, §13 and the contracts in `contracts/src/`. Addresses come from [contracts/deployments/46630.json](../../contracts/deployments/46630.json).

## The one-paragraph version

Every Monday at 14:00 UTC (and again Friday ten minutes after NYSE close, for the weekend series) each vault offers 100 % of its Stock Tokens as European covered calls, strike gridded 0.25 % above a Chainlink reference price. Bonded market makers bid quantity and price in USDG; the escrow moves at bid time. After 15 minutes anyone clears: highest bids fill first, every winner pays the same marginal price, losers' escrow becomes a pull refund. Options are ERC-1155, physically collateralised by the vault's tokens, cash-settled in the Stock Token itself at expiry on the official Chainlink round. You claim the payout by burning the option, or skip minting entirely and call `claimPayout` once.

## Chain and contract quick reference (testnet 46630)

| | |
|---|---|
| Chain | Robinhood Chain testnet, chainId `46630`, gas in ETH, ~100 ms blocks |
| RPC | `https://rpc.testnet.chain.robinhood.com` (public, rate-limited, keeps ~19 minutes of state) |
| Explorer | `https://explorer.testnet.chain.robinhood.com` |
| AuctionHouse | `0xEFE287cE0761813e642B6df5D6A08637E97E9B93` |
| BondManager | `0x920F79DF191899934a04269B2280B2A1B2391266` |
| OptionToken (ERC-1155) | `0x56009D85b2318A3B3aDbE5764f602C0F26555eA6` |
| USDG (mock, open `mint`) | `0x640c46710A5C075292655e8602EC1D4BA844A930` |
| NVDA vault | `0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0` |
| SPY vault | `0x7b242611B7C490BC5F571095ef511d60E89bf914` |

On testnet USDG, the stock tokens, the Chainlink feeds and the Uniswap pools are mocks. Everything else is the code that ships to mainnet.
