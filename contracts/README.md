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
  BondManager.sol           MM and curator bonds in USDG, participation locks, 7-day cooldown, timelock slashing (SPEC §13)
  FeeRouter.sol             performance fee booked at clearing, permissionless flush to treasury; WRITE mode gated (SPEC §11)
  SettlementOracle.sol      SPEC §9 oracle policy: paths 1/2/3 with verified keeper hints, jump guard, halt, resolveHalted,
                            resolveHaltedByOracle; `capPrice` (§12) and `referencePrice` (§7.2) (D-050…D-055)
  RiskModule.sol            guardian pauses (vault | ALL), halt registry, versioned OracleParams per vault (SPEC §15, D-050, D-056)
  libraries/                TickMath (v4-core constants, no assembly), OracleMath (TWAP tick, harmonic liquidity, depth rule, price8)
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
  invariants/               VaultHandler + VaultInvariants (vault layer) and AuctionHandler + AuctionInvariants (I-3 exact escrow
                            conservation, allocation identity, fee conservation, I-13 bond locks, preview == clear, auction OPEN ⇔
                            vault AUCTION; the handler plays depositors, MMs, keeper, settlement, issuer, Paxos freeze, timelock)
                            SettlementHandler + SettlementInvariants (I-5, I-7, I-9, I-10, I-11, I-12, I-14, payouts ≤ encumbered
                            collateral, preview == settle, halted vault cannot open; restricted to the action selectors, the scripted
                            `cycle*` functions back `test_handlerReachesEveryState`)
  mocks/                    MockRiskModule, MockPriceSource, MockSafetyModule, MockAggregatorV3 (phase-aware rounds, doubles as the
                            sequencer and USDG/USD feed), MockUniswapV3Pool (real observation ring: cumulative math, interpolation, OLD)
```

Foundry gotcha that bit this codebase more than five times: `vm.prank(x)` and `vm.expectRevert(...)` apply to the **very next call**, and a view read such as `vault.currentSeriesId()`, `ah.KEEPER_ROLE()` or `usdg.balanceOf(x)` inside the argument list counts. Read arguments into locals first. `vm.expectEmit` has the same shape: put it right before the emitting call, not before a helper that makes a view call or a mint first.

Deployment order (D-044, D-049, D-050, D-054): RiskModule first; OptionToken, BondManager and FeeRouter; AuctionHouse (holds the three as immutables and asserts the USDG of the two; `priceSource` is a placeholder until the oracle exists); CapController; SettlementOracle (RiskModule, AuctionHouse and the USDG/USD feed as immutables); `RiskModule.setSettlementOracle` (once) and `setGuardian` for both keys; `setAuctionHouse` on BondManager and FeeRouter; each vault with `auctionHouse`, `settlement = SettlementOracle`, `riskModule = RiskModule` and the same OptionToken (all immutable); `AuctionHouse.registerVault(vault)` and `setKeeper`; `SettlementOracle.registerVault(vault, feed, pool)` (asserts the whole wiring and the pool's tokens); `AuctionHouse.setPriceSource(oracle)` and `CapController.setPriceSource(oracle)`; `pool.increaseObservationCardinalityNext(65535)`; ownership to the timelock. `test/SettlementBase.t.sol` is the executable version.

Measured 2026-09-03: SettlementOracle is 22.5 KB (2.0 KB of headroom, `via_ir` off); `settle` on path 2 with `minObservationsInWindow = 16` and a 20-swap window costs under 1.5 M gas (`test_T07_settleGasBound`). Slither 0.11.6 (`python -m slither . --filter-paths "lib/|test/|src/mocks/"` from `contracts/` with `~/.foundry/bin` on PATH) reports no High findings; the Medium/Low results on the new contracts are the canonical `divide-before-multiply` in TickMath, `bytes32` equality comparisons and destructured tuple returns.

Not yet built (next phases): VaultFactory, deploy script + fork test asserting the wiring, the AuctionHouse switch from `capPrice` to `referencePrice` (OQ-005). WRITE mode of FeeRouter and the WRITE bond migration are post-token.

## Run

```bash
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariants/*'
forge fmt --check
```

`forge` lives at `~/.foundry/bin` on the dev machine (not on PATH).
