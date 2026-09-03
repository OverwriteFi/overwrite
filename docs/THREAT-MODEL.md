# Overwrite Protocol — Threat Model

Version 0.2 · 2026-09-02 · Status: internal. Written against SPEC.md v0.1; the sixteen recommended revisions in §4 were all accepted the same day (DECISIONS.md D-018…D-034, SPEC.md v0.2). The threat sections below keep the original analysis; §4 records what was adopted and where the founder amended a proposal.

**INTERNAL. Nothing in this file goes on the website, into the docs site, or into marketing copy.** The frontend disclosures are written separately and only summarise the accepted external risks (§5) in plain language.

State of the code when this was written: `contracts/src/` contains only the Foundry scaffold (`Counter.sol`). Every "Enforced by" entry below is therefore a **build requirement** for the implementation session, not a description of existing code. Contract names follow SPEC §3; test names follow the convention in §6 so coverage can be proven with `forge test --match-test T03`.

---

## 1. Scope and method

### 1.1 What is protected

| Asset | Where it sits | Owner |
|---|---|---|
| Stock tokens (principal) | `CoveredCallVault[i]` | depositors |
| Option payout (stock tokens reserved after settlement) | vault, `payoutOwed` | option holders |
| Premium (USDG) | vault accumulator, `premiumClaimable` | depositors |
| Bid escrow (USDG) | `AuctionHouse` | bidders |
| Bonds (USDG, later WRITE) | `BondManager` | curators, MMs |
| Protocol fees (USDG) | `FeeRouter` → treasury | protocol |
| Correct settlement price | `SettlementOracle` | both sides of every series |
| Liveness (auctions open, series settle, queues clear) | keeper + permissionless calls | everyone |

### 1.2 Trust assumptions (from SPEC §2)

- Depositors, MMs, option holders, LPs on Uniswap: untrusted.
- Keeper: untrusted for safety, trusted only for liveness. Every number it supplies is bounded or verified on-chain.
- Guardian: hot key on the keeper server; can only pause new auctions and deposits.
- Admin: one hardware-wallet EOA, sole proposer/executor of a 48 h `TimelockController`.
- Robinhood (issuer, sequencer operator, 2 of 8 council seats): external; can pause tokens, pause oracle flags, block addresses, burn balances, upgrade all stock tokens via one beacon, filter transactions at the sequencer. **Accepted and disclosed; not mitigable on-chain.**
- Chainlink: honest but slow (24 h heartbeat, 0.5 % deviation, no weekend updates).
- Paxos (USDG): can pause the token and freeze addresses.
- OpenZeppelin 5.1, Uniswap v3 math libraries: assumed correct as audited.

### 1.3 Scales

Severity is worst-case impact if the threat materialises with mitigations in place as specified.

| Severity | Meaning |
|---|---|
| **Critical** | Loss of principal across vaults, or unbounded loss in one vault |
| **High** | Loss of principal in one vault or series above ~10 % of notional; or funds locked with no exit |
| **Medium** | Bounded loss ≤ ~10 % of notional; loss of premium; one series mis-settled inside a sanity bound |
| **Low** | Liveness, gas, UX; skipped week; delayed settlement with no wrong price |

| Likelihood | Meaning |
|---|---|
| **High** | Expected to happen in normal operation or cheaply attackable |
| **Medium** | Requires a capable, funded attacker or an uncommon external event |
| **Low** | Requires key compromise, issuer action, or a chain-level failure |

---

## 2. Register

| ID | Threat | Severity | Likelihood | Residual after v0.2 | Adopted as |
|---|---|---|---|---|---|
| T-01 | Chainlink staleness (weekday path) | High | High (age) / Low (wrong price) | Low | — |
| T-02 | Chainlink wrong or malfunctioning answer, phase changes | High | Low | Low (jump guard) | D-025 |
| T-03 | Uniswap TWAP manipulation on a thin pool (weekend path) | High | Medium | Medium, bounded by caps | D-018, D-019 |
| T-04 | Weekend price gap: Sunday settlement vs Monday open | Medium | High | Accepted (economic) | — |
| T-05 | Sequencer downtime / timestamp drift on an Orbit chain | High | Low–Medium | Low (falls to path 3) | D-019 |
| T-06 | ERC-4626 inflation / first-depositor attack | High | Medium | Low | — |
| T-07 | Auction griefing (slot filling, refund DoS, receiver DoS) | High (DoS) | Medium | Low | D-023, D-024, D-030 |
| T-08 | Settlement front-running and path selection | Medium | Medium | Low | D-021 |
| T-09 | Rounding and unit errors in payout, escrow, premium | High | Medium (bug class) | Low with tests | — |
| T-10 | `uiMultiplier` change mid-series (split, dividend) | High | Low | Low–Medium (see §4 note) | D-026, D-025 |
| T-11 | Stock token issuer actions (pause, block, burn, beacon upgrade, halt/delist) | Critical | Low | Accepted | D-020 |
| T-12 | USDG depeg, pause, address freeze | Medium | Low | Low | D-023 |
| T-13 | Keeper key compromise | Medium | Medium | Low | D-027, D-028, D-029 |
| T-14 | Admin key compromise or loss | Critical | Low | Medium (bounded, exit window) | D-022, D-031, D-033 |
| T-15 | Guardian key compromise | Low | Medium | Low | D-029 |
| T-16 | Reentrancy (token hooks, ERC-1155 callbacks, cross-contract) | High | Medium (bug class) | Low | D-024 |
| T-17 | Upgradeability | Critical | — | Low (immutable + sunset) | D-034 |
| T-18 | Deposit-queue griefing blocks `openAuction` | Low–Medium | High | Closed | D-032 |
| T-19 | Keeper + MM collusion on auction parameters | Medium | Medium | Low | D-027 |
| T-20 | Chain-level trust (council, sequencer FCFS, tx filtering) | Critical | Low | Accepted | — |

The last column names the DECISIONS.md entry that adopted the revision; §4 maps the original RS ids to decisions and records the founder's amendments.

---

## 3. Threats

Format per threat: what is at risk, the scenario, severity and likelihood with the reasoning, mitigations already in SPEC, which contract and which tests enforce them, and what remains.

### T-01 · Chainlink staleness (weekday path)

**At risk.** Correct weekday settlement price; by extension option payout and depositor principal.

**Scenario.** The weekday series settles on the last Chainlink round at or before Friday 16:00 ET. Measured behaviour (SPEC §1.3): NVDA had weekday gaps of 4.4–8.1 h; SPY is essentially heartbeat-only, so its last round before Friday close was 3.7 h old and can in principle be 24 h old. A naive "2 h staleness" rule fails routinely; a too-loose rule settles on Thursday's price. Separately, if the feed stops entirely (Chainlink outage, feed deprecated, `isTradingHalt` on the underlying) the "last round before expiry" is arbitrarily old.

**Severity.** High. A price that is 24 h old at expiry on a name that moved 5 % on Friday mis-settles the whole series in one direction.
**Likelihood.** High that the round is hours old (it is normal); Low that it is materially wrong, because the deviation threshold of 0.5 % guarantees an update whenever the price moved during the 24/5 session.

**Mitigations in SPEC.**
- §9.2: accept round `r` only if it is the last round with `updatedAt ≤ expiry` (verified via `next(r)`), and `expiry − updatedAt ≤ weekdayMaxStale` (default 26 h, bound `[1 h, 30 h]`).
- The 0.5 % deviation threshold means age is not the same as error: within the 24/5 session an old round is still within 0.5 % of the live price. Age beyond the heartbeat is the real failure signal, hence 26 h = heartbeat + 2 h.
- Fallback: 30-minute TWAP within 3 % of `lastChainlink`, USD-converted; else HALT (never settle stale).
- Keeper hint is verified, never trusted: a wrong `roundId` reverts.

**Enforced by.**
- `SettlementOracle.settle` / `previewSettle` (path 1 checks), `chainlinkRoundAtOrBefore`.
- Tests: `SettlementOracle.t.sol::test_T01_rejectsRoundNewerThanExpiry`, `test_T01_rejectsNotLastRoundBeforeExpiry`, `test_T01_rejectsStaleBeyondMaxStale`, `testFuzz_T01_maxStaleBoundary`, fork test `Fork_Settlement.t.sol::test_T01_nvdaFridayRound930` replaying the 2026-08-28 data; invariant **I-5**.

**Residual.** A round that is 25 h old and passes the guard is by construction the last 24/5 price (a Friday holiday case, documented). A Chainlink feed that publishes a wrong price inside the heartbeat is T-02.

---

### T-02 · Chainlink wrong answer, malfunction, phase change

**At risk.** Settlement price on paths 1 and 3, reference spot `S_ref` (strike), cap pricing, and the sanity reference for every TWAP bound.

**Scenario.**
1. A feed publishes a bad answer (data provider error, aggregator bug, wrong decimals after an aggregator swap). Path 1 has **no sanity bound** against the previous round: a single bad round is accepted as long as it is the last before expiry and ≤ 26 h old. A 4× answer settles calls at ≈ 75 % of collateral to option holders; a 0.25× answer expires them worthless.
2. Proxy phase change (aggregator replaced) mid-week: round ids jump to `(p+1) << 64 | 1`; `prev(r)` across a phase boundary depends on a keeper-supplied hint; an unverified hint could let the keeper pick a non-adjacent round.
3. Feed deprecated or paused: `latestRoundData` returns stale or zero; `oraclePaused()` on the token is only advisory.
4. Description strings differ across feeds ("RH…" vs "Robinhood …"): a deploy script keying on `description()` would wire the wrong feed.

**Severity.** High (one series, up to ~75 % of a vault's collateral in the 4× case).
**Likelihood.** Low. Chainlink tokenized-equity feeds are new (63 days of history) and some are listed "High risk" on Chainlink's own page (SPEC §19), which is why this is not "very low".

**Mitigations in SPEC.**
- `validRound`: `answer > 0`, `updatedAt > 0`, `oraclePaused() == false` at call time.
- Phase-aware neighbour lookup (§9.1): `next(r)` computed on-chain; `prev(r)` across phases must satisfy `next(prev) == r`, so a keeper cannot supply a non-adjacent round.
- Contracts key on feed **addresses**, never `description()`; allowlist is cast-verified and hardcoded (D-008).
- Path 2 (TWAP) and path 3 have a bound relative to `lastChainlink`; path 1 does not.
- Sequencer hook slot exists (disabled, D-005).

**Enforced by.**
- `SettlementOracle` (`validRound`, `next`, `prev`), `VaultFactory` allowlist constants, deploy script assertions on `feed.decimals() == 8`.
- Tests: `SettlementOracle.t.sol::test_T02_rejectsZeroAnswer`, `test_T02_rejectsWhenOraclePaused`, `test_T02_phaseBoundaryPrevMustLinkToR`, `test_T02_prevHintNonAdjacentReverts`, `MockAggregatorV3` with phase-encoded ids; `Deploy.t.sol::test_T02_everyFeedDecimals8AndAddressMatchesSpec`.

**Residual / recommendation.** Scenario 1 is unmitigated on path 1. See **RS-05**: a jump guard on path 1 (`|answer / prevRound.answer − 1| > jumpBps`, e.g. 4 000 bps) that halts instead of settling, with `resolveHalted` bounded (RS-13). The trade-off is that a genuine 40 % single-day move (rare; earnings on a small cap, not on this allowlist) becomes a 48 h timelocked resolution instead of an instant settlement. With the allowlist limited to mega-caps and two ETFs the guard almost never trips on real moves.

---

### T-03 · Uniswap v3 TWAP manipulation on a thin pool (weekend path)

**At risk.** Weekend settlement price (path 2), weekday fallback (path 2), `S_ref` fallback and `S_cap` fallback. Payout to option holders is `(S − K)/S` of collateral, so a pumped `S` moves depositor principal to whoever holds the options; a dumped `S` expires the options worthless.

**Scenario.**
1. **Pump for payout.** An option holder (any address; options are transferable, D-012) pushes the pool price up during the 60-minute window anchored at Sunday 23:59 UTC. With strike distance `d` and pump `m`, extra payout ≈ `((1+m) − (1+d)) / (1+m)` of notional for `m > d` (SPEC §9.3). At the 15 % bound with a 5 % OTM strike: ≈ 8.7 % of notional.
2. **Pump inside natural noise.** A 3 % nudge on top of a real 5 % weekend move is inside the bound and indistinguishable from the market.
3. **Liquidity pull.** An LP who owns most in-range liquidity withdraws it for the window, moves the price with little capital, re-adds liquidity, then calls `settle`. The SPEC liquidity check reads `pool.liquidity()` at **settle time**, so it passes.
4. **Quiet pool.** No trades over the weekend: `observe` extrapolates the last written tick, so the "TWAP" is Friday's last trade, passes the 15 % bound trivially, and is exactly the "Friday price on a Sunday" that D-001 rejected for Chainlink.
5. **Dump to avoid payout.** A depositor with a large position pushes the price down at the anchor so options that would be ITM expire worthless. Profit = the avoided payout, bounded by the same cap.
6. Weekend market context: the 24/5 session reopens 18:00 ET Sunday (22:00/23:00 UTC), so during the 22:59–23:59 UTC window arbitrageurs do have an external reference and will trade against a manipulator. Before that (Saturday, early Sunday) there is no reference and the pool is the only price. The window sits inside the reopened session by design.

**Severity.** High per series (up to ~8.7 % of vault notional at the bound; more if the bound is loosened).
**Likelihood.** Medium at launch caps, rising with caps. Cost to move NVDA/USDG 1 % ≈ 698 000 USDG of in-range depth (cast 2026-09-02); holding a 15 % move for 60 minutes against arbitrage costs multiples of that in realised slippage plus 2 × 0.05 % fees. Profit ceiling at the 25 000 USDG cap: ≈ 2 175 USDG. **Unprofitable by two to three orders of magnitude at launch.** SPY/QQQ pool depth is unmeasured (SPEC §19); do not create those vaults until measured.

**Mitigations in SPEC.**
- 60-minute window anchored at expiry (call timing does not change the window).
- Liquidity rule (D-010): a 250 000 USDG swap must move price < 1 %, evaluated from `slot0` and `liquidity()` at settle time; parameters timelocked.
- Sanity bound ±15 % vs `lastChainlink` (D-017), per-vault tightenable to 3 %.
- `twapGrace` 30 min so the window stays inside the observation buffer; `increaseObservationCardinalityNext(65535)` at deploy; keeper monitors coverage.
- USD conversion via USDG/USD feed with band and staleness (D-015).
- Caps: 25 000 USDG per vault pre-token (D-011), chosen so the manipulation profit ceiling stays far below the cost of moving the pool.
- Fallback path 3 (first fresh Chainlink round after expiry) if any TWAP check fails.
- MM bonds slashable by timelock for demonstrated manipulation (§13). Note this only bites if the manipulator is a bonded MM; anyone can hold options.

**Enforced by.**
- `SettlementOracle.settle` path 2 (`_twap`, `_poolDepthOk`, `_withinBound`, `_usdgOk`), `CapController` for caps, `BondManager.slashBond` (timelock).
- Tests: `Twap.t.sol::test_T03_liquidityRuleUsdgToken0`, `test_T03_liquidityRuleUsdgToken1`, `test_T03_rejectsBeyondBound`, `test_T03_windowAnchoredNotCallTime`, `testFuzz_T03_tickToPrice8_bothOrderings` (compare with the cast reference tick 222534 → ≈ 216.4), `test_T03_observeOldFallsThroughToPath3`; fork test `Fork_Twap.t.sol::test_T03_nvdaPoolPassesDepthRule` and a **fork manipulation test** that swaps N USDG into the real pool at a fork block, advances time, and asserts `previewSettle` either rejects or stays inside the bound; invariants **I-5**, **I-9**.

**Residual / recommendation.**
- Scenario 3 (liquidity pull): **RS-01** — replace the spot `liquidity()` check with time-weighted liquidity over the window using `secondsPerLiquidityCumulativeX128` from the same `observe` call (harmonic-mean liquidity, the Uniswap `OracleLibrary.consult` technique). A manipulator then has to keep the pool deep for the whole hour to pass.
- Scenario 4 (quiet pool): **RS-02** — require trading activity inside the window: at least `minObservationsInWindow` (e.g. 3) observations with timestamps inside `[expiry − window, expiry]`, read from `pool.observations(i)` walking back from `slot0.observationIndex` (bounded loop). If not met, fall through to path 3 rather than settle on an extrapolated tick.
- Scenario 2 (nudge inside noise) is not detectable on-chain; it is bounded by caps. **Rule for raising caps**: keep `Σ caps of vaults sharing a pool × (bound − d_min)/(1 + bound)` well below the realised cost of holding a `bound`-sized move for one hour on that pool. Re-measure depth before every cap increase; record in DECISIONS.md.
- Weekday fallback (30-minute window, 3 % bound) has a smaller exposure and only runs when Chainlink failed; same tests apply with `window = 1800`.

---

### T-04 · Weekend price gap: Sunday settlement vs Monday open

**At risk.** Depositor economics (weekend calls sold at 100–1000 bps distance) and option-holder economics. Not a security threat; recorded because it is the most likely source of "the protocol settled at the wrong price" complaints.

**Scenario.**
1. The weekend series settles at Sunday 23:59 UTC on the on-chain TWAP (or the first Chainlink round ≈ 00:00 UTC Monday). Monday's 09:30 ET open can gap in either direction on weekend news. A depositor whose calls expired worthless at 23:59 UTC sees the stock gap up 6 % Monday morning and feels they "sold cheap"; the call holder feels the opposite on a gap down. Both are wrong: the instrument is defined on the Sunday price and both sides priced that.
2. Path 2 vs path 3 give different prices (the pool at 23:59 vs the 24/5 print at 00:00). Whoever prefers one can try to steer the path (T-08).
3. The 24/5 session reopens at 18:00 ET Sunday; the pool may lag or lead it by more than the spread while liquidity is thin, so the 23:59 TWAP can differ from the "real" 24/5 price by a few tenths of a percent.
4. Adverse selection: MMs bid on Friday at 20:10 UTC knowing the weekend news calendar. Depositors do not set the reserve; the keeper does.

**Severity.** Medium (mispricing of premium relative to realised risk; never loss beyond the defined payoff).
**Likelihood.** High (every weekend has some gap).

**Mitigations in SPEC.**
- Fixed expiry at Sunday 23:59 UTC, inside the reopened 24/5 session, documented on the frontend (§5).
- Weekend strike distance bounds 100–1000 bps and keeper defaults (single names 500, ETFs 100) so the option is meaningfully OTM.
- D-001 rejected the 52–56 h old Chainlink price precisely because it is a Friday price and gives the winning bidder a free look at Sunday's on-chain price.
- Reserve price bounded `[S_ref × minReserveBpsOfSpot / 1e4, S_ref]`; curator can set a floor.
- The settlement-preview panel (§16.2) shows both candidate prices before expiry.

**Enforced by.** Nothing on-chain beyond the bounds; this is product design. `Vault.t.sol::test_T04_weekendDistanceBounds` covers the bounds. Frontend disclosure text is the actual mitigation.

**Residual.** Accepted. If weekend series systematically under-earn, the lever is the reserve model and the distance defaults, not the oracle. Keep a per-vault log of `settlementPath` and `S_path2 − S_path3` (both are computable off-chain after the fact) to tune.

---

### T-05 · Sequencer downtime and timestamp drift on an Arbitrum Orbit chain

**At risk.** Liveness of every timed step (auction window, settle within `twapGrace`, path-3 deadline); correctness of the TWAP; correctness of anything keyed on `block.timestamp`.

**Scenario.**
1. Sequencer down across the 15-minute auction window: no bids land; `clear` sees no bids → SKIPPED. Liveness only.
2. Sequencer down across Sunday 23:59 UTC + 30 min: path 2 is unreachable (`now > expiry + twapGrace`). Path 3 remains until Monday 15:00 UTC. If downtime exceeds ~15 h, HALT.
3. Sequencer down across Friday 16:00 ET: path 1 has no call deadline (the last round before expiry stays valid whenever the call lands), so a delayed `settle` still works. Chainlink itself cannot post during downtime, so the last round before expiry may be older; the 26 h guard still applies.
4. **TWAP after downtime.** No observations are written while the chain is down. `observe` for a window that spans the outage linearly interpolates tick cumulatives, i.e. it reports the pre-outage tick as if it had held. If the sequencer comes back at 23:50 UTC after a 6-hour outage and someone calls `settle` at 23:59:30, the TWAP is a 7-hour-old price presented as fresh. The 15 % bound is the only guard.
5. **Timestamp drift.** `block.timestamp` is the sequencer's clock, allowed 24 h behind or 1 h ahead of real time, monotone. The sequencer operator (Robinhood) could, by mis-set clock or intent, close an auction early, move an anchor, or make a round look older or younger than it is. Timelock delays are measured in the same clock (48 h can be stretched, never shortened below 48 h of sequencer time).
6. **Forced inclusion is not a fallback.** L2BEAT notes ArbOS 61 transaction filtering can neutralise L1 force-inclusion on this chain; users cannot route around a filtering sequencer.
7. No published Chainlink L2 Sequencer Uptime Feed for this chain (SPEC §19), so the standard hook is disabled (D-005).

**Severity.** High for scenario 4 (wrong price, bounded by 15 %); Low for the liveness cases (a skipped week or a delayed settlement at a still-correct price); the timestamp and filtering cases are chain-trust (T-20).
**Likelihood.** Low–Medium. Orbit chains have had multi-hour sequencer incidents; this chain is two months old.

**Mitigations in SPEC.**
- Every timed step has a fallback or a halt: skipped auction, path 3 deadline, HALT with timelocked resolution; `openTolerance` 2 h for Monday.
- `sequencerFeed` slot and standard check kept in code, enable by timelock when Chainlink publishes an address.
- Keeper monitors observation coverage hourly.
- 15 % bound on the TWAP.

**Enforced by.**
- `SettlementOracle` deadlines (`twapGrace`, `expiry + 54 060`), `RiskModule.pauseNewAuctions` on halt, sequencer hook code path.
- Tests: `SettlementOracle.t.sol::test_T05_sequencerHookRejectsDown`, `test_T05_sequencerHookGrace3600`, `test_T05_sequencerHookDisabledWhenZero`, `test_T05_weekendPastGraceFallsToPath3`, `test_T05_weekendPastMondayDeadlineHalts`, `test_T05_weekdayPath1HasNoCallDeadline`; `MockV3PoolObserve` test `test_T05_twapAcrossGapIsExtrapolated` documenting scenario 4 and asserting RS-02 rejects it once implemented.

**Residual / recommendation.**
- Scenario 4 is the real gap. **RS-02** (minimum observations inside the window) closes it: an outage leaves no observations in the window, so the TWAP is rejected and path 3 is used. **RS-03**: additionally let the keeper (or anyone) pass a cheap on-chain signal that the chain was down, e.g. require `slot0` observation timestamp ≥ `expiry − 900` for path 2; this is a subset of RS-02 and can be the first version.
- Enable `sequencerFeed` the day Chainlink publishes one; add it to RUNBOOK.md as a standing check.
- Timestamp drift and filtering are accepted chain risks (T-20); disclose.

---

### T-06 · ERC-4626 inflation / first-depositor attack

**At risk.** The first (or every small) depositor's principal.

**Scenario.** Classic: attacker deposits 1 wei, donates a large amount of stock tokens directly to the vault to inflate the share price, and the next depositor's deposit rounds to 0 shares. Variants specific to this design:
1. Donations raise `totalAssets()` (it is `balanceOf − encumbrances`), so donated tokens become vault property, are counted in `offeredQty` at the next open, and are distributed pro-rata to existing shareholders at withdrawal. This is the standard behaviour and it is why donation is unprofitable for the donor.
2. **Cap griefing**: donate enough to push `totalAssets × S_cap` to the cap so `maxDeposit = 0` for everyone. Cost = the donation, which goes to existing depositors. At a 25 000 USDG cap this is a ~$25 000 gift to depositors to annoy them; irrational but possible.
3. Rounding on `previewDeposit` when the vault holds encumbered tokens: inside IDLE nothing is encumbered except `payoutOwed` and `withdrawalClaimable`, both excluded from `totalAssets`, so the ratio is exact (SPEC §4.1).

**Severity.** High (total loss of a victim deposit) without the guard; Low with it.
**Likelihood.** Medium: it is a scripted, well-known attack against any new ERC-4626 vault.

**Mitigations in SPEC.**
- OZ `ERC4626` with `_decimalsOffset() = 6`: 1e6 virtual shares per asset unit; an attacker must donate 1e6 × the amount they hope to steal, and the loss on the donation dwarfs any gain.
- Deposits only in IDLE, cap check on every deposit; the deployer can seed each vault with a small deposit whose shares are burned (recommended in the deploy script, cheap insurance on top of the offset).

**Enforced by.**
- `CoveredCallVault` (`_decimalsOffset`, `totalAssets`, `maxDeposit`).
- Tests: `Vault.t.sol::test_T06_inflationAttackUnprofitable` (attacker 1 wei + donation, victim deposits, assert victim shares > 0 and attacker loses), the a16z `erc4626-tests` property suite already vendored under `lib/openzeppelin-contracts/lib/erc4626-tests` run against the vault, `test_T06_donationRaisesTotalAssetsNotSharePriceOfNewShares`, `test_T06_capGriefingByDonationIsBounded`; invariant **I-8** (share price constant between settlements, which also catches unexpected donations mid-series being mis-attributed).

**Residual.** Cap griefing by donation is accepted; the donor pays. A donation mid-series is counted in `totalAssets` but not in `offeredQty` of the live series, so it is unencumbered and harmless.

---

### T-07 · Auction griefing

**At risk.** Liveness of `clear` (and therefore of the vault: a series stuck in AUCTION blocks settlement, windows and queues), premium level, fair allocation.

**Scenario.**
1. **Bid then fail to pay.** Not possible: escrow is transferred with `safeTransferFrom` at bid time (§8.1). A bid that cannot fund itself reverts and is never stored. Refunds and payments at clearing are computed from escrow already held (**I-3**).
2. **Slot filling.** `maxBids = 64` per auction, ≤ 8 per bidder. Eight bonded addresses (8 × 25 000 USDG bonds, refundable escrow, gas only) can fill all 64 slots at the reserve price in the first 100 ms block of the auction on a FCFS sequencer, locking out every other bidder. The cartel then clears at reserve, i.e. buys the calls at the keeper's floor. The bonds are not lost unless the timelock slashes them, 48 h later, on off-chain grounds.
3. **Refund DoS.** `clear` pushes refunds with `safeTransfer`. If a bidder's address has been frozen by Paxos (`isFrozen`, SPEC §1.4) between bid and clear, the transfer reverts and `clear` reverts **forever**. The series cannot leave AUCTION; the vault never returns to IDLE. One frozen address freezes the vault.
4. **Receiver DoS.** `OptionToken.mint` (OZ ERC-1155) calls `onERC1155Received` on contract recipients. A bidder that is a contract without the receiver interface (or one that reverts on purpose) makes `clear` revert. Same outcome as 3.
5. **Callback games.** A bidder contract's `onERC1155Received` runs in the middle of `clear` (see T-16).
6. **Bond escape.** Option tokens are transferable; SPEC §13 ties MM bond withdrawal to "no unclaimed option tokens in LIVE series", which the MM can satisfy by transferring the tokens to another address, then withdraw the bond and manipulate (T-03) with nothing to slash.
7. **Dust bids.** `minBidQty = 0.1` option and `qty × price / 1e18` escrow; fine, but pro-rata fills at the marginal price produce dust assigned to the earliest bid (§8.2 step 4) — the earliest bidder is slightly favoured, which is acceptable and deterministic.
8. **Gas.** 64 bids, insertion sort, 64 transfers: must stay < 6 M gas; if it did not, `clear` could be unexecutable. Measured in tests.

**Severity.** High for 3 and 4 (vault stuck indefinitely; exit only via a timelocked rescue that does not exist in SPEC). Medium for 2 (depositors get reserve-price premium; no principal loss).
**Likelihood.** Medium: 3 requires a Paxos freeze, uncommon but real; 4 is trivial for any bidder who wants to grief; 2 needs 200 000 USDG of bonds and is visible on-chain.

**Mitigations in SPEC.**
- Escrow at bid time; bonded bidders; `maxBids`, per-bidder limit; reserve floor; insertion order tie-break; slashing by timelock with evidence; gas bound measured.

**Bonded-bidder mitigation, specified exactly.** "Bonded bidders" mitigates 2 and 6 only if the bond is locked by **participation**, not by token holdings:
- `BondManager.hasActiveMMBond(bidder)` is checked at `bid`.
- `AuctionHouse.bid` calls `BondManager.lock(bidder, seriesId)`; the lock is released at `clear` (if unfilled), at `settle`/`halt`→`resolve` (if filled), never by transferring option tokens. `withdrawBond` requires zero active locks **and** the 7-day cooldown.
- Slashing grounds and amounts are decided by the timelock (48 h public). For scenarios 3/4 the evidence is on-chain (a reverting refund or receiver); the bond is slashed 100 % and the vault is unstuck by RS-06/RS-07, not by the slash.
- The bond amount (25 000 USDG) must exceed the value a griefer can extract from one auction. At launch caps a whole auction's premium is a few hundred USDG, so the bond is 50–100× the prize.

**Enforced by.**
- `AuctionHouse.bid` / `clear`, `BondManager.lock/unlock/withdrawBond`, `OptionToken.mint`.
- Tests (`contracts/test/AuctionHouse.threats.t.sol`, `AuctionHouse.fuzz.t.sol`, implemented 2026-09-03): `test_T07_bidWithoutEscrowReverts`, `test_T07_maxBidsPerAuctionAndPerBidder`, `test_T07_clearWithFrozenBidderDoesNotRevert` (mock USDG with `isFrozen`; pull-refund path, D-023), `test_T07_clearWithNonReceiverContractBidderDoesNotRevert` (D-024, payout via `claimPayout`), `test_T07_bondLockedUntilSeriesSettledEvenAfterTokenTransfer` (D-030), `test_T07_clearGasUnder6M` (64 distinct bidders: 4.09 M gas measured) and `test_T07_skipGasUnder6M` (2.04 M), `testFuzz_T07_proRataMarginalFillConservesQty`; invariants **I-3** (`invariant_I3_escrowExact`, `invariant_I3_closedConservation`, `invariant_I3_allocationIdentity`) and **I-13** (`invariant_I13_bondLocks`) in `test/invariants/AuctionInvariants.t.sol`.

**Residual / recommendation.**
- **RS-06** Pull-based refunds and payments: `clear` credits `refundable[bidder]`; bidders call `withdrawRefund`. Pull for fee forwarding too (`FeeRouter.collect` must not be able to revert `clear`).
- **RS-07** Option delivery must not be able to revert `clear`: either reject contract bidders that do not return the ERC-1155 magic value at `bid` time (call `supportsInterface(IERC1155Receiver)` and revert the bid), or mint with `_update` (no acceptance check) and document that contract bidders must be able to handle ERC-1155. Prefer the check at `bid`: it fails early and cheaply.
- **RS-08** Participation-based bond lock as specified above (SPEC §13 currently says "no unclaimed option tokens", which is escapable).
- Slot filling (2): consider `maxBids` per auction counted per **bidder** only, with the auction-wide cap replaced by "a new bid replaces the lowest-priced bid when the array is full" so a higher bid can never be locked out. Optional; the reserve floor already bounds the damage.

---

### T-08 · Settlement front-running and path selection

**At risk.** Which of two valid prices a series settles at; premium capture around windows.

**Scenario.**
1. **Hints.** `settle(seriesId, hint)` is permissionless. Hints are verified, so a front-runner cannot make the contract accept a different round than the one that satisfies the rules. Two callers with different hints produce the same result or one reverts.
2. **Weekend path race.** Path 2 (TWAP) is valid for 30 min after expiry, path 3 (first Chainlink round after expiry) becomes available around 00:00 UTC Monday, inside that grace. Both can be valid at once. The contract prefers path 2 whenever its checks pass, so the outcome depends on **who calls when**: if the option holder prefers path 3 they simply do not call; if the keeper is down, depositors (diffuse, no bot) must call within 30 min to lock path 2. Also `lastChainlink` for the 15 % bound flips from Friday's round to Monday's first round the moment it lands, which can change whether path 2 is valid at all.
3. **Anchor-block trading.** TWAP is anchored at expiry, so trading in the last blocks before expiry moves the TWAP by `Δtick × seconds / 3600`; at 100 ms blocks this is negligible per block and is T-03 in general.
4. **Premium capture.** Deposit at 13:59 UTC Monday in IDLE, earn the clearing premium, `requestRedeem` immediately: the redeem executes at Friday's post-settlement price, so the depositor bore the full series risk. Fair; no threat.
5. **Post-settlement MEV.** After `settle` the vault is IDLE and `payoutOwed` is already reserved, so an immediate withdrawal cannot dodge the payout. Queued redeems execute at the post-settlement rate. Fair.
6. **`openAuction` sandwich.** `S_ref` is read on-chain at open. Normally from Chainlink (unmanipulable in-block); on the TWAP fallback a same-block sandwich shifts nothing (30-minute window). The reserve price is keeper-supplied off-chain and can be stale relative to `S_ref` by a few minutes; bounded by `[minReserve, S_ref]`.
7. **`halt` and `resolveHalted`.** `halt` is permissionless but only valid when all paths are provably exhausted; `resolveHalted` is timelocked and visible.

**Severity.** Medium (scenario 2: path choice between two legitimate prices, difference usually well under 1 %).
**Likelihood.** Medium: an MM bot will exploit any free choice.

**Mitigations in SPEC.**
- Deterministic rules; keeper hints verified; window anchored at expiry; the keeper settles at expiry as its primary job so path 2 is the default whenever valid.

**Enforced by.**
- `SettlementOracle.settle`, `previewSettle` (pure mirror for the keeper).
- Tests: `SettlementOracle.t.sol::test_T08_differentValidHintsSameResult`, `test_T08_wrongHintReverts`, `test_T08_path2PreferredWhenBothValid`, `test_T08_lastChainlinkFlipInsideGrace` (documents the reference flip), `Vault.t.sol::test_T08_withdrawAfterSettleCannotDodgePayout`.

**Residual / recommendation.**
- **RS-04** Make the weekend bound reference deterministic: use the last Chainlink round with `updatedAt ≤ expiry` (Friday's close) as `lastChainlink` for the path-2 bound, not "latest at call time". Then path-2 validity does not depend on call timing, and the only remaining free choice is "call within 30 min or not", which the keeper removes by calling at expiry. Keep a second keeper instance (different host) whose only job is to call `settle` for open series so the grace window is never missed.

---

### T-09 · Rounding and unit errors in payout, escrow, strike and premium math

**At risk.** Everything; this is the most common class of real vault exploits.

**Units in play.** Stock tokens 18 dec, USDG 6 dec, Chainlink 8 dec, shares 18 + 6 offset, ticks, `sqrtPriceX96`, bps 1e4, WAD 1e18.

**Scenario.**
1. `payoutPerOption = (S − K) × 1e18 / S` must round **down** and be `< 1e18` (K > 0 guarantees strict). `payoutTotal = filledQty × payoutPerOption / 1e18` rounds down. Rounding errors favour the vault by design.
2. Escrow `qty × price / 1e18` floors; payment `filled × clearingPrice / 1e18` floors; refund = escrow − payment. Because `clearingPrice ≤ price`, refund ≥ 0. `premiumGross` is the sum of the floored payments (D-043), so the sub-unit dust stays with each bidder as refund, nothing accumulates in the AuctionHouse and **I-3** holds exactly (`testFuzz_T09_escrowRefundPaymentConserve`).
3. Pro-rata marginal fills: `Σ fills ≤ remaining`, dust to the earliest `bidId`; must not exceed `offeredQty`.
4. Strike grid: `grid = S_ref × 25 / 1e4`; `ceilDiv(K_raw, grid) × grid`. With 8-dec `S_ref`, `grid` ≥ 1 for any `S_ref ≥ 400` (i.e. $0.000004); a zero grid would divide by zero — guard `grid > 0`.
5. Premium accumulator: `accPremiumPerShare += premiumNet × 1e18 / totalSupply()`. Shares carry a 6-dec offset so `totalSupply` is large and the truncation is tiny; `premiumDebt` bookkeeping in `_update` must be exact on mint, burn and transfer, including self-transfers and zero-value transfers.
6. Cap check: `(totalAssets + assets) × S_cap / 1e18 ≤ capUSD × 1e2` (8-dec USD both sides).
7. TWAP tick math: `tc[1] − tc[0]` over `window`, round toward −∞ for negative; `price8` via `FullMath.mulDiv` with `2^192`; both token orderings.
8. Overflow: `filledQty` and `payoutPerOption` are `uint128`, their product fits `uint256`; `S − K` with `S,K` `uint128` × 1e18 fits; `sqrtP²` needs `FullMath`.
9. USDG/USD conversion: `twapUSD8 = twapUSDG8 × answer / 1e8`, rounding down.
10. ERC-4626 direction: deposit rounds shares down, mint rounds assets up, withdraw rounds shares up, redeem rounds assets down (OZ default). Queue executions must use the same functions, not hand-rolled ratios.

**Severity.** High (a wrong direction in 1 or 3 can over-pay option holders beyond collateral or mint uncovered options).
**Likelihood.** Medium as a bug class; Low once the tests below exist.

**Mitigations in SPEC.** Explicit rounding directions in §7.1, §8.2, §9.5; `uint128` fields; OZ `ERC4626` for share math; invariants I-1…I-4.

**Enforced by.**
- `CoveredCallVault`, `AuctionHouse`, `SettlementOracle`, `CapController`.
- Tests: `testFuzz_T09_payoutPerOptionLtWadAndMonotoneInS`, `testFuzz_T09_payoutTotalNeverExceedsFilledQty`, `testFuzz_T09_escrowRefundPaymentConserve` (I-3 in fuzz form), `testFuzz_T07_proRataMarginalFillConservesQty` (Σ fills == remaining, dust prefix), `testFuzz_T09_strikeGridRoundsUpAtMostOneStep`, `test_T09_gridZeroReverts`, `testFuzz_T09_premiumAccumulatorConservation` (random mints, burns, transfers, clears; assert I-4), `testFuzz_T09_capCheckUnits`, `testFuzz_T09_tickToPrice8_roundTrip`, `test_T09_negativeTickRoundsTowardNegInfinity`; invariants **I-1**, **I-2**, **I-3**, **I-4**, **I-8**.

**Residual.** Dust in AuctionHouse and vault (sub-unit USDG) is accepted and must be excluded from the conservation invariants explicitly (I-4 already says "unsettled accumulator dust").

---

### T-10 · `uiMultiplier` change mid-series (splits, dividends)

**At risk.** Settlement price on any path; strike/price unit consistency.

**Scenario.**
1. **Correct case.** Feed prices one raw token as `share price × uiMultiplier`; raw balances never change; strike is per raw token (D-002). A 4:1 split leaves feed, NAV and strike continuous. Nothing to do.
2. **Mis-sequenced transition.** Robinhood pauses the feed flag, stages `newUIMultiplier`/`effectiveAt`, and unpauses when price and multiplier agree. If a Chainlink round is published with the new multiplier applied before the exchange price reflects the split (or the reverse), the feed shows 4× (or 0.25×) the true token price for a round. On path 1 there is no jump guard: a 4× round that happens to be the last before expiry pays ≈ 75 % of collateral to option holders.
3. **Pause across expiry.** `settle` reverts while `oraclePaused()`. Weekday: the last pre-pause round remains valid after unpause (§10.3); if the pause spans past `expiry + 26 h`... path 1 still accepts because the guard is `expiry − updatedAt`, and the round's `updatedAt` precedes expiry; fine. Weekend: TWAP path unaffected by the flag but compares to the pre-pause Chainlink answer; a pending multiplier that takes effect inside the weekend makes the pool price (raw tokens, continuous) and the paused feed (pre-action) agree, so no false rejection. If the corporate action is a genuine discontinuity in token value (spin-off, not an active type today), the pool moves and the 15 % bound may reject → path 3 → possibly HALT.
4. **Points/UI.** `multiplierAtOpen` is informational; the indexer prices with the feed. Fine.

**Severity.** High (scenario 2, one series).
**Likelihood.** Low: Robinhood's process exists precisely to avoid it, and only ~150 assets have had two months of history; dividends (AAPL 2026-09-02) have gone through cleanly.

**Mitigations in SPEC.** PER_TOKEN strike (D-002), `oraclePaused` gate on `settle` and `openAuction`, keeper watches `UIMultiplierUpdated`/`newUIMultiplier`/`effectiveAt` and the corporate-actions API, curator may skip a series.

**Enforced by.**
- `SettlementOracle` (`validRound` includes `oraclePaused() == false`), `CoveredCallVault.openAuction`.
- Tests: `Multiplier.t.sol::test_T10_splitLeavesPayoutContinuous` (mock token multiplier ×4 with feed unchanged in token terms), `test_T10_settleRevertsWhileOraclePaused`, `test_T10_prePauseRoundValidAfterUnpause`, `test_T10_openAuctionRevertsWithPendingEffectiveAtInsideSeries` (RS-09).

**Residual / recommendation.**
- **RS-09** `openAuction` reverts if `token.effectiveAt() != 0 && effectiveAt ≤ expiry` (a staged multiplier change falls inside the series). Cheap, on-chain, removes the "keeper forgot to check" failure. Skipping one series around a split costs a week of premium and avoids the only scenario where the feed can be transiently wrong by 4×.
- **RS-05** (path-1 jump guard) is the backstop for scenario 2 if the change is not staged in advance.

---

### T-11 · Stock token issuer actions

**At risk.** All principal. This is the largest risk in the system and it is external.

**Scenario** (powers verified in the implementation bytecode, SPEC §1.2).
1. `pause()` on a token: every transfer reverts. Deposits, withdrawals, `claimWithdrawal`, `OptionToken.claim`, bid-side stock movements all fail. `settle` must **not** fail: it should only write accounting (`payoutOwed`, queue execution as bookkeeping), never transfer stock tokens. If `settle` includes a token transfer (e.g. processing a queued deposit by pulling tokens, or moving redeem proceeds), a paused token makes settlement impossible → paths expire → HALT for the wrong reason.
2. `isBlocked(vault)`: the vault address blocklisted (compliance precompile). Same effect as pause, permanently until unblocked. Nothing on-chain fixes it; migration impossible since tokens cannot leave.
3. `burn(vault, amount)`: principal destroyed. `asset.balanceOf(vault) < payoutOwed` → pro-rata payout scaling and `ShortfallRecorded` (§9.7 step 5); depositors take the rest of the loss pro-rata through `totalAssets`. Also `totalAssets` can drop below `Σ filledQty` of a LIVE series, breaking **I-1** through no fault of the protocol; the invariant test must model burns as an external actor and assert the shortfall path rather than the coverage equality.
4. **Beacon upgrade** of all tokens at once (one beacon, owner unknown, delay unknown, SPEC §19). A new implementation could add transfer fees, make `balanceOf` UI-scaled, add hooks (re-entrancy surface, T-16), or change decimals. Any of these breaks accounting silently.
5. Underlying halted or delisted: the feed stops (`isTradingHalt` in the prices API; Chainlink holds the last price). Weekday path 1 settles on the pre-halt round if ≤ 26 h old — a price that no longer reflects a market. Delisting ends in issuer redemption, i.e. a burn.
6. `pauseOracle()` left on indefinitely: `settle` and `openAuction` revert; paths expire; HALT; resolution needs the timelock (T-14 liveness).
7. Issuer as sequencer operator and as 2/8 council: can censor `settle` or `claim` transactions (T-20).

**Severity.** Critical (3, 4). **Likelihood.** Low, but not negligible: these are ordinary issuer powers exercised for compliance, and the beacon's governance is unverified.

**Mitigations in SPEC.** Disclosure (CLAUDE.md rule 10); shortfall path and safety module post-token (§14); `SafeERC20`; keeper alerts on `Paused`, `UIMultiplierUpdated`, beacon `Upgraded`; guardian can pause new auctions and deposits within seconds (D-012); caps limit exposure per vault; no protocol contract holds stock tokens except vaults.

**Enforced by.**
- `CoveredCallVault.settle` must be transfer-free (accounting only); `OptionToken.claim` and `claimWithdrawal` are the only stock-token transfers out; shortfall scaling in `_finaliseSettlement`.
- Tests: `Issuer.t.sol::test_T11_settleSucceedsWhileTokenPaused` (mock token `pause()`), `test_T11_burnCreatesShortfallAndProRataPayout`, `test_T11_claimsScaleProRataAfterShortfall`, `test_T11_injectCoverageRestoresFullPayout`, invariant handler with an `issuerBurn` action asserting **I-2**'s "unless ShortfallRecorded" clause; fork test reading `paused()`, `oraclePaused()`, beacon slot and implementation address for every allowlisted token at deploy (`Deploy.t.sol::test_T11_tokenSurfaceMatchesSpec`).

**Residual / recommendation.**
- **RS-10** Deploy script and keeper store the beacon implementation address (`0xb35490d6…`) and the keeper alerts on any change; the guardian pauses deposits and new auctions on such an alert until a human confirms the new implementation is accounting-compatible. This is monitoring, not prevention; there is no prevention.
- Scenario 5 (halted underlying): consider a curator/keeper rule to not open series while `isTradingHalt` is true in the prices API. Off-chain only.
- Disclosure text (frontend, written separately) must state: issuer can pause, block, burn; the protocol cannot prevent or reverse it.

---

### T-12 · USDG depeg, pause, address freeze

**At risk.** Premium (in vaults, claimable), bid escrow (AuctionHouse), bonds (BondManager), fees; and, via the USD conversion, the TWAP price.

**Scenario.**
1. **Depeg.** TWAP is USDG-denominated; without conversion a 5 % USDG discount overstates every TWAP settlement by 5 %. D-015 converts with the USDG/USD feed and invalidates the TWAP path outside `[0.98, 1.02]` or if stale.
2. **Depeg, economic.** Premium already paid is worth less; MMs bid in devalued USDG and the reserve is in USDG terms. Depositors lose yield, not principal.
3. **`paused()` on USDG.** Bids impossible (auction SKIPPED), `claimPremium` reverts, fee forwarding reverts (must not block `clear`), bond posting/withdrawal reverts. Settlement in stock tokens proceeds.
4. **Freeze of a protocol address** (`isFrozen(vault)`, `isFrozen(AuctionHouse)`, `isFrozen(BondManager)`): premiums unclaimable; escrow stuck; bonds stuck. Push-based refunds make `clear` revert (T-07 scenario 3).
5. USDG/USD feed itself stale (24 h heartbeat, 0.5 % deviation, no weekend updates): treated as "TWAP invalid", never as "depeg" (D-015). Note the feed follows the same off-hours pattern as stock feeds, so a Sunday 23:59 read is normally ~2 days old — **26 h staleness will frequently fail on Sunday**, pushing weekend series to path 3 far more often than intended. Verify the actual cadence of `0x61B7e565…` before launch; if it is heartbeat-only over weekends, either raise `usdgMaxStale` to 80 h or accept path 3 as the de-facto weekend primary.

**Severity.** Medium (yield and escrow, bounded by amounts at rest; principal is in stock tokens). **Likelihood.** Low for depeg/pause; Medium for the staleness interaction in 5.

**Mitigations in SPEC.** D-015 conversion, band, staleness, `TwapRejected` events, fallback to path 3; premium accumulator separate from NAV (D-004) so a USDG problem never touches share accounting; caps.

**Enforced by.**
- `SettlementOracle._usdgOk`, `CoveredCallVault.claimPremium`, `AuctionHouse` (pull refunds per RS-06), `FeeRouter.collect` (must not revert `clear`).
- Tests: `Usdg.t.sol::test_T12_twapInvalidOutsideBand`, `test_T12_twapInvalidWhenStale`, `test_T12_weekendFallsToPath3OnDepeg`, `test_T12_weekdayHaltsOnDepegWhenTwapIsLastPath`, `AuctionHouse.threats.t.sol::test_T12_clearSucceedsWhenFeeRouterFrozen` and `test_T12_clearSucceedsWhenTreasuryFrozen` (fee is pulled by `flush`, D-049; a paused USDG delays `clear` until unpause, `test_T12_clearWaitsForUsdgUnpause`), `test_T12_settleSucceedsWhenUsdgPaused`; invariant **I-9**; fork test `Fork_Usdg.t.sol::test_T12_measureUsdgFeedCadence` that prints round timestamps for the last 14 days (informational, gates the parameter choice).

**Residual / recommendation.** Minimise USDG at rest: encourage prompt `claimPremium` (frontend), forward fees per clearing (already), and keep the pull pattern (RS-06) so a freeze never blocks state transitions. Bonds are the largest USDG balance at rest (25 000 per MM); accepted.

---

### T-13 · Keeper key compromise

**At risk.** Auction parameters within bounds; liveness; the guardian key on the same host.

**Scenario.** Attacker controls the keeper's transaction key (and, being on the same server, very likely the guardian hot key, D-012).
1. **Parameters.** Opens auctions with the minimum `strikeDistanceBps` (300 weekday, 100 weekend) and the minimum `reservePrice` (`minReserveBpsOfSpot` defaults to 0 = disabled). A colluding MM buys near-the-money calls at near-zero premium. Loss to depositors: the expected payout of a 3 %-OTM weekly call minus ~zero premium; per vault bounded by cap × P(ITM) × average moneyness, realistically a few percent of the 25 000 USDG cap per week.
2. **Timing.** Opens late within `openTolerance`; withholds `settle` to force the weekend path 3 (T-08); withholds `halt`/queue processing (all permissionless, anyone can call).
3. **Pause.** Uses the guardian key to pause deposits/auctions (T-15).
4. **Rotation lag.** If `openAuction` is gated by a `KEEPER_ROLE`, revoking it is a timelocked action: 48 h during which the attacker can open one bad series per vault (only one live series per vault at a time, and the weekday series lasts the whole week). If `openAuction` is permissionless, anyone can do scenario 1 at any time, which is worse; the spec implies the keeper calls it but does not say it is gated. **It must be gated.**

**Severity.** Medium (bounded by caps and by one series per vault per week). **Likelihood.** Medium: a hot key on a server is the most exposed key in the system.

**Mitigations in SPEC.** Bounds on distance and reserve; `S_ref` read on-chain; hints verified; every keeper duty is also permissionless so liveness does not depend on the keeper; guardian scope limited; caps.

**Enforced by.**
- `AuctionHouse.openAuction` (`onlyRole(KEEPER_ROLE)`, distance and reserve bounds, §5 schedule), `RiskModule`.
- Tests (`contracts/test/AuctionHouse.threats.t.sol`): `test_T13_openAuctionRequiresKeeperRole`, `test_T13_noRoleAdminExists`, `test_T13_distanceBelowBoundReverts`, `test_T13_reserveBelowCuratorFloorReverts`, `test_T13_reserveAboveSpotReverts`, `test_T13_weekendCannotOpenOutsideFridayWindow`; `test_T13_anyoneCanSettleHaltProcessQueues` awaits SettlementOracle.

**Residual / recommendation.**
- **RS-11** Curator-set per-vault floors: `minStrikeDistanceBps[kind]` (within protocol bounds) and `minReserveBpsOfSpot > 0` by default (e.g. 20 bps of spot for weekday single names). This turns scenario 1 from "near-zero premium at 3 % OTM" into "at least the curator's floor", and a curator is bonded.
- **RS-12** Guardian on a **second, off-server key** as well (two guardian addresses: the hot key for automation and a phone/hardware key held by the founder). A compromised server then cannot prevent the human from pausing new auctions immediately, which is the only fast response to a rogue keeper during the 48 h rotation. This changes D-012 only by adding a second holder.
- RUNBOOK.md: keeper key rotation procedure; keeper never holds stock tokens or USDG beyond gas ETH.

---

### T-14 · Admin key compromise or loss

**At risk.** Everything behind the timelock. This is the highest-severity internal risk because there is one key and no co-signer (D-003).

**What the 48 h delay protects.**
- Every privileged action is queued publicly 48 h before execution: parameter changes, `resolveHalted`, `slashBond`, `SafetyModule.slash`, `allowToken`, `treasury`, `sequencerFeed`, cap changes, role grants/revokes.
- Watchers (keeper alerting, the founder, depositors) see the proposal. In an **IDLE** vault, depositors can `withdraw`/`redeem` before execution.
- No key can block withdrawals in IDLE, `claimPremium`, `OptionToken.claim` or queue processing. There is no sweep/rescue function on any contract holding user funds (this must remain true; see below).

**What the 48 h delay does not protect.**
1. **Live series have no exit.** A weekday series is LIVE from Monday 14:15 to Friday 20:00 UTC. A proposal queued Monday 14:16 executes Wednesday 14:16 while the series is LIVE; the only depositor action is `requestRedeem`, which executes at the **next settlement**, i.e. after the malicious change already applied to that settlement. Weekend series are shorter (Fri 20:25 → Sun 23:59, ~52 h) but the same logic holds for a proposal queued right after clearing.
2. **Concrete attack chain with the admin key.** (a) Post an MM bond and win options in the auction (attacker can also just buy option tokens). (b) Queue `setSequencerFeed(maliciousFeed)` whose `latestRoundData` reports "down" forever, or `setWeekdayMaxStale(1 h)` for a heartbeat-only vault. (c) 48 h later it executes mid-series; at expiry every path fails; `halt`. (d) Queue `resolveHalted(seriesId, price = 100 × S)`. (e) 48 h later: `payoutPerOption ≈ 0.99e18` → the attacker claims ≈ 99 % of the vault's collateral. Total elapsed ≥ 96 h, fully visible, and **nobody can cancel** because the admin EOA is also the only canceller. Depositors' queued redeems execute after the payout at the post-payout share price.
3. **Delay reduction.** `TimelockController.updateDelay` is self-administered: the attacker queues a delay change to 0 (48 h), then acts at will. Still 48 h of visibility for the first step.
4. **Bond and stake slashing.** Up to 100 % of bonds and 30 % of the safety module per event; bonded parties cannot exit (7-day cooldown, 14-day unstake) faster than the timelock.
5. **`allowToken` with a malicious token/feed/pool.** Only affects deposits into the new vault, which are visible as new; low impact.
6. **`treasury` redirection.** Fee diversion only (≤ 20 % of premium).
7. **Key loss.** No parameter can ever change; no `resolveHalted`; a HALTED series is frozen forever: state ≠ IDLE, so no withdrawals, `payoutOwed` never set, queued redeems never execute. **Loss of the single admin key plus one halt = permanent lock of that vault.** D-003 says "funds remain withdrawable" when the key is lost; that is true only for vaults that are IDLE or reach IDLE through a normal settlement.

**Severity.** Critical. **Likelihood.** Low for compromise (hardware wallet, used rarely); Low but real for loss (single device, single person).

**Mitigations in SPEC.** 48 h timelock; deployer renounces; guardian separate; no upgradeability (T-17); parameter bounds (`weekdayMaxStale` `[1 h, 30 h]`, `weekendTwapBoundBps` `[300, 1500]`, `feeBps` `[0, 2000]`, `k` `[1, 20]`); treasury and team tokens outside the admin wallet.

**Enforced by.**
- `TimelockController` (OZ), `onlyOwner == timelock` on every setter, bounds in every setter, `Deploy.t.sol::test_T14_everyRoleHeldOnlyByTimelockOrGuardian`, `test_T14_noRescueOrSweepFunctionOnFundHoldingContracts` (selector scan of the compiled artifacts), `Governance.t.sol::test_T14_setterRevertsWithoutTimelock`, `testFuzz_T14_parameterBoundsEnforced`, `test_T14_resolveHaltedBoundedPrice` (RS-13).

**Residual / recommendation.** As specified, the attack chain in 2 works. Three changes close it and the key-loss case:
- **RS-13 Bound `resolveHalted`.** `|price8 / ref − 1| ≤ resolveBoundBps` where `ref` is the last valid Chainlink round at or before expiry (any age) and `resolveBoundBps` is a constant (not a parameter), e.g. 2 500. Worst case payout with a 5 % OTM strike and a 25 % pumped resolution: `(1.25 − 1.05)/1.25 = 16 %` of collateral, instead of 99 %. Still bad, no longer total.
- **RS-14 Snapshot oracle parameters at `openAuction`.** Copy `weekdayMaxStale`, `weekendTwapBoundBps`, `twapGrace`, `swapNotionalUSDG`, `impactBps`, `sequencerFeed` into the `Series` struct at open. A parameter change then affects only series opened after execution, and every depositor gets an IDLE window (Sunday 14 h) between seeing the proposal and the first series it applies to. This alone breaks step (c) of the attack chain.
- **RS-15 Permissionless late resolution.** After `haltedTimeout` (e.g. 7 days past expiry) anyone can `resolveHaltedByOracle(seriesId, hint)` using the first valid Chainlink round after expiry, any lateness, with `oraclePaused == false`. This removes the "lost key freezes a halted vault forever" failure and removes the admin from the happy path of most halts (most halts are oracle outages that end within days). `resolveHalted` by timelock stays for the case where the feed never returns.
- A canceller: OZ `TimelockController` supports a separate `CANCELLER_ROLE`. Giving it to the guardian creates a deadlock (the guardian could cancel its own revocation). Giving it to a second cold key held by the same founder ("veto key", used only to cancel) is compatible with D-003's "one operator" and is the cheapest way to make a compromised admin key non-fatal. Founder decision; record either way.
- Admin key custody, backup and the "what if lost" runbook belong in RUNBOOK.md (D-003 consequence, still empty).

---

### T-15 · Guardian key compromise

**At risk.** Liveness only: new auctions and deposits.

**Scenario.** Hot key on the keeper server (D-012) is stolen. The attacker pauses new auctions and deposits on all vaults and keeps re-pausing after each unpause. Yield stops. The attacker cannot move funds, change parameters, block IDLE withdrawals, `claimPremium`, `OptionToken.claim`, queue processing or `settle` (SPEC §15, invariant **I-7**). A live series still settles; the vault then sits IDLE with withdrawals open.

**Severity.** Low. **Likelihood.** Medium (hot key).

**Mitigations in SPEC.** Scope limited by construction; rotation by timelocked `grantRole/revokeRole` (48 h); unpause also possible by timelock.

**Enforced by.**
- `RiskModule` (only pause flags writable by `GUARDIAN_ROLE`).
- Tests: `RiskModule.t.sol::test_T15_guardianCannotCallAnySetter` (fuzz over every selector of every contract with the guardian as caller; only the pause selectors succeed), `test_T15_pauseDoesNotBlockWithdrawInIdle`, `test_T15_pauseDoesNotBlockSettleOrClaims`; invariant **I-7** (storage diff after any guardian call touches only pause flags).

**Residual.** 48 h of forced idleness per compromise. If RS-12 (second guardian key) is adopted, note that either guardian can unpause the other's pause, so a stolen hot key cannot keep the protocol paused against the founder's key; and if the canceller idea from T-14 is adopted, the canceller must **not** be the guardian.

---

### T-16 · Reentrancy

**At risk.** Accounting integrity (I-1…I-4), escrow, premium.

**External call surface** (every one is a potential reentry point):
- Stock token `transfer/transferFrom` — beacon-proxied, upgradeable by the issuer; today no hooks, tomorrow unknown (T-11.4).
- USDG `transfer/transferFrom` — proxied, Paxos-controlled.
- `OptionToken.mint` → `onERC1155Received` on contract bidders, **inside `clear`**, before or after premium accounting depending on ordering.
- `OptionToken.claim` → burns, then stock transfer.
- Vault share `_update` hook settles premium on every transfer; shares are our own ERC-20, no external hook.
- `FeeRouter.collect`, `BondManager`, `CapController` (reads feeds and pools: view), `SettlementOracle` (view except `settle`).
- Cross-contract: `AuctionHouse.clear` → vault `creditPremium` → ... ; a callback in `onERC1155Received` can call `vault.deposit` (blocked: state AUCTION), `auction.bid` (blocked: `now ≥ auctionClose`), `claimPremium` (reads `premiumClaimable` computed from the accumulator as of that moment; if premium is credited **before** minting, the callback could claim a premium share for shares it holds — legitimate; if credited after, nothing extra; either way the invariant is that `claimPremium` only pays what `_update` has already settled).
- Read-only reentrancy: a contract reading `totalAssets()`/`convertToAssets` mid-`settle` (before `payoutOwed` is updated) would see an inflated NAV. External integrators (Morpho oracles, points indexer) reading at a block boundary are safe; in-transaction readers are not.

**Severity.** High. **Likelihood.** Medium as a bug class; the ERC-1155 callback inside `clear` is the concrete, present-day vector.

**Mitigations in SPEC.** OZ `ReentrancyGuard`, CEI, boring patterns (rule 8).

**Enforced by.**
- `nonReentrant` on every state-changing external function of `CoveredCallVault`, `AuctionHouse`, `OptionToken.claim`, `BondManager`, `FeeRouter`, `SettlementOracle.settle`. Cross-contract: a single `ReentrancyGuardTransient`-style lock shared per vault (the vault exposes `lock/unlock` callable only by `AuctionHouse` and `SettlementOracle`) or, simpler, all mutating flows enter through the vault which then calls out. Effects before interactions everywhere; ERC-1155 mint at the very end of `clear` (after premium, fee, refunds are recorded) and preferably with the receiver check moved to `bid` time (RS-07).
- Tests: `Reentrancy.t.sol::test_T16_erc1155CallbackCannotReenterVaultOrAuction` (malicious receiver tries every entry point during `clear`), `test_T16_maliciousStockTokenHookCannotReenter` (mock token with a transfer hook), `test_T16_claimPremiumInsideCallbackPaysOnlySettledAmount`, `test_T16_readOnlyReentrancyNavDuringSettle` (documents the window; asserts `payoutOwed` is updated before any external call in `settle`); invariants I-1…I-4 run with a handler that includes reentrant actors.

**Residual.** A future issuer upgrade adding hooks is covered by the guards if every mutating function is guarded; keep the selector-scan test that asserts every non-view external function on fund-holding contracts is `nonReentrant`.

---

### T-17 · Upgradeability

**Decision to recommend: fully immutable core contracts; migration by new deployment. Justification:**
1. **Key model.** The only privileged key is a single EOA behind a 48 h timelock (D-003). With a proxy, that key owns all code, and T-14 shows the 48 h delay gives live-series depositors no exit. An upgrade can do anything, including removing every bound in this document. Immutability turns the admin's worst case from "arbitrary code" into "parameters within bounds", which is what the rest of this model relies on.
2. **Attack surface.** Proxies add initializer bugs, storage-layout collisions, `delegatecall` to a wrong implementation, and beacon/implementation governance. Every one of these has produced real losses. Rule 8 (boring patterns) argues against carrying them for a v1 with nine vaults and 25 000 USDG caps.
3. **Stacked upgrade risk.** The stock tokens are already beacon proxies upgradeable by the issuer with unknown governance (T-11.4), and the chain is upgradeable by 7/8 council with no delay (T-20). Depositors already carry two layers of upgrade risk they cannot audit; the protocol should not add a third.
4. **Audit and verification.** Immutable bytecode is what gets audited and what stays deployed; Blockscout verification of a proxy shows an implementation that can change after the audit.
5. **Migration is cheap here.** Vault positions are ERC-4626 shares of a single token with no lock: migration = `withdraw` in IDLE, `deposit` in the new vault. Series are weekly, so there is always an IDLE window within seven days. Option tokens are per-deployment and settle within the week. Bonds are withdrawable after the 7-day cooldown once no series is live.

**What a migration needs from v1 (build now, cost is small):**
- `sunset(vaultId)` behind the timelock: after the current series settles the vault refuses `openAuction` permanently, stays IDLE, withdrawals open forever. Combined with guardian `pauseNewAuctions` for the immediate reaction.
- Frontend "migrate" flow reading `sunset` flags; the new deployment lists the old one for one-click withdraw/deposit.
- No storage or address dependencies between deployments except the allowlisted external contracts.

**What stays configurable:** parameters within bounds (SPEC §15) and `allowToken` for new vaults. Contract **addresses** referenced by a vault (oracle, auction house, fee router, bond manager, cap controller) are immutable per vault; swapping any of them is a code change in disguise and is excluded.

**Severity if violated.** Critical. **Likelihood.** N/A; this is a design rule.

**Enforced by.**
- No `ERC1967`/`UUPS`/`Beacon`/`TransparentProxy` imports in `src/` (CI grep); constructor-only initialisation; `immutable` for every cross-contract reference.
- Tests: `Deploy.t.sol::test_T17_noProxyBytecodeMarkers` (no `delegatecall` in fund-holding contracts, checked via the compiled opcode stream), `test_T17_crossReferencesAreImmutable` (setters for those addresses do not exist), `Vault.t.sol::test_T17_sunsetBlocksOpenAuctionKeepsWithdrawals`.

**Residual.** A bug found after deployment costs a migration week and a new audit diff. Accepted; it is the cheapest of the alternatives at this scale. Revisit only if the admin becomes a real multisig and the protocol has an exit mechanism for live-series depositors.

---

### T-18 · Deposit-queue griefing blocks `openAuction`

**At risk.** Liveness: the weekly auction; with it all premium for the week.

**Scenario.** `openAuction` requires the deposit queue to be empty (SPEC §5). `requestDeposit` is allowed outside IDLE, and nothing in the spec forbids it during IDLE. An attacker submits a dust `requestDeposit` in the block before Monday 14:00 UTC, and again after every `processDeposits`. The keeper's `openAuction` reverts each time. On a 100 ms FCFS chain a bot wins this race cheaply. Within `openTolerance` (2 h) the week is skipped; repeat every Monday and Friday.

**Severity.** Low–Medium (no loss of principal; total loss of yield while sustained). **Likelihood.** High: trivially cheap, and skipping auctions may benefit a competitor or a short-premium party.

**Mitigations in SPEC.** None directly; `processDeposits` is permissionless.

**Enforced by (after RS-16).** `CoveredCallVault.requestDeposit` reverts in IDLE (use `deposit`); `openAuction` executes up to `maxQueueOpsPerOpen` remaining requests itself before checking emptiness. Tests: `Queue.t.sol::test_T18_requestDepositRevertsInIdle`, `test_T18_openAuctionDrainsSmallQueue`, `test_T18_openAuctionWithLargeQueueRevertsWithReason` (bounded gas), fuzz on queue lengths.

**Residual / recommendation.** **RS-16** as above. With it, the queue can only grow during AUCTION/LIVE/HALTED and only shrink after settlement, so a griefer cannot add to it in the IDLE window before open. Do the same analysis for `requestRedeem`: queued redeems do not block open (they are carved out of `offeredQty`), so no change needed there.

---

### T-19 · Keeper and MM collusion on auction parameters

Covered in T-13 scenario 1; listed separately because it does not need a key compromise, only a dishonest operator. Severity Medium, likelihood Medium (the operator is also the founder today, which makes this a reputational rather than adversarial risk, but the design should not depend on it). Mitigation is RS-11 (curator floors) plus public, indexed `AuctionOpened` events with `sRef`, `strike`, `reservePrice` so any observer can compute the implied vol the keeper accepted. Tests as in T-13.

---

### T-20 · Chain-level trust

Robinhood Chain is "not even Stage 0" (L2BEAT): core contracts upgradeable by 7/8 council with no delay and no exit window; two whitelisted validators; centralized FCFS sequencer operated by the issuer of the collateral; ArbOS 61 transaction filtering can neutralise forced inclusion; `block.timestamp` is the sequencer's clock. Any of these can censor `settle`, `claim` or `withdraw`, reorder auction bids, or in the extreme rewrite state. Severity Critical, likelihood Low. **Not mitigable by the protocol**; accepted and disclosed. Operational consequence: keep caps small relative to what a chain-level incident could freeze, and never describe the protocol as trustless.

---

## 4. Spec revisions (all sixteen accepted 2026-09-02)

| ID | Change as adopted | Closes | Decision |
|---|---|---|---|
| RS-01 | TWAP liquidity check uses harmonic-mean liquidity from `secondsPerLiquidityCumulativeX128` over the window instead of spot `liquidity()` | T-03.3 | D-018 |
| RS-02 | Path 2 requires ≥ `minObservationsInWindow` (3) observations inside the window; else fall through | T-03.4, T-05.4 | D-019 |
| RS-03 | Latest pool observation at or before expiry ≥ `expiry − 900`; folded into RS-02 as its second condition | T-05.4 | D-019 |
| RS-04 | Bound reference for every TWAP = last Chainlink round with `updatedAt ≤ expiry` (`refRound`), not latest at call time | T-08.2 | D-021 |
| RS-05 | **Amended:** jump guard is per vault, ±30 % vs `sRef` (reference spot at open) on every path, with a multiplier-change exception; tripped guard → HALT `JUMP_GUARD` | T-02.1, T-10.2 | D-025 |
| RS-06 | Pull-based refunds; fee credited internally and flushed separately; `clear` makes no outbound transfer | T-07.3, T-12.4 | D-023 |
| RS-07 | **Amended:** option mints are pull-based (`claimOptions`), no receiver gate at `bid` and no callback in `clear` | T-07.4, T-16 | D-024 |
| RS-08 | MM bond lock by participation (`lock` at bid, release at clear for unfilled / at SETTLED or RESOLVED for filled) | T-07.6, T-03 | D-030 |
| RS-09 | `openAuction` reverts if `token.effectiveAt()` falls inside the series | T-10 | D-026 |
| RS-10 | Keeper polls beacon and USDG implementation; guardian pauses on change | T-11.4 | D-020 |
| RS-11 | Curator floors `minStrikeDistanceBps[kind]`, `minReserveBpsOfSpot[kind]` (defaults 10 / 3 bps, never 0) | T-13.1, T-19 | D-027 |
| RS-12 | Second guardian key off-server, held by the founder | T-13, T-15 | D-029 |
| RS-13 | `resolveHalted` bounded to ±25 % of `refRound` (constant `resolveBoundBps = 2 500`) | T-14.2 | D-022 |
| RS-14 | `Series.params` snapshot of all oracle parameters at `openAuction` | T-14.1–2 | D-031 |
| RS-15 | **Amended:** permissionless `resolveHaltedByOracle` after 7 days, first post-expiry round **clamped** into the band (always resolvable) | T-14.7, T-11.6 | D-033 |
| RS-16 | **Amended:** `requestDeposit` allowed in any state, executes at the next IDLE; `openAuction` never requires an empty queue | T-18 | D-032 |
| — | `openAuction` explicitly behind `KEEPER_ROLE`; everything else permissionless | T-13.4 | D-028 |
| — | `sunset(vaultId)` from day one; immutable core | T-17 | D-034 |

Still open, not part of the sixteen (SPEC §18 OQ-001, OQ-002): a canceller ("veto") key on the timelock, which must not be the guardian; measuring the USDG/USD feed weekend cadence before choosing `usdgMaxStale`, and SPY/QQQ pool depth before creating those vaults.

**Residual notes after adoption.**
- T-02 / T-10: the D-025 multiplier exception admits exactly the feed/multiplier mis-sequencing case (a price that moved by the multiplier ratio). D-026 confines it to changes staged after open; the keeper must alert on any `UIMultiplierUpdated` during a live series and the guardian pauses new auctions until the settlement is reviewed. Re-examine after the first corporate action on a live series.
- T-14: with D-022, D-031 and D-033 the attack chain in T-14.2 is bounded to ≈ 16 % of one series' collateral and requires a change to a *future* series that depositors can exit before. The remaining single-key residual is governance liveness (no parameter can ever change if the key is lost); OQ-001 is the only further reduction on the table.
- T-07: slot filling (T-07.2) is not addressed by the sixteen; the reserve floor of D-027 bounds it. Revisit if a cartel of bonded addresses is observed.
- T-12.5: if the USDG/USD feed is heartbeat-only over weekends, path 3 becomes the de-facto weekend primary. Decide `usdgMaxStale` from the fork measurement (OQ-002) before launch.

---

## 5. Accepted risks (disclosed, not mitigated)

- Issuer powers over stock tokens: pause, block, burn, beacon upgrade (T-11).
- Chain governance and sequencer trust (T-20), including no usable forced inclusion and no sequencer uptime feed.
- Weekend gap between Sunday settlement and Monday open (T-04).
- USDG issuer pause/freeze on protocol addresses (T-12).
- Single-operator admin key (D-003): governance liveness if the key is lost (no parameter can ever change); loss bounded by D-022/D-031/D-033.
- TWAP nudges inside the sanity bound, bounded by caps (T-03.2).
- Guardian-induced idleness for up to 48 h (T-15).

---

## 6. Test naming and coverage rule

- Every test that enforces a threat carries the threat id in its name: `test_T07_…`, `testFuzz_T09_…`, `invariant_I1_…`. `forge test --match-test T07` must run at least one test for every threat with severity ≥ Medium; a CI script greps this file for `T-\d\d` ids and fails if any has zero matching tests once `src/` contains more than the scaffold.
- Invariant handlers must include external actors the protocol does not control: an issuer that can `pause`/`burn`, a Paxos that can `freeze`, a malicious ERC-1155 receiver, a pool whose liquidity and tick the handler moves, an aggregator with settable rounds and phases.
- Fork tests (`--fork-url` archive RPC, block ≥ 52502703) cover the real NVDA feed/pool data cited in SPEC §1.3 and §1.5; the mock suite covers everything the fork cannot reproduce (halts, phases, depeg, freezes).
- This file is updated in the same commit as any change to SPEC §8, §9, §13, §15 or to the invariant list.
