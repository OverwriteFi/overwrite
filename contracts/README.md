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
  interfaces/               IStockToken (ERC-8056), IRiskModule, ICapController, IPriceSource, ISafetyModule, IOptionToken, ICoveredCallVault
  mocks/                    MockStockToken, MockUSDG (testnet mocks, SPEC §1.8 / D-014)
test/
  Base.t.sol                fixture: one vault wired to mocks; AuctionHouse and Settlement are plain addresses
  CoveredCallVault.t.sol    unit tests, one per external function incl. every revert path
  CoveredCallVault.fuzz.t.sol  fuzz: deposit/withdraw math, coverage bound, payout formula, queues, premium split
  OptionToken.t.sol, CapController.t.sol
  invariants/               VaultHandler (guarded actions + ghosts) and VaultInvariants (I1–I4 of the brief, SPEC I-1/I-2/I-3/I-4/I-6/I-8)
  mocks/                    MockRiskModule, MockPriceSource, MockSafetyModule
```

Not yet built (next phases): AuctionHouse, SettlementOracle (owns the §9 oracle policy and implements `IPriceSource`), RiskModule, FeeRouter, BondManager, VaultFactory, deploy script.

## Run

```bash
forge build --sizes
forge test
FOUNDRY_PROFILE=ci forge test --match-path 'test/invariants/*'
forge fmt --check
```

`forge` lives at `~/.foundry/bin` on the dev machine (not on PATH).
