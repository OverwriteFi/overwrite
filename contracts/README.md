# overwrite / contracts

Foundry project for the overwrite protocol on Robinhood Chain (Arbitrum Orbit L2).

- solc 0.8.26, EVM `cancun`, `via_ir` off by default
- deps: forge-std, OpenZeppelin v5.1.0, solady (git submodules in `lib/`)
- profiles: `default` (256 fuzz runs, invariants 64 × 32) and `ci` (10 000 fuzz runs, invariants 256 × 64) → `FOUNDRY_PROFILE=ci forge test`
- invariants run with `fail_on_revert = true`: every handler action must be guarded, an unexpected revert is a failure

## Layout

```
src/
  Types.sol                 SeriesKind / VaultState / SeriesState
  CoveredCallVault.sol      ERC-4626 vault: windows, queues, premium accumulator, series lifecycle (SPEC §4, §5, §9.7)
  OptionToken.sol           ERC-1155 options, one id per series, vault-only mint/burn, claim → payout (SPEC §3, §9.7)
  CapController.sol         deposit caps, FIXED / SAFETY_MODULE switch (SPEC §12)
  AuctionHouse.sol          weekly uniform-price auctions: schedule checks, on-chain strike, bids + escrow, clearing with
                            pro-rata at the margin, pull refunds / options / payout, bond locks (SPEC §5, §7.2, §8, D-043…D-048)
  BondManager.sol           MM and curator bonds, one independent leg per asset, participation locks, 7-day cooldown,
                            timelock slashing, the one-way USDG -> WRITE migration with a dual-asset grace (SPEC §13, D-079…D-083)
  WRITE.sol                 the token: fixed 1e27 supply minted once into five distribution contracts, no mint, no owner,
                            ERC20Permit + ERC20Burnable; recipients must declare their own allocation (SPEC §14, D-059…D-061)
  SafetyModule.sol          WRITE staking backstop: shares over an accumulator, pulled emissions, 14-day cooldown with a
                            3-day claim window, timelock slashing <= 30 %/event, valueUSD() for the cap (SPEC §12, §14)
  EmissionsController.sol   4-year linear WRITE stream to the SafetyModule, pulled not pushed, rate settable, never
                            retroactive (SPEC §14, D-074…D-077)
  WritePriceOracle.sol      WRITE/USD for the safety module and the fee path: Chainlink if fresh, else the 30-min pool TWAP
                            with the depth rule and a mandatory sanity band; never reverts (D-064…D-068)
  Vesting.sol               linear vesting with a cliff, many beneficiaries; deployed twice, treasury (irrevocable) and
                            team (revocable) (D-062, D-090…D-092)
  PointsDistributor.sol     Merkle rounds with deadlines and a sweep to treasury; airdrop and bond grants (D-093)
  LiquidityEscrow.sol       the 250 M launch liquidity; one timelock-set destination, no rescue, refuses a raw AMM (D-094)
  FeeRouter.sol             performance fee booked at clearing, permissionless flush to treasury; WRITE mode gated (SPEC §11)
  SettlementOracle.sol      SPEC §9 oracle policy: paths 1/2/3 with verified keeper hints, jump guard, halt, resolveHalted,
                            resolveHaltedByOracle; `capPrice` (§12) and `referencePrice` (§7.2) (D-050…D-055)
  RiskModule.sol            guardian pauses (vault | ALL), halt registry, versioned OracleParams per vault (SPEC §15, D-050, D-056)
  libraries/                TickMath (v4-core constants, no assembly) - DEPLOYED and linked, not inlined (D-058);
                            OracleMath (TWAP tick, harmonic liquidity, depth rule, price8) - internal, inlined
  interfaces/               IStockToken (ERC-8056), IRiskModule, ICapController, IPriceSource, ISafetyModule, IOptionToken,
                            ICoveredCallVault, IAuctionHouse, IBondManager, IFeeRouter, ISettlementOracle, AggregatorV3Interface,
                            IUniswapV3Pool
  mocks/                    MockStockToken, MockUSDG (testnet mocks, SPEC §1.8 / D-014; USDG has `paused()` / `isFrozen()`)
test/
  Base.t.sol                fixture: one vault wired to mocks; AuctionHouse and Settlement are plain addresses
  AuctionBase.t.sol         fixture: real AuctionHouse + BondManager + FeeRouter wired to a vault, four bonded MMs, Monday 14:00
                            (`_deployRiskModule` / `_deploySettlement` hooks default to the mock and an EOA)
  SettlementBase.t.sol      fixture: real RiskModule + SettlementOracle as the vault's immutables, phase-1 Chainlink mock (4 h rounds),
                            USDG/USD mock, USDG/NVDA 0.05 % pool mock at the $200 tick; helpers to post rounds, seed TWAP windows,
                            open/clear weekday and weekend series and settle through the oracle
  CoveredCallVault.t.sol    unit tests, one per external function incl. every revert path
  CoveredCallVault.fuzz.t.sol  fuzz: deposit/withdraw math, coverage bound, payout formula, queues, premium split
  CoveredCallVault.threats.t.sol  THREAT-MODEL regressions (`test_Txx_…`): T-18 queue flood, T-11 paused token / issuer burn,
                            T-12 dead cap oracle, T-10 retained effectiveAt, T-14 path/state, T-09 shares to vault, T-16 reentrancy,
                            T-15 guardian scope, T-07 gas at MAX_QUEUE_OPS
  AuctionHouse.t.sol        unit: registerVault, openAuction (schedule, distance, reserve, S_ref), bid, clear (single, multi,
                            undersubscribed, pro-rata + dust, every skip path), withdrawRefund, claimOptions, claimPayout,
                            releaseLocks, setters, one end-to-end week
  AuctionHouse.fuzz.t.sol   ClearingHarness over the pure clearing math (no over-allocation, price priority, pro-rata prefix),
                            escrow conservation to the unit through the real contract (parsed BidFilled logs), preview == clear,
                            strike grid, reserve bounds
  AuctionHouse.threats.t.sol  T-07 (escrow, 64/8 caps, frozen bidder, non-receiver bidder, bond lock, 64-bidder gas), T-12,
                            T-13/T-19, T-04, T-09, T-05, T-16
  SettlementOracle.t.sol    unit: registerVault wiring asserts, path 1 (hints, phase boundaries, garbage rounds, staleness), path 2
                            (every TwapRejected reason, both pool orientations, observation hint), path 3 (first-after, prev hint,
                            deadline), sequencer hook, every halt branch incl. the 7-day backstop, resolveHalted band,
                            resolveHaltedByOracle clamp, capPrice / referencePrice / twap views, I-6
  SettlementOracle.fuzz.t.sol  payout vs plain-arithmetic reference and claims, monotone in S, 26 h boundary, jump guard with and
                            without a multiplier change, resolution clamp, USDG conversion, window anchored at expiry, hint independence
  SettlementOracle.threats.t.sol  T-03 liquidity pull / quiet pool / pump bound, T-05 sequencer gap, T-08 refRound and hints,
                            T-10 split 4x mid-series (three cases), T-11, T-12 depeg and 80 h peg staleness, T-14 snapshot and
                            bounded resolution and key-less liveness, T-07 gas
  RiskModule.t.sol          setters and bounds, guardian scope incl. the I-7 storage-diff check, ALL vs vault precedence, halt hook,
                            paramsAt versioning, a real 48 h TimelockController
  OracleMath.t.sol          TickMath canonical values and monotonicity, twap tick floor, depth rule vs exact v3 swap amounts,
                            price8 for both orientations, harmonic liquidity
  OptionToken.t.sol, CapController.t.sol, BondManager.t.sol, FeeRouter.t.sol
  TokenBase.t.sol           fixture: SettlementBaseTest + the whole token layer, deployed through script/TokenDeployLib.sol
                            so it cannot drift from the real deployment; the real module is `sm` (the inherited mock keeps
                            the name `safetyModule`). Pool ticks come from a binary search over the production math (D-096)
  TokenUnitBase.t.sol       bare fixture for the suites that need no vault state
  WRITE.t.sol, LiquidityEscrow.t.sol, EmissionsController.t.sol, Vesting.t.sol, PointsDistributor.t.sol
  SafetyModule.t.sol        staking, cooldown boundaries, slashing incl. the 14-day interval, emissions parking, valueUSD
                            decimals and its fail-closed path through the cap
  WritePriceOracle.t.sol    setPool asserts, Chainlink vs TWAP, both token orderings, every non-reverting failure mode,
                            the sanity band, T-03 spike damping
  BondManagerMigration.t.sol  the dual-asset window: both assets during grace, no gap, no cooldown after grace, the lock
                            that is never waived, per-leg slashing, and a fuzzed never-stranded property
  FeeRouterWrite.t.sol      the WRITE fee path: discount, burn, USDG rebate, every fallback, and T-07 (clear can never be
                            bricked by the WRITE path)
  DayInTheLife.t.sol        one narrative: launch -> stake -> cap switch -> deposit -> auction -> ITM settle -> USDG fee ->
                            WRITE mode -> auction -> OTM settle -> WRITE fee -> emissions -> bond migration -> points claim -> slash
  TokenHolderGuards.t.sol   the staged deploy holds no deployer privilege, and the holder-side guards and error
                            branches added by the D-098 review (vesting term bounds, the raw-AMM shapes, T-25)
  TokenLayerGuards.t.sol    the staking-side guards: slash voiding matured requests, the residual floor, the
                            FeeRouter fee reservation, the oracle's sequencer check (T-05) and band floor
  TokenLayer.threats.t.sol  T-11, T-12, T-13, T-16, T-21, T-22, T-23, T-24 for the token layer
  utils/MerkleTreeLib.sol   roots and proofs in Solidity (no JS harness), OZ sorted-pair convention
  invariants/               VaultHandler + VaultInvariants (vault layer) and AuctionHandler + AuctionInvariants (I-3 exact escrow
                            conservation, allocation identity, fee conservation, I-13 bond locks, preview == clear, auction OPEN ⇔
                            vault AUCTION; the handler plays depositors, MMs, keeper, settlement, issuer, Paxos freeze, timelock)
                            SettlementHandler + SettlementInvariants (I-5, I-7, I-9, I-10, I-11, I-12, I-14, payouts ≤ encumbered
                            collateral, preview == settle, halted vault cannot open; restricted to the action selectors, the scripted
                            `cycle*` functions back `test_handlerReachesEveryState`)
                            SafetyModuleHandler + SafetyModuleInvariants (I-17…I-22: the share ledger sums, the module is
                            always solvent for principal + rewards, totalStaked is tracked not measured, the 30 % cap held,
                            shares and principal vanish together, rewards bounded by emissions released)
                            VestingHandler + VestingInvariants (I-23…I-27: allocated == sum of schedules, the three buckets
                            partition the allocation, released <= vested per schedule, outstanding promises stay funded)
                            TokenDistributionHandler + TokenDistributionInvariants (I-31…I-35: WRITE's fixed supply, the
                            points buckets partition, live rounds stay funded, no round overpays, the escrow's release bound)
                            WriteFeeBondHandler + WriteFeeBondInvariants (I-36…I-41: fee conservation across both modes,
                            prefunded-WRITE conservation, per-asset bond backing, bonded-implies-requirement, burn-only supply)
                            -- AuctionInvariants deliberately never enters WRITE mode or the migration (D-097), so this is
                            the only invariant coverage of either
  mocks/                    MockRiskModule, MockPriceSource, MockSafetyModule, MockAggregatorV3 (phase-aware rounds, doubles as the
                            sequencer and USDG/USD feed), MockUniswapV3Pool (real observation ring: cumulative math, interpolation, OLD)
```

Foundry gotcha that bit this codebase more than five times: `vm.prank(x)` and `vm.expectRevert(...)` apply to the **very next call**, and a view read such as `vault.currentSeriesId()`, `ah.KEEPER_ROLE()` or `usdg.balanceOf(x)` inside the argument list counts. Read arguments into locals first. `vm.expectEmit` has the same shape: put it right before the emitting call, not before a helper that makes a view call or a mint first.

Deployment order (D-044, D-049, D-050, D-054, D-058): **TickMath first** — it is a deployed library and every build of
SettlementOracle carries a link placeholder until its address is supplied (`libraries` in `foundry.toml`, or
`forge create --libraries src/libraries/TickMath.sol:TickMath:0x…`); the oracle's constructor reverts `Miswired("TICK_MATH")`
if it is unlinked or points at the wrong contract. Then RiskModule; OptionToken, BondManager and FeeRouter; AuctionHouse (holds the three as immutables and asserts the USDG of the two; `priceSource` is a placeholder until the oracle exists); CapController; SettlementOracle (RiskModule, AuctionHouse and the USDG/USD feed as immutables); `RiskModule.setSettlementOracle` (once) and `setGuardian` for both keys; `setAuctionHouse` on BondManager and FeeRouter; each vault with `auctionHouse`, `settlement = SettlementOracle`, `riskModule = RiskModule` and the same OptionToken (all immutable); `AuctionHouse.registerVault(vault)` and `setKeeper`; `SettlementOracle.registerVault(vault, feed, pool)` (asserts the whole wiring and the pool's tokens); `AuctionHouse.setPriceSource(oracle)` and `CapController.setPriceSource(oracle)`; `pool.increaseObservationCardinalityNext(65535)`; ownership to the timelock.

The token layer ships later, on its own, and needs nothing from the vault layer redeployed (`script/DeployToken.s.sol`, which calls the same `script/TokenDeployLib.sol` the test fixture uses). Order: the five holders (LiquidityEscrow, EmissionsController, two Vesting instances, PointsDistributor); then `WRITE`, whose constructor mints the whole supply into them and asserts each one's declared `allocation()`; then one `setWriteToken` per holder (a single `scheduleBatch` on mainnet, before any WRITE can move); then `WritePriceOracle` — **which also links the deployed TickMath and repeats the D-058 constructor assert** — and `setSanityBand`; then `SafetyModule`, whose constructor checks both back-references; then `EmissionsController.setSink`. Environment-specific and therefore manual afterwards: `escrow.setPool(launchpad)` + `escrow.fundAll()`, seeding the WRITE/USDG pool and raising its observation cardinality, `oracle.setPool(...)`. Then, when governance chooses: `CapController.setSafetyModule` + `setCapWeightBps` + `setCapMode(SAFETY_MODULE)`; `FeeRouter.setWriteToken` + `setPriceOracle` + `setCurator` + `setFeeMode`; and the four-call BondManager migration. `test/SettlementBase.t.sol` is the executable version.

Measured 2026-09-04 (after the token layer, D-059…D-097): SettlementOracle is **byte-identical** to the pre-token build at 22,646 bytes (1,930 headroom); AuctionHouse was too until D-100 added its `renounceOwnership` override and is now 23,101 (1,475). The new contracts are well inside the limit (re-measured after the D-098 review fixes): WritePriceOracle 10,026, SafetyModule 7,405, Vesting 6,286, PointsDistributor 4,455, WRITE 4,056, EmissionsController 3,461, LiquidityEscrow 2,739; BondManager grew to 11,067 and FeeRouter to 7,865. After `injectCoverage` (D-099) CoveredCallVault is 20,794 bytes (3,782 headroom). D-100 added 16 bytes each to AuctionHouse, OptionToken (8,690, 15,886 headroom) and CapController (3,522, 21,054); every other contract is byte-identical. TickMath deploys separately at 1,357 bytes and now has two consumers.

Slither 0.11.6 (`python -m slither . --filter-paths "lib/|test/|src/mocks/|script/"` from `contracts/` **with `~/.foundry/bin` on PATH** — without it crytic-compile cannot find `forge` and dies with a bare `FileNotFoundError`) reports 128 results, 3 of them High, and the token layer added none: `weak-prng` is `at % WEEK`, a calendar computation in the untouched `AuctionHouse.canOpen`, and `arbitrary-send-erc20` is the D-023 standing-approval pattern in `FeeRouter.flush` (`from` is the set-once `auctionHouse`, and the amount pulled is exactly `pending[vault]`, which only the AuctionHouse can increment) — now flagged on two lines because the WRITE path adds the curator rebate. The baseline's third High, `uninitialized-state` on `FeeRouter.writePool`, is **gone**: D-084 removed the field. The Medium/Low results are the canonical `divide-before-multiply` in TickMath, `bytes32` equality comparisons, destructured tuple returns, `block.timestamp` comparisons and `nonReentrant`-guarded reentrancy patterns.

`SettlementOracle.registerVault` is one-shot per vault and probes the feed for its earliest reachable round, so the feed must already serve rounds when a vault is registered (D-057). There is no re-point path: a retired feed or pool is handled by `sunset` (D-034).

The token layer was independently reviewed on 2026-09-04 (D-098): the deploy is staged so the deployer key never owns anything, and the review's findings -- a vesting grant that could be fully vested in its creating block, a raw-AMM guard that only knew Uniswap's shape, a ~29 % slash-dodge duty cycle, a missing sequencer check on the WRITE oracle, and eight tests that passed without proving anything -- are all fixed and recorded there.

Not yet built (next phases): VaultFactory, a fork test asserting the whole wiring, and the AuctionHouse switch from `capPrice` to `referencePrice` (OQ-005). `renounceOwnership` reverts `RenounceDisabled` on **all fourteen** owned contracts (D-100 closed the last three — AuctionHouse, CapController and OptionToken, which had been left out): an ownerless vault could never call `injectCoverage` or `setSunset`, an ownerless AuctionHouse could never register a vault or revoke a keeper, an ownerless CapController would freeze every cap, and an ownerless OptionToken could never serve another underlying. **`CoveredCallVault.injectCoverage` ships in v0.7 (D-099)**, so the slash-to-shortfall loop closes on chain: the timelock raises `payoutPerOption` for the still-unclaimed options of a shortfall series back to its unscaled value, pulling only what that raise makes claimable (SPEC §14; `coverageNeeded(seriesId)` sizes the purchase). The FeeRouter WRITE mode and the WRITE bond migration are implemented as of v0.6 but stay dormant until the timelock wires the token.

## Run

```bash
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariants/*'
forge fmt --check
```

`forge` lives at `~/.foundry/bin` on the dev machine (not on PATH).
