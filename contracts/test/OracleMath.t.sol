// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {OracleMath} from "../src/libraries/OracleMath.sol";

/// @dev TickMath port (D-055) and TWAP arithmetic (SPEC §9.3, §9.5; D-052).
contract OracleMathTest is Test {
    uint256 internal constant Q96 = 2 ** 96;

    // ───────────────────────────── TickMath ─────────────────────────────

    function test_tickMath_knownValues() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(0), uint160(Q96), "tick 0");
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_RATIO, "min");
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_RATIO, "max");
        // SPEC §9.5 check: tick 222534 → 1e12 / 1.0001^222534 ≈ 216.4 (USDG per token, stock = token1)
        uint256 p = OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(222_534), true, 18, 6);
        assertApproxEqRel(p, 216.75e8, 0.001e18, "spec check (1e12 / 1.0001^222534 = 216.75)");
    }

    function sqrtAt(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function test_tickMath_revertsOutOfRange() public {
        vm.expectRevert(abi.encodeWithSelector(TickMath.TickOutOfRange.selector, int24(887_273)));
        this.sqrtAt(887_273);
        vm.expectRevert(abi.encodeWithSelector(TickMath.TickOutOfRange.selector, int24(-887_273)));
        this.sqrtAt(-887_273);
    }

    function testFuzz_tickMath_monotone(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        assertLt(TickMath.getSqrtRatioAtTick(tick), TickMath.getSqrtRatioAtTick(tick + 1));
    }

    /// @dev sqrtP(t)² / sqrtP(t−1)² ≈ 1.0001 for every tick.
    function testFuzz_tickMath_ratioStep(int24 tick) public pure {
        tick = int24(bound(int256(tick), -400_000, 400_000));
        uint256 a = TickMath.getSqrtRatioAtTick(tick);
        uint256 b = TickMath.getSqrtRatioAtTick(tick + 1);
        // (b/a)^2 ≈ 1.0001 → b*b*1e8 / (a*a) ≈ 1.0001e8
        uint256 r = Math.mulDiv(b * b / 1e6, 1e8, a * a / 1e6);
        assertApproxEqAbs(r, 100_010_000, 20, "step");
    }

    // ───────────────────────────── twapTick ─────────────────────────────

    function test_twapTick_roundsTowardNegativeInfinity() public pure {
        assertEq(OracleMath.twapTick(7, 2), 3);
        assertEq(OracleMath.twapTick(-7, 2), -4);
        assertEq(OracleMath.twapTick(-8, 2), -4);
        assertEq(OracleMath.twapTick(0, 2), 0);
    }

    function testFuzz_twapTick_floor(int56 delta, uint32 window) public pure {
        window = uint32(bound(window, 1, 7 days));
        delta = int56(bound(int256(delta), -int256(uint256(window)) * 887_272, int256(uint256(window)) * 887_272));
        int24 t = OracleMath.twapTick(delta, window);
        int256 w = int256(uint256(window));
        assertLe(int256(t) * w, int256(delta), "floor <= delta/w");
        assertGt((int256(t) + 1) * w, int256(delta), "floor+1 > delta/w");
    }

    // ───────────────────────────── depth rule ─────────────────────────────

    function test_sqrtFactor_matchesSpecConstant() public pure {
        assertEq(OracleMath.sqrtFactor1e9(100), 1_004_987_562, "SPEC: sqrt(1.01) - 1 = 4 987 562 / 1e9");
    }

    /// @dev Reference: exact v3 swap amounts for a 1 % price move in the direction that raises the stock price.
    /// USDG = token0 (stock = token1): price of token1 in token0 rises ⇒ sqrtP falls ⇒ Δx = L(1/sqrtP' − 1/sqrtP).
    /// USDG = token1 (stock = token0): sqrtP rises ⇒ Δy = L(sqrtP' − sqrtP).
    function testFuzz_depthRule_matchesSwapAmounts(uint128 l, int24 tick, uint128 notional, bool usdgIsToken0)
        public
        pure
    {
        tick = int24(bound(int256(tick), -300_000, 300_000));
        l = uint128(bound(l, 1e6, type(uint128).max / 1e9));
        notional = uint128(bound(notional, 1, 1e30));
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        // sqrt(1.01) ≈ 1_004_987_562 / 1e9 (floored) → use the same factor as the implementation
        uint256 f = OracleMath.sqrtFactor1e9(100);
        uint256 expectedCap;
        if (usdgIsToken0) {
            // sqrtP' = sqrtP / sqrt(1.01); Δx = L × (1/sqrtP' − 1/sqrtP) = L × (sqrt(1.01) − 1) / sqrtP
            expectedCap = Math.mulDiv(Math.mulDiv(l, f - 1e9, 1e9), Q96, sqrtP);
        } else {
            // sqrtP' = sqrtP × sqrt(1.01); Δy = L × (sqrtP' − sqrtP)
            expectedCap = Math.mulDiv(Math.mulDiv(l, f - 1e9, 1e9), sqrtP, Q96);
        }
        bool ok = OracleMath.depthOk(l, sqrtP, usdgIsToken0, notional, 100);
        assertEq(ok, expectedCap >= notional, "depth rule == swap-amount reference");
    }

    function test_depthRule_orientationDiffers() public pure {
        // sqrtP > 2^96 (tick > 0): token0-side capacity is smaller than token1-side capacity.
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(223_338);
        uint256 l = 1e19;
        assertTrue(OracleMath.depthOk(l, sqrtP, true, 250_000e6, 100), "USDG token0: 1e19 passes");
        assertFalse(OracleMath.depthOk(1e18, sqrtP, true, 250_000e6, 100), "USDG token0: 1e18 fails");
        // For USDG = token1 the same L at the same sqrtP has capacity × sqrtP² / 2^192 (≈ 5e9 ×) more.
        assertTrue(OracleMath.depthOk(1e12, sqrtP, false, 250_000e6, 100), "USDG token1: 1e12 passes");
    }

    // ───────────────────────────── price8 ─────────────────────────────

    /// @dev Both orientations against the SPEC formulas with the ratio computed the other way round.
    function testFuzz_quotePrice8_bothOrderings(int24 tick) public pure {
        tick = int24(bound(int256(tick), -440_000, 440_000));
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint256 ratioX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64); // token1/token0 in Q128
        // stock = token1: price8 = 1e8 × 1e12 × 2^128 / ratioX128
        uint256 refT1 = Math.mulDiv(1e20, 1 << 128, ratioX128);
        // stock = token0: price8 = 1e8 × 1e12 × ratioX128 / 2^128
        uint256 refT0 = Math.mulDiv(1e20, ratioX128, 1 << 128);
        uint256 t1 = OracleMath.quotePrice8(sqrtP, true, 18, 6);
        uint256 t0 = OracleMath.quotePrice8(sqrtP, false, 18, 6);
        if (refT1 > 1e6) assertApproxEqRel(t1, refT1, 1e12, "token1 orientation");
        if (refT0 > 1e6) assertApproxEqRel(t0, refT0, 1e12, "token0 orientation");
    }

    /// @dev Orientation symmetry: the pool with the tokens swapped sits at −tick and must quote the same price.
    function testFuzz_quotePrice8_symmetry(int24 tick) public pure {
        tick = int24(bound(int256(tick), -440_000, 440_000));
        uint256 a = OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(tick), true, 18, 6);
        uint256 b = OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(-tick), false, 18, 6);
        if (a > 1e6) assertApproxEqRel(a, b, 1e12, "symmetry");
    }

    function test_quotePrice8_200dollars() public pure {
        uint256 p = OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(223_338), true, 18, 6);
        assertApproxEqRel(p, 200e8, 0.0002e18, "tick 223338 ~ $200");
    }

    // ───────────────────────────── withinBps / clamp ─────────────────────────────

    function testFuzz_withinBps(uint128 v, uint128 r, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, 9_999));
        bool expected =
            r != 0 && uint256(v) * 1e4 >= uint256(r) * (1e4 - bps) && uint256(v) * 1e4 <= uint256(r) * (1e4 + bps);
        assertEq(OracleMath.withinBps(v, r, bps), expected);
    }

    function testFuzz_clamp(uint256 v, uint256 lo, uint256 hi) public pure {
        if (lo > hi) (lo, hi) = (hi, lo);
        uint256 c = OracleMath.clamp(v, lo, hi);
        assertGe(c, lo);
        assertLe(c, hi);
        if (v >= lo && v <= hi) assertEq(c, v);
    }

    // ───────────────────────────── harmonic liquidity ─────────────────────────────

    /// @dev Piecewise-constant liquidity L1 for t1 seconds and L2 for t2 seconds: L_avg = (t1+t2) / (t1/L1 + t2/L2).
    function testFuzz_harmonicLiquidity(uint128 l1, uint128 l2, uint32 t1, uint32 t2) public pure {
        l1 = uint128(bound(l1, 1e6, 1e30));
        l2 = uint128(bound(l2, 1e6, 1e30));
        t1 = uint32(bound(t1, 1, 1 days));
        t2 = uint32(bound(t2, 1, 1 days));
        uint160 spl = uint160((uint256(t1) << 128) / l1 + (uint256(t2) << 128) / l2);
        uint256 got = OracleMath.harmonicLiquidity(t1 + t2, spl);
        uint256 expected = Math.mulDiv(uint256(t1) + t2, uint256(l1) * l2, uint256(t1) * l2 + uint256(t2) * l1);
        assertApproxEqRel(got, expected, 1e12, "harmonic mean");
    }
}
