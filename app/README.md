# app

Next.js App Router frontend for Overwrite: `/vaults`, `/vaults/[symbol]`, `/stake` (behind
`NEXT_PUBLIC_STAKE_ENABLED`), `/points`, `/docs`.

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

## Voice and design

Copied from `landing/index.html`: white, black, one accent, Schibsted Grotesk, tables and rules instead
of cards. Premium figures are always tagged **last auction** or **model estimate**; never an APY. The only
disclosures live in the footer.
