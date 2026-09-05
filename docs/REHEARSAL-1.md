# REHEARSAL-1 — full mainnet rehearsal on an anvil fork of 46630

**Result: every step of the operating procedure works end to end on the audited build (commit e471df6).** One
genuine surprise (the SPY weekday auction was *skipped*, see §S-1), one operational cost of the 48 h unpause
(§S-2), and a short list of RUNBOOK corrections at the end.

What was rehearsed, in order:

| # | Step | Outcome |
|---|---|---|
| 1 | Governance through the TimelockController: grant KEEPER_ROLE and GUARDIAN_ROLE to separate keys, raise `minDelay` to 48 h | executed; every later governance action waited 48 h |
| 2 | Three wallets deposit into NVDA (40 + 30 + 20) and SPY (10 + 8 + 7) under the 25 000 USDG caps | 90 NVDA ($18 000) and 25 SPY ($17 500) in; headroom shown by `maxDeposit` |
| 3 | Two market makers post the 25 000 USDG MM bond | `hasActiveMMBond` true |
| 4–6 | Monday: the keeper opens both weekday auctions, MMs bid, the keeper clears | NVDA cleared at 2.346558 USDG/option (uniform price, 90/90 filled, 211.19 USDG gross); **SPY never cleared — see S-1** |
| 7 | Wednesday: depositor C queues a redeem while NVDA is LIVE | direct `redeem` refused (`WithdrawalsClosed`), `requestRedeem` accepted, shares escrowed |
| 8 | Friday 20:00 UTC: settle NVDA **in the money** (230 vs strike 216, path 1) | `payoutPerOption = 0.0609` tokens; depositor C's queued redeem executed inside `settleSeries` at the post-payout price and claimed (9.39 NVDA for 10 shares); MM1 `claimOptions` → ERC-1155 → `OptionToken.claim` → 3.652 NVDA; MM2 `claimPayout` → 1.826 NVDA; `payoutOwed` back to 0; three depositors `claimPremium` → 84.48 / 63.36 / 42.24 USDG |
| 9 | Friday 20:10: weekend auctions on both vaults, bids, clear | NVDA 50/75 filled at 0.28 USDG, SPY 20/25 at 0.84 USDG |
| 10 | Sunday 23:59: settle both weekend series **out of the money** on the 60-min TWAP (path 2) | NVDA 229.99 vs 241.50, SPY 689.99 vs 696.90; `payoutPerOption = 0` |
| 11 | Fees | the keeper flushed after every clear; treasury +24.215742 USDG (21.119 + 1.408 + 1.689) |
| 12 | Guardian emergency pause (deposits + new auctions, ALL) | `deposit` reverts `DepositsPaused`, `maxDeposit` 0; **redeem of unencumbered tokens and `claimPremium` on both vaults work while paused**; the keeper reports `AUCTIONS_PAUSED` at the next Monday open |
| 13 | Unpause through the timelock: schedule → early execute refused → 48 h warp → execute | deposits and auctions reopen; the Monday window was missed (S-2) |
| 14 | App on port 3211 against the fork | vault list, NVDA and SPY detail pages match the chain (see §App) |


---

# Transcript


Date: 2026-09-05 · Deployment: contracts/deployments/46630.json (commit e471df6) · Driver: keeper/test/week/rehearsal.ts (uncommitted one-off; reuses the week harness and the keeper's own Scheduler)

Every on-chain action is recorded as the equivalent `cast` command with the receipt (transaction hashes, salts and ABI-encoded payloads are abbreviated to `0x12345678…abcd`: the repo's pre-commit hook rejects any 64-hex string as a possible key, and the fork is ephemeral anyway); every read as `cast call` with the decoded value. Time moves with anvil `evm_setNextBlockTimestamp`; every warp is *stepped* so no oracle goes stale (RUNBOOK §11.8). Wallets are anvil's deterministic accounts; the admin EOA and the TimelockController are impersonated (`anvil_impersonateAccount`) — on 46630 the admin is also treasury, and the timelock delay is 0, so step 1 raises it to 48 h first to rehearse the real procedure.

| Role | Address |
|---|---|
| admin EOA / treasury (impersonated) | 0x65A5206f9d92D92783c78C60b878A671EA1D2786 |
| TimelockController | 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C |
| keeper (anvil #0) | 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 |
| depositor A (anvil #1) | 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 |
| depositor B (anvil #4) | 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 |
| depositor C (anvil #5) | 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc |
| market maker 1 (anvil #2) | 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC |
| market maker 2 (anvil #3) | 0x90F79bf6EB2c4f870365E785982E1f101E93b906 |
| guardian (anvil #6) | 0x976EA74026E726554dB657fA54763abd0C3a0aa9 |
| NVDA vault / stock / feed / pool | 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 / 0xc2D152ebE42be2c65d86c50b410231e5271634fb / 0x2d4e84FBaE927EcF2CCc924808E593BA48F1b72F / 0x8e1CFC19D17EC56CB6C6b545596637F60376B3c9 |
| SPY vault / stock / feed / pool | 0x7b242611B7C490BC5F571095ef511d60E89bf914 / 0x3c37fE477079789cA80b0F20A6585d96894f2006 / 0x301dd8371eD858A77474c5506236B8EBA5F5961b / 0x75671ad2E95DB072817DF949A1fD143A8C398769 |
| AuctionHouse / RiskModule / FeeRouter / OptionToken | 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 / 0x23580d6EB623Ad8108512e6ea27ae3852F295740 / 0xCb3FaaD6515DF255Bc080194Eb32dA357B12775b / 0x56009D85b2318A3B3aDbE5764f602C0F26555eA6 |
| USDG (mock) | 0x640c46710A5C075292655e8602EC1D4BA844A930 |

## 0 · Fork

```bash
anvil --fork-url https://rpc.testnet.chain.robinhood.com --port 8545
WEEK_SYMBOL=NVDA node --import tsx test/week/prefetch.ts && WEEK_SYMBOL=SPY node --import tsx test/week/prefetch.ts
```
```text
chainId 46630  block 113715749  time 1788645592 (2026-09-05T21:59:52Z)
prefetched 351 reads for each vault (the public RPC keeps ~19 minutes of state; everything the run touches is warmed first)
```
> `anvil_setBalance` gave every actor 100 ETH for gas (the timelock too: anvil impersonates a contract as happily as an EOA).


## 1 · Governance setup through the timelock (RUNBOOK §3, §8)

> On 46630 the deployer key is admin, guardian, keeper and treasury and `minDelay` is 0 (D-105). To rehearse mainnet procedure the first batch grants KEEPER_ROLE to a separate keeper key and GUARDIAN_ROLE to a separate guardian key, and raises the delay to 172 800 s; from here on every governance action waits 48 h.

```bash
cast send 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" 0xEFE287cE0761813e642B6df5D6A08637E97E9B93,0x23580d6EB623Ad8108512e6ea27ae3852F295740,0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C 0,0,0 0xd1b9e853…0001,0x2b8a1c5a…0001,0x64d62353…a300 0x00000000…0000 0x00000000…0001 0 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # admin EOA schedules: setKeeper, setGuardian, updateDelay(48h)
```
```text
status success  gasUsed 72571  block 113715750  tx 0xec72459c…4623
```
```bash
cast send 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" 0xEFE287cE0761813e642B6df5D6A08637E97E9B93,0x23580d6EB623Ad8108512e6ea27ae3852F295740,0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C 0,0,0 0xd1b9e853…0001,0x2b8a1c5a…0001,0x64d62353…a300 0x00000000…0000 0x00000000…0001 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # admin EOA executes (delay was 0)
```
```text
status success  gasUsed 137558  block 113715751  tx 0x5ae021ee…5548
```
```bash
cast call 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "getMinDelay()(uint256)" 
```
```text
172800 s (48 h)
```
```bash
cast call 0x23580d6EB623Ad8108512e6ea27ae3852F295740 "hasRole(bytes32,address)(bool)" 0x55435dd2…5041 0x976EA74026E726554dB657fA54763abd0C3a0aa9
```
```text
true
```

## 2 · Deposits from three wallets into NVDA and SPY


### NVDA: cap 25000 USDG at $200.0000 → max 125.00 tokens

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "maxDeposit(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
125 NVDA
```
```bash
cast send 0xc2D152ebE42be2c65d86c50b410231e5271634fb "approve(address,uint256)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 80000000000000000000 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A
```
```text
status success  gasUsed 46402  block 113715753  tx 0xda9931f0…0c35
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "deposit(uint256,address)" 40000000000000000000 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A
```
```text
status success  gasUsed 191962  block 113715754  tx 0xa220e54e…551d
```
```bash
cast send 0xc2D152ebE42be2c65d86c50b410231e5271634fb "approve(address,uint256)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 60000000000000000000 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B
```
```text
status success  gasUsed 46402  block 113715756  tx 0xf0854c4d…2fa7
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "deposit(uint256,address)" 30000000000000000000 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B
```
```text
status success  gasUsed 157948  block 113715757  tx 0x06848f4e…a860
```
```bash
cast send 0xc2D152ebE42be2c65d86c50b410231e5271634fb "approve(address,uint256)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 40000000000000000000 --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C
```
```text
status success  gasUsed 46402  block 113715759  tx 0x47c74538…ff2e
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "deposit(uint256,address)" 20000000000000000000 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C
```
```text
status success  gasUsed 157948  block 113715760  tx 0x3830b679…b1f8
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "totalAssets()(uint256)" 
```
```text
90 NVDA
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "maxDeposit(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
35 NVDA of headroom left under the cap
```

### SPY: cap 25000 USDG at $700.0000 → max 35.71 tokens

```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "maxDeposit(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
35.714285714285714285 SPY
```
```bash
cast send 0x3c37fE477079789cA80b0F20A6585d96894f2006 "approve(address,uint256)" 0x7b242611B7C490BC5F571095ef511d60E89bf914 20000000000000000000 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A
```
```text
status success  gasUsed 46402  block 113715762  tx 0xf1760732…6c2c
```
```bash
cast send 0x7b242611B7C490BC5F571095ef511d60E89bf914 "deposit(uint256,address)" 10000000000000000000 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A
```
```text
status success  gasUsed 191950  block 113715763  tx 0x2b69a5dd…65ab
```
```bash
cast send 0x3c37fE477079789cA80b0F20A6585d96894f2006 "approve(address,uint256)" 0x7b242611B7C490BC5F571095ef511d60E89bf914 16000000000000000000 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B
```
```text
status success  gasUsed 46390  block 113715765  tx 0xd7972963…b664
```
```bash
cast send 0x7b242611B7C490BC5F571095ef511d60E89bf914 "deposit(uint256,address)" 8000000000000000000 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B
```
```text
status success  gasUsed 157936  block 113715766  tx 0x65965d26…83ac
```
```bash
cast send 0x3c37fE477079789cA80b0F20A6585d96894f2006 "approve(address,uint256)" 0x7b242611B7C490BC5F571095ef511d60E89bf914 14000000000000000000 --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C
```
```text
status success  gasUsed 46390  block 113715768  tx 0x93adbcd5…d649
```
```bash
cast send 0x7b242611B7C490BC5F571095ef511d60E89bf914 "deposit(uint256,address)" 7000000000000000000 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C
```
```text
status success  gasUsed 157936  block 113715769  tx 0xd5c26f2b…cb67
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "totalAssets()(uint256)" 
```
```text
25 SPY
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "maxDeposit(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
10.714285714285714285 SPY of headroom left under the cap
```
> Mock stock tokens were minted by the issuer (admin) before each approve; on mainnet the depositor already holds them.


## 3 · Two market makers post the 25 000 USDG MM bond (RUNBOOK §11, SPEC §13)

```bash
cast send 0x640c46710A5C075292655e8602EC1D4BA844A930 "approve(address,uint256)" 0x920F79DF191899934a04269B2280B2A1B2391266 10000000000000 --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM 0x3C44…93BC → BondManager
```
```text
status success  gasUsed 46378  block 113715771  tx 0xc5bea5ec…d0ee
```
```bash
cast send 0x640c46710A5C075292655e8602EC1D4BA844A930 "approve(address,uint256)" 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 10000000000000 --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM 0x3C44…93BC → AuctionHouse (bid escrow)
```
```text
status success  gasUsed 46378  block 113715772  tx 0xe8bdacfc…6033
```
```bash
cast send 0x920F79DF191899934a04269B2280B2A1B2391266 "postBond(uint8)" 1 --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM bond, kind MM = 1
```
```text
tx 0xb0893a65…b5bf
```
```bash
cast send 0x640c46710A5C075292655e8602EC1D4BA844A930 "approve(address,uint256)" 0x920F79DF191899934a04269B2280B2A1B2391266 10000000000000 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM 0x90F7…b906 → BondManager
```
```text
status success  gasUsed 46378  block 113715775  tx 0x0ea68b14…ae21
```
```bash
cast send 0x640c46710A5C075292655e8602EC1D4BA844A930 "approve(address,uint256)" 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 10000000000000 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM 0x90F7…b906 → AuctionHouse (bid escrow)
```
```text
status success  gasUsed 46378  block 113715776  tx 0xc9861d69…6412
```
```bash
cast send 0x920F79DF191899934a04269B2280B2A1B2391266 "postBond(uint8)" 1 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM bond, kind MM = 1
```
```text
tx 0x63a3d82c…1a50
```
```bash
cast call 0x920F79DF191899934a04269B2280B2A1B2391266 "hasActiveMMBond(address)(bool)" 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
```
```text
true
```

## 4 · Monday 14:00 UTC — the keeper opens both weekday auctions

```bash
# oracle upkeep to 1788789600 (2026-09-07T14:00:00Z, Mon 14:00:00 UTC (off 396000)) — to Monday 14:00
```
```text
9 steps of 4 h; each posted NVDA/SPY Chainlink rounds; every 4th step a USDG/USD round and a pool observation per vault
equivalent per step: cast send <feed> "setRound(uint80,int256,uint256)" <id> <answer8> <ts> --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```bash
# keeper tick — Monday 14:00 open WEEKDAY  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-07T14:00:30Z)
```
```text
NVDA  state=IDLE    due=open     → sent
SPY   state=IDLE    due=open     → sent
sent 2 tx
  SPY openAuction WEEKDAY sent — strike 72100000000 reserve 913476 (model; sigma 0.1800 fallback, model 913476 vs floor 700000)
  NVDA openAuction WEEKDAY sent — strike 21600000000 reserve 1173279 (model; sigma 0.5500 fallback, model 1173279 vs floor 200000)
```
> re-run 1: nothing further due (idempotent).

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "series(uint256)" 1   # and AuctionHouse.auctions(1)
```
```text
NVDA series 1: state AUCTION  sRef 200.0000  strike 216.0000  offered 90  filled 0
reserve 1.173279 USDG/option  clearing 0 USDG  premiumGross 0 USDG  fee 0 USDG  expiry 2026-09-11T20:00:00Z
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "series(uint256)" 2   # and AuctionHouse.auctions(2)
```
```text
SPY series 2: state AUCTION  sRef 700.0000  strike 721.0000  offered 25  filled 0
reserve 0.913476 USDG/option  clearing 0 USDG  premiumGross 0 USDG  fee 0 USDG  expiry 2026-09-11T20:00:00Z
```

## 5 · Monday 14:05 — two bonded market makers bid

```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "bid(uint256,uint256,uint256)" 1 60000000000000000000 3519837 --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM1 on NVDA: 60 options at 3.519837 USDG each
```
```text
tx 0x39ca24ad…8481
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "bid(uint256,uint256,uint256)" 1 60000000000000000000 2346558 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM2 on NVDA: 60 options at 2.346558 USDG each
```
```text
tx 0xc3ed3523…cfc6
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "bid(uint256,uint256,uint256)" 2 15000000000000000000 2740428 --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM1 on SPY: 15 options at 2.740428 USDG each
```
```text
tx 0xb868de92…b610
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "bid(uint256,uint256,uint256)" 2 15000000000000000000 1826952 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM2 on SPY: 15 options at 1.826952 USDG each
```
```text
tx 0x2fd8c71f…c02a
```
> Offered 90 NVDA against 120 bid: MM1 (higher price) fills 60, MM2 fills the remaining 30 at MM2's price, which is the clearing price (uniform-price auction, SPEC §8.2). SPY: 25 offered against 30 bid.


## 6 · Monday 14:15 — clear (permissionless; the keeper does it)

```bash
# keeper tick — Monday 14:15 clear WEEKDAY  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-07T14:15:27Z)
```
```text
NVDA  state=AUCTION due=clear    → cleared
SPY   state=AUCTION due=clear    → waiting  (auction closes at 1788790530 (Mon 14:15:30 UTC (off 396930)))
sent 1 tx
  NVDA clear cleared
```
> re-run 1 sent 1 tx for a newly-due action:
  NVDA flush sent

> re-run 2: nothing further due (idempotent).

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "series(uint256)" 1   # and AuctionHouse.auctions(1)
```
```text
NVDA series 1: state LIVE  sRef 200.0000  strike 216.0000  offered 90  filled 90
reserve 1.173279 USDG/option  clearing 2.346558 USDG  premiumGross 211.19022 USDG  fee 21.119022 USDG  expiry 2026-09-11T20:00:00Z
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "series(uint256)" 2   # and AuctionHouse.auctions(2)
```
```text
SPY series 2: state AUCTION  sRef 700.0000  strike 721.0000  offered 25  filled 0
reserve 0.913476 USDG/option  clearing 0 USDG  premiumGross 0 USDG  fee 0 USDG  expiry 2026-09-11T20:00:00Z
```
```bash
cast call 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "refundable(address)(uint256)" 0x90F79bf6EB2c4f870365E785982E1f101E93b906
```
```text
MM2 refundable 70.39674 USDG (escrow above the clearing price + unfilled quantity)
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "withdrawRefund(address)" 0x90F79bf6EB2c4f870365E785982E1f101E93b906 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM2 pulls its refund
```
```text
status success  gasUsed 48976  block 113715822  tx 0xea966bc0…810c
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "premiumClaimable(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
NVDA depositor A premium claimable 84.476088 USDG (accrued at clear, claimable any time)
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "premiumClaimable(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
SPY depositor A premium claimable 0 USDG (accrued at clear, claimable any time)
```
```bash
cast call 0xCb3FaaD6515DF255Bc080194Eb32dA357B12775b "pending(address)(uint256)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0
```
```text
FeeRouter.pending(NVDA) 0 USDG — 10 % performance fee booked at clear (already flushed by the keeper on the re-run)
```

## 7 · Wednesday — depositor C queues a withdrawal while NVDA is LIVE

```bash
# oracle upkeep to 1788962400 (2026-09-09T14:00:00Z, Wed 14:00:00 UTC (off 568800)) — to Wednesday 14:00
```
```text
11 steps of 4 h; each posted NVDA/SPY Chainlink rounds; every 4th step a USDG/USD round and a pool observation per vault
equivalent per step: cast send <feed> "setRound(uint80,int256,uint256)" <id> <answer8> <ts> --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "redeem(uint256,address,address)" 10000000000000000000000000 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C tries a direct redeem while LIVE
```
```text
REVERTED: WithdrawalsClosed()   — direct redeem/withdraw only in IDLE (SPEC §4.3); use requestRedeem
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "requestRedeem(uint256,address)" 10000000000000000000000000 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C queues half its shares
```
```text
status success  gasUsed 220294  block 113715864  tx 0x755a5ea1…4e4b
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "escrowedRedeemShares()(uint256)" 
```
```text
10000000000000000000000000 shares escrowed in the vault (24-dec shares)
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "queuedRedeem(uint256)" 0
```
```text
request 0 status QUEUED
```

## 8 · Friday 16:00 ET — settle: NVDA in the money, SPY out of the money (path 1, Chainlink at expiry)

```bash
# oracle upkeep to 1789153200 (2026-09-11T19:00:00Z, Fri 19:00:00 UTC (off 154800)) — to Friday 19:00 UTC
```
```text
13 steps of 4 h; each posted NVDA/SPY Chainlink rounds; every 4th step a USDG/USD round and a pool observation per vault
equivalent per step: cast send <feed> "setRound(uint80,int256,uint256)" <id> <answer8> <ts> --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```bash
cast send 0x2d4e84FBaE927EcF2CCc924808E593BA48F1b72F "setRound(uint80,int256,uint256)" <next> 23000000000 1789155000 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
cast send 0x301dd8371eD858A77474c5506236B8EBA5F5961b "setRound(uint80,int256,uint256)" <next> 69000000000 1789155000 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```text
last rounds before expiry: NVDA 230.0000 (strike 216.0000 → ITM), SPY 690.0000 (strike 721.0000 → OTM)
```
```bash
# keeper tick — Friday 20:00 UTC settle WEEKDAY  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-11T20:00:03Z)
```
```text
NVDA  state=LIVE    due=settle   → settled  (path 1)
SPY   state=AUCTION due=clear    → skipped
sent 2 tx
  SPY clear skipped
  NVDA settle settled — path 1
```
> re-run 1 sent 1 tx for a newly-due action:
  NVDA releaseLocks sent

> re-run 2: nothing further due (idempotent).

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "series(uint256)" 1   # and AuctionHouse.auctions(1)
```
```text
NVDA series 1: state SETTLED  sRef 200.0000  strike 216.0000  offered 90  filled 90
reserve 1.173279 USDG/option  clearing 2.346558 USDG  premiumGross 211.19022 USDG  fee 21.119022 USDG  expiry 2026-09-11T20:00:00Z
settlement path 1  price 230.0000  payoutPerOption 0.060869565217391304 token/option
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "series(uint256)" 2   # and AuctionHouse.auctions(2)
```
```text
SPY series 2: state SKIPPED  sRef 700.0000  strike 721.0000  offered 25  filled 0
reserve 0.913476 USDG/option  clearing 0 USDG  premiumGross 0 USDG  fee 0 USDG  expiry 2026-09-11T20:00:00Z
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "payoutOwed()(uint256)" 
```
```text
5.47826086956521736 NVDA reserved for option holders
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "queuedRedeem(uint256)" 0
```
```text
depositor C's request 0 status EXECUTED — executed inside settleSeries at the post-payout share price
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "withdrawalClaimable(address)(uint256)" 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
```
```text
9.39130434782608696 NVDA claimable by depositor C
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "claimWithdrawal(address)" 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C claims the executed withdrawal
```
```text
status success  gasUsed 45888  block 113715924  tx 0x162a2ed5…972a
```
```bash
cast call 0xc2D152ebE42be2c65d86c50b410231e5271634fb "balanceOf(address)(uint256)" 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
```
```text
29.39130434782608696 NVDA (was 20; +9.39130434782608696, i.e. half of 20 NVDA less this share's part of the ITM payout)
```

### Option holders claim the ITM payout in NVDA tokens

```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "claimOptions(uint256,address)" 1 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM1 pulls its 60 ERC-1155 options
```
```text
status success  gasUsed 140885  block 113715925  tx 0xcc69795b…9732
```
```bash
cast call 0x56009D85b2318A3B3aDbE5764f602C0F26555eA6 "balanceOf(address,uint256)(uint256)" 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 1
```
```text
60 option tokens of series 1
```
```bash
cast send 0x56009D85b2318A3B3aDbE5764f602C0F26555eA6 "claim(uint256,uint256,address)" 1 60000000000000000000 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM1 burns the options and is paid in NVDA
```
```text
status success  gasUsed 97091  block 113715926  tx 0x7931890a…108d
```
```bash
cast call 0xc2D152ebE42be2c65d86c50b410231e5271634fb "balanceOf(address)(uint256)" 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
```
```text
3.65217391304347824 NVDA (+3.65217391304347824 = 60 × payoutPerOption 0.060869565217391304; SPEC §7.1: (S−K)/S per option)
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "claimPayout(uint256,address)" 1 0x90F79bf6EB2c4f870365E785982E1f101E93b906 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM2 never pulled its options: claimPayout mints and claims in one tx (D-038)
```
```text
status success  gasUsed 180145  block 113715927  tx 0xdd9a191a…de6a
```
```bash
cast call 0xc2D152ebE42be2c65d86c50b410231e5271634fb "balanceOf(address)(uint256)" 0x90F79bf6EB2c4f870365E785982E1f101E93b906
```
```text
1.82608695652173912 NVDA (+1.82608695652173912)
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "payoutOwed()(uint256)" 
```
```text
0 NVDA still owed (0 once every holder has claimed)
```
```bash
cast call 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "claimableOptions(uint256,address)(uint256)" 2 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
```
```text
SPY options unclaimed by MM1: 0 — worthless (OTM), payoutPerOption 0
```

### Depositors claim premium in USDG

```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "claimPremium(address)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A claims 84.476088 USDG of NVDA premium
```
```text
status success  gasUsed 96557  block 113715928  tx 0x3a0c87b7…4586
```
```bash
cast call 0x640c46710A5C075292655e8602EC1D4BA844A930 "balanceOf(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
84.476088 USDG (+84.476088 USDG)
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "claimPremium(address)" 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B claims 63.357066 USDG of NVDA premium
```
```text
status success  gasUsed 96557  block 113715929  tx 0x46208ef4…74af
```
```bash
cast call 0x640c46710A5C075292655e8602EC1D4BA844A930 "balanceOf(address)(uint256)" 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
```
```text
63.357066 USDG (+63.357066 USDG)
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "claimPremium(address)" 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C claims 42.238044 USDG of NVDA premium
```
```text
status success  gasUsed 69857  block 113715930  tx 0x8e5c7256…9116
```
```bash
cast call 0x640c46710A5C075292655e8602EC1D4BA844A930 "balanceOf(address)(uint256)" 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
```
```text
42.238044 USDG (+42.238044 USDG)
```
> Depositor C requested a redeem *after* the clear, so it earned the full premium on all its shares; a request filed during the AUCTION window would forfeit that series' premium (D-036).


## 9 · Friday 16:10 ET — weekend auctions open, bid, clear

```bash
# keeper tick — Friday 20:10 UTC open WEEKEND  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-11T20:10:06Z)
```
```text
NVDA  state=IDLE    due=open     → sent
SPY   state=IDLE    due=open     → sent
sent 2 tx
  SPY openAuction WEEKEND sent — strike 69690000000 reserve 211140 (contract-floor; sigma 0.1800 fallback, model 54502 vs floor 207000)
  NVDA openAuction WEEKEND sent — strike 24150000000 reserve 70380 (contract-floor; sigma 0.5500 fallback, model 2224 vs floor 69000)
```
> re-run 1: nothing further due (idempotent).

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "series(uint256)" 3   # and AuctionHouse.auctions(3)
```
```text
NVDA series 3: state AUCTION  sRef 230.0000  strike 241.5000  offered 75.13043478260869568  filled 0
reserve 0.07038 USDG/option  clearing 0 USDG  premiumGross 0 USDG  fee 0 USDG  expiry 2026-09-13T23:59:00Z
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "series(uint256)" 4   # and AuctionHouse.auctions(4)
```
```text
SPY series 4: state AUCTION  sRef 690.0000  strike 696.9000  offered 25  filled 0
reserve 0.21114 USDG/option  clearing 0 USDG  premiumGross 0 USDG  fee 0 USDG  expiry 2026-09-13T23:59:00Z
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "bid(uint256,uint256,uint256)" 3 50000000000000000000 281520 --from 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC   # MM1 on NVDA weekend: 50 options at 0.28152 USDG each
```
```text
tx 0x01d2cf42…b1ac
```
```bash
cast send 0xEFE287cE0761813e642B6df5D6A08637E97E9B93 "bid(uint256,uint256,uint256)" 4 20000000000000000000 844560 --from 0x90F79bf6EB2c4f870365E785982E1f101E93b906   # MM2 on SPY weekend: 20 options at 0.84456 USDG each
```
```text
tx 0x6e37951f…ed0b
```
```bash
# keeper tick — Friday 20:25 UTC clear WEEKEND  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-11T20:25:14Z)
```
```text
NVDA  state=AUCTION due=clear    → cleared
SPY   state=AUCTION due=clear    → cleared
sent 2 tx
  SPY clear cleared
  NVDA clear cleared
```
> re-run 1 sent 2 tx for a newly-due action:
  SPY flush sent
  NVDA flush sent

> re-run 2: nothing further due (idempotent).

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "series(uint256)" 3   # and AuctionHouse.auctions(3)
```
```text
NVDA series 3: state LIVE  sRef 230.0000  strike 241.5000  offered 75.13043478260869568  filled 50
reserve 0.07038 USDG/option  clearing 0.28152 USDG  premiumGross 14.076 USDG  fee 1.4076 USDG  expiry 2026-09-13T23:59:00Z
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "series(uint256)" 4   # and AuctionHouse.auctions(4)
```
```text
SPY series 4: state LIVE  sRef 690.0000  strike 696.9000  offered 25  filled 20
reserve 0.21114 USDG/option  clearing 0.84456 USDG  premiumGross 16.8912 USDG  fee 1.68912 USDG  expiry 2026-09-13T23:59:00Z
```

## 10 · Sunday 23:59 UTC — settle the weekend series on the 60-minute TWAP (path 2)

```bash
# oracle upkeep to 1789329540 (2026-09-13T19:59:00Z, Sun 19:59:00 UTC (off 331140)) — to Sunday 20:00 UTC
```
```text
11 steps of 4 h; each posted NVDA/SPY Chainlink rounds; every 4th step a USDG/USD round and a pool observation per vault
equivalent per step: cast send <feed> "setRound(uint80,int256,uint256)" <id> <answer8> <ts> --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```bash
# five pool observations per vault at expiry −{3600,2400,1200,600,120} s (minObservationsInWindow = 3, MAX_LAST_OBS_AGE = 900)
```
```text
NVDA pool tick for $230.00, SPY pool tick for $690.00
```
```bash
# keeper tick — Sunday 23:59 UTC settle WEEKEND  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-14T00:00:04Z)
```
```text
NVDA  state=LIVE    due=settle   → settled  (path 2)
SPY   state=LIVE    due=settle   → settled  (path 2)
sent 2 tx
  SPY settle settled — path 2
  NVDA settle settled — path 2
```
> re-run 1 sent 2 tx for a newly-due action:
  SPY releaseLocks sent
  NVDA releaseLocks sent

> re-run 2: nothing further due (idempotent).

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "series(uint256)" 3   # and AuctionHouse.auctions(3)
```
```text
NVDA series 3: state SETTLED  sRef 230.0000  strike 241.5000  offered 75.13043478260869568  filled 50
reserve 0.07038 USDG/option  clearing 0.28152 USDG  premiumGross 14.076 USDG  fee 1.4076 USDG  expiry 2026-09-13T23:59:00Z
settlement path 2  price 229.9888  payoutPerOption 0 token/option
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "series(uint256)" 4   # and AuctionHouse.auctions(4)
```
```text
SPY series 4: state SETTLED  sRef 690.0000  strike 696.9000  offered 25  filled 20
reserve 0.21114 USDG/option  clearing 0.84456 USDG  premiumGross 16.8912 USDG  fee 1.68912 USDG  expiry 2026-09-13T23:59:00Z
settlement path 2  price 689.9891  payoutPerOption 0 token/option
```

## 11 · Fees flushed to the treasury (FeeRouter, SPEC §11)

```bash
cast call 0xCb3FaaD6515DF255Bc080194Eb32dA357B12775b "pending(address)(uint256)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0
```
```text
0 — the keeper flushed NVDA on its own re-run ticks (see the "flush" actions above)
```
```bash
cast call 0xCb3FaaD6515DF255Bc080194Eb32dA357B12775b "pending(address)(uint256)" 0x7b242611B7C490BC5F571095ef511d60E89bf914
```
```text
0 — the keeper flushed SPY on its own re-run ticks (see the "flush" actions above)
```
```bash
cast call 0x640c46710A5C075292655e8602EC1D4BA844A930 "balanceOf(address)(uint256)" 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # treasury
```
```text
1000024.215742 USDG (was 1000024.215742 USDG before the last flush)
keeper flush actions this week:
  SPY flush sent
  NVDA flush sent
  NVDA flush sent
```

## 12 · Emergency pause with the guardian key (RUNBOOK §8, SPEC §15)

```bash
cast send 0x23580d6EB623Ad8108512e6ea27ae3852F295740 "pauseDeposits(address)" 0x0000000000000000000000000000000000000000 --from 0x976EA74026E726554dB657fA54763abd0C3a0aa9   # guardian pauses deposits on ALL vaults
```
```text
status success  gasUsed 30989  block 113715998  tx 0x98f7b4cf…d767
```
```bash
cast send 0x23580d6EB623Ad8108512e6ea27ae3852F295740 "pauseNewAuctions(address)" 0x0000000000000000000000000000000000000000 --from 0x976EA74026E726554dB657fA54763abd0C3a0aa9   # guardian pauses new auctions on ALL vaults
```
```text
status success  gasUsed 30990  block 113715999  tx 0xd72ca86b…4855
```
```bash
cast call 0x23580d6EB623Ad8108512e6ea27ae3852F295740 "depositsPaused(address)(bool)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0
```
```text
true
```

### While paused: deposits refused, withdrawals of unencumbered tokens and premium claims still work

```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "deposit(uint256,address)" 1000000000000000000 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A tries to deposit 1 NVDA
```
```text
REVERTED: DepositsPaused()
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "maxDeposit(address)(uint256)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```
```text
0 (0 while paused)
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "convertToAssets(uint256)(uint256)" 30000000000000000000000000
```
```text
depositor B's 30000000000000000000000000 shares are worth 28.17391304347826088 NVDA (vault IDLE, nothing encumbered)
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "redeem(uint256,address,address)" 30000000000000000000000000 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B redeems everything while paused
```
```text
status success  gasUsed 94013  block 113716000  tx 0xf5e7cc00…d292
```
```bash
cast call 0xc2D152ebE42be2c65d86c50b410231e5271634fb "balanceOf(address)(uint256)" 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
```
```text
58.17391304347826088 NVDA (+28.17391304347826088)
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "claimPremium(address)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A claims the weekend premium 6.3342 USDG while paused
```
```text
status success  gasUsed 68046  block 113716001  tx 0x824a2512…5898
```
```bash
cast send 0x7b242611B7C490BC5F571095ef511d60E89bf914 "claimPremium(address)" 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65 --from 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65   # depositor B claims SPY premium 4.864665 USDG while paused
```
```text
status success  gasUsed 81726  block 113716002  tx 0xac7bd8fd…d2cf
```
```bash
cast send 0x7b242611B7C490BC5F571095ef511d60E89bf914 "requestRedeem(uint256,address)" 1000000000000000000000000 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc --from 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc   # depositor C: queue path is for LIVE series; in IDLE use redeem
```
```text
REVERTED: VaultIsIdle()   — the queue is for LIVE/AUCTION/HALTED; in IDLE the direct `redeem` above is the path
```

### Monday 14:00 arrives during the pause: the keeper refuses to open

```bash
# oracle upkeep to 1789999200 (2026-09-21T14:00:00Z, Mon 14:00:00 UTC (off 396000)) — to next Monday 14:00
```
```text
45 steps of 4 h; each posted NVDA/SPY Chainlink rounds; every 4th step a USDG/USD round and a pool observation per vault
equivalent per step: cast send <feed> "setRound(uint80,int256,uint256)" <id> <answer8> <ts> --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```bash
# keeper tick — Monday 14:00 while paused  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-21T14:00:00Z)
```
```text
NVDA  state=IDLE    due=open     → blocked  (AUCTIONS_PAUSED)
SPY   state=IDLE    due=open     → blocked  (AUCTIONS_PAUSED)
sent 0 tx
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "canOpenAuction(uint64)(bool,bytes32)" 1790431200
```
```text
false AUCTIONS_PAUSED
```

## 13 · Unpause through the timelock: schedule, wait 48 h, execute (RUNBOOK §3)

> Payloads: `unpauseDeposits(address(0))` = `0xdbea37b8…0`, `unpauseNewAuctions(address(0))` = `0x07deb697…0`; predecessor `0x0`, salt `0x…02`, delay `172800`.

```bash
cast send 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" 0x23580d6EB623Ad8108512e6ea27ae3852F295740,0x23580d6EB623Ad8108512e6ea27ae3852F295740 0,0 0xdbea37b8…0000,0x07deb697…0000 0x00000000…0000 0x00000000…0002 172800 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # admin EOA schedules unpauseDeposits(ALL) + unpauseNewAuctions(ALL) with the 48 h delay
```
```text
status success  gasUsed 65117  block 113716173  tx 0x2145b675…822b
```
```bash
cast call 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "getTimestamp(bytes32)(uint256)" 0xf1d90895…82c1
```
```text
operation 0xf1d90895…82c1 ready at 1790172001 (2026-09-23T14:00:01Z)
```
```bash
cast send 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" 0x23580d6EB623Ad8108512e6ea27ae3852F295740,0x23580d6EB623Ad8108512e6ea27ae3852F295740 0,0 0xdbea37b8…0000,0x07deb697…0000 0x00000000…0000 0x00000000…0002 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # executing early is refused
```
```text
REVERTED: TimelockUnexpectedOperationState(id, Ready)   — 48 h have not passed
```
> A guardian could also unpause without delay (SPEC §15, D-029); this rehearses the timelock route because that is the one the runbook prescribes after an incident review.

```bash
# oracle upkeep to 1790172061 (2026-09-23T14:01:01Z, Wed 14:01:01 UTC (off 568861)) — the 48 h wait (oracle upkeep continues so nothing is stale afterwards)
```
```text
12 steps of 4 h; each posted NVDA/SPY Chainlink rounds; every 4th step a USDG/USD round and a pool observation per vault
equivalent per step: cast send <feed> "setRound(uint80,int256,uint256)" <id> <answer8> <ts> --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786
```
```bash
cast call 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "isOperationReady(bytes32)(bool)" 0xf1d90895…82c1
```
```text
true
```
```bash
cast send 0x183CD3640c5Cf5886F09117c7cF9B844782e9E8C "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" 0x23580d6EB623Ad8108512e6ea27ae3852F295740,0x23580d6EB623Ad8108512e6ea27ae3852F295740 0,0 0xdbea37b8…0000,0x07deb697…0000 0x00000000…0000 0x00000000…0002 --from 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # admin EOA executes after the delay
```
```text
status success  gasUsed 64294  block 113716221  tx 0xde620a3b…bbca
```
```bash
cast call 0x23580d6EB623Ad8108512e6ea27ae3852F295740 "depositsPaused(address)(bool)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0
```
```text
false
```
```bash
cast call 0x23580d6EB623Ad8108512e6ea27ae3852F295740 "auctionsPaused(address)(bool)" 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0
```
```text
false
```
```bash
cast send 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "deposit(uint256,address)" 5000000000000000000 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --from 0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # depositor A deposits again after the unpause
```
```text
status success  gasUsed 143636  block 113716222  tx 0x47927656…fb95
```
```bash
# keeper tick — Wednesday after the unpause  (KEEPER_CONFIG=config/keeper.46630.json, chain time 2026-09-23T14:01:03Z)
```
```text
NVDA  state=IDLE    due=open     → waiting  (outside every opening window)
SPY   state=IDLE    due=open     → waiting  (outside every opening window)
sent 0 tx
```
> The Monday open window (14:00 ± 2 h) passed during the 48 h wait, so this week's weekday series is skipped; the keeper reports nothing due until Friday's weekend window.


## 14 · Final state

```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "totalAssets()(uint256)" 
```
```text
NVDA totalAssets 51.9565217391304348
```
```bash
cast call 0x7d873a335aD3cf8cc5A7AfEe8fA80b2d042b54E0 "state()(uint8)" 
```
```text
NVDA state IDLE
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "totalAssets()(uint256)" 
```
```text
SPY totalAssets 25
```
```bash
cast call 0x7b242611B7C490BC5F571095ef511d60E89bf914 "state()(uint8)" 
```
```text
SPY state IDLE
```
```bash
cast call 0x640c46710A5C075292655e8602EC1D4BA844A930 "balanceOf(address)(uint256)" 0x65A5206f9d92D92783c78C60b878A671EA1D2786   # treasury
```
```text
1000024.215742 USDG
```

Chain time at the end: 2026-09-23T14:01:03Z. anvil left running on http://127.0.0.1:8545 for the app check (port 3211).


## App check — http://localhost:3211 against the fork (launch.json `overwrite-app-fork`)

Read with the in-app browser after the run, chain time Wed 23 Sept 14:01 UTC.

**/vaults** — both vaults listed. NVDA: "This week's premium 0.12 % · last auction · weekend series" (0.28152 / 230 = 0.122 % ✓), annualised 67.4 %, strike distance +5.0 % (weekend), "48 % of cap · $13.1k of $25.0k cap" (51.96 NVDA × $230 = $11 950 used = 48 %, $13 050 remaining ✓), next auction Mon 28 Sept 14:00 UTC ✓. SPY: 0.12 %, 9.3 % annualised (marked "last auction + estimate" because the weekday series never cleared — correct labelling), "69 % of cap · $7,750" (25 × $690 = $17 250 used ✓). Footer "Read from Robinhood Chain at Wed 23 Sept 14:01 UTC".

**/vaults/NVDA** — reference price $230.00 "Chainlink, updated Wed 23 Sept 14:00 UTC" ✓; capacity "51.96 NVDA deposited of a $25.0k cap" ✓; current series #3 · Weekend · settled, strike $241.50 (+5.0 %), expiry Sun 13 Sept 23:59 UTC, auction window Fri 20:10–20:25 ✓, offered 75.1304 / filled 50 (67 %) ✓, clearing $0.28 (0.12 %), premium to depositors $12.67 (= 14.076 − 1.4076 ✓), settlement $229.99, "Paid out at settlement 0.00 %" ✓. Countdown "Weekday auction opens 4d 23:57:58 · Mon 28 Sept". **Settled series** table: #3 Weekend 13 Sept, cap $241.50, settled $229.99, 0.12 % / $12.67 net, "Expired below the cap — you kept every token and the premium" ✓; #1 Weekday 11 Sept, cap $216.00 (+8.0 %), settled $230.00, 1.17 % / $190.07 net, "Called away above the cap — 6.09 % of each written token paid out" (payoutPerOption 0.0609 ✓). **Premium history**: 2 cleared auctions, $202.74 in total (190.07 + 12.67 ✓), fees $21.12 / $1.41 ✓. No console errors.

**/vaults/SPY** — reference $690.00 ✓; "25 SPY deposited of a $25.0k cap", capacity $7,750 ✓; current series #4 · Weekend · settled, strike $696.90 (+1.0 %), offered 25 / filled 20 (80 %) ✓, clearing $0.84 (0.12 %), premium to depositors $15.20 (= 16.8912 − 1.68912 ✓), settlement $689.99, paid out 0.00 % ✓. Settled-series table: #4 "Expired below the cap" ✓; **#2 Weekday 11 Sept, cap $721.00 (+3.0 %), "No auction cleared — No bid met the floor, so the vault kept its upside and sells it next week."** That explanation is wrong for this series: two bids above the reserve were placed; the series was skipped because `clear` arrived after `clearGrace` (S-1). The app's copy assumes the only skip cause is "no bid" — see S-9. Premium history: 1 cleared auction, $15.20 ✓.

Not checked: the connected-wallet panels (position, claimable premium, deposit/withdraw) — no wallet was connected in the in-app browser; those paths were exercised on chain directly in §7, §8 and §12.


## Surprises

- **S-1 · The SPY weekday auction was skipped, and that is the audit's new `clearGrace` doing its job.** The keeper opened NVDA and SPY in the same tick 30 s apart, so their `auctionClose` differed by 30 s. The rehearsal driver ticked once at NVDA's close + 10 s and then re-ran *at the same chain time*, so SPY was still "waiting (auction closes at 14:15:30)"; the next tick the driver ran was Friday 20:00. By then `auctionClose + clearGrace (1 h)` was long past, `previewClear` said `willSkip`, and the keeper's clear took the skip path: series 2 → SKIPPED, both MM escrows refundable, vault back to IDLE with no series that week. On the real keeper (a tick every 30 s) SPY would have cleared at 14:15:30; in the driver it did not, and the protocol did exactly what D-113 F-2 says it should — a clear that arrives more than an hour late costs the week's premium, never the collateral. Two lessons: (a) the keeper must keep ticking through the whole 15-minute + 1-hour window, and a *single* missed hour on Monday now skips the week (before the audit it would have cleared any time before Friday); (b) the harness should advance time between re-runs. The unfilled SPY escrow (`refundable`) was left unclaimed on purpose — pull-based refunds never expire.
- **S-2 · A 48 h unpause through the timelock costs the next Monday auction.** Pause on Monday 14:00 → schedule unpause → execute Wednesday 14:00 → the open window (14:00 ± 2 h, Monday only) is gone and the keeper reports "waiting (outside every opening window)" until Friday's weekend window. SPEC §15 already says either guardian may unpause without delay; the RUNBOOK should say plainly that the timelock route is for *parameter* changes and the guardian route is the one to use to reopen after a false alarm, otherwise a Monday pause silently costs a week.
- **S-3 · Depositor C's queued redeem paid 9.391 NVDA for 10 shares, not 10.** Correct and worth showing users: the request was executed inside `settleSeries` at the post-payout share price (ITM series, 5.478 NVDA paid out to option holders over 90), i.e. the redeemer bore its share of the assignment. Requests filed after the clear earn the full premium (C claimed 42.24 USDG), requests filed during the 15-minute auction window would not (D-036).
- **S-4 · `payoutOwed` went back to exactly 0** after both holders claimed (60 × 0.060869565217391304 + 30 × 0.060869565217391304 = 5.47826086956521736), so the floor-rounding reserve dust SPEC §9.7 documents did not materialise here — the per-option payout divided evenly. Do not expect that in general.
- **S-5 · The weekend reserve came from the contract floor, not the model.** Both weekend opens logged `contract-floor; … model 2224 vs floor 69000` (NVDA) and `model 54502 vs floor 207000` (SPY): with the fallback σ (0.55 / 0.18) and a 2.16-day weekend series the Black-Scholes price of a 5 % / 1 % OTM call is below `minReserveBpsOfSpot` (3 bps of spot), so the reserve is the floor. Expected per RUNBOOK §11.5's last row, but it means the weekend reserve on a fresh deployment is effectively `minReserveBpsOfSpot`, not a volatility estimate, until the feed has history.
- **S-6 · The vault-list "Capacity" column shows headroom, the % shows usage.** "48 % of cap · $13.1k of $25.0k cap" reads as if $13.1k were used; it is the remaining capacity ($11 950 used). Both numbers are right; the caption is ambiguous. (App, not contracts.)
- **S-9 · The app explains every SKIPPED series as "no bid met the floor".** Series 2 (SPY weekday) was skipped with two valid bids on it, because the clear was late (S-1). The AuctionHouse knows the difference (`previewClear`/`clear` skip for no bids, `remaining == 0`, past expiry, all shares escrowed, or past `clearGrace`); the app should read the bid count (`bids(seriesId).length`) and the timing and say "the auction was not cleared in time — bids were refunded" when bids existed. Same root cause as RUNBOOK item 2.
- **S-7 · Revert reasons in the driver's transcript were not decoded** for four calls (`WithdrawalsClosed`, `DepositsPaused`, `VaultIsIdle`, `TimelockUnexpectedOperationState`); viem's error object carries them but the driver's regex only kept the first line. Annotated by hand above; the real keeper decodes custom errors through `src/chain/errors.ts`.
- **S-8 · One `sendAs` hung on the second attempt** (a MockUSDG mint never mined; anvil showed no upstream error). The week harness has the same pattern; adding an explicit `evm_mine` after 2 s made the third attempt clean. The fork-block budget (~19 min of upstream state) is real: each attempt needed a fresh fork + prefetch.

## What the RUNBOOK got wrong or leaves out

1. **§8 Rotation / incident response says nothing about *reopening*.** It should state: after a guardian pause for a false alarm, **unpause with the guardian key** (no delay, SPEC §15 permits it); reserve the timelock route for changes that need public review. A timelocked unpause scheduled on Monday reopens on Wednesday and skips that week's weekday series (S-2).
2. **§11.3 "Monday 14:15 · clear" implies one attempt.** With `clearGrace = 1 h` (D-113) the clear must land inside `[auctionClose, auctionClose + 1 h)`; the table should say so and §11.5 should get a `clear.missed` row: a clear that is late by an hour is a *skip*, refunds every bid, and the week's premium is gone. Also worth stating that auctions opened in one tick close at slightly different times (30 s apart here), so "clear" is per vault, not one moment.
3. **§3.1 says the Ledger blind-signs `scheduleBatch`.** The rehearsal shows what the operator actually needs at that moment: `hashOperationBatch(...)` to get the operation id, `getTimestamp(id)` to confirm the ready time, and `isOperationReady(id)` before `executeBatch`. Add those three `cast call`s to §3.1–§3.3; the early `executeBatch` reverts `TimelockUnexpectedOperationState`, which the runbook should name so it is not mistaken for a wiring error.
4. **§10 still describes the 2026-09-04 rehearsal deployment.** Redeployed 2026-09-05 (e471df6, 18 new contracts); the paragraph and the "26 contracts" count need updating, and `deployerIsAdmin` now also drives `Deploy._governanceIsUs` (D-113 C-1).
5. **§11.8 documents `npm run week` but not how to drive a second vault or a pause.** The one-off driver `keeper/test/week/rehearsal.ts` (uncommitted) does both; if a second rehearsal is wanted it should become a maintained script with the time-advancing re-run fix from S-1.
6. **Nothing tells the operator that option payouts are pull-based in two ways.** `claimOptions` then `OptionToken.claim`, or `claimPayout` in one transaction (D-038); the market-maker onboarding note (§11.1 area) should list both, and that unclaimed allocations never expire.
7. **`.env` RPC URL has no scheme.** `deploy.sh` prepends `https://`; a hand-run `forge script --rpc-url $ROBINHOOD_TESTNET_RPC_URL` fails with "relative URL without a base". Either store the scheme in `.env.example` or say so in §1.

Mock caveats: prices are mock Chainlink rounds and a mock v3 pool posted by the impersonated issuer, so the ITM/OTM outcomes were chosen, not observed; the rehearsal proves the machinery, not the market.
