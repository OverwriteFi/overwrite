# AUDIT-PREP — internal audit of `contracts/`

Date: 2026-09-05 · Base commit: `707ab99` (working tree; the audit changes are recorded as D-113) · Reviewer: internal, no
external auditor yet. Purpose: everything an external auditor asks for first, done in-house, so mainnet can open behind a
hard deposit cap (docs/CAPS.md) while the external audit is procured. Companions: docs/AUDIT-SCOPE.md (scope, trust
assumptions, invariants), docs/CAPS.md (cap schedule), docs/DECISIONS.md D-113 (every change made in this pass).

Tooling

| Tool | Version | Invocation |
|---|---|---|
| forge | 1.5.1-stable (b0a9dd9) | `forge test`, `forge coverage --ir-minimum`, `FOUNDRY_PROFILE=deep forge test --match-path "test/invariants/*"` |
| slither | 0.11.6 (pip, `python -m slither`) | `python -m slither . --filter-paths "lib/\|test/\|script/\|src/mocks/"` (102 detectors) |
| aderyn | 0.6.8 (Linux binary run in `ubuntu:24.04`; there is no Windows build) | `aderyn --src src/ -x mocks/ .` (88 detectors) |
| reviews | four fresh-context subagents, read-only | see §4 |

Baseline before the pass: 706 tests, 0 failed. After the pass: **724 tests, 0 failed, 1 skipped** (the RPC-gated fork test).

---

## 1. Static analysis

Every finding is either **fixed** (code changed) or **documented** (kept, with the reason). IDs `A-nn` are this pass's;
detector names are given so a finding can be re-located after a re-run.

### 1.1 Fixed

| ID | Source | Where | Finding | Fix |
|---|---|---|---|---|
| A-01 | aderyn H-2 `unsafe-casting` (OracleMath.sol:20); own review | `SettlementOracle._observe`, `WritePriceOracle._twap` | `twapTick` truncates the `int56` average to `int24`; an out-of-range average would make `TickMath.getSqrtRatioAtTick` revert **outside** the `observe` try/catch and brick `settle` instead of failing the path. | Both readers range-check the floored `int56` tick (`OracleMath.twapTick56`, R-4 corrected the first version which checked the truncated average) and fail the path with `OBSERVE` / `TICK_RANGE`. Tests: `test_path2_reason_OBSERVE_onOutOfRangeTick`, `testFuzz_path2_neverRevertsOnArbitraryCumulatives`, `test_writePrice_notOkOnOutOfRangeTick`. |
| A-02 | own review | `WritePriceOracle._twap` | Cumulative deltas were checked subtractions; Uniswap cumulatives wrap by design. Consumers catch the revert, so the impact was a closed cap, not a loss. | `unchecked`, as in SettlementOracle. |

### 1.2 Documented (kept)

**slither — High**

| ID | Detector | Where | Why it is not a bug |
|---|---|---|---|
| A-03 | `arbitrary-send-erc20` ×2 | `FeeRouter.flush` → `usdg.safeTransferFrom(auctionHouse, treasury \| curator, amount)` | Design (D-023, D-085): the AuctionHouse grants the standing approval in its constructor; `amount` is `pending[vault]`, increased only by `collect` (`onlyAuctionHouse`, from `clear`) and zeroed before the pull; recipients are timelock-set. Invariants I-3, I-36. |
| A-04 | `weak-prng` | `AuctionHouse.canOpen`: `at % WEEK` | Epoch-week schedule arithmetic (D-046), not randomness. |

**slither — Medium**

| ID | Detector | Count | Why it is not a bug |
|---|---|---|---|
| A-05 | `divide-before-multiply` | 2 | `TickMath` is the verbatim Uniswap v4-core ladder (D-058). `computeStrike`: `grid = sRef×25/1e4` then `ceilDiv(kRaw, grid)×grid` *is* the SPEC §7.2 grid rounding; `grid == 0` reverts `GridZero`. Fuzzed. |
| A-06 | `incorrect-equality` | 17 | All compare against sentinel `0`/`bytes32(0)`/enum values, or are the deliberate D-045 `totalSupply() == balanceOf(vault)` skip check. |
| A-07 | `reentrancy-no-eth` | 7 | State after external call in `SafetyModule.*` (callee `EmissionsController.claim`), `CoveredCallVault.{openSeries,settleSeries}` (callee `OptionToken`), `AuctionHouse.openAuction` (callee `vault.openSeries`). Every callee is a protocol contract held as an `immutable` or set-once; all entry points `nonReentrant`. Reentrancy from untrusted code is exercised by `ReentrantActor` (`invariant_T16_noReentrancy` ×2, `test_T16_*`). |
| A-08 | `uninitialized-local` | 7 | Zero-default locals, each assigned on every path that reads it. |
| A-09 | `unused-return` | 13 | Deliberately dropped tuple fields (`roundId`, `startedAt`, `answeredInRound`, `slot0`/`observations` fields, `this.twap`'s USDG-denominated leg). |

**slither — Low / Informational**

| ID | Detector | Count | Why it is not a bug |
|---|---|---|---|
| A-10 | `timestamp` | 49 | The protocol is a schedule; every comparison is intended. Sequencer drift is T-05 (accepted, bounded). |
| A-11 | `calls-loop` | 14 | Bounded loops over trusted or read-only callees: ≤ 64 bidders, ≤ `minObs + 2` observations, ≤ 32 garbage rounds, 5 WRITE holders. Gas measured in `test_T07_*`. |
| A-12 | `reentrancy-benign` / `reentrancy-events` | 11 | Events after trusted calls. |
| A-13 | `missing-zero-check` | 2 | `WritePriceOracle.setChainlinkFeed(0)` / `setSequencerFeed(0, …)` are the documented **clear** operations (same convention as `OracleParams.sequencerFeed == 0`); `onlyOwner`. |
| A-14 | `unimplemented-functions` | 1 | `BondManager.requiredAmountOf` is a public mapping whose getter satisfies the interface; slither does not resolve mapping getters. |
| A-15 | `low-level-calls` | 1 | `LiquidityEscrow._probeHoldsWrite` uses `staticcall` so a non-conforming candidate cannot revert the raw-AMM probe (D-094). |
| A-16 | `cyclomatic-complexity`, `too-many-digits` | 4 | Informational: the §9 decision tree, the Uniswap constants. |

**aderyn**

| ID | Detector | Count | Why it is not a bug |
|---|---|---|---|
| A-17 | H-1 `state change after external call` | 40 | A-07's population plus constructor / `registerVault` / `setSink` / `setPool` wiring asserts (view calls into protocol contracts before storing an address). All mutating entry points are `onlyOwner` and/or `nonReentrant`. |
| A-18 | L-1 `centralization risk` | 90 | Every `onlyOwner` function. The owner is the 48 h `TimelockController` with one hardware-wallet proposer/executor (D-003); the deployer never owns anything (D-103); `renounceOwnership` is disabled everywhere (D-100). Disclosed in AUDIT-SCOPE §3–§5. |
| A-19 | L-9 `nonReentrant is not the first modifier` | 15 | Access modifiers only read `msg.sender`; the guard is entered before any body statement. |
| A-20 | L-2 / L-10 loops with costly ops or `revert` | 7 | Queue processing bounded by `n ≤ MAX_QUEUE_OPS = 100` and gas-measured; clearing by `MAX_BIDS`; `Vesting._removeId` by a beneficiary's own schedules. |
| A-21 | L-3 empty block | 1 | `_marginalRange` scan loop with an empty body. |
| A-22 | L-4…L-8, L-12…L-14 | ~70 | Style (literals, constructor-struct shadowing, single-use modifiers, zero-init locals, public functions unused internally). |
| A-23 | L-11 address set without checks | 1 | `setSequencerFeed`, see A-13. |

### 1.3 From the manual read

| ID | Where | Note | Status |
|---|---|---|---|
| A-24 | `forge coverage --ir-minimum` | Five tests fail **only** under the coverage build: `test_open_weekendStandaloneWindow`, `test_e2e_dayInTheLife`, `test_emissions_accrueProRata`, `test_emissions_unallocatedWhileNobodyStaked`, `AuctionInvariants.test_handlerReachesEveryState`. They pass under the default profile and under `via_ir = true, optimizer = false`. The trace shows the *test contract* computing `block.timestamp − t0 == 0` right after a visible `VM::warp`, i.e. the instrumentation of test code, not the contract under test. `forge coverage` produces no report when any test fails, so the coverage runs below exclude those five with `--no-match-test`; their lines are covered by neighbouring tests. | Foundry artefact; re-check on the next release. |
| A-25 | `AuctionHouse.referencePrice` | Uses `capPrice` (Chainlink ≤ 80 h, no `oraclePaused`) as `S_ref`, not `SettlementOracle.referencePrice` (OQ-005). Needs an AuctionHouse redeploy. The freeze half of OQ-005 is closed (G-1). | Known issue, AUDIT-SCOPE K-2. |
| A-26 | contract sizes | After this pass: AuctionHouse 23 712 B (864 B headroom), SettlementOracle 23 486 B (1 090 B), CoveredCallVault 21 175 B. Any further feature in the first two needs trimming or a library (D-058 precedent). | Note for the next change. |

---

## 2. Coverage

Command: `forge coverage --ir-minimum --report summary --report lcov --no-match-coverage "(test|script|mocks|lib)"
--no-match-test "<the five A-24 tests>"` (the default build hits *stack too deep* in `CoveredCallVault.fuzz.t.sol`).
Target: ≥ 90 % lines per contract. **Every contract is above 93 %; total 98.5 % lines.**

<!-- COVERAGE_TABLE -->
Final tree (after every fix in §4); 713 tests run under coverage (the five A-24 exclusions removed 10 test functions across suites):

| File | % Lines | % Statements | % Branches | % Funcs |
|---|---|---|---|---|
| src/AuctionHouse.sol | 99.15 % (351/354) | 99.00 % | 97.37 % | 97.96 % |
| src/BondManager.sol | 99.33 % (149/150) | 95.72 % | 81.82 % | 100 % |
| src/CapController.sol | 100 % (52/52) | 98.55 % | 100 % | 100 % |
| src/CoveredCallVault.sol | 99.46 % (367/369) | 99.01 % | 96.47 % | 100 % |
| src/EmissionsController.sol | 96.36 % (53/55) | 90.12 % | 64.71 % | 100 % |
| src/FeeRouter.sol | 98.57 % (138/140) | 94.22 % | 78.26 % | 100 % |
| src/LiquidityEscrow.sol | 97.44 % (38/39) | 91.53 % | 76.47 % | 100 % |
| src/OptionToken.sol | 100 % (49/49) | 100 % | 100 % | 100 % |
| src/PointsDistributor.sol | 100 % (76/76) | 94.12 % | 73.91 % | 100 % |
| src/RiskModule.sol | 100 % (94/94) | 99.21 % | 96.67 % | 100 % |
| src/SafetyModule.sol | 93.71 % (134/143) | 91.80 % | 75.76 % | 100 % |
| src/SettlementOracle.sol | 97.72 % (385/394) | 96.10 % | 86.36 % | 100 % |
| src/Vesting.sol | 100 % (99/99) | 94.78 % | 75.00 % | 100 % |
| src/WRITE.sol | 100 % (14/14) | 95.45 % | 75.00 % | 100 % |
| src/WritePriceOracle.sol | 96.79 % (151/156) | 96.17 % | 82.35 % | 100 % |
| **Total** | **98.44 % (2150/2184)** | **96.54 %** | **86.50 %** | **99.70 %** |

Below-100 % lines are the defensive branches that need a hostile external (a WRITE token whose `burn` reverts, a
Chainlink feed with `decimals > 38`, `EmissionsController` reached before `setSink`, `SafetyModule` reward-dust paths
that only the fuzzer reaches) — none is a business path. Branch coverage under 80 % in BondManager / FeeRouter /
Vesting / PointsDistributor is the `require`-style revert branches of admin setters, each of which has at least one
negative unit test; the remaining uncovered branches are the second operand of `||` conditions.


---

## 3. Invariant campaign

Profile `deep` (`contracts/foundry.toml`): `runs = 6000`, `depth = 128`, `fail_on_revert = true`,
`shrink_run_limit = 5000`, 50 000 fuzz runs, separate `out-deep/` / `cache-deep/`. Sized for ~24 h on one 8-core box
across the seven suites. Every invariant honours `FOUNDRY_INVARIANT_TIMEOUT`, so a bounded campaign is:

```bash
cd contracts && for c in VaultInvariants AuctionInvariants SettlementInvariants SafetyModuleInvariants \
  WriteFeeBondInvariants TokenDistributionInvariants VestingInvariants; do
  FOUNDRY_PROFILE=deep FOUNDRY_INVARIANT_TIMEOUT=270 FOUNDRY_INVARIANT_RUNS=1000000 forge test --match-contract "^$c$"; done
```

Run the suites **one at a time**: launched together, ~60 invariants compete for 8 cores and the timeout clock starts at
scheduling, so half of them reported `runs: 0` in the first attempt.

### 3.1 Runs of 2026-09-05

| Run | Code state | Wall clock | Runs / calls | Result |
|---|---|---|---|---|
| 1 | after A-01/A-02 | 5 min (all suites in parallel, 150 s/invariant) | ~55 k / 7 M, 22 invariants starved to 0 runs | 0 failures |
| 2 | after G-1…G-3 | **32 min** (sequential, 270 s/invariant) | **508 132 runs / 51 914 880 calls**, every invariant ≥ 3 400 runs | **1 failure: `invariant_I21_sharesAndPrincipalVanishTogether` — "no worthless shares: 2 != 0"**. Sequence: stake → slash → requestUnstake(all) → warp → unstake. `previewUnstake` floors, so after a slash the last exit left 2 wei of `totalStaked` behind zero shares. **Fixed** (D-113 item 10): the last unstaker takes the whole principal; `test_unstake_lastLeaverTakesAllPrincipal`. Economically harmless (the dust would have gone to the next staker), but I-21 as written was false. |
| 3 | after F/C/R fixes | **32 min** (sequential, 270 s/invariant) | **477 946 runs / 50 807 616 calls**, every invariant ≥ 4 300 runs | **1 failure, again I-21, the other direction: "no worthless shares: 1 != 0"**. Sequence: stake 100 WRITE → slash 18.67 → requestUnstake(`totalShares − 1`) → unstake. The ERC-4626-style virtual `+1` asset let `previewUnstake(totalShares − 1)` round **up** to the whole `totalStaked`, leaving one share worth nothing. **Fixed** (D-113 item 10): a non-total exit that would take everything leaves 1 wei behind the remaining shares; `test_unstake_nearTotalExitLeavesPrincipalForRemainingShares`. Dust-level economics, but the invariant is the point. |
| 3b | final tree, `SafetyModuleInvariants` only | 4.5 min | 41 732 runs / 5.3 M calls | 0 failures (I-21 4 925 runs). Every other suite was unchanged between run 3 and the final tree. |

Bottom line for the campaign: ≈ 1.04 M invariant runs / 108 M handler calls across the day on three code states; two
real findings (both I-21, both dust-level, both fixed), zero findings against any fund-conservation, coverage, settlement
or governance invariant.

---

## 4. Independent reviews

Four read-only reviews of the whole `contracts/src` tree (plus `script/`, `config/` for review b) by fresh-context
subagents, each against docs/SPEC.md and docs/THREAT-MODEL.md, each with a different focus. Every finding was verified
by the maintainer before a change was made. Severity is the reviewer's; "Fix" is what shipped (D-113).

### 4.1 General SPEC / THREAT-MODEL conformance

| ID | Sev | Finding | Fix |
|---|---|---|---|
| G-1 | High (admin-key compromise) | `AuctionHouse.priceSource` / `CapController.priceSource` re-settable forever. One 48 h batch pointing them at a contract answering `capPrice = 400` plus `setKeeper(attacker)` gives the next series a strike of ≈ $0.000004, reserve bounds of a few USDG units, 100 % of `offeredQty` for dust, every path tripping the jump guard, a halt with `resolveRef` = the real price, and `payoutPerOption ≈ 1e18` — the whole unencumbered collateral, far above the ≈ 16 % T-14 bound the docs claimed. | One-way `freezePriceSource()` on both (refuses a codeless placeholder), executed in deploy batch A right after `setPriceSource`, asserted by `DeployChecks`. Batch A is 19 calls (RUNBOOK §3). |
| G-2 | Low | Past the 7-day backstop an unusable ref hint left `resolveRef = sRef` even when the Friday round existed: the caller chose the band centre by withholding the hint. | `_resolveRefFor`: hinted valid pre-expiry round → feed latest if pre-expiry → `sRef`; the caller can force the halt (D-057) but not move the band. Tests `test_halt_backstop_*`. |
| G-3 | Low | `OptionToken.claim` not `nonReentrant`, so T-16's "every state-changing external function" held only through the vault's guard. | `nonReentrant` added. |
| G-4 | Low | SPEC §9.6 weekend-halt wording ("or the same") ambiguous vs D-053 ("past Monday 15:00 **and**"). | Doc: code follows D-053; the SPEC text keeps D-053's reading. |
| G-5 | Info | = A-02. | Fixed. |
| drift | — | SPEC §3 immutable-references sentence, §7.2 `S_ref`, §9.5 revert wording, §13 grace, §14 1:1, §16.1 event names, §16.2 non-existent views, THREAT-MODEL T-16/T-18 enforced-by text, T-14 `transferOwnership` residual. | All corrected in SPEC v0.8 / THREAT-MODEL. |

### 4.2 (a) Fund-loss paths

| ID | Sev | Finding | Fix |
|---|---|---|---|
| F-1 | Medium | A redeem request carried across `openSeries` (settle processed ≤ `maxQueueOpsPerSettle`; open processed only deposits) was excluded from `offeredQty` but **not** from the pooled NAV, so the redeemer bore the next series' payout with no premium. Worked example: 100 tokens, 20 shares escrowed, 80 offered and filled, settle at `S = 2K` ⇒ payout 40, share price 0.6, carried redeemers get 12 instead of 20. 50 dust `requestRedeem`s during LIVE push every honest request past the settle budget. | `openSeries` drains the redeem queue first and refuses to open (`CannotOpen("REDEEM_QUEUE")`, mirrored in `canOpenAuction`) while anything is still QUEUED. Not griefable: `requestRedeem` reverts in IDLE. Tests `test_openSeries_drainsCarriedRedeemsFirst`, `test_openSeries_refusesUndrainedRedeemQueue`. SPEC §4.3 rewritten. |
| F-2 | Medium (low likelihood) | `clear` callable by anyone in `[auctionClose, expiry)`; bids cannot be cancelled and depositors cannot exit during AUCTION, so with the keeper down a bidder clears only if the stock rallied past the strike (ITM option for an OTM premium) and lets it skip otherwise. | `clearGrace` (1 h default, `[5 min, 4 h]`, `setClearGrace`): later clears skip. `test_clear_afterGraceSkips`, `test_setClearGrace_bounds`. |
| F-3 | Low | Queue-then-cancel: a carried request shrinks `offeredQty`, `cancelRedeem` before `clear` puts the shares back into the premium denominator. | Closed by F-1 (nothing is carried). |
| N-1 | needs confirmation | After an issuer burn `totalAssets()` saturates at 0 and OZ `redeem` burns shares for nothing. | `redeem`/`withdraw` revert `ZeroAmount` when the payout is zero; shares survive for `injectCoverage`. `test_redeem_refusesZeroAssets`. |
| N-2 | needs confirmation | `_processDeposits` can mint 0 shares at an extreme share price. | Accepted (standard ERC-4626 offset behaviour, T-06); documented in D-113. |

### 4.3 (b) Access control and timelock wiring

| ID | Sev | Finding | Fix |
|---|---|---|---|
| C-1 | Medium | The 48 h / four-key mainnet shape was a JSON convention: nothing pinned `timelockMinDelay`, `deployerIsAdmin`, guardian count or key distinctness for 4663; `_governanceIsUs` let a zero delay alone make the script execute governance itself. | `Config.validate` pins all of it on chainId 4663 (`MainnetGovernance` errors); `DeployChecks.assertTimelock` requires ≥ 48 h on 4663; `_governanceIsUs` needs the declared deviation. `test_mainnetConfigRefusesWeakGovernance`. |
| C-2 | Low | `OptionToken.registerVault` irreversible with no pairing assert; a mis-pairing burned the underlying's slot forever. | Asserts `vault.stock() == underlying` and `vault.optionToken() == this`. |
| C-3 | Low | `setAuctionHouse` ×2 / `setSettlementOracle` only asserted inside batch A by later calls; outside it a typo was permanent. | Each probes the target's back-pointer (`Miswired`). |
| C-4 | Low | `DeployChecks` did not verify the curator floors batch A may set. | Four `require`s per vault. |
| C-5 | Low | `DeployToken` accepted any `TIMELOCK_ADDRESS`. | Requires code and `getMinDelay() ≥ 48 h`. |
| C-6 | Low | `Deploy.run()` not idempotent on a real-delay chain. | Documented in RUNBOOK §2 (do not re-run between stage 1 and batch A). |
| C-7 | Info | `deploy.sh` exported the whole `.env` (incl. the private key) into child processes and accepted `--private-key` on 4663. | Ledger-only on 4663; only the RPC variables are exported. |
| C-8 | Info | `Ownable2Step.transferOwnership` on every contract: a 48 h step then an undelayed `acceptOwnership` moves every privilege off the timelock. | Accepted residual of D-003; recorded in THREAT-MODEL T-14 item 3; the keeper should alert on `OwnershipTransferStarted`. |
| C-9 | Info | Doc inaccuracies (SPEC §3 list, `setCapUSD` unbounded, RUNBOOK expected-failure messages). | SPEC §3 rewritten; `setCapUSD` bound documented as policy (docs/CAPS.md); RUNBOOK messages left for the next rehearsal. |
| matrix | — | The full access-control matrix (contract · function · modifier · who in practice) is in the review output and summarised in AUDIT-SCOPE §3–§4: every state-changing function is either permissionless by design, gated to an immutable/set-once protocol contract, or `onlyOwner` = the timelock. Guardian writes only pause flags (I-7); no `DEFAULT_ADMIN_ROLE` holder anywhere; the deployer only calls `new`. | — |

### 4.4 (c) Rounding, units and oracle edge cases

| ID | Sev | Finding | Fix |
|---|---|---|---|
| R-1 | Medium | The observation hint was advisory ("an older hint only under-counts"). From the moment Monday's first round exists, anyone passing the live head as `obsIndex` failed path 2 with `OBSERVATIONS` and settled a WEEKEND series on path 3 — T-08's free choice between two legitimate prices, bounded only by the 30 % jump guard (worked example: 1.06 % of collateral). | `_observationsOk` verifies the hint (initialised, ≤ anchor, no newer observation ≤ anchor in the next slot) and reverts `BadObsHint` otherwise. `test_T08_liveHeadHintCannotForcePath3`, `test_path2_observationHintCannotHelp` rewritten. The keeper must always compute `obsIndex` (newest observation at or before expiry). |
| R-2 | Low | Chainlink phase overlap: both phases could hold a verifiable "last round ≤ expiry" / "first round > expiry"; the caller picked between two answers. | Only the newest phase's candidate verifies. `test_path1_phaseOverlapHasOneReference`. |
| R-3 | Low | `claimPremium` uncapped: balance splits re-floor two debts, Σ credits can exceed the balance by a unit and the last claimant reverts. | Capped at the vault's USDG balance, remainder stays credited. `test_claimPremium_cappedAtBalance`. |
| R-4 | Low | A-01's first guard checked the truncated average; `dTick = MIN_TICK·w − 1` passed it and still reverted in `getSqrtRatioAtTick`. | Guard on the floored tick (`twapTick56`). |
| R-5 | Low | A feed answer > `uint128.max` counted as a valid round and made `halt` revert in `toUint128` — a stuck LIVE series if the feed also died. | Treated as invalid like `answer ≤ 0`. `test_round_absurdAnswerIsInvalid`. |
| needs confirmation | — | Jump-guard multiplier exception (D-051) admits exactly the T-10.2 mis-sequenced round; mock fidelity gaps (OCR2 zero-return for unknown in-phase rounds, checked cumulatives in the pool mock); 80 h USDG staleness in WritePriceOracle; path-3 hint when the earliest phase is > 1. | Recorded as accepted / open in D-113 and AUDIT-SCOPE §5; the mock gaps are covered by `vm.mockCall`-based tests where it mattered (A-02, R-1). |

### 4.5 What the reviews confirmed sound (one line each)

Vault stock-token conservation absent issuer burns; coverage `filledQty ≤ min(offeredQty, totalAssets)`; `payoutOwed`
never underflows and holders cannot extract more than `filledQty × ppo`; `injectCoverage` bounds; premium accumulator
and share escrow; share price constancy across queue processing; AuctionHouse USDG conservation to the unit and the
clearing math incl. pro-rata dust; every pull-payment path; bond locks through the migration; FeeRouter WRITE path
atomicity; SafetyModule accumulator vs balance; EmissionsController cap; Vesting / Points / Escrow partitions;
CapController rounding directions; every decimal bridge (8/18/6), every downcast and `unchecked` block, the Uniswap
math for both token orderings, the epoch-week constants and DST window, RiskModule bounds; guardian scope; timelock
construction and batch ordering; no sweep/rescue/arbitrary-call anywhere; `renounceOwnership` disabled on all fourteen
owned contracts.
