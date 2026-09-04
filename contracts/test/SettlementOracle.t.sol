// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SettlementBaseTest} from "./SettlementBase.t.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {ICoveredCallVault} from "../src/interfaces/ICoveredCallVault.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockRiskModule} from "./mocks/MockRiskModule.sol";
import {RiskModule} from "../src/RiskModule.sol";
import {OracleParams, SeriesState, VaultState} from "../src/Types.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {OracleMath} from "../src/libraries/OracleMath.sol";

/// @dev SettlementOracle unit tests: every path, every rejection reason, halt, resolution, price views (SPEC §9, §12).
contract SettlementOracleTest is SettlementBaseTest {
    // ═════════════════════════════ registerVault ═════════════════════════════

    function test_registerVault_stored() public view {
        ISettlementOracle.VaultConfig memory c = oracle.vaultConfig(address(vault));
        assertTrue(c.registered);
        assertEq(address(c.feed), address(feed));
        assertEq(address(c.pool), address(pool));
        assertEq(address(c.stock), address(stock));
        assertTrue(c.stockIsToken1, "USDG is token0 in the fixture");
        assertEq(c.stockDecimals, 18);
        assertEq(c.usdgDecimals, 6);
        assertEq(address(ah.priceSource()), address(oracle));
        assertEq(address(cap.priceSource()), address(oracle));
    }

    function test_registerVault_onlyOwner_zero_duplicate() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.registerVault(address(vault), address(feed), address(pool));
        vm.startPrank(admin);
        vm.expectRevert(SettlementOracle.ZeroAddress.selector);
        oracle.registerVault(address(vault), address(0), address(pool));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.AlreadyRegistered.selector, address(vault)));
        oracle.registerVault(address(vault), address(feed), address(pool));
        vm.stopPrank();
    }

    /// @dev Second vault over a second stock token; registered with OptionToken/AuctionHouse when `wire` is true.
    function _newVault(address settlement_, address risk_, bool wire)
        internal
        returns (CoveredCallVault v, MockStockToken s)
    {
        s = new MockStockToken("Mock SPY", "SPY", admin);
        v = new CoveredCallVault(
            CoveredCallVault.Config({
                stock: address(s),
                usdg: address(usdg),
                optionToken: address(opt),
                auctionHouse: address(ah),
                settlement: settlement_,
                riskModule: risk_,
                capController: address(cap),
                owner: admin,
                name: "Overwrite SPY",
                symbol: "owSPY"
            })
        );
        if (wire) {
            vm.startPrank(admin);
            opt.registerVault(address(s), address(v));
            ah.registerVault(address(v));
            vm.stopPrank();
        }
    }

    function test_registerVault_miswires() public {
        (CoveredCallVault v1,) = _newVault(alice, address(rm), false);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.Miswired.selector, bytes32("VAULT_SETTLEMENT")));
        oracle.registerVault(address(v1), address(feed), address(pool));

        MockRiskModule other = new MockRiskModule();
        (CoveredCallVault v2,) = _newVault(address(oracle), address(other), false);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.Miswired.selector, bytes32("VAULT_RISK_MODULE")));
        oracle.registerVault(address(v2), address(feed), address(pool));

        (CoveredCallVault v3,) = _newVault(address(oracle), address(rm), false);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.Miswired.selector, bytes32("AUCTION_HOUSE")));
        oracle.registerVault(address(v3), address(feed), address(pool));

        (CoveredCallVault v4, MockStockToken s4) = _newVault(address(oracle), address(rm), true);
        MockAggregatorV3 f18 = new MockAggregatorV3(18);
        vm.prank(admin);
        vm.expectRevert(SettlementOracle.WrongFeedDecimals.selector);
        oracle.registerVault(address(v4), address(f18), address(pool));

        MockUniswapV3Pool p3000 = new MockUniswapV3Pool(address(usdg), address(s4), 3000, 0, 1e19, uint32(START_TS));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.WrongPoolFee.selector, uint24(3000)));
        oracle.registerVault(address(v4), address(feed), address(p3000));

        vm.prank(admin);
        vm.expectRevert(SettlementOracle.PoolTokenMismatch.selector); // fixture pool is USDG/NVDA, not USDG/SPY
        oracle.registerVault(address(v4), address(feed), address(pool));

        // token0 = stock orientation is accepted and recorded
        MockUniswapV3Pool pSpy =
            new MockUniswapV3Pool(address(s4), address(usdg), 500, -TICK_200, 1e12, uint32(START_TS));
        vm.prank(admin);
        oracle.registerVault(address(v4), address(feed), address(pSpy));
        assertFalse(oracle.vaultConfig(address(v4)).stockIsToken1);
    }

    function test_constructor_checks() public {
        vm.expectRevert(SettlementOracle.ZeroAddress.selector);
        new SettlementOracle(address(0), address(ah), address(usdgFeed), admin);
        MockAggregatorV3 f18 = new MockAggregatorV3(18);
        vm.expectRevert(SettlementOracle.WrongFeedDecimals.selector);
        new SettlementOracle(address(rm), address(ah), address(f18), admin);
    }

    // ═════════════════════════════ path 1 (weekday Chainlink) ═════════════════════════════

    function test_settle_path1_happy() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 refId = _feedRoundAt(e - 1 hours, 230e8);
        vm.warp(e);
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.Settled(id, 1, 230e8, refId);
        oracle.settle(id, _hint(refId));
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(uint8(s.state), uint8(SeriesState.SETTLED));
        assertEq(s.settlementPath, 1);
        assertEq(s.settlementPrice, 230e8);
        assertEq(s.payoutPerOption, _ppo(230e8, K_DEFAULT));
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        ISettlementOracle.SeriesRecord memory r = oracle.records(id);
        assertEq(r.path, 1);
        assertEq(r.price8, 230e8);
        assertEq(r.roundId, refId);
        assertFalse(r.halted);
    }

    function test_settle_gates() public {
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.UnknownSeries.selector, 99));
        oracle.settle(99, _hint(1));
        _deposit(alice, DEPOSIT);
        uint256 id = _openDefault();
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("NOT_LIVE")));
        oracle.settle(id, _hint(1));
        _bid(mm1, id, 500e18, 2e6);
        _clear(id);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("NOT_EXPIRED")));
        oracle.settle(id, _hint(1));
        uint64 e = vault.series(id).expiry;
        uint80 refId = _feedRoundAt(e - 1 hours, PRICE);
        vm.warp(e);
        vm.prank(admin);
        stock.setOraclePaused(true);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("ORACLE_PAUSED")));
        oracle.settle(id, _hint(refId));
        vm.prank(admin);
        stock.setOraclePaused(false);
        oracle.settle(id, _hint(refId));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("NOT_LIVE")));
        oracle.settle(id, _hint(refId));
    }

    function test_settle_refHint_mustBeLastBeforeExpiry() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r1 = _feedRoundAt(e - 2 hours, PRICE);
        uint80 r2 = _feedRoundAt(e - 1 hours, PRICE);
        uint80 r3 = _feedRoundAt(e + 1, PRICE);
        vm.warp(e + 1);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, r1));
        oracle.settle(id, _hint(r1));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, r3));
        oracle.settle(id, _hint(r3));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, uint80(12345)));
        oracle.settle(id, _hint(12345));
        vm.expectRevert(SettlementOracle.RefRoundRequired.selector);
        oracle.settle(id, _hint(0));
        oracle.settle(id, _hint(r2));
        assertEq(oracle.records(id).roundId, r2);
    }

    function test_settle_refHint_exactlyAtExpiryIsAtOrBefore() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r = _feedRoundAt(e, 210e8);
        vm.warp(e);
        oracle.settle(id, _hint(r));
        assertEq(vault.series(id).settlementPrice, 210e8);
    }

    /// @dev A garbage round (answer 0) between the reference and expiry does not invalidate the hint; a valid
    /// later round does.
    function test_settle_refHint_skipsGarbageSuccessors() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r = _feedRoundAt(e - 3 hours, PRICE);
        _feedRoundAt(e - 2 hours, 0);
        _feedRoundAt(e - 1 hours, 0);
        vm.warp(e);
        (bool ok,, uint8 path,) = oracle.previewSettle(id, _hint(r));
        assertTrue(ok);
        assertEq(path, 1);
        uint80 later = _feedRoundAt(e - 30 minutes, PRICE);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, r));
        oracle.settle(id, _hint(r));
        oracle.settle(id, _hint(later));
    }

    /// T-02: phase change. The last round of phase 1 is the reference when phase 2 starts after expiry.
    function test_T02_phaseBoundary_refRound() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 last1 = _feedRoundAt(e - 1 hours, PRICE);
        _feedRoundAtPhase(2, 1, e + 10, PRICE);
        vm.warp(e + 10);
        oracle.settle(id, _hint(last1));
        assertEq(oracle.records(id).roundId, last1);
    }

    function test_T02_phaseBoundary_refRoundInNewPhaseBeforeExpiry() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 last1 = _feedRoundAt(e - 2 hours, PRICE);
        uint80 first2 = _feedRoundAtPhase(2, 1, e - 1 hours, 205e8);
        vm.warp(e);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, last1));
        oracle.settle(id, _hint(last1));
        oracle.settle(id, _hint(first2));
        assertEq(vault.series(id).settlementPrice, 205e8);
    }

    /// T-02: a non-positive answer is never a settlement price.
    function test_T02_rejectsZeroAnswerAsRef() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 bad = _feedRoundAt(e - 1 hours, 0);
        vm.warp(e);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, bad));
        oracle.settle(id, _hint(bad));
    }

    /// T-01: a round older than weekdayMaxStale is rejected on path 1 and the series falls to the TWAP.
    function test_T01_staleRoundFallsToTwap() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 26 hours - 1, PRICE);
        uint16 obs = _seedWindow(e, TICK_200);
        vm.warp(e + 60);
        _usdgFresh();
        ISettlementOracle.Hint memory h = _hint(stale);
        h.obsIndex = obs;
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.PathRejected(id, 1, "STALE");
        oracle.settle(id, h);
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(s.settlementPath, 2);
        assertApproxEqRel(s.settlementPrice, 200e8, 0.001e18, "TWAP at the $200 tick");
    }

    function test_T01_maxStaleBoundary() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 edge = _feedRoundAt(e - 26 hours, PRICE);
        vm.warp(e);
        (bool ok,, uint8 path,) = oracle.previewSettle(id, _hint(edge));
        assertTrue(ok, "exactly 26 h is accepted");
        assertEq(path, 1);
        // shrink the parameter for a new series: the live series keeps its snapshot (I-12)
        OracleParams memory p = _params();
        p.weekdayMaxStale = 1 hours;
        _setParams(p);
        (ok,,,) = oracle.previewSettle(id, _hint(edge));
        assertTrue(ok, "snapshot protects the open series");
    }

    function test_settle_path1_noRoundAndNoTwap_revertsNoOraclePath() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        vm.warp(e);
        // last round is Monday's: > 26 h old; no TWAP activity → both fail
        uint80 last = feed.roundId(1, nextAgg - 1);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("STALE"), bytes32("OBSERVATIONS"))
        );
        oracle.settle(id, _hint(last));
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, _hint(last));
        assertFalse(ok);
        assertEq(reason, bytes32("OBSERVATIONS"));
    }

    /// D-053: `refRoundId == 0` is only accepted when the feed's first round is after expiry.
    function test_settle_refHintZero_feedStartedAfterExpiry() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        for (uint64 i = 1; i < nextAgg; ++i) {
            feed.deleteRound(feed.roundId(1, i));
        }
        feed.setRound(feed.roundId(1, 1), int256(PRICE), e + 5);
        feed.setLatest(feed.roundId(1, 1));
        vm.warp(e + 5);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("NO_ROUND"), bytes32("OBSERVATIONS"))
        );
        oracle.settle(id, _hint(0));
    }

    // ═════════════════════════════ jump guard (D-025, D-051) ═════════════════════════════

    function test_jumpGuard_path1_boundary() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 hi = _feedRoundAt(e - 2 hours, 260e8 + 1);
        vm.warp(e);
        // 260e8 + 1 trips the 30 % guard; no TWAP → NoOraclePath(JUMP_GUARD, OBSERVATIONS)
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, _hint(hi));
        assertFalse(ok);
        assertEq(reason, bytes32("OBSERVATIONS"));
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.NoOraclePath.selector, bytes32("JUMP_GUARD"), bytes32("OBSERVATIONS")
            )
        );
        oracle.settle(id, _hint(hi));
        uint80 edge = _feedRoundAt(e - 1 hours, 260e8);
        oracle.settle(id, _hint(edge));
        assertEq(vault.series(id).settlementPrice, 260e8, "exactly +30 % passes");
    }

    function test_jumpGuard_lowSide() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 lo = _feedRoundAt(e - 1 hours, 140e8 - 1);
        vm.warp(e);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.NoOraclePath.selector, bytes32("JUMP_GUARD"), bytes32("OBSERVATIONS")
            )
        );
        oracle.settle(id, _hint(lo));
    }

    /// @dev The event fires when a later path succeeds after the guard tripped on path 1 (TWAP inside 3 % of the
    /// tripped reference is impossible, so use a weekend series where path 3 follows a tripped path 2).
    function test_jumpGuard_eventOnFallthrough() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        uint80 refId = feed.roundId(1, nextAgg - 1);
        // pool pumped +40 % inside the window; the TWAP bound vs refRound (15 %) fails first → BOUND, not JUMP_GUARD
        uint16 obs = _seedWindow(e, TICK_200 - 3_365);
        uint80 after_ = _feedRoundAt(e + 300, 205e8);
        vm.warp(e + 400);
        _usdgFresh();
        ISettlementOracle.Hint memory h = _hint(refId);
        h.obsIndex = obs;
        h.afterRoundId = after_;
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.PathRejected(id, 2, "BOUND");
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 3);
    }

    // ═════════════════════════════ path 2 (TWAP) ═════════════════════════════

    function _weekendReady(int24 tick) internal returns (uint256 id, ISettlementOracle.Hint memory h) {
        id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        h = _hint(feed.roundId(1, nextAgg - 1)); // Friday's round: last at or before Sunday 23:59
        h.obsIndex = _seedWindow(e, tick);
        vm.warp(e + 60);
        _usdgFresh();
    }

    function test_settle_path2_weekend_happy() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        (bool ok, uint256 price8, uint8 path,) = oracle.previewSettle(id, h);
        assertTrue(ok);
        assertEq(path, 2);
        assertApproxEqRel(price8, 200e8, 0.0002e18);
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPrice, uint128(price8), "preview == settle");
        assertEq(vault.series(id).settlementPath, 2);
        assertEq(oracle.records(id).roundId, 0);
    }

    function test_settle_path2_usdgConversion() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        _usdgAt(1.01e8, block.timestamp);
        (, uint256 price8,,) = oracle.previewSettle(id, h);
        (uint256 usdg8,,) = oracle.twap(address(vault), 3600);
        assertGt(usdg8, 0);
        oracle.settle(id, h);
        assertApproxEqRel(price8, 202e8, 0.0002e18, "twapUSD = twapUSDG x 1.01");
    }

    function test_T08_path2PreferredWhenBothValid() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        h.afterRoundId = _feedRoundAt(block.timestamp - 30, 210e8);
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 2, "TWAP wins over the first fresh round");
    }

    function test_path2_reason_GRACE() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        vm.warp(vault.series(id).expiry + 1801);
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("NO_ROUND"), "path 3 not attempted without a hint");
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("GRACE"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    function test_path2_reason_OBSERVE() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        pool.setDead(true);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("OBSERVE"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    /// @dev One thin second before the window does not enter the window's harmonic mean.
    function test_path2_reason_LIQUIDITY_outsideWindowIgnored() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        pool.write(uint32(e) - 3601, TICK_200, 1e18);
        h.obsIndex = _seedWindow(e, TICK_200);
        vm.warp(e + 60);
        _usdgFresh();
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h);
        assertTrue(ok);
        assertEq(reason, 0);
    }

    function test_path2_reason_LIQUIDITY_thinWindow() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        uint32[5] memory offsets = [uint32(3600), 2400, 1200, 600, 120];
        for (uint256 i; i < offsets.length; ++i) {
            pool.write(uint32(e) - offsets[i], TICK_200, 1e18);
        }
        h.obsIndex = pool.observationIndex();
        vm.warp(e + 60);
        _usdgFresh();
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("LIQUIDITY"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    function test_path2_reason_OBSERVATIONS_quietPool() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        // only two swaps inside the window (minObservationsInWindow = 3)
        pool.write(uint32(e) - 1800, TICK_200, POOL_LIQ);
        pool.write(uint32(e) - 300, TICK_200, POOL_LIQ);
        h.obsIndex = pool.observationIndex();
        vm.warp(e + 60);
        _usdgFresh();
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("OBSERVATIONS"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    function test_path2_reason_OBSERVATIONS_lastObsTooOld() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        pool.write(uint32(e) - 3000, TICK_200, POOL_LIQ);
        pool.write(uint32(e) - 2000, TICK_200, POOL_LIQ);
        pool.write(uint32(e) - 1000, TICK_200, POOL_LIQ); // newest is 1000 s > 900 s before expiry
        h.obsIndex = pool.observationIndex();
        vm.warp(e + 60);
        _usdgFresh();
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("NO_ROUND"));
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("OBSERVATIONS"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    /// D-053: a wrong observation hint can only make the TWAP path fail, never pass; the right one settles.
    function test_path2_observationHintCannotHelp() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        uint16 good = h.obsIndex;
        pool.write(uint32(block.timestamp), TICK_200, POOL_LIQ); // a swap after expiry
        h.obsIndex = pool.observationIndex(); // after the anchor: rejected
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("NO_ROUND"));
        h.obsIndex = good - 4; // the first swap of the window: only one observation counted from there
        (ok,,,) = oracle.previewSettle(id, h);
        assertFalse(ok);
        h.obsIndex = 999; // uninitialised slot
        (ok,,,) = oracle.previewSettle(id, h);
        assertFalse(ok);
        h.obsIndex = good;
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 2);
    }

    function test_path2_reason_USDG_STALE_and_OUT_OF_BAND() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        _usdgAt(1e8, block.timestamp - 26 hours - 1);
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("NO_ROUND"));
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("USDG_STALE"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
        _usdgAt(0.98e8 - 1, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.NoOraclePath.selector, bytes32("USDG_OUT_OF_BAND"), bytes32("NO_ROUND")
            )
        );
        oracle.settle(id, h);
        _usdgAt(1.02e8 + 1, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.NoOraclePath.selector, bytes32("USDG_OUT_OF_BAND"), bytes32("NO_ROUND")
            )
        );
        oracle.settle(id, h);
        _usdgAt(0.98e8, block.timestamp);
        oracle.settle(id, h);
        assertApproxEqRel(vault.series(id).settlementPrice, 196e8, 0.0002e18, "band edge accepted");
    }

    function test_path2_reason_BOUND() public {
        // TWAP 20 % below Friday's round: outside the 15 % weekend bound
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200 + 2_232);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("BOUND"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    function test_path2_weekdayBoundIs3pct() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, PRICE);
        // TWAP ≈ 4 % below: fails the 300 bps weekday bound although inside the weekend bound
        uint16 obs = _seedWindow(e, TICK_200 + 400);
        vm.warp(e + 60);
        _usdgFresh();
        ISettlementOracle.Hint memory h = _hint(stale);
        h.obsIndex = obs;
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("STALE"), bytes32("BOUND"))
        );
        oracle.settle(id, h);
    }

    /// T-09 analogue: a negative average tick rounds toward −∞ (stock = token0 pools sit at negative ticks).
    function test_T09_negativeTickRoundsTowardNegInfinity() public {
        (CoveredCallVault v, MockStockToken s) = _newVault(address(oracle), address(rm), true);
        MockUniswapV3Pool pSpy =
            new MockUniswapV3Pool(address(s), address(usdg), 500, -TICK_200, 1e19, uint32(START_TS));
        vm.prank(admin);
        oracle.registerVault(address(v), address(feed), address(pSpy));
        for (uint256 t = START_TS + 1 hours; t <= block.timestamp; t += 1 hours) {
            pSpy.write(uint32(t), -TICK_200, 1e19);
        }
        // alternate ticks so the cumulative delta is not divisible by the window
        pSpy.write(uint32(block.timestamp) - 1799, -TICK_200 - 1, 1e19);
        pSpy.write(uint32(block.timestamp) - 1000, -TICK_200, 1e19);
        pSpy.write(uint32(block.timestamp) - 100, -TICK_200 - 1, 1e19);
        (uint256 usdg8,, bytes32 reason) = oracle.twap(address(v), 1800);
        assertEq(reason, 0);
        // floor(avg tick) = −TICK_200 − 1 → price slightly below the $200 tick price
        uint256 atFloor = _priceAtTickToken0(-TICK_200 - 1);
        assertEq(usdg8, atFloor, "rounded toward negative infinity");
    }

    function _priceAtTickToken0(int24 t) internal pure returns (uint256) {
        return OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(t), false, 18, 6);
    }

    // ═════════════════════════════ path 3 (weekend Chainlink first-after) ═════════════════════════════

    function _weekendNoTwap() internal returns (uint256 id, ISettlementOracle.Hint memory h, uint64 e) {
        id = _liveWeekend();
        e = vault.series(id).expiry;
        h = _hint(feed.roundId(1, nextAgg - 1));
    }

    function test_settle_path3_happy() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 600, 205e8);
        vm.warp(e + 700);
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.PathRejected(id, 2, "OBSERVATIONS");
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.Settled(id, 3, 205e8, h.afterRoundId);
        oracle.settle(id, h);
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(s.settlementPath, 3);
        assertEq(s.settlementPrice, 205e8);
        assertEq(s.payoutPerOption, _ppo(205e8, s.strike));
    }

    function test_settle_path3_badHints() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        uint80 first = _feedRoundAt(e + 600, 205e8);
        uint80 second = _feedRoundAt(e + 1200, 206e8);
        vm.warp(e + 1300);
        h.afterRoundId = second;
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadAfterRoundHint.selector, second));
        oracle.settle(id, h);
        h.afterRoundId = h.refRoundId; // before expiry
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadAfterRoundHint.selector, h.refRoundId));
        oracle.settle(id, h);
        h.afterRoundId = first;
        oracle.settle(id, h);
    }

    function test_settle_path3_deadlineBoundary() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 54_061, 205e8);
        vm.warp(e + 54_100);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("GRACE"), bytes32("DEADLINE"))
        );
        oracle.settle(id, h);
        (uint256 id2, ISettlementOracle.Hint memory h2, uint64 e2) = _prepareSecondWeekend();
        h2.afterRoundId = _feedRoundAt(e2 + 54_060, 205e8);
        vm.warp(e2 + 54_100);
        oracle.settle(id2, h2);
        assertEq(vault.series(id2).settlementPath, 3, "exactly Monday 15:00 UTC is accepted");
    }

    /// @dev After a halted/failed weekend series the vault stays LIVE; resolve it by timelock so a second weekend
    /// series can be opened the following week.
    function _prepareSecondWeekend() internal returns (uint256 id, ISettlementOracle.Hint memory h, uint64 e) {
        uint256 prev = vault.currentSeriesId();
        ISettlementOracle.Hint memory hp = _hint(feed.roundId(1, nextAgg - 1));
        hp.afterRoundId = 0;
        // halt (past the deadline, first-after beyond it) and resolve by timelock
        oracle.halt(prev, _haltHintFirstAfterBeyondDeadline(prev));
        vm.prank(admin);
        oracle.resolveHalted(prev, uint128(PRICE), "ipfs://evidence");
        vm.prank(guardianHot);
        rm.unpauseNewAuctions(address(vault));
        // next weekend
        vm.warp(_nextMonday1400(block.timestamp));
        _feedRoundAt(block.timestamp - 1 hours, PRICE);
        vm.warp(_fridayExpiry() + 1 hours);
        _feedRoundAt(block.timestamp - 30 minutes, PRICE);
        id = _openWeekend(500, RESERVE);
        _bid(mm1, id, 100e18, 2e6);
        _clear(id);
        e = vault.series(id).expiry;
        h = _hint(feed.roundId(1, nextAgg - 1));
    }

    function _haltHintFirstAfterBeyondDeadline(uint256 id) internal view returns (ISettlementOracle.Hint memory h) {
        h.refRoundId = oracle.records(id).roundId; // unused
        uint64 e = vault.series(id).expiry;
        // the only round after expiry in these tests is the one posted at e + 54_061
        for (uint64 i = nextAgg - 1; i > 0; --i) {
            (,,, uint256 upd,) = feed.getRoundData(feed.roundId(1, i));
            if (upd <= e) {
                h.refRoundId = feed.roundId(1, i);
                h.afterRoundId = feed.roundId(1, i + 1);
                break;
            }
        }
    }

    function test_settle_path3_invalidAnswer() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 600, 0);
        vm.warp(e + 700);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.NoOraclePath.selector, bytes32("OBSERVATIONS"), bytes32("INVALID_ANSWER")
            )
        );
        oracle.settle(id, h);
    }

    /// T-02: phase boundary on path 3. Round (2,1) is first-after only with the last phase-1 round as prev hint.
    function test_T02_path3_phaseBoundary() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        uint80 last1 = h.refRoundId;
        uint80 first2 = _feedRoundAtPhase(2, 1, e + 600, 205e8);
        vm.warp(e + 700);
        h.afterRoundId = first2;
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadAfterRoundHint.selector, first2));
        oracle.settle(id, h); // prev hint required
        h.afterPrevRoundId = feed.roundId(1, 1); // not adjacent: phase 1 continues after it
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadAfterRoundHint.selector, first2));
        oracle.settle(id, h);
        h.afterPrevRoundId = last1;
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPrice, 205e8);
        assertEq(oracle.records(id).roundId, first2);
    }

    function test_T05_weekendPastGraceFallsToPath3() public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReady(TICK_200);
        uint64 e = vault.series(id).expiry;
        h.afterRoundId = _feedRoundAt(e + 1900, 204e8);
        vm.warp(e + 2000);
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 3);
    }

    // ═════════════════════════════ sequencer hook (D-005) ═════════════════════════════

    function test_T05_sequencerHook() public {
        OracleParams memory p = _params();
        p.sequencerFeed = address(seqFeed);
        _setParams(p);
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 refId = _feedRoundAt(e - 1 hours, PRICE);
        vm.warp(e);
        seqFeed.setRound(1, 1, e - 2 days, e - 2 days); // down
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("SEQUENCER_DOWN")));
        oracle.settle(id, _hint(refId));
        seqFeed.setRound(2, 0, e - 100, e - 100); // up for 100 s < grace
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("SEQUENCER_DOWN")));
        oracle.settle(id, _hint(refId));
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(refId));
        assertFalse(ok);
        seqFeed.setDead(true);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("SEQUENCER_DOWN")));
        oracle.settle(id, _hint(refId));
        seqFeed.setDead(false);
        seqFeed.setRound(3, 0, e - 3600, e - 3600); // up for exactly the grace
        oracle.settle(id, _hint(refId));
        assertEq(vault.series(id).settlementPath, 1);
        reason; // silence
    }

    function test_sequencerHook_disabledByDefault() public view {
        assertEq(_params().sequencerFeed, address(0));
    }

    // ═════════════════════════════ halt (SPEC §9.6) ═════════════════════════════

    function test_halt_weekday_conditions() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 fresh = _feedRoundAt(e - 1 hours, PRICE);
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(fresh));
        assertFalse(ok);
        assertEq(reason, bytes32("NOT_EXPIRED"));
        vm.warp(e + 1);
        (ok, reason) = oracle.canHalt(id, _hint(fresh));
        assertEq(reason, bytes32("TWAP_GRACE_OPEN"));
        vm.warp(e + 1801);
        (ok, reason) = oracle.canHalt(id, _hint(fresh));
        assertFalse(ok);
        assertEq(reason, bytes32("PATH_AVAILABLE"), "a fresh round means settle, not halt");
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.CannotHalt.selector, bytes32("PATH_AVAILABLE")));
        oracle.halt(id, _hint(fresh));
        oracle.settle(id, _hint(fresh));
    }

    function test_halt_weekday_staleRound() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, 190e8);
        vm.warp(e + 1801);
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(stale));
        assertTrue(ok);
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.SeriesHalted(id, "NO_ORACLE_PATH", 190e8);
        oracle.halt(id, _hint(stale));
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.HALTED));
        assertEq(uint8(vault.state()), uint8(VaultState.HALTED));
        assertTrue(rm.auctionsPaused(address(vault)), "halt pauses new auctions");
        assertFalse(rm.depositsPaused(address(vault)));
        (uint256 sid, bytes32 r,) = rm.lastHalt(address(vault));
        assertEq(sid, id);
        assertEq(r, bytes32("NO_ORACLE_PATH"));
        ISettlementOracle.SeriesRecord memory rec = oracle.records(id);
        assertTrue(rec.halted);
        assertEq(rec.resolveRef, 190e8, "resolveRef = refRound.answer (any age)");
        assertEq(rec.haltReason, bytes32("NO_ORACLE_PATH"));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.CannotHalt.selector, bytes32("NOT_LIVE")));
        oracle.halt(id, _hint(stale));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("NOT_LIVE")));
        oracle.settle(id, _hint(stale));
    }

    function test_halt_weekday_jumpGuard() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 wild = _feedRoundAt(e - 1 hours, 400e8);
        vm.warp(e + 1801);
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(wild));
        assertTrue(ok);
        assertEq(reason, bytes32("JUMP_GUARD"));
        oracle.halt(id, _hint(wild));
        assertEq(oracle.records(id).resolveRef, 400e8, "band is anchored on the (rejected) refRound, bounded to +-25 %");
    }

    function test_halt_noRefRound_usesSRef() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        for (uint64 i = 1; i < nextAgg; ++i) {
            feed.deleteRound(feed.roundId(1, i));
        }
        feed.setRound(feed.roundId(1, 1), int256(PRICE), e + 5);
        feed.setLatest(feed.roundId(1, 1));
        vm.warp(e + 1801);
        oracle.halt(id, _hint(0));
        assertEq(oracle.records(id).resolveRef, PRICE, "sRef");
    }

    function test_halt_weekend_conditions() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        vm.warp(e + 54_060);
        (bool ok, bytes32 reason) = oracle.canHalt(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("DEADLINE_OPEN"));
        vm.warp(e + 54_061);
        (ok, reason) = oracle.canHalt(id, h);
        assertTrue(ok);
        assertEq(reason, bytes32("NO_ORACLE_PATH"), "no round after expiry at all");
        // a round after expiry exists: the hint is required, then judged against the deadline
        uint80 late = _feedRoundAt(e + 54_061, PRICE);
        (ok, reason) = oracle.canHalt(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("AFTER_HINT_REQUIRED"));
        h.afterRoundId = late;
        (ok, reason) = oracle.canHalt(id, h);
        assertTrue(ok);
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
        oracle.halt(id, h);
        assertEq(oracle.records(id).resolveRef, PRICE);
    }

    function test_halt_weekend_path3StillAvailable() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 600, 205e8);
        vm.warp(e + 60_000);
        (bool ok, bytes32 reason) = oracle.canHalt(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("PATH_AVAILABLE"));
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 3, "a round inside the deadline settles even when called late");
    }

    function test_halt_weekend_jumpGuard() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 600, 400e8);
        vm.warp(e + 54_061);
        (bool ok, bytes32 reason) = oracle.canHalt(id, h);
        assertTrue(ok);
        assertEq(reason, bytes32("JUMP_GUARD"));
        oracle.halt(id, h);
        assertEq(oracle.records(id).resolveRef, PRICE, "refRound (Friday), not the wild round");
    }

    /// D-053 backstop: an oracle pause that never lifts cannot lock the vault; 7 days after expiry anyone halts.
    function test_halt_backstop_oraclePaused() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 refId = _feedRoundAt(e - 1 hours, PRICE);
        vm.prank(admin);
        stock.setOraclePaused(true);
        vm.warp(e + 1801);
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(refId));
        assertFalse(ok);
        assertEq(reason, bytes32("ORACLE_PAUSED"));
        vm.warp(e + 7 days - 1);
        (ok,) = oracle.canHalt(id, _hint(refId));
        assertFalse(ok);
        vm.warp(e + 7 days);
        (ok, reason) = oracle.canHalt(id, _hint(refId));
        assertTrue(ok);
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
        oracle.halt(id, _hint(refId));
    }

    // ═════════════════════════════ resolution (D-022, D-033) ═════════════════════════════

    function _halted() internal returns (uint256 id, uint64 e) {
        id = _liveWeekday();
        e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, PRICE);
        vm.warp(e + 1801);
        oracle.halt(id, _hint(stale));
    }

    function test_resolveHalted_bandAndOwner() public {
        (uint256 id,) = _halted();
        (uint256 lo, uint256 hi) = oracle.resolutionBand(id);
        assertEq(lo, 150e8);
        assertEq(hi, 250e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.resolveHalted(id, 200e8, "x");
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.OutOfResolutionBand.selector, 250e8 + 1, lo, hi));
        oracle.resolveHalted(id, 250e8 + 1, "x");
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.OutOfResolutionBand.selector, 150e8 - 1, lo, hi));
        oracle.resolveHalted(id, 150e8 - 1, "x");
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.SeriesResolved(id, 250e8, "ipfs://evidence");
        oracle.resolveHalted(id, 250e8, "ipfs://evidence");
        vm.stopPrank();
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(uint8(s.state), uint8(SeriesState.RESOLVED));
        assertEq(s.settlementPath, 4);
        assertEq(s.payoutPerOption, _ppo(250e8, K_DEFAULT), "worst case (250 - 216) / 250 = 13.6 %");
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        assertEq(oracle.records(id).path, 4);
    }

    function test_resolveHalted_notHalted() public {
        uint256 id = _liveWeekday();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotHalted.selector, id));
        oracle.resolveHalted(id, 200e8, "x");
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotHalted.selector, id));
        oracle.resolutionBand(id);
    }

    function test_resolveHaltedByOracle_timingAndClamp() public {
        (uint256 id, uint64 e) = _halted();
        uint80 after_ = _feedRoundAt(e + 2 days, 600e8);
        (bool ok, uint64 unlockAt) = oracle.canResolveByOracle(id);
        assertFalse(ok);
        assertEq(unlockAt, e + 7 days);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.TooEarly.selector, e + 7 days));
        oracle.resolveHaltedByOracle(id, after_, 0);
        vm.warp(e + 7 days);
        (ok,) = oracle.canResolveByOracle(id);
        assertTrue(ok);
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.SeriesResolvedByOracle(id, 600e8, 250e8, after_);
        vm.prank(alice); // anyone
        oracle.resolveHaltedByOracle(id, after_, 0);
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(s.settlementPath, 5);
        assertEq(s.settlementPrice, 250e8, "clamped to the top of the band");
        assertEq(uint8(s.state), uint8(SeriesState.RESOLVED));
    }

    function test_resolveHaltedByOracle_clampLowAndInside() public {
        (uint256 id, uint64 e) = _halted();
        uint80 low = _feedRoundAt(e + 1 days, 10e8);
        vm.warp(e + 7 days);
        oracle.resolveHaltedByOracle(id, low, 0);
        assertEq(vault.series(id).settlementPrice, 150e8, "clamped to the bottom");

        // second series, in-band value passes through unchanged
        vm.warp(_nextMonday1400(block.timestamp));
        _feedRoundAt(block.timestamp - 1 hours, PRICE);
        vm.prank(admin);
        rm.unpauseNewAuctions(address(vault));
        uint256 id2 = _openDefault();
        _bid(mm1, id2, 100e18, 2e6);
        _clear(id2);
        uint64 e2 = vault.series(id2).expiry;
        uint80 stale = _feedRoundAt(e2 - 27 hours, PRICE);
        vm.warp(e2 + 1801);
        oracle.halt(id2, _hint(stale));
        uint80 inside = _feedRoundAt(e2 + 3 days, 222e8);
        vm.warp(e2 + 7 days);
        oracle.resolveHaltedByOracle(id2, inside, 0);
        assertEq(vault.series(id2).settlementPrice, 222e8);
    }

    function test_resolveHaltedByOracle_guards() public {
        (uint256 id, uint64 e) = _halted();
        uint80 first = _feedRoundAt(e + 1 days, 210e8);
        uint80 second = _feedRoundAt(e + 2 days, 205e8);
        vm.warp(e + 7 days);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadAfterRoundHint.selector, second));
        oracle.resolveHaltedByOracle(id, second, 0); // the hint must be the first round after expiry
        vm.prank(admin);
        stock.setOraclePaused(true);
        (bool ok,) = oracle.canResolveByOracle(id);
        assertFalse(ok);
        (ok,) = oracle.previewResolveByOracle(id, first, 0);
        assertFalse(ok);
        vm.expectRevert(SettlementOracle.OraclePaused.selector);
        oracle.resolveHaltedByOracle(id, first, 0);
        vm.prank(admin);
        stock.setOraclePaused(false);
        vm.prank(admin);
        oracle.resolveHalted(id, 200e8, "timelock");
        assertEq(vault.series(id).settlementPath, 4);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotHalted.selector, id));
        oracle.resolveHaltedByOracle(id, first, 0);
    }

    /// D-057 (review finding 2), SPEC §9.6 "the first **valid** round after expiry": a garbage round published right
    /// after expiry must not kill the permissionless resolution, which is the whole point of D-033 / I-14.
    function test_T14_resolveHaltedByOracle_skipsGarbageFirstAfter() public {
        (uint256 id, uint64 e) = _halted();
        uint80 garbage = _feedRoundAt(e + 1 hours, 0);
        uint80 good = _feedRoundAt(e + 2 hours, 210e8);
        vm.warp(e + 7 days);
        (bool ok, uint256 price8) = oracle.previewResolveByOracle(id, garbage, 0);
        assertTrue(ok, "preview: resolvable through the garbage round");
        assertEq(price8, 210e8);
        // a hint that skips the garbage round on the caller's side is still rejected: the hint is a position claim
        (ok,) = oracle.previewResolveByOracle(id, good, 0);
        assertFalse(ok);
        vm.prank(bob);
        oracle.resolveHaltedByOracle(id, garbage, 0);
        assertEq(vault.series(id).settlementPath, 5);
        assertEq(vault.series(id).settlementPrice, 210e8);
        assertEq(oracle.records(id).roundId, good, "the round actually used is recorded");
    }

    /// Same skip on path 3: a garbage first-after round must not remove the weekend fallback.
    function test_settle_path3_skipsGarbageFirstAfter() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 300, 0);
        uint80 good = _feedRoundAt(e + 600, 204e8);
        vm.warp(e + 700);
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 3);
        assertEq(vault.series(id).settlementPrice, 204e8);
        assertEq(oracle.records(id).roundId, good);
    }

    /// D-057 (review finding 1): a run of invalid rounds longer than MAX_GARBAGE_SKIP makes every hint
    /// unverifiable, so `settle` and the normal `halt` both refuse — but the 7-day backstop still frees the vault
    /// and depositors get their collateral back. Before the fix the series stayed LIVE forever.
    function test_T14_longGarbageRunCannotBrickTheVault() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 good = _feedRoundAt(e - 2 hours, PRICE);
        for (uint256 i; i < 40; ++i) {
            _feedRoundAt(e - 2 hours + 60 * (i + 1), 0);
        }
        vm.warp(e + 1801);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, good));
        oracle.settle(id, _hint(good));
        vm.expectRevert(SettlementOracle.RefRoundRequired.selector);
        oracle.settle(id, _hint(0));
        vm.expectRevert(SettlementOracle.RefRoundRequired.selector);
        oracle.canHalt(id, _hint(0)); // before the backstop an unusable hint is an error, not a halt

        vm.warp(e + 7 days);
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(0));
        assertTrue(ok, "backstop: unverifiable hints count as no path");
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
        vm.prank(bob);
        oracle.halt(id, _hint(0));
        assertEq(oracle.records(id).resolveRef, PRICE, "resolveRef falls back to sRef");
        uint80 after_ = _feedRoundAt(e + 7 days, 205e8);
        vm.prank(bob);
        oracle.resolveHaltedByOracle(id, after_, 0);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    /// The skip bound is 32, so a realistic run of invalid rounds still verifies.
    function test_settle_refHint_skipsLongGarbageRun() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 good = _feedRoundAt(e - 3 hours, 210e8);
        for (uint256 i; i < 20; ++i) {
            _feedRoundAt(e - 3 hours + 60 * (i + 1), 0);
        }
        vm.warp(e);
        oracle.settle(id, _hint(good));
        assertEq(vault.series(id).settlementPrice, 210e8);
    }

    /// D-057 (review finding 3): the backstop is a liveness escape, not a way to replace a working settlement.
    /// With a path still available the 7-day halt is refused and `settle` produces the true price.
    function test_T08_backstopDoesNotPreemptAvailablePath() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r = _feedRoundAt(e - 1 hours, 230e8);
        vm.warp(e + 8 days); // keeper outage well past the backstop
        (bool ok, uint8 path) = _preview(id, r);
        assertTrue(ok);
        assertEq(path, 1);
        (bool canHalt, bytes32 reason) = oracle.canHalt(id, _hint(r));
        assertFalse(canHalt, "a live path is never pre-empted");
        assertEq(reason, bytes32("PATH_AVAILABLE"));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.CannotHalt.selector, bytes32("PATH_AVAILABLE")));
        oracle.halt(id, _hint(r));
        oracle.settle(id, _hint(r));
        assertEq(vault.series(id).settlementPrice, 230e8);
    }

    /// The same for a weekend series whose path-3 round is inside the Monday deadline.
    function test_T08_backstopDoesNotPreemptPath3() public {
        (uint256 id, ISettlementOracle.Hint memory h, uint64 e) = _weekendNoTwap();
        h.afterRoundId = _feedRoundAt(e + 600, 205e8);
        vm.warp(e + 8 days);
        (bool ok, bytes32 reason) = oracle.canHalt(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("PATH_AVAILABLE"));
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 3);
    }

    /// D-057 (review finding 4): "no round at or before expiry" is checked against the feed's registered first
    /// round AND its own latest round, so deleting one round no longer lets a griefer halt a healthy series.
    function test_T08_zeroRefClaimRejectedWhenTheFeedShowsARound() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 good = _feedRoundAt(e - 1 hours, PRICE);
        feed.deleteRound(feed.roundId(1, 1)); // the registered first round becomes unreadable
        vm.warp(e + 1801);
        vm.expectRevert(SettlementOracle.RefRoundRequired.selector);
        oracle.settle(id, _hint(0));
        vm.expectRevert(SettlementOracle.RefRoundRequired.selector);
        oracle.halt(id, _hint(0));
        oracle.settle(id, _hint(good));
        assertEq(vault.series(id).settlementPath, 1);
    }

    /// D-057 (review finding 7): hostile external inputs must fail the guard, not revert it.
    function test_T05_sequencerFutureStartedAtCountsAsDown() public {
        OracleParams memory p = _params();
        p.sequencerFeed = address(seqFeed);
        _setParams(p);
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r = _feedRoundAt(e - 1 hours, PRICE);
        vm.warp(e);
        seqFeed.setRound(1, 0, block.timestamp + 1 days, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NotSettleable.selector, bytes32("SEQUENCER_DOWN")));
        oracle.settle(id, _hint(r));
        vm.warp(e + 7 days);
        seqFeed.setRound(2, 0, block.timestamp + 1 days, block.timestamp); // still reporting a future startedAt
        (bool ok, bytes32 reason) = oracle.canHalt(id, _hint(r));
        assertTrue(ok, "a broken sequencer feed never blocks the backstop");
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
        oracle.halt(id, _hint(r));
        assertEq(uint8(vault.series(id).state), uint8(SeriesState.HALTED));
    }

    function test_T10_absurdMultiplierFailsTheGuardWithoutReverting() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        vm.startPrank(admin);
        stock.stageMultiplier(1, block.timestamp - 1); // m_now = 1 wei: ratio far beyond any corporate action
        stock.applyMultiplier();
        vm.stopPrank();
        uint80 r = _feedRoundAt(e - 1 hours, type(uint128).max);
        vm.warp(e);
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, _hint(r));
        assertFalse(ok, "guard fails instead of reverting on overflow");
        assertEq(reason, bytes32("OBSERVATIONS"));
    }

    /// CLAUDE.md rule 5: the timelock must not be able to strand the contracts.
    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(SettlementOracle.RenounceDisabled.selector);
        oracle.renounceOwnership();
        vm.prank(admin);
        vm.expectRevert(RiskModule.RenounceDisabled.selector);
        rm.renounceOwnership();
        assertEq(oracle.owner(), admin);
        assertEq(rm.owner(), admin);
    }

    /// D-058: TickMath is a deployed library reached by DELEGATECALL, so a deployment that forgets to link it (the
    /// bytecode keeps a placeholder address with no code) or links the wrong contract must fail in the constructor,
    /// not at the first weekend expiry. `address(TickMath)` is the linked address forge deployed for this run.
    function test_D058_constructorRejectsUnlinkedOrWrongTickMath() public {
        address lib = address(TickMath);
        assertGt(lib.code.length, 0, "forge linked the library for the test run");

        // wrong library: returns 0 for every tick (PUSH1 0, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN)
        vm.etch(lib, hex"600060005260206000f3");
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.Miswired.selector, bytes32("TICK_MATH")));
        new SettlementOracle(address(rm), address(ah), address(usdgFeed), admin);

        // unlinked: the placeholder address has no code at all
        vm.etch(lib, hex"");
        vm.expectRevert();
        new SettlementOracle(address(rm), address(ah), address(usdgFeed), admin);
    }

    /// A feed that serves no round at all cannot be registered (D-057).
    function test_registerVault_requiresAReachableFirstRound() public {
        (CoveredCallVault v, MockStockToken s) = _newVault(address(oracle), address(rm), true);
        MockUniswapV3Pool p =
            new MockUniswapV3Pool(address(usdg), address(s), 500, TICK_200, POOL_LIQ, uint32(START_TS));
        MockAggregatorV3 empty = new MockAggregatorV3(8);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.Miswired.selector, bytes32("FEED_FIRST_ROUND")));
        oracle.registerVault(address(v), address(empty), address(p));
        empty.setRound(empty.roundId(3, 1), 200e8, START_TS); // a later phase is found by the probe
        vm.prank(admin);
        oracle.registerVault(address(v), address(empty), address(p));
        assertEq(oracle.vaultConfig(address(v)).firstRound, empty.roundId(3, 1));
    }

    function _preview(uint256 id, uint80 refId) internal view returns (bool ok, uint8 path) {
        (ok,, path,) = oracle.previewSettle(id, _hint(refId));
    }

    // ═════════════════════════════ price views (SPEC §7.2, §12) ═════════════════════════════

    function test_capPrice_chainlinkFresh() public view {
        (uint256 p, bool ok) = oracle.capPrice(address(vault));
        assertTrue(ok);
        assertEq(p, PRICE);
        (p, ok) = oracle.capPrice(alice);
        assertFalse(ok, "unregistered");
    }

    function test_capPrice_80hBoundaryThenTwap() public {
        uint256 last = block.timestamp;
        _feedRoundAt(last, PRICE);
        vm.warp(last + 80 hours - 1);
        (uint256 p, bool ok) = oracle.capPrice(address(vault));
        assertTrue(ok);
        assertEq(p, PRICE);
        vm.warp(last + 80 hours + 4 hours);
        (p, ok) = oracle.capPrice(address(vault));
        assertFalse(ok, "no round < 80 h and a quiet pool");
        // pool activity at now: 30-min TWAP with all checks, converted through USDG/USD
        uint32 now_ = uint32(block.timestamp);
        pool.write(now_ - 1500, TICK_200, POOL_LIQ);
        pool.write(now_ - 900, TICK_200, POOL_LIQ);
        pool.write(now_ - 100, TICK_200, POOL_LIQ);
        _usdgAt(1.005e8, block.timestamp);
        (p, ok) = oracle.capPrice(address(vault));
        assertTrue(ok);
        assertApproxEqRel(p, 201e8, 0.0002e18);
        // deposits work through the cap controller on the TWAP price
        _deposit(alice, 1e18);
    }

    function test_capPrice_neverReverts() public {
        feed.setDead(true);
        pool.setDead(true);
        (uint256 p, bool ok) = oracle.capPrice(address(vault));
        assertFalse(ok);
        assertEq(p, 0);
        usdgFeed.setDead(true);
        (, ok) = oracle.capPrice(address(vault));
        assertFalse(ok);
        assertEq(vault.maxDeposit(alice), 0, "vault views survive a dead price source");
    }

    function test_referencePrice_branches() public {
        (uint256 p, bytes32 src) = oracle.referencePrice(address(vault));
        assertEq(p, PRICE);
        assertEq(src, bytes32("CHAINLINK"));
        vm.prank(admin);
        stock.setOraclePaused(true);
        vm.expectRevert(SettlementOracle.NoReferencePrice.selector);
        oracle.referencePrice(address(vault)); // quiet pool → no TWAP
        uint32 now_ = uint32(block.timestamp);
        pool.write(now_ - 1500, TICK_200, POOL_LIQ);
        pool.write(now_ - 900, TICK_200, POOL_LIQ);
        pool.write(now_ - 100, TICK_200, POOL_LIQ);
        (p, src) = oracle.referencePrice(address(vault));
        assertEq(src, bytes32("TWAP"));
        assertApproxEqRel(p, 200e8, 0.0002e18);
        // TWAP > 15 % away from the last Chainlink answer is refused
        feed.setRound(feed.roundId(1, nextAgg - 1), 300e8, block.timestamp - 1 hours);
        vm.expectRevert(SettlementOracle.NoReferencePrice.selector);
        oracle.referencePrice(address(vault));
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.VaultNotRegistered.selector, alice));
        oracle.referencePrice(alice);
    }

    // ═════════════════════════════ misc ═════════════════════════════

    /// SPEC I-6 / T-11: settlement, halt and resolution move no stock tokens.
    function test_I6_settleHaltResolveMoveNoTokens() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint256 bal = stock.balanceOf(address(vault));
        uint80 stale = _feedRoundAt(e - 27 hours, PRICE);
        vm.warp(e + 1801);
        oracle.halt(id, _hint(stale));
        assertEq(stock.balanceOf(address(vault)), bal, "halt");
        vm.prank(admin);
        oracle.resolveHalted(id, 200e8, "x");
        assertEq(stock.balanceOf(address(vault)), bal, "resolve");
        uint256 id2 = _liveWeekdayAfterUnpause();
        _settleWeekdayPath1(id2, 230e8);
        assertEq(stock.balanceOf(address(vault)), bal, "settle moves nothing; claims do");
        vm.prank(mm1);
        ah.claimOptions(id2, mm1);
        uint256 q = opt.balanceOf(mm1, id2);
        vm.prank(mm1);
        uint256 tokens = opt.claim(id2, q, mm1);
        assertEq(tokens, q * _ppo(230e8, K_DEFAULT) / WAD);
        assertEq(stock.balanceOf(address(vault)), bal - tokens);
    }

    function _liveWeekdayAfterUnpause() internal returns (uint256 id) {
        vm.warp(_nextMonday1400(block.timestamp));
        _feedRoundAt(block.timestamp - 1 hours, PRICE);
        vm.prank(guardianHot);
        rm.unpauseNewAuctions(address(vault));
        id = _openDefault();
        _bid(mm1, id, 100e18, 2e6);
        _clear(id);
    }

    /// Guardian pauses never touch settlement (SPEC §15, T-15).
    function test_T15_guardianCannotStopSettleHaltOrResolve() public {
        uint256 id = _liveWeekday();
        vm.startPrank(guardianCold);
        rm.pauseDeposits(rm.ALL());
        rm.pauseNewAuctions(rm.ALL());
        vm.stopPrank();
        _settleWeekdayPath1(id, 230e8);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        vm.prank(mm1);
        ah.claimOptions(id, mm1);
        uint256 q = opt.balanceOf(mm1, id);
        vm.prank(mm1);
        opt.claim(id, q, mm1);
        // withdrawals stay open in IDLE
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeem(half, alice, alice);
    }
}
