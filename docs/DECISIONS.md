# Overwrite — Design Decisions

Format: ID · date · decision · alternatives considered · why · sources. Newest at the bottom. Every entry that changes behaviour must also be reflected in SPEC.md.

---

## D-001 · 2026-09-02 · Settlement oracle policy: Chainlink (26 h) for weekday series, Uniswap v3 TWAP primary for weekend series

**Decision.**
- Weekday series (expiry Friday 16:00 ET): settle on the last Chainlink round at or before expiry, accepted only if `expiry − updatedAt ≤ 26 h` (feed heartbeat 86 400 s + 2 h). Fallback: 30-minute TWAP anchored at expiry, within 3 % of the last Chainlink answer. Else halt.
- Weekend series (expiry Sunday 23:59 UTC): never settle on a Chainlink answer older than 2 h. Primary: 60-minute Uniswap v3 TWAP of the stock/USDG 0.05 % pool anchored at expiry, with observation-coverage and minimum-liquidity checks and a ±15 % sanity bound against the last Chainlink answer. Fallback: the first fresh Chainlink round after expiry, accepted no later than Monday 15:00 UTC. Else halt.

**Alternatives considered.**
1. The original brief: Chainlink primary with staleness 2 h weekday / 26 h weekend, TWAP fallback if stale and within 3 %. Rejected: measured feed behaviour makes this fail routinely (below).
2. Chainlink primary with staleness 26 h weekday / 78 h weekend (78 h = Thursday-heartbeat worst case to Sunday 23:59 UTC). Rejected by the founder: a ~52–56 h old price is a Friday close, not a Sunday price, and the whole point of the weekend series is exposure over the weekend; a weekend-old Chainlink price also gives the winning bidder a free look at Sunday's on-chain price before settlement.
3. Chainlink first-round-after-expiry as the weekend primary (typically arrives ~00:00–00:01 UTC Monday). Kept as the fallback only, because the TWAP reflects the on-chain price at expiry itself and does not depend on the feed reopening.

**Why (measured, cast on 2026-09-02 against `https://rpc.mainnet.chain.robinhood.com`).**
- All Robinhood stock feeds: decimals 8, heartbeat 86 400 s, deviation 0.5 %, schedule `us_equities_24/5`, no heartbeat off-hours. Sources: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json , https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood , https://docs.chain.link/data-feeds/selecting-data-feeds
- NVDA aggregator `0xC9d16E4f2569b9E3ea0468fD85844953713DC2a2`: 954 rounds in ~63 days; weekday gaps of 4.4 h, 7.6 h, 8.1 h observed; last round before Fri 2026-08-28 20:00 UTC was round 930 at 19:56 UTC; last round before Sun 2026-08-30 23:59 UTC was still round 930 (≈ 52 h old); round 931 came at Mon 00:00:54 UTC.
- SPY aggregator `0x78BCB218fA04B9b3a278eBc865Ed320BF8DEFBAc`: 116 rounds in ~63 days, i.e. essentially heartbeat-only (round 113→114 = 86 401 s); last round before Fri 20:00 UTC was 3.7 h old (fails a 2 h guard); last round before Sun 23:59 UTC was ≈ 56 h old (fails a 26 h guard); round 113 came at Mon 00:00:33 UTC.
- Uniswap v3 NVDA/USDG 0.05 % pool `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3`: `observationCardinality` 6000, `observe([1800,0])` succeeded, TWAP tick 222534 ≈ $216.4 vs feed $216.79; ≈ $6.1 M TVL. Source: cast, https://scopl.live/pools/robinhood/0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3 , https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
- Robinhood docs on staleness and sequencer checks: https://docs.robinhood.com/chain/oracles-and-price-feeds

**Consequences.** SPEC.md §9. Deploy step: `increaseObservationCardinalityNext(65535)` on every allowlisted pool. Keeper must monitor observation coverage. The ±15 % bound caps manipulation damage at ≈ 8.7 % of notional for a 5 % OTM strike (SPEC §9.3); MM bonds are slashable for demonstrated manipulation.

---

## D-002 · 2026-09-02 · Strike convention PER_TOKEN, no adjustment across splits or dividends

**Decision.** Strike is USD per raw stock token, the unit the Chainlink feed reports. Settlement applies no multiplier adjustment to the strike.

**Alternatives considered.** Adjusting the strike by `uiMultiplier(expiry) / uiMultiplier(open)` at settlement (the brief's original wording). Rejected.

**Why.** The feed already prices one raw token as `share price × uiMultiplier`; raw balances never change. A split or reinvested dividend therefore leaves the token price, the vault NAV and a per-token strike continuous. Applying a multiplier ratio on top would double-count the corporate action. Sources: https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood ("Token Price = Underlying Equity Market Price × Multiplier"), https://docs.robinhood.com/chain/building-with-stock-tokens ("The Chainlink price already includes the corporate-action multiplier … don't apply the multiplier yourself"), https://docs.robinhood.com/chain/stock-tokens , https://eips.ethereum.org/EIPS/eip-8056 . Observed: AAPL `uiMultiplier() = 1.000566080061092436` on 2026-09-02 (dividend reinvested) with the feed unchanged in token terms.

**Consequences.** SPEC.md §10. `Series.multiplierAtOpen` is stored for indexers only. `settle` and `openAuction` wait while `oraclePaused()` is true.

---

## D-003 · 2026-09-02 · Admin is a single hardware-wallet EOA behind a 48 h TimelockController; no multisig

**Decision.** `TimelockController(minDelay = 48 h)` with one proposer/executor EOA (hardware wallet). A separate guardian key can only pause new auctions and deposits. Deployer renounces all roles.

**Alternatives considered.** 2-of-3 or 3-of-5 Safe as proposer. Rejected by the founder for v1 (single operator, no co-signers available; a multisig with one real signer adds ceremony without security). Revisit when there is a second independent operator.

**Why.** CLAUDE.md rule 5. The 48 h public delay is the actual protection: every privileged action is visible in the timelock queue before execution, and withdrawals of unencumbered tokens are never blockable by any key.

**Consequences.** SPEC.md §15. RUNBOOK.md must cover key custody, the guardian rotation procedure and what to do if the admin key is lost (nothing can be changed; funds remain withdrawable).

---

## D-004 · 2026-09-02 · Premium is claimable in USDG per share; no auto-compounding in v1

**Decision.** Premium stays outside the ERC-4626 NAV as a per-share USDG accumulator; depositors call `claimPremium`. The vault never swaps USDG into stock tokens.

**Alternatives considered.** (1) Auto-compound by buying stock tokens on Uniswap at clearing. Rejected for v1: introduces slippage/MEV exposure and a second oracle dependency inside the vault. (2) Holding USDG inside NAV with a mixed-asset share price. Rejected: breaks the clean ERC-4626 accounting and makes `convertToAssets` depend on a price.

**Why.** Keeps `totalAssets` purely in stock tokens, makes the coverage invariant trivial and lets the share price stay constant between settlements (SPEC I-8).

**Consequences.** SPEC.md §4.2; points indexer reads `PremiumAccrued`.

---

## D-005 · 2026-09-02 · Sequencer uptime hook shipped disabled

**Decision.** `SettlementOracle` keeps a `sequencerFeed` slot and the standard Chainlink check (`answer == 0`, grace 3 600 s) but ships with address `0`, i.e. disabled.

**Alternatives considered.** Hardcoding an address (none exists for this chain), or omitting the check entirely (would need a redeploy later).

**Why.** No L2 Sequencer Uptime Feed for Robinhood Chain is published at https://docs.chain.link/data-feeds/l2-sequencer-feeds or in the feed JSON; https://docs.robinhood.com/chain/oracles-and-price-feeds tells integrators to check one but gives no address. Enabling it later is a single timelocked parameter change.

---

## D-006 · 2026-09-02 · Deposits and redemptions outside the IDLE window are queued, not rejected

**Decision.** `requestDeposit` / `requestRedeem` queues are executed at the next settlement at the post-settlement share price; direct ERC-4626 calls only work in IDLE.

**Alternatives considered.** Reverting deposits mid-series (simpler, worse UX; the Friday window is only 10 minutes). Allowing deposits mid-series (dilutes settlement losses onto depositors who received no premium). 

**Why.** Coverage must never drop below sold options, and premium must go to the shares that carried the risk. Queues achieve both without a long IDLE window.

**Consequences.** SPEC.md §4.3, §5.

---

## D-007 · 2026-09-02 · Market-maker eligibility: on-chain bond only; non-US-person attestation is off-chain

**Decision.** MM bond 25 000 USDG pre-token, migrated to WRITE post-token. The signed attestation is checked by the off-chain allowlist service and the frontend; nothing on-chain encodes it.

**Alternatives considered.** On-chain attestation registry or KYC-gated bidding. Rejected for v1: adds a privileged registrar and does not materially improve compliance beyond the issuer-level restrictions that already exist on the tokens (https://docs.robinhood.com/chain/stock-tokens).

**Consequences.** SPEC.md §13, frontend geo-block and disclosures per CLAUDE.md rule 10.

---

## D-008 · 2026-09-02 · Vault allowlist is hardcoded to cast-verified token and feed addresses

**Decision.** v1 `VaultFactory` allows exactly the stock tokens, Chainlink proxies and 0.05 % pools listed in SPEC.md §1.2–§1.5, verified by `cast` on 2026-09-02. Adding a token is a timelocked `allowToken` with all three addresses.

**Alternatives considered.** Reading Robinhood's on-chain asset registry. Rejected: its address is not published (https://docs.robinhood.com/chain/contracts says the table is generated from it but gives no address) and the beacon's `owner()` reverts.

**Consequences.** SPEC.md §1.2, §15, §19.

---

## D-009 · 2026-09-02 · Option parameters: relative 0.25 % strike grid, per-kind distance bounds, 100 % utilisation net of queued redeems

**Decision.**
- `grid = S_ref × 0.25 %`; `K = ceilDiv(S_ref × (1 + d), grid) × grid` (round up, further out of the money).
- `strikeDistanceBps` bounds enforced on-chain: WEEKDAY 300–1500, WEEKEND 100–1000. Keeper defaults: single names (NVDA, TSLA, AAPL, MSFT, AMZN, GOOGL, META) 800 / 500 bps; ETFs (SPY, QQQ) 200 / 100 bps.
- `offeredQty = totalAssets() − convertToAssets(queued redeem shares)`: the vault writes calls on 100 % of its unencumbered balance, excluding tokens already requested for withdrawal.

**Alternatives considered.** Fixed dollar grids per ticker ($1 NVDA, $5 SPY) — rejected: needs per-vault tuning and drifts with price level. A `maxUtilizationBps` buffer below 100 % — rejected: idle tokens earn nothing and queued redeems are already carved out.

**Why.** A relative grid is self-scaling across a 4:1 split and across tickers; the rounding cost is bounded at one step (0.25 %). Distance bounds prevent a keeper from selling near-the-money weekday calls by mistake.

**Consequences.** SPEC.md §5, §7.2, §4.3; `openAuction` no longer takes `offeredQty`.

---

## D-010 · 2026-09-02 · Weekend TWAP liquidity rule: a 250 000 USDG swap must move the price by less than 1 %; grace 30 minutes

**Decision.** At settle time the pool's in-range liquidity must satisfy `L × (√1.01 − 1) ≥ 250 000e6 × sqrtPriceX96 / 2^96` (derivation in SPEC §9.3). `twapGrace = 1 800 s`.

**Alternatives considered.** A raw `liquidity ≥ constant` per pool — rejected: v3 liquidity units are not comparable across price levels. A TVL-in-USD check — rejected: TVL includes out-of-range liquidity that does not resist a swap.

**Why.** In-range liquidity is exactly what a manipulator must trade against. Measured 2026-09-02 on the NVDA/USDG 0.05 % pool (`0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3`): `liquidity` 9.5037e18, `sqrtPriceX96` 5.3815e33, giving ≈ 698 000 USDG of room before 1 % impact, so NVDA passes with margin. SPY and QQQ pools not yet measured (SPEC §19).

**Consequences.** SPEC.md §9.3; `swapNotionalUSDG` and `impactBps` are timelocked parameters.

---

## D-011 · 2026-09-02 · Economic constants pre-token

**Decision.** Curator bond 10 000 USDG (one per vault); MM bond 25 000 USDG (D-007); fixed cap 25 000 USDG per vault, priced via the vault's Chainlink feed; post-token `k = 5` with governance-set `capWeightBps` defaulting to an equal split; WRITE fee mode with 20 % discount and 50 % of the received WRITE burned, remainder to treasury; performance fee 10 % of premium.

**Alternatives considered.** Larger launch caps (100 000–250 000 USDG) — rejected in favour of a small, audited-in-production start given the TWAP manipulation exposure (SPEC §9.3) and unmeasured pool depth for ETFs.

**Why.** Caps below the TWAP liquidity threshold keep the worst-case manipulation profit below the cost of moving the pool.

**Consequences.** SPEC.md §11, §12, §13.

---

## D-012 · 2026-09-02 · Guardian is a hot key on the keeper server; option tokens are freely transferable ERC-1155

**Decision.** `GUARDIAN_ROLE` is held by a hot key on the keeper server, separate from the keeper's transaction key, so automated alerting can pause without a human. Option tokens are standard ERC-1155 with no transfer restriction.

**Alternatives considered.** Guardian on a hardware wallet — rejected: pauses must be fast, and the role can only pause. Soul-bound option tokens — rejected: MMs need to hedge or unwind; compliance is enforced off-chain at bidding (D-007), not at transfer.

**Why.** The guardian's blast radius is limited by construction (SPEC §15): it cannot move funds, change parameters or block withdrawals, so a hot key is acceptable.

**Consequences.** SPEC.md §3, §8.2, §15; RUNBOOK.md must describe key rotation.

---

## D-013 · 2026-09-02 · Points formula

**Decision.** Daily snapshot at 00:00 UTC. Depositors: 1 point per USD-equivalent of stock tokens deposited per day, priced with the vault's Chainlink feed. Bonded MMs: 2 × the USD value of their bond per day. Staking points added post-token.

**Alternatives considered.** Share-seconds without USD pricing — rejected: not comparable across vaults. Premium-based points — rejected: double-counts what depositors already receive.

**Consequences.** SPEC.md §16.3; indexer needs `convertToAssets`, share balances and feed answers at snapshot blocks.

---

## D-014 · 2026-09-02 · Testnet: four mocks plus mainnet-fork tests

**Decision.** Mocks for the ERC-8056 stock token, USDG (6 decimals), a Chainlink aggregator with settable `answer`/`updatedAt`, and a v3 pool `observe` stub. Real integrations are tested on a mainnet fork.

**Alternatives considered.** Deploying a full Uniswap v3 stack on testnet — rejected: heavy, and the fork tests cover the real pool. Mainnet-fork only — rejected: keeper and frontend need a persistent public environment.

**Why.** cast on 2026-09-02 showed testnet 46630 has no USDG, stock tokens, Chainlink stock feeds, Uniswap v3 factory or Morpho at the mainnet addresses (SPEC §1.8).

**Consequences.** SPEC.md §1.8; `contracts/test/mocks/`.
