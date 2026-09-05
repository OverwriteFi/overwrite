// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SettlementBaseTest} from "./SettlementBase.t.sol";
import {SettlementOracle} from "../src/SettlementOracle.sol";
import {ISettlementOracle} from "../src/interfaces/ISettlementOracle.sol";
import {ICoveredCallVault} from "../src/interfaces/ICoveredCallVault.sol";
import {OracleMath} from "../src/libraries/OracleMath.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";

/// @dev Fuzz tests for the settlement policy and the payout formula (SPEC §7.1, §9; THREAT-MODEL T-01, T-09, T-10).
contract SettlementOracleFuzzTest is SettlementBaseTest {
    /// @dev Reference payout in plain arithmetic (no mulDiv): S and K are < 2^128 so the product cannot overflow.
    function _refPpo(uint256 s, uint256 k) internal pure returns (uint256) {
        if (s <= k) return 0;
        return (s - k) * 1e18 / s;
    }

    /// T-09: the vault's payout equals the reference `(S − K) × 1e18 / S`, is < 1e18, and every claim pays exactly
    /// `qty × ppo / 1e18`; the total never exceeds the encumbered collateral of the series.
    function testFuzz_T09_payoutMatchesReference(uint128 s, uint16 dist, uint128 fill, uint128 claimQty) public {
        dist = uint16(bound(dist, 300, 1500));
        fill = uint128(bound(fill, 1e18, DEPOSIT));
        // inside the ±30 % jump guard around sRef = 200
        s = uint128(bound(s, 140e8, 260e8));
        _deposit(alice, DEPOSIT);
        uint256 id = _open(dist, RESERVE);
        _bid(mm1, id, fill, 2e6);
        _clear(id);
        ICoveredCallVault.VaultSeries memory before = vault.series(id);
        uint256 encumbered = vault.encumbered();
        assertEq(encumbered, before.filledQty);
        uint256 ta = vault.totalAssets();

        _settleWeekdayPath1(id, s);
        ICoveredCallVault.VaultSeries memory after_ = vault.series(id);
        uint256 ppo = after_.payoutPerOption;
        assertEq(ppo, _refPpo(s, before.strike), "payout formula vs reference");
        assertLt(ppo, 1e18, "always < 1e18");
        uint256 payoutTotal = uint256(before.filledQty) * ppo / 1e18;
        assertEq(vault.payoutOwed(), payoutTotal, "payoutOwed == filled x ppo / 1e18");
        assertLe(payoutTotal, encumbered, "total payout <= encumbered collateral");
        assertLe(payoutTotal, ta, "total payout <= totalAssets at settlement");
        assertEq(vault.encumbered(), 0, "encumbrance released");

        // claim part of the allocation
        vm.prank(mm1);
        ah.claimOptions(id, mm1);
        uint256 held = opt.balanceOf(mm1, id);
        claimQty = uint128(bound(claimQty, 1, held));
        uint256 balBefore = stock.balanceOf(mm1);
        vm.prank(mm1);
        uint256 paid = opt.claim(id, claimQty, mm1);
        assertEq(paid, uint256(claimQty) * ppo / 1e18, "claim pays qty x ppo / 1e18");
        assertEq(stock.balanceOf(mm1) - balBefore, paid);
        assertLe(paid, payoutTotal);
    }

    /// The payout is monotone in S: two series with the same strike, higher settlement price → higher payout.
    function testFuzz_T09_payoutMonotoneInPrice(uint128 s1, uint128 s2) public {
        s1 = uint128(bound(s1, 140e8, 260e8));
        s2 = uint128(bound(s2, 140e8, 260e8));
        if (s1 > s2) (s1, s2) = (s2, s1);
        uint256 id1 = _liveWeekday();
        _settleWeekdayPath1(id1, s1);
        uint256 p1 = vault.series(id1).payoutPerOption;
        vm.warp(_nextMonday1400(block.timestamp));
        _feedRoundAt(block.timestamp - 1 hours, PRICE);
        uint256 id2 = _openDefault();
        _bid(mm1, id2, 100e18, 2e6);
        _clear(id2);
        _settleWeekdayPath1(id2, s2);
        uint256 p2 = vault.series(id2).payoutPerOption;
        assertEq(vault.series(id1).strike, vault.series(id2).strike, "same strike");
        assertLe(p1, p2, "monotone in S");
    }

    /// T-01: path 1 accepts a round iff `expiry − updatedAt <= weekdayMaxStale` (26 h).
    function testFuzz_T01_maxStaleBoundary(uint32 age) public {
        age = uint32(bound(age, 0, 40 hours));
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 r = _feedRoundAt(e - age, PRICE);
        vm.warp(e);
        (bool ok,, uint8 path, bytes32 reason) = oracle.previewSettle(id, _hint(r));
        if (age <= 26 hours) {
            assertTrue(ok);
            assertEq(path, 1);
            oracle.settle(id, _hint(r));
            assertEq(vault.series(id).settlementPath, 1);
        } else {
            assertFalse(ok);
            assertEq(reason, bytes32("OBSERVATIONS"), "path 2 reason (no pool activity)");
            ISettlementOracle.Hint memory hh_1 = _hint(r);
            vm.expectRevert(
                abi.encodeWithSelector(
                    SettlementOracle.NoOraclePath.selector, bytes32("STALE"), bytes32("OBSERVATIONS")
                )
            );
            oracle.settle(id, hh_1);
        }
    }

    /// D-025 / D-051: the jump guard accepts iff |S/sRef − 1| ≤ 30 %, or — after a multiplier change — the
    /// multiplier-adjusted price passes the same test.
    function testFuzz_jumpGuardBoundary(uint128 s, bool split) public {
        s = uint128(bound(s, 50e8, 1_200e8));
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        if (split) {
            vm.startPrank(admin);
            stock.stageMultiplier(4e18, e - 1 days);
            stock.applyMultiplier();
            vm.stopPrank();
        }
        uint80 r = _feedRoundAt(e - 1 hours, s);
        vm.warp(e);
        bool plain = OracleMath.withinBps(s, PRICE, 3_000);
        bool adjusted = split && OracleMath.withinBps(uint256(s) * 1e18 / 4e18, PRICE, 3_000);
        (bool ok,, uint8 path,) = oracle.previewSettle(id, _hint(r));
        assertEq(ok, plain || adjusted, "jump guard");
        if (ok) {
            assertEq(path, 1);
            oracle.settle(id, _hint(r));
            assertEq(vault.series(id).settlementPrice, s, "no strike or price adjustment (D-002)");
        } else {
            ISettlementOracle.Hint memory hh_2 = _hint(r);
            vm.expectRevert(
                abi.encodeWithSelector(
                    SettlementOracle.NoOraclePath.selector, bytes32("JUMP_GUARD"), bytes32("OBSERVATIONS")
                )
            );
            oracle.settle(id, hh_2);
        }
    }

    /// D-033: the permissionless resolution price is always inside the band and equals the clamped answer.
    function testFuzz_resolveClampAlwaysInBand(uint128 answer) public {
        answer = uint128(bound(answer, 1, type(uint128).max / 2));
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 stale = _feedRoundAt(e - 27 hours, 190e8);
        vm.warp(e + 1801);
        oracle.halt(id, _hint(stale));
        (uint256 lo, uint256 hi) = oracle.resolutionBand(id);
        assertEq(lo, 190e8 * 75 / 100);
        assertEq(hi, 190e8 * 125 / 100);
        uint80 after_ = _feedRoundAt(e + 1 days, answer);
        vm.warp(e + 7 days);
        oracle.resolveHaltedByOracle(id, after_, 0);
        uint256 p = vault.series(id).settlementPrice;
        assertGe(p, lo);
        assertLe(p, hi);
        assertEq(p, OracleMath.clamp(answer, lo, hi));
        assertEq(vault.series(id).settlementPath, 5);
        assertLe(vault.series(id).payoutPerOption, _refPpo(hi, K_DEFAULT), "bounded extraction (D-022)");
    }

    /// D-057 (review finding 1): whatever run of invalid rounds the feed emits before expiry, an expired series is
    /// always actionable once the backstop is open — `settle` or `halt` succeeds — so collateral is never locked.
    function testFuzz_T14_garbageRunNeverBricksTheVault(uint8 n) public {
        n = uint8(bound(n, 0, 45));
        uint256 id = _liveWeekday();
        uint64 e = vault.series(id).expiry;
        uint80 good = _feedRoundAt(e - 3 hours, PRICE);
        for (uint256 i; i < n; ++i) {
            _feedRoundAt(e - 3 hours + 60 * (i + 1), 0);
        }
        vm.warp(uint256(e) + 7 days);
        ISettlementOracle.Hint memory h = _hint(n < 32 ? good : 0);
        bool okSettle;
        try oracle.previewSettle(id, h) returns (bool ok, uint256, uint8, bytes32) {
            okSettle = ok;
        } catch {}
        (bool okHalt,) = oracle.canHalt(id, h);
        assertTrue(okSettle || okHalt, "expired series must be settleable or haltable");
        if (okSettle) {
            oracle.settle(id, h);
        } else {
            oracle.halt(id, h);
            uint80 after_ = _feedRoundAt(uint256(e) + 7 days, PRICE);
            oracle.resolveHaltedByOracle(id, after_, 0);
        }
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE), "vault returns to IDLE");
        assertEq(vault.encumbered(), 0);
    }

    /// D-015: `twapUSD = twapUSDG × usdgUsd / 1e8`, rounded down, for every in-band peg read.
    function testFuzz_T09_usdgConversionRoundsDown(uint32 peg) public {
        peg = uint32(bound(peg, 0.98e8, 1.02e8));
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        vm.warp(e + 60);
        _usdgAt(peg, block.timestamp);
        (uint256 usdg8, uint256 usd8, bytes32 reason) = oracle.twap(address(vault), 3600);
        assertEq(reason, 0);
        assertEq(usd8, usdg8 * peg / 1e8, "floor conversion");
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPrice, usd8);
    }

    /// T-03 / T-08: the TWAP is anchored at expiry, so the settlement price does not depend on when inside the
    /// grace window `settle` is called nor on swaps after expiry.
    function testFuzz_T03_windowAnchoredAtExpiry(uint32 delay, int24 driftAfter) public {
        delay = uint32(bound(delay, 1, 1800));
        driftAfter = int24(bound(int256(driftAfter), -5_000, 5_000));
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        vm.warp(e);
        _usdgFresh();
        (bool ok0, uint256 atExpiry,,) = oracle.previewSettle(id, h);
        assertTrue(ok0);
        // manipulation after expiry
        if (delay > 1) pool.write(uint32(e) + 1, TICK_200 + driftAfter, POOL_LIQ);
        vm.warp(e + delay);
        (bool ok, uint256 later,,) = oracle.previewSettle(id, h);
        assertTrue(ok);
        assertEq(later, atExpiry, "price independent of call time and post-expiry swaps");
        oracle.settle(id, h);
        assertEq(vault.series(id).settlementPrice, atExpiry);
    }

    /// T-08: any two valid hints give the same result (weekend: with or without the path-3 hint).
    function testFuzz_T08_hintIndependence(uint32 afterDelay) public {
        afterDelay = uint32(bound(afterDelay, 1, 1700));
        uint256 id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        ISettlementOracle.Hint memory h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        uint80 after_ = _feedRoundAt(e + afterDelay, 300e8); // would settle very differently on path 3
        vm.warp(e + 1750);
        _usdgFresh();
        (, uint256 p1, uint8 path1,) = oracle.previewSettle(id, h);
        h.afterRoundId = after_;
        (, uint256 p2, uint8 path2,) = oracle.previewSettle(id, h);
        assertEq(p1, p2);
        assertEq(path1, path2);
        assertEq(path1, 2);
    }

    /// @dev Audit A-01: whatever cumulatives a pool returns, `previewSettle` and `settle` classify the TWAP path
    /// instead of reverting; an out-of-range average is reported as OBSERVE.
    function testFuzz_path2_neverRevertsOnArbitraryCumulatives(int56 tcDelta, uint160 splDelta) public {
        (uint256 id, ISettlementOracle.Hint memory h) = _weekendReadyFuzz();
        int56[] memory tcs = new int56[](2);
        uint160[] memory spls = new uint160[](2);
        tcs[1] = tcDelta;
        spls[1] = splDelta;
        vm.mockCall(
            address(pool), abi.encodeWithSelector(bytes4(keccak256("observe(uint32[])"))), abi.encode(tcs, spls)
        );
        (bool ok,,, bytes32 reason) = oracle.previewSettle(id, h); // must not revert
        int56 avg = tcDelta / int56(uint56(oracle.TWAP_WINDOW_WEEKEND()));
        if (splDelta == 0 || avg < -887_272 || avg > 887_272) {
            assertFalse(ok);
            assertEq(reason, bytes32("NO_ROUND"), "path 3 has no hint; path 2 failed with OBSERVE");
        }
        vm.clearMockedCalls();
    }

    function _weekendReadyFuzz() internal returns (uint256 id, ISettlementOracle.Hint memory h) {
        id = _liveWeekend();
        uint64 e = vault.series(id).expiry;
        h = _hint(feed.roundId(1, nextAgg - 1));
        h.obsIndex = _seedWindow(e, TICK_200);
        vm.warp(e + 60);
        _usdgFresh();
    }
}
