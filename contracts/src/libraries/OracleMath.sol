// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OracleMath
/// @notice TWAP arithmetic for SettlementOracle (SPEC §9.3, §9.5; D-018, D-052). Pure functions, no assembly.
library OracleMath {
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant Q128 = 2 ** 128;
    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant BPS = 1e4;

    /// @notice Time-weighted average tick over `window` seconds, rounded toward negative infinity
    /// (Uniswap OracleLibrary.consult convention).
    function twapTick(int56 tickCumulativeDelta, uint32 window) internal pure returns (int24 tick) {
        int56 w = int56(uint56(window));
        int56 t = tickCumulativeDelta / w;
        if (tickCumulativeDelta < 0 && tickCumulativeDelta % w != 0) t--;
        tick = int24(t);
    }

    /// @notice Harmonic-mean in-range liquidity over the window: `(window << 128) / Δ secondsPerLiquidityX128`
    /// (D-018). Reverts on a zero delta, which is impossible for `window > 0`.
    function harmonicLiquidity(uint32 window, uint160 secondsPerLiquidityDelta) internal pure returns (uint256) {
        return (uint256(window) << 128) / uint256(secondsPerLiquidityDelta);
    }

    /// @notice `√(1 + impactBps/1e4) × 1e9`, floored. 100 bps → 1_004_987_562 (SPEC §9.3 writes √1.01 − 1 as
    /// 4 987 562 / 1e9).
    function sqrtFactor1e9(uint16 impactBps) internal pure returns (uint256) {
        return Math.sqrt((BPS + impactBps) * 1e14);
    }

    /// @notice USDG needed to raise the stock price by `impactBps` given the average in-range liquidity, compared
    /// with `notional` (SPEC §9.3, corrected per orientation in D-052):
    /// - USDG = token0 (stock = token1): Δx = L × (√(1+i) − 1) × 2^96 / sqrtP  (buying token1 lowers sqrtP);
    /// - USDG = token1 (stock = token0): Δy = L × (√(1+i) − 1) × sqrtP / 2^96  (buying token0 raises sqrtP).
    function depthOk(uint256 lAvg, uint160 sqrtPriceX96, bool usdgIsToken0, uint256 notional, uint16 impactBps)
        internal
        pure
        returns (bool)
    {
        if (sqrtPriceX96 == 0) return false;
        uint256 lhs = Math.mulDiv(lAvg, sqrtFactor1e9(impactBps) - 1e9, 1e9);
        uint256 capacity = usdgIsToken0 ? Math.mulDiv(lhs, Q96, sqrtPriceX96) : Math.mulDiv(lhs, sqrtPriceX96, Q96);
        return capacity >= notional;
    }

    /// @notice USDG per one stock token at `sqrtPriceX96`, 8 decimals (SPEC §9.5; D-052 fixes the token0 sign):
    /// - stock = token1: `price8 = 1e8 × 10^(dS−dU) × 2^192 / sqrtP²`;
    /// - stock = token0: `price8 = 1e8 × 10^(dS−dU) × sqrtP² / 2^192`.
    /// Uses the OracleLibrary two-branch technique so `sqrtP²` never overflows.
    function quotePrice8(uint160 sqrtPriceX96, bool stockIsToken1, uint8 stockDecimals, uint8 usdgDecimals)
        internal
        pure
        returns (uint256 price8)
    {
        uint256 base = 1e8 * 10 ** uint256(stockDecimals);
        uint256 div = 10 ** uint256(usdgDecimals);
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            price8 = stockIsToken1 ? Math.mulDiv(base, Q192, ratioX192) : Math.mulDiv(base, ratioX192, Q192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            price8 = stockIsToken1 ? Math.mulDiv(base, Q128, ratioX128) : Math.mulDiv(base, ratioX128, Q128);
        }
        price8 /= div;
    }

    /// @notice `|value / reference − 1| ≤ bps / 1e4`, evaluated without division.
    function withinBps(uint256 value, uint256 ref, uint256 bps) internal pure returns (bool) {
        if (ref == 0) return false;
        uint256 scaled = value * BPS;
        return scaled >= ref * (BPS - bps) && scaled <= ref * (BPS + bps);
    }

    /// @notice Clamp `value` into `[lo, hi]`.
    function clamp(uint256 value, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return value < lo ? lo : (value > hi ? hi : value);
    }
}
