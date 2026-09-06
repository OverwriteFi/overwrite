# Outreach email to options desks

Plain text, short paragraphs, no attachments. Swap the bracketed parts. Subject line options at the bottom.

---

**Subject:** Weekly covered-call auctions on tokenized NVDA and SPY. Bonded bidders only.

Hi [first name],

Stock Tokens on Robinhood Chain trade around the clock. 190 of them. Not one has written an option. Overwrite is the vault layer that does: every Monday the vaults put 100 % of their tokens up as one-week covered calls and sell them to market makers in a single on-chain batch auction. Friday night they do it again for the weekend, a series no listed venue can sell.

Here is the mechanism, because it is the whole pitch.

Uniform price. Bids are quantity and price in USDG. The vault fills the highest bids first and every winner pays the same clearing price, the marginal bid. If you are the only bidder above the floor, you clear at your own price.

Escrow first. USDG moves when you bid, not when you win. What you do not pay is refundable the moment the auction clears. No margin calls, no counterparty, no settlement risk on the premium leg.

Physically collateralised. One option is one Stock Token, held in the vault for the life of the series. Settlement is on the official Chainlink round, in the token itself, on-chain. Nothing is ever sold on an exchange to settle. Your payout is reserved at settlement and cannot be paid to anyone else.

Fifteen minutes, twice a week. Monday 14:00 UTC, and again ten minutes after Friday's NYSE close for the Sunday 23:59 UTC expiry. Strikes sit 3–15 % above spot on weekdays and 1–10 % on weekends, on a 0.25 % grid off the Chainlink reference.

To bid you post a 25,000 USDG bond. It is locked while you hold a live series, withdrawable after a 7-day cooldown, and slashable only through a 48-hour public timelock with published grounds. No admin key touches it.

The contracts are live on the Robinhood Chain testnet today: two vaults, NVDA and SPY, real auction code, mock tokens. I have a kit that gets a desk from zero to a filled bid in about ten minutes: a one-page mechanics note, a bidding guide with the exact transactions, a small viem SDK, and the bond FAQ. [link to docs/mm-kit]

Mainnet follows the audit. The first vaults open with fixed caps, so the early bidders are bidding into thin books with a floor set from realised vol. That does not last.

Would a 30-minute walkthrough next week suit? I can also send testnet gas to any address you name.

[Your name]
Overwrite
[telegram / signal handle]
[link]

Overwrite is an independent protocol deployed on Robinhood Chain. It is not affiliated with, operated by, or endorsed by Robinhood. Stock Tokens are issued by Robinhood Assets (Jersey) Limited.

---

## Alternative subject lines

- The weekend, which no exchange on earth can sell
- Two covered-call auctions a week on Robinhood Chain Stock Tokens
- Bid for tokenized-equity upside. Escrow first, options second.
- 15 minutes on Monday, 15 on Friday: uniform-price call auctions, bonded bidders only

## Follow-up (5 days later, no reply)

**Subject:** Re: Weekly covered-call auctions on tokenized NVDA and SPY

[first name], one line so this does not get lost: the testnet auctions run every Monday 14:00 UTC and Friday after the close. If someone on the desk wants to watch a clear before we talk, the AuctionHouse is at `0xEFE287cE0761813e642B6df5D6A08637E97E9B93` on `explorer.testnet.chain.robinhood.com`. Happy to send gas.

[Your name]

## Voice notes for editing

Keep the landing page's rhythm: short declaratives, one idea per sentence, mechanism over adjectives. "Premium first, options second." "Fully covered, no leverage, no liquidations, ever." No exclamation marks, no "revolutionary", no APY promises. Every claim in the email is a rule in the contracts; if you add one, make sure it is too.
