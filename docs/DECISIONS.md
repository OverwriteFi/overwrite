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

---

## D-015 · 2026-09-02 (revised same day) · TWAPs are converted to USD with the USDG/USD feed; a depeg beyond ±2 % or a stale peg read invalidates the TWAP path only

**Decision.** Every Uniswap TWAP the protocol uses (weekend primary, weekday fallback, reference spot, cap pricing) is multiplied by the USDG/USD Chainlink answer (`0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`). If that answer is older than 26 h **or** outside `[0.98, 1.02]`, the TWAP is invalid and the series falls through to the next oracle path: for a weekend series the first fresh Chainlink round after expiry (accepted until Monday 15:00 UTC), for a weekday series HALTED because the TWAP is already the last path. A depeg by itself never halts a weekend series.

**Alternatives considered.** Treating USDG at par (the v0.1 draft) — rejected: strikes and Chainlink answers are in USD, so a USDG discount would systematically overstate the payout to option holders. Halting a weekend series immediately on a depeg with no Chainlink fallback (the first revision of this entry) — rejected by the founder: the Chainlink stock feed is USD-denominated and unaffected by USDG, so a valid fresh round is a better outcome than a 48 h timelocked manual resolution; the USDG exposure of premium, escrow and bonds is a treasury risk, not a settlement-price risk.

**Why.** Measured USDG/USD 0.99975827 on 2026-09-02; the feed has the same 24 h heartbeat / 0.5 % deviation as the stock feeds (https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json). USDG is a Paxos-issued, LayerZero-bridged asset with issuer pause and freeze (SPEC §1.4), so a depeg is possible and must be handled explicitly.

**Consequences.** SPEC.md §7.2, §9.2, §9.3, §9.5, §9.6, §12, §16.1 (`TwapRejected` event), §16.2, invariant I-9. Parameters `usdgBandLowBps/HighBps`, `usdgMaxStale` are timelocked.

---

## D-016 · 2026-09-02 · `writePool` is a post-launch placeholder

**Decision.** `FeeRouter.writePool` (and the same reference used for cap valuation and MM-bond points) ships as `address(0)`. While zero, WRITE fee mode cannot be enabled and WRITE deposits are disabled. Set once by timelock after the token launches and a WRITE/USDG pool exists.

**Alternatives considered.** Deferring the whole WRITE path to a v2 deployment — rejected: CLAUDE.md rule 6 requires both cap paths to exist from day one, and the fee path is cheap to include behind the same switch.

**Consequences.** SPEC.md §11, §12, §16.3.

---

## D-017 · 2026-09-02 · Weekend TWAP sanity bound stays at 15 % globally, configurable per vault

**Decision.** `weekendTwapBoundBps` global default 1 500; per-vault override by timelock within `[300, 1500]`.

**Alternatives considered.** Starting at 1 000 bps for the first month — rejected: with launch caps of 25 000 USDG per vault (D-011) and the 250 000 USDG / 1 % liquidity rule (D-010), the manipulation profit ceiling (≈ 8.7 % of notional for a 5 % OTM weekend strike, SPEC §9.3) is small relative to the cost of moving the pool, and a tighter bound would trip on legitimate weekend moves in single names.

**Consequences.** SPEC.md §9.3.

---

## D-018 · 2026-09-02 · TWAP liquidity rule uses time-weighted liquidity over the window (RS-01)

**Decision.** The depth rule of D-010 (`L × (√1.01 − 1) ≥ 250 000e6 × sqrtP_X96 / 2^96`) is evaluated with the harmonic-mean in-range liquidity over the TWAP window, `L_avg = (window << 128) / (spl[1] − spl[0])` from the `secondsPerLiquidityCumulativeX128` values returned by the same `observe` call, not with spot `pool.liquidity()` at settle time.

**Alternatives considered.** Spot liquidity at the call (v0.1): an LP can withdraw liquidity for the window, move the price cheaply, re-add it and call `settle`. Sampling liquidity at several blocks by the keeper: off-chain, unverifiable.

**Why.** Closes THREAT-MODEL T-03.3. The manipulator must now keep the pool deep for the whole hour they are manipulating, which is the cost the rule was meant to impose. The value is available for free from the `observe` call already made (Uniswap `OracleLibrary.consult` convention).

**Consequences.** SPEC §9.3 item 1, §9.5. `TwapRejected(LIQUIDITY)` reason. Fork test must compute `L_avg` on the real NVDA/USDG pool and compare with the cast spot value (9.5037e18 on 2026-09-02).

---

## D-019 · 2026-09-02 · TWAP requires trading activity inside the window (RS-02, RS-03 folded in)

**Decision.** Path 2 requires at least `minObservationsInWindow` (default 3, timelocked within `[1, 16]`, snapshotted per series) pool observations with `blockTimestamp` inside `[expiry − window, expiry]`, and the most recent observation at or before `expiry` no older than `expiry − 900`. Otherwise the TWAP is rejected (`TwapRejected(OBSERVATIONS)`) and the series falls through to the next path.

**Alternatives considered.** RS-03 alone (only the "latest observation ≤ 900 s old" check): cheaper, but a single swap at 23:45 satisfies it; kept as the second half of this rule. Reading a sequencer uptime feed: none exists for this chain (D-005).

**Why.** Closes THREAT-MODEL T-03.4 and T-05.4. Uniswap `observe` linearly interpolates between stored observations, so a window with no swaps returns the last trade before the window as if it had held; that is a Friday price on a Sunday (the very thing D-001 rejected for Chainlink) and, after a sequencer outage, a stale price presented as fresh. Requiring observations inside the window turns both into a fall-through to path 3.

**Consequences.** SPEC §9.3 item 1, §9.5, `OracleParams.minObservationsInWindow`. Bounded backwards walk over `pool.observations` from `slot0.observationIndex`.

---

## D-020 · 2026-09-02 · Keeper monitors the stock-token beacon and USDG implementation; guardian pauses on change (RS-10)

**Decision.** The keeper stores the beacon implementation (`0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2`) and the USDG implementation (`0x68184c449e1a8f34fa18d289737129fd27b66f8f`) read at deploy, polls both every 5 minutes, and on any change pauses deposits and new auctions on all vaults with the guardian key and pages the founder. Unpause requires a human review of the new code (raw-unit `balanceOf`, no fee, no hooks, same decimals).

**Alternatives considered.** On-chain check of the implementation address in `settle`/`deposit`: would freeze the protocol on a benign upgrade with no way to review; rejected. Doing nothing: an upgrade that adds a transfer fee or UI-scaled `balanceOf` silently breaks accounting.

**Why.** Closes THREAT-MODEL T-11.4 (monitoring only; the risk itself is not mitigable). One beacon upgrades all nine tokens at once and its governance is unverified (SPEC §19).

**Consequences.** SPEC §9.5 (keeper monitoring paragraph), RUNBOOK.md checklist for reviewing an upgrade.

---

## D-021 · 2026-09-02 · Deterministic reference for TWAP sanity bounds: last Chainlink round at or before expiry (RS-04)

**Decision.** `refRound` = last valid Chainlink round with `updatedAt ≤ expiry`, any age, verified on-chain via `next(refRound).updatedAt > expiry`. It is the reference for the weekday TWAP fallback (3 %), the weekend TWAP bound (15 %) and the resolution band (D-022). "Latest answer at call time" is no longer used anywhere.

**Alternatives considered.** Latest answer at settle time (v0.1): flips from Friday's round to Monday's first round the moment it lands inside the 30-minute grace window, so path-2 validity depended on who called when.

**Why.** Closes THREAT-MODEL T-08.2. Settlement must not have a timing-dependent outcome that a bot can select.

**Consequences.** SPEC §9.1, §9.2, §9.3 item 2, §9.6. Keeper supplies `refRound` as a hint; `previewSettle` mirrors it.

---

## D-022 · 2026-09-02 · `resolveHalted` is bounded to ±25 % of the last valid oracle price; the bound is a constant (RS-13)

**Decision.** `resolveRef = refRound.answer` (D-021), or `sRef` if no valid round at or before expiry exists. `resolveBoundBps = 2 500` is a contract constant. `resolveHalted(seriesId, price8, evidenceURI)` reverts unless `0.75 × resolveRef ≤ price8 ≤ 1.25 × resolveRef`.

**Alternatives considered.** Unbounded (v0.1): with a single admin EOA and no canceller, a compromised key could halt a live series by parameter change and then resolve it at 100× spot, taking ~99 % of collateral, with depositors unable to exit a live series (THREAT-MODEL T-14.2). A timelocked parameter instead of a constant: the same key could widen it first; rejected.

**Why.** Closes T-14.2. Worst case with a 5 % OTM strike and a resolution at the top of the band is 16 % of collateral instead of total loss. A genuine move beyond 25 % between the last pre-expiry round and expiry is a case for the timelock to resolve at the band edge and document; that is a bounded, visible loss.

**Consequences.** SPEC §9.6, invariant I-11.

---

## D-023 · 2026-09-02 · Refunds and fee forwarding are pull-based; `clear` makes no outbound transfer (RS-06)

**Decision.** `clear` credits `refundable[bidder]` (escrow minus payment, or the full escrow for unfilled and skipped auctions) and credits the fee to `FeeRouter` as an internal balance. Bidders call `withdrawRefund(to)`; anyone calls `FeeRouter.flush(vaultId)` to forward fees to treasury. `clear` therefore contains no `safeTransfer` out.

**Alternatives considered.** Push refunds in the same transaction (v0.1): a single bidder address frozen by Paxos (`isFrozen`) or a paused USDG makes `clear` revert forever, leaving the series in AUCTION and the vault unable to reach IDLE. Try/catch around each transfer: works but leaves the escrow stranded and complicates I-3.

**Why.** Closes THREAT-MODEL T-07.3 and T-12.4. State transitions must never depend on a third party's willingness or ability to receive tokens.

**Consequences.** SPEC §8.2 steps 5, 7, 8; §11; §9.6; events `RefundCredited`, `RefundWithdrawn`; invariant I-3 revised.

---

## D-024 · 2026-09-02 · Option allocation is pull-based; no ERC-1155 mint inside `clear` (RS-07, as amended by the founder)

**Decision.** `clear` records `claimableOptions[seriesId][bidder]`; the bidder calls `claimOptions(seriesId, to)` to mint the ERC-1155. `OptionToken.claim` accepts an unminted allocation as well as tokens, so a bidder that never pulls still receives its payout.

**Alternatives considered.** RS-07 as proposed (reject contract bidders lacking `IERC1155Receiver` at `bid`, mint last in `clear`). The founder chose pull-based minting instead: it removes the callback from `clear` entirely rather than gating who may bid, and it is symmetric with D-023.

**Why.** Closes THREAT-MODEL T-07.4 (a non-receiver contract bidder reverting `clear`) and removes the only present-day reentrancy callback inside a state transition (T-16).

**Consequences.** SPEC §3, §8.2 step 6, §9.7 step 4; events `OptionsAllocated`, `OptionsClaimed`; invariant I-3 extended with the allocation identity.

---

## D-025 · 2026-09-02 · Per-vault jump guard: settlement price within ±30 % of `sRef` unless a multiplier change explains it (RS-05, as amended by the founder)

**Decision.** Every candidate settlement price on paths 1, 2 and 3 must satisfy `|S / sRef − 1| ≤ jumpBps` (per vault, default 3 000, timelocked within `[1 000, 5 000]`, snapshotted per series). Exception: if `uiMultiplier()` at settle differs from `multiplierAtOpen` and `oraclePaused()` is false, the multiplier-adjusted ratio `S × multiplierAtOpen / uiMultiplier()` is tested instead. A tripped guard fails that path; if all paths fail the series halts with `reason = JUMP_GUARD` and is resolved inside the D-022 band.

**Alternatives considered.** RS-05 as proposed (40 % vs the previous Chainlink round): the founder chose the reference spot at open, which is a fixed, already-stored value and also bounds paths 2 and 3. No guard (v0.1): a single bad Chainlink round settles a series at up to 75 % of collateral. No multiplier exception: rejected by the founder.

**Why.** Closes THREAT-MODEL T-02.1 and bounds T-14.2 further. On the allowlist (mega-caps, SPY, QQQ) a 30 % move inside one week is a market event worth a 48 h human look; the cost of a false halt is a delayed, bounded resolution.

**Recorded caveat on the exception.** Under ERC-8056 the Chainlink feed prices one raw token as share price × `uiMultiplier`, so a correctly sequenced split or dividend does not move `S` and passes the plain check. The exception can therefore only admit a price that moved by the multiplier ratio, which is precisely the feed/multiplier mis-sequencing of THREAT-MODEL T-10.2. Because D-026 refuses to open a series across a staged change, the exception can only apply to a change staged after open. The keeper alerts on any `UIMultiplierUpdated` inside a live series and the guardian pauses new auctions until that settlement has been reviewed. Revisit after the first observed corporate action on a live series.

**Consequences.** SPEC §9.1, §9.2, §9.3, §9.6, §10.3; `OracleParams.jumpBps`; event `JumpGuardTripped`; invariant I-10.

---

## D-026 · 2026-09-02 · `openAuction` refuses a series that spans a staged multiplier change (RS-09)

**Decision.** `openAuction` reverts with `MultiplierChangeInsideSeries` when `token.effectiveAt() != 0 && token.effectiveAt() ≤ expiry`.

**Alternatives considered.** Keeper-only check: a forgotten check is exactly the failure mode. Adjusting the strike at settlement: rejected in D-002 (double counting).

**Why.** Closes THREAT-MODEL T-10. Skipping one series around a corporate action costs a week of premium and avoids the only case where the feed can be transiently wrong by the split ratio.

**Consequences.** SPEC §5 (a), §7.2, §10.3. Mock stock token needs settable `effectiveAt`.

---

## D-027 · 2026-09-02 · Curator floors on strike distance and reserve price; reserve floor is never zero (RS-11)

**Decision.** Per vault and per series kind: `minStrikeDistanceBps[kind]` (defaults to the protocol lower bound 300 / 100, curator may raise within the protocol bounds) and `minReserveBpsOfSpot[kind]` (protocol range `[1, 500]`, defaults 10 bps WEEKDAY / 3 bps WEEKEND). `openAuction` enforces both. Defaults for the reserve floor are placeholders to be tuned against the implied-vol model before mainnet.

**Alternatives considered.** Reserve floor default 0 (v0.1): a rogue or careless keeper could sell 3 %-OTM weekly calls for nothing. Protocol-wide floors only: asset classes differ too much (ETF weekend calls are worth a few bps).

**Why.** Closes THREAT-MODEL T-13.1 and T-19. The curator is bonded; the keeper is a hot key.

**Consequences.** SPEC §7.2, §8.3, §15 parameter list.

---

## D-028 · 2026-09-02 · `openAuction` is gated by `KEEPER_ROLE`; everything else in the lifecycle is permissionless

**Decision.** Only `KEEPER_ROLE` may call `openAuction`. `clear`, `settle`, `halt`, `processDeposits/Redeems`, `flush`, `withdrawRefund`, `claimOptions`, `resolveHaltedByOracle` are permissionless. Role grant/revoke is timelocked.

**Alternatives considered.** Permissionless `openAuction`: anyone could open with the minimum distance and reserve at any moment inside the tolerance window. Gating settlement too: would make liveness depend on the keeper key.

**Why.** THREAT-MODEL T-13.4: the spec implied but did not state the gate. Liveness must never depend on the keeper; parameter choice must.

**Consequences.** SPEC §2, §5, §7.2, §15.

---

## D-029 · 2026-09-02 · Second guardian key held off-server by the founder (RS-12, amends D-012)

**Decision.** `GUARDIAN_ROLE` has two holders: the hot key on the keeper server (D-012) and a hardware-wallet or phone signer held by the founder, never on the server. Either can pause; either can unpause the other's pause.

**Alternatives considered.** Hot key only (D-012): a compromised server holds both the keeper and the guardian key, so nobody can pause a rogue keeper during the 48 h it takes the timelock to revoke `KEEPER_ROLE`.

**Why.** Closes the residual of THREAT-MODEL T-13 and T-15. Adds one role grant at deploy and no ceremony: the founder key is used only in an incident.

**Consequences.** SPEC §2, §15. If OQ-001 (canceller) is ever adopted, the canceller must not be a guardian key.

---

## D-030 · 2026-09-02 · MM bond locks by participation, not by option-token balance (RS-08)

**Decision.** `AuctionHouse.bid` calls `BondManager.lock(bidder, seriesId)` on the bidder's first bid in a series. The lock is released at `clear` for bidders with no fill and at SETTLED/RESOLVED for filled bidders. `withdrawBond` requires zero active locks plus the 7-day cooldown. Curator locks: one per live series of the curator's vault.

**Alternatives considered.** "No unclaimed option tokens in LIVE series" (v0.1): escapable by transferring the tokens to another address, after which a manipulator (THREAT-MODEL T-03) has nothing at stake.

**Why.** Closes T-07.6. Bonded bidders only mitigate griefing and manipulation if the bond is actually at stake for the life of the series.

**Consequences.** SPEC §8.1, §13; events `BondLocked`, `BondUnlocked`; invariant I-13.

---

## D-031 · 2026-09-02 · Oracle parameters are snapshotted into the series at `openAuction` (RS-14)

**Decision.** `Series.params` (`OracleParams`: `weekdayMaxStale`, `twapGrace`, `weekendTwapBoundBps`, `weekdayTwapBoundBps`, `swapNotionalUSDG`, `impactBps`, `minObservationsInWindow`, `jumpBps`, `sequencerFeed`, `sequencerGrace`, USDG band and staleness) is copied from vault configuration at open and never changes. A timelocked parameter change applies only to series opened after execution.

**Alternatives considered.** Live parameters read at settle (v0.1): a change queued Monday executes Wednesday while the weekday series is LIVE and depositors have no exit until Friday's settlement, which the change itself governs.

**Why.** Closes THREAT-MODEL T-14.1. Every vault is IDLE between series (at least the Sunday→Monday window), so depositors always get a withdrawal window between seeing a queued change and the first series it applies to. This is what makes the 48 h delay an actual protection.

**Consequences.** SPEC §6, §9.1, §15; invariant I-12.

---

## D-032 · 2026-09-02 · `requestDeposit` allowed in any state; executes at the next IDLE; `openAuction` never requires an empty queue (RS-16, as amended by the founder)

**Decision.** `requestDeposit` is allowed in every vault state. `processDeposits` runs whenever the vault is IDLE (share price is constant inside IDLE, I-8). `openAuction` executes up to `maxQueueOpsPerOpen` (50) queued deposits and then opens regardless of any remaining queue; the remainder executes at the next IDLE. `requestRedeem` stays outside-IDLE only (use `redeem` in IDLE).

**Alternatives considered.** RS-16 as proposed (revert `requestDeposit` in IDLE). The founder chose to allow it in any state, which is simpler for integrators and equally removes the blocking condition, since `openAuction` no longer checks the queue at all.

**Why.** Closes THREAT-MODEL T-18: with v0.1's "queue must be empty" rule, a dust request in the block before Monday 14:00 UTC reverted `openAuction` for the cost of gas, repeatably, on a 100 ms FCFS chain.

**Consequences.** SPEC §4.3, §5 (a); invariant I-6 revised (queued deposit executions occur only in IDLE).

---

## D-033 · 2026-09-02 · Permissionless resolution of a halted series after 7 days, clamped into the resolution band (RS-15, as amended by the founder)

**Decision.** `resolveHaltedByOracle(seriesId, roundHint)` is callable by anyone once `now ≥ expiry + haltedTimeout` (constant, 7 days). It takes the first valid Chainlink round after expiry (any lateness, verified with `prev`, `oraclePaused() == false`), clamps the answer into the D-022 band, sets `settlementPath = 5` and finishes settlement. Before the timeout only the timelock can resolve.

**Alternatives considered.** RS-15 as proposed (reject if outside the band): could leave a series halted forever if the feed returns far from the reference and the admin key is lost; the founder chose clamping so resolution is always possible without any key. Timelock-only resolution (v0.1): loss of the single admin key plus one halt locked the vault permanently.

**Why.** Closes THREAT-MODEL T-14.7 and T-11.6. Most halts are oracle outages that end within days; the admin should not be on the happy path, and its loss must not be fatal.

**Consequences.** SPEC §9.6, §15 constants; event `SeriesResolvedByOracle`; invariants I-11, I-14.

---

## D-034 · 2026-09-02 · `sunset(vaultId)` migration path exists from day one; core stays immutable (THREAT-MODEL T-17)

**Decision.** No proxies, no `delegatecall` in fund-holding contracts, every cross-contract reference `immutable`. `sunset(vaultId)` behind the timelock is irreversible: after the current series settles or resolves, the vault refuses `openAuction` forever, stays IDLE with `withdraw/redeem` open, and rejects new deposits. A v2 is a new deployment; the frontend offers withdraw-then-deposit.

**Alternatives considered.** UUPS or transparent proxies behind the timelock: with a single admin EOA the proxy makes the key owner of all code, and T-14 shows live-series depositors have no exit; adds initializer and storage-layout risk; stacks a third layer of upgrade risk on top of the issuer's beacon and the chain's 7/8 council. Immutable without a sunset function: migration would rely on the guardian pause alone, which is reversible and not a signal.

**Why.** THREAT-MODEL T-17. Migration is cheap here: single-asset ERC-4626 shares, no lock, weekly IDLE windows, 7-day bond cooldown.

**Consequences.** SPEC §3, §15; event `VaultSunset`; invariant I-15; CI grep for proxy imports in `src/`.

---

## D-035 · 2026-09-02 · Inflation-attack guard is the OpenZeppelin virtual-share offset (6), not a burned seed deposit

**Decision.** `CoveredCallVault` overrides `_decimalsOffset()` to return 6: every share computation uses `totalSupply + 1e6` virtual shares and `totalAssets + 1` virtual asset. Shares have 24 decimals. No dead-address deposit, no deployer seed transaction.

**Alternatives considered.** (1) Minimum initial deposit burned to `address(0xdead)` (Uniswap v2 style). Rejected: needs a funded seed transaction per vault at deploy (nine vaults, stock tokens the deployer must first acquire), creates a privileged first depositor path in the factory, and the burned amount is a permanent, visible loss that a reviewer has to explain per vault. (2) Offset 3 (the OZ documentation example). Rejected: 1e3 still leaves a profitable attack against a small first depositor at a 25 000 USDG cap. (3) Requiring `shares > 0` on deposit. Not needed with offset 6 and would turn dust deposits into reverts.

**Why.** THREAT-MODEL T-06. With offset 6 an attacker must donate 1e6 × the amount they hope to strand and receives back at most deposit + donation; the victim's loss is bounded by one share unit = donation / 1e6. Encoded as `testFuzz_inflationAttack_unprofitable` and `testFuzz_depositRedeemRoundTrip_neverProfits`. Cost: at most 1 wei of rounding per operation in the vault's favour.

**Consequences.** SPEC §4.1 (unchanged text, now implemented); share `decimals() == 24`; premium accumulator precision raised to 1e36 (SPEC §4.2) because 24-decimal shares would otherwise truncate up to 1 USDG per token-worth of shares.

---

## D-036 · 2026-09-02 · Queued redeems escrow the shares in the vault; escrowed shares earn no premium

**Decision.** `requestRedeem(shares, receiver)` transfers the shares to the vault contract itself. The vault's own balance is `escrowedRedeemShares`; it is skipped by the premium hook and excluded from the premium denominator at clearing: `accPremiumPerShare += premiumNet × 1e36 / (totalSupply − balanceOf(vault))`. `cancelRedeem` transfers them back; `processRedeems` burns them from the vault's balance.

**Alternatives considered.** (1) Per-account `lockedShares` mapping checked in `_update`. Rejected: a second balance the ERC-20 transfer path must consult on every transfer, more storage, more ways to get the premium bookkeeping wrong. (2) Escrow but keep paying premium to escrowed shares via a per-request checkpoint. Rejected: requires a second accumulator per request for a 15-minute edge case.

**Why.** Escrow makes locked shares non-transferable with zero extra bookkeeping and matches the ERC-7540 pattern. Premium exclusion is consistent with D-009: requests present at open are excluded from `offeredQty`, so those shares bear no option risk and should earn nothing. Edge case, documented in SPEC §4.3: a request filed inside the 15-minute AUCTION window (after `offeredQty` was fixed) still sits inside `offeredQty` if the clear fills it, so it bears the series outcome but forfeits the premium. Only the requester loses; nobody can profit from it; the requester can `cancelRedeem` before the clear.

**Consequences.** SPEC §4.2, §4.3; `pendingRedeemAssets()` view; invariant `balanceOf(vault) == escrowedRedeemShares`; test `test_premium_escrowedRedeemSharesExcluded`.

---

## D-037 · 2026-09-02 · A queued deposit that no longer fits the cap at execution is EXPIRED and refundable; the FIFO never blocks

**Decision.** `processDeposits` walks the FIFO. A request larger than the remaining cap is marked `EXPIRED`, its tokens stay counted in `queuedDepositTokens`, and the requester reclaims them with `cancelDeposit`. Processing continues with the next request. Processing stops (without expiring anything) when no cap price is available, deposits are paused or the vault is sunset. No ERC-20 transfer happens inside processing.

**Alternatives considered.** (1) Stop at the first request that does not fit. Rejected: one large request blocks every later one until its owner acts (griefing for the cost of gas, same shape as T-18). (2) Partial fill up to the cap. Rejected: leaves a remainder request and a second share price for the same request; more state for little value at a 25 000 USDG cap. (3) Refund by transfer inside processing. Rejected: T-11 (settle performs no transfers; a paused or blocked token would revert settlement).

**Consequences.** SPEC §4.3; status enum `{QUEUED, EXECUTED, CANCELLED, EXPIRED}`; event `DepositRequestExpired`.

---

## D-038 · 2026-09-02 · Only the vault mints and burns option tokens; `mintOptions` is the AuctionHouse's pull step

**Decision.** `OptionToken.create/mint/burn/markSettled` are callable only by the vault registered for the underlying (`registerVault`, one per underlying, irreversible, timelock-owned). `mintSeries` (at clear) only encumbers `filledQty` and pulls premium; it mints nothing. `AuctionHouse.claimOptions` calls `vault.mintOptions(seriesId, bidder, qty)` with cumulative mints bounded by `filledQty`. `OptionToken.claim` burns and calls `vault.payOptionClaim`, which transfers the stock-token payout directly from the vault.

**Alternatives considered.** Granting the AuctionHouse a mint role on `OptionToken`. Rejected: two minters for one supply; the coverage bound `Σ minted ≤ filledQty` would live outside the contract that owns the encumbrance.

**Why.** Keeps D-024 (no ERC-1155 mint inside `clear`) and puts the only supply bound next to the only encumbrance bound, so invariant I-3 (`totalSupply + claimed == minted ≤ filled`) is checked in one place.

**Consequences.** SPEC §3 call graph, §8.2 step 6 wording, §9.7; the unminted-allocation claim of §8.2 is implemented in AuctionHouse as `mintOptions` followed by `claim` in one transaction.

---

## D-039 · 2026-09-02 · `CapController.priceSource` is settable by the timelock until SettlementOracle ships

**Decision.** `CapController` reads `S_cap` through an `IPriceSource` reference that the timelock can change. Everything else in the vault layer is `immutable`.

**Alternatives considered.** Making it immutable now and redeploying `CapController` when `SettlementOracle` exists. Rejected: the vault's `capController` reference is immutable, so that redeploy would force a vault redeploy too.

**Why.** Temporary exception to the "every cross-contract reference is immutable" rule of SPEC §3, confined to a contract that holds no funds and can only lower or raise deposit headroom. To be revisited: once `SettlementOracle` is deployed, either freeze the setter (one-way `freezePriceSource`) or redeploy before mainnet.

**Consequences.** SPEC §12 note; OQ-003 in SPEC §18.

---

## D-040 · 2026-09-02 · The coverage re-check at clearing is against `totalAssets()`, not `freeAssets()` (review finding)

**Decision.** `mintSeries` requires `filledQty ≤ offeredQty` and `filledQty ≤ totalAssets()`. Redeem requests filed during the 15-minute AUCTION window do not reduce what the AuctionHouse may fill.

**Alternatives considered.** The v0.3 implementation checked `filledQty ≤ freeAssets()` (`totalAssets − encumbered − pendingRedeemAssets`). Rejected by the independent review: with D-009 (100 % of the balance offered) any `requestRedeem` of ≥ 1e6 shares (1e-12 token) during the window makes a full clear revert, so a griefer could kill every auction for gas and cancel afterwards.

**Why.** The check is not needed for I-1: pending redeems stay inside `totalAssets` until they are processed, which happens only after `encumbered −= filledQty` at settlement, so encumbering the full offer never breaks coverage. The only legitimate reason for `totalAssets() < offeredQty` between open and clear is an issuer burn (SPEC §2), which the new check still catches (`InsufficientCoverage`). Consistent with D-036: an AUCTION-window request stays inside `offeredQty` and bears the series outcome.

**Consequences.** SPEC §4.1; error renamed `InsufficientCoverage(qty, available)`; `test_T11_mintSeriesRevertsAfterIssuerBurnBetweenOpenAndClear`.

---

## D-041 · 2026-09-02 · Queue-processing hardening after the independent review (T-18, T-11, T-12, T-07.8)

**Decision.**
1. Every visited queue entry, including CANCELLED/EXECUTED/EXPIRED ones that are merely skipped, counts against the `n` bound in `_processDeposits` and `_processRedeems`.
2. The cap read inside `_processDeposits` is wrapped in `try/catch`; a reverting `CapController`/`IPriceSource` stops deposit execution instead of reverting `settleSeries` or `openSeries`.
3. When the remaining cap headroom is 0, processing stops; a request is EXPIRED only when headroom exists but the request is larger than it.
4. `MAX_QUEUE_OPS = 100` (was 200), gas-measured: 100 redeems + 100 deposits inside one `settleSeries` cost **9.71 M gas** on 2026-09-02 (`test_T07_settleGasAtMaxQueueOps`, asserted < 20 M; Arbitrum per-tx limit 32 M). Defaults stay 50/50 (~5 M).
5. `settleSeries` cross-checks the path against the series state: LIVE accepts paths 1–3, HALTED accepts 4–5.
6. Shares can never be transferred, minted or deposited to the vault address except through `requestRedeem` escrow; `requestDeposit`/`requestRedeem` reject `receiver == vault`.
7. `CapController.setSafetyModule(0)` reverts while `SAFETY_MODULE` mode is active.

**Alternatives considered.** (1) Leaving skips uncounted (v0.3): the reviewer showed ~14 000 cancelled 1-wei entries (~$100–300 of gas on an Orbit chain) push `settleSeries` past the block gas limit and lock the vault in LIVE forever, re-opening T-18 in a worse form. (2) Removing queue processing from `settleSeries` entirely: rejected for now, keeps SPEC §4.3 UX; the try/catch and the bound make settlement independent of the queue contents and of the cap oracle. (3) Expiring every request when the cap is full (v0.3): lets anyone deposit-to-cap, process, withdraw, and mass-expire the queue; stopping instead matches the D-037 text.

**Why.** Settlement liveness must depend on nothing a third party controls (T-11, T-12); queue bounds must be measured (T-07.8); state-machine holes are cheap to close; stranded shares in the vault would break I-16.

**Consequences.** SPEC §4.3, §4.4, §9.6; new tests `test_T18_cancelledEntriesDoNotBlockSettle`, `test_T12_settleSurvivesRevertingPriceSource`, `test_T14_settlePathMustMatchState`, `test_T09_sharesCannotBeSentToVault`, `test_T07_settleGasAtMaxQueueOps`; handler actions `massCancel`, `setCap`, `issuerBurn`, `issuerPauseToggle`, `sunsetVault`, `setMaxQueueOps`, `transferShares`, reentrant receiver.

---

## D-042 · 2026-09-02 · D-026 check reads `effectiveAt` as "inside (now, expiry]"; ERC-8056 tokens keep a past `effectiveAt` (cast-verified)

**Decision.** `canOpenAuction` refuses a series only when `token.effectiveAt() > block.timestamp && effectiveAt ≤ expiry`. A non-zero `effectiveAt` in the past does not block.

**Alternatives considered.** v0.3 implemented `effectiveAt != 0 && effectiveAt ≤ expiry` (the wording of SPEC §5 (a) and §7.2). The reviewer flagged that a token which keeps the last effective timestamp after applying the multiplier would block the vault forever. `cast call` against AAPL (`0xaF3D…93f9`) on 2026-09-02 returned `effectiveAt() = 1786720366` (2026-08-14, in the past) with `uiMultiplier() == newUIMultiplier() == 1.000566080061092436`: the field is indeed retained. With the v0.3 check an AAPL vault could never have opened.

**Why.** SPEC §10.3 already said "inside `(now, expiry]`"; §5 and §7.2 were the inconsistent lines and are corrected.

**Consequences.** SPEC §1.2 (AAPL reads), §5 (a), §7.2; `test_T10_pastEffectiveAtDoesNotBlockOpen`. All three vault-layer contracts also moved to `Ownable2Step` so a mistyped `transferOwnership` cannot orphan `setSunset`/`registerVault` (reviewer finding, CLAUDE.md rule 5).
