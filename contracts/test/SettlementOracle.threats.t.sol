// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SettlementBaseTest} from "./SettlementBase.t.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {ICoveredCallVault} from "../src/interfaces/ICoveredCallVault.sol";
import {OracleParams, SeriesState, VaultState} from "../src/Types.sol";

/// @dev THREAT-MODEL regressions for the settlement layer: T-01, T-02, T-03, T-05, T-07, T-08, T-10, T-11, T-12, T-14.
contract SettlementOracleThreatsTest is SettlementBaseTest {
    // ───────────────────────────── T-03: TWAP manipulation ─────────────────────────────

    /// T-03.3 / D-018: an LP that pulls in-range liquidity for the window and re-adds it before the call fails the
    /// time-weighted depth rule even though `pool.liquidity()` at call time is deep.
    function test_T03_liquidityPullDuringWindowRejected() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        pool.pullLiquidity(uint32(e) - 3599);
        pool.write(uint32(e) - 2400, TICK_200, 1);
        pool.write(uint32(e) - 1200, TICK_200, 1);
        pool.write(uint32(e) - 300, TICK_200, 1);
        pool.write(uint32(e) - 1, TICK_200, POOL_LIQ); // re-add just before expiry
        h.obsIndex = pool.observationIndex();
        vm.warp(e + 60);
        _usdgFresh();
        assertEq(pool.liquidity(), POOL_LIQ, "spot liquidity looks deep");
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("LIQUIDITY"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
    }

    /// T-03.4 / D-019: a quiet pool (no swaps in the window) is rejected instead of settling on an extrapolated tick.
    function test_T03_quietPoolFallsThroughToPath3() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.afterRoundId = _feedRoundAt(e + 120, 201e8);
        vm.warp(e + 200);
        _usdgFresh();
        (bool ok, uint256 price8, uint8 path,) = oracle.previewSettle(id, h);
        assertTrue(ok);
        assertEq(path, 3);
        assertEq(price8, 201e8);
        oracle.settle(id, h);
    }

    /// T-03.1: a pump beyond the 15 % bound (vs Friday's round) is rejected; a pump inside the bound is the accepted
    /// exposure (SPEC §9.3 "manipulation exposure"), bounded by caps.
    function test_T03_pumpBeyondBoundRejected_insideBoundAccepted() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200 - 1_800); // ≈ +20 %
        vm.warp(e + 60);
        _usdgFresh();
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.NoOraclePath.selector, bytes32("BOUND"), bytes32("NO_ROUND"))
        );
        oracle.settle(id, h);
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h);
        assertFalse(ok);
        assertEq(reason, bytes32("NO_ROUND"));
    }

    /// The winning bidder's maximum extraction inside the bound: (1.15 − 1.05) / 1.15 ≈ 8.7 % of notional.
    function test_T03_maxExtractionInsideBound() public pure {
        uint256 strike = 210e8; // 5 % OTM
        uint256 pumped = 230e8; // +15 %
        uint256 ppo = (pumped - strike) * 1e18 / pumped;
        assertApproxEqRel(ppo, 0.087e18, 0.01e18, "8.7 % of collateral");
    }

    // ───────────────────────────── T-05: sequencer / timestamp ─────────────────────────────

    /// T-05.4: no observations are written while the chain is down; the TWAP across the gap is rejected instead of
    /// reporting the pre-outage tick as fresh.
    function test_T05_twapAcrossSequencerGapRejected() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        pool.write(uint32(e) - 8 hours, TICK_200, POOL_LIQ); // last swap before a 7 h outage
        h.obsIndex = pool.observationIndex();
        h.afterRoundId = _feedRoundAt(e + 900, 199e8);
        vm.warp(e + 1000);
        _usdgFresh();
        (bool ok,, uint8 path,) = oracle.previewSettle(id, h);
        assertTrue(ok);
        assertEq(path, 3, "falls to the first fresh Chainlink round");
    }

    // ───────────────────────────── T-08: path selection ─────────────────────────────

    /// T-08.2 / D-021: Monday's first round landing inside the grace window does not change the TWAP reference.
    function test_T08_refRoundDoesNotFlipInsideGrace() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        _feedRoundAt(e + 30, 300e8); // Monday's first round, far from the TWAP
        vm.warp(e + 600);
        _usdgFresh();
        (bool ok,, uint8 path,) = oracle.previewSettle(id, h);
        assertTrue(ok, "bound is against Friday's round (refRound), not the latest answer");
        assertEq(path, 2);
        oracle.settle(id, h);
    }

    function test_T08_wrongHintRevertsRightHintSettles() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r1 = _feedRoundAt(e - 3 hours, 220e8);
        uint80 r2 = _feedRoundAt(e - 1 hours, 210e8);
        vm.warp(e);
        ISettlementOracle.Hint memory h_1 = _hint(r1);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BadRefRoundHint.selector, r1));
        oracle.settle(id, h_1); // the keeper cannot pick the more favourable earlier round
        oracle.settle(id, _hint(r2));
        assertEq(vault.series(id).settlementPrice, 210e8);
    }

    // ───────────────────────────── T-10: multiplier change mid-series ─────────────────────────────

    /// T-10 / D-002 / D-025 / D-051. A 4-for-1 split staged and applied after the auction cleared:
    /// (a) feed unchanged (correctly sequenced): settles on path 1 with the payout of the no-split control;
    /// (b) feed ×4 (feed/multiplier mis-sequenced): accepted through the multiplier exception;
    /// (c) feed ×4 without a multiplier change: jump guard trips.
    function test_T10_split4xMidSeries_payoutUnchanged() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint256 control = _ppo(230e8, K_DEFAULT);
        vm.startPrank(admin);
        stock.stageMultiplier(4e18, e - 1 days);
        vm.warp(e - 1 days);
        stock.applyMultiplier();
        vm.stopPrank();
        assertEq(stock.uiMultiplier(), 4e18);
        assertEq(vault.series(id).multiplierAtOpen, 1e18);
        uint80 r = _feedRoundAt(e - 1 hours, 230e8); // raw-token price unchanged by the split
        vm.warp(e);
        oracle.settle(id, _hint(r));
        ICoveredCallVault.VaultSeries memory s = vault.series(id);
        assertEq(s.settlementPath, 1);
        assertEq(s.settlementPrice, 230e8, "no price adjustment");
        assertEq(s.strike, K_DEFAULT, "no strike adjustment");
        assertEq(s.payoutPerOption, control, "payout identical to the no-split control");
    }

    function test_T10_split4x_feedMovedByRatio_acceptedByException() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        vm.startPrank(admin);
        stock.stageMultiplier(4e18, e - 1 days);
        vm.warp(e - 1 days);
        stock.applyMultiplier();
        vm.stopPrank();
        uint80 r = _feedRoundAt(e - 1 hours, 920e8); // feed shows 4x: T-10.2 mis-sequencing
        vm.warp(e);
        (bool ok,, uint8 path,) = oracle.previewSettle(id, _hint(r));
        assertTrue(ok, "920 / 4 = 230 is within 30 % of sRef");
        assertEq(path, 1);
        oracle.settle(id, _hint(r));
        // documented residual (THREAT-MODEL T-10.2): the payout follows the mis-sequenced feed; the keeper alerts
        // on UIMultiplierUpdated and the guardian pauses new auctions until reviewed
        assertEq(vault.series(id).payoutPerOption, _ppo(920e8, K_DEFAULT));
    }

    function test_T10_feedMoved4xWithoutMultiplierChange_tripsGuard() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r = _feedRoundAt(e - 1 hours, 920e8);
        vm.warp(e);
        (bool ok,,,) = oracle.previewSettle(id, _hint(r));
        assertFalse(ok);
        vm.warp(e + 1801);
        (bool canHalt, bytes32 reason) = oracle.canHalt(id, _hint(r));
        assertTrue(canHalt);
        assertEq(reason, bytes32("JUMP_GUARD"));
        oracle.halt(id, _hint(r));
        // resolution stays bounded around the tripped round: (D-022) the timelock can pick at most +25 % of it
        (uint256 lo, uint256 hi) = oracle.resolutionBand(id);
        assertEq(lo, 690e8);
        assertEq(hi, 1_150e8);
    }

    /// T-10 / D-026 / D-042: a staged change inside the series refuses to open; a past `effectiveAt` does not.
    function test_T10_stagedMultiplierChangeBlocksOpen() public {
        _deposit(alice, DEPOSIT);
        uint64 e = _fridayExpiry();
        vm.prank(admin);
        stock.stageMultiplier(4e18, e - 1 hours);
        (bool ok, bytes32 reason) = vault.canOpenAuction(e);
        assertFalse(ok);
        assertEq(reason, bytes32("MULTIPLIER_CHANGE"));
        vm.prank(admin);
        stock.stageMultiplier(4e18, block.timestamp - 1);
        (ok,) = vault.canOpenAuction(e);
        assertTrue(ok, "past effectiveAt is not a staged change");
    }

    // ───────────────────────────── T-11: issuer pause ─────────────────────────────

    /// T-11: settlement is bookkeeping only, so it succeeds while the stock token is paused.
    function test_T11_settleSucceedsWhileTokenPaused() public {
        uint256 id = _liveWeekday();
        vm.prank(admin);
        stock.setPaused(true);
        _settleWeekdayPath1(id, 230e8);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        vm.prank(admin);
        stock.setPaused(false);
    }

    // ───────────────────────────── T-12: USDG depeg ─────────────────────────────

    function test_T12_weekendFallsToPath3OnDepeg() public {
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        h.afterRoundId = _feedRoundAt(e + 300, 202e8);
        vm.warp(e + 400);
        _usdgAt(0.95e8, block.timestamp);
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.PathRejected(id, 2, "USDG_OUT_OF_BAND");
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 3);
        assertEq(vault.series(id).settlementPrice, 202e8, "USD-denominated path unaffected by USDG");
    }

    function test_T12_weekdayHaltsOnDepegWhenTwapIsLastPath() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, PRICE);
        ISettlementOracle.Hint memory h = _hint(stale);
        h.obsIndex = _seedWindow(e, TICK_200);
        vm.warp(e + 60);
        _usdgAt(0.95e8, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.NoOraclePath.selector, bytes32("STALE"), bytes32("USDG_OUT_OF_BAND")
            )
        );
        oracle.settle(id, h);
        vm.warp(e + 1801);
        (bool ok, bytes32 reason) = oracle.canHalt(id, h);
        assertTrue(ok);
        assertEq(reason, bytes32("NO_ORACLE_PATH"));
    }

    /// T-12.5: raising `usdgMaxStale` to 80 h (allowed by the bound) keeps the weekend TWAP alive on a
    /// heartbeat-only peg feed.
    function test_T12_usdgMaxStale80h() public {
        OracleParams memory p = _params();
        p.usdgMaxStale = 80 hours;
        _setParams(p);
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        vm.warp(e + 60);
        _usdgAt(1e8, block.timestamp - 50 hours);
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPath, 2);
    }

    // ───────────────────────────── T-14: admin key ─────────────────────────────

    /// T-14.2 / D-031: a parameter change queued mid-series applies only to later series.
    function test_T14_snapshotProtectsOpenSeries() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        OracleParams memory p = _params();
        p.weekdayMaxStale = 1 hours; // attacker tightens staleness so path 1 always fails on a heartbeat feed
        p.jumpBps = 1_000;
        _setParams(p);
        uint80 r = _feedRoundAt(e - 2 hours, 250e8); // 2 h old, +25 %: fails the new params, passes the snapshot
        vm.warp(e);
        oracle.settle(id, _hint(r));
        assertEq(vault.series(id).settlementPath, 1);
    }

    /// T-14.2 / D-022: the timelock cannot resolve a halted series outside ±25 % of the last oracle price; worst
    /// case extraction with a 8 % OTM strike is (1.25 − 1.08) / 1.25 = 13.6 % of collateral, not ~99 %.
    function test_T14_resolveHaltedBoundedPrice() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, PRICE);
        vm.warp(e + 1801);
        oracle.halt(id, _hint(stale));
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.OutOfResolutionBand.selector, 100 * PRICE, 150e8, 250e8)
        );
        oracle.resolveHalted(id, uint128(100 * PRICE), "attack");
        oracle.resolveHalted(id, 250e8, "max");
        vm.stopPrank();
        uint256 ppo = vault.series(id).payoutPerOption;
        assertEq(ppo, (250e8 - K_DEFAULT) * 1e18 / 250e8);
        assertLt(ppo, 0.14e18, "bounded to 13.6 %");
    }

    /// T-14.7 / D-033 / I-14: with the admin key lost, a halted series still resolves without any key.
    function test_T14_liveNessWithoutKeys() public {
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, PRICE);
        vm.warp(e + 1801);
        ISettlementOracle.Hint memory h_2 = _hint(stale);
        vm.prank(bob);
        oracle.halt(id, h_2);
        uint80 after_ = _feedRoundAt(e + 3 days, 205e8);
        vm.warp(e + 7 days);
        vm.prank(bob);
        oracle.resolveHaltedByOracle(id, after_, 0);
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
    }

    // ───────────────────────────── T-07: gas ─────────────────────────────

    /// T-07: settle on path 2 with the maximum observation requirement and a deep buffer stays far below the block
    /// gas limit (oracle overhead + vault queue processing).
    function test_T07_settleGasBound() public {
        OracleParams memory p = _params();
        p.minObservationsInWindow = 16;
        _setParams(p);
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        for (uint32 i = 20; i > 0; --i) {
            pool.write(uint32(e) - i * 60, TICK_200, POOL_LIQ);
        }
        h.obsIndex = pool.observationIndex();
        vm.warp(e + 60);
        _usdgFresh();
        uint256 g = gasleft();
        oracle.settle(id, h);
        uint256 used = g - gasleft();
        emit log_named_uint("settle path 2 gas (minObs = 16)", used);
        assertLt(used, 1_500_000, "settle path 2 gas");
        assertEq(vault.series(id).settlementPath, 2);
    }
}
