# AUDIT-SCOPE — what an auditor is asked to look at

2026-09-05 · for the external engagement that docs/CAPS.md step 2 requires · prepared alongside docs/AUDIT-PREP.md
(internal pass: static analysis, coverage, invariant campaign, four independent reviews).

## 1. Contracts in scope

Foundry project `contracts/`, solc 0.8.26, EVM `cancun`, optimizer 200 runs, `via_ir = false`. Target chain: Robinhood
Chain (Arbitrum Orbit L2, chainId 4663; testnet 46630). All of `contracts/src` except `src/mocks` (testnet stand-ins,
never deployed on 4663).

SLOC = non-blank, non-comment lines.

| Contract | File | Lines | SLOC | Role (SPEC §) | Holds funds |
|---|---|---:|---:|---|---|
| CoveredCallVault | src/CoveredCallVault.sol | 812 | 609 | ERC-4626 vault, queues, premium accumulator, series lifecycle, `injectCoverage` (§4, §5, §9.7, §14) | stock tokens, USDG premium |
| AuctionHouse | src/AuctionHouse.sol | 841+ | 649+ | weekly uniform-price auctions, escrow, clearing, pull refunds/options/payout, schedule (§5, §7.2, §8) | USDG escrow + booked fees |
| SettlementOracle | src/SettlementOracle.sol | 809+ | 612+ | §9 settlement policy: paths 1–5, hints, jump guard, halt/backstop, `capPrice`/`referencePrice`, TWAP | — |
| RiskModule | src/RiskModule.sol | 263 | 186 | guardian pauses, halt registry, versioned `OracleParams` (§6, §15) | — |
| CapController | src/CapController.sol | 128+ | 89+ | deposit caps, FIXED / SAFETY_MODULE switch (§12) | — |
| OptionToken | src/OptionToken.sol | 148+ | 110+ | ERC-1155 options, one id per series, claim → payout (§3, §9.7) | — (burns, vault pays) |
| BondManager | src/BondManager.sol | 391 | 256 | MM/curator bonds, participation locks, cooldown, slashing, USDG→WRITE migration (§13) | USDG / WRITE bonds |
| FeeRouter | src/FeeRouter.sol | 347 | 231 | performance fee booking and flush; WRITE fee mode with discount + burn (§11) | prefunded WRITE (curators) |
| SafetyModule | src/SafetyModule.sol | 368 | 232 | WRITE staking backstop, pulled emissions, cooldown/claim window, slash ≤ 30 %/14 d, `valueUSD` (§14) | staked WRITE + rewards |
| EmissionsController | src/EmissionsController.sol | 165 | 99 | 4-year linear WRITE stream to one sink, checkpointed rate (§14) | 300 M WRITE bucket |
| WritePriceOracle | src/WritePriceOracle.sol | 358+ | 245+ | WRITE/USD: Chainlink-if-fresh else 30-min TWAP + depth rule + validity band (§11, §12) | — |
| Vesting (×2 instances) | src/Vesting.sol | 280 | 194 | linear vesting with cliff; treasury (irrevocable) and team (revocable) | 200 M + 150 M WRITE |
| PointsDistributor | src/PointsDistributor.sol | 217 | 140 | Merkle rounds with deadlines and sweep (airdrop + bond grants) | 100 M WRITE |
| LiquidityEscrow | src/LiquidityEscrow.sol | 130 | 74 | 250 M launch liquidity, one destination, raw-AMM guard | 250 M WRITE |
| WRITE | src/WRITE.sol | 80 | 42 | fixed 1e27 supply minted once into five holders; ERC20Permit + Burnable; no owner | — |
| Types | src/Types.sol | 44 | 35 | enums, `OracleParams` | — |
| OracleMath (internal lib) | src/libraries/OracleMath.sol | 82 | 54 | TWAP tick, harmonic liquidity, depth rule, `quotePrice8`, `withinBps` | — |
| TickMath (deployed, linked) | src/libraries/TickMath.sol | 46 | 34 | `getSqrtRatioAtTick`, Uniswap v4-core constants, no assembly (D-058) | — |
| interfaces/* (17 files) | src/interfaces | 518 | 363 | protocol interfaces, `AggregatorV3Interface`, `IUniswapV3Pool`, `IStockToken` (ERC-8056) | — |
| **Total in scope** | | **≈ 5 530** | **≈ 3 920** | | |

"+" marks files that grew by a few lines in the 2026-09-05 pass (D-113); counts are from before that pass.

Also in scope, lower priority: `contracts/script/*` (deploy library + checks: the timelock batches are generated here
and executed by tests, so a wiring mistake would be a script bug) and `contracts/config/4663.json` (every mainnet
parameter). Out of scope: `src/mocks`, `keeper/`, `app/`, `points/`, `landing/`.

Test suite: ≈ 13 600 SLOC in `contracts/test`, 724 test functions (unit, fuzz, threat-model regressions `test_Txx_*`,
61 invariants across 7 stateful suites, deploy-library and fork tests). `forge test`: 724 tests, 0 failed, 1 skipped
(a fork test that needs an RPC). Contract sizes after the pass: AuctionHouse 23 712 B and SettlementOracle 23 486 B
against the 24 576 B limit (AUDIT-PREP A-26).

## 2. External dependencies

| Dependency | Version / address | Used for | Assumed |
|---|---|---|---|
| OpenZeppelin Contracts | 5.1.0 (`lib/openzeppelin-contracts` @ 69c8def5) | ERC20, ERC4626, ERC1155(+Supply), Ownable2Step, AccessControl, ReentrancyGuard, SafeERC20, SafeCast, Math, MerkleProof, TimelockController, ERC20Permit/Burnable | correct as audited |
| forge-std | v1.16.2 | tests only | — |
| solady | v0.1.26 | tests only (present as submodule) | — |
| Uniswap v3 pools | stock/USDG 0.05 % pools, e.g. NVDA/USDG `0xd4EB…14a3`; WRITE/USDG pool TBD | `observe`, `observations`, `slot0`, `token0/1`, `fee` — TWAP and depth rule | canonical v3 semantics: cumulatives wrap, `observe` reverts `OLD` beyond the ring, `cardinalityNext` raised by anyone |
| Chainlink AggregatorV3 | one 8-dec feed per stock token (NVDA `0x379E…9F15`), USDG/USD `0x61B7…9aD2`; optional L2 sequencer uptime feed (none exists yet) | settlement rounds by id (phase-aware), latest round, USDG peg | honest but slow (24 h heartbeat, 0.5 % deviation, no weekend updates); `getRoundData` may revert for unknown ids |
| Robinhood Stock Tokens | ERC-8056 ERC-20s, 18 dec, beacon-upgradeable, issuer can pause / block / burn; `uiMultiplier`, `newUIMultiplier`, `effectiveAt`, `oraclePaused` | vault asset | issuer powers accepted and disclosed (T-11); no transfer hooks today |
| USDG (Paxos) | `0x5fc5…d168`, 6 dec, pausable, address freeze | quote asset: premium, escrow, bonds, fees | pause/freeze accepted (T-12); no fee-on-transfer |
| TickMath library | deployed once, address linked at build (D-058) | `getSqrtRatioAtTick` via DELEGATECALL | constructors assert `getSqrtRatioAtTick(0) == 2**96` |
| OpenZeppelin TimelockController | deployed by the project, `minDelay = 172 800` | owner of every contract | one proposer/executor EOA (hardware wallet), self-administered |

## 3. Trust assumptions

From SPEC §2 / THREAT-MODEL §1.2, as implemented:

- **Depositors, market makers, option holders, LPs:** untrusted. Every user-facing entry point is permissionless or
  gated only by a bond; every amount they supply is bounded on-chain.
- **Keeper (`KEEPER_ROLE`):** trusted for liveness only. It alone calls `openAuction`; every parameter it passes
  (`expiry`, `strikeDistanceBps`, `reservePrice`) is checked against the on-chain schedule, the on-chain `S_ref`, and
  protocol/curator bounds. Its settlement *hints* are verified on-chain and a wrong hint reverts. Everything else it does
  (`clear`, `settle`, `halt`, queue processing, `flush`, `resolveHaltedByOracle`) anyone can do.
- **Guardian (`GUARDIAN_ROLE`, two holders, no delay):** can only set and clear four pause flags (deposits, new auctions;
  per vault or all). Cannot move funds, change parameters, block withdrawals in IDLE, block any claim, or stop
  settlement / halt / resolution. Invariant I-7 checks this with a storage-write recorder.
- **Admin (timelock owner):** one hardware-wallet EOA, sole proposer and executor of a 48 h `TimelockController`. It is
  the only privileged actor. Its blast radius is bounded by construction (§5 below) but **not zero**: THREAT-MODEL T-14
  lists what 48 h of visibility does and does not protect. `renounceOwnership` is disabled everywhere (an ownerless
  contract could not slash, resolve, register or sunset), so ownership can only move by `transferOwnership` +
  `acceptOwnership`, both visible in the queue.
- **Deployer:** only ever calls `new`; every contract takes the timelock as `owner_` in its constructor (D-103). Holds no
  role afterwards; `DeployChecks.renounceSweep` and `assertNoDeployerRoles` verify it.
- **Robinhood (issuer, sequencer operator, council seats), Paxos, Chainlink, Uniswap:** external, per §2. The protocol
  is a no-op across correctly sequenced corporate actions (strike is per raw token, §10) and halts rather than settles
  on any price it cannot verify (§9).
- **No revenue share:** WRITE holders receive fixed-supply emissions only; no fee, premium or settlement flow reaches
  the token (CLAUDE.md rule 7, `test_noHolderDistributionPathExists`).

## 4. Governance surface

Every `onlyOwner` function (about 90, aderyn L-1) is reachable only through the 48 h timelock. Set-once wiring is
asserted by the counter-party at registration (D-044, D-049); the two price-source pointers are frozen one-way in deploy
batch A (D-113). Parameters have on-chain bounds (RiskModule `_validate`, AuctionHouse/CapController/FeeRouter/
SafetyModule/EmissionsController constants) and oracle parameters are versioned so a change never touches a live series
(D-031). The complete access-control matrix (contract · function · role · who in practice) is in docs/AUDIT-PREP.md §4
(review b).

## 5. Known issues and accepted risks

Everything here is disclosed on purpose; an auditor should confirm the bound, not re-discover the item.

| # | Item | Bound / status |
|---|---|---|
| K-1 | **Single admin key** (D-003). Loss = no parameter can ever change and a HALTED series without a permissionless exit stays halted until `resolveHaltedByOracle` (7 days after expiry, needs one post-expiry Chainlink round). Compromise = the T-14 chain: ≈ 16 % of one series' collateral via an in-band `resolveHalted`, 100 % of bonds, 30 % of the safety module per 14 days; each step visible for 48 h and nobody else can cancel (OQ-001). The price-source lever that broke this bound is frozen since D-113 (AUDIT-PREP G-1); `transferOwnership` + `acceptOwnership` remains the residual of the same class. | accepted; caps (docs/CAPS.md) bound the absolute number |
| K-2 | **`S_ref` is `capPrice`, not `referencePrice`** (OQ-005): strike gridded off a Chainlink answer up to 80 h old without the `oraclePaused` check. | open; needs an AuctionHouse redeploy; keeper pre-checks and curator floors mitigate |
| K-3 | **Issuer powers over stock tokens** (T-11): pause, block, burn, beacon upgrade. A burn of vault balance produces `ShortfallRecorded` and scaled payouts, repaired only by `injectCoverage` from the treasury/safety module. | accepted and disclosed |
| K-4 | **USDG pause / freeze** (T-12): a paused USDG makes `clear` wait; a frozen AuctionHouse or vault address strands escrow/premium until unfrozen. | accepted |
| K-5 | **Weekend TWAP manipulation inside the bounds** (T-03): profit ceiling ≈ 8.7 % of notional for a 5 % OTM strike; the depth rule (250 000 USDG / 1 %) plus caps keep it below the cost of moving the pool. | accepted; caps are the control |
| K-6 | **Sequencer downtime / timestamp drift** (T-05); no uptime feed exists for this chain yet (`sequencerFeed = 0`). | accepted; `MAX_LAST_OBS_AGE`, `sequencerGrace` when a feed appears |
| K-7 | **Halt backstop can be forced by withholding a usable hint** (D-057 residual). As of D-113 the caller cannot move the band centre; the consequence is a resolution inside ±25 % of the on-chain reference instead of a path 1–3 price. | accepted, bounded |
| K-8 | **Guardian-induced idleness** (T-15): a compromised guardian can keep deposits and new auctions paused for the 48 h it takes to rotate the role; a live series still settles and withdrawals stay open. | accepted |
| K-9 | **Weekend gap** (T-04): Sunday 23:59 UTC settlement vs Monday open. | economic, accepted |
| K-10 | **`Ownable2Step.transferOwnership`** on every contract: the timelock can hand a contract to an undelayed key in one 48 h step (same class as `updateDelay`, T-14 item 3). | accepted residual of D-003 |
| K-11 | **VaultFactory not shipped**: vaults are added by hand through three timelocked `registerVault` calls; SPEC §13 curator per-series locks and §15 `allowToken` wait for it. | not in scope |
| K-12 | **Coverage-build artefact**: five tests fail only under `forge coverage --ir-minimum` (test-side `block.timestamp` arithmetic), pass under every other setting (AUDIT-PREP A-24). | tooling |
| K-13 | **USDG/USD feed cadence on Sundays** (OQ-002): `usdgMaxStale = 26 h` may fail Sunday TWAPs, making path 3 the de-facto weekend primary; raising to 80 h is the recorded alternative. | open, parameter-only |
| K-14 | **Keeper must supply a correct `obsIndex`** (newest pool observation at or before expiry) on every `settle`: since D-113 a wrong observation hint reverts `BadObsHint` like a wrong round hint (AUDIT-PREP R-1). Liveness, not safety: anyone can compute and submit the right hint. | by design |
| K-15 | **`clearGrace` = 1 h**: a clear later than `auctionClose + 1 h` skips the week (AUDIT-PREP F-2). A keeper outage of more than an hour on a Monday costs that week's premium, never collateral. | by design, timelocked `[5 min, 4 h]` |
| K-16 | **Jump-guard multiplier exception** (D-051) admits a feed that moved by exactly the multiplier ratio, which SPEC §10 identifies as the T-10.2 mis-sequencing. Bounded by `jumpBps`; reviewer (c) suggested requiring the TWAP to agree before the adjusted check is used. | open, founder decision |

## 6. Invariants

Encoded in `contracts/test/invariants/` (7 suites, `fail_on_revert = true`; handlers play every actor incl. the issuer,
Paxos freezes, guardians, the timelock, Chainlink phase bumps, pool swaps and liquidity pulls, reentrant actors). Numbers
are SPEC §17 ids; the test function is named after the id.

**Vault (`VaultInvariants`)**
- I-1 coverage: `encumbered ≤ totalAssets()`; `Σ filledQty of LIVE/HALTED ≤ balance − payoutOwed − withdrawalClaimable − queuedDepositTokens`.
- I-2 payout bound: `payoutPerOption < 1e18`; `payoutOwed` backed unless a shortfall was recorded; `payoutPerOption ≤ unscaled (S−K)/S`; OptionToken mirror equals the vault's.
- I-3 no encumbrance after settlement; I-4 a zero-payout settlement never lowers the share price; I-8 share price non-decreasing outside a paying settlement or an issuer burn.
- I-15 IDLE ⇒ every share redeemable regardless of pause/sunset; I-16 `OptionToken.totalSupply(id) + claimedQty == mintedQty ≤ filledQty`, `balanceOf(vault) == escrowedRedeemShares`, `totalAssets + payoutOwed + withdrawalClaimableTotal + queuedDepositTokens == balance` absent burns.
- premium conservation (`USDG.balanceOf(vault) ≥ Σ premiumClaimable`); T-16 no reentrancy from the mint callback.

**Auction (`AuctionInvariants`)**
- I-3 escrow conservation, exact: `USDG.balanceOf(AuctionHouse) == Σ open escrow + Σ refundable + Σ pending fees`; per closed auction `Σ escrow == Σ refunds + premiumNet + fee`; allocation identity `Σ claimableOptions + totalSupply(id) + Σ claimed == filledQty`, `filledQty ≤ offeredQty`, `clearingPrice ≥ reservePrice`.
- I-13 bond locks: a filled bidder of the LIVE/HALTED series is locked and no bond withdrawal ever succeeded while locked.
- fee conservation (`pending + treasury == Σ fee`); `previewClear == clear`; auction OPEN ⇔ vault AUCTION; T-16.

**Settlement (`SettlementInvariants`)**
- I-5 never stale (path 1 age ≤ `weekdayMaxStale`; weekend paths never use a pre-expiry round as the price).
- I-7 guardian scope (storage-write recorder: only pause flags).
- I-9 USDG band on path 2; I-10 jump guard (plain or multiplier-adjusted) on paths 1–3; I-11 resolution band on paths 4–5.
- I-12 parameter snapshot: a version change never alters `previewSettle` of an open series.
- I-14 liveness: past the backstop the honest hint makes `settle` or `halt` succeed and no view reverts; a halted series past the timeout with a fresh post-expiry round is resolvable without a key.
- payouts bounded (`Σ claimed ≤ filledQty × ppo / 1e18 ≤ collateral`), `previewSettle == settle`, a halted vault cannot open.

**Safety module (`SafetyModuleInvariants`)**
- I-17 `Σ sharesOf == totalShares`; I-18 `balance ≥ totalStaked + unallocatedRewards`; I-19 `totalStaked` is never the balance when rewards exist; I-20 slash cap enforced by the contract (an over-cap slash is attempted on every call); I-21 `totalShares == 0 ⇔ totalStaked == 0`; I-22 rewards ≤ emissions released (+1 wei/harvest dust); I-28 owed ≤ `rewardSurplus()`; I-29 `stakedIn − unstakedOut − slashedOut == totalStaked`; I-30 donations create no credit.

**Vesting (`VestingInvariants`)**: I-23 `totalAllocated == Σ totalAmount`; I-24 `unallocated + totalAllocated + reallocated == allocation`; I-25 released ≤ vested per schedule; I-26 `totalAllocated − totalReleased ≤ balance`; I-27 `totalReleased == Σ released`.

**Token distribution (`TokenDistributionInvariants`)**: I-31 supply only falls by burns; I-32 `paidOut + swept + outstanding + unreserved == allocation`; I-33 `balance(Points) ≥ outstanding`; I-34 no round overpays; I-35 escrow `released ≤ allocation`, everything released reached `pool`.

**WRITE fee & bonds (`WriteFeeBondInvariants`)**: I-36 `Σ collected == Σ flushed + pending`; I-37 prefunded WRITE `deposited == held + withdrawn + burned + toTreasury`; I-38 `write.balanceOf(FeeRouter) == Σ writeBalance` and the router never holds USDG; I-39 bond legs backed per asset through the migration; I-40 bonded ⇒ requirement met with no pending withdrawal; I-41 the router only ever burns.

Not encoded as stateful invariants (unit-tested instead): I-6 windows (event-based, recorded logs), the exact-constant form of I-8 (fails by rounding dust; the monotone form is encoded).

Campaign results and the `deep` profile: docs/AUDIT-PREP.md §3.

## 7. How to run

```bash
cd contracts
forge test                                   # 711 tests, ~1 min
FOUNDRY_PROFILE=ci forge test                # 10 000 fuzz runs, invariants 256 × 64
FOUNDRY_PROFILE=deep FOUNDRY_INVARIANT_TIMEOUT=270 forge test --match-path "test/invariants/*"   # bounded campaign
forge coverage --ir-minimum --report summary --no-match-coverage "(test|script|mocks|lib)"
python -m slither . --filter-paths "lib/|test/|script/|src/mocks/"
```
