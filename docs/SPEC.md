# Overwrite Protocol — Engineering Specification

Version 0.4 · 2026-09-03 · Status: vault layer and auction layer implemented (`contracts/src/CoveredCallVault.sol`, `OptionToken.sol`, `CapController.sol`, `AuctionHouse.sol`, `BondManager.sol`, `FeeRouter.sol`), SettlementOracle / RiskModule / VaultFactory draft. v0.4 records what changed while implementing the auction (D-043…D-048): exact escrow conservation (`premiumGross` = Σ floored payments, §7.3, §8.2, I-3), set-once wiring of BondManager/FeeRouter (§3), the skip paths of `clear` (§8.2 step 8), `auctionOpen = block.timestamp` and the Friday-anchored weekend window (§5), `S_ref == S_cap` until SettlementOracle ships (§7.2), the pro-rata dust carry (§8.2 step 4), read functions (§16.2) and the auction invariants (§17). v0.2 applied the sixteen revisions RS-01…RS-16 from THREAT-MODEL.md, recorded as DECISIONS.md D-018…D-034 (RS-03 is folded into D-019; D-028 records the `KEEPER_ROLE` gate; D-034 records `sunset`). v0.3 also folds in the independent review of the vault layer (D-040…D-042: coverage check vs `totalAssets`, queue-processing hardening, retained `effectiveAt`, `Ownable2Step`) and records what changed while implementing the vault (D-035…D-039): the vault ↔ AuctionHouse / SettlementOracle / OptionToken call graph (§3), explicit `encumbered` and saturating `totalAssets` (§4.1), premium accumulator precision 1e36 (§4.2), redeem escrow and `EXPIRED` deposit requests (§4.3), the split of the Series struct between vault and AuctionHouse (§6), vault-only option minting (§8.2 step 6), new events (§16.1), invariant I-16 (§17).
Chain: Robinhood Chain mainnet (chainId 4663), testnet (chainId 46630)

This document is the source of truth for contract, keeper, indexer and frontend work. Every chain fact carries a source URL or a `cast` read taken on 2026-09-02 (block 52502703, timestamp 1788344808) against the public RPC. Where a fact could not be verified it is listed in §19.

Conventions
- All times are UTC unless a line says ET. Timestamps are `block.timestamp` (sequencer clock, see §1.4).
- `bps` = basis points (1e4 = 100%). `WAD` = 1e18.
- Stock token amounts are raw ERC-20 units (18 decimals). USDG amounts are 6-decimal units. Chainlink answers are 8-decimal USD.
- "Series" = one option issuance (weekday or weekend) of one vault. "Option" = the right on 1e18 raw units (one token) of the vault's stock token.

---

## 1. Verified chain facts

### 1.1 Network

| Fact | Value | Source |
|---|---|---|
| Chain IDs | mainnet 4663, testnet 46630 | https://docs.robinhood.com/chain/connecting |
| Public RPC (rate-limited, not for production) | `https://rpc.mainnet.chain.robinhood.com`, `https://rpc.testnet.chain.robinhood.com` | same |
| Provider RPC | Alchemy `https://robinhood-mainnet.g.alchemy.com/v2/{KEY}` (+ `-testnet`, wss); QuickNode, Blockdaemon, dRPC, Validation Cloud listed | same |
| Explorers | `https://robinhoodchain.blockscout.com` (verify API `/api/`), testnet `https://explorer.testnet.chain.robinhood.com` | https://docs.robinhood.com/chain/deploy-smart-contracts |
| Gas token | ETH; fee = L2 execution + L1 data component | https://docs.robinhood.com/chain/gas-and-fees |
| Stack | Arbitrum Nitro `v3.11.2`, ArbOS 61, data posted to Ethereum (blobs) | https://docs.robinhood.com/chain/run-a-full-node , https://www.dwellir.com/blog/what-is-robinhood-chain |
| Sequencing | first-come-first-served, centralized sequencer; ~100 ms soft confirmations; L1 finality ≈ 13 min after batch posting | https://docs.robinhood.com/chain/ , https://docs.robinhood.com/chain/transaction-finality |
| `block.number` | estimate of the **L1** block number, updates periodically. Use `ArbSys(0x64).arbBlockNumber()` for the L2 block (read 52502867 at the same instant the RPC reported block 52502703) | https://docs.robinhood.com/chain/differences-from-ethereum |
| `block.timestamp` | set by the sequencer clock; bounded to no earlier than 24 h in the past and no later than 1 h in the future, monotone non-decreasing | https://docs.arbitrum.io/build-decentralized-apps/arbitrum-vs-ethereum/block-numbers-and-time |
| `block.prevrandao` | constant; never use for randomness | https://docs.robinhood.com/chain/differences-from-ethereum |
| Chain governance | 8-seat Security Council (Robinhood 2 seats), routine actions 6/8 + 7-day timelock, emergency 7/8 with no delay; 2 whitelisted validators (Offchain Labs, Alchemy) | https://docs.robinhood.com/chain/governance |
| L2BEAT risk | "not even Stage 0"; core contracts upgradable by 7/8 with no delay and no exit window; force-inclusion can be neutralised by ArbOS 61 transaction filtering (`ArbFilteredTransactionsManager` precompile `0x…74`) | https://l2beat.com/scaling/projects/robinhood |
| L1 withdrawal | 7-day challenge period via canonical bridge | https://docs.robinhood.com/chain/bridging |

### 1.2 Stock tokens

| Fact | Value | Source |
|---|---|---|
| Issuer / nature | tokenised debt securities issued by Robinhood Assets (Jersey) Ltd; economic exposure only; prohibited for US persons and restricted in CA, UK, CH and others | https://docs.robinhood.com/chain/stock-tokens |
| Standard | ERC-20, 18 decimals, freely transferable; ERC-8056 Scaled UI Amount extension | https://docs.robinhood.com/chain/building-with-stock-tokens , https://eips.ethereum.org/EIPS/eip-8056 |
| Corporate actions | handled by `uiMultiplier()` (18 dec, 1e18 = 1.0; shares per token). Raw balances never change. `newUIMultiplier()` / `effectiveAt()` expose a pending change. Events `UIMultiplierUpdated(old,new,effectiveAt)`, `TransferWithScaledUI(from,to,raw,ui)` | same |
| Oracle pause flag | `oraclePaused()` on the token; advisory, not enforced on-chain; true while a corporate action is being processed | https://docs.robinhood.com/chain/oracles-and-price-feeds |
| Minting | only Authorised Participants (KYB) subscribe from the issuer | https://docs.robinhood.com/chain/stock-tokens |
| Proxy pattern (cast) | every stock token is an ERC-1967 **beacon proxy**; beacon `0xe10b6f6b275de231345c20d14ab812db62151b00`, implementation `0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2` (23 231 bytes). One upgrade changes all tokens | `cast storage <token> 0xa3f0ad74…3d50` |
| Issuer powers in the implementation bytecode (cast selector scan) | `pause()`, `unpause()`, `pauseOracle()`, `unpauseOracle()`, `isBlocked(address)`, `burn(address,uint256)`, `mint(address,uint256)`, `permit(...)`, `balanceOfUI`, `totalSupplyUI`, `newUIMultiplier`, `effectiveAt` | `cast code 0xb35490d6…` |
| Third-party analysis | inherits `IStock, AccessControlled, OraclePausable, ERC20ScaledUIUpgradeable`; 13 roles; per-token pause + oracle pause; compliance manager at precompile `0x…74`, screening address `0xebDc18A1F5C42fC25552eA233fAcf4054DF224b7` (no code at that address per cast, i.e. an EOA or role holder) | https://beosin.com/resources/robinhood-chain-stock-token-practice-code-analysis-on-token-contract-and-blockchain-protocol |
| Contracts may hold stock tokens | Uniswap v3 NVDA/USDG pool holds ≈ 15 124 NVDA; Morpho holds ≈ 3.8 NVDA | `cast call NVDA balanceOf(pool)` |
| Registry / metadata API | `GET https://api.robinhood.com/rhj/assets` (151 active assets, per-chain deployments, `currentMultiplier`, `pendingMultiplier`), `/prices/{symbol}` (raw underlying bid/ask, **not** multiplier-adjusted, `isTradingHalt`), `/corporate-actions`; public, 60 req/s | https://docs.robinhood.com/chain/stock-token-apis |

Stock token addresses (mainnet 4663) — the v1 allowlist is exactly this table, hardcoded in the deploy script (founder decision, 2026-09-02):

| Symbol | Token | `uiMultiplier` on 2026-09-02 | Source |
|---|---|---|---|
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | 1.000000000000000000 | assets API + cast |
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | 1.000566080061092436 | prices API + cast |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | — | assets API; `symbol()` + beacon slot verified by cast |
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | — | https://www.quicknode.com/guides/robinhood/read-stock-tokens-data-onchain ; `symbol()` + beacon slot verified by cast |
| MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` | 1.0 | assets API; `symbol()` verified by cast |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | 1.0 | assets API; `symbol()` verified by cast |
| GOOGL | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` | 1.0 | assets API; `symbol()` verified by cast |
| META | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` | 1.0 | assets API; `symbol()` verified by cast |
| QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` | — | https://sqd.dev/learn/robinhood-tokenized-stocks/ ; `symbol()` + beacon slot verified by cast |

Asset class per vault (drives strike defaults, §7.2): `SINGLE_NAME` = NVDA, AAPL, TSLA, MSFT, AMZN, GOOGL, META; `ETF` = SPY, QQQ.

NVDA on-chain reads: `decimals()=18`, `totalSupply()=totalSupplyUI()=64 278.967 e18`, `oraclePaused()=false`, `paused()=false`, `newUIMultiplier()=1e18`, `effectiveAt()=0`.

AAPL on-chain reads (cast 2026-09-02, D-042): `uiMultiplier() = newUIMultiplier() = 1.000566080061092436`, **`effectiveAt() = 1786720366`** (2026-08-14 UTC, in the past). A token that has had a corporate action keeps the last `effectiveAt` after the change took effect; `effectiveAt != 0` therefore does **not** mean "a change is pending". Contracts must test `effectiveAt > now` before treating it as staged.

### 1.3 Oracles (Chainlink)

| Fact | Value | Source |
|---|---|---|
| Provider | Chainlink is the only on-chain price provider; one `AggregatorV3Interface` feed per stock token | https://docs.robinhood.com/chain/oracles-and-price-feeds |
| Price semantics | feed returns the price of **one token** = underlying share price × `uiMultiplier`. Do not apply the multiplier again | same ; https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood |
| Schedule | `us_equities_24/5`: 18:00 ET Sunday to 17:00 ET Friday; no updates on weekends or US equity holidays; "the feed may hold the last published price"; "no heartbeats during off-hours" | https://docs.chain.link/data-feeds/selecting-data-feeds ; https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood |
| Parameters (all stock feeds) | decimals 8, heartbeat 86 400 s, deviation threshold 0.5 %, category `custom` | https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json |
| Corporate actions | Robinhood pauses the feed (`oraclePaused`), stages `newUIMultiplier` with `effectiveAt`, unpauses when price and multiplier are consistent; Chainlink provides no calendar | https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood |
| Sequencer uptime feed | docs say to check one; **no address is published** for Robinhood Chain in Chainlink's list or the feed JSON | https://docs.chain.link/data-feeds/l2-sequencer-feeds |
| Data Streams verifier | `0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7` (not used in v1) | https://docs.robinhood.com/chain/data-streams |

Feed proxies (mainnet 4663), from the reference JSON; every proxy's `description()` confirmed by cast on 2026-09-02:

| Feed (`description()` on-chain) | Proxy | Aggregator (cast) |
|---|---|---|
| "RHNVDA / USD" | `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` | `0xC9d16E4f2569b9E3ea0468fD85844953713DC2a2` |
| "Robinhood SPY / USD" | `0x319724394D3A0e3669269846abE664Cd621f9f6A` | `0x78BCB218fA04B9b3a278eBc865Ed320BF8DEFBAc` |
| "Robinhood AAPL / USD" | `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0` | — |
| "RHTSLA / USD" | `0x4A1166a659A55625345e9515b32adECea5547C38` | — |
| "RHMSFT / USD" | `0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E` | — |
| "Robinhood AMZN / USD" | `0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C` | — |
| "Robinhood GOOGL / USD" | `0xF6f373a037c30F0e5010d854385cA89185AE638b` | — |
| "Robinhood META / USD" | `0x7C38C00C30BEe9378381E7B6135d7283356D71b1` | — |
| "Robinhood QQQ / USD" | `0x80901d846d5D7B030F26B480776EE3b29374C2ae` | — |
| "USDG / USD" | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` | answer 0.99975827 on 2026-09-02 |
| "ETH / USD" | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | — |

Naming is inconsistent across feeds ("RH…" vs "Robinhood …"); contracts must key on the address, never on `description()`.

Measured update cadence (cast `getRoundData`, aggregator round ids):

| Feed | Rounds since launch (≈63 days) | Weekday gaps observed | Last round before Fri 2026-08-28 20:00 UTC | Last round before Sun 2026-08-30 23:59 UTC |
|---|---|---|---|---|
| NVDA | 954 | 4.4 h, 7.6 h, 8.1 h (rounds 936→937, 933→934, 940→941) | round 930 at 19:56 UTC (4 min old) | round 930 (≈ 52 h old); next round 931 at Mon 00:00:54 UTC |
| SPY | 116 | 24.0 h heartbeat gaps are typical (113→114 = 86 401 s) | round 112 at 16:18 UTC (3.7 h old) | round 112 (≈ 56 h old); next round 113 at Mon 00:00:33 UTC |

Consequence: during open hours a stock feed is always within 0.5 % of the live price, but its `updatedAt` can be many hours old. Age alone does not mean the feed is broken; age beyond the heartbeat does. Weekend expiries (Sun 23:59 UTC) never have a Chainlink answer younger than ~50 h. This drives §9.

Round id encoding on the proxy: `roundId = (phaseId << 64) | aggregatorRoundId` (NVDA latest `18446744073709552570` = phase 1, aggregator round 954).

### 1.4 Quote asset: USDG

| Fact | Value | Source |
|---|---|---|
| Address (mainnet) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | https://docs.robinhood.com/chain/contracts ; https://docs.paxos.com/guides/stablecoin/usdg/mainnet |
| `decimals()` | **6** | cast |
| `name()/symbol()` | "Global Dollar" / "USDG" | cast |
| Proxy | ERC-1967, implementation `0x68184c449e1a8f34fa18d289737129fd27b66f8f`, `owner()` = `0xcFA0388f5ddf905FdC08c45c716C15Dc10A14C6F` | cast |
| Admin surface | `paused()` (false) and `isFrozen(address)` exist (Paxos pattern) — USDG balances can be frozen by the issuer | cast |
| Bridging | LayerZero OFT / Stargate | https://docs.robinhood.com/chain/bridging |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | https://docs.robinhood.com/chain/contracts |

### 1.5 Uniswap (TWAP source)

Source: https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments and https://developers.uniswap.org/docs/protocols/v4/deployments ; pools verified by cast.

| Contract | Address |
|---|---|
| UniswapV3Factory | `0x1f7d7550b1b028f7571e69a784071f0205fd2efa` |
| QuoterV2 | `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7` |
| SwapRouter02 | `0xcaf681a66d020601342297493863e78c959e5cb2` |
| NonfungiblePositionManager | `0x73991a25c818bf1f1128deaab1492d45638de0d3` |
| TickLens | `0x7dfd4f31be6814d2906bde155c3e1b146eac1468` |
| UniversalRouter | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| v4 StateView / Quoter / PositionManager | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` / `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` / `0x58daec3116aae6d93017baaea7749052e8a04fa7` |

| Pool (v3) | Address | token0 / token1 | fee | Notes (cast 2026-09-02) |
|---|---|---|---|---|
| NVDA/USDG | `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` | USDG / NVDA | 500 (0.05 %) | `observationCardinality` 6000, `observe([1800,0])` succeeds, tick 222534, ≈ $6.1 M TVL, ≈ $42 M 24 h volume (https://scopl.live/pools/robinhood/0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3) |
| NVDA/USDG | `0xB944cec30Bd4175855215D767ADC81F39e5f7E2B` | USDG / NVDA | 3000 | — |
| SPY/USDG | `0xa7Bb1AC63BBaB0C44316E6c8C455213441689167` | — | 500 | exists (factory `getPool`) |
| SPY/USDG | `0xA43b424Bc609495AED4BCD88d654934b510B0aD9` | — | 3000 | exists |
| QQQ/USDG | `0xD60A5d14dB690B7Afad71F76B108071D7175597d` | — | 500 | exists (factory `getPool`) |

Liquidity sanity for the §9.3 rule on the NVDA/USDG 0.05 % pool (cast 2026-09-02): `liquidity` 9.5037e18, `sqrtPriceX96` 5.3815e33 → `sqrtP` ≈ 67 924; max USDG that moves price < 1 % ≈ `L × (√1.01 − 1) / sqrtP` ≈ 698 000 USDG, above the 250 000 USDG requirement.

Pools for AAPL/TSLA/MSFT/AMZN/GOOGL/META must be looked up with `factory.getPool(token, USDG, 500)` at deploy time; a vault cannot be created without a non-zero 0.05 % pool (§9.3).

### 1.6 Morpho Blue (idle-USDG parking, not used in v1 logic)

Source: https://docs.morpho.org/get-started/resources/addresses/ ; code presence verified by cast.

| Contract | Address |
|---|---|
| Morpho | `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010` |
| AdaptiveCurveIRM | `0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1` |
| ChainlinkOracleV2Factory | `0xB7c16F6F8cF531447Bf27Ca7220f981E79C9cdF2` |

### 1.7 Misc

| Contract | Address | Source |
|---|---|---|
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` (mainnet and testnet, cast) | QuickNode guide |
| Arbitrum L2 Multicall | `0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1` | https://docs.robinhood.com/chain/protocol-contracts |
| ArbSys precompile | `0x0000000000000000000000000000000000000064` | https://docs.robinhood.com/chain/differences-from-ethereum |

### 1.8 Testnet (46630) — what exists

cast on `rpc.testnet.chain.robinhood.com` (chainId 46630, block 111668627): code **absent** at the mainnet addresses of USDG, NVDA, the NVDA feed, the Uniswap v3 factory and Morpho; code **present** for Uniswap v4 PoolManager and Multicall3. No testnet stock tokens, USDG or Chainlink stock feeds were found in any source. Faucets: Chainlink faucet (`https://faucets.chain.link/robinhood-testnet`, drips 25 LINK, page verified), QuickNode faucet (Robinhood listed), `faucet.testnet.chain.robinhood.com` (referenced by third parties; returned 403 to my fetch).

Testnet plan (founder decision, D-014): deploy four mocks — `MockStockToken` (ERC-20, 18 dec, ERC-8056 `uiMultiplier/newUIMultiplier/effectiveAt/balanceOfUI/totalSupplyUI`, `oraclePaused`, `pause`, owner-settable), `MockUSDG` (6 dec, mintable), `MockAggregatorV3` (8 dec, owner-settable `answer` and `updatedAt` per round, phase-encoded round ids), and `MockV3PoolObserve` (implements `slot0`, `liquidity`, `token0/token1`, `observe(uint32[])` with settable tick cumulatives). The real integrations (feeds, pool, USDG, stock tokens) are exercised in Foundry mainnet-fork tests (`--fork-url` against an archive-capable provider RPC) which are the primary test path; testnet is for keeper and frontend end-to-end runs only.

### 1.9 NYSE calendar facts used by the schedule

Regular session 09:30–16:00 ET. 2026 holidays falling on a Friday: Apr 3 (Good Friday), Jun 19, Jul 3 (observed), Dec 25. Early close 13:00 ET on Fri Nov 27 2026. 2027: Jan 1, Mar 26, Jun 18, Dec 24 are Fridays. Source: https://www.nyse.com/markets/hours-calendars

---

## 2. Actors

| Actor | Role | Trust |
|---|---|---|
| Depositor | deposits stock tokens into a vault, receives ERC-4626 shares, earns USDG premium, bears the capped upside | untrusted |
| Curator | posts the curator bond, creates a vault for one stock token, sets vault parameters within protocol bounds, optionally prefunds WRITE for fee mode | semi-trusted; bonded; parameters bounded and timelocked |
| Market maker (MM) | posts the MM bond, signs the off-chain non-US-person attestation, bids USDG in auctions, receives option tokens, claims settlement in stock tokens | untrusted on-chain; bids fully escrowed |
| Keeper | off-chain bot holding `KEEPER_ROLE`; the only caller of `openAuction` (D-028). Clears auctions, submits settlement with round/TWAP hints, processes queues (all of those are permissionless). Cannot choose prices: every number it supplies is bounded or verified on-chain | untrusted for safety, trusted for liveness only |
| Guardian | two keys hold `GUARDIAN_ROLE`: a hot key on the keeper server and an off-server key held by the founder (D-029); can only pause new auctions and new deposits, and unpause | limited |
| Admin | one hardware-wallet EOA that is sole proposer and executor of a 48 h `TimelockController`; no multisig (founder decision, DECISIONS.md D-003) | privileged, delayed, public |
| Deployer | deploys, wires roles, renounces everything | one-shot |
| Issuer (Robinhood) | external: can pause tokens, pause the oracle, block addresses, burn any balance, upgrade all tokens via the beacon (§1.2). Accepted, disclosed risk | external, not controllable |

---

## 3. Contract map

```
TimelockController (48h)  ── owner of everything below
 ├─ VaultFactory            creates CoveredCallVault + Series storage per stock token (allowlist hardcoded)
 ├─ CoveredCallVault[i]     ERC-4626 (asset = stock token); accounting, windows, queues, premium accumulator, sunset flag (§15)
 ├─ AuctionHouse            bids, escrow, clearing; pull-based refunds and option allocation (§8.2, D-023/D-024) — implemented v0.4
 ├─ OptionToken             ERC-1155, id = seriesId; freely transferable (D-012); minted when the winning bidder pulls its allocation, burned to claim
 ├─ SettlementOracle        Chainlink + Uniswap v3 TWAP policy (§9); pure view + settle / halt / resolve entries
 ├─ RiskModule              pause state, halt registry, guardian role (two holders)
 ├─ FeeRouter               performance fee in USDG or WRITE — implemented v0.4 (USDG mode; WRITE gated until launch)
 ├─ BondManager             curator and MM bonds (USDG now, WRITE later) — implemented v0.4 (USDG; migration post-token)
 ├─ CapController           fixed caps now, k × safety-module value later
 └─ SafetyModule            (post-token) staked WRITE, cooldown, slashing
Keeper (off-chain, viem)    calls openAuction / clear / settle / processQueues
```

Libraries: OpenZeppelin 5.1 (`ERC4626`, `ERC1155`, `TimelockController`, `AccessControl`, `ReentrancyGuard`, `SafeERC20`), Chainlink `AggregatorV3Interface`, Uniswap v3 `TickMath` / `FullMath` / `OracleLibrary`-equivalent (re-implemented under solc 0.8.26 without assembly beyond the audited library). No upgradeable proxies in v1; a v2 is a new deployment plus migration via `sunset` (§15, D-034). Every cross-contract reference is `immutable`, with three recorded exceptions: `CapController.priceSource` and `AuctionHouse.priceSource` are settable by the timelock until SettlementOracle ships (D-039, D-047), and `BondManager.auctionHouse` / `FeeRouter.auctionHouse` are set exactly once after deployment because the AuctionHouse holds both as immutables (D-044).

Auction call graph (implemented, v0.4). The AuctionHouse holds every bid escrow plus fees booked but not yet flushed, and nothing else; it never touches `OptionToken` except through `claim` inside `claimPayout`. It serves exactly one `OptionToken` (immutable): series ids come from that token's counter, so `registerVault` rejects a vault on any other token (D-049). `registerVault` also asserts `vault.usdg`, `bondManager.auctionHouse` and `feeRouter.auctionHouse`.

```
Keeper (KEEPER_ROLE) ──▶ auction.openAuction(vault, kind, expiry, strikeDistanceBps, reservePrice)   §5 schedule, §7.2 strike from S_ref, §8.3 reserve bounds, then vault.openSeries
MM (bonded)          ──▶ auction.bid(seriesId, qty, price)                  escrow pulled; first bid → bondManager.lock(bidder, seriesId)
anyone               ──▶ auction.clear(seriesId)                            fills, refundable[], claimableOptions[]; fee → FeeRouter.collect; vault.mintSeries pulls premiumNet;
                                                                            unlock unfilled bidders; or skip → vault.skipSeries, all escrow refundable, all locks released
bidder               ──▶ auction.withdrawRefund(to)                         pull (D-023)
bidder               ──▶ auction.claimOptions(seriesId, to)                 vault.mintOptions → OptionToken.mint (D-024, D-038)
bidder               ──▶ auction.claimPayout(seriesId, to)                  unminted allocation: mintOptions to the AuctionHouse, then OptionToken.claim(id, qty, to) in one tx
anyone               ──▶ auction.releaseLocks(seriesId)                     once vault.series(id).state ∈ {SETTLED, RESOLVED}: bondManager.unlock for every bidder
anyone               ──▶ feeRouter.flush(vault)                             pulls the pending fee from the AuctionHouse to the treasury (D-049)
MM                   ──▶ bondManager.postBond / requestWithdraw / cancelWithdraw / withdrawBond
Timelock (owner)     ──▶ auction.registerVault (calls feeRouter.initVault), setKeeper, setMinStrikeDistanceBps, setMinReserveBpsOfSpot, setOpenTolerance,
                         setMaxBidsPerBidder, setMinBidQty, setPriceSource; bondManager.slashBond, setRequiredAmount, setTreasury; feeRouter.setFeeBps, setTreasury
```

Vault call graph (implemented, v0.3). The vault is the only contract that holds stock tokens and the only minter/burner of option tokens (D-038). Every caller below is an `immutable` address fixed in the vault constructor.

```
AuctionHouse ──▶ vault.openSeries(kind, strike, expiry) → (seriesId, offeredQty)   IDLE → AUCTION; runs queued deposits first
             ──▶ vault.skipSeries(seriesId)                                        AUCTION → IDLE (no valid bid)
             ──▶ vault.mintSeries(seriesId, filledQty, premiumNet)                 AUCTION → LIVE; encumbers filledQty, pulls USDG premium; mints nothing
             ──▶ vault.mintOptions(seriesId, bidder, qty)                          pull step of claimOptions; Σ qty ≤ filledQty; vault → OptionToken.mint
SettlementOracle ──▶ vault.settleSeries(seriesId, price8, path)                    LIVE/HALTED → IDLE; bookkeeping only, no ERC-20 transfer; runs queues
                 ──▶ vault.haltSeries(seriesId, reason)                            LIVE → HALTED
OptionToken.claim(seriesId, qty, to) ──▶ burn ──▶ vault.payOptionClaim(seriesId, to, qty)   transfers qty × payoutPerOption / 1e18 stock tokens
RiskModule       ◀── vault reads depositsPaused(vault) / auctionsPaused(vault) (views)
CapController    ◀── vault reads remainingDepositAssets(vault, totalAssets) (view) ── reads IPriceSource.capPrice(vault)
Timelock (owner) ──▶ vault.setSunset(), vault.setMaxQueueOps(); OptionToken.registerVault(underlying, vault); CapController setters
```

The vault performs none of the §5 schedule checks, §7.2 strike derivation, §8 bid logic or §9 oracle policy; it trusts `auctionHouse` and `settlement` for those and enforces only its own accounting (coverage, windows, state machine, D-026 multiplier check, pauses, sunset).

---

## 4. Vault accounting (CoveredCallVault)

### 4.1 Assets and shares
- `asset()` = stock token. Shares are ERC-20 with the OZ `_decimalsOffset() = 6` virtual-share inflation guard.
- `totalAssets() = asset.balanceOf(vault) − payoutOwed − withdrawalClaimableTotal − queuedDepositTokens`, **saturating at 0** (only reachable if the issuer burns vault tokens, §2; views must never revert).
  - `payoutOwed`: stock tokens owed to option holders of settled series not yet claimed.
  - `withdrawalClaimableTotal`: stock tokens set aside for executed queued withdrawals (per-account `withdrawalClaimable[a]`).
  - `queuedDepositTokens`: tokens transferred in by queued depositors that are not yet the vault's (includes `EXPIRED` requests until cancelled, §4.3).
- `encumbered` is tracked explicitly: `filledQty` of the LIVE or HALTED series, 0 in IDLE and AUCTION. `pendingRedeemAssets() = convertToAssets(escrowedRedeemShares)`. `freeAssets() = totalAssets() − encumbered − pendingRedeemAssets()`, saturating (informational). `mintSeries` requires `filledQty ≤ offeredQty` and `filledQty ≤ totalAssets()` (I-1 re-check at clear, D-040; the second bound only bites after an issuer burn between open and clear). Redeem requests filed during the AUCTION window do not shrink what may be filled (D-036, D-040).
- `maxDeposit/maxMint` = 0 outside IDLE, when paused by guardian, when sunset, when the cap is reached or when no cap price is available (§12); `deposit/mint` revert with typed reasons (`VaultNotIdle`, `DepositsPaused`, `VaultSunsetted`, `CapPriceUnavailable`) before the ERC-4626 max check. `maxWithdraw/maxRedeem` = 0 outside IDLE regardless of any pause; users queue instead (§4.3).
- `previewDeposit/previewRedeem` use `totalAssets()` above; they are exact inside windows because nothing is encumbered then.
- Share `decimals() = 24` (`_decimalsOffset() = 6`, D-035). All state-changing entry points are `nonReentrant` (stock tokens are upgradable beacons, THREAT-MODEL T-11.4).

### 4.2 Premium accumulator (USDG, outside NAV)
Premium is never converted into stock tokens in v1 (founder decision, D-004).
- State: `accPremiumPerShare` (USDG × **1e36** / share; 1e18 would truncate up to 1 USDG per token-worth of 24-decimal shares, D-035), `premiumDebt[account]`, `premiumClaimable[account]`.
- On `mintSeries` (the clear) for a series of this vault: `accPremiumPerShare += premiumNet × 1e36 / (totalSupply() − balanceOf(vault))` where `premiumNet = premiumGross − fee` and `balanceOf(vault)` is the shares escrowed by queued redeems (D-036, §4.3). Reverts `NoSharesForPremium` if the denominator is 0 (only possible when every share is escrowed and only rounding dust is free).
- `_update(from, to, value)` (share transfer/mint/burn hook) settles both parties, skipping `address(0)` and the vault itself: `premiumClaimable[a] += balance[a] × accPremiumPerShare / 1e36 − premiumDebt[a]; premiumDebt[a] = newBalance[a] × accPremiumPerShare / 1e36` (all products via `mulDiv`).
- `claimPremium(address to) → uint256 usdg` transfers `premiumClaimable[msg.sender]`. Always callable, including while paused or halted.
- Shares that existed at clearing earn the premium; shares minted later do not. Because deposits are impossible between auction open and settlement (§5), this equals "premium goes to whoever was in the vault when the calls were sold".

### 4.3 Deposit and withdrawal windows and queues
- Direct `deposit/mint/withdraw/redeem` are allowed only when `vault.state == IDLE` (between a settlement and the next `openAuction`).
- Queues (`requestDeposit` is allowed in **any** state, D-032):
  - `requestDeposit(assets, receiver)`: allowed in any vault state, including IDLE (reverts only when sunset or deposits are paused). Transfers tokens in, records `(requester, receiver, assets)` in the deposit queue, increments `queuedDepositTokens`. Executed by anyone via `processDeposits(n)` **whenever the vault is IDLE** (the share price is constant inside IDLE, invariant I-8, so a request made in IDLE executes at the current price; a request made during AUCTION/LIVE/HALTED executes at the post-settlement price of the next IDLE). Cancellable by the requester while `QUEUED` or `EXPIRED`. Processing walks the FIFO and **every visited entry counts against `n`**, cancelled ones included, so a flood of request+cancel pairs can never make `settle`/`openAuction` run out of gas (D-041, T-18); leftover garbage is skipped by permissionless `processDeposits`/`processRedeems` calls. A request larger than the remaining cap headroom is marked **`EXPIRED`** (tokens refundable via `cancelDeposit`) and processing continues, so one oversized request never blocks the queue (D-037); processing stops without expiring anything when the headroom is exactly 0 (cap full), when no cap price is available **or the cap controller reverts** (the read is `try/catch`-wrapped so settlement never depends on an oracle, D-041), when deposits are paused or the vault is sunset. `maxQueueOpsPerOpen/Settle` default 50, bound `[1, 100]`; the 100/100 case is gas-measured at 9.71 M (asserted < 20 M, chain limit 32 M) in `test_T07_settleGasAtMaxQueueOps`.
  - `requestRedeem(shares, receiver)`: allowed outside IDLE (in IDLE use `redeem`). **Escrows the shares in the vault contract** (`balanceOf(vault) == escrowedRedeemShares`, D-036), which makes them non-transferable; escrowed shares earn no premium and are excluded from the premium denominator (§4.2). A request filed during the 15-minute AUCTION window is still inside `offeredQty` and therefore bears the series outcome without earning its premium; cancel before the clear to avoid that. Executed via `processRedeems(n)` in the next IDLE: shares burned at the post-settlement rate, tokens moved to `withdrawalClaimable[receiver]`, then `claimWithdrawal(to)`. Cancellable while queued.
- Queue processing is part of the settlement transaction up to `maxQueueOpsPerSettle` (default 50) and continues permissionlessly afterwards. `openAuction` first executes up to `maxQueueOpsPerOpen` (default 50) queued deposits and then opens **regardless of any remaining queue** (D-032, closes THREAT-MODEL T-18); tokens still queued at open are not in `totalAssets()`, are not in `offeredQty`, and execute at the next IDLE. Redeem requests still queued at open are excluded from `offeredQty` (§5) and stay unencumbered, so they can be executed at the next settlement regardless of the option outcome.
- Queue execution is bookkeeping only: executing a queued deposit mints shares against tokens already in the vault; executing a queued redeem moves an amount from `totalAssets` into `withdrawalClaimable`. **`settle` performs no ERC-20 transfers** (THREAT-MODEL T-11): the only stock-token transfers out of a vault are `withdraw/redeem` in IDLE, `claimWithdrawal` and `OptionToken.claim`.
- If the vault is paused by the guardian or a series is halted, queued redeems remain executable once every open series of the vault is settled or resolved (§15).

### 4.4 State machine (per vault)
```
IDLE ──openAuction──▶ AUCTION ──clear (≥1 valid bid)──▶ LIVE ──settle──▶ IDLE
  ▲                     │ clear (no valid bid) → IDLE                │ settle fails all paths → HALTED ──resolveHalted (timelock)──▶ IDLE
  └─────────────────────┘                                            
```
A vault has at most one live series at a time (weekday and weekend series never overlap, §5). The vault enforces the path/state pairing (D-041): from LIVE `settle` accepts `settlementPath ∈ {1,2,3}`; from HALTED only `{4,5}` (`resolveHalted`, `resolveHaltedByOracle`); anything else reverts `InvalidPath`. Vault shares can reach the vault address only through `requestRedeem` escrow; any other transfer/mint/deposit to the vault reverts `CannotTransferToVault` (D-041).

---

## 5. Weekly lifecycle

All times UTC. The keeper supplies `expiry` and `auctionOpen` timestamps; the contract validates them against a per-vault `Schedule` struct set by the curator and bounded by protocol constants. Reference: NYSE close 16:00 ET = 20:00 UTC while US Eastern Daylight Time applies and 21:00 UTC under Eastern Standard Time; the keeper computes the correct offset off-chain and the contract checks the result falls in `[Friday 19:30, Friday 21:30] UTC`.

| Step | When | What |
|---|---|---|
| (a) Weekday auction opens | Monday 14:00:00, duration 900 s (14:00–14:15). Contract check: caller has `KEEPER_ROLE` (D-028); `auctionOpen = block.timestamp` (D-046) and `|auctionOpen mod 604800 − Monday 14:00| ≤ openTolerance` (default 7 200 s to survive a late Sunday settlement, §9.4; bound ≤ 4 h); `expiry` falls in `[Friday 19:30, Friday 21:30]` of the following epoch week; vault state IDLE and not sunset (§15); `token.oraclePaused() == false`; no staged multiplier change inside the series: `!(token.effectiveAt() > now && effectiveAt ≤ expiry)` (D-026, D-042: a past `effectiveAt` is retained by the token and does not block); `strikeDistanceBps ≥ max(protocol bound, curator floor)` (D-027) | `openAuction(vaultId, SeriesKind.WEEKDAY, expiry, strikeDistanceBps, reservePriceUSDG)`; contract executes up to `maxQueueOpsPerOpen` queued deposits (§4.3), reads `S_ref` (§7.2), computes the strike, (the D-031 oracle-parameter snapshot is taken by SettlementOracle, keyed by `auctionOpen`, D-047), and sets `offeredQty = totalAssets() − pendingRedeemAssets` where `pendingRedeemAssets = convertToAssets(Σ queued redeem shares)` (100 % of the unencumbered balance net of queued withdrawals, founder decision D-009). Neither queue needs to be empty at open |
| (b) Clearing | at or after `auctionClose` | `clear(seriesId)` (§8). Option allocations and refunds recorded for pull (§8.2), premium credited (§4.2), fee credited (§11). If no bid is ≥ reserve, series is `SKIPPED`, vault returns to IDLE |
| (c) Weekday settlement | `expiry` = Friday 16:00 ET (20:00 or 21:00 UTC). Settlement callable from `expiry` | `settle(seriesId, hint)` (§9.2). Queues processed |
| (d) Weekend auction | opens at `weekdayExpiry + 600 s`, duration 900 s. Requires the weekday series settled (or skipped). Contract check (D-046, D-049): `auctionOpen mod 604800 ∈ [Friday 19:40, Friday 21:40 + min(openTolerance, 2 h)]`, `expiry == Sunday 23:59:00 UTC` of the same epoch week, and `auctionOpen ≥ lastWeekdayExpiry + 600` when the vault's last weekday series expired this week. A Saturday or Sunday open is impossible (THREAT-MODEL T-13/T-19) | `openAuction(vaultId, SeriesKind.WEEKEND, expiry = Sunday 23:59:00 UTC, …)` |
| (e) Weekend settlement | from Sunday 23:59:00 UTC | `settle(seriesId, hint)` (§9.3). Queues processed |
| Windows | IDLE periods: Sunday settlement → Monday 14:00 (~14 h); Friday settlement → weekend auction (10 min); any week in which an auction is skipped | direct deposits/withdrawals; queues otherwise (§4.3) |

Fixed-timestamp rule (founder decision): expiry timestamps do not move for NYSE holidays or early closes. On a Friday holiday the settlement price is the Chainlink round last published before `expiry` (the feed holds Thursday's last 24/5 price); on an early-close day the 24/5 feed still updates in the post-market session until 17:00 ET, so the 16:00 ET price is a post-market price. Both are documented on the frontend.

Skipped week: if the weekday auction cannot open within `openTolerance` of Monday 14:00 (e.g. the weekend series is unsettled until the Monday 15:00 deadline of §9.3, or a staged multiplier change falls inside the week), the keeper calls nothing; the vault stays IDLE (windows open) and the next event is the Friday weekend auction, which is allowed to open standalone at Friday `expiry + 600 s` when there is no live weekday series.

---

## 6. Series data

```solidity
enum SeriesKind { WEEKDAY, WEEKEND }
enum SeriesState { NONE, AUCTION, SKIPPED, LIVE, SETTLED, HALTED, RESOLVED }
struct Series {
  uint64  vaultId;
  SeriesKind kind;
  SeriesState state;
  uint64  auctionOpen;      // seconds
  uint64  auctionClose;     // auctionOpen + 900
  uint64  expiry;
  uint128 strike;           // USD, 8 decimals (feed units), PER_TOKEN convention (§10)
  uint128 sRef;             // reference spot used for the strike, 8 dec
  uint128 offeredQty;       // raw token units (1e18 = one option)
  uint128 filledQty;
  uint128 clearingPrice;    // USDG (6 dec) per option
  uint128 reservePrice;     // USDG per option
  uint128 settlementPrice;  // USD 8 dec, 0 until settled
  uint8   settlementPath;   // 1 = Chainlink at/before expiry, 2 = TWAP, 3 = Chainlink first-after-expiry, 4 = resolved by timelock, 5 = resolved permissionlessly after haltedTimeout
  uint128 payoutPerOption;  // raw token units per option (≤ 1e18)
  uint256 multiplierAtOpen; // uiMultiplier() snapshot; enters the jump guard only (§9.1, D-025)
  OracleParams params;      // snapshot of the vault's oracle parameters at openAuction (D-031); immutable for the life of the series
}
```
Storage split (v0.4). The vault stores the accounting subset as `VaultSeries {kind, state, settlementPath, expiry, strike, offeredQty, filledQty, mintedQty, claimedQty, settlementPrice, payoutPerOption, multiplierAtOpen}` keyed by `seriesId`; `OptionToken` stores `SeriesInfo {vault, underlying, kind, settled, expiry, strike, settlementPrice, payoutPerOption, multiplierAtCreation}` per ERC-1155 id (id == seriesId, allocated by `OptionToken.create` from an incrementing counter starting at 1); the AuctionHouse stores `Auction {vault, kind, state (NONE/OPEN/CLEARED/SKIPPED), auctionOpen, auctionClose, expiry, sRef, strike, offeredQty, reservePrice, clearingPrice, filledQty, premiumGross, fee}` plus the bid array `Bid {bidder, qty, price, escrow}` (per-bid fills are emitted in `BidFilled`, not stored). The `OracleParams` snapshot (`params`) will live in SettlementOracle, keyed by `auctions(seriesId).auctionOpen` (D-047). `SeriesState.RESOLVED` is set by the vault when `settlementPath ∈ {4, 5}`.
```
struct OracleParams {       // copied from the vault's timelocked configuration at openAuction
  uint32  weekdayMaxStale;          // s, §9.2
  uint32  twapGrace;                // s, §9.3
  uint16  weekendTwapBoundBps;      // §9.3
  uint16  weekdayTwapBoundBps;      // §9.2 (300)
  uint128 swapNotionalUSDG;         // §9.3
  uint16  impactBps;                // §9.3
  uint8   minObservationsInWindow;  // §9.5, D-019
  uint16  jumpBps;                  // §9.1, D-025 (3000)
  address sequencerFeed;            // §9.1
  uint32  sequencerGrace;           // §9.1
  uint16  usdgBandLowBps;           // §9.5
  uint16  usdgBandHighBps;
  uint32  usdgMaxStale;
}
```
A parameter change executed by the timelock applies only to series opened after execution. Because every vault is IDLE for at least the Sunday→Monday window between any two series, depositors always have a withdrawal window between seeing a queued parameter change and the first series it governs (THREAT-MODEL T-14).

---

## 7. Option economics

### 7.1 Instrument
European call on one stock token (1e18 raw units) per option, physically collateralised: the vault never sells more options than `totalAssets()` (invariant I-1). Cash-settled at expiry **in the stock token** at the settlement price `S`:

```
payoutPerOption = S > K ? (S − K) × 1e18 / S : 0          // raw token units, < 1e18 always
payoutTotal     = filledQty × payoutPerOption / 1e18
```
Rounding: `payoutPerOption` rounds down (favours the vault); `payoutTotal` rounds down.

### 7.2 Strike
```
S_ref  = reference spot at openAuction (8 dec), see below
grid   = S_ref × 25 / 1e4                                  // 0.25 % of S_ref, 8 dec (founder decision D-009)
K_raw  = S_ref × (1e4 + strikeDistanceBps) / 1e4
K      = ceilDiv(K_raw, grid) × grid                       // round UP to the grid (further OTM)
```
- The grid is relative, so strikes land on multiples of 0.25 % of the reference spot, not on fixed dollar levels. Rounding up can add at most one grid step (0.25 %) to the requested distance.
- `strikeDistanceBps` is supplied by the keeper and must lie within protocol bounds per series kind: **WEEKDAY 300–1500 bps, WEEKEND 100–1000 bps** (founder decision). Keeper defaults per asset class: `SINGLE_NAME` 800 / 500 bps, `ETF` 200 / 100 bps (weekday / weekend). The defaults are keeper configuration, not contract state. The contract enforces the protocol bounds **and a per-vault curator floor** `minStrikeDistanceBps[kind]` (D-027, closes THREAT-MODEL T-13/T-19): the floor defaults to the protocol lower bound and the curator may raise it, within the protocol bounds, via the timelock. A keeper can therefore never sell closer to the money than the curator allows.
- `openAuction` reverts (vault: `CannotOpen("MULTIPLIER_CHANGE")`) if `token.effectiveAt() > now && token.effectiveAt() ≤ expiry` (D-026, D-042, closes T-10): a staged corporate action inside the series skips that series. A past `effectiveAt` (retained by ERC-8056 tokens after the change, §1.2 AAPL) never blocks.
- `openAuction` is callable only by `KEEPER_ROLE` (D-028). Everything else in the lifecycle is permissionless.
- `S_ref` is read on-chain, never keeper-supplied:
  1. Chainlink `latestRoundData()` if `answer > 0`, `updatedAt ≥ now − 26 h`, `oraclePaused() == false`; else
  2. 30-minute TWAP (§9.5) if `|TWAP / lastChainlinkAnswer − 1| ≤ 15 %` and the last Chainlink answer is ≤ 80 h old; else
  3. revert `NoReferencePrice` (auction cannot open this cycle).
  Until SettlementOracle ships, the AuctionHouse reads `S_ref` through the same `IPriceSource.capPrice(vault)` as the CapController (`S_ref == S_cap`, settable by the timelock, D-047); a zero or unavailable price reverts `NoReferencePrice`, a price below 400 (8 dec) reverts `GridZero`.
- `multiplierAtOpen` is stored for indexers only; it does not enter any formula (§10).

### 7.3 Premium
Paid in USDG at clearing by winning bidders (from escrow) at the uniform clearing price. Each filled bid pays `payment_i = floor(filledQty_i × clearingPrice / 1e18)` (6-dec USDG) and `premiumGross = Σ payment_i` (D-043; at most `#filled bids − 1` units below the product `filledQty × clearingPrice / 1e18`, the difference stays with the bidders as refund). Fee per §11. Net premium credited per §4.2.

---

## 8. Auction (AuctionHouse)

Open-bid, sealed nothing: bids are public on-chain the moment they are placed.

### 8.1 Eligibility and bid placement
- `bid(seriesId, qty, priceUSDG)` requires: auction OPEN, `now < auctionClose`, `BondManager.hasActiveMMBond(msg.sender)`, `qty ≥ minBidQty` (default 1e17 = 0.1 option, timelocked), `priceUSDG ≥ reservePrice`, bids per auction `< MAX_BIDS` (64, constant: the §8.2 gas bound is measured against it), bids per bidder per auction ≤ `maxBidsPerBidder` (default 8, timelocked, ≤ 64).
- Escrow: `qty × priceUSDG / 1e18` USDG (floored) transferred in with `safeTransferFrom` at bid time; a bid whose escrow floors to 0 reverts `ZeroEscrow`. A bid that cannot fund its escrow reverts and is never stored; "bid then fail to pay" is impossible by construction. `openAuction` also requires `offeredQty ≥ minBidQty` (`OfferTooSmall`) so a dust vault never runs an auction nobody can bid in.
- Bond lock (D-030, closes T-07.6): the first bid of a bidder in a series calls `BondManager.lock(bidder, seriesId)`; the lock is released at `clear` if the bidder received no fill, otherwise when the series reaches SETTLED or RESOLVED. Locks are counted per bidder and are independent of option-token balances, so transferring option tokens away does not free the bond.
- No cancellation; no amendment (a new bid is a new escrow). Bids below reserve revert rather than being stored.
- A bidder's total `qty` across bids may exceed `offeredQty`; only the cleared portion is filled.

### 8.2 Clearing
`clear(seriesId)` callable by anyone at `now ≥ auctionClose`; returns `(clearingPrice, filledQty, premiumGross, fee)`.
1. Load all bids (≤ 64). Insertion-sort an index array by `price` descending, ties by `bidId` ascending (earlier first). `remaining = min(offeredQty, vault.totalAssets())` (an issuer burn between open and clear lowers the fill instead of reverting `mintSeries`, D-045).
2. Walk the sorted list, filling `min(bid.qty, remaining)` until `remaining == 0`.
3. `clearingPrice` = price of the last bid that received any fill. If only one bid exists, it clears at its own price (one valid bid ≥ reserve is enough, founder decision).
4. Marginal price tie: if several bids share the clearing price and the remaining quantity is smaller than their total, fill them pro-rata by qty (floor); the rounding dust goes to the earliest `bidId` of the group up to its remaining headroom, then to the next in `bidId` order, and so on (D-048: `Σ headroom ≥ dust`, so `Σ fills == remaining` exactly and no bid is over-filled).
5. Every filled bidder pays `payment = floor(filledQty × clearingPrice / 1e18)`; `premiumGross = Σ payments` (D-043). **Refunds are pull-based (D-023, closes T-07.3 and T-12.4):** `clear` credits `refundable[bidder] += escrow − payment` (unfilled bids: the whole escrow) and emits `RefundCredited` and `BidFilled(seriesId, bidder, bidId, filledQty, refund)`; bidders call `withdrawRefund(to)` at any time. `clear` performs **no outbound USDG transfer to a bidder** and can therefore not be reverted by a frozen bidder address. Residual: a *paused* USDG reverts the fee transfer and the vault's premium pull, so `clear` waits for the unpause (`test_T12_clearWaitsForUsdgUnpause`).
6. **Option allocation is pull-based (D-024, closes T-07.4 and T-16):** `clear` records `claimableOptions[seriesId][bidder] += filledQty` and emits `OptionsAllocated`; the bidder calls `claimOptions(seriesId, to)` which calls `vault.mintOptions(seriesId, to, qty)`; only the vault mints (D-038) and it bounds cumulative mints by `filledQty`. No ERC-1155 receiver callback runs inside `clear`. An unclaimed allocation is still an option: `AuctionHouse.claimPayout(seriesId, to)` mints it to the AuctionHouse and calls `OptionToken.claim` in one transaction (D-038, §9.7 step 4), so a bidder that never pulls its tokens still receives its payout. Option tokens are standard, freely transferable ERC-1155 (founder decision D-012); whoever holds them at claim time receives the payout. Unfilled offered quantity is simply never allocated (the "burned" quantity in the product description); `offeredQty − filledQty` tokens stay unencumbered.
7. `fee = floor(premiumGross × feeBps / 1e4)` (with `feeBps` snapshotted at open, D-049) is booked in `FeeRouter` with `collect`; the USDG stays in the AuctionHouse until the permissionless `FeeRouter.flush` pulls it to the treasury (§11, D-049), so nothing fee-side can revert `clear`; `premiumNet = premiumGross − fee` is approved and pulled by `vault.mintSeries` (§4.2). Series → LIVE. Coverage: `filledQty ≤ totalAssets()` re-checked by the vault (I-1). Bond locks of bidders without any fill released (§8.1); locks of filled bidders are released by the permissionless `releaseLocks(seriesId)` once the vault reports the series SETTLED or RESOLVED.
8. Skip path (D-045), taken when there is no bid, when `remaining == 0`, when `now ≥ expiry` (keeper down for the whole series), or when the premium would be non-zero but every share is escrowed for redeem (the vault would revert `NoSharesForPremium`): series → SKIPPED, vault → IDLE, `AuctionSkipped` emitted, all bond locks released, all escrow credited to `refundable`. The vault therefore never stays in AUCTION once `clear` is callable. `previewClear` reports `willSkip`.

Gas bound: 64 bids × insertion sort ≈ 2 k comparisons + 64 storage credits (no transfers); must stay < 6 M gas. Measured 2026-09-03 with 64 distinct bidders and a marginal pro-rata group: **4.09 M** (`test_T07_clearGasUnder6M`); the skip path with 64 bids: **2.04 M** (`test_T07_skipGasUnder6M`).

### 8.3 Reserve price
Keeper-supplied per auction, not verifiable on-chain. Bound: `reservePrice ≥ S_ref × minReserveBpsOfSpot[kind] / 1e4` and `≤ S_ref` (a call premium above spot is nonsense). `minReserveBpsOfSpot` is per vault and per series kind, set by the curator via the timelock within the protocol range `[1, 500]`; **protocol defaults are 10 bps (WEEKDAY) and 3 bps (WEEKEND)**, never 0 (D-027, closes T-13.1/T-19). The defaults are placeholders to be tuned against the keeper's implied-vol model before mainnet; the point is that a rogue or careless keeper cannot sell calls for nothing. The keeper derives the reserve off-chain from an implied-vol model; the spec only bounds it.

---

## 9. Settlement oracle policy (SettlementOracle)

Founder decisions of 2026-09-02 (DECISIONS.md D-001). Two series kinds, two policies. Never settle on a stale price; halt instead.

### 9.1 Common definitions
- All parameters named in this section are read from `series.params`, the snapshot taken at `openAuction` (§6, D-031), never from live vault configuration.
- `feed` = the vault's Chainlink proxy; `pool` = the vault's 0.05 % Uniswap v3 stock/USDG pool (stored at vault creation, immutable).
- `refRound` = the last valid Chainlink round with `updatedAt ≤ expiry`, **any age** (D-021, closes T-08.2). It is the reference for every TWAP sanity bound (§9.2 fallback, §9.3) and for the resolution band (§9.6). It is deterministic: it does not depend on when `settle` is called. The keeper supplies it as a hint; the contract verifies it with `next(refRound).updatedAt > expiry` (or none). If no valid round exists (feed dead since before expiry) `refRound` is undefined and the bounds that need it fail, i.e. the TWAP paths are unavailable and `sRef` is the resolution reference.
- **Jump guard (D-025, closes T-02.1, T-10.2, T-14.2).** Every candidate settlement price `S` on every path (1, 2, 3) must satisfy `|S / sRef − 1| ≤ jumpBps` (per vault, default **3 000 bps = 30 %**, timelocked within `[1 000, 5 000]`, snapshotted at open), where `sRef` is the reference spot stored at `openAuction` (§7.2). Exception, *a multiplier change explains it*: if `token.uiMultiplier()` at settle time `m_now ≠ multiplierAtOpen` and `token.oraclePaused() == false`, the guard instead accepts `S` when `|S × multiplierAtOpen / m_now / sRef − 1| ≤ jumpBps`. Note for implementers and auditors: under ERC-8056 the feed prices one raw token as share price × multiplier, so a correctly sequenced corporate action does **not** move `S` and passes the plain check; the exception only admits a price that moved by the multiplier ratio, which is exactly the feed/multiplier mis-sequencing of THREAT-MODEL T-10.2. Because D-026 refuses to open a series across a staged change, the exception can only apply to a change staged after open; the keeper alerts on `UIMultiplierUpdated` inside a live series and the guardian pauses new auctions until the settlement has been reviewed. A price rejected by the guard → `JumpGuardTripped(seriesId, path, S)`; the path is treated as failed; if all paths fail → HALTED with `reason = JUMP_GUARD` (§9.6).
- `validRound(r)`: `getRoundData(r)` returns `answer > 0`, `updatedAt > 0`, `answeredInRound ≥ r` semantics ignored (deprecated), and `oraclePaused() == false` on the token at call time.
- Sequencer hook: `if (sequencerFeed != address(0))` require `answer == 0` and `now − startedAt ≥ sequencerGrace (3600 s)` per https://docs.chain.link/data-feeds/l2-sequencer-feeds . **Disabled in v1 (`sequencerFeed = 0`)** because no address is published for this chain (founder decision D-005); the storage slot and check stay so it can be enabled by timelock.
- Phase-aware neighbour lookup: for proxy round `r = (p << 64) | a`, `next(r)` is `(p << 64) | (a+1)` if it exists, else `((p+1) << 64) | 1` if that exists, else none. `prev(r)` is `(p << 64) | (a−1)` if `a > 1`, else the last round of phase `p−1` supplied by the keeper in the hint and verified to have `next == r`.

### 9.2 WEEKDAY series (expiry Friday 16:00 ET)
Primary — Chainlink round at or before expiry. Keeper hint `roundId r`. Accept iff:
1. `validRound(r)` and `r.updatedAt ≤ expiry`;
2. `next(r)` is none, or `next(r).updatedAt > expiry` (so `r` is the last round before expiry);
3. `expiry − r.updatedAt ≤ weekdayMaxStale` — **default 26 h** = heartbeat 86 400 s + 7 200 s (configurable per vault by timelock, protocol bound `[1 h, 30 h]`);
4. sequencer hook passes;
5. jump guard passes (§9.1).
Then `S = r.answer`, `settlementPath = 1`.

Fallback — TWAP, only if (1)–(3) cannot be satisfied by any round: 30-minute TWAP anchored at expiry (§9.5, `window = 1800`, USD-converted), accepted iff `|twapUSD / refRound.answer − 1| ≤ weekdayTwapBoundBps` (300), the pool checks of §9.3 (liquidity and observations) pass, the USDG/USD read is fresh and inside the band, and the jump guard passes. `settlementPath = 2`.

Else → `HALTED` (§9.6).

### 9.3 WEEKEND series (expiry Sunday 23:59:00 UTC)
A weekend series never settles on a Chainlink answer older than 2 h (founder decision). Measured last-round ages at Sunday 23:59 UTC are ~52–56 h (§1.3), so Chainlink-at-expiry is not an available path.

Primary — 60-minute Uniswap v3 TWAP anchored at expiry (§9.5, `window = 3600`), accepted iff:
1. pool checks pass: `observe` succeeds for the anchored window (observation cardinality covers it); **time-weighted** in-range liquidity over the window is deep enough that a **250 000 USDG swap would move the price by less than 1 %** (founder decision D-010, revised by D-018 to use the window average instead of spot liquidity, closes T-03.3). `L_avg` is the harmonic-mean liquidity over the window from the same `observe` call (§9.5); `sqrtP` is `TickMath.getSqrtRatioAtTick(twapTick)`. Require
   - USDG = token0 (NVDA/USDG case): `L_avg × (√1.01 − 1) ≥ 250 000e6 × sqrtP_X96 / 2^96`
   - USDG = token1: same inequality (for a v3 swap the token1 amount is `L × ΔsqrtP` and the token0 amount is `L × Δ(1/sqrtP)`; both reduce to `L × (√1.01 − 1) / sqrtP ≥ Δ` for a 1 % price move in the direction that raises the stock price)
   with `√1.01 − 1` encoded as `4 987 562 / 1e9`; `swapNotionalUSDG` (250 000e6) and `impactBps` (100) are timelocked parameters snapshotted at open; pool is the vault's immutable 0.05 % pool. Spot `pool.liquidity()` is not used: an LP that pulls liquidity for the window and re-adds it before the call no longer passes;
   and **trading activity inside the window** (D-019, closes T-03.4 and T-05.4): at least `minObservationsInWindow` (default **3**, timelocked within `[1, 16]`) pool observations have `blockTimestamp` inside `[expiry − window, expiry]`, and the most recent observation at or before `expiry` is no older than `expiry − 900`. Checked by walking `pool.observations(i)` backwards from `slot0.observationIndex` (bounded to `minObservationsInWindow + 1` initialized entries, wrapping at cardinality). A quiet pool or a sequencer outage across the window leaves no observations in it and the TWAP is rejected instead of settling on an extrapolated tick;
2. sanity bound `|twapUSD / refRound.answer − 1| ≤ weekendTwapBoundBps` where `refRound` is the last valid Chainlink round at or before expiry (§9.1, D-021; normally Friday's last 24/5 round) and `twapUSD` is the USD-converted TWAP of §9.5. **Global default 1 500 bps (15 %), overridable per vault by timelock within `[300, 1500]`** (founder decision D-017). The reference no longer changes when Monday's first round lands inside the grace window, so path-2 validity does not depend on call timing;
3. the settle call happens at `now ≤ expiry + twapGrace` (**1 800 s**, founder decision) so the anchored window is still inside the observation buffer;
4. the USDG/USD feed read is fresh (≤ 26 h) and inside the 0.98–1.02 band (§9.5). Stale or out of band → TWAP invalid, continue to the fallback below (D-015);
5. jump guard passes (§9.1).
Then `S = twapUSD`, `settlementPath = 2`.

Fallback — first fresh Chainlink round after expiry. Keeper hint `roundId r`. Accept iff:
1. `validRound(r)` and `r.updatedAt > expiry`;
2. `prev(r).updatedAt ≤ expiry` (so `r` is the first round after expiry), or `r` is aggregator round 1 of a new phase;
3. `r.updatedAt ≤ expiry + 54 060 s` (= Monday 15:00:00 UTC);
4. sequencer hook passes;
5. jump guard passes (§9.1).
Then `S = r.answer`, `settlementPath = 3`. The 24/5 feed reopens 18:00 ET Sunday (22:00 or 23:00 UTC), and the first post-weekend round arrived at 00:00:33–00:00:54 UTC Monday on 2026-08-31 for both SPY and NVDA, so this path normally resolves within an hour of expiry.

Else (no TWAP inside grace and no fresh round by Monday 15:00 UTC) → `HALTED`.

Manipulation exposure of the TWAP path, stated so the parameters can be tuned: with strike distance `d` and a pumped TWAP `S' = S(1+m)` the extra payout is `((1+m) − (1+d)) / (1+m)` of collateral for `m > d`; at the bound `m = 15 %` and `d = 5 %` that is ≈ 8.7 % of the option notional. Mitigations: 60-minute window, the 250 000 USDG / 1 % time-weighted liquidity check, the minimum-observations rule, the ±15 % bound, the jump guard, and the curator may tighten `weekendTwapBoundBps` per vault (protocol range `[300, 1500]`). The winning bidder is the only party who profits from a pump; MM bonds are locked for the life of the series (§8.1, §13) and slashable by timelock for demonstrated manipulation. Cap rule (THREAT-MODEL T-03): before any cap increase, re-measure the pool and keep `Σ caps of vaults on the pool × (bound − d_min) / (1 + bound)` well below the realised cost of holding a `bound`-sized move for one hour.

### 9.4 Interaction with the Monday auction
If the weekend series settles before Monday 14:00 UTC (normal case) the weekday auction opens on time. If it settles between 14:00 and 16:00 UTC the auction may open late (`openTolerance`, §5). If it halts, no weekday auction; see §5 skipped week.

### 9.5 TWAP computation
```
(int56[] memory tc, uint160[] memory spl) = pool.observe([secondsAgoStart, secondsAgoEnd]);
  secondsAgoEnd   = now − expiry            // anchor the window at expiry, not at the call
  secondsAgoStart = secondsAgoEnd + window
tick  = (tc[1] − tc[0]) / int56(window)     // round toward negative infinity when negative (Uniswap OracleLibrary convention)
sqrtP = TickMath.getSqrtRatioAtTick(tick)
L_avg = (uint256(window) << 128) / (spl[1] − spl[0])   // harmonic-mean in-range liquidity over the window
                                            // (secondsPerLiquidityCumulativeX128 delta; Uniswap OracleLibrary.consult convention), D-018
```
`spl[1] − spl[0] == 0` (no time elapsed, impossible for `window > 0`) reverts. `L_avg` replaces `pool.liquidity()` in the depth rule of §9.3. Observation-activity rule: see §9.3 item 1 (D-019); the observations are read directly from `pool.observations(index)`.
Price in USD (8 dec) per one stock token, with `dS = 18`, `dU = 6`:
- if stock token is `token1` (NVDA/USDG case, token0 = USDG): `P_raw = 1.0001^tick = token1/token0 = stockWei per USDG unit`, so `price8 = 1e8 × 10^(dS − dU) / 1.0001^tick`; computed as `FullMath.mulDiv(1e8 × 1e12, 2^192, sqrtP²)`.
- if stock token is `token0`: `price8 = 1e8 × 1.0001^tick / 10^(dS − dU)`; computed as `FullMath.mulDiv(sqrtP², 1e8, 2^192 × 1e12)`.
Check against cast: tick 222534 → `1e12 / 1.0001^222534 ≈ 216.4`, feed answer 216.79. ✓
USD conversion (founder decision D-015): the pool price is USDG per token; every TWAP used by the protocol is converted to USD with the USDG/USD Chainlink feed (`0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`, 8 dec, heartbeat 86 400 s, read 0.99975827 on 2026-09-02):
```
twapUSD8 = twapUSDG8 × usdgUsd.answer / 1e8
```
Requirements on the USDG/USD read at the settle (or open) call:
- `answer > 0` and `now − updatedAt ≤ 26 h`; if stale, the TWAP is **invalid** (the series falls through to the next path in §9.2/§9.3; a stale peg feed is not evidence of a depeg).
- `0.98e8 ≤ answer ≤ 1.02e8`; if the answer is **outside the band, the TWAP is invalid** (founder decision D-015, revised): a USDG price more than 2 % from par makes a USDG-denominated pool an unreliable USD reference, so the series falls through to the next path exactly as for a stale read. For a WEEKEND series that is the first-fresh-Chainlink-round fallback of §9.3, which is USD-denominated and unaffected by USDG; for a WEEKDAY series the TWAP is already the last path, so the outcome is HALTED with `NO_ORACLE_PATH`.
- `TwapRejected(seriesId, reason)` is emitted with `USDG_STALE` or `USDG_OUT_OF_BAND` so the keeper and frontend can show why the primary path was skipped.
`usdgBandLowBps = 9800`, `usdgBandHighBps = 10200`, `usdgMaxStale = 26 h` are timelocked global parameters. The same converted TWAP is used for `S_ref` (§7.2) and `S_cap` (§12).

Deploy-time action: call `pool.increaseObservationCardinalityNext(65535)` on every allowlisted pool (permissionless; cardinality 6000 today on NVDA/USDG). With 100 ms blocks and one observation per block that has a swap, 6 000 observations may cover only minutes during busy sessions; 65 535 is the v3 maximum. The keeper monitors coverage (`slot0.observationCardinality` and the oldest observation timestamp) every hour and alerts if the buffer would not cover `window + twapGrace`.

Keeper monitoring of external code (D-020, closes T-11.4): the keeper stores the stock-token beacon (`0xe10b6f6b…`) implementation address read at deploy (`0xb35490d6…`) and the USDG implementation (`0x68184c44…`), polls both every 5 minutes, and on any change (or a `Upgraded` event) pauses deposits and new auctions on all vaults via the guardian key and pages the founder. Unpause only after a human has confirmed the new implementation keeps raw-unit `balanceOf`, no transfer fee, no transfer hooks and unchanged `decimals`.

### 9.6 HALTED and resolution
- `settle` reverts with a typed error until the keeper (or anyone) calls `halt(seriesId)` once all paths are provably exhausted on-chain (for WEEKDAY: no valid round and `now > expiry + twapGrace`, or every available round tripped the jump guard; for WEEKEND: `now > expiry + 54 060`, or the same). A USDG depeg alone never halts a weekend series; it only removes the TWAP path (§9.5). `halt` sets `state = HALTED`, calls `RiskModule.pauseNewAuctions(vaultId, reason)`, emits `SeriesHalted` with `reason ∈ {NO_ORACLE_PATH, JUMP_GUARD}`.
- **Resolution band (D-022, closes T-14.2).** `resolveRef` = `refRound.answer` (§9.1: the last valid Chainlink round at or before expiry, any age); if no such round exists, `resolveRef = sRef`. `resolveBoundBps = 2 500` is a **contract constant**, not a parameter. Any resolution price must satisfy `resolveRef × 0.75 ≤ price8 ≤ resolveRef × 1.25`.
- `resolveHalted(seriesId, price8, bytes evidenceURI)` — timelock only (48 h public delay). **Reverts if `price8` is outside the resolution band.** Sets `settlementPrice = price8`, `settlementPath = 4`, finishes settlement exactly as `settle` would. Option holders and depositors can observe the proposal in the timelock before execution. Worst case with a 5 % OTM strike and a resolution at the top of the band: `(1.25 − 1.05) / 1.25 = 16 %` of collateral, instead of unbounded.
- `resolveHaltedByOracle(seriesId, roundHint)` — **permissionless after `haltedTimeout = 7 days` past `expiry`** (D-033, closes T-14.7 and T-11.6). Accepts the first valid Chainlink round with `updatedAt > expiry` (verified with `prev` as in §9.3, any lateness, `oraclePaused() == false`), **clamps** its answer into the resolution band, sets `settlementPrice` to the clamped value, `settlementPath = 5`, emits `SeriesResolvedByOracle(seriesId, rawAnswer, clampedPrice, roundId)` and finishes settlement exactly as `settle` would. Clamping rather than rejecting guarantees that a halted series can always be resolved without any key, which removes the single-admin-key liveness dependency; the timelock path stays for feeds that never return. Before `haltedTimeout` only the timelock can resolve.
- While a vault is halted: no new auctions; deposits blocked; queued redeems are executed at resolution; `claimPremium`, `withdrawRefund`, `claimOptions` and claims for previously settled series keep working.

### 9.7 Settlement effects (all paths)
1. `series.settlementPrice = S; payoutPerOption = S > K ? (S − K) × 1e18 / S : 0`.
2. `payoutOwed += filledQty × payoutPerOption / 1e18` (tokens reserved for option holders).
3. Series → SETTLED; vault → IDLE; process queues (§4.3).
4. `OptionToken.claim(seriesId, qty)` burns `qty` and transfers `qty × payoutPerOption / 1e18` stock tokens; decrements `payoutOwed`. No expiry on claims. A bidder with an unminted allocation (§8.2 step 6) calls `AuctionHouse.claimPayout(seriesId, to)`, which mints the allocation to the AuctionHouse and claims it in the same transaction (D-038). Bond locks of filled bidders are released by the permissionless `AuctionHouse.releaseLocks(seriesId)` once the series is SETTLED or RESOLVED (§8.1).
5. If `payoutTotal > totalAssets()` at settlement (only possible if the issuer burned or froze vault tokens, §2), `payoutPerOption` is scaled by `totalAssets() / payoutTotal` (rounded down), so the new payout never touches tokens already owed to earlier series' option holders or to executed queued redeems, the shortfall is recorded, and `ShortfallRecorded` triggers the safety-module flow (§14). Invariant I-2 covers the normal case. Rounding dust (`payoutTotal − Σ floor(q_i × payoutPerOption / 1e18)`, a few wei per series) stays in `payoutOwed` permanently; accepted.

---

## 10. Multiplier handling (corporate actions)

### 10.1 Why the vault is a no-op across corporate actions
- Raw balances never change (`uiMultiplier` scales only the UI amount; ERC-8056). The vault's `balanceOf` and share math are in raw units.
- The Chainlink feed prices **one raw token**: `Token Price = share price × uiMultiplier` (https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood ; https://docs.robinhood.com/chain/building-with-stock-tokens "don't apply the multiplier yourself").
- A 4-for-1 split: share price ÷ 4, multiplier × 4, token price unchanged. A cash dividend: share price drops by the dividend on the ex-date, multiplier rises by the reinvested fraction, token price unchanged (total-return feed). AAPL's multiplier of 1.000566080061092436 on 2026-09-02 is such a reinvestment (inference: 0.0566 % ≈ one $0.26 dividend net of 30 % withholding on a ~$320 share; not sourced).
- Therefore the vault's NAV in USD, the strike in USD per token and the payoff formula are all continuous across a corporate action. Nothing in the vault reads `uiMultiplier` for accounting.

### 10.2 Strike convention: PER_TOKEN, no adjustment (founder decision D-002)
`K` is USD per raw token, exactly the unit the feed reports. At settlement `S` is USD per raw token. **No adjustment is applied at settlement**, even if `uiMultiplier` changed between `auctionOpen` and `expiry`.

Rejected alternative, recorded for completeness: if `K` were defined per underlying share (`K_share`), the settlement strike would be `K_token = K_share × m(expiry) / 1e18` with `m` = `uiMultiplier()` at settlement, equivalently `K_settle = K_open × m(expiry) / m(open)`. Applying this formula on top of the multiplier-adjusted feed double-counts the corporate action and mis-settles, which is why it is rejected.

### 10.3 Oracle pause and pending multipliers
- `settle` and `openAuction` revert while `token.oraclePaused() == true`; the keeper retries. The Chainlink feed holds its last value during the pause, so a round published just before the pause is still a valid "at or before expiry" round after unpause. The weekend TWAP path is unaffected by the flag but the ±15 % bound then compares against the pre-pause Chainlink answer; if a large discontinuity is expected (e.g. a spin-off, which is not an active corporate-action type today per the API) the curator should skip that weekend by not opening the auction.
- `openAuction` refuses to open a series that spans a staged multiplier change (`effectiveAt` inside `(now, expiry]`, D-026). A change staged **after** open is the only way a multiplier can change inside a live series; the keeper alerts on it and the jump-guard exception of §9.1 governs settlement.
- The keeper watches `UIMultiplierUpdated`, `newUIMultiplier()/effectiveAt()` and `GET /corporate-actions`, and surfaces pending actions in the frontend.
- `Series.multiplierAtOpen` is emitted for indexers so a UI can show "1 option = X underlying shares" and is read by the jump-guard exception (§9.1). It enters no payout formula.

---

## 11. Fees (FeeRouter)

- Performance fee on **premium only**: `feeBps` default 1000 (10 %), protocol bound `[0, 2000]`, per vault, timelocked. No management fee, no fee on principal, no fee on settlement.
- Taken at clearing: `fee = premiumGross × feeBps / 1e4` USDG with the `feeBps` snapshotted at `openAuction` (D-049); `FeeRouter.collect(vault, seriesId, fee)` is called by the AuctionHouse and only updates internal balances while the USDG stays in the AuctionHouse (which holds a standing approval for the router). The permissionless `FeeRouter.flush(vault)` pulls the pending amount from the AuctionHouse to `treasury` (or, post-token, runs the WRITE-mode processing), so no fee-side transfer can block `clear` (D-023, D-049). Implemented v0.4: `AuctionHouse.registerVault` calls `FeeRouter.initVault(vault)`, which sets `feeBps = 1000` once (an explicit `initialised` flag, since `feeBps == 0` is a legal value); `setFeeBps` is timelocked and bounded by 2000; `feeRouter.auctionHouse` is set once after deployment (D-044).
- Payment modes (per vault, set by the curator, effective after timelock):
  - `USDG` (default): the USDG fee is forwarded to `treasury` (a timelock-controlled address).
  - `WRITE` (post-token, founder decision, reading confirmed 2026-09-02): the USDG fee is still deducted from premium at clearing; the FeeRouter then debits the curator's prefunded WRITE balance by `feeUSD × (1e4 − writeDiscountBps) / 1e4` converted at the WRITE/USDG 30-minute TWAP (`writePool`, **placeholder `address(0)` until the token launches; set by timelock post-launch, D-016**; while zero, `setFeeMode(WRITE)` reverts and `depositWrite` is disabled), burns `writeBurnShareBps` of it and forwards the rest to `treasury`; the USDG fee is then paid out to the curator's `feeRebateRecipient`. If the curator's WRITE balance is insufficient the router falls back to the USDG path for that clearing and emits `WriteModeFallback`. **`writeDiscountBps = 2000` (20 % discount), `writeBurnShareBps = 5000` (50 % of the WRITE burned, rest to treasury)** — founder decision D-011.
- `depositWrite(vaultId, amount)` / `withdrawWrite(vaultId, amount)` by the curator; withdrawals allowed any time (no lock).

---

## 12. Caps (CapController)

- `capMode ∈ {FIXED, SAFETY_MODULE}`; global switch by timelock. Both paths exist from day one.
- `FIXED`: `capUSD[vaultId]` in 6-dec USD, set per vault by timelock (curator proposes). **Launch value 25 000 USDG per vault** (founder decision D-011). Deposit check: `(totalAssets() + assets) × S_cap / 1e18 ≤ capUSD × 1e2` where `S_cap` = Chainlink latest answer if < 80 h old, else the 30-min TWAP; if neither is available, deposits revert (`CapPriceUnavailable`). Queued deposits are checked at execution, not at request. Implemented as `CapController.remainingDepositAssets(vault, totalAssets) → (assets, priceOk)`: the used-USD term rounds **up** so the cap can never be exceeded by dust (fuzz-tested); `S_cap` comes from an `IPriceSource` implemented by `SettlementOracle` (settable by timelock until then, D-039).
- `SAFETY_MODULE`: `globalCapUSD = k × safetyModuleValueUSD`, `k` default 5 (WAD-scaled, bound `[1, 20]`), `safetyModuleValueUSD = SafetyModule.totalStaked() × WRITE/USDG TWAP (30 min)`. Per-vault cap = `globalCapUSD × capWeightBps[vaultId] / 1e4`, weights set by timelock (governance), `Σ weights ≤ 1e4`; **default at switch-over is an equal split** `floor(1e4 / activeVaults)` across active vaults (founder decision D-011). A vault may also keep a `capUSD` ceiling under this mode (`min` of both).
- Caps limit deposits only; they never force withdrawals.

---

## 13. Bonds (BondManager)

| Bond | Purpose | Amount pre-token | Post-token |
|---|---|---|---|
| Curator bond | required to call `VaultFactory.createVault` and to propose parameter changes for that vault | **10 000 USDG** (founder decision D-011); one bond per vault | migrated to WRITE, amount by timelock |
| MM bond | required to bid | **25 000 USDG** (founder decision) | migrated to WRITE |

- `postBond(kind)` / `withdrawBond(kind)`: withdrawal allowed only when the holder has **zero active locks** and after `bondCooldown` (7 days) from the withdrawal request. Locks are by participation (D-030): `AuctionHouse.bid` calls `lock(bidder, seriesId)` on the bidder's first bid in a series; the lock is released at `clear` for bidders with no fill and at SETTLED/RESOLVED for filled bidders. Curator locks: one per live series of the curator's vault. Locks never depend on option-token balances, so transferring option tokens away does not unlock a bond. `hasActiveMMBond(account)` is true while a bond of the required asset and amount is posted and no withdrawal request is pending.
- Slashing: only via timelock, `slashBond(holder, kind, amount, evidenceURI)`, capped at 100 % of the bond, proceeds to `treasury`. Grounds are off-chain (attestation fraud, demonstrated TWAP manipulation, malicious parameters) and public in the timelock queue.
- Migration to WRITE: `bondAsset` switch by timelock with a 30-day grace during which both assets satisfy the requirement; after grace, USDG bonds no longer count and become withdrawable immediately (no cooldown).
- MM eligibility also requires an off-chain signed non-US-person attestation checked by the keeper's/frontend's allowlist service; **nothing on-chain** enforces it (founder decision). `BondManager` therefore has no attestation field.
- Implemented v0.4 (`contracts/src/BondManager.sol`): `postBond(kind)` tops the bond up to `requiredAmount[kind]` (so a raised requirement never strands a holder) and reverts while a withdrawal is pending; `requestWithdraw` needs zero active locks and starts the 7-day cooldown, during which `hasActiveMMBond` is false; `cancelWithdraw` restores it; `withdrawBond` needs the cooldown elapsed and still zero locks; `lock`/`unlock` are AuctionHouse-only and idempotent (`isLocked[holder][seriesId]`, `activeLocks[holder]`, gating the MM bond only, D-049); `slashBond` is `onlyOwner`, capped at the bond, proceeds to `treasury`, and a slashed bond below the requirement no longer counts until topped up. `bondManager.auctionHouse` is set once after deployment (D-044). Per-series curator locks and the WRITE migration are not implemented yet.

---

## 14. Safety module (post-token)

- `stake(amount)` mints `sWRITE` 1:1 (non-transferable accounting token). `requestUnstake(amount)` starts a **14-day cooldown**; `unstake()` is valid in a 3-day claim window after the cooldown; missing the window requires a new request. Stake in cooldown is still slashable.
- `slash(amount, recipient, evidenceURI)` — timelock only, **≤ 30 % of `totalStaked()` per event**, and at most one slash per 14 days per vault incident. Slashed WRITE goes to `ShortfallReserve` (timelock-controlled).
- Shortfall flow: `ShortfallRecorded(vaultId, seriesId, tokensShort)` (§9.7 step 5, or an exploit) → timelock proposal that slashes, converts WRITE to the needed asset (Uniswap or OTC; executed by the timelock as a second proposal) and calls `vault.injectCoverage(seriesId, tokens)` which raises `payoutOwed` back to full and re-enables claims at 100 %.
- `safetyModuleValueUSD()` view feeds §12. No revenue share: stakers receive nothing except protocol-defined WRITE incentives decided by governance (CLAUDE.md rule 7).

---

## 15. Governance and admin

- `TimelockController(minDelay = 48 h, proposers = [adminEOA], executors = [adminEOA], admin = itself)`. The admin EOA is a hardware wallet. No multisig, by decision (D-003).
- Behind the timelock: every parameter setter in every contract; `resolveHalted` (bounded, §9.6); `slashBond`; `SafetyModule.slash`; `capMode`, `capUSD`, `capWeightBps`, `k`; `bondAsset`; `feeBps`, fee mode acceptance, `treasury`; `sequencerFeed`; `weekdayMaxStale`, `twapGrace`, `weekendTwapBoundBps`, `swapNotionalUSDG`, `impactBps`, `minObservationsInWindow`, `jumpBps`; curator floors `minStrikeDistanceBps[kind]`, `minReserveBpsOfSpot[kind]`; `sunset(vaultId)`; `KEEPER_ROLE` and `GUARDIAN_ROLE` grants and revocations; adding a vault (factory allowlist is fixed at deploy; adding a token requires a new factory deployment or a timelocked `allowToken`). Oracle parameters take effect only for series opened after execution (snapshot, §6, D-031).
- Constants (not parameters, not changeable by anyone): `resolveBoundBps = 2 500`, `haltedTimeout = 7 days`, the protocol bounds on every parameter.
- Keeper (`KEEPER_ROLE`, D-028): the only caller of `openAuction`. Everything else the keeper does (`clear`, `settle`, `halt`, `processDeposits/Redeems`, `flush`, `resolveHaltedByOracle`) is permissionless, so liveness never depends on the keeper key. Grant/revoke is timelocked; the fast response to a rogue keeper is the guardian pausing new auctions.
- Guardian (`GUARDIAN_ROLE` in RiskModule, no delay): **two holders** (D-012 as amended by D-029): a hot key on the keeper server, distinct from the keeper's transaction key, so the keeper's alerting can pause within seconds without human presence; and an off-server key (hardware wallet or phone signer) held by the founder, so a compromised server cannot prevent a human pause during the 48 h it takes to rotate roles. Functions: `pauseNewAuctions(vaultId | ALL)`, `pauseDeposits(vaultId | ALL)`, `unpause*` of any guardian pause (either holder can unpause the other's pause). Compromise of either key can at worst pause new auctions and deposits; rotation is a timelocked `grantRole/revokeRole` (RUNBOOK.md). It cannot: move any funds, change any parameter, block `withdraw/redeem` in IDLE, block `claimPremium`, `withdrawRefund`, `claimOptions`, `OptionToken.claim` or `claimWithdrawal`, block queued-redeem processing after settlement, or stop `settle`, `halt` or `resolveHaltedByOracle`. A deposit pause does hold queued **deposits** (they execute after unpause, §4.3), never queued redeems. After a guardian pause, any live series still settles; once settled the vault is IDLE with withdrawals open indefinitely until unpause.
- Deployer: deploys with `CREATE2`, wires roles, runs the post-deploy checklist (`increaseObservationCardinalityNext`, verify on Blockscout), then `renounceRole` on every contract and transfers ownership to the timelock. Verified in a fork test that reads every role after deployment. No contract that holds user funds has a sweep, rescue or arbitrary-call function.
- Treasury, team tokens and LP live in `Vesting` contracts and locked LP, never in the admin wallet (CLAUDE.md rule 5).
- Upgradeability: none. Every cross-contract reference is `immutable`; no proxy, no `delegatecall` in fund-holding contracts. **Migration path from day one (D-034, closes T-17):** `sunset(vaultId)` behind the timelock sets `vault.sunset = true`; after the current series settles or resolves the vault refuses `openAuction` permanently and stays IDLE with `withdraw/redeem` open forever; queued deposits are refundable (`cancelDeposit`) and deposits revert. `sunset` is irreversible. A v2 is a new deployment; the frontend reads `sunset()` on old vaults and offers withdraw-then-deposit into the new vault. Option tokens, bonds and premium accumulators of the old deployment keep working until claimed.

---

## 16. Events and read functions

### 16.1 Events (indexed fields marked `*`)
Vault
- `Deposit(*sender, *owner, assets, shares)`, `Withdraw(*sender, *receiver, *owner, assets, shares)` (ERC-4626)
- `DepositQueued(*receiver, *requestId, assets)`, `DepositQueueCancelled(*requestId)`, `DepositRequestExpired(*requestId)`, `DepositExecuted(*requestId, shares, sharePrice)` (`sharePrice` = `convertToAssets(1e18)`, i.e. raw stock units per 1e18 share units; shares have 24 decimals)
- `RedeemQueued(*owner, *requestId, shares)`, `RedeemQueueCancelled(*requestId)`, `RedeemExecuted(*requestId, assets)`, `WithdrawalClaimed(*owner, *to, assets)`
- `PremiumAccrued(*seriesId, premiumNet, accPremiumPerShare)`, `PremiumClaimed(*account, *to, usdg)`
- `VaultStateChanged(from, to)`, `VaultSunset()` (one contract per vault, so no `vaultId` field)
- `SeriesOpened(*seriesId, kind, strike, expiry, offeredQty, multiplierAtOpen)`, `SeriesCleared(*seriesId, filledQty, premiumNet)`, `SeriesSkipped(*seriesId)`, `SeriesHalted(*seriesId, reason)`, `SeriesSettled(*seriesId, settlementPrice, settlementPath, payoutPerOption, payoutTotal)` (vault-side; the AuctionHouse emits the richer `AuctionOpened`/`AuctionCleared` below), `OptionsMinted(*seriesId, *to, qty)`, `OptionPaid(*seriesId, *to, qty, tokens)`
- `ShortfallRecorded(*seriesId, tokensShort)`, `CoverageInjected(*seriesId, tokens)` (post-token, not yet implemented)
OptionToken
- `VaultRegistered(*underlying, *vault)`, `SeriesCreated(*id, *vault, *underlying, kind, strike, expiry, multiplierAtCreation)`, `SeriesSettled(*id, settlementPrice, payoutPerOption)`, `OptionClaimed(*seriesId, *holder, *to, qty, tokens)`
Series / Auction
- `AuctionOpened(*vaultId, *seriesId, kind, auctionOpen, auctionClose, expiry, sRef, strike, offeredQty, reservePrice, multiplierAtOpen)`
- `BidPlaced(*seriesId, *bidder, bidId, qty, price, escrow)`
- `AuctionCleared(*seriesId, clearingPrice, filledQty, premiumGross, fee)`, `BidFilled(*seriesId, *bidder, bidId, filledQty, refund)`
- `RefundCredited(*seriesId, *bidder, usdg)`, `RefundWithdrawn(*bidder, *to, usdg)`, `OptionsAllocated(*seriesId, *bidder, qty)`, `OptionsClaimed(*seriesId, *bidder, *to, qty)`, `PayoutClaimed(*seriesId, *bidder, *to, qty, tokens)`, `LocksReleased(*seriesId)`, `VaultRegistered(*vault, *optionToken)` (AuctionHouse)
- `AuctionSkipped(*seriesId)`
- `SeriesSettled(*seriesId, settlementPrice, settlementPath, payoutPerOption, payoutTotal, oracleRoundId)`
- `TwapRejected(*seriesId, reason)` (`USDG_STALE`, `USDG_OUT_OF_BAND`, `LIQUIDITY`, `OBSERVATIONS`, `BOUND`, `GRACE`), `JumpGuardTripped(*seriesId, path, price)`, `SeriesHalted(*seriesId, reason)`, `SeriesResolved(*seriesId, price, evidenceURI)`, `SeriesResolvedByOracle(*seriesId, rawAnswer, clampedPrice, roundId)`
- `OptionClaimed(*seriesId, *holder, qty, tokens)`
Risk / admin
- `Paused(*vaultId, what, *by)`, `Unpaused(*vaultId, what, *by)`
- `ParameterChanged(*target, key, oldValue, newValue)`
- `FeeCollected(*vaultId, *seriesId, usdg, mode)`, `FeeFlushed(*vault, *treasury, usdg)`, `VaultInitialised(*vault, feeBps)`, `WriteFeePaid(*vaultId, writeAmount, burned)`, `WriteModeFallback(*vaultId)`
- `BondPosted(*holder, kind, asset, amount)`, `BondLocked(*holder, *seriesId)`, `BondUnlocked(*holder, *seriesId)`, `BondWithdrawRequested(*holder, kind, unlockAt)`, `BondWithdrawCancelled(*holder, kind)`, `BondWithdrawn(*holder, kind, amount)`, `BondSlashed(*holder, kind, amount, evidenceURI)`, `AuctionHouseSet(*auctionHouse)` (BondManager and FeeRouter, once)
- `Staked(*account, amount)`, `UnstakeRequested(*account, amount, unlockAt)`, `Unstaked(*account, amount)`, `Slashed(amount, recipient, evidenceURI)`

### 16.2 Read functions by consumer
Keeper
- `vault.state()`, `vault.canOpenAuction(expiry) → (bool, bytes32 reason)` (vault-side checks only; `auction.canOpen(vaultId, kind, at)` will add the §5 schedule checks), `vault.queueLengths()`, `vault.freeAssets()`, `vault.pendingRedeemAssets()`
- `oracle.referencePrice(vaultId) → (price8, source)`; `oracle.previewSettle(seriesId, hint) → (ok, price8, path, reason)` (pure view mirror of `settle`)
- `oracle.chainlinkRoundAtOrBefore(feed, ts, hintRound)` and `chainlinkFirstRoundAfter(feed, ts, hintRound)` views used to build hints
- `pool` observation coverage helpers: `oracle.twapCoverageSeconds(pool)`
- `auction.bids(seriesId)`, `auction.bidders(seriesId)`, `auction.previewClear(seriesId) → (clearingPrice, filledQty, premiumGross, willSkip)` (pure mirror of `clear`; returns the stored result for a cleared auction), `auction.canOpen(vault, kind, expiry, at) → (ok, reason)` (§5 schedule checks, then `vault.canOpenAuction`; reasons `NOT_REGISTERED`, `OPEN_WINDOW`, `EXPIRY`, `WEEKDAY_GAP` plus the vault's), `auction.scheduledExpiry(kind, at)` (Friday 20:00 UTC of the next epoch week for WEEKDAY — 21:00 under EST is the keeper's substitution — or Sunday 23:59:00 of the current one), `auction.strikeDistanceBounds(vault, kind)`, `auction.reserveBounds(vault, kind, sRef)`, `auction.referencePrice(vault)`, `auction.computeStrike(sRef, bps)`, `auction.auctions(seriesId)`, `auction.refundable(account)`, `auction.claimableOptions(seriesId, account)`, `auction.currentAuction(vault)`, `auction.lastWeekdayExpiry(vault)`
- `oracle.canResolveByOracle(seriesId) → (bool, unlockAt)`, `oracle.resolutionBand(seriesId) → (low8, high8)`, `series(seriesId).params`
- `vault.sunset()`, `bond.activeLocks(account)`
Points indexer
- all events above; specifically `Deposit/Withdraw/*Executed` for share-time, `PremiumAccrued` for yield, `BidPlaced/BidFilled` for MM activity, `Transfer` of vault shares (ERC-20) and of `OptionToken` (ERC-1155 `TransferSingle/Batch`)
- `vault.totalAssets()`, `vault.totalSupply()`, `vault.convertToAssets(1e18)` at each settlement block
Frontend
- `vault.maxDeposit(user)`, `maxWithdraw(user)`, `previewDeposit`, `previewRedeem`, `premiumClaimable(user)`, `queuedDeposit(requestId)`, `queuedRedeem(requestId)` (request ids come from the `DepositQueued`/`RedeemQueued` events), `withdrawalClaimable(user)`, `vault.sunset()`
- `auction.refundable(user)`, `auction.claimableOptions(seriesId, user)`
- `series(seriesId)` struct, `vault.currentSeriesId()`, `vault.nextEvent() → (kind, at)`
- `cap.remainingCapUSD(vaultId)`, `cap.capMode()`
- `fee.mode(vaultId)`, `fee.writeBalance(vaultId)`
- `bond.status(account, kind) → (amount, asset, unlockAt)`
- `token.uiMultiplier()`, `token.newUIMultiplier()`, `token.effectiveAt()`, `token.oraclePaused()` for disclosure banners
- `oracle.lastChainlink(vaultId) → (answer, updatedAt)`, `oracle.twap(vaultId, window) → (twapUSDG8, twapUSD8)` and `oracle.usdgUsd() → (answer, updatedAt, inBand)` for the settlement-preview panel

### 16.3 Points (off-chain indexer, founder decision D-013)
- Snapshot once per day at 00:00:00 UTC (first L2 block with `timestamp ≥ midnight`).
- Depositor points per day = `Σ over vaults of shares × convertToAssets(1e18) / 1e18 × feedPrice8 / 1e8`, i.e. **1 point per USD-equivalent of stock tokens deposited per day**, priced with the vault's Chainlink feed answer at the snapshot block (any age; the feed is the protocol's price reference). Queued deposits count from execution, queued redeems count until execution.
- Market makers with an active bond earn **2 × the USD value of their bond per day** (USDG at par; WRITE at the WRITE/USDG TWAP post-token). Bonds in withdrawal cooldown do not earn.
- Staking points for the safety module are added post-token (formula TBD in TOKENOMICS.md).
- Points are informational until governance decides otherwise; no on-chain state.

---

## 17. Invariants (to be encoded in Foundry invariant tests)

- **I-1 Coverage**: for every vault, `Σ filledQty of LIVE series ≤ asset.balanceOf(vault) − payoutOwed − withdrawalClaimable − queuedDepositTokens` at all times (equivalently `≤ totalAssets()`), and offered quantity is checked at open and at clear.
- **I-2 Payout bound**: `payoutPerOption < 1e18` for every settled series; `payoutOwed ≤ asset.balanceOf(vault)` unless a `ShortfallRecorded` event exists.
- **I-3 Escrow conservation** (exact, D-043, D-049): `USDG.balanceOf(AuctionHouse) == Σ escrow of open bids + Σ refundable + Σ FeeRouter.pending`; for every closed auction `Σ escrow == Σ refunds credited + premiumNet + fee`; after `clear`, every bid's escrow equals `floor(filled × clearingPrice / 1e18) + refund credited`; `Σ claimableOptions[seriesId] + OptionToken.totalSupply(seriesId) + Σ claimed qty == filledQty` for every series.
- **I-4 Premium conservation**: `USDG.balanceOf(vault) == Σ premiumClaimable + (unsettled accumulator dust)`; the sum of all `PremiumClaimed` never exceeds the sum of all `premiumNet`.
- **I-5 Never stale**: no `SeriesSettled` with `settlementPath == 1` has `expiry − round.updatedAt > weekdayMaxStale`; no `settlementPath ∈ {2,3}` on a WEEKEND series uses a Chainlink answer with `updatedAt ≤ expiry` as the settlement price.
- **I-6 Windows**: `Deposit`/`Withdraw` events only occur while `state == IDLE`; queued deposit executions only occur while `state == IDLE`; queued redeem executions only occur at or after a settlement of the same vault. `settle`, `halt` and both resolve functions emit no ERC-20 `Transfer` of the stock token.
- **I-7 Guardian scope**: no guardian-only function changes any storage other than pause flags.
- **I-8 Share price monotonicity outside settlement**: `convertToAssets(1e18)` is constant between two settlements of the same vault (no fees on principal, no rebasing).
- **I-9 USDG peg guard**: no `SeriesSettled` with `settlementPath == 2` exists whose settle block had a USDG/USD answer outside `[0.98e8, 1.02e8]` or older than 26 h.
- **I-10 Jump guard**: for every `SeriesSettled` with `settlementPath ∈ {1,2,3}`, `|settlementPrice / sRef − 1| ≤ params.jumpBps`, or `multiplierAtOpen ≠ uiMultiplier()` at the settle block and the multiplier-adjusted ratio is within the bound.
- **I-11 Resolution band**: for every series with `settlementPath ∈ {4,5}`, `settlementPrice ∈ [0.75 × resolveRef, 1.25 × resolveRef]`.
- **I-12 Parameter snapshot**: `series.params` never changes after `AuctionOpened`; a `ParameterChanged` event never alters the outcome of `previewSettle` for a series that is already open.
- **I-13 Bond locks**: an MM whose bid was filled in a series that is LIVE or HALTED has `activeLocks > 0` and `withdrawBond` reverts, regardless of its option-token balance.
- **I-14 Liveness without keys**: from any HALTED series and any block ≥ `expiry + haltedTimeout`, there exists a permissionless call sequence (`resolveHaltedByOracle`, then queue processing) that returns the vault to IDLE whenever the feed has published any valid round after expiry.
- **I-15 Sunset**: after `VaultSunset`, no `AuctionOpened` for that vault; `maxWithdraw` is never forced to 0 by any flag once the last series is settled.
- **I-16 Encumbrance accounting**: `encumbered == Σ filledQty of LIVE/HALTED series` (at most one) and `encumbered ≤ totalAssets()`; `state == IDLE ⇒ encumbered == 0`; for every series `OptionToken.totalSupply(id) + claimedQty == mintedQty ≤ filledQty`; `balanceOf(vault) == escrowedRedeemShares`; `totalAssets + payoutOwed + withdrawalClaimableTotal + queuedDepositTokens == asset.balanceOf(vault)` absent issuer burns.

Encoded so far (`contracts/test/invariants/VaultInvariants.t.sol`, stateful with `fail_on_revert`; the handler plays depositors, AuctionHouse, Settlement, option holders, the issuer (burn, pause), the guardian (pauses), the timelock (sunset, queue bounds, caps) and a reentrant ERC-1155 receiver): I-1, I-2 (payout bound; after an issuer burn the shortfall form), I-3 (supply clause), I-4, I-8 (as "share price never decreases outside a paying settlement or an issuer burn", the exact-constant form fails by rounding dust), I-15 (IDLE ⇒ every share redeemable regardless of pause/sunset), I-16, T-16 (no reentrancy from the mint callback), plus the brief's I1–I4: encumbered ≤ balance, Σ share claims ≤ totalAssets, no encumbrance after settlement, zero-payout settlement never lowers the share price. I-6 (no stock `Transfer` inside `settle`) is a unit test with recorded logs; threat-model regressions live in `test/CoveredCallVault.threats.t.sol` (`test_Txx_…` naming per THREAT-MODEL §6).

Auction layer (`contracts/test/invariants/AuctionInvariants.t.sol`, v0.4; the handler plays depositors, four bonded MMs, the keeper, the settlement oracle, the issuer, Paxos freezes and the timelock, with structured time travel): I-3 in all three forms (`invariant_I3_escrowExact`, `invariant_I3_closedConservation`, `invariant_I3_allocationIdentity`, the last one also asserting `filledQty ≤ offeredQty`, `clearingPrice ≥ reservePrice` and vault/auction agreement), I-13 (`invariant_I13_bondLocks`: a filled bidder of the LIVE/HALTED series is locked and no bond withdrawal ever succeeded while locked), fee conservation (`pending + treasury == Σ fee`), `previewClear == clear`, and "auction OPEN ⇔ vault AUCTION" (the skip paths of D-045 never leave the vault stuck). I-5, I-7, I-9…I-12, I-14 need SettlementOracle / RiskModule.

---

## 18. Open questions for the founder

Resolved on 2026-09-02 (see DECISIONS.md D-009 to D-014): curator bond 10 000 USDG; relative strike grid 0.25 % with per-kind distance bounds and per-asset-class defaults; 100 % of unencumbered balance net of queued redeems written per series; TWAP liquidity rule (250 000 USDG swap < 1 % impact) and 30-minute grace; WRITE fee 20 % discount / 50 % burn; caps k = 5 with governance weights defaulting to an equal split and 25 000 USDG per vault pre-token; guardian is a hot key on the keeper server; option tokens freely transferable; points formula; testnet mocks + mainnet-fork tests.

Closed on 2026-09-02 (D-015 to D-017): TWAPs are converted to USD with the USDG/USD feed, and a USDG/USD read that is stale or outside 0.98–1.02 invalidates the TWAP path only (the Chainlink fallback still runs); `writePool` is a post-launch placeholder (`address(0)`); the weekend TWAP bound stays at 15 % globally, per-vault configurable.

OQ-004 (2026-09-03, D-047): once SettlementOracle exists, freeze or redeploy `AuctionHouse.priceSource` and `CapController.priceSource` (same fate as OQ-003), and move the D-031 `OracleParams` snapshot into SettlementOracle keyed by `auctionOpen`.

Closed on 2026-09-02 (D-018 to D-034): all sixteen revisions from THREAT-MODEL.md §4 accepted: time-weighted TWAP liquidity, minimum observations in the window, beacon monitoring, deterministic bound reference, resolution band ±25 % with permissionless resolution after 7 days, pull-based refunds and option allocation, bond locks by participation, no series across a staged multiplier change, jump guard ±30 % vs `sRef`, curator floors on strike distance and reserve, second guardian key, `KEEPER_ROLE` on `openAuction`, parameter snapshot per series, `requestDeposit` in any state with execution at the next IDLE, `sunset`.

Still open (not among the sixteen, THREAT-MODEL T-14): **OQ-001** whether a second cold key should hold `CANCELLER_ROLE` on the timelock (must not be the guardian). **OQ-002** measure the USDG/USD feed weekend cadence and the SPY/QQQ pool depth before choosing `usdgMaxStale` and creating the ETF vaults (THREAT-MODEL T-12.5, T-03). **OQ-003** freeze or redeploy `CapController.priceSource` once `SettlementOracle` exists (D-039). New questions go here with an `OQ-` id and are closed with a DECISIONS.md entry.

---

## 19. Not verified (no source found, or source blocked)

- Chainlink **L2 Sequencer Uptime Feed** address for Robinhood Chain: absent from https://docs.chain.link/data-feeds/l2-sequencer-feeds and from the feed JSON; Robinhood docs reference one without an address. Hook shipped disabled.
- Testnet (46630) addresses for USDG, stock tokens and Chainlink stock feeds: none found; cast confirms nothing at the mainnet addresses. Testnet feed JSON (`feeds-robinhood-testnet*.json`) returned 404.
- `faucet.testnet.chain.robinhood.com`: referenced by third parties, returned HTTP 403 to my fetch; Chainlink faucet page verified.
- The on-chain **asset registry** address that `docs.robinhood.com/chain/contracts` says its table is generated from: not published; the beacon `owner()` call reverts. The v1 allowlist is therefore hardcoded (§1.2).
- Stock-token `isBlocked(address)` reverts under `eth_call` for every address tried (likely calls the compliance precompile); blocklist semantics for contract addresses are unverified beyond the fact that Uniswap and Morpho hold tokens.
- Who controls the stock-token beacon upgrade and whether it has a delay: beacon `owner()` reverts; Beosin's role list (13 roles) could not be read (HTTP 403 direct, partial via proxy).
- Chainlink's tokenized-equity docs page lists AAPL/AMD/AMZN/… as "High risk" with SVR-Backup; the reference JSON lists all stock feeds as `custom`; NVDA/SPY/TSLA/MSFT rows were not visible in the fetched docs page. Parameters (8 dec / 86 400 s / 0.5 %) are from the JSON only.
- Blockscout API (`/api/v2/tokens/…`, `/api?module=token`) returned 403; all token facts come from `cast` against the public RPC instead.
- USDG `isFrozen`/`paused` semantics (what exactly is blocked) are inferred from the Paxos pattern; the Robinhood-chain implementation source was not read.
- The AAPL multiplier interpretation (dividend net of 30 % withholding) is an inference, not sourced.
- Exact `expiry` UTC values depend on US DST; the contract validates a window, the keeper computes the offset; no on-chain DST calendar was verified.
- Uniswap v3 pool addresses for AAPL/TSLA/MSFT/AMZN/GOOGL/META vs USDG were not queried (NVDA, SPY and QQQ were); `getPool` at deploy time is specified instead. Liquidity depth of the SPY and QQQ pools against the 250 000 USDG / 1 % rule was not measured.
