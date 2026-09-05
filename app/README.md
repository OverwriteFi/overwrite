# app

Next.js App Router frontend for Overwrite: `/` (marketing home, ported from `landing/index.html`),
`/vaults`, `/vaults/[symbol]`, `/stake` (behind `NEXT_PUBLIC_STAKE_ENABLED`), `/points`, `/docs`.

## Run

```bash
npm install
cp .env.example .env      # blank RPC = public testnet RPC
npm run dev
```

Point `NEXT_PUBLIC_RPC_URL` at `http://127.0.0.1:8545` while `keeper`'s `npm run week` anvil fork is
up to see cleared auctions, settled series and the queued-withdrawal flow with real state.

## How it reads the chain

- Addresses come from `contracts/deployments/<chainId>.json` (imported in `src/lib/deployments/index.ts`);
  there is no factory, so that file is the vault list.
- ABIs are sliced from `contracts/out` by `npm run gen:abi` into `src/lib/abi/generated.ts` (committed).
  Run it after any contract change; it fails loudly on a missing fragment.
- Shared, wallet-independent state is read server-side (`src/lib/reads/*`) through Multicall3 and
  cached with `unstable_cache` for 30 s. Everything that crosses the cache is JSON: bigints are strings.
- Series history is enumerated from `optionToken.nextSeriesId()` with state reads only. The public
  testnet RPC keeps ~19 minutes of history, so nothing here uses `getLogs`.
- Wallet-specific reads and every write are client-side wagmi hooks (`src/hooks/*`). Every write pins
  the chain id and re-checks the wallet's chain right before sending.
- There is no geo-restriction (D-110, founder decision). The footer carries the two factual disclosures on every page.

## The marketing home (`/`)

`src/app/(marketing)/` is `landing/index.html` as React: same copy, same CSS (`landing.css`, every rule
scoped under `.landing`), same model. It lives in its own route group so it ships without the wagmi
bundle; `(app)/` holds the wallet-connected pages with the providers, header and footer. Lighthouse
performance on the production build: 100 desktop, 94 mobile.

Its two instruments read the chain through the same server-side layer as the rest of the app:

- **Calculator and ledger** (`src/lib/reads/landing.ts`): the Black-Scholes model from the landing at
  each vault's cap. For a deployed vault the cap is the strike distance of its last auction (else the
  keeper default in `vault-defaults.ts`), the slider range is `AuctionHouse.strikeDistanceBounds`, and
  once a vault has a cleared auction "Last auction paid X%" (`clearingPrice / sRef`) appears under the
  estimate and in the ledger. Tickers without a vault show the model and "Soon".
- **WRITE loop** (`src/lib/reads/loop.ts`): `launched` is `FeeRouter.writeToken() != 0`, which the
  timelock sets after the token launches (SPEC §11). Before that the page shows the landing's slider
  model with one line, "Model. Live after launch." After it: `SafetyModule.safetyModuleValueUSD`,
  Σ `CapController.vaultCapUSD` and Σ vault TVL, last 7 days' `premiumGross` and `fee` from
  `AuctionHouse.auctions()` (the same numbers `AuctionCleared` carries, read as state because the public
  RPC keeps ~19 minutes of logs), WRITE burned to date as `WRITE.MAX_SUPPLY − totalSupply` (I-31; set
  `FEE_ROUTER_FROM_BLOCK` on an archive RPC to sum `FeeRouter.WriteFeePaid.burned` from logs instead),
  and WRITE in bonds as `WRITE.balanceOf(BondManager)`.

### Waitlist store ("Get in line")

`POST /api/waitlist` takes `{contact}` (email or 0x address; validated and normalised on both sides,
honeypot field `hp`) and inserts into a Supabase table through PostgREST with the service-role key.
Supabase was chosen over Vercel KV because it is host-independent, free at this size, and exports to
CSV from the dashboard (D-111).

1. Create a Supabase project, open the SQL editor, run `supabase/waitlist.sql`.
2. Set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in `.env` (server-only; never `NEXT_PUBLIC_`).
3. With both blank, rows append to `.data/waitlist.jsonl` (gitignored) so local previews still work.

Duplicates are ignored, not errors. The confirmation promises exactly one message: the first auction's
clearing premium.

## Voice and design

Copied from `landing/index.html`: white, black, one accent, Schibsted Grotesk, tables and rules instead
of cards. Premium figures are always tagged **last auction** or **model estimate**; never an APY. The only
disclosures live in the footer.
