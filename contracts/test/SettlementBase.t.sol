// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuctionBaseTest} from "./AuctionBase.t.sol";
import {RiskModule} from "../src/RiskModule.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {OracleParams, SeriesKind} from "../src/Types.sol";

/// @dev Full stack with the real RiskModule and SettlementOracle wired as the vault's immutables, a phase-1 Chainlink
/// mock (one round every 4 h, $200), a USDG/USD mock at par and a USDG/NVDA 0.05 % pool (USDG = token0, stock =
/// token1, tick 223 338 ≈ $200, in-range liquidity 1e19 which passes the 250 000 USDG / 1 % depth rule).
abstract contract SettlementBaseTest is AuctionBaseTest {
    RiskModule internal rm;
    SettlementOracle internal oracle;
    MockAggregatorV3 internal feed;
    MockAggregatorV3 internal usdgFeed;
    MockAggregatorV3 internal seqFeed;
    MockUniswapV3Pool internal pool;

    address internal guardianHot = makeAddr("guardianHot");
    address internal guardianCold = makeAddr("guardianCold");

    int24 internal constant TICK_200 = 223_338; // floor(log_1.0001(1e18 / 200e6))
    uint128 internal constant POOL_LIQ = 1e19;
    uint32 internal constant FEED_PERIOD = 4 hours;
    uint256 internal constant DEPOSIT = 1_000e18;
    uint64 internal nextAgg = 1;

    // ───────────────────────────── hooks ─────────────────────────────

    function _deployRiskModule() internal override returns (address) {
        rm = new RiskModule(admin);
        return address(rm);
    }

    function _deploySettlement(address ah_) internal override returns (address) {
        usdgFeed = new MockAggregatorV3(8);
        feed = new MockAggregatorV3(8);
        seqFeed = new MockAggregatorV3(0);
        oracle = new SettlementOracle(address(rm), ah_, address(usdgFeed), admin);
        settlement = address(oracle);
        return settlement;
    }

    function setUp() public virtual override {
        super.setUp(); // ends at MONDAY_1400
        pool = new MockUniswapV3Pool(address(usdg), address(stock), 500, TICK_200, POOL_LIQ, uint32(START_TS));
        vm.startPrank(admin);
        rm.setSettlementOracle(address(oracle));
        rm.setGuardian(guardianHot, true);
        rm.setGuardian(guardianCold, true);
        oracle.registerVault(address(vault), address(feed), address(pool));
        ah.setPriceSource(address(oracle));
        cap.setPriceSource(address(oracle));
        vm.stopPrank();

        // Chainlink: phase 1, one round every 4 h from START_TS up to now.
        for (uint256 t = START_TS; t <= block.timestamp; t += FEED_PERIOD) {
            _feedRoundAt(t, PRICE);
        }
        // Pool: one swap per hour at the $200 tick so the buffer covers every window.
        for (uint256 t = START_TS + 1 hours; t <= block.timestamp; t += 1 hours) {
            pool.write(uint32(t), TICK_200, POOL_LIQ);
        }
        _usdgFresh();
        vm.label(address(oracle), "settlementOracle");
        vm.label(address(rm), "riskModule");
        vm.label(address(feed), "feed");
        vm.label(address(pool), "pool");
    }

    // ───────────────────────────── feed / pool helpers ─────────────────────────────

    /// @dev Appends the next phase-1 round at `ts`.
    function _feedRoundAt(uint256 ts, uint256 answer) internal returns (uint80 id) {
        id = feed.roundId(1, nextAgg++);
        feed.setRound(id, int256(answer), ts);
    }

    function _feedRoundAtPhase(uint16 phase, uint64 agg, uint256 ts, uint256 answer) internal returns (uint80 id) {
        id = feed.roundId(phase, agg);
        feed.setRound(id, int256(answer), ts);
    }

    function _usdgFresh() internal {
        usdgFeed.setRound(feed.roundId(1, uint64(block.timestamp)), 1e8, block.timestamp);
    }

    function _usdgAt(uint256 answer, uint256 ts) internal {
        uint80 id = feed.roundId(1, uint64(ts));
        usdgFeed.setRound(id, int256(answer), ts);
        usdgFeed.setLatest(id);
    }

    /// @dev Five swaps inside `[expiry − 1 h, expiry]` at `tick`; returns the observation index at expiry.
    function _seedWindow(uint64 expiry, int24 tick) internal returns (uint16 obsIndex) {
        uint32[5] memory offsets = [uint32(3600), 2400, 1200, 600, 120];
        for (uint256 i; i < offsets.length; ++i) {
            pool.write(uint32(expiry) - offsets[i], tick, POOL_LIQ);
        }
        return pool.observationIndex();
    }

    // ───────────────────────────── lifecycle helpers ─────────────────────────────

    /// @dev Opens, fills and clears a weekday series; time ends at auction close. Returns the seriesId.
    function _liveWeekday() internal returns (uint256 id) {
        _deposit(alice, DEPOSIT);
        id = _openDefault();
        _bid(mm1, id, 500e18, 2e6);
        _clear(id);
    }

    /// @dev Warps to Friday 21:00 UTC (inside the weekend open window), posts a fresh round so `S_ref` is
    /// available, deposits, opens, fills and clears a weekend series. Expiry is Sunday 23:59 UTC.
    function _liveWeekend() internal returns (uint256 id) {
        vm.warp(_fridayExpiry() + 1 hours);
        _feedRoundAt(block.timestamp - 30 minutes, PRICE);
        _deposit(alice, DEPOSIT);
        id = _openWeekend(500, RESERVE);
        _bid(mm1, id, 500e18, 2e6);
        _clear(id);
    }

    function _hint(uint80 refId) internal pure returns (ISettlementOracle.Hint memory h) {
        h.refRoundId = refId;
    }

    /// @dev Posts a fresh round 1 h before expiry, warps to expiry and settles on path 1.
    function _settleWeekdayPath1(uint256 id, uint256 price) internal returns (uint80 refId) {
        uint64 e = vault.series(id).expiry;
        refId = _feedRoundAt(e - 1 hours, price);
        vm.warp(e);
        oracle.settle(id, _hint(refId));
    }

    /// @dev Overrides the EOA-prank settle of AuctionBaseTest: path 1 through the oracle.
    function _settle(uint256 id, uint128 price) internal override {
        _settleWeekdayPath1(id, price);
    }

    function _ppo(uint256 s, uint256 k) internal pure returns (uint256) {
        return s > k ? (s - k) * WAD / s : 0;
    }

    function _params() internal view returns (OracleParams memory) {
        return rm.currentParams(address(vault));
    }

    /// @dev Sets a parameter version and moves one second forward: a version applies to series opened strictly
    /// after the block that set it (I-12).
    function _setParams(OracleParams memory p) internal {
        vm.prank(admin);
        rm.setOracleParams(address(vault), p);
        vm.warp(block.timestamp + 1);
    }
}
