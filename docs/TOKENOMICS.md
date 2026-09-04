# $WRITE tokenomics

**Status: PROPOSAL, pending legal review.** Nothing here is an offer or a commitment. The supply split below
is implemented in `contracts/src/WRITE.sol` as `constant`s and is fixed at deployment; the schedules are
deploy-script parameters and the governance levers are timelocked. Version 0.1, 2026-09-04.

## What WRITE is for

Four uses, and no others (CLAUDE.md rule 7):

1. **Safety-module staking** — stake WRITE as the protocol's backstop; the staked USD value sets every
   vault's deposit cap (`cap = k × safetyModuleValueUSD × weight`, SPEC §12).
2. **Bonds** — curator and market-maker bonds migrate from USDG to WRITE post-launch (SPEC §13).
3. **Fee discount and burn** — a curator may pay the performance fee in WRITE at a 20 % discount; half of
   that WRITE is burned and the rest goes to the treasury (SPEC §11).
4. **Governance** — parameter changes through the 48 h timelock.

**There is no revenue share, and there will not be one.** No protocol fee, premium or settlement flow reaches
a token holder as income. Stakers earn only the fixed-supply emissions below, which governance sets and which
come out of a bucket minted at genesis — not out of revenue. This is a hard rule in `CLAUDE.md`, enforced in
`FeeRouter` (fees go to the treasury or the burn address) and covered by
`test_noHolderDistributionPathExists`.

## Supply

Fixed at **1,000,000,000 WRITE**, 18 decimals, minted once in the constructor. There is no mint function, no
owner, no pause. The whole supply is minted directly into five contracts — never into an EOA, which
`WRITE.sol` enforces structurally by requiring each recipient to declare its own allocation (D-061).

| Bucket | Amount | Share | Contract | Schedule |
|---|---:|---:|---|---|
| Liquidity | 250,000,000 | 25 % | `LiquidityEscrow` | released only into the launchpad pool, by timelock |
| Emissions | 300,000,000 | 30 % | `EmissionsController` | 4-year linear stream to the SafetyModule |
| Treasury | 200,000,000 | 20 % | `Vesting` (treasury instance) | 1095-day linear, no cliff, **non-revocable** |
| Team | 150,000,000 | 15 % | `Vesting` (team instance) | 365-day cliff then linear to day 1095, **revocable** |
| Points + bond grants | 100,000,000 | 10 % | `PointsDistributor` | Merkle rounds, each with a claim deadline |
| **Total** | **1,000,000,000** | **100 %** | | |

### Schedules in detail

- **Treasury (200 M).** Linear over 1095 days from TGE with no cliff, in a `Vesting` instance deployed with
  `allowRevocable = false`, so the timelock is structurally incapable of revoking it. Released tokens fund
  protocol operations; the timelock is the beneficiary.
- **Team (150 M).** 365-day cliff, then linear to day 1095. At the cliff, 365/1095 (one third) unlocks in a
  lump and the rest streams. Deployed with `allowRevocable = true`, so the timelock can revoke a departing
  member's *unvested* remainder — the already-vested portion always stays claimable, and the revoked
  remainder returns to the unallocated pool for re-granting rather than being burned or swept.
- **Emissions (300 M).** Streams linearly to the SafetyModule over four years at
  `300,000,000e18 / (4 × 365 days) ≈ 2.378 WRITE/second`. Governance may change the rate through the timelock
  (bounded by `MAX_RATE`, the whole bucket over one year) but never retroactively: the controller checkpoints
  before every rate change. `setRate(0)` pauses the stream. Emissions accruing while nobody is staked are
  parked in `unallocatedRewards` rather than handed to the first staker who arrives.
- **Liquidity (250 M).** Held by `LiquidityEscrow`, which can transfer to exactly one timelock-set
  destination and nothing else. There is no rescue path. The escrow holds WRITE only; the paired USDG for the
  launch pool comes from the treasury at pool creation. *(Open: the launch venue is not yet named in the SPEC.)*
- **Points and bond grants (100 M).** Points are computed entirely off-chain (D-013); this bucket is only the
  on-chain claim leg. Governance opens rounds with a Merkle root, an allocation, a start and a deadline;
  anything unclaimed at the deadline is swept to the treasury. The same bucket funds WRITE bond grants to
  market makers and curators at the bond migration.

## Governance levers (all behind the 48 h timelock)

| Parameter | Where | Bound |
|---|---|---|
| `k` (cap multiple) | `CapController` | [1, 20], default 5 |
| `capWeightBps` per vault | `CapController` | Σ ≤ 10 000 |
| emissions `rate` | `EmissionsController` | [0, `MAX_RATE`] |
| `writeDiscountBps` | `FeeRouter` | ≤ 5 000, default 2 000 |
| `writeBurnShareBps` | `FeeRouter` | ≤ 10 000, default 5 000 |
| WRITE bond requirement | `BondManager` | fixed token amount, re-pegged by governance |
| slash size | `SafetyModule` | ≤ 30 % of staked per event, ≤ one event per 14 days |
| WRITE price source | `WritePriceOracle` | Chainlink if set, else a 30-min TWAP inside a sanity band |

## Open items for legal review

1. Whether the team schedule should be 1095 days total with a 365-day cliff (as implemented) or 365 days
   plus a further 1095. This is one deploy-script argument.
2. The launch venue for the liquidity bucket, and the source of its paired USDG.
3. Jurisdictional treatment of the points airdrop, and whether claims need geo-gating at the frontend in the
   same way the app is geo-blocked (CLAUDE.md rule 10).
4. The review cadence for re-pegging the WRITE bond requirement, which is a fixed token amount and therefore
   drifts against USD.
