// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoveredCallVault} from "../../src/CoveredCallVault.sol";
import {OptionToken} from "../../src/OptionToken.sol";
import {AuctionHouse} from "../../src/AuctionHouse.sol";
import {RiskModule} from "../../src/RiskModule.sol";
import {SettlementOracle} from "../../src/SettlementOracle.sol";
import {ISettlementOracle} from "../../src/interfaces/ISettlementOracle.sol";
import {IAuctionHouse} from "../../src/interfaces/IAuctionHouse.sol";
import {ICoveredCallVault} from "../../src/interfaces/ICoveredCallVault.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {OracleParams, SeriesKind, SeriesState, VaultState} from "../../src/Types.sol";

/// @dev Stateful fuzzing handler for the settlement layer (SPEC §17 I-5, I-7, I-9..I-12, I-14). Every action is
/// guarded (`fail_on_revert = true`). Plays the keeper (open), MMs (bid), anyone (clear / settle / halt /
/// resolveHaltedByOracle), the Chainlink feed operator (rounds, phase bumps, garbage answers), the pool (swaps,
/// liquidity pulls), the USDG/USD feed, the issuer (splits), the two guardians (with an I-7 storage check) and the
/// timelock (bounded parameter changes, in-band resolutions). Lifecycle actions warp to their earliest valid time so
/// every run reaches settlement inside the depth budget. Ghosts snapshot what the invariants need at settle time.
contract SettlementHandler is Test {
    CoveredCallVault public vault;
    OptionToken public opt;
    AuctionHouse public ah;
    RiskModule public rm;
    SettlementOracle public oracle;
    MockStockToken public stock;
    MockAggregatorV3 public feed;
    MockAggregatorV3 public usdgFeed;
    MockUniswapV3Pool public pool;
    address public admin;
    address public keeper;
    address public guardianHot;
    address public guardianCold;
    address[] public mms;
    address[] public depositors;

    struct Ghost {
        SeriesKind kind;
        uint64 expiry;
        uint64 auctionOpen;
        uint128 sRef;
        bytes32 paramsHash;
        uint256 mAtOpen;
        uint256 filledQty;
        bool settled;
        uint8 path;
        uint256 price;
        uint80 roundId;
        uint256 mAtSettle;
        uint256 settleTs;
        uint256 usdgAnswer;
        uint256 usdgUpdatedAt;
        uint256 totalAssetsAtSettle;
        uint256 payoutTotal;
        uint256 claimed;
        uint256 resolveRef;
        bool halted;
    }

    uint256[] public seriesIds;
    mapping(uint256 => Ghost) internal ghosts;

    struct RoundRec {
        uint80 id;
        uint256 ts;
        int256 answer;
    }

    RoundRec[] internal _rounds;
    uint16 public phase = 1;
    uint64 public nextAgg;
    int256 public lastAnswer = 200e8;
    int24 public tick = 223_338;
    uint128 public constant POOL_LIQ = 1e19;
    bytes32[4] internal _flagSlots;

    // counters
    uint256 public calls;
    uint256 public opens;
    uint256 public clears;
    uint256 public halts;
    uint256 public claims;
    uint256 public splits;
    uint256 public paramChanges;
    uint256 public guardianCalls;
    uint256 public guardianViolations;
    uint256 public livenessFailures;
    uint256 public previewMismatches;
    uint256 public resolveFailures;
    mapping(uint8 => uint256) public settlesByPath;

    struct Deps {
        CoveredCallVault vault;
        OptionToken opt;
        AuctionHouse ah;
        RiskModule rm;
        SettlementOracle oracle;
        MockStockToken stock;
        MockAggregatorV3 feed;
        MockAggregatorV3 usdgFeed;
        MockUniswapV3Pool pool;
        address admin;
        address keeper;
        address guardianHot;
        address guardianCold;
        uint64 nextAgg;
    }

    constructor(Deps memory d, address[] memory mms_, address[] memory depositors_) {
        vault = d.vault;
        opt = d.opt;
        ah = d.ah;
        rm = d.rm;
        oracle = d.oracle;
        stock = d.stock;
        feed = d.feed;
        usdgFeed = d.usdgFeed;
        pool = d.pool;
        admin = d.admin;
        keeper = d.keeper;
        guardianHot = d.guardianHot;
        guardianCold = d.guardianCold;
        nextAgg = d.nextAgg;
        mms = mms_;
        depositors = depositors_;
        // import the fixture's rounds so hints can be computed
        for (uint64 i = 1; i < nextAgg; ++i) {
            uint80 id = feed.roundId(1, i);
            (, int256 a,, uint256 upd,) = feed.getRoundData(id);
            _rounds.push(RoundRec(id, upd, a));
        }
        _learnFlagSlots();
    }

    modifier count() {
        calls++;
        _;
    }

    // ═════════════════════════════ lifecycle ═════════════════════════════

    /// @dev Keeper: opens the next weekday series, warping to the Monday window and posting a fresh round first.
    function openWeekday(uint256 seed) external count {
        if (vault.state() != VaultState.IDLE || rm.auctionsPaused(address(vault))) return;
        uint256 t = _nextMonday1400(block.timestamp);
        _warpTo(t);
        _postRound(block.timestamp - 5 minutes, lastAnswer);
        _ensureDeposit(seed);
        uint64 exp = ah.scheduledExpiry(SeriesKind.WEEKDAY, uint64(block.timestamp));
        uint16 dist = uint16(bound(seed, 300, 1500));
        (bool ok,) = ah.canOpen(address(vault), SeriesKind.WEEKDAY, exp, uint64(block.timestamp));
        if (!ok) return;
        vm.prank(keeper);
        try ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, dist, 1e6) returns (uint256 id) {
            _recordOpen(id);
        } catch {}
    }

    /// @dev Keeper: opens the weekend series in the Friday window.
    function openWeekend(uint256 seed) external count {
        if (vault.state() != VaultState.IDLE || rm.auctionsPaused(address(vault))) return;
        uint256 t = _nextFriday2010(block.timestamp);
        _warpTo(t);
        _postRound(block.timestamp - 5 minutes, lastAnswer);
        _ensureDeposit(seed);
        uint64 exp = ah.scheduledExpiry(SeriesKind.WEEKEND, uint64(block.timestamp));
        uint16 dist = uint16(bound(seed, 100, 1000));
        (bool ok,) = ah.canOpen(address(vault), SeriesKind.WEEKEND, exp, uint64(block.timestamp));
        if (!ok) return;
        vm.prank(keeper);
        try ah.openAuction(address(vault), SeriesKind.WEEKEND, exp, dist, 1e6) returns (uint256 id) {
            _recordOpen(id);
        } catch {}
    }

    function bid(uint256 seed) external count {
        uint256 id = vault.currentSeriesId();
        if (id == 0) return;
        IAuctionHouse.Auction memory a = ah.auctions(id);
        if (a.state != IAuctionHouse.AuctionState.OPEN || block.timestamp >= a.auctionClose) return;
        address mm = mms[seed % mms.length];
        uint256 qty = bound(seed >> 8, 1e18, a.offeredQty);
        uint256 price = bound(seed >> 16, a.reservePrice, 5e6);
        vm.prank(mm);
        try ah.bid(id, qty, price) {} catch {}
    }

    /// @dev Warps to the auction close and clears (permissionless); a bid is placed first if there is none.
    function clear(uint256 seed) external count {
        uint256 id = vault.currentSeriesId();
        if (id == 0) return;
        IAuctionHouse.Auction memory a = ah.auctions(id);
        if (a.state != IAuctionHouse.AuctionState.OPEN) return;
        if (ah.bids(id).length == 0 && block.timestamp < a.auctionClose) {
            vm.prank(mms[seed % mms.length]);
            try ah.bid(id, bound(seed, 1e18, a.offeredQty), 2e6) {} catch {}
        }
        _warpTo(a.auctionClose);
        try ah.clear(id) {
            clears++;
        } catch {}
    }

    /// @dev Anyone: settles the live series if the oracle says it can, halts if it says the paths are exhausted,
    /// resolves a halted series once permissionless resolution is open. Warps to expiry when called early.
    function settle(uint256 seed) external count {
        // self-sufficient: open and clear a series first when there is none (AuctionHandler pattern)
        if (vault.state() == VaultState.IDLE) {
            if (seed % 2 == 0) this.openWeekday(seed >> 1);
            else this.openWeekend(seed >> 1);
        }
        if (vault.state() == VaultState.AUCTION) this.clear(seed);
        uint256 id = vault.currentSeriesId();
        if (id == 0) return;
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        if (s.state == SeriesState.HALTED) {
            _resolve(id, seed);
            return;
        }
        if (s.state != SeriesState.LIVE) return;
        if (block.timestamp < s.expiry) {
            _weekActivity(seed, s.expiry);
            _warpTo(uint256(s.expiry) + bound(seed, 0, 2 hours));
        }
        ISettlementOracle.Hint memory h = _hint(s.expiry);
        (bool ok, uint256 price8, uint8 path,) = oracle.previewSettle(id, h);
        if (ok) {
            _snapshotBeforeSettle(id);
            try oracle.settle(id, h) {
                _recordSettle(id, path, price8);
            } catch {
                livenessFailures++;
            }
            return;
        }
        (bool canHalt,) = oracle.canHalt(id, h);
        if (canHalt) {
            try oracle.halt(id, h) {
                halts++;
                Ghost storage g = ghosts[id];
                g.halted = true;
                g.resolveRef = oracle.records(id).resolveRef;
            } catch {
                livenessFailures++;
            }
        }
    }

    /// @dev Feed and pool activity between the clear and the expiry, randomised so every path and rejection reason
    /// is reachable: a round at a random age before expiry (fresh or stale), a window of swaps at a random tick and
    /// liquidity, sometimes a first round after expiry.
    function _weekActivity(uint256 seed, uint64 expiry) internal {
        if (seed % 4 != 0) {
            int256 a = lastAnswer * int256(bound(seed >> 8, 70, 130)) / 100;
            _postRound(uint256(expiry) - bound(seed >> 16, 0, 30 hours), a);
        }
        if (seed % 3 != 0) {
            int24 t = tick + int24(int256(bound(seed >> 24, 0, 2_000))) - 1_000;
            uint128 liq = (seed >> 32) % 8 == 0 ? 1 : POOL_LIQ;
            uint32[5] memory offsets = [uint32(3600), 2400, 1200, 600, 120];
            for (uint256 i; i < offsets.length; ++i) {
                uint32 ts = uint32(expiry) - offsets[i];
                (uint32 last,,,) = pool.observations(pool.observationIndex());
                if (ts >= last) pool.write(ts, t, liq);
            }
            tick = t;
        }
        if (seed % 5 == 0) {
            _postRound(uint256(expiry) + bound(seed >> 40, 1, 60_000), lastAnswer);
        }
    }

    function _resolve(uint256 id, uint256 seed) internal {
        ISettlementOracle.Hint memory h = _hint(vault.series(id).expiry);
        // `previewResolveByOracle` mirrors the call exactly (D-057): whenever it says ok the call must succeed, so a
        // revert here is a liveness violation rather than a guarded no-op.
        (bool ok,) = oracle.previewResolveByOracle(id, h.afterRoundId, h.afterPrevRoundId);
        if (ok) {
            _snapshotBeforeSettle(id);
            try oracle.resolveHaltedByOracle(id, h.afterRoundId, h.afterPrevRoundId) {
                _recordSettle(id, 5, vault.series(id).settlementPrice);
            } catch {
                resolveFailures++;
            }
            return;
        }
        if (seed % 3 == 0) {
            (uint256 lo, uint256 hi) = oracle.resolutionBand(id);
            uint128 p = uint128(bound(seed >> 4, lo, hi));
            _snapshotBeforeSettle(id);
            vm.prank(admin);
            try oracle.resolveHalted(id, p, "ipfs://evidence") {
                _recordSettle(id, 4, p);
            } catch {
                resolveFailures++;
            }
        }
    }

    /// @dev Composite lifecycle action (the `AuctionHandler.fullCycle` pattern): open, fill, clear, let the feed and
    /// the pool move, then settle / halt / resolve. Without it a random run of depth 32 rarely reaches a settlement
    /// and the per-series invariants assert nothing.
    function cycle(uint256 seed) external count {
        if (vault.state() == VaultState.IDLE) {
            if (seed % 2 == 0) this.openWeekday(seed);
            else this.openWeekend(seed);
        }
        this.clear(seed >> 8);
        this.settle(seed >> 16);
        this.claim(seed >> 32);
    }

    function claim(uint256 seed) external count {
        if (seriesIds.length == 0) return;
        uint256 id = seriesIds[seed % seriesIds.length];
        if (!ghosts[id].settled) return;
        address mm = mms[(seed >> 8) % mms.length];
        vm.prank(mm);
        try ah.claimOptions(id, mm) {} catch {}
        uint256 q = opt.balanceOf(mm, id);
        if (q == 0) return;
        vm.prank(mm);
        try opt.claim(id, q, mm) returns (uint256 tokens) {
            ghosts[id].claimed += tokens;
            claims++;
        } catch {}
    }

    // ═════════════════════════════ environment ═════════════════════════════

    /// @dev Chainlink operator: a new round at now, ±40 % drift, 3 % phase bumps, and 5 % of calls emit a run of
    /// up to 12 rounds with `answer = 0` (D-057: the hint verifier tolerates runs up to MAX_GARBAGE_SKIP).
    function postRound(uint256 seed) external count {
        int256 answer = lastAnswer * int256(bound(seed, 60, 140)) / 100;
        if (seed % 100 >= 5 && seed % 100 < 8) {
            phase++;
            nextAgg = 1;
        }
        if (seed % 100 < 5) {
            uint256 n = bound(seed >> 8, 1, 12);
            for (uint256 i; i < n; ++i) {
                _postRound(block.timestamp, 0);
            }
            return;
        }
        _postRound(block.timestamp, answer);
    }

    /// @dev Pool: a swap at now with a bounded tick drift; 10 % of swaps are liquidity pulls.
    function swap(uint256 seed) external count {
        int24 drift = int24(int256(bound(seed, 0, 1600))) - 800;
        int24 t = tick + drift;
        if (t < 223_338 - 4_000) t = 223_338 - 4_000;
        if (t > 223_338 + 4_000) t = 223_338 + 4_000;
        tick = t;
        uint128 liq = seed % 10 == 0 ? 1 : POOL_LIQ;
        pool.write(uint32(block.timestamp), t, liq);
    }

    function usdg(uint256 seed) external count {
        if (seed % 10 == 0) return; // stale read
        uint256 answer = bound(seed, 0.95e8, 1.05e8);
        uint80 id = feed.roundId(1, uint64(block.timestamp));
        usdgFeed.setRound(id, int256(answer), block.timestamp);
        usdgFeed.setLatest(id);
    }

    /// @dev Issuer: a corporate action applied immediately (multiplier ×2 or ×4, or back to 1e18).
    function split(uint256 seed) external count {
        uint256 m = [uint256(1e18), 2e18, 4e18][seed % 3];
        vm.startPrank(admin);
        stock.stageMultiplier(m, block.timestamp - 1);
        stock.applyMultiplier();
        vm.stopPrank();
        splits++;
    }

    /// @dev Guardian: pause / unpause with the I-7 storage check.
    function guardian(uint256 seed) external count {
        address g = seed % 2 == 0 ? guardianHot : guardianCold;
        address target = (seed >> 2) % 2 == 0 ? address(vault) : address(0);
        bytes memory data;
        uint256 k = (seed >> 4) % 4;
        if (k == 0) data = abi.encodeCall(rm.pauseDeposits, (target));
        else if (k == 1) data = abi.encodeCall(rm.unpauseDeposits, (target));
        else if (k == 2) data = abi.encodeCall(rm.pauseNewAuctions, (target));
        else data = abi.encodeCall(rm.unpauseNewAuctions, (target));
        vm.record();
        vm.prank(g);
        (bool ok,) = address(rm).call(data);
        (, bytes32[] memory writes) = vm.accesses(address(rm));
        guardianCalls++;
        if (!ok || writes.length != 1) {
            guardianViolations++;
            return;
        }
        bool known;
        for (uint256 i; i < 4; ++i) {
            if (writes[0] == _flagSlots[i]) known = true;
        }
        if (!known) guardianViolations++;
    }

    /// @dev Timelock: a bounded random parameter version (applies to later series only).
    function setParams(uint256 seed) external count {
        OracleParams memory p = rm.defaultParams();
        p.weekdayMaxStale = uint32(bound(seed, 3_600, 108_000));
        p.twapGrace = uint32(bound(seed >> 8, 300, 3_600));
        p.weekendTwapBoundBps = uint16(bound(seed >> 16, 300, 1_500));
        p.weekdayTwapBoundBps = uint16(bound(seed >> 24, 100, 500));
        p.minObservationsInWindow = uint8(bound(seed >> 32, 1, 16));
        p.jumpBps = uint16(bound(seed >> 40, 1_000, 5_000));
        p.usdgMaxStale = uint32(bound(seed >> 48, 3_600, 288_000));
        vm.prank(admin);
        rm.setOracleParams(address(vault), p);
        paramChanges++;
    }

    function warp(uint256 seed) external count {
        vm.warp(block.timestamp + bound(seed, 10 minutes, 1 days));
    }

    // ═════════════════════════════ scripted cycles (non-vacuity) ═════════════════════════════

    function cycleWeekdayPath1() external {
        this.openWeekday(500);
        this.clear(1);
        uint256 id = vault.currentSeriesId();
        uint64 e = vault.series(id).expiry;
        _postRound(uint256(e) - 1 hours, lastAnswer);
        this.settle(0);
    }

    function cycleWeekendPath2() external {
        this.openWeekend(400);
        this.clear(1);
        uint256 id = vault.currentSeriesId();
        uint64 e = vault.series(id).expiry;
        uint32[5] memory offsets = [uint32(3600), 2400, 1200, 600, 120];
        for (uint256 i; i < offsets.length; ++i) {
            pool.write(uint32(e) - offsets[i], 223_338, POOL_LIQ);
        }
        tick = 223_338;
        vm.warp(uint256(e) + 30);
        _usdgPar();
        this.settle(0);
    }

    function cycleWeekendPath3() external {
        this.openWeekend(400);
        this.clear(1);
        uint256 id = vault.currentSeriesId();
        uint64 e = vault.series(id).expiry;
        _postRound(uint256(e) + 600, lastAnswer);
        vm.warp(uint256(e) + 700);
        this.settle(0);
    }

    /// @dev Weekday series with a stale feed: halt after the grace, then the timelock resolves in-band.
    function cycleHaltResolveTimelock() external {
        this.openWeekday(500);
        this.clear(1);
        uint256 id = vault.currentSeriesId();
        uint64 e = vault.series(id).expiry;
        vm.warp(uint256(e) + 1801);
        this.settle(0); // halts (no round inside 26 h, quiet pool)
        this.settle(0); // resolveHalted by the timelock (seed 0 → branch)
        _unpause();
    }

    /// @dev Weekday halt, then a fresh round after expiry and the permissionless resolution after 7 days.
    function cycleHaltResolveOracle() external {
        this.openWeekday(500);
        this.clear(1);
        uint256 id = vault.currentSeriesId();
        uint64 e = vault.series(id).expiry;
        vm.warp(uint256(e) + 1801);
        this.settle(0);
        _postRound(uint256(e) + 1 days, lastAnswer);
        vm.warp(uint256(e) + 7 days);
        this.settle(1);
        _unpause();
    }

    function _usdgPar() internal {
        uint80 id = feed.roundId(1, uint64(block.timestamp));
        usdgFeed.setRound(id, 1e8, block.timestamp);
        usdgFeed.setLatest(id);
    }

    function _unpause() internal {
        vm.prank(guardianHot);
        rm.unpauseNewAuctions(address(vault));
    }

    // ═════════════════════════════ internals ═════════════════════════════

    function _recordOpen(uint256 id) internal {
        opens++;
        seriesIds.push(id);
        IAuctionHouse.Auction memory a = ah.auctions(id);
        Ghost storage g = ghosts[id];
        g.kind = a.kind;
        g.expiry = a.expiry;
        g.auctionOpen = a.auctionOpen;
        g.sRef = a.sRef;
        g.paramsHash = keccak256(abi.encode(rm.paramsAt(address(vault), a.auctionOpen)));
        g.mAtOpen = stock.uiMultiplier();
    }

    function _snapshotBeforeSettle(uint256 id) internal {
        Ghost storage g = ghosts[id];
        g.filledQty = vault.series(id).filledQty;
        g.totalAssetsAtSettle = vault.totalAssets();
        g.mAtSettle = stock.uiMultiplier();
        g.settleTs = block.timestamp;
        (, int256 a,, uint256 upd,) = usdgFeed.latestRoundData();
        g.usdgAnswer = a > 0 ? uint256(a) : 0;
        g.usdgUpdatedAt = upd;
    }

    function _recordSettle(uint256 id, uint8 path, uint256 price8) internal {
        Ghost storage g = ghosts[id];
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        g.settled = true;
        g.path = path;
        g.price = s.settlementPrice;
        g.roundId = oracle.records(id).roundId;
        g.payoutTotal = uint256(s.filledQty) * s.payoutPerOption / 1e18;
        if (s.settlementPrice != price8) previewMismatches++;
        settlesByPath[path]++;
    }

    function _postRound(uint256 ts, int256 answer) internal {
        if (_rounds.length > 0 && ts < _rounds[_rounds.length - 1].ts) ts = _rounds[_rounds.length - 1].ts;
        uint80 id = feed.roundId(phase, nextAgg++);
        feed.setRound(id, answer, ts, ts);
        _rounds.push(RoundRec(id, ts, answer));
        if (answer > 0) lastAnswer = answer;
    }

    /// @dev Hint for `expiry`: last round at or before expiry (the oracle skips garbage successors), the first round
    /// after expiry with its previous-phase predecessor when needed, and the newest pool observation at or before
    /// expiry.
    function _hint(uint64 expiry) internal view returns (ISettlementOracle.Hint memory h) {
        uint256 n = _rounds.length;
        for (uint256 i = n; i > 0; --i) {
            RoundRec memory r = _rounds[i - 1];
            if (r.ts <= expiry && r.answer > 0) {
                h.refRoundId = r.id;
                break;
            }
        }
        for (uint256 i; i < n; ++i) {
            if (_rounds[i].ts > expiry) {
                h.afterRoundId = _rounds[i].id;
                if (uint64(_rounds[i].id) == 1 && i > 0) h.afterPrevRoundId = _rounds[i - 1].id;
                break;
            }
        }
        h.obsIndex = _obsAtOrBefore(expiry);
    }

    function _obsAtOrBefore(uint64 expiry) internal view returns (uint16) {
        uint16 i = pool.observationIndex();
        uint16 card = pool.observationCardinality();
        for (uint256 k; k < card; ++k) {
            (uint32 ts,,, bool init) = pool.observations(i);
            if (init && ts <= expiry) return i;
            i = i == 0 ? card - 1 : i - 1;
        }
        return 0;
    }

    function _ensureDeposit(uint256 seed) internal {
        if (vault.totalAssets() >= 100e18) return;
        address d = depositors[seed % depositors.length];
        vm.prank(d);
        try vault.deposit(1_000e18, d) {} catch {}
    }

    function _warpTo(uint256 t) internal {
        if (block.timestamp < t) vm.warp(t);
    }

    function _nextMonday1400(uint256 t) internal view returns (uint256 m) {
        uint256 week = ah.WEEK();
        m = t - (t % week) + ah.MON_1400();
        if (m < t) m += week;
    }

    /// @dev Friday 20:10 UTC of the epoch week of `t` if still ahead, else next week's.
    function _nextFriday2010(uint256 t) internal view returns (uint256 f) {
        uint256 week = ah.WEEK();
        f = t - (t % week) + ah.FRI_2000() + ah.WEEKEND_GAP();
        if (f < t) f += week;
    }

    function _learnFlagSlots() internal {
        bytes[4] memory calls_ = [
            abi.encodeCall(rm.pauseDeposits, (address(0))),
            abi.encodeCall(rm.pauseNewAuctions, (address(0))),
            abi.encodeCall(rm.pauseDeposits, (address(vault))),
            abi.encodeCall(rm.pauseNewAuctions, (address(vault)))
        ];
        for (uint256 i; i < 4; ++i) {
            vm.record();
            vm.prank(guardianHot);
            (bool ok,) = address(rm).call(calls_[i]);
            require(ok, "learn");
            (, bytes32[] memory writes) = vm.accesses(address(rm));
            _flagSlots[i] = writes[0];
        }
        vm.startPrank(guardianHot);
        rm.unpauseDeposits(address(0));
        rm.unpauseNewAuctions(address(0));
        rm.unpauseDeposits(address(vault));
        rm.unpauseNewAuctions(address(vault));
        vm.stopPrank();
    }

    function ghost(uint256 id) external view returns (Ghost memory) {
        return ghosts[id];
    }

    /// @dev The hint an honest keeper would build from on-chain data, for the liveness invariant.
    function hintFor(uint64 expiry) external view returns (ISettlementOracle.Hint memory) {
        return _hint(expiry);
    }

    function seriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function roundsCount() external view returns (uint256) {
        return _rounds.length;
    }
}
