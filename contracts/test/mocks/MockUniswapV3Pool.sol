// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "../../src/libraries/TickMath.sol";

/// @dev Uniswap v3 pool mock with a real observation ring (D-014): `write(ts, tick, liquidityAfter)` appends an
/// observation using the pool's cumulative math (previous tick/liquidity weighted by elapsed time), `observe`
/// extrapolates past the newest entry, interpolates between entries and reverts "OLD" before the oldest, exactly
/// like `Oracle.observeSingle`.
contract MockUniswapV3Pool is IUniswapV3Pool {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    int24 public tick;
    uint128 public liquidity;
    uint16 public observationIndex;
    uint16 public observationCardinality; // grown, as in v3: 1 until the buffer wraps into the reserved capacity
    uint16 public capacity; // observationCardinalityNext
    uint16 public count; // initialized entries
    bool public dead;
    mapping(uint256 => Observation) internal _obs;

    constructor(address token0_, address token1_, uint24 fee_, int24 initialTick, uint128 liquidity_, uint32 ts) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tick = initialTick;
        liquidity = liquidity_;
        observationCardinality = 1;
        capacity = 1000;
        _obs[0] = Observation({
            blockTimestamp: ts, tickCumulative: 0, secondsPerLiquidityCumulativeX128: 0, initialized: true
        });
        count = 1;
    }

    // ───────────────────────────── test controls ─────────────────────────────

    function setCardinality(uint16 c) external {
        require(count == 1 && c >= 1, "set before writes");
        capacity = c;
        observationCardinality = 1;
    }

    function setDead(bool d) external {
        dead = d;
    }

    /// @dev Records a swap at `ts` that leaves the pool at `newTick` with `liquidityAfter` in range. Same-second
    /// writes only update tick/liquidity (v3 writes one observation per block).
    function write(uint32 ts, int24 newTick, uint128 liquidityAfter) public {
        Observation memory last = _obs[observationIndex];
        require(ts >= last.blockTimestamp, "past");
        if (ts > last.blockTimestamp) {
            uint32 dt = ts - last.blockTimestamp;
            // v3 `Oracle.write`: cardinality jumps to cardinalityNext on the write that fills the current ring.
            uint16 card = observationCardinality;
            if (capacity > card && observationIndex == card - 1) {
                card = capacity;
                observationCardinality = card;
            }
            uint16 next = (observationIndex + 1) % card;
            _obs[next] = Observation({
                blockTimestamp: ts,
                tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(dt)),
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                    + uint160((uint256(dt) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
            observationIndex = next;
            if (count < card) count++;
        }
        tick = newTick;
        liquidity = liquidityAfter;
    }

    /// @dev LP pulls (almost) all in-range liquidity at `ts` without moving the price.
    function pullLiquidity(uint32 ts) external {
        write(ts, tick, 1);
    }

    function setLiquidity(uint128 l) external {
        liquidity = l;
    }

    // ───────────────────────────── IUniswapV3Pool ─────────────────────────────

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick_,
            uint16 index,
            uint16 cardinality,
            uint16 cardinalityNext,
            uint8,
            bool
        )
    {
        if (dead) revert("dead");
        return (TickMath.getSqrtRatioAtTick(tick), tick, observationIndex, observationCardinality, capacity, 0, true);
    }

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        if (dead) revert("dead");
        Observation memory o = _obs[index];
        return (o.blockTimestamp, o.tickCumulative, o.secondsPerLiquidityCumulativeX128, o.initialized);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory spls)
    {
        if (dead) revert("dead");
        tickCumulatives = new int56[](secondsAgos.length);
        spls = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            (tickCumulatives[i], spls[i]) = _observeSingle(uint32(block.timestamp) - secondsAgos[i]);
        }
    }

    function increaseObservationCardinalityNext(uint16) external {}

    // ───────────────────────────── internals ─────────────────────────────

    function _oldestIndex() internal view returns (uint16) {
        return count < observationCardinality ? 0 : (observationIndex + 1) % observationCardinality;
    }

    function _observeSingle(uint32 target) internal view returns (int56 tc, uint160 spl) {
        Observation memory last = _obs[observationIndex];
        if (target >= last.blockTimestamp) {
            uint32 dt = target - last.blockTimestamp;
            return (
                last.tickCumulative + int56(tick) * int56(uint56(dt)),
                last.secondsPerLiquidityCumulativeX128 + uint160((uint256(dt) << 128) / (liquidity > 0 ? liquidity : 1))
            );
        }
        Observation memory oldest = _obs[_oldestIndex()];
        require(target >= oldest.blockTimestamp, "OLD");
        // linear search from the oldest for beforeOrAt / atOrAfter
        uint16 idx = _oldestIndex();
        Observation memory before = oldest;
        Observation memory after_ = oldest;
        for (uint256 k; k < count; ++k) {
            Observation memory o = _obs[idx];
            if (o.blockTimestamp <= target) {
                before = o;
            } else {
                after_ = o;
                break;
            }
            idx = (idx + 1) % observationCardinality;
        }
        if (before.blockTimestamp == target) return (before.tickCumulative, before.secondsPerLiquidityCumulativeX128);
        uint32 delta = after_.blockTimestamp - before.blockTimestamp;
        uint32 targetDelta = target - before.blockTimestamp;
        tc = before.tickCumulative + ((after_.tickCumulative - before.tickCumulative) / int56(uint56(delta)))
            * int56(uint56(targetDelta));
        spl = before.secondsPerLiquidityCumulativeX128
            + uint160(
                (uint256(after_.secondsPerLiquidityCumulativeX128 - before.secondsPerLiquidityCumulativeX128)
                        * targetDelta) / delta
            );
    }
}
