# RUNBOOK — deploying Overwrite to Robinhood Chain mainnet (4663)

The exact procedure for a mainnet deployment: what you sign with the Ledger, in what order, what to check
after each step, and how to abort. Written to be followed literally, one signature at a time.

The deploy layer is `contracts/script/`; the chain's parameters are `contracts/config/4663.json`. Read
`contracts/README.md` lines 122–129 for why the ordering is what it is, and `docs/DECISIONS.md` D-100…D-106
for the decisions this procedure encodes.

**The whole design in one sentence:** every contract is constructed with the `TimelockController` as its
owner, so the deployer key only ever calls `new` and there is nothing to hand over afterwards — all the wiring
is two timelock batches.

---

## 0. Keys

| Key | Holds | Used for |
|---|---|---|
| **Deployer** | nothing, ever | signs the `new` transactions of stages 1 and 3. A hot key is acceptable: it owns no contract, holds no role and holds no WRITE. Its only power is to waste its own gas. |
| **Admin EOA** (hardware wallet) | `PROPOSER_ROLE`, `EXECUTOR_ROLE`, `CANCELLER_ROLE` on the timelock | signs `scheduleBatch`, `executeBatch` and `cancel`. No multisig, by decision (D-003). |
| **Guardian hot** | `GUARDIAN_ROLE` on `RiskModule` | on the keeper server, **distinct from the keeper's transaction key** (D-029), so alerting can pause within seconds with nobody present. |
| **Guardian cold** | `GUARDIAN_ROLE` on `RiskModule` | off-server (hardware wallet or phone signer), so a compromised server cannot stop a human pausing during the 48 h it takes to rotate roles. |
| **Keeper** | `KEEPER_ROLE` on `AuctionHouse` | the only caller of `openAuction` (D-028). Everything else in the lifecycle is permissionless, so liveness never depends on it. |
| **Treasury** | receives fees and slash proceeds | a timelock-controlled address. Team and treasury tokens live in `Vesting`, never here (CLAUDE.md rule 5). |

A guardian can only pause and unpause new auctions and deposits. It cannot move funds, change a parameter,
block a withdrawal, or stop `settle`, `halt` or `resolveHaltedByOracle` (SPEC §15).

**If the admin key is lost**, the protocol is frozen in its current configuration: every parameter setter is
`onlyOwner` and the owner is a timelock nobody can propose to any more. Vaults keep running — deposits,
auctions, settlement and withdrawals are all permissionless or keeper-driven — but nothing can ever be
re-parameterised, no vault can be added, and `sunset` is unreachable. There is no recovery path. Treat the
admin key's backup as the single most important artefact of the deployment.

**OQ-001 is still open**: whether a second cold key should hold `CANCELLER_ROLE` so a compromised admin key
cannot both queue and execute a malicious batch. `config/4663.json` carries an empty `cancellers` array as a
placeholder. If you adopt it, the canceller must **not** be a guardian key (D-029).

---

## 1. Pre-flight

Nothing here sends a transaction. Do all of it before touching the Ledger.

1. **Fill in `contracts/config/4663.json`.** `governance.admin`, both `governance.guardians`,
   `governance.treasury` and `governance.keeper` ship as zero addresses on purpose; `Config.validate` refuses
   to run on 4663 while any of them is zero. Leave `timelockMinDelay` at `172800` and `deployerIsAdmin` at
   `false` — those two are what make the verification strict.
2. **Confirm the vault list.** It ships with NVDA only. SPEC §1.5 records that the SPY/USDG and QQQ/USDG
   0.05 % pools exist, but their depth against the 250 000 USDG / 1 % rule of SPEC §9.3 was never measured,
   and **OQ-002 blocks creating those vaults until it is.** Measure first or ship one vault.
3. **Re-measure the NVDA/USDG pool** against the same rule, and re-read the cap rule of THREAT-MODEL T-03
   before setting `capUSD` above the D-011 launch value of 25 000 USDG.
4. **Check the feed serves rounds.** `SettlementOracle.registerVault` probes the Chainlink proxy for its
   earliest reachable round and reverts `Miswired("FEED_FIRST_ROUND")` if there is none (D-057).
   ```bash
   cast call 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url robinhood
   ```
5. **Set `ROBINHOOD_RPC_URL` in `.env`** (gitignored; `.env.example` has placeholders only).
6. **Run the fork test against mainnet.** This is the real integration test — it runs the same deploy library
   against the actual USDG, stock token, feed and pool:
   ```bash
   cd contracts && DEPLOY_FORK_RPC_URL="$ROBINHOOD_RPC_URL" forge test --match-path test/DeployFork.t.sol -vv
   ```
   A `[SKIP]` means the RPC is not set. Do not proceed on a skip.
7. **Run everything else green.**
   ```bash
   cd contracts && forge build --sizes && forge test && forge fmt --check
   ```
8. **Fund the deployer.** The 46630 rehearsal cost 0.00156 ETH for 173 transactions at 0.02 gwei. Mainnet gas
   differs; get the real number from the dry run in step 2.1 below and fund with a wide margin.

---

## 2. Stage 1 — the deployer signs `new`, and nothing else

### 2.1 Dry run

```bash
cd contracts && ./script/deploy.sh 4663 --ledger --dry-run
```

This deploys `TickMath` for real (one small transaction — an external library's address is a compile-time
input, so there is nothing to simulate against without it; D-058) and records it in the config. Everything
after that is simulated. Read the **estimated total gas** and the **estimated amount required** at the end and
confirm the deployer can cover it several times over.

`TickMath` is a pure library: no state, no owner, no privileges, nothing references it until the oracles are
deployed. Deploying it early commits to nothing.

### 2.2 The real thing

```bash
cd contracts && ./script/deploy.sh 4663 --ledger
```

The Ledger will be asked to sign each `new` in turn (`--slow` sends one at a time; constructors assert on
contracts deployed moments earlier, and a 100 ms-block chain will otherwise reorder a batch of nonces). With
the shipped config that is the timelock, the seven core contracts, one vault, the five WRITE holders and
WRITE — 15 contracts.

The script then **stops**, because `timelockMinDelay` is 172 800, and prints batch A. It writes
`deployments/4663.json`.

### 2.3 Check before going further

```bash
cd contracts && forge script script/Verify.s.sol:Verify --sig "run()" \
  --rpc-url robinhood --libraries src/libraries/TickMath.sol:TickMath:<TICKMATH>
```

It will **fail** at this point, and the message tells you how far you got. Expected here:
`bondManager: auctionHouse` — batch A has not run, so the back-references are unset. That is correct.

What you can check by hand right now, and should:

```bash
cast call <VAULT>     "owner()(address)"        --rpc-url robinhood   # == the timelock
cast call <VAULT>     "pendingOwner()(address)" --rpc-url robinhood   # == 0
cast call <TIMELOCK>  "getMinDelay()(uint256)"  --rpc-url robinhood   # == 172800
cast call <WRITE>     "totalSupply()(uint256)"  --rpc-url robinhood   # == 1e27
cast call <WRITE>     "balanceOf(address)(uint256)" <DEPLOYER> --rpc-url robinhood   # == 0
```

The system is inert here: `capUSD` is 0, so no deposit is possible, and `KEEPER_ROLE` is ungranted, so no
auction can open. Nothing is at risk while you sit on this state.

---

## 3. Batch A — the first timelock signature

The script printed, for each of the **17 calls** (one vault, two guardians, token layer included), the target
and the calldata; then the whole `scheduleBatch` calldata and the whole `executeBatch` calldata.

The batch, in order — this ordering is load-bearing, and every constraint is a setter assert, not a preference:

| # | Call | Why here |
|---|---|---|
| 1 | `bondManager.setAuctionHouse` | one-shot (D-044); asserted by `registerVault` |
| 2 | `feeRouter.setAuctionHouse` | one-shot; asserted by `registerVault` |
| 3 | `riskModule.setSettlementOracle` | one-shot; asserted by `oracle.registerVault` |
| 4–5 | `riskModule.setGuardian` ×2 | hot and cold |
| 6 | `auctionHouse.setKeeper` | |
| 7 | `optionToken.registerVault` | irreversible, one vault per underlying |
| 8 | `auctionHouse.registerVault` | needs 1 and 2; also seeds `feeBps = 1000` |
| 9 | `settlementOracle.registerVault` | needs 3 **and** 8 |
| 10 | `capController.setCapUSD` | without it the vault takes no deposits |
| 11 | `auctionHouse.setPriceSource` | swaps the placeholder for the oracle |
| 12 | `capController.setPriceSource` | same |
| 13–17 | `setWriteToken` ×5 | on the five WRITE holders |

### 3.1 Schedule

Send the printed `scheduleBatch` calldata to the timelock from the admin EOA. The Ledger blind-signs it, so
**reconcile the device against the printed list before approving**: check the target count, and spot-check
that call 9's target is the SettlementOracle and its arguments are your vault, your feed and your pool.

The salt is `keccak256("overwrite.deploy.batchA")` — deterministic, so the operation id is reproducible:

```bash
cast call <TIMELOCK> "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)" \
  "[<targets>]" "[<zeros>]" "[<payloads>]" \
  $(cast --format-bytes32-string "") $(cast keccak "overwrite.deploy.batchA") --rpc-url robinhood
```

### 3.2 Wait 48 hours

```bash
cast call <TIMELOCK> "isOperationPending(bytes32)(bool)" <ID> --rpc-url robinhood
cast call <TIMELOCK> "isOperationReady(bytes32)(bool)"   <ID> --rpc-url robinhood
cast call <TIMELOCK> "getTimestamp(bytes32)(uint256)"    <ID> --rpc-url robinhood
```

The queued operation is public. Use the wait: anyone reviewing the deployment can decode it in that window.

### 3.3 Execute

Send the printed `executeBatch` calldata from the admin EOA once `isOperationReady` is true.

### 3.4 Check

```bash
cd contracts && forge script script/Verify.s.sol:Verify --sig "run()" \
  --rpc-url robinhood --libraries src/libraries/TickMath.sol:TickMath:<TICKMATH>
```

Still expected to fail, now on `emissions: sink` — batch B has not run. Everything before it must pass:
ownership, timelock roles, guardians, keeper, core wiring, the vault's seven immutables, the feed's decimals,
the pool's fee tier and token pair, caps, fees, bonds and pause state.

---

## 4. Stage 3 — the deployer signs two more `new`s

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --sig "runStage3()" \
  --rpc-url robinhood --broadcast --slow \
  --libraries src/libraries/TickMath.sol:TickMath:<TICKMATH> --ledger
```

It reads `deployments/4663.json`, refuses to run unless batch A has executed
(`EmissionsController.writeToken() == WRITE`), deploys `WritePriceOracle` and `SafetyModule` owned by the
timelock, updates the address book and prints batch B.

`SafetyModule`'s constructor asserts `emissions.writeToken() == write`, which is exactly why this stage cannot
come before batch A.

---

## 5. Batch B — the second timelock signature

Two calls, salt `keccak256("overwrite.deploy.batchB")`:

| # | Call | Why |
|---|---|---|
| 1 | `writePriceOracle.setSanityBand` | must precede any `setPool`; until it is set, `writePrice()` reports unavailable and the cap stays closed (D-066) |
| 2 | `emissionsController.setSink` | one-shot; points the 300 M emissions stream at the SafetyModule |

Same procedure: schedule, wait 48 h, execute.

### 5.1 Final check

```bash
cd contracts && forge script script/Verify.s.sol:Verify --sig "run()" \
  --rpc-url robinhood --libraries src/libraries/TickMath.sol:TickMath:<TICKMATH>
```

This must now print **`All assertions passed.`** and the address table. On 4663 that includes the strict
half: the deployer holds no timelock role at all, owns nothing, and holds no WRITE.

It also prints a `WARN` for any owned contract whose ownership could still be renounced. After D-100 all
fourteen are protected, so **it should print nothing**. If it prints something, a contract was added without
the `renounceOwnership` override — stop and fix that before announcing anything.

---

## 6. Blockscout verification

`./script/deploy.sh` passes `--verify` to `forge script`, so contracts are verified as they are deployed,
with the constructor arguments forge already knows. Verification is an off-chain HTTP loop: if it is
interrupted, nothing on chain is affected and it can simply be re-run.

To re-verify, `script/Verify.s.sol` writes `deployments/<chainId>-verify.sh` with one command per contract:

```bash
cd contracts && sh deployments/4663-verify.sh
```

The two chains, for reference:

| Chain | Verifier URL |
|---|---|
| 4663 | `https://robinhoodchain.blockscout.com/api/` |
| 46630 | `https://explorer.testnet.chain.robinhood.com/api/` |

A single contract by hand:

```bash
forge verify-contract <ADDRESS> src/AuctionHouse.sol:AuctionHouse \
  --chain-id 4663 --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/ \
  --libraries src/libraries/TickMath.sol:TickMath:<TICKMATH> \
  --guess-constructor-args --watch
```

**`--libraries` is not optional.** The deployed bytecode of `SettlementOracle` and `WritePriceOracle` has the
TickMath address linked into it; without the same flag the recompiled bytecode will not match and
verification fails for reasons that look like a compiler mismatch.

---

## 7. How to abort

**Before batch A executes** — nothing is wired. The contracts are inert: `capUSD` is 0 so no deposit is
possible, `KEEPER_ROLE` is ungranted so no auction can open, and no user funds exist. Walk away and redeploy
from scratch. The only cost is gas. Delete `deployments/4663.json` so the next run starts clean.

**A batch is queued and you want it stopped** — `cancel` from the admin EOA, which holds `CANCELLER_ROLE`:

```bash
cast send <TIMELOCK> "cancel(bytes32)" <ID> --rpc-url robinhood --ledger
```

Cancelling is immediate; it is not itself delayed.

**After batch A executes** — say this part out loud before you start, because it is the point of no return.
`optionToken.registerVault`, `settlementOracle.registerVault`, `riskModule.setSettlementOracle` and both
`setAuctionHouse` calls are **one-shot with no re-point path** (D-044, D-050, D-057). A vault wired to the
wrong feed or the wrong pool cannot be repaired. The only exit is `sunset(vault)` behind the timelock, which
lets the current series settle and then leaves the vault permanently IDLE with withdrawals open forever
(D-034), plus a fresh deployment of everything. Option tokens, bonds and premium accumulators of the old
deployment keep working until claimed.

This is why step 1.4 checks the feed and step 3.1 asks you to spot-check call 9 against the device.

**Emergency, post-launch** — the guardian pauses. `pauseNewAuctions(ALL)` and `pauseDeposits(ALL)` take
effect immediately with no delay, where `ALL` is `address(0)`. Either guardian can unpause the other's pause.
A pause cannot block withdrawals, `claimPremium`, `withdrawRefund`, `claimOptions`, `OptionToken.claim`,
`claimWithdrawal`, or settlement.

---

## 8. Rotation

Both are `onlyOwner`, so both are 48 h timelock operations (SPEC §15, D-003, D-012).

**Guardian** — `riskModule.setGuardian(newKey, true)` then `riskModule.setGuardian(oldKey, false)`. Grant
before revoking, so there is never a window with fewer than two holders. A compromised guardian key can at
worst pause; the 48 h to rotate it is survivable, which is why the second, off-server holder exists.

**Keeper** — `auctionHouse.setKeeper(newKey, true)` / `setKeeper(oldKey, false)`. The fast response to a
rogue keeper is not rotation, it is the guardian pausing new auctions within seconds; the rotation follows at
governance speed.

Note that no account holds `DEFAULT_ADMIN_ROLE` on either `RiskModule` or `AuctionHouse` — the owner is the
admin. `grantRole` and `revokeRole` will always revert. Use `setGuardian` and `setKeeper`.

---

## 9. Deferred — governance decides when

None of this is part of the deploy (D-063: it depends on the launch venue, which is an open item in
`docs/TOKENOMICS.md`).

- `escrow.setPool(launchpad)` then `escrow.fundAll()` — the 250 M launch liquidity.
- Seed the WRITE/USDG pool, raise its observation cardinality to at least 256, then `writePriceOracle.setPool`.
- `writePriceOracle.setSequencerFeed` — only if Chainlink ever publishes an uptime feed for this chain
  (`sequencerFeed` is 0 today by D-005).
- The two `Vesting.createSchedule` calls: treasury 1095-day linear no cliff, team 365-day cliff then linear
  to day 1095.
- `pool.increaseObservationCardinalityNext(65535)` on every allowlisted pool. Permissionless, and the deploy
  already calls it, but the keeper monitors coverage hourly (SPEC §9.5).
- The cap switch, **as one batch**: `capController.setSafetyModule`, then `setCapWeightBps` for every active
  vault, then `setCapMode(SAFETY_MODULE)`. Split across batches there is a window where the mode is on and
  the weights are zero, which closes deposits protocol-wide.
- The FeeRouter WRITE mode: `setWriteToken`, `setPriceOracle`, `setCurator(vault, …)`, `setFeeMode(vault, WRITE)`.
- The BondManager migration, four separately visible calls (D-081): `setWriteToken`,
  `setRequiredAmountFor(WRITE, MM, …)`, `setRequiredAmountFor(WRITE, CURATOR, …)`, `startMigration(30 days)`.

---

## 10. The 46630 rehearsal

The whole procedure was rehearsed on testnet 46630 on 2026-09-04. `contracts/deployments/46630.json` is the
result: 26 contracts plus `TickMath`, all four stages executed, all 27 verified on Blockscout, and
`Verify.s.sol` green against the live chain.

Two differences from the procedure above, both recorded in `config/46630.json` and both reported by
`Verify.s.sol` as a `TESTNET DEVIATION` banner:

- **`timelockMinDelay` is 0** and the deployer doubles as the admin EOA, guardian, treasury and keeper,
  because only one key is funded there. That lets `run()` schedule and execute both batches itself and finish
  all four stages in one command. `deployerIsAdmin: true` in the config makes the deviation machine-readable
  and is the only thing that relaxes any assertion — the deployer still owns no contract and holds no WRITE,
  and those are still asserted.
- **Every external is mocked** (SPEC §1.8, D-014): USDG, the USDG/USD feed, and per vault the stock token,
  the Chainlink feed and the 0.05 % pool. A cast sweep of every address in `docs/SPEC.md` against 46630
  confirmed only Uniswap v4, Permit2 and Multicall3 exist there. The eight mocks are listed in the `mocked`
  field of the address book, and a re-run reads them back and reuses them; delete `deployments/46630.json` to
  force a fresh set.

One stray artefact, so it is not a mystery later: **`0x31E96497285a1F658cdAD985C15B300Fc786031e` on 46630 is
an orphaned first copy of `TickMath`** (deployer nonce 0). `deploy.sh` deployed it and then failed to parse
`forge create --json`; the live copy is `0x80AbE3b669ecF49FA57883661A4c4F94E79B79e7` (nonce 1), which is what
the config records and what everything is linked against. The orphan is a pure library with no state and no
references. The parser bug is fixed.

The testnet system is for keeper and frontend end-to-end runs only. The real integrations are exercised by
the mainnet fork test (step 1.6), which SPEC §1.8 names the primary test path.
