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
  interfaces/               IStockToken (ERC-8056), IRiskModule, ICapController, IPriceSource, ISafetyModule, IOptionToken,
                            ICoveredCallVault, IAuctionHouse, IBondManager, IFeeRouter
  mocks/                    MockStockToken, MockUSDG (testnet mocks, SPEC §1.8 / D-014; USDG has `paused()` / `isFrozen()`)
test/
  Base.t.sol                fixture: one vault wired to mocks; AuctionHouse and Settlement are plain addresses
  AuctionBase.t.sol         fixture: real AuctionHouse + BondManager + FeeRouter wired to a vault, four bonded MMs, Monday 14:00
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
  OptionToken.t.sol, CapController.t.sol, BondManager.t.sol, FeeRouter.t.sol
  invariants/               VaultHandler + VaultInvariants (vault layer) and AuctionHandler + AuctionInvariants (I-3 exact escrow
                            conservation, allocation identity, fee conservation, I-13 bond locks, preview == clear, auction OPEN ⇔
                            vault AUCTION; the handler plays depositors, MMs, keeper, settlement, issuer, Paxos freeze, timelock)
  mocks/                    MockRiskModule, MockPriceSource, MockSafetyModule
```

Foundry gotcha that bit this codebase more than five times: `vm.prank(x)` and `vm.expectRevert(...)` apply to the **very next call**, and a view read such as `vault.currentSeriesId()`, `ah.KEEPER_ROLE()` or `usdg.balanceOf(x)` inside the argument list counts. Read arguments into locals first. `vm.expectEmit` has the same shape: put it right before the emitting call, not before a helper that makes a view call or a mint first.

Deployment order (D-044, D-049): OptionToken, BondManager and FeeRouter first, then AuctionHouse (holds all three as immutables and asserts the USDG of the two), then `setAuctionHouse` on BondManager and FeeRouter, then each vault with `auctionHouse = AuctionHouse` and the same OptionToken (both immutable), then `AuctionHouse.registerVault(vault)` (asserts the wiring, rejects any other OptionToken) and `setKeeper`. One AuctionHouse serves exactly one OptionToken.

Not yet built (next phases): SettlementOracle (owns the §9 oracle policy, implements `IPriceSource` for both CapController and AuctionHouse, takes over the D-031 parameter snapshot), RiskModule, VaultFactory, deploy script + fork test asserting the wiring. WRITE mode of FeeRouter and the WRITE bond migration are post-token.

## Run

```bash
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariants/*'
forge fmt --check
```

`forge` lives at `~/.foundry/bin` on the dev machine (not on PATH).
