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

---

## D-043 · 2026-09-03 · `premiumGross` is the sum of the floored per-bid payments, so escrow conservation is exact

**Decision.** At clearing every filled bid pays `floor(filledQty_i × clearingPrice / 1e18)` and `premiumGross := Σ payments_i`; `fee = floor(premiumGross × feeBps / 1e4)`, `premiumNet = premiumGross − fee`. Therefore `Σ refund_i + premiumNet + fee == Σ escrow_i` to the unit, `USDG.balanceOf(AuctionHouse) == Σ open escrow + Σ refundable` exactly, and no USDG is ever stranded in the AuctionHouse.

**Alternatives considered.** v0.3 wrote `premiumGross = filledQty × clearingPrice / 1e18` (§7.3, §8.2 step 5). That product exceeds the sum of the per-bid floors by up to `#filled bids − 1` units, which is where I-3's "sub-unit dust excluded" and T-09.2's "dust stays in the AuctionHouse" came from; paying the product would dip into other bidders' refunds.

**Why.** An invariant that is exact is cheaper to test and impossible to mis-account; the difference is at most 63 × 1e-6 USDG per auction and stays with the bidders.

**Consequences.** SPEC §7.3, §8.2 steps 5 and 7, §17 I-3; THREAT-MODEL T-09.2; `AuctionCleared.premiumGross` carries the sum; `testFuzz_T09_escrowRefundPaymentConserve`, `invariant_I3_escrowExact`, `invariant_I3_closedConservation`.

---

## D-044 · 2026-09-03 · `BondManager.auctionHouse` and `FeeRouter.auctionHouse` are set once after deployment

**Decision.** The AuctionHouse holds `bondManager` and `feeRouter` as immutables; the two of them hold `auctionHouse` in a storage slot that the owner sets exactly once (`setAuctionHouse`, reverts `AlreadySet`; `lock/unlock/initVault/collect` revert `NotAuctionHouse` while unset, so mis-wiring fails at the first bid). Deployment order: BondManager, FeeRouter, AuctionHouse, `setAuctionHouse` on both, then the vaults (whose `auctionHouse` is immutable), then `AuctionHouse.registerVault`.

**Alternatives considered.** (1) Predicting the AuctionHouse address with `vm.computeCreateAddress` and passing it as an immutable: fragile to a burned nonce. (2) An atomic deployer contract creating all three in one constructor: removes the window but adds a contract for one-off use. (3) Making the AuctionHouse side settable instead: rejected, it is the fund-holding contract.

**Why.** Two immutables cannot point at each other. Set-once on the two admin-ish contracts is the same pattern as `OptionToken.registerVault` and `CapController.priceSource` (D-039).

**Consequences.** SPEC §3 note on immutables; `test_setAuctionHouse_onceOnly`, `test_constructor_andWiring`; deploy script and fork test must assert the wiring.

---

## D-045 · 2026-09-03 · `clear` takes the skip path whenever `mintSeries` could not succeed; the vault never stays in AUCTION

**Decision.** `clear(seriesId)` skips (all escrow refundable, all bond locks released, `vault.skipSeries`) in four cases: no bid; `min(offeredQty, totalAssets()) == 0`; `block.timestamp ≥ expiry`; the premium would be non-zero but every share is escrowed for redeem (`totalSupply() == balanceOf(vault)`, which would revert `NoSharesForPremium`). Otherwise the fill is bounded by `remaining = min(offeredQty, totalAssets())`, so an issuer burn between open and clear cannot revert `mintSeries` with `InsufficientCoverage`.

**Alternatives considered.** Calling `mintSeries` with `premiumNet = 0` in the all-escrowed case: gives the MMs free options. Letting a late `clear` proceed after `expiry`: a weekend series cleared after Monday 15:00 UTC is guaranteed to halt (both oracle paths' deadlines passed) and a weekday one settles on a stale reference. Reverting in these cases: leaves the series in AUCTION forever, the exact liveness failure D-023/D-024 exist to prevent.

**Why.** CLAUDE.md: "when unsure, choose the safer option". A skipped week costs one premium; a stuck vault costs everything.

**Consequences.** SPEC §8.2 step 8 rewritten; `previewClear` returns `willSkip`; tests `test_clear_skipAfterExpiry`, `test_clear_skipWhenAllSharesEscrowed`, `test_clear_coverageCapAfterIssuerBurn`, `test_clear_skipWhenNothingCoverable`, `invariant_openAuctionMatchesVaultState`. Residual: a paused USDG makes `clear` revert until unpause (fee transfer and `mintSeries` pull); unavoidable and documented in §8.2 and `test_T12_clearWaitsForUsdgUnpause`.

---

## D-046 · 2026-09-03 · `auctionOpen = block.timestamp`; the weekend open window is anchored to Friday

**Decision.** The keeper no longer supplies `auctionOpen`; `openAuction` uses `block.timestamp` and validates it against the §5 schedule with epoch-week arithmetic (`ws = now − now mod 604800`, epoch weeks start Thursday 00:00 UTC, so a Friday and the following Sunday share a week). WEEKDAY: `|off − Mon 14:00| ≤ openTolerance` (≤ 4 h) and `expiry − (ws + WEEK) ∈ [Fri 19:30, Fri 21:30]` (keeper still supplies expiry because of DST). WEEKEND: `off ∈ [Fri 19:40, Fri 21:40 + openTolerance]`, `expiry == ws + Sun 23:59:00`, and if the vault had a weekday series expiring this week, `now ≥ that expiry + 600 s`. No `expiry > lastExpiry` check: a skipped auction may be re-opened inside the same window (T-05.1).

**Alternatives considered.** "`expiry mod week == Sun 23:59` and `expiry − now < 3 days`": lets a keeper open a weekend auction on Saturday night, a 3-hour option at the 100 bps floor with a 3 bps reserve (T-13/T-19). Keeper-supplied `auctionOpen`: one more value to validate for no benefit.

**Why.** The window checks are the only thing standing between a hot keeper key and selling short-dated calls for nothing.

**Consequences.** SPEC §5 (a), (d); `AuctionHouse.canOpen`, `scheduledExpiry`; `test_open_weekdayWindow`, `test_open_weekendStandaloneWindow`, `test_T13_weekendCannotOpenOutsideFridayWindow`, `test_T05_retryOpenAfterSkipInSameWindow`.

---

## D-047 · 2026-09-03 · `S_ref == S_cap` through `IPriceSource` until SettlementOracle ships; the D-031 snapshot waits for it

**Decision.** `AuctionHouse.priceSource` is an `IPriceSource` settable by the owner (same exception as D-039). Until SettlementOracle implements the §7.2 reference-price rules (Chainlink ≤ 26 h, else TWAP within 15 %), `S_ref` is whatever `capPrice(vault)` returns. The `OracleParams` snapshot of D-031 is not taken by the AuctionHouse: there is no oracle configuration to copy yet. SettlementOracle will keep a versioned parameter history per vault and select the version by `auctions(seriesId).auctionOpen`, which is exposed for that purpose.

**Alternatives considered.** A settlement hook called from `openAuction`: adds a cross-contract call inside a state transition for a contract that does not exist. Keeper-supplied strike: violates §7.2 "never keeper-supplied".

**Why.** Keeps the AuctionHouse fully immutable except for the one temporary reference, and keeps I-12 satisfiable by construction (`auctionOpen` never changes).

**Consequences.** SPEC §3 immutables note, §6 storage split (`params` moves to SettlementOracle), §7.2; OQ-004 in §18: freeze or redeploy once SettlementOracle exists.

---

## D-048 · 2026-09-03 · Pro-rata dust is carried across the marginal group in bidId order, each bid capped at its qty

**Decision.** At the marginal price, `fill_i = floor(qty_i × remaining / total)`; the rounding dust goes to the earliest `bidId` of the group up to its remaining headroom, then to the next, and so on. Because `Σ (qty_i − fill_i) ≥ dust`, the carry always terminates inside the group and `Σ fills == remaining` exactly.

**Alternatives considered.** SPEC v0.3 "dust to the earliest bidId" alone: with one large bid and many 0.1-option bids at the clearing price the earliest bid's headroom can be 1 unit while the dust is up to 63 units, so the earliest bid would be over-filled.

**Why.** Deterministic, still favours the earliest bidder, never over-allocates (I-1).

**Consequences.** SPEC §8.2 step 4; `testFuzz_T07_proRataMarginalFillConservesQty` (dust receivers form a prefix in bidId order), `test_clear_tieDustToEarliestBid`.

---

## D-049 · 2026-09-03 · Independent review of the auction layer: one OptionToken per AuctionHouse, fee pull, wiring asserts

**Decision.** A fresh-context review of commits `5684416`/`298cbb6` (1 High, 3 Medium, 6 Low) led to:
1. **One `OptionToken` per AuctionHouse (High).** `_auctions` is keyed by `seriesId`, which is allocated by the OptionToken counter. A vault on a second OptionToken would reuse id 1 and overwrite another vault's live auction (escrow mixed, the first vault stuck in AUCTION forever; reproduced by the reviewer). `optionToken` is now an immutable of the AuctionHouse, `registerVault` reverts `WrongOptionToken` on any other, and `_record` reverts `SeriesIdInUse` as a belt-and-braces check.
2. **Fee is pulled, not pushed (Medium).** `clear` no longer transfers the fee to the FeeRouter; it books it with `collect` while the USDG stays in the AuctionHouse (standing approval granted in the constructor), and `FeeRouter.flush` pulls it with `safeTransferFrom(auctionHouse, treasury, amount)`. A Paxos-frozen FeeRouter can therefore not revert `clear` (the v0.4 text promised this, the code did not deliver it). I-3 becomes `balanceOf(AuctionHouse) == Σ open escrow + Σ refundable + Σ FeeRouter.pending`.
3. **Wiring asserted early (Low).** The constructor checks `bondManager.usdg()` and `feeRouter.usdg()`; `registerVault` checks `vault.usdg()`, `bondManager.auctionHouse() == this` and `feeRouter.auctionHouse() == this`. A set-once mistake (D-044) is caught at registration instead of at the first bid, when the vaults' immutable `auctionHouse` can no longer be changed.
4. **`feeBps` snapshotted at open** into `Auction.feeBps` (D-031 principle): a timelocked fee change applies from the next auction, never to bids already placed.
5. `withdrawRefund(to)` and `claimPayout(to)` reject `to == address(this)` like `claimOptions` (stranding funds inside the AuctionHouse would break the exact I-3).
6. `BondManager.activeLocks` gates the MM bond only; a curator bond of the same account is withdrawable while its MM bond is locked. Per-series curator locks (SPEC §13) arrive with VaultFactory.
7. Weekend open window capped at `Friday 21:40 + min(openTolerance, 2 h)` (`MAX_WEEKEND_LATE`), so it never reaches Saturday whatever the tolerance.
8. Tests: `test_T16_erc1155CallbackCannotReenterVaultOrAuction` was vacuous (every attempt failed a precondition); it now uses `ReentrantActor`, which holds a refund, an allocation and premium-bearing shares, asserts `ReentrancyGuardReentrantCall` on each attempt and proves the same calls succeed outside the callback. The same actor bids in the invariant handler (`invariant_T16_noReentrancy`). Added `test_T12_clearSucceedsWhenFeeRouterFrozen`, `test_T13_noRoleAdminExists`, `test_registerVault_rejectsForeignOptionToken`, `test_registerVault_rejectsMiswiring`, `test_twoVaultsOneOptionToken`, `test_clear_feeBpsSnapshottedAtOpen`, `test_haltedThenResolved_claimsAndLocks`, `test_bid_onSkippedAuctionReverts`, `test_locks_gateMMBondOnly`, `test_flush_pullsFromAuctionHouse`, `test_handlerReachesEveryState` (deterministic coverage of the invariant handler); auction invariants run at depth 64; the tautological fee assertion was replaced by the snapshotted-rate identity.

**Accepted, recorded, not changed.**
- A depositor holding every share can `requestRedeem(all)` during the 15-minute window and force the skip path after seeing the bids (a free look; MMs are refunded, nobody loses funds, the depositor forfeits its own premium). Fixing it means rejecting `requestRedeem` in AUCTION, which reverses D-036/D-040; left for the founder.
- No account holds `DEFAULT_ADMIN_ROLE`; `grantRole`/`revokeRole` are dead for everyone and `setKeeper` (owner = timelock) is the only role mutation (D-028).
- A pro-rata fill smaller than `1e18 / clearingPrice` wei pays 0 units; a few wei of options for free per auction, economically nil.
- `renounceOwnership` is not overridden (same status as the vault layer; the timelock is the only owner).

**Why.** CLAUDE.md rule 2 and 5; a second OptionToken is one deploy-script mistake away and the failure mode is a permanently frozen vault.

**Consequences.** SPEC §3, §5 (d), §8.2 steps 6-7, §9.7 step 4, §11, §13, §16.1, §17 I-3; THREAT-MODEL T-09/T-12/T-13 test names; `AuctionHouse` constructor takes `optionToken`; deployment order unchanged.

Scope recorded with D-043…D-048: BondManager implements MM and curator bonds in USDG with participation locks, cooldown and timelock slashing; per-series curator locks (VaultFactory phase), the WRITE migration (D-007) and the off-chain attestation stay out. FeeRouter implements the USDG mode; `setFeeMode(WRITE)`, `depositWrite`, `withdrawWrite` revert `WriteNotLaunched` while `writePool == address(0)` (D-016). Measured 2026-09-03: `clear` with 64 distinct bidders and a marginal pro-rata group costs **4.09 M gas**, the skip path with 64 bids **2.04 M** (`test_T07_clearGasUnder6M`, `test_T07_skipGasUnder6M`, bound 6 M).

---

## D-050 · 2026-09-03 · RiskModule: guardian role, `ALL` sentinel, halt hook, versioned oracle parameters

**Decision.** `RiskModule` (`contracts/src/RiskModule.sol`) is `Ownable2Step` (owner = timelock) plus `AccessControl` with a single `GUARDIAN_ROLE` and no `DEFAULT_ADMIN_ROLE` holder (`setGuardian(account, bool)` by the owner, the `setKeeper` pattern of D-028). Guardian functions are `pauseDeposits`, `unpauseDeposits`, `pauseNewAuctions`, `unpauseNewAuctions`, each taking a vault or `ALL = address(0)`; they are idempotent, write exactly one flag and are callable by either guardian or the owner. `ALL` dominates the per-vault flag; unpausing `ALL` leaves per-vault flags in place. The oracle parameters of SPEC §6 (`OracleParams`, now in `Types.sol`) live in the RiskModule as append-only versions per vault; `paramsAt(vault, auctionOpen)` returns the version in effect when a series opened, `currentParams(vault)` the one a series opened in the next block would get. `setSettlementOracle` is set-once (D-044); the oracle calls `pauseNewAuctionsOnHalt(vault, seriesId, reason)` on every halt, which also writes a `lastHalt` record and `haltCount`.

**Alternatives considered.** Parameters in SettlementOracle keyed by `auctionOpen` (D-047 wording): same snapshot semantics, but it mixes timelocked configuration with permissionless settlement logic in the largest contract (SettlementOracle is 22.5 KB). A global default version: rejected, every vault is configured explicitly and the protocol defaults apply until then.

**Why.** Founder choice (2026-09-03): configuration and pauses in one small contract, settlement logic in another; invariant I-7 becomes a storage-diff check (`vm.record`) that a guardian call writes nothing but a pause flag.

**Consequences.** SPEC §6, §15, §16; `IRiskModule` gains `paramsAt`, `currentParams`, `settlementOracle`, `pauseNewAuctionsOnHalt` (the vault-facing views are unchanged, the vault is not redeployed); `test/RiskModule.t.sol` (bounds, versioning, I-7, a real 48 h `TimelockController` proving I-12), `invariant_I7_guardianScope`.

---

## D-051 · 2026-09-03 · Jump guard accepts the plain check OR the multiplier-adjusted check

**Decision.** `|S / sRef − 1| ≤ jumpBps` accepts; otherwise, if `uiMultiplier()` at settle time differs from `multiplierAtOpen`, `|S × multiplierAtOpen / m_now / sRef − 1| ≤ jumpBps` accepts.

**Alternatives considered.** D-025 as written ("the guard *instead* accepts …"): under ERC-8056 a correctly sequenced 4-for-1 split leaves the raw-token price unchanged, so the adjusted ratio would be 0.25 and the guard would trip on the honest case. I-10 (SPEC §17) was already written as an OR.

**Why.** The exception exists only to admit the feed/multiplier mis-sequencing of T-10.2; it must not reject the correctly sequenced case.

**Consequences.** SPEC §9.1 wording; `testFuzz_jumpGuardBoundary`, `test_T10_split4xMidSeries_payoutUnchanged`, `test_T10_split4x_feedMovedByRatio_acceptedByException`, `test_T10_feedMoved4xWithoutMultiplierChange_tripsGuard`, `invariant_I10_jumpGuard`.

---

## D-052 · 2026-09-03 · Depth rule and price formula are orientation-specific; `√(1 + impactBps)` is computed

**Decision.** For the D-010/D-018 depth rule the USDG amount that moves the stock price by `impactBps` is `L_avg × (√(1+i) − 1) × 2^96 / sqrtP` when USDG is token0 (buying token1 lowers `sqrtP`) and `L_avg × (√(1+i) − 1) × sqrtP / 2^96` when USDG is token1 (buying token0 raises `sqrtP`). `√(1+i) × 1e9` is `Math.sqrt((1e4 + impactBps) × 1e14)` (1 004 987 562 for 100 bps, the SPEC constant). The stock-is-token0 price formula of §9.5 is `price8 = 1e8 × 10^(dS − dU) × sqrtP² / 2^192` (the SPEC had the decimal factor inverted); the SPEC check value for tick 222 534 is 216.75, not 216.4.

**Alternatives considered.** The SPEC's "same inequality for both orientations": wrong by a factor `sqrtP² / 2^192` (≈ 5 × 10⁹ at $200), which would have let a USDG-is-token1 pool (SPY, TSLA, AMZN, GOOGL by address order) pass the depth rule with almost no liquidity. Caught by `test_path2_reason_LIQUIDITY_thinWindow` during implementation.

**Why.** Correctness; the rule is the main T-03 mitigation.

**Consequences.** SPEC §9.3 item 1, §9.5; `OracleMath.depthOk`, `OracleMath.quotePrice8`; `testFuzz_depthRule_matchesSwapAmounts` (against the exact v3 swap amounts, both orientations), `testFuzz_quotePrice8_bothOrderings`, `testFuzz_quotePrice8_symmetry`.

---

## D-053 · 2026-09-03 · Settlement hints, exhaustion proofs, the 7-day halt backstop and next-second parameter versions

**Decision.**
1. `Hint {refRoundId, afterRoundId, afterPrevRoundId, obsIndex}`. `refRoundId` must be the last round with `answer > 0` at or before expiry; rounds with `answer ≤ 0` after it (at most 8) are skipped. `refRoundId == 0` is accepted only when the feed's first round `(1 << 64) | 1` is after expiry or the feed is unreachable; otherwise `RefRoundRequired`. A wrong round hint reverts (`BadRefRoundHint`, `BadAfterRoundHint`); a policy failure falls through to the next path.
2. `obsIndex` (the newest pool observation at or before expiry) is advisory: an older index only under-counts the window, so a wrong index fails the TWAP path instead of reverting; the walk reads at most `minObservationsInWindow + 1` entries. The keeper computes it off-chain from `pool.observations`.
3. `halt` needs an on-chain exhaustion proof (weekday: past `twapGrace` and no fresh round or a tripped guard; weekend: past Monday 15:00 UTC and no round after expiry, or the verified first-after round beyond the deadline or tripped) and is refused while `oraclePaused()` or the sequencer hook fails — except that from `expiry + haltedTimeout` (7 days) `halt` is allowed unconditionally, so a feed that stays paused can never lock a vault. Path 3 stays valid however late `settle` is called as long as the round itself is inside the deadline.
4. A parameter version set in block `t` applies to series whose auction opens at `t + 1` or later (`effectiveFrom = block.timestamp + 1`). Found by `invariant_I12_paramSnapshot`: with `effectiveFrom = block.timestamp` a timelocked change executed in the same block as `openAuction` changed the parameters of the series that had just opened.
5. `resolveRef` is fixed at `halt` (refRound answer, else `sRef`) and stored; both resolutions require the vault series to be HALTED.

**Alternatives considered.** Reverting on a wrong observation index (first implementation): it made the default hint revert on every quiet window and gave the keeper nothing in return, since the index cannot be used to pass a check that the true state fails. Halting on `oraclePaused()` immediately: premature, the pause is meant to be short (§10.4).

**Consequences.** SPEC §9.1, §9.3, §9.6, §6; `ISettlementOracle.Hint`; `test_settle_refHint_*`, `test_path2_observationHintCannotHelp`, `test_halt_*`, `test_halt_backstop_oraclePaused`, `test_paramsAt_versioning`, `invariant_I12_paramSnapshot`, `invariant_I14_liveness`.

---

## D-054 · 2026-09-03 · `capPrice` implements §12, `referencePrice` implements §7.2; the AuctionHouse keeps reading `capPrice`

**Decision.** `SettlementOracle.capPrice(vault)` (IPriceSource) returns the Chainlink answer if younger than 80 h, else the 30-min TWAP anchored at now with all pool and USDG checks, and never reverts (`(0, false)` on a dead feed and pool). `referencePrice(vault) → (price8, source)` applies §7.2 (Chainlink ≤ 26 h and `oraclePaused() == false`, else the TWAP within 15 % of a Chainlink answer ≤ 80 h old, else `NoReferencePrice`). `AuctionHouse.setPriceSource(oracle)` and `CapController.setPriceSource(oracle)` are called at deployment (closes OQ-003 and the first half of OQ-004); the AuctionHouse still derives `S_ref` from `capPrice` (D-047), so the stricter §7.2 rule is not yet enforced at open — recorded as OQ-005.

**Why.** The AuctionHouse is 1.5 KB from the size limit and is not redeployed in this phase.

**Consequences.** SPEC §7.2, §12, §18; `test_capPrice_*`, `test_referencePrice_branches`.

---

## D-055 · 2026-09-03 · TickMath ported from Uniswap v4-core (MIT) without assembly

**Decision.** `contracts/src/libraries/TickMath.sol` implements `getSqrtRatioAtTick` with the v4-core constants in plain Solidity (CLAUDE.md rule 8); `getTickAtSqrtRatio` is not needed. `OracleMath` holds the TWAP tick floor, harmonic liquidity, depth rule, price quote and bps helpers.

**Alternatives considered.** Vendoring `v3-core` (`TickMath` is GPL-2.0, and the 0.8 branch still uses assembly) or `v3-periphery` `OracleLibrary`.

**Consequences.** `test/OracleMath.t.sol`: the three canonical values (tick 0, MIN_TICK, MAX_TICK), monotonicity, the 1.0001 step, the SPEC §9.5 check.

---

## D-056 · 2026-09-03 · Protocol bounds for the parameters the SPEC left unstated

**Decision.** `twapGrace ∈ [300, 3 600]`, `weekdayTwapBoundBps ∈ [100, 500]`, `swapNotionalUSDG ∈ [10 000e6, 10 000 000e6]`, `impactBps ∈ [10, 500]`, `sequencerGrace ∈ [600, 86 400]`, `usdgBandLowBps ∈ [9 000, 9 999]`, `usdgBandHighBps ∈ [10 001, 11 000]`, `usdgMaxStale ∈ [1 h, 80 h]` (T-12.5). The stated ones are unchanged: `weekdayMaxStale ∈ [1 h, 30 h]`, `weekendTwapBoundBps ∈ [300, 1 500]`, `minObservationsInWindow ∈ [1, 16]`, `jumpBps ∈ [1 000, 5 000]`. Bounds are constants of the RiskModule.

**Why.** SPEC §15 says every parameter is bounded; a compromised timelock could otherwise set `twapGrace = 0` or a 100 % USDG band (T-14).

**Consequences.** `RiskModule._validate`, `test_T14_parameterBoundsEnforced`.

---

## D-057 · 2026-09-04 · Independent review of the settlement layer: liveness of `halt`, the first *valid* round after expiry, and a non-pre-emptive backstop

**Decision.** A fresh-context review of `5b75fbd`/`db06c38` (2 High, 4 Medium, 2 Low, 5 informational) led to:

1. **The 7-day halt backstop is now reachable and non-pre-emptive (High + Medium).** `_haltCheck` used to verify the reference-round hint *before* the backstop, so a series whose hints had all become unverifiable could be neither settled nor halted: it stayed `LIVE` for ever, `withdraw`/`redeem` stayed closed and the collateral was locked with no admin escape (reproduced by the reviewer with nine consecutive `answer = 0` rounds). From `expiry + haltedTimeout` no hint failure reverts and an unusable hint counts as "no path". In exchange the backstop no longer fires unconditionally: a path that still succeeds with the supplied hint is never pre-empted, so a keeper outage cannot be turned into a different settlement price by whoever calls first (`test_T08_backstopDoesNotPreemptAvailablePath`, `test_T08_backstopDoesNotPreemptPath3`).
2. **`resolveHaltedByOracle` and path 3 take the first *valid* round after expiry (High).** They verified the hint's *position* and then rejected a non-positive answer, so a single garbage round published right after expiry killed the permissionless resolution and re-created the single-admin-key liveness dependency that D-033 exists to remove. `_firstValidAfter` verifies the position and then skips up to `MAX_GARBAGE_SKIP` invalid successors, which is what SPEC §9.6 always said ("the first **valid** round"). `previewResolveByOracle(seriesId, roundId, prevRoundId)` mirrors the call exactly; `canResolveByOracle` stays as the coarse window signal.
3. **`MAX_GARBAGE_SKIP` raised from 8 to 32**, in both directions. A longer run leaves every hint unverifiable; the backstop of item 1 is the escape, and `testFuzz_T14_garbageRunNeverBricksTheVault` fuzzes runs of 0…45 rounds and asserts the vault always returns to IDLE.
4. **The "no round at or before expiry" claim is checked against the feed, not a guess (Medium).** `registerVault` probes the feed's earliest reachable round `(phase << 64) | 1` over the first eight phases and stores it (`Miswired("FEED_FIRST_ROUND")` if the feed serves none); `refRoundId == 0` is refused when that round is at or before expiry, or when the feed's own `latestRoundData()` is a valid round at or before expiry. Before this, deleting one round let anyone halt a healthy series and moved the resolution band onto `sRef`.
5. **Hostile external inputs fail the guard instead of reverting it (Low).** A sequencer feed reporting a `startedAt` in the future reads as down; the jump guard's multiplier exception is skipped when `price8` exceeds `uint128` or the multiplier ratio exceeds `MAX_MULTIPLIER_RATIO = 1e12`, so an absurd `uiMultiplier` cannot make `settle` or `halt` revert.
6. **`renounceOwnership` reverts** on SettlementOracle and RiskModule: the owner is the timelock and `resolveHalted`, `registerVault` and the parameter setters must stay reachable (CLAUDE.md rule 5).
7. **The T-16 invariant was over-broad (Medium).** `ReentrantActor` counted a successful `withdrawRefund` / `claimOptions` / `claimPremium` from its ERC-1155 hook even when the hook fired on a plain holder-to-holder transfer, where no protocol call is on the stack and those calls legitimately succeed; `invariant_T16_noReentrancy` therefore failed on some seeds (pre-existing, seed-dependent, present at `af3fec4`). The actor now only attempts re-entry when `operator` is the vault or the AuctionHouse.
8. **The settlement invariants were close to vacuous (Medium).** Added `invariant_I14_expiredSeriesActionable` (the first arm of SPEC I-14: past the backstop, the hint an honest keeper builds must make `settle` or `halt` succeed, and neither view may revert — this is the invariant item 1 would have broken), a composite `cycle` action so random runs reach settlement, depth 64 for the suite, feed runs of up to 12 invalid rounds, and `previewResolveByOracle` in the handler in place of the `answer > 0` early-return that had hidden item 2.
9. **Three convenience views removed** (`isLastRoundAtOrBefore`, `isFirstRoundAfter`, `lastChainlink`) to stay inside the 24 576-byte limit: the keeper reads the feed off-chain to build a hint and validates it with `previewSettle` / `previewResolveByOracle`, which are exact mirrors of the calls.

**Alternatives considered.** Keeping the backstop unconditional (simplest, but it lets anyone convert a stalled settlement into a resolution). Making the wrong-hint case revert at the backstop too (keeps the strict error surface, but that is exactly the bricking path). Proving "no valid round before expiry" on-chain by search: not affordable; the two cross-checks of item 4 bound the claim instead.

**Accepted residuals (recorded, not fixed).**
- At the backstop a caller who *withholds* a usable hint can still force `NO_ORACLE_PATH`, because the contract cannot distinguish "no hint exists" from "hint not supplied". The consequence is bounded: the series resolves inside the ±25 % band of D-022, seven days after expiry, and any honest party can call first with the correct hint.
- If the registered first round becomes unreadable *and* the feed has published after expiry, the zero-refRound claim cannot be disproved on-chain; the consequence is again a halt with `resolveRef = sRef` and the ±25 % band.
- A guardian can lift the auction pause that `pauseNewAuctionsOnHalt` set (SPEC §15); the HALTED vault still refuses to open by its own state machine (`invariant_haltedVaultCannotOpen`).
- `registerVault` is one-shot per vault; if a feed or pool is ever retired the migration path is `sunset` (D-034), not a re-point.
- SettlementOracle is 23.6 KB with 956 bytes of headroom. If more logic lands in it, extract `TickMath` into a deployed (linked) library before adding features.

**Why.** CLAUDE.md rules 2 and 4: never settle on a price that fails the §9 policy, and never ship with a failing test. Items 1 and 2 were fund-locking and key-dependency bugs that the invariants were structurally unable to see.

**Consequences.** SPEC §9.1, §9.3, §9.6, §16.2, §17; `ISettlementOracle` gains `previewResolveByOracle` and `VaultConfig.firstRound`; new tests `test_T14_longGarbageRunCannotBrickTheVault`, `testFuzz_T14_garbageRunNeverBricksTheVault`, `test_T14_resolveHaltedByOracle_skipsGarbageFirstAfter`, `test_settle_path3_skipsGarbageFirstAfter`, `test_settle_refHint_skipsLongGarbageRun`, `test_T08_backstopDoesNotPreemptAvailablePath`, `test_T08_backstopDoesNotPreemptPath3`, `test_T08_zeroRefClaimRejectedWhenTheFeedShowsARound`, `test_T05_sequencerFutureStartedAtCountsAsDown`, `test_T10_absurdMultiplierFailsTheGuardWithoutReverting`, `test_renounceOwnershipDisabled`, `test_registerVault_requiresAReachableFirstRound`, `invariant_I14_expiredSeriesActionable`. Also from the review: `testFuzz_T06_inflationAttackUnprofitable` renamed so the THREAT-MODEL grep finds T-06, `MockUniswapV3Pool` grows its observation cardinality like a real pool, and `OracleMath.sqrtFactor1e9` gained an independent floored-square-root fuzz reference.

---

## D-058 · 2026-09-04 · TickMath is a deployed, linked library; the oracle rejects a bad link in its constructor

**Decision.** `TickMath.getSqrtRatioAtTick` becomes `public`, so the library is deployed once and reached by `DELEGATECALL`
instead of being inlined into every consumer. `SettlementOracle` drops from 23,620 to **22,646 bytes** (headroom 956 → 1,930 of
the 24,576 limit); `TickMath` deploys as its own 1,357-byte contract. The library's `internal constant`s (`MIN_TICK`,
`MAX_TICK`, `MIN_SQRT_RATIO`, `MAX_SQRT_RATIO`) and the `TickOutOfRange` error stay compile-time, so consumers and tests are
unchanged apart from the link.

Linking: `forge test` deploys and links the library automatically, so `libraries` in `foundry.toml` stays empty in the repo and
the entry is documented there for deployment (`libraries = ["src/libraries/TickMath.sol:TickMath:0x…"]`, or the same string via
`forge create --libraries`). An unlinked build keeps a placeholder (`__$55326c8c82635485e895268bfefd3c9895$__`, one site in
`SettlementOracle`) whose address holds no code, which would make every TWAP path revert at the first weekend expiry and turn
`capPrice` into "no price" (blocking deposits) — a failure that unit tests, which always link, cannot catch. So the constructor
now runs `TickMath.getSqrtRatioAtTick(0) != 2 ** 96 → Miswired("TICK_MATH")`: an unlinked library has no code and reverts the
deployment, a mis-linked one returns the wrong value and also reverts it.

**Alternatives considered.** Leaving `TickMath` inlined (956 bytes of headroom in the contract that will carry the next oracle
change; rejected as the tightest constraint in the repo after AuctionHouse's 1.5 KB). Lowering `optimizer_runs` to 1 for this
one contract through `compilation_restrictions`: measured, saved only 179 bytes and costs runtime gas everywhere. Splitting the
price views into a separate `IPriceSource` lens contract: a bigger design change (D-054 puts `capPrice` on the oracle) for a
similar win, and it adds a second address to the deployment instead of a library.

**Consequences.** `contracts/foundry.toml` gains the documented `libraries` key; deployment order (README) gains "deploy
TickMath first, link it into SettlementOracle"; the deploy script and its fork test must assert the constructor accepted the
link. `test_D058_constructorRejectsUnlinkedOrWrongTickMath` etches over `address(TickMath)` to prove both failure modes.
Gas: one `DELEGATECALL` per TWAP evaluation (`getSqrtRatioAtTick` is called once per `_poolTwap`), which leaves
`test_T07_settleGasBound` far inside its 1.5 M bound. D-055 (the v4-core port, no assembly) is unchanged; this only changes how
it is deployed.

---

## D-059 · 2026-09-04 · The WRITE supply split lives in the token as constants

**Decision.** `WRITE.sol` carries the five bucket sizes as `constant`s (250 M liquidity, 300 M emissions, 200 M
treasury, 150 M team, 100 M points) summing to `MAX_SUPPLY = 1e27`; the constructor takes only the five
recipient *addresses*. `ERC20 + ERC20Burnable + ERC20Permit`, no owner, no mint, no pause, no `ERC20Votes`.

**Alternatives considered.** Passing the amounts as constructor arguments (rejected: the split then lives only
in a deploy script, so a fat-fingered argument is unverifiable from the verified source, and Blockscout readers
cannot check the tokenomics against the bytecode). `ERC20Votes` (rejected: governance is a timelock with one
hardware-wallet EOA, D-003; checkpoints would tax every transfer permanently for dead code — if voting ever
ships, an `ERC20Wrapper + ERC20Votes` vWRITE adds it with zero change to WRITE).

**Consequences.** `docs/TOKENOMICS.md` and the contract agree by construction.
`test_constructor_allocationsSumToMaxSupply` and `test_noMintOrOwnerSelectorsExist` pin it.

## D-060 · 2026-09-04 · The mint-into-contracts circularity is resolved by set-once wiring, not a bootstrap

**Decision.** The five holders deploy first knowing nothing about WRITE; WRITE's constructor mints into them;
then one `setWriteToken` per holder wires the token back. On mainnet the five calls go out as a single
`TimelockController.scheduleBatch`, executed before any WRITE can move. This is the existing D-044 idiom.

**Alternatives considered.** A `TokenBootstrap` contract doing everything atomically in one transaction
(rejected: a new fund-adjacent contract to audit, plus an address-prediction pattern; its post-mint assertions
live equally well in `script/DeployToken.s.sol` and `test_e2e_dayInTheLife`, where they cost nothing on chain).
CREATE2 pre-computation so every holder could hold `write` as an `immutable` (rejected: the holders' addresses
feed WRITE's constructor arguments and WRITE's address feeds theirs — a two-way dependency needing a bespoke
deployer anyway).

**Consequences.** `script/TokenDeployLib.sol` is the single description of the sequence, shared by the deploy
script and `test/TokenBase.t.sol`, so the fixture cannot drift from the deployment.

## D-061 · 2026-09-04 · "Never into an EOA" is enforced by an `allocation()` handshake, not `code.length`

**Decision.** Every mint recipient implements `IWriteHolder.allocation()`. WRITE's constructor calls it on each
address and requires the answer to equal the constant it is about to mint.

**Alternatives considered.** `to.code.length > 0` (rejected: it cannot catch a *contract* wired into the wrong
bucket, which is the likelier deploy error). **Corrected by D-098:** this record originally claimed the
handshake is stronger than a code-length check because an EIP-7702 delegated account would pass the latter.
It passes the handshake too, if its delegate implements `allocation()`. The handshake is a wiring guard, not
a security boundary. Nothing at all, relying on
the deploy script (rejected: the mint is irreversible and the timelock is the party making the typo).

**Consequences.** An EOA has no `allocation()`, so the call reverts and the deployment fails.
A holder in the wrong slot reverts `AllocationMismatch`. `test_constructor_revertsOnEOARecipient` and
`test_constructor_revertsOnAllocationMismatch` cover both.

## D-062 · 2026-09-04 · Two `Vesting` deployments, so the treasury grant is structurally irrevocable

**Decision.** `Vesting` takes `allocation` and `allowRevocable` as immutables and is deployed twice: treasury
(200 M, `allowRevocable = false`) and team (150 M, `allowRevocable = true`). `createSchedule` rejects a
revocable schedule on an instance that does not allow them. Funding asserts use `>=`, never `==`, and no
accounting term reads `balanceOf`.

**Alternatives considered.** One 350 M contract with a per-schedule `revocable` flag (rejected: the treasury
grant would then be unrevoked only by policy, not by construction, and a single wrong flag in one proposal
would be enough).

**Consequences.** WRITE has five recipients rather than four.
`test_createSchedule_treasuryInstanceRejectsRevocable` pins the guarantee.

## D-063 · 2026-09-04 · Deploy order: holders, token, wiring, oracle, module, sink

**Decision.** `TokenDeployLib.deploy` runs: five holders → `WRITE` → five `setWriteToken` →
`WritePriceOracle` + `setSanityBand` → `SafetyModule` → `EmissionsController.setSink`. Each later step asserts
the earlier ones: the module's constructor checks both back-references and `setSink` checks the reverse.

**Alternatives considered.** Deploying the module before the oracle and pointing it later (rejected: the
constructor assert is the cheapest place to catch a miswiring, per D-049).

**Consequences.** Pool-dependent steps (`escrow.setPool`, `escrow.fundAll`, `oracle.setPool`) stay outside the
library because they depend on the launch venue; the deploy script prints them as the operator's next actions.

## D-064 · 2026-09-04 · One canonical `IWritePriceOracle` that never reverts

**Decision.** `writePrice() → (price8, ok)`, `usdValueOfWrite(uint256) → (usd6, ok)`,
`writeForUSD(uint256) → (writeWei, ok)`, `previewPrice() → (price8, reason, source)`. Every view follows
`IPriceSource.capPrice`'s never-reverting shape, so no consumer needs a try/catch around it.

**Alternatives considered.** A reverting oracle with consumer-side try/catch (rejected: two consumers with
opposite needs would each implement the wrapping differently, which is exactly the seam where a bug hides).

**Consequences.** `SafetyModule` turns `!ok` into a zero value, `FeeRouter` turns it into a USDG fallback, and
`previewPrice` makes "why is there no price" answerable from chain data.

## D-065 · 2026-09-04 · Decimal conversion lives in the oracle, not in its consumers

**Decision.** `usdValueOfWrite` floors (18 + 8 − 20 = 6 decimals) and `writeForUSD` ceils (6 + 20 − 8 = 18).
Neither `SafetyModule` nor `FeeRouter` repeats the bridge.

**Alternatives considered.** Each consumer doing its own `mulDiv` (rejected: the same conversion written twice
is the classic place for an off-by-1e12, and the two call sites want opposite rounding).

**Consequences.** The rounding direction is stated once, next to the reasoning: understating the safety module
understates the deposit cap (conservative), and overstating a WRITE fee favours the protocol.

## D-066 · 2026-09-04 · The WRITE price sanity band is a validity band and is mandatory

**Decision.** `setPool` reverts `SanityBandRequired` while `sanityHigh8 == 0`. A quote outside
`[sanityLow8, sanityHigh8]` is reported as *unavailable*, never clamped to the bound.

**Alternatives considered.** Clamping to the bound (rejected: a clamped price still feeds the deposit cap at
the ceiling value, which is precisely the outcome a manipulator wants). Making the band optional (rejected: at
launch there is no Chainlink feed to deviate against, so the ceiling is the only thing bounding a sustained
cross-window pump that would inflate every vault's cap).

**Consequences.** Launch proposal `sanityLow8 = 0.005e8`, `sanityHigh8 = 5.00e8` at a $0.10 launch: wide enough
for honest price discovery, tight enough that a pump cannot inflate caps by more than ~50×. The numbers are a
founder call recorded in `docs/TOKENOMICS.md`.

## D-067 · 2026-09-04 · The oracle prices Chainlink-first, TWAP-second, and bands both

**Decision.** `writePrice` tries Chainlink (positive answer, fresh within `CL_MAX_STALE = 26 h`,
`answeredInRound >= roundId`, decimals normalised to 8), then the pool TWAP, then reports no price. The sanity
band applies to whichever source answered.

**Alternatives considered.** Trusting Chainlink unconditionally once configured (rejected: a stale feed would
silently freeze every deposit when a working TWAP was available). Banding only the TWAP (rejected: a feed
misconfiguration deserves the same guard).

**Consequences.** `chainlinkFeed` ships as `address(0)`, so the TWAP carries the whole load at launch;
`setChainlinkFeed` is the timelock switch for when a real feed exists.

## D-068 · 2026-09-04 · `setPool` asserts the pair, the fee tier, the cardinality and the history

**Decision.** `WritePriceOracle.setPool` requires `{token0, token1} == {WRITE, USDG}`, a fee in
`{500, 3000, 10000}`, `observationCardinalityNext >= 256`, and a successful `observe([window, 0])` probe. The
orientation is cached in `writeIsToken1`, read from the pool and never inferred from address ordering.

**Alternatives considered.** A "minimum observations in the window" rule at read time (rejected: it would
freeze deposits protocol-wide after any half-hour without a WRITE swap, and break every inherited fixture that
warps days forward; manipulation resistance is already carried by `OracleMath.depthOk` over harmonic-window
liquidity, the D-018 property, plus `observe`'s own `OLD` revert).

**Consequences.** A freshly created pool is rejected at configuration time rather than silently reporting no
price at the first read. `WritePriceOracle` links the same deployed `TickMath` and repeats the D-058
constructor assert, so `foundry.toml`'s `libraries` entry now has two consumers.

## D-069 · 2026-09-04 · `SafetyModule.valueUSD()` returns zero on an unavailable price, and never reverts

**Decision.** `valueUSD()` returns 0 when the oracle has no price; `valueUSDView()` carries the flag.

**Alternatives considered.** Reverting (rejected: `CapController.vaultCapUSD` is a public view the frontend and
keepers read, so a revert makes the entire cap system unreadable rather than merely closed — both fail closed,
only one keeps the views answerable).

**Consequences.** The failure mode changes shape and the implementer must not miss it: with `cap6 == 0`,
`remainingDepositAssets` returns `(0, true)`, so `deposit()` reverts with OpenZeppelin's
`ERC4626ExceededMaxDeposit`, **not** `CapPriceUnavailable`. Pinned by
`test_valueUSD_zeroClosesDepositsViaTheCap`.

## D-070 · 2026-09-04 · `ISafetyModule` is not extended

**Decision.** The interface keeps its single `valueUSD()` member. `totalStaked()` and
`safetyModuleValueUSD()` (SPEC §12's name for the same number) live on the concrete `SafetyModule` and are read
through the concrete type in tests.

**Alternatives considered.** Adding both to the interface (rejected: `MockSafetyModule` satisfies it with a
bare public state variable, and every fixture in the tree imports that mock; widening the interface for one
alias is churn across the whole test tree for no consumer benefit — `CapController` needs only `valueUSD`).

**Consequences.** `test/mocks/MockSafetyModule.sol`, `Base.t.sol` and `AuctionBase.t.sol` are untouched by this
change, and `CapControllerTest` keeps its isolation.

## D-071 · 2026-09-04 · The safety module is share-based; SPEC §14's "sWRITE 1:1" is amended

**Decision.** Staking credits non-transferable internal shares over an explicit `totalStaked` accumulator, with
`DECIMALS_OFFSET = 6` matching the vault. A slash reduces `totalStaked` and leaves `totalShares` alone, so the
loss lands pro rata. **This amends `SPEC.md` §14**: "mints sWRITE 1:1" becomes "credits non-transferable
shares; 1:1 at genesis, pro rata after any slash".

**Alternatives considered.** A real 1:1 `sWRITE` ERC-20 (rejected: the peg breaks the instant a slash lands, so
either the token stops being 1:1 or every balance must be rewritten — the first is a lie, the second is
unbounded gas). A balance-based ledger pro-rating every account on slash (rejected: same unbounded loop).

**Consequences.** Because `totalStaked` is an accumulator and never `balanceOf`, a donation cannot move the
share price — proven by `test_stake_donationDoesNotMoveSharePrice`. The virtual offset is kept for consistency
with `CoveredCallVault` rather than out of necessity.

## D-072 · 2026-09-04 · `UnstakeRequest.shares` is `uint256`

**Decision.** The cooldown struct stores shares as a full `uint256`.

**Alternatives considered.** Packing it into `uint128` next to `unlockAt` (rejected: every slash raises the
shares-per-asset multiplier by `1/0.7`, so after roughly ninety maximum slashes a large holder's `toUint128()`
would revert and that account could never open an unstake request again — a permanent, silent lockout to save
one storage slot on one struct per account).

**Consequences.** One extra slot per account with a live request.

## D-073 · 2026-09-04 · `MIN_RESIDUAL_STAKE` blocks only the crossing, not every slash below it

**Decision.** `slash` reverts `SlashWouldWipe` when `staked > FLOOR && staked - amount < FLOOR`. A pool already
below the floor stays slashable.

**Alternatives considered.** A flat "no slash when `totalStaked < FLOOR`" (rejected: it disables slashing
exactly when the module is weakest, which is when it is most likely to be needed).

**Consequences.** The share-price divisor can never be driven to zero by slashing, while the backstop stays
usable in the tail.

## D-074 · 2026-09-04 · Emissions are pulled by the sink, never pushed

**Decision.** `EmissionsController.claim()` is `onlySink`; `SafetyModule._accrue()` calls it, and the
permissionless `SafetyModule.poke()` is the liveness path. The module checks `emissions.sink() == address(this)`
before claiming, so staking works in the deployment window before `setSink` has executed.

**Alternatives considered.** A permissionless `drip()` that pushes tokens into the module (rejected: the stake
asset *is* the reward asset, so a push forces the module to distinguish principal from rewards by looking at
its own balance — the exact accounting that lets a slash silently consume unclaimed rewards).

**Consequences.** `invariant_I19_totalStakedIsNotTheBalance` states the property the pull model preserves.

## D-075 · 2026-09-04 · Emissions accrued while nobody is staked are parked, not jackpotted

**Decision.** When `totalShares == 0`, pulled emissions go to `unallocatedRewards`, and only the timelock can
move them, via `redirectUnallocated`.

**Alternatives considered.** Crediting the index anyway (rejected: division by zero). Not pulling at all and
leaving the tokens in the controller (rejected: the controller accrues on `rate × Δt` independently of its
balance, so the skipped amount would be unpayable forever). Letting the first staker take the backlog
(rejected: this is the classic MasterChef bug — a whale who stakes one block before a poke harvests weeks of
emissions).

**Consequences.** `test_emissions_unallocatedWhileNobodyStaked` asserts the first staker inherits nothing.

## D-076 · 2026-09-04 · The emissions schedule is bounded at construction and its end time is immutable

**Decision.** `EmissionsController`'s constructor enforces `MIN_DURATION = 365 days` and
`MAX_DURATION = 3650 days`, and `MAX_RATE` is the whole bucket over `MIN_DURATION`. `endTime` is immutable;
there is no `setEndTime`. `setRate(0)` stops the stream and `setRate` restarts it.

**Alternatives considered.** An unbounded constructor duration (rejected: a one-day duration produces a rate
hundreds of times above what `setRate` would ever accept, draining 300 M in a day — the bound and the setter
cap must agree). A mutable `endTime` (rejected: a second mutable time axis buys nothing once the rate is
settable, and it carries a dead-window resurrection subtlety).

**Consequences.** `test_constructor_enforcesMinAndMaxDuration` and `test_noSetEndTimeSelectorExists` pin both.

## D-077 · 2026-09-04 · A rate change is never retroactive

**Decision.** `setRate` checkpoints first: elapsed time is moved into `owed` at the old rate before the new
rate takes effect.

**Alternatives considered.** Recomputing accrual from `lastAccrual` at the new rate (rejected: it silently
reprices time that has already passed, in either direction).

**Consequences.** `test_setRate_isNeverRetroactive` asserts the first week keeps its original rate across a
doubling.

## D-078 · 2026-09-04 · The module's oracle is re-settable; its token and controller are immutable

**Decision.** `SafetyModule.setOracle` is `onlyOwner` and asserts the candidate quotes the same token.
`writeToken` and `emissions` stay immutable.

**Alternatives considered.** An immutable oracle (rejected: a dead oracle would freeze every vault's deposits
protocol-wide with no fix short of redeploying the module and re-staking everyone). Precedent:
`CapController.setPriceSource`, D-039.

**Consequences.** `renounceOwnership` is disabled on the module: an ownerless SafetyModule could never slash,
which is its entire purpose.

## D-079 · 2026-09-04 · A 14-day interval between slashes, on top of the 30 % per-event cap

**Decision.** `slash` requires `block.timestamp >= lastSlashAt + 14 days` as well as
`amount <= 30 % of totalStaked`. It takes an `evidenceURI`, matching `BondManager.slashBond` and SPEC §14.

**Alternatives considered.** The per-call cap alone (rejected: three consecutive timelock executions would
remove 65.7 % of the stake, which is not what "≤ 30 % per event" means; SPEC §14 specifies both limits).

**Consequences.** The user-facing request named a two-argument `slash(amount, recipient)`; the SPEC form with
`evidenceURI` is implemented instead, and the extra rate limit is flagged in the plan as an addition.
The 14-day cooldown also dominates the 48 h timelock delay, so a staker cannot exit ahead of a queued slash —
`test_cooldownDominatesTheTimelockDelay` states it, `test_cooldownStakeIsStillSlashable` demonstrates it.

## D-080 · 2026-09-04 · The WRITE bond requirement is a fixed token amount, never oracle-denominated

**Decision.** `requiredAmountOf[WRITE][kind]` is an 18-decimal token amount set by the timelock. `BondManager`
imports no oracle and performs no cross-asset arithmetic.

**Alternatives considered.** A USD-denominated requirement converted at read time (rejected: `hasActiveMMBond`
is called inside `AuctionHouse.bid` with no try/catch, so a cheap TWAP push on a young token's own pool — or a
merely unavailable price — would un-bond every competing market maker at once and collapse the clearing price;
`AuctionHouse` is also off-limits for modification).

**Consequences.** The requirement drifts against USD and must be re-pegged by 48 h governance; the cadence is
an open item in `docs/TOKENOMICS.md`.

## D-081 · 2026-09-04 · The bond migration is four separately visible timelock calls

**Decision.** `setWriteToken` → `setRequiredAmountFor(WRITE, MM, …)` → `setRequiredAmountFor(WRITE, CURATOR, …)`
→ `startMigration(graceSeconds)`, which reverts `RequirementUnset` if either requirement is still zero.
`startMigration` is one-way and bounded by `MAX_GRACE = 90 days`; `extendGrace` may only move the deadline
later. D-007's value is 30 days.

**Alternatives considered.** A single `setBondAsset(asset, amounts…)` call (rejected: a half-configured
migration would un-bond every market maker the moment it executed, and one large call is harder to review in a
timelock queue than four small ones).

**Consequences.** Per-asset legs mean `usdg` stays `immutable` with the same getter, so
`AuctionHouse`'s constructor assert still passes and the AuctionHouse is not recompiled.

## D-082 · 2026-09-04 · The bond lock gates qualification, not a named asset; the cooldown is waived, the lock never

**Decision.** A market maker with active locks may withdraw a leg only while some *other* accepted leg still
keeps it bonded. A leg in a de-accepted asset skips the 7-day cooldown entirely (SPEC §13: "after grace, USDG
bonds no longer count and become withdrawable immediately") but never skips the lock check.

**Alternatives considered.** Waiving the lock for a de-accepted asset, reading SPEC §13 literally (rejected:
that turns the migration into a collateral escape hatch — an MM with a live series could pull the collateral
standing behind it). Keeping the old "no withdrawal while locked" rule unchanged (rejected: an MM that had
already posted the new asset would have to skip an auction to migrate).

**Consequences.** With a single asset the new rule is exactly the old one, so `BondManager.t.sol` is unchanged.
`test_T13_migrationIsNotACollateralEscapeHatch` and `test_lockedMmMayPullTheLegItIsNotStandingOn` cover both
sides.

## D-083 · 2026-09-04 · Slashing is per leg, with no spillover, and proceeds go to the treasury

**Decision.** `slashBondIn(holder, kind, asset, amount, evidenceURI)` names its asset; the one-argument
`slashBond` is an alias for the current `bondAsset`. Slashed WRITE goes to `treasury`, not to the burn address.

**Alternatives considered.** An implicit ordering that drains one leg then the other (rejected: the timelock
proposal should say what it is slashing). Burning slashed WRITE (rejected: it destroys the resource that funds
the shortfall path).

**Consequences.** `test_slashBondIn_hasNoSpillover` pins the isolation between legs.

## D-084 · 2026-09-04 · `writePool` is removed from FeeRouter, superseding D-016

**Decision.** The WRITE-mode launch gate becomes `writeToken != address(0) && priceOracle != address(0)`.
`FeeRouter` no longer stores a pool address.

**Alternatives considered.** Keeping `writePool` as the D-016 flag and asserting it equals the oracle's pool
(rejected: an address the contract never reads is dead state and a second, unverifiable place to point at a
pool; the oracle already validates the pool thoroughly in `setPool`).

**Consequences.** D-016's intent — WRITE mode unreachable until the timelock enables it post-launch — is
preserved exactly; only the flag changes. `SPEC.md` §11 is amended, and
`test/FeeRouter.t.sol:42` changes from asserting `writePool()` to asserting `writeToken()` and `priceOracle()`.
This is the only compile-level change in the existing test suite.

## D-085 · 2026-09-04 · The WRITE fee debit happens in `flush`, never in `collect`

**Decision.** `FeeRouter.collect` is left byte-for-byte as it was — pure bookkeeping, no transfer. The entire
WRITE path (oracle read, balance debit, burn, treasury transfer, USDG rebate) runs inside the permissionless
`flush`. SPEC §11 already described it this way.

**Alternatives considered.** Debiting at collect time inside a try/catch (rejected: EIP-150's 63/64 rule means
a gas-bomb oracle can consume enough gas that `mintSeries` and the bond-unlock loop at
`AuctionHouse.sol:384-390` run out, bricking a permissionless `clear()` without the try/catch ever seeing a
revert).

**Consequences.** `clear()` is un-brickable *by construction* rather than by exhaustive revert analysis.
`test_T07_clearNeverRevertsBecauseOfTheWritePath` drives a clearing with the oracle dead, the curator balance
empty and WRITE mode on, and it still succeeds.

## D-086 · 2026-09-04 · The USDG rebate goes to the curator; no separate rebate recipient

**Decision.** When the WRITE path succeeds, the USDG fee is transferred to `curatorOf[vault]`.

**Alternatives considered.** A separate `feeRebateRecipient` with its own setter, as SPEC §11 hints (rejected:
a second 48 h governance path for a rarely-used payout override, when re-pointing `curatorOf` achieves the same
thing).

**Consequences.** `SPEC.md` §11 is amended to name the curator directly.

## D-087 · 2026-09-04 · The WRITE discount and burn share are global, not per vault

**Decision.** `writeDiscountBps` (default 2000) and `writeBurnShareBps` (default 5000) are protocol-wide,
bounded by 5000 and 10000 respectively.

**Alternatives considered.** Per-vault values, matching `feeBps` (rejected: a per-vault 100 % discount is a
silent fee waiver for one curator, decided by a parameter that reads like a discount rather than an exemption).

**Consequences.** D-011's values are unchanged; only their scope is stated.

## D-088 · 2026-09-04 · Both WRITE conversion legs round up

**Decision.** `discounted6 = ceil(feeUSD6 × (1e4 − discountBps) / 1e4)` and
`writeAmount = ceil(discounted6 × 1e20 / price8)`.

**Alternatives considered.** Flooring either leg (rejected: a strictly positive, repeatable leak to the curator
on every clearing — small per series, unbounded over a year of weekly auctions).

**Consequences.** The curator overpays by at most one wei per clearing.
`test_previewWriteFee_roundsUpInTheProtocolsFavour` pins the direction.

## D-089 · 2026-09-04 · `WriteFeePaid` carries the price, `WriteModeFallback` carries a reason

**Decision.** `WriteFeePaid(vault, curator, feeUSDG, writeAmount, burned, price8)` and
`WriteModeFallback(vault, bytes32 reason)`. `withdrawWrite` checks `WriteNotLaunched` before the curator check.

**Alternatives considered.** Keeping the original one-argument `WriteModeFallback(vault)` (rejected: "why did
WRITE mode not fire" then needs off-chain state reconstruction; the reason code answers it from a log).
Nothing is deployed, so changing the event topics costs nothing.

**Consequences.** **Amends `SPEC.md` §16.1.** The check ordering keeps `test/FeeRouter.t.sol:167` passing
byte-for-byte — without it the pre-launch revert would be `NotCurator` instead of `WriteNotLaunched`.

## D-090 · 2026-09-04 · No vesting or distribution accounting reads `balanceOf`

**Decision.** `Vesting.unallocated() = allocation − reallocated − totalAllocated` and
`PointsDistributor.unreserved() = allocation − paidOut − sweptTotal − outstanding`. Both derive from an
immutable, never from the token balance.

**Alternatives considered.** Bounding allocations by `balanceOf(address(this))` (rejected: a donation would
then expand what governance may allocate or reallocate, and a 1-wei donation at the wrong moment can brick an
`==` funding assert).

**Consequences.** `test_donationDoesNotExpandTheUnallocatedPool` and
`test_donationDoesNotExpandTheUnreservedPool` state the property directly; `invariant_I24` proves the buckets
partition the allocation exactly.

## D-091 · 2026-09-04 · `revoke` moves no tokens, and `createSchedule` rejects an already-passed cliff

**Decision.** `revoke` freezes `totalAmount` at the amount vested so far and returns the remainder to the
unallocated pool; `vestedAmount` then reports that frozen figure forever. `createSchedule` reverts
`InvalidSchedule` when `start + cliffDuration < block.timestamp`. The reallocation entry point is named
`reallocateUnallocated`, not "sweep".

**Alternatives considered.** Sending the unvested remainder straight to the treasury on revoke (rejected: a
replacement hire cannot then be granted from it without a second proposal). Allowing a backdated cliff
(rejected: one proposal could unlock a large grant instantly; backdating `start` to TGE stays legal, which is
the legitimate use). Calling it `sweepUnallocated` (rejected: SPEC §15 forbids sweeps, so the word invites a
false audit finding on a provably bounded function).

**Consequences.** The already-vested-but-unreleased portion stays claimable after revocation, and
`totalAllocated == Σ totalAmount` stays exact — `invariant_I23`.

## D-092 · 2026-09-04 · Beneficiary rotation is two-step and self-initiated; the timelock cannot redirect

**Decision.** `proposeBeneficiary` is callable only by the current beneficiary; `acceptBeneficiary` only by the
proposed one. There is no governance path to change a beneficiary.

**Alternatives considered.** A timelocked `setBeneficiary` for lost keys (rejected: it is a governance power to
redirect a vested grant, which is what "non-revocable" is supposed to exclude).

**Consequences.** Accepted residual: a genuinely lost key strands the grant. Recorded here so it is a decision
rather than an oversight.

## D-093 · 2026-09-04 · Points are distributed in rounds, with a round-scoped double-hashed leaf

**Decision.** `setRound(roundId, root, amount, start, deadline)`, amendable only before `start`;
`claim(roundId, index, account, amount, proof)` with a per-round bitmap; `sweep(roundId)` after the deadline.
The leaf is `keccak256(bytes.concat(keccak256(abi.encode(roundId, index, account, amount))))`, verified with
`MerkleProof.verifyCalldata`. Both claim and sweep are permissionless, and a claim always pays `account`.

**Alternatives considered.** A single replaceable root (rejected: it cannot be replaced once claiming has
started, and the 100 M bucket must serve both the airdrop and the MM/curator bond grants). A single-hashed leaf
(rejected: an internal node could be presented as a leaf). Omitting `roundId` from the leaf (rejected: a proof
from one round would replay into another).

**Consequences.** This encoding is the integration contract with the off-chain `points/` generator, which does
not exist yet and which **must** assert that its leaf amounts sum to the round's allocation; on chain,
`RoundExhausted` confines an over-issuing root to its own allocation.

## D-094 · 2026-09-04 · `LiquidityEscrow` refuses a raw AMM pool as its destination

**Decision.** `setPool` probes the candidate for `token0()`/`token1()` and reverts `PoolIsRawAmm` if either is
WRITE. The pool is re-pointable until the first `fund`, then frozen. `renounceOwnership` is disabled. There is
no rescue path and no second destination.

**Alternatives considered.** Requiring the destination to implement a deposit callback interface (rejected: it
imposes an interface on a venue the SPEC does not yet describe). Relying on `onlyOwner` alone (rejected: the
timelock is the party that would make the typo, and a bare `transfer` of 250 M WRITE into a v3 pool is a
donation the next swap takes — 25 % of supply gone in one block).

**Consequences.** The escrow holds WRITE only; the paired USDG for the launch pool comes from the treasury.
The launch venue itself is still an open item in `docs/TOKENOMICS.md`.

## D-095 · 2026-09-04 · One `TokenBaseTest` on top of `SettlementBaseTest`; the real module is named `sm`

**Decision.** Everything needing chain state extends `TokenBaseTest is SettlementBaseTest`; the pure-token
suites use a bare `TokenUnitBaseTest is Test`. Both deploy through `script/TokenDeployLib.sol`. The real
safety module is `sm`, because `Base.t.sol` already declares `MockSafetyModule safetyModule`.

**Alternatives considered.** A mixin fixture (rejected: two `setUp()` bases). Extending `SettlementBaseTest` in
place (rejected: it would change the state every existing settlement test runs against).

**Consequences.** The inherited `MockSafetyModule` stays constructed and unused, so `CapControllerTest` keeps
its isolation and `Base.t.sol` / `AuctionBase.t.sol` are untouched.

## D-096 · 2026-09-04 · Pool ticks are derived by binary search, and price expectations come from the live oracle

**Decision.** `TokenBaseTest._tickForWritePrice` binary-searches the production math for the tick nearest a
target price; every price assertion uses `assertApproxEqRel` and every downstream expectation (`valueUSD`,
`vaultCapUSD`, `maxDeposit`) is derived from the live oracle price rather than the nominal $0.10.

**Alternatives considered.** A hardcoded tick constant, as `SettlementBaseTest` uses for the stock pool
(rejected: hand-computed it is wrong by tens of ticks, and even the exactly correct tick prices WRITE at
$0.100000280 rather than $0.10 — a test asserting the nominal figure to a tight tolerance fails for a reason
that has nothing to do with the code under test). `vm.etch` to force an address ordering (rejected: it would
not copy WRITE's minted balances).

**Consequences.** Both pool token orderings are covered by `test_writePrice_bothTokenOrderings`, and the
fixture reads `pool.token0()` rather than comparing addresses, so no test depends on deploy-nonce ordering.

## D-097 · 2026-09-04 · A reward claim is capped at the module's surplus above principal

**Decision.** `SafetyModule.claimRewards` pays `min(credited, rewardSurplus())`, where
`rewardSurplus() = balanceOf(this) − totalStaked − unallocatedRewards`, and decrements
`totalUnclaimedRewards` saturatingly. Any shortfall stays credited to the account.

**Why.** Found by the CI-profile invariant run (256 × 64), not by the default profile. Rewards are credited
from a floored cumulative index: `_harvest` credits `floor(s × A₂ / P) − floor(s × A₁ / P)`, and that can
exceed `floor(s × (A₂ − A₁) / P)` by one wei. `_accrue` meanwhile increments `totalUnclaimedRewards` by the
exact amount pulled. The sum of credits therefore drifts above the counter by roughly a wei per harvest, and
the *last* account to claim hit `totalUnclaimedRewards -= amount` on an underflow — their rewards became
permanently unreachable. Reproduced deterministically from the shrunk sequence: a stake, an accrual, a slash,
a second stake and two claims left `sum(pending) = totalUnclaimedRewards + 1`.

**Alternatives considered.** Keeping `_rewardDebt` unfloored as `shares × A` so the credit is a single floor
(rejected: with `ACC_PRECISION = 1e36` and post-slash share inflation, `shares × A` reaches ~1e81 and
overflows `uint256`). Lowering `ACC_PRECISION` (rejected: it trades a liveness bug for a precision loss on
small stakes, and the vault's 1e36 is the house constant). Making only the subtraction saturating (rejected:
it stops the revert but leaves the real question — whether a claim can reach staked principal — unanswered).

**Consequences.** "A reward claim never touches staked principal" becomes structural rather than a
consequence of the index being exact. The `safeRewardTransfer` shape is the standard fix for this class of
bug in index-based reward contracts. Invariant I-18 is restated against principal plus parked emissions
(which is exactly true) rather than against `totalUnclaimedRewards` (which drifts), and I-28 bounds credits
by the surplus plus the dust. Regression tests:
`test_claimRewards_dustDriftNeverBricksTheLastClaimant`, `test_rewardSurplusBoundsEveryClaim`.

---

## D-098 · 2026-09-04 · Independent review of the WRITE token layer: staged deploy, seven hardening changes, and the tests that were passing without proving anything

Three fresh-context reviews of `b35aeff..HEAD` (fund-loss paths; SPEC/CLAUDE.md conformance; test quality). Two
of them independently traced every value flow and confirmed **CLAUDE.md rule 7 holds**: no fee, premium,
settlement or slash proceeds can reach a WRITE holder because they hold or stake WRITE. The curator's USDG
rebate is a priced swap — the same call debits WRITE worth `feeUSD × (1e4 − discountBps) / 1e4` — and a holder
who is not `curatorOf[vault]` receives nothing. Emissions are provably capped at the 300 M genesis bucket:
`_pending()` bounds accrual by `allocation − released − owed`, so WRITE donated to the controller is stranded
rather than emitted, and there is no deposit path by which revenue could enter. The share math, the Merkle
accounting and the "a claim never reaches principal" property were each verified analytically and cleared.

**Decision.** Fix everything the reviews found. The substantive changes:

1. **The deploy is staged and the timelock owns everything from birth.** `TokenDeployLib` previously wired the
   holders as `Params.owner = deployer`, and `DeployToken.s.sol` transferred ownership afterwards with
   `Ownable2Step.transferOwnership` — which does not take effect until the recipient calls `acceptOwnership`,
   itself a 48 h-delayed operation. For that whole window one hot key owned all seven contracts and could take
   250 M from `LiquidityEscrow`, 350 M from the two `Vesting` instances and 100 M from `PointsDistributor` via
   a same-block round, and could *irreversibly* misdirect the 300 M emissions stream through the one-shot
   `setSink`. That also contradicted D-060, which describes the wiring going out as a `scheduleBatch`. The
   library now exposes four stages — `deployHolders`/`deployToken` (deployer), `wireHolders` (timelock batch),
   `deployStaking` (deployer), `wireStaking` (timelock batch) — with the ordering forced by `SafetyModule`'s
   constructor assert. The deployer only ever calls `new`. `deploy()` remains as a single-call convenience for
   the fixture, which pranks the timelock. `test_stagedDeploy_deployerHoldsNoPrivilege` pins it.
2. **`Vesting` cannot create an already-vested grant.** D-091 recorded a guard against a proposal that unlocks
   a grant instantly, but `cliffDuration == duration` and `start + cliffDuration == block.timestamp` both
   passed, and `vestedAmount` then returned the full `totalAmount` in the creating block. Now `cliff < duration`
   and the term must still have `MIN_REMAINING_TERM` (90 days) left. `reallocateUnallocated` is additionally
   blocked until at least one schedule exists — before that the "unallocated pool" is the entire bucket, so it
   would have been a drain rather than the re-granting path it is meant to be, and D-062's "structurally
   irrevocable" claim about the treasury instance only holds once its schedule exists.
3. **`LiquidityEscrow.setPool` recognises more than the Uniswap shape.** The probe returned "safe" whenever
   `token0()` reverted, which admitted a Curve pool, a v4 `PoolManager`, the escrow itself and the token
   itself — each of which would park 250 M unreachably. It now also probes `coins(uint256)` and rejects
   `address(this)` and `writeToken` outright. It remains a typo guard, not a proof, and the NatSpec says so.
4. **A slash voids unstake requests that had already matured.** The NatSpec claimed "a staker cannot dodge a
   slash", but a standing request opens a 3-day window every 17 days, which overlaps a 48 h execution window
   about 29 % of the time — so a prepared position lost ~21 %, not 30 %. `unstake` now requires
   `req.unlockAt > lastSlashAt`. The narrow claim (someone reacting *at* queue time cannot exit) was always
   true and is now tested behaviourally against a real `TimelockController` rather than by comparing two
   constants.
5. **`slash` and `redirectUnallocated` reject `address(this)`.** Slashing to the module decremented
   `totalStaked` while leaving the tokens where no credit can ever reach them: stakers took the full loss and
   the WRITE was unrecoverable.
6. **`FeeRouter` reserves booked fees and requires a curator before funding.** `flush` is permissionless and
   priced at call time, so a curator could watch the price and pull their prefunded WRITE moments before a
   flush would have debited it, taking the discount only when it suited them; `withdrawWrite` now keeps
   `previewWriteFee(pending[vault])` covered while in WRITE mode. `depositWrite` requires `curatorOf[vault]`,
   since without one there is no withdrawal path at all. `renounceOwnership` is disabled on `FeeRouter` and
   `BondManager`, matching the rest of the layer.
7. **`WritePriceOracle` gains the sequencer check it was missing, and a non-zero band floor.** T-05 was a
   *mitigation* gap, not just a test gap: `observe` interpolates across a sequencer outage and reports a
   pre-outage tick as fresh, and that stale price sizes every vault's deposit cap. The oracle now carries the
   same uptime feed and recovery grace as `SettlementOracle`. `setSanityBand` rejects `low8 == 0`, which would
   have made `_inBand(0)` true and reported a truncated feed answer as a usable price of zero.

Smaller corrections: `extendGrace` reverts `MigrationNotStarted` rather than an unrelated error;
`Vesting.acceptBeneficiary` drops the id from the previous beneficiary's index; a dead branch in `_scaleTo8`
is gone; `ScheduleSet` was removed from SPEC §16.1 (it does not exist), `FeeFlushed`'s second parameter is
`to` rather than `treasury` (in WRITE mode it is the curator), and the two different `PoolSet` signatures are
now both listed.

**D-061's reasoning was wrong and is corrected.** Both the NatSpec and the record claimed the `allocation()`
handshake is "stronger than a `code.length > 0` check, which an EIP-7702 delegated account would pass". A
7702-delegated account whose delegate implements `allocation()` passes the handshake too, as can any hostile
contract returning the right number. The check is a **wiring guard** — it rejects a plain EOA and, more
usefully, a contract wired into the wrong bucket — not a security boundary. The addresses are chosen by the
deployer inside `TokenDeployLib`, which is where the real guarantee comes from.

**Tests that were passing without proving anything**, all found by the test-quality review and all fixed:
`testFuzz_writeFeeSplitConservesTheDebit` asserted `burned + (amount − burned) == amount` on local variables
and never called `flush`; `test_setSink_assertsBackReference` reverted on the token check and never reached
either back-reference branch (`SINK_EMISSIONS` and `SINK_WRITE` had zero occurrences in the whole repo);
`test_permit_revertsOnExpiredDeadline` signed a garbage digest, so it reverted on the signer check and would
have passed with the deadline branch deleted; `test_cooldownDominatesTheTimelockDelay` compared two constants;
`invariant_I20` asserted a bound the handler had already applied with its own `bound()`, so deleting
`ExceedsSlashCap` would not have failed it; `testFuzz_fund_neverExceedsAllocation` skipped exactly the
over-allocation case it was named for; `testFuzz_bitmapMarksExactlyOneIndex` kept every index in word 0, so
`index >> 8` was never exercised; and `testFuzz_writePriceNeverRevertsForAnyTick` bounded the tick to ±600 000
when the guard it targets fires at ±887 272.

**The invariant handler was measured, not assumed.** At `FOUNDRY_INVARIANT_DEPTH=4000`, `unstake` succeeded 13
times in 4 096 calls; at the shipped depths every logged run reported `unstakes: 0`. The share-burning path —
and with it I-21's "no orphaned principal" clause — was never evaluated. The handler gained
`warpToUnstakeWindow`, a `donate` action for both new suites (their comments claimed donation-resistance was
the point, but only unit tests covered it), and `slashOverCap`, which deliberately attempts an illegal slash
on every call so I-20 is proven by the contract.

**Alternatives considered.** For (1), keeping the deployer-owns-then-transfers shape and merely asserting
`pendingOwner()` (rejected: it documents the window instead of closing it, and SPEC §15's deployer model was
written for contracts that do not hold 1e27 of token). For (4), accepting the duty-cycle escape and correcting
the comment (rejected: two lines make the documented property true). For (7), porting RS-02's
minimum-observations rule (rejected: it would freeze deposits protocol-wide after any quiet half-hour and
break every fixture that warps days forward — the sequencer feed is the targeted fix, and the depth rule
already carries manipulation resistance).

**Consequences.** SPEC §11, §12, §14, §16.1, §16.2 and §17 updated; §17 gains I-17…I-41, which existed only in
the test files and in DECISIONS. THREAT-MODEL.md gains **T-21…T-25** (WRITE price manipulation into the cap,
bond-migration griefing, emissions misdirection, points root mis-issuance, launchpad destination error) plus
token-layer notes on T-05, T-11, T-12, T-13, T-14 and T-16 — that file's own §6 requires it to change in the
same commit as SPEC §13/§15 or the invariant list, and it had not been touched. Four new invariant suites mean
every contract in the layer now satisfies CLAUDE.md rule 2; `AuctionInvariants` deliberately stays out of WRITE
mode and the migration (D-097), so `WriteFeeBondInvariants` is the only coverage of either. Tests: 605 → 676,
green under `FOUNDRY_PROFILE=ci`.

---

## D-099 · 2026-09-04 · `injectCoverage` restores only the unclaimed options, from a recomputed unscaled payout

**Decision.** `CoveredCallVault.injectCoverage(seriesId, tokens)` is `onlyOwner` (the timelock, SPEC §15) and
`nonReentrant`, accepts only a SETTLED or RESOLVED series, and raises `payoutPerOption` toward the payout the
series would have paid without the §9.7 step 5 scaling. Four sub-decisions:

1. **The unscaled payout is recomputed, not stored.** `ppoFull = (settlementPrice − strike) × 1e18 /
   settlementPrice`, read back from the series. Both fields are written once at settlement and never mutated,
   and SPEC §10.2 fixes them as USD per **raw** token with no multiplier adjustment ever applied, so the
   recomputation is exact for the life of the series — splits and dividends included.
2. **Only `filledQty − claimedQty` is restored.** Holders who already claimed were paid at the scaled rate.
3. **`tokens` is an upper bound and the call clamps.** It pulls `min(tokens, what a full restore needs)` and
   caps the rate at `ppoFull`.
4. **The `OptionToken` mirror is raised too**, through a new vault-only `raisePayout`.

The vault also exposes `coverageNeeded(seriesId)` so governance can size the purchase on chain.

**Why.** The invariant that makes this safe is per-series `reserve = credited − drawn ≥ floor(rem × ppo /
1e18)`. It holds with equality at settlement; a claim of `q` preserves it by superadditivity of floor (the
argument already commented on `payOptionClaim`); and an injection credits exactly `floor(rem × ppoNew / 1e18) −
floor(rem × ppoOld / 1e18)`, which restores it. Since `payoutOwed = Σ reserve`, it can never underflow, and
repeat injections are safe. The amount pulled is the claimable increase rather than the budget, so no dust is
stranded, and the full-restore branch assigns `ppoFull` outright so 100 % is exact rather than floored. Because
the balance and `payoutOwed` rise by the same amount, `totalAssets()` never moves: coverage reaches option
holders and cannot leak into depositor NAV or the share price (I-8).

**Alternatives considered.** *Storing the unscaled payout (or a per-series shortfall) on `VaultSeries`*
— rejected: the struct packs into five slots today and a sixth `uint128` costs a slot per series forever, to
hold a value that is already derivable exactly. *Reverting on overshoot* — rejected: the call executes after a
48 h delay, so a slightly oversized OTC fill would cost another 48 h; the event records what was actually
pulled, and the 100 % cap is enforced either way. *Topping up holders who already claimed* — rejected: there
is no per-holder claimed ledger, only the aggregate `claimedQty`, and adding one would mean per-holder storage
on every claim to serve an event that should be rare. Early claimers taking the haircut is the documented
consequence, not an oversight. *Leaving the `OptionToken` mirror stale* — rejected: `claim` prices from the
vault so no money was at risk, but SPEC §16.1 publishes that copy to indexers and the frontend, and it would
have shown the scaled rate forever (`markSettled` is one-shot).

**Consequences.** `test_injectCoverage_*` (nine unit tests) pin the semantics, including
`_onlyUnclaimedAreRestored` and `_clampsOvershoot`; `testFuzz_injectCoverageNeverExceedsUnscaled` and
`testFuzz_injectCoverageClaimsNeverUnderflow` check the maths against a plain-arithmetic reference;
`invariant_I2_coverageBackedAndBounded` asserts `payoutOwed ≤ balance`, the `ppoFull` ceiling and
vault/mirror agreement across the stateful run, with `test_handlerReachesShortfallAndInjection` proving the
path is not vacuous (a random walk has to burn through half the collateral first). `test_T11_injectCoverage
RestoresFullPayout` and `test_e2e_slashCoversAShortfall` close the loop THREAT-MODEL T-11.3 and SPEC §14
describe. Vault size 19,542 → 20,778 bytes (3,798 headroom). Tests: 676 → 692, green under
`FOUNDRY_PROFILE=ci`. `CoveredCallVault` still does not override `renounceOwnership` while eight sibling
contracts do; a renounce would now brick the shortfall-repair path, so that override is the next hardening
item.
