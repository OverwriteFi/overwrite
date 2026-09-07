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
5. **Set `ROBINHOOD_RPC_URL` in `.env`** (gitignored; `.env.example` has placeholders only). **Include the
   scheme** (`https://…`): `deploy.sh` prepends `https://` when it is missing, but a hand-run
   `forge script … --rpc-url "$ROBINHOOD_RPC_URL"` or `cast … --rpc-url` does not and fails with
   `invalid provider URL … relative URL without a base` (REHEARSAL-1 item 7). The same applies to
   `ROBINHOOD_TESTNET_RPC_URL`.
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

> Audit 2026-09-05 (D-113): `deploy.sh` refuses anything but `--ledger` on 4663, `Config.validate` refuses a mainnet
> config with `timelockMinDelay < 172800`, `deployerIsAdmin = true`, fewer than two guardians or a key used twice, and
> `run()` must **not** be re-run between stage 1 and batch A on a real-delay chain — it would deploy a second system and
> overwrite `deployments/4663.json` (re-print batch A from the address book instead).

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

The script printed, for each of the **19 calls** (one vault, two guardians, token layer included), the target
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
| 13 | `auctionHouse.freezePriceSource` | one-way (audit G-1, D-113): `S_ref` can never be re-pointed again; refuses a placeholder |
| 14 | `capController.freezePriceSource` | same for `S_cap` |
| 15–19 | `setWriteToken` ×5 | on the five WRITE holders |

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

Send the printed `executeBatch` calldata from the admin EOA once `isOperationReady` is true. Sent early it
reverts `TimelockUnexpectedOperationState(id, Ready)` — that is the delay working, not a wiring error
(REHEARSAL-1 §13 shows the revert and the successful execute 48 h later). The three `cast call`s of §3.2
are the whole pre-flight for *every* timelock operation, not only batch A: `hashOperationBatch` for the id,
`getTimestamp` for the ready time, `isOperationReady` before signing the execute.

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

### 8.1 Reopen after a pause

Two routes reopen a paused vault, and they cost very different things (REHEARSAL-1 S-2).

- **Guardian unpause — immediate.** Either guardian key may call `riskModule.unpauseDeposits(vault | ALL)` and
  `unpauseNewAuctions(vault | ALL)` with no delay (SPEC §15, D-029: either holder can unpause the other's
  pause). **This is the route after a false alarm** or once the incident that caused the pause is understood.
  ```bash
  cast send <RISK_MODULE> "unpauseNewAuctions(address)" 0x0000000000000000000000000000000000000000 --rpc-url robinhood --ledger   # guardian key
  cast send <RISK_MODULE> "unpauseDeposits(address)"    0x0000000000000000000000000000000000000000 --rpc-url robinhood --ledger
  ```
- **Timelock unpause — 48 h.** The owner may schedule the same two calls through the TimelockController.
  Use it only when the reopening itself should sit in the public queue for review. Its cost is the calendar:
  a pause on Monday that is unpaused through the timelock reopens on Wednesday, the Monday opening window
  (14:00 ± `openTolerance`) is gone, and **that week's weekday series is skipped**; the keeper reports
  "waiting (outside every opening window)" until Friday's weekend window. Schedule the unpause so that it
  executes *before* the next opening window, or accept the skipped week explicitly.

Either way, a `HALTED` vault stays closed by its own state machine until the series is resolved (D-050);
unpausing only reopens deposits and new auctions. After any unpause, confirm with
`riskModule.depositsPaused(vault)` / `auctionsPaused(vault)` and watch the keeper's next tick.

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

The whole procedure was rehearsed on testnet 46630 on 2026-09-04 and **redeployed on 2026-09-05 after the
internal audit** (D-113; commit e471df6). `contracts/deployments/46630.json` is the current result: 18 new
protocol contracts on top of the eight reused mocks and the reused `TickMath`, all four stages executed, all
18 verified on Blockscout, `Verify.s.sol` green against the live chain, and the keeper's week simulation
green against the new addresses. A full operating rehearsal on an anvil fork of that deployment is
`docs/REHEARSAL-1.md`.

Two differences from the procedure above, both recorded in `config/46630.json` and both reported by
`Verify.s.sol` as a `TESTNET DEVIATION` banner:

- **`timelockMinDelay` is 0** and the deployer doubles as the admin EOA, guardian, treasury and keeper,
  because only one key is funded there. That lets `run()` schedule and execute both batches itself and finish
  all four stages in one command. `deployerIsAdmin: true` in the config makes the deviation machine-readable
  and is the only thing that relaxes any assertion — the deployer still owns no contract and holds no WRITE,
  and those are still asserted. Since D-113 it is also what *enables* the direct schedule-and-execute path:
  a zero delay alone no longer does, and `Config.validate` refuses `deployerIsAdmin: true` on 4663.
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

---

## 11. Running the keeper

The keeper is the only thing that drives the protocol. `openAuction` is the sole privileged call in the
system (`KEEPER_ROLE`, D-028); `clear`, `settle`, `halt`, the queue processors, `releaseLocks` and
`FeeRouter.flush` are permissionless, and the keeper runs them because somebody has to, not because the
key is entitled to anything by doing so. Liveness never depends on it: anyone can settle.

Code lives in `keeper/`. TypeScript on Node 22 with viem, holding exactly one key.

### 11.1 Keys and what they can do

| Key | Env | Can call | Cannot |
|---|---|---|---|
| Keeper | `KEEPER_PRIVATE_KEY` | `openAuction`, `clear`, `releaseLocks`, `settle`, `halt`, `resolveHaltedByOracle`, `processDeposits`, `processRedeems`, `flush` | anything else — `src/chain/tx.ts` refuses to sign a call whose (contract, function) pair is not on that list, and the addresses come from the deploy's own address book, so a config typo cannot aim a call elsewhere |
| Guardian (optional) | `GUARDIAN_PRIVATE_KEY` | `pauseDeposits`, `pauseNewAuctions`, `unpauseDeposits`, `unpauseNewAuctions` | move any value. Ships **disarmed** (`GUARDIAN_AUTOPAUSE=false`); see 11.6 |

The two must be different keys (D-029); the keeper refuses to start if they are equal. Neither is ever
logged: pino redacts the known field names, and a second pass scrubs anything shaped like a 32-byte hex
value or a URL carrying credentials out of every message.

`resolveHalted` (the timelocked path 4) is deliberately **not** on the keeper's list. The keeper reports
that a human resolution is needed; it never proposes one.

**What market makers need to know about payouts** (REHEARSAL-1 §8). Option allocations are pull-based in
two ways, and neither expires: `AuctionHouse.claimOptions(seriesId, to)` mints the ERC-1155 options, which
are then redeemed with `OptionToken.claim(seriesId, qty, to)` after settlement; or
`AuctionHouse.claimPayout(seriesId, to)` mints and claims in one transaction (D-038). Escrow above the
clearing price and unfilled quantity is pulled with `withdrawRefund(to)`. Payout is in the stock token,
`payoutPerOption = (S − K) / S` per option (SPEC §7.1).

### 11.2 First run

```bash
cd keeper
npm ci
npm run gen:abi          # regenerates src/abi/generated.ts from contracts/out, after a contract change
npm run typecheck && npm test
DRY_RUN=true npm run dev # simulates every action, sends nothing
```

A dry run is a real exercise of the decision logic: it builds hints, prices reserves and simulates each
transaction against live state, and stops before `writeContract`. Read one tick of its output before
turning it loose.

Then either Docker or systemd, **not both** — two keepers sharing one key interleave nonces:

```bash
docker compose --env-file ../.env up -d --build    # from keeper/
sudo systemctl enable --now overwrite-keeper
curl -s http://127.0.0.1:8787/status | jq '.overall, .vaults[].state'
```

`--env-file` matters. The repo root `.env` also holds `DEPLOYER_PRIVATE_KEY`, and an `env_file:` entry
would inject the whole file into the container — handing the keeper the deploy key it must never have,
and rendering that key on the terminal of anyone who runs `docker compose config`. The flag makes the
root `.env` an *interpolation* source only; the explicit `environment:` list in `docker-compose.yml` is
the allowlist of what actually reaches the process. To inspect the stack without rendering any secret:

```bash
docker compose --env-file ../.env config --no-interpolate
```

### 11.3 What it does, and when

All times UTC. The Friday close is computed from `America/New_York`, so it is 20:00 UTC under EDT and
21:00 UTC under EST. SPEC §5's fixed-timestamp rule holds: expiry never moves for a holiday or an early
close, and it *cannot* — the contract requires expiry in [Fri 19:30, Fri 21:30] and a 13:00 ET half-day
close is 18:00 UTC. The 2026/2027 NYSE calendar in `src/time/nyse.ts` therefore drives **notes and
alerts only**.

| When | Action |
|---|---|
| Monday 14:00:00, or up to `openTolerance` late — never early | `openAuction(vault, WEEKDAY, fridayClose, distance, reserve)`. The contract accepts 14:00 ± `openTolerance`, but the early half is the contract's allowance, not the keeper's schedule: a keeper that opened at 12:00 would close the book before the 14:00 an MM set an alarm for |
| Monday 14:15 → 15:15 | `clear` — **inside `[auctionClose, auctionClose + clearGrace)`**, 1 h by default (D-113 F-2). A later clear takes the skip path: every bid is refunded, the series is SKIPPED, the week's premium is gone. Auctions opened in one tick close a few seconds apart, so this is per vault, not one moment |
| after a skip, same window, **only if the skipped series had at least one bid** | `openAuction` again — a SKIPPED series hands the vault back IDLE and `canOpen` (D-046) accepts another open inside the same window; the keeper re-opens at once (`openAuction KIND (retry after skip)`) so the bidders a late clear refunded get a second chance. An empty book is not re-opened: a fresh series 15 minutes later has the same empty book, and on the 46630 demo that loop burnt 24 series ids in one Monday window. The week's series is skipped and the next open is the next scheduled one |
| Friday close | `settle` — Chainlink at expiry (path 1), else the 30-min TWAP (path 2) |
| Friday close + 10 min | `openAuction(vault, WEEKEND, Sunday 23:59, …)` |
| Friday close + 25 min → +85 min | `clear`, same `clearGrace` rule |
| Sunday 23:59 | `settle` — the 60-min TWAP (path 2), else the first fresh round after expiry (path 3, deadline Monday 15:00) |
| any time, vault IDLE | `processDeposits` / `processRedeems`, `releaseLocks`, `flush` |

The scheduler does not own these deadlines as cron callbacks. Every tick (default 30 s) re-derives what
is due from chain state and epoch-week arithmetic, so a missed tick, a restart or an RPC outage costs
latency and nothing else. Idempotency is the contract's: a second `openAuction` is refused `NOT_IDLE`, a
second `clear` `WrongAuctionState`, a second `settle` `NOT_LIVE` — each caught at simulate, before
anything is signed. `keeper/state/` is advisory only; deleting it loses no correctness.

**The clock is chain time** — `block.timestamp`, never the host clock. That is what every contract check
uses, and it is what lets the fork harness drive a whole simulated week through the same code (D-108).

### 11.4 Strike and reserve

The keeper supplies three numbers. `expiry`, because the DST offset is off-chain knowledge (D-046).
`strikeDistanceBps`, because the strike itself is derived on chain from `sRef` and is never
keeper-supplied (SPEC §7.2). And `reservePrice`, the one value the contract cannot verify and only
bounds (SPEC §8.3).

The reserve is a **floor, not a forecast** — see D-107. Black-Scholes at trailing realised volatility, on
a session-based variance clock, clamped into `reserveBounds()` with a margin above the lower bound so a
feed update between simulate and inclusion cannot invalidate it. When the estimator has too little
history, or the feed has not moved at all, it falls back to the per-vault `fallbackVolAnnualBps` and says
so. Every reserve is logged with its σ, that σ's source, the model price and the contract floor; the
rounds behind each estimate are kept in `state/vol-<SYMBOL>.json` as an audit trail, because the reserve
is the one input nobody else can reconstruct after the fact.

Configured strike distances are checked against the live `strikeDistanceBounds()` at startup and the
keeper **refuses to start** on a mismatch rather than clamping — selling a different option than the
operator configured is the failure D-027 exists to prevent. That check is why SPY ships at 300 bps
weekday and not the 200 the spec names: see D-109.

### 11.5 Alerts — what each means and what to do

Alerts reach Telegram when `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set, and always reach the log
and `status.json`. They are deduplicated with a cooldown and cleared with an explicit `RECOVERED`.

| Alert | Means | Do |
|---|---|---|
| `keeper.balance` | The keeper cannot pay for many more transactions | Top it up. CRIT means the next `openAuction` may not land |
| `chainlink.staleness` | The vault's feed has used most (WARN) or all (CRIT) of its `weekdayMaxStale` budget | Nothing, on a weekend or a holiday — the 24/5 feed is quiet by design. Inside a session, check the feed on Blockscout; a weekday settle will fall through to the TWAP |
| `usdg.staleness` / `usdg.peg` | The peg feed is stale, or USDG is outside the on-chain band | Neither halts a series. Both remove the **TWAP** path (SPEC §9.5), so a weekend series settles on path 3 instead. If the peg is genuinely broken, expect weekend settlements to run to the Monday 15:00 deadline |
| `pool.coverage` | Fewer than `minObservationsInWindow` swaps in the last hour, or the ring cannot span `window + twapGrace` | The weekend TWAP path will be rejected `OBSERVATIONS`. Call `increaseObservationCardinalityNext` (permissionless) if cardinality is the problem; if the pool is simply quiet, path 3 is the fallback and this is informational |
| `clear.window` WARN / CRIT | WARN: fewer than 15 minutes left in `[auctionClose, auctionClose + clearGrace)`; CRIT: the window has passed | WARN: the keeper is not clearing — check its log and balance; anyone may call `clear`. CRIT: the next `clear` **skips** the series and refunds every bid (REHEARSAL-1 S-1). If still inside the opening window the keeper re-opens on its own; otherwise the week is lost |
| `settlement.pending` WARN | A series is past expiry and not yet settled | Usually the grace window doing its job. Read the reason: `GRACE`, `TWAP_GRACE_OPEN`, `DEADLINE_OPEN` and `PATH_AVAILABLE` all mean "not yet, by design" |
| `settlement.pending` CRIT | Well past grace, or the vault is HALTED | If HALTED, the alert carries `unlockAt`. Before it, only a timelocked `resolveHalted` can close the series (48 h, price inside the ±25 % band). After it, the keeper resolves permissionlessly on its own |
| `HINT_UNVERIFIABLE` (settle log) | The run of invalid rounds before expiry is longer than the contract's 32-round skip bound, so **no** hint verifies | Do not retry; nothing can be built. The §9.6 backstop at `expiry + 7 days` is the only route, and the keeper takes it automatically |
| `vault.drift` | A pause, a sunset, `oraclePaused`, a staged multiplier inside a live series, or vault state disagreeing with the AuctionHouse | A guardian pause is expected after any halt (D-050) and clears when a human unpauses. A staged multiplier inside a live series is the D-025 case: review that settlement before unpausing |
| `implementation.watch` CRIT | The stock-token beacon or the USDG implementation changed | D-020. Pause deposits and new auctions immediately; do not unpause until a human has confirmed the new code keeps raw-unit `balanceOf`, no transfer fee, no transfer hooks and unchanged `decimals`. `n/a` on 46630 is correct — the testnet tokens are plain mocks, not proxies |
| `nyse.calendar` | The holiday table is running out | Extend `NYSE_HOLIDAYS` / `NYSE_EARLY_CLOSES` in `src/time/nyse.ts` and bump `CALENDAR_KNOWN_THROUGH` |
| `open.priceAvailable` | `capPrice` is unavailable, so the next `openAuction` would revert `NoReferencePrice` | Check the feed and the pool. This fires *before* the Monday window, which is the point |
| `vault.empty` (INFO) | The vault holds nothing, so no auction can open | Expected on a fresh vault. Never paged |
| reserve floor bound (log) | The contract's `minReserveBpsOfSpot` sat above the model price | Not a fault. If it happens every week for a vault, that curator floor is miscalibrated for the asset and wants a timelocked `setMinReserveBpsOfSpot`. SPEC §8.3 calls the 10/3 bps defaults placeholders "to be tuned against the keeper's implied-vol model"; this is that measurement |

### 11.6 The guardian auto-pause

D-020 asks the keeper to watch the stock-token beacon and the USDG implementation every five minutes and,
on any change, pause deposits and new auctions on every vault with the guardian key. That path is
implemented and ships **off** (`GUARDIAN_AUTOPAUSE=false`): pausing every vault is a real, user-visible
action, and arming it should be a deliberate decision by whoever runs the server. Disarmed, the keeper
still detects the change and pages; a human then pauses with the cold guardian key.

To arm it, set a distinct `GUARDIAN_PRIVATE_KEY` holding `GUARDIAN_ROLE`, and `GUARDIAN_AUTOPAUSE=true`.

### 11.7 A second, settle-only instance

THREAT-MODEL RS-04 asks for a second keeper on a different host whose only job is to settle, so the grace
window is never missed. Run it with `"role": "settle-only"` and **its own key**: `settle`, `halt` and
`resolveHaltedByOracle` are permissionless, so that key needs no role at all and holds nothing. Never
give two instances the same key — they would interleave nonces on every call.

### 11.8 Testing a whole week without waiting a week

```bash
cd keeper && npm run week
```

Forks 46630 into anvil, warms the fork cache, then drives Monday's auction, the clear, Friday's
settlement, the weekend auction, its clear and Sunday's settlement — through the keeper's own scheduler,
jobs, hint builder and pricing. The harness only does what the outside world does: deposit, bond, bid,
publish oracle data, move time. It asserts both series reach `SETTLED`, that the weekday settles on path 1
and the weekend on path 2, and that re-running each tick never repeats a lifecycle action. Takes about
three minutes; the log lands in `keeper/state/week.log`.

`npm run week` drives one vault (`WEEK_SYMBOL`, default NVDA) and never pauses anything. The wider run —
three depositors on two vaults, two bidders, an ITM and an OTM settlement, a queued redeem, a guardian
pause, a timelocked unpause — is `docs/REHEARSAL-1.md`; its driver (`keeper/test/week/rehearsal.ts`) is a
one-off and is not maintained. If it is run again, advance chain time between keeper re-runs: the first run
did not, and Monday's SPY auction was still uncleared when the driver next ticked on Friday (S-1).

Two things the run teaches that are easy to forget when operating for real:

- **The public testnet RPC is not an archive node.** It keeps roughly 9 000 blocks — about 19 minutes at
  the ~8 blocks/s this chain produces. Anvil fetches forked state lazily, so any slot first touched after
  that window has closed fails `metadata is not found`. `scripts/fork-week.sh` warms everything up front
  for exactly that reason, and `anvil_dumpState` does not help: it serialises only anvil's own modified
  accounts, not the forked state it has cached.
- **A bare time warp breaks every oracle at once.** `capPrice` has an 80 h bound, `referencePrice` and
  `weekdayMaxStale` 26 h, `usdgMaxStale` 26 h, and any TWAP anchor needs an observation within 900 s plus
  at least `minObservationsInWindow` inside the window. The harness posts rounds and observations across
  every gap, exactly as `test/DayInTheLife.t.sol:_nextWeek()` does.

### 11.9 The public testnet demo: keeping 46630 alive by itself

On 46630 every external is a mock (§10, SPEC §1.8). Nobody publishes Chainlink rounds there and nobody
swaps in the pools, so a deployment left to itself is unusable within a day: the stock feeds cross
`weekdayMaxStale` (26 h), `referencePrice` reverts `NoReferencePrice` at the next Monday open, and the
Sunday TWAP fails §9.3's minimum-observations rule for want of a single swap. The `testnet-demo` compose
profile runs the normal keeper plus one extra job, `src/jobs/testnetUpkeep.ts`, that plays the market:

| What | Cadence | Value |
|---|---|---|
| stock-feed round, per vault | every 4 h (`MockDeployLib.FEED_PERIOD`) | last answer × exp(σ·z), σ = 40 bps, clamped to ±8 % of an anchor (the answer seen at first run, kept in `state/upkeep-anchor-<SYMBOL>.json`) — well inside the 15 % weekend TWAP bound and the 30 % jump guard |
| USDG/USD round | every 4 h | 1.00 ± 5 bps; the peg band is ±2 % |
| pool observation, per vault | every 10 min | the tick that prices the stock at the feed's latest answer, at the pool's current liquidity, so any Sunday 23:59 window holds ≥ 3 observations with the newest inside 900 s and the TWAP agrees with Friday's round |

Every "is it due" question is answered from chain state (the newest round's `updatedAt`, the newest
observation's timestamp), so a restart never double-posts and a missed tick only delays. The job runs
*after* the lifecycle step of each tick, never before it: a round landing between `planOpen`'s read of
`sRef` and the `openAuction` send would move `reserveBounds().lo` under an already-simulated reserve.

**It cannot run anywhere else.** `TESTNET_UPKEEP=true` (or `testnetUpkeep.enabled` in the config) is
refused by `src/config.ts` on any `CHAIN_ID` but 46630; `buildKeeperAllowTable` only admits `setRound`
and `write` on the mock addresses when the address book's own `chainId` is 46630; and the job's
constructor asserts both again. On 4663 the same addresses are real Chainlink proxies and real pools with
no such functions.

Run it from `keeper/`, naming the service so the plain `keeper` service does not start beside it:

```bash
docker compose --env-file ../.env --profile testnet-demo up -d --build keeper-testnet-demo
docker compose --profile testnet-demo logs -f keeper-testnet-demo
curl -s http://127.0.0.1:8787/status | jq '.overall, [.recentActions[] | select(.action|startswith("upkeep"))][:3]'
```

`KEEPER_PRIVATE_KEY` comes from the repo root `.env` through `--env-file`, as in 11.2. On 46630 it is the
one funded key (D-105), which holds `KEEPER_ROLE`; the mocks have no owner, so it needs nothing else. Keep
it topped up: the job adds roughly 300 transactions a day per vault (288 observations, 6 rounds) plus the
USDG rounds, each a few thousand gas. Both compose services share the `keeper-state` volume on purpose: if
the plain `keeper` is ever started next to the demo, the second one refuses on the single-instance lock
(`another keeper is running`) instead of interleaving nonces with the first. The systemd unit does not
share that volume, so never run it on the same key at the same time.

The first tick after start logs `TESTNET UPKEEP ON` with the cadence, then posts whatever is already
overdue. `recentActions` shows `upkeep:feedRound`, `upkeep:usdgRound` and `upkeep:poolObservation` with
the value written; the `feed.staleness`, `usdg.peg` and `pool.coverage` checks go green within one tick and
stay there. Without a deposit in a vault the keeper still opens nothing (`cannot open this cycle`, reason
`NO_ASSETS`), which is the correct idle state, not a fault: deposit any amount of the mock stock token into
a vault and the next window opens an auction.

**What a market maker sees on Monday 14:00 UTC.** With the demo up and a vault funded:

1. At 14:00:00 UTC, plus at most one tick (30 s), the keeper calls `openAuction` for each vault. It
   never opens before 14:00 even though the contract would accept it from 12:00; the tolerance is for a
   late keeper. If nobody bids, the 14:15 clear skips the series and **no second series is opened that
   day**: the next open is Friday's weekend auction, 600 s after the Friday close (20:10 UTC under EDT,
   21:10 under EST). Each open emits
   `AuctionOpened(vault, seriesId, WEEKDAY, …)` with `sRef` = the feed's latest walk value, the strike
   gridded 800 bps (NVDA) or 300 bps (SPY) above it, `offeredQty` = the vault's whole balance, and a
   reserve from the Black-Scholes floor at realised vol — realised on the walk itself, which is why the
   walk has a non-zero σ. `currentAuction(vault)` returns the new seriesId; `auctions(seriesId).state` is 1.
2. 14:00–14:15 UTC: `bid` is open to any address with an active MM bond (docs/mm-kit/BIDDING-GUIDE.md).
   The public RPC and the explorer show every bid the moment it lands.
3. 14:15:05 UTC: the keeper clears (`clearDelaySeconds` = 5). `AuctionCleared` with the uniform price;
   allocations and refunds are pullable at once; bidders without a fill have their bond released.
4. Friday 20:00 UTC (EDT) or 21:00 UTC (EST): `settle` on path 1 — the round the upkeep job posted at or
   before expiry is the last valid round, inside 26 h. `claimPayout` and `OptionToken.claim` work from
   that block; `releaseLocks` follows in the same tick.
5. Friday expiry + 10 min: the weekend auction opens; Sunday 23:59 UTC it settles on path 2, the 60-min
   TWAP the pool observations kept fresh, with the USDG/USD round inside its band.

If an MM asks why the price moves in 4-hour steps with no news: that is the walk, and it is the point of
the demo, not a bug. The band and the σ are in `config/keeper.46630.json` under `testnetUpkeep`.
