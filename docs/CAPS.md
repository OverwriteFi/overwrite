# CAPS — deposit caps at launch and how they grow

Internal document. 2026-09-05. Owner: founder / timelock proposer. Not a promise to users; the app shows only the
live `CapController.vaultCapUSD(vault)` value.

## 1. Why caps, and why 25 000 USDG

Mainnet opens **without an external audit**. The internal audit (docs/AUDIT-PREP.md) is the substitute, and its
residual is bounded the only way it can be bounded on-chain: by the amount at risk. Two independent arguments give
the same number.

1. **Manipulation economics (SPEC §9.3, D-010, D-011).** The weekend settlement path is a 60-minute Uniswap v3 TWAP
   gated by the depth rule "250 000 USDG must move the price ≤ 1 %". The worst-case profit from nudging the TWAP
   inside the ±15 % weekend bound is ≈ 8.7 % of the *notional written* for a 5 % OTM strike. With 25 000 USDG of
   assets in a vault that ceiling is ≈ 2 200 USDG per weekend, well below the cost of moving a pool that passes the
   depth rule. Caps are what keep that inequality true; the depth rule alone does not.
2. **Unaudited-code exposure.** A total-loss bug in one vault costs at most the cap. 25 000 USDG per vault is a
   loss the treasury can make whole out of pocket, which is the honest definition of "audited in production".

Launch configuration (`contracts/config/4663.json`, D-011): `capMode = FIXED`, `capUSD[NVDA] = 25 000 000 000`
(6-dec USDG), one vault. The cap is enforced by `CapController.remainingDepositAssets` (used-USD term rounds **up**,
so dust can never breach it) and read through `CoveredCallVault.maxDeposit`. Queued deposits are checked at
execution, not at request, so raising a cap releases the queue in order.

**Default for every new vault: 25 000 USDG**, regardless of the underlying. A vault is added by `AuctionHouse.registerVault`
+ `SettlementOracle.registerVault` + `CapController.setCapUSD(vault, 25_000e6)` in one batch; the cap is never
inherited from another vault.

## 2. Raising a cap: the timelock procedure

Every cap lever is `onlyOwner` on `CapController`, and the owner is the 48 h `TimelockController` whose single
proposer/executor is the admin hardware wallet (SPEC §15, D-003). There is no fast path and no guardian override;
a guardian can only *lower effective exposure* by pausing deposits (`RiskModule.pauseDeposits`), never raise a cap.

Procedure (RUNBOOK §3 is the general form):

1. **Decide and record.** Write the target, the reason and the evidence (§3 checklist below) as a `D-nnn` entry in
   docs/DECISIONS.md *before* scheduling. Caps are a governance decision; the entry is the audit trail.
2. **Build the calldata.** For FIXED mode, one call per vault:
   ```bash
   cast calldata "setCapUSD(address,uint256)" <VAULT> <NEW_CAP_USD6>
   ```
   Batch several vaults into one `scheduleBatch` so they land together.
3. **Schedule** from the admin EOA: `TimelockController.scheduleBatch(targets, values, payloads, 0x0, salt, 172800)`.
   Post the operation id and the intended values in the ops channel; the 48 h window is the public review period.
   Anyone can verify the pending values with `cast call <TIMELOCK> "getTimestamp(bytes32)"` and by decoding the payload.
4. **Wait 48 h.** During the wait the keeper's health monitor keeps reporting `vaultCapUSD` and utilisation; if
   anything in §3 stops being true, `cancel(id)` from the admin EOA (RUNBOOK §7) and start again.
5. **Execute** `executeBatch` with the same arguments. Verify:
   ```bash
   cast call <CAP_CONTROLLER> "capUSD(address)(uint256)" <VAULT> --rpc-url robinhood
   cast call <VAULT> "maxDeposit(address)(uint256)" 0x0000000000000000000000000000000000000001 --rpc-url robinhood
   ```
6. **Announce** the new cap after execution, never before (a pre-announced raise invites a queue race at the exact
   block; deposits are first-come and the queue is processed in order anyway).

Lowering a cap is the same procedure and takes effect immediately on execution; it never forces a withdrawal
(SPEC §12), it only stops new deposits until utilisation falls below the new value.

## 3. Pre-conditions for any raise

All of these must hold at scheduling time and still hold at execution. They are the conditions under which the two
arguments in §1 stay true at the larger size.

- **Settlement track record.** At least the stated number of consecutive series on that vault settled on paths 1–3
  with no `ShortfallRecorded`, no `SeriesHalted`, and no manual `resolveHalted`.
- **Pool depth.** The vault's USDG pool passes the SPEC §9.3 depth rule with margin: `swapNotionalUSDG` at
  `impactBps` must be ≤ 1/4 of the harmonic-mean liquidity capacity over the last four weekend windows (the
  keeper logs `capacity / notional` each weekend). Rule of thumb: **total vault assets ≤ 10 % of the two-sided
  pool depth at ±1 %** — above that the pool, not the cap, is the binding constraint on manipulation profit.
- **Oracle health.** No Chainlink staleness event > `weekdayMaxStale` on that feed in the last 30 days; USDG/USD
  feed inside the band every Sunday of the window.
- **No open Critical/High finding** in docs/AUDIT-PREP.md, and no open incident.
- **Backstop present (post-token only, §4).** The safety module's USD value covers the next step by the `k` rule.

## 4. Schedule: how caps grow as the backstop grows

Two regimes, separated by the token launch and the `capMode` switch (CLAUDE.md rule 6: both exist from day one).

### 4.1 Pre-token (FIXED mode) — bootstrapping on track record alone

Per vault, each step needs the §3 conditions and the stated track record. Steps are ×2 or ×2.5, never larger,
so a single raise never more than doubles the amount at risk.

| Step | Cap per vault (USDG) | Earliest after | Requires |
|---|---:|---|---|
| 0 (launch) | 25 000 | — | internal audit done (docs/AUDIT-PREP.md), invariant campaign green |
| 1 | 50 000 | 4 settled weeks (8 series) | §3; keeper has run unattended for the whole window |
| 2 | 100 000 | 8 settled weeks | §3; **external audit engagement signed**, scope = docs/AUDIT-SCOPE.md |
| 3 | 250 000 | external audit **report delivered**, all High/Critical fixed and re-tested | §3; equals the `swapNotionalUSDG` depth threshold, the ceiling of the pre-token regime |

**Pre-token ceiling: 250 000 USDG per vault.** Above that the manipulation-profit argument in §1 no longer holds
by itself (vault assets ≈ the depth-rule notional), so the next lever must be a real backstop, not more track
record. Protocol-wide pre-token exposure is therefore ≤ 250 000 USDG × active vaults; with NVDA alone, 250 000.

### 4.2 Post-token (SAFETY_MODULE mode) — caps follow the backstop

At launch of WRITE, the timelock switches **as one batch** (RUNBOOK §9: `setSafetyModule`, then `setCapWeightBps`
for every vault, then `setCapMode(SAFETY_MODULE)`; split across batches there is a window with mode on and weights
zero, which closes deposits protocol-wide). From then on:

```
globalCapUSD      = k × SafetyModule.valueUSD()          k ∈ [1, 20], default 5 (D-011)
capPerVault       = globalCapUSD × capWeightBps[vault] / 1e4,   Σ weights ≤ 1e4
effectiveCap      = min(capPerVault, capUSD[vault])        (capUSD kept as a hard ceiling per vault)
```

`SafetyModule.valueUSD()` is `totalStaked × WRITE/USD` from `WritePriceOracle` (Chainlink if a feed exists, else the
30-min pool TWAP inside the sanity band; unavailable ⇒ 0 ⇒ **every cap closes**, D-069). So the cap grows only
when real, slashable WRITE is staked, and it *shrinks automatically* when stake leaves or the WRITE price falls —
no proposal needed in either direction.

Governance schedule for the two knobs it does control:

| Phase | `k` | `capUSD` ceiling per vault | Condition to move to the next phase |
|---|---:|---:|---|
| Switch-over | 5 | keep the FIXED-mode value (250 000 at most) | staked value ≥ 2 × Σ current caps for 4 consecutive weeks (i.e. the backstop alone would already cover a 50 % loss protocol-wide); `WritePriceOracle` has answered every hourly keeper read for those weeks |
| Growth | 5 | 1 000 000 | external audit report published; no slash event in the last 90 days; at least one `injectCoverage` drill run end-to-end on testnet with the real timelock calldata |
| Steady state | 5 → 10 (one step) | remove the ceiling (`setCapUSD(vault, 0)`, which in SAFETY_MODULE mode means "weight alone applies") | 6 months in Growth with no shortfall; second audit or a public bug bounty live for 90 days |
| Never | > 10 | — | `k > 10` means the backstop covers under 10 % of a total loss; not proposed without a re-underwriting of the whole model |

Rules that hold in every phase:

- **One knob per proposal.** A batch changes `k` *or* weights *or* one vault's ceiling, never two of them, so a
  mistake is one thing to undo.
- **Weights sum ≤ 1e4** is enforced on-chain; a new vault gets weight from the pool of unassigned bps, never by
  silently diluting others — if the sum is already 1e4 the batch must lower another vault first, and that is
  a two-step over two windows.
- **The 30 % slash cap and 14-day interval** (SPEC §14) bound how fast the backstop can be consumed; the cap
  schedule above keeps total exposure ≤ `k ×` backstop, so a single maximal slash always leaves ≥ 70 % of the
  backstop for the next event.
- **Reverting to FIXED** (`setCapMode(FIXED)`) is the emergency lever if the WRITE price source misbehaves for
  longer than a pause is acceptable; `capUSD` values are still in storage and take effect immediately.

## 5. Monitoring that gates the schedule

Already produced by the keeper's health monitor (keeper/, RUNBOOK §11.5); the values a raise proposal must quote:

- `vaultCapUSD`, `totalAssets × S_cap` (utilisation), and the deposit-queue length per vault.
- Weekend depth margin: `capacity / swapNotionalUSDG` from the TWAP depth check, per settlement.
- Settlement path histogram (1/2/3/4/5) and every `PathRejected` / `JumpGuardTripped` / `SeriesHalted` event.
- Post-token: `SafetyModule.valueUSD()`, `WritePriceOracle.previewPrice()` source and reason, `lastSlashAt`.

If any of these stops being reported for more than 24 h, no cap proposal is scheduled until it is back.
