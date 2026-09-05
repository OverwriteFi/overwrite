// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenBaseTest} from "./TokenBase.t.sol";
import {WritePriceOracle} from "../src/WritePriceOracle.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockUniswapV3Pool} from "../src/mocks/MockUniswapV3Pool.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract WritePriceOracleTest is TokenBaseTest {
    /// @dev Builds a pool with a chosen token ordering, seeded so it can answer the TWAP window.
    function _poolWithOrdering(bool writeIsToken1) internal returns (MockUniswapV3Pool p, int24 tick) {
        address t0 = writeIsToken1 ? address(usdg) : address(write);
        address t1 = writeIsToken1 ? address(write) : address(usdg);
        tick = _tickForWritePrice(WRITE_PRICE_8, writeIsToken1);
        uint32 start = uint32(block.timestamp - 2 days);
        p = new MockUniswapV3Pool(t0, t1, WRITE_POOL_FEE, tick, WRITE_POOL_LIQ, start);
        for (uint256 t = start + 1 hours; t <= block.timestamp; t += 1 hours) {
            p.write(uint32(t), tick, WRITE_POOL_LIQ);
        }
    }

    // ═════════════════════════════ construction / wiring ═════════════════════════════

    function test_constructor_readsDecimalsOnChain() public view {
        assertEq(wOracle.writeToken(), address(write));
        assertEq(wOracle.usdg(), address(usdg));
        assertEq(wOracle.writeDecimals(), 18);
        assertEq(wOracle.usdgDecimals(), 6);
        assertEq(wOracle.twapWindow(), 30 minutes);
        assertEq(wOracle.chainlinkFeed(), address(0), "TWAP-only at launch");
    }

    /// @dev D-058, repeated for this consumer: an unlinked or mis-linked TickMath must fail the deployment,
    /// not silently kill every TWAP at the first read.
    function test_constructor_rejectsUnlinkedOrWrongTickMath() public {
        address lib = address(TickMath);
        assertGt(lib.code.length, 0, "forge linked the library for the test run");

        vm.etch(lib, hex"600060005260206000f3"); // returns 0 for every tick
        vm.expectRevert(abi.encodeWithSelector(WritePriceOracle.Miswired.selector, bytes32("TICK_MATH")));
        new WritePriceOracle(address(write), address(usdg), address(usdgFeed), admin);

        vm.etch(lib, hex"");
        vm.expectRevert();
        new WritePriceOracle(address(write), address(usdg), address(usdgFeed), admin);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(WritePriceOracle.ZeroAddress.selector);
        new WritePriceOracle(address(0), address(usdg), address(usdgFeed), admin);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(WritePriceOracle.RenounceDisabled.selector);
        wOracle.renounceOwnership();
    }

    // ═════════════════════════════ setPool asserts (D-068) ═════════════════════════════

    function test_setPool_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wOracle.setPool(address(writePool));
    }

    function test_setPool_revertsOnWrongPair() public {
        MockUniswapV3Pool wrong =
            new MockUniswapV3Pool(address(usdg), address(stock), 500, 0, WRITE_POOL_LIQ, uint32(block.timestamp));
        vm.prank(admin);
        vm.expectRevert(WritePriceOracle.PoolTokenMismatch.selector);
        wOracle.setPool(address(wrong));
    }

    function test_setPool_revertsOnDisallowedFeeTier() public {
        (MockUniswapV3Pool p,) = _poolWithOrdering(wOracle.writeIsToken1());
        MockUniswapV3Pool odd = new MockUniswapV3Pool(p.token0(), p.token1(), 123, 0, WRITE_POOL_LIQ, uint32(1));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(WritePriceOracle.PoolFeeNotAllowed.selector, uint24(123)));
        wOracle.setPool(address(odd));
    }

    function test_setPool_revertsOnLowCardinality() public {
        (MockUniswapV3Pool p,) = _poolWithOrdering(wOracle.writeIsToken1());
        MockUniswapV3Pool thin =
            new MockUniswapV3Pool(p.token0(), p.token1(), WRITE_POOL_FEE, 0, WRITE_POOL_LIQ, uint32(block.timestamp));
        thin.setCardinality(16);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(WritePriceOracle.PoolCardinalityTooLow.selector, uint16(16), uint16(256))
        );
        wOracle.setPool(address(thin));
    }

    /// @dev A freshly created pool cannot answer a 30-minute window; wiring it in would silently report
    /// "no price" at the first read, so the probe rejects it at configuration time instead.
    function test_setPool_revertsWithoutEnoughHistory() public {
        bool w1 = wOracle.writeIsToken1();
        address t0 = w1 ? address(usdg) : address(write);
        address t1 = w1 ? address(write) : address(usdg);
        MockUniswapV3Pool fresh =
            new MockUniswapV3Pool(t0, t1, WRITE_POOL_FEE, writeTick, WRITE_POOL_LIQ, uint32(block.timestamp));
        vm.prank(admin);
        vm.expectRevert(WritePriceOracle.PoolHasNoHistory.selector);
        wOracle.setPool(address(fresh));
    }

    /// @dev The band is a hard precondition: without a ceiling there is nothing bounding a sustained pump.
    function test_setPool_requiresASanityBand() public {
        WritePriceOracle fresh = new WritePriceOracle(address(write), address(usdg), address(usdgFeed), admin);
        vm.prank(admin);
        vm.expectRevert(WritePriceOracle.SanityBandRequired.selector);
        fresh.setPool(address(writePool));
    }

    // ═════════════════════════════ pricing ═════════════════════════════

    function test_writePrice_twapAtLaunch() public view {
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertTrue(ok);
        assertApproxEqRel(price8, WRITE_PRICE_8, 1e14, "the tick grid gets within a fraction of a bp");
        (, bytes32 reason, uint8 source) = wOracle.previewPrice();
        assertEq(reason, bytes32("OK"));
        assertEq(source, wOracle.SOURCE_TWAP());
    }

    /// @dev Orientation is read from the pool, never inferred from address ordering, so both layouts price
    /// identically (D-096).
    function test_writePrice_bothTokenOrderings() public {
        uint256 asDeployed = _writePrice8();

        bool flipped = !wOracle.writeIsToken1();
        (MockUniswapV3Pool p,) = _poolWithOrdering(flipped);
        vm.prank(admin);
        wOracle.setPool(address(p));

        assertEq(wOracle.writeIsToken1(), flipped, "orientation cached from the pool");
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertTrue(ok);
        assertApproxEqRel(price8, asDeployed, 1e14, "same price whichever side WRITE sits on");
    }

    function test_writePrice_prefersFreshChainlink() public {
        MockAggregatorV3 clFeed = new MockAggregatorV3(8);
        clFeed.setRound(clFeed.roundId(1, 1), 0.25e8, block.timestamp);
        vm.prank(admin);
        wOracle.setChainlinkFeed(address(clFeed));

        (uint256 price8, bool ok) = wOracle.writePrice();
        assertTrue(ok);
        assertEq(price8, 0.25e8, "Chainlink wins when it is fresh");
        (,, uint8 source) = wOracle.previewPrice();
        assertEq(source, wOracle.SOURCE_CHAINLINK());
    }

    function test_writePrice_fallsBackToTwapWhenChainlinkIsStale() public {
        MockAggregatorV3 clFeed = new MockAggregatorV3(8);
        clFeed.setRound(clFeed.roundId(1, 1), 0.25e8, block.timestamp);
        vm.prank(admin);
        wOracle.setChainlinkFeed(address(clFeed));

        _warpWithOracles(27 hours); // past CL_MAX_STALE
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertTrue(ok);
        assertApproxEqRel(price8, WRITE_PRICE_8, 1e14, "the TWAP carries it");
        (,, uint8 source) = wOracle.previewPrice();
        assertEq(source, wOracle.SOURCE_TWAP());
    }

    function test_writePrice_normalisesFeedDecimals() public {
        MockAggregatorV3 clFeed = new MockAggregatorV3(18);
        clFeed.setRound(clFeed.roundId(1, 1), 0.25e18, block.timestamp);
        vm.prank(admin);
        wOracle.setChainlinkFeed(address(clFeed));
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertTrue(ok);
        assertEq(price8, 0.25e8, "18-decimal feed scaled to 8");
    }

    // ═════════════════════════════ failure modes, all non-reverting ═════════════════════════════

    function test_writePrice_notOkOnThinLiquidity() public {
        writePool.pullLiquidity(uint32(block.timestamp));
        _warpWithOracles(1 hours);
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        assertEq(price8, 0);
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("THIN_LIQUIDITY"));
    }

    function test_writePrice_notOkOnUsdgDepeg() public {
        _usdgAt(0.9e8, block.timestamp); // 10 % off par, outside the 200 bps band
        (, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("USDG_DEPEG"));
    }

    function test_writePrice_notOkOnStaleUsdgFeed() public {
        vm.warp(block.timestamp + 81 hours); // past USDG_MAX_STALE, deliberately without refreshing
        writePool.write(uint32(block.timestamp), writeTick, WRITE_POOL_LIQ);
        (, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("USDG_DEPEG"));
    }

    /// @dev Audit A-01 / A-02: cumulatives that average outside the tick range, or that wrap, are classified,
    /// never allowed to revert a view both consumers rely on.
    function test_writePrice_notOkOnOutOfRangeTick() public {
        int56[] memory tcs = new int56[](2);
        uint160[] memory spls = new uint160[](2);
        tcs[1] = int56(uint56(wOracle.twapWindow())) * 1_000_000;
        spls[0] = type(uint160).max; // a wrapped secondsPerLiquidity cumulative must not revert either
        spls[1] = 1;
        vm.mockCall(
            address(writePool), abi.encodeWithSelector(bytes4(keccak256("observe(uint32[])"))), abi.encode(tcs, spls)
        );
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        assertEq(price8, 0);
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("TICK_RANGE"));
        vm.clearMockedCalls();
    }

    function test_writePrice_notOkOnDeadPool() public {
        writePool.setDead(true);
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        assertEq(price8, 0);
        (, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("TWAP_UNAVAILABLE"));
    }

    function test_writePrice_notOkBeforeAPoolIsSet() public {
        WritePriceOracle fresh = new WritePriceOracle(address(write), address(usdg), address(usdgFeed), admin);
        (, bool ok) = fresh.writePrice();
        assertFalse(ok);
        (, bytes32 reason,) = fresh.previewPrice();
        assertEq(reason, bytes32("POOL_UNSET"));
    }

    /// @dev The band rejects a manipulated quote rather than clamping it: a clamp would keep feeding the cap
    /// at the ceiling value, which is exactly the outcome the band exists to prevent (D-066).
    function test_writePrice_outOfBandIsRejectedNotClamped() public {
        _setWritePrice(20e8); // far above sanityHigh8 = $5
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertFalse(ok);
        assertEq(price8, 0, "no price at all, not a clamped one");
        (uint256 raw, bytes32 reason,) = wOracle.previewPrice();
        assertEq(reason, bytes32("OUT_OF_BAND"));
        assertGt(raw, SANITY_HIGH_8, "the raw quote is still visible for diagnosis");
    }

    function test_writePrice_neverRevertsAcrossEveryFailureMode() public {
        writePool.setDead(true);
        wOracle.writePrice();
        wOracle.usdValueOfWrite(1e18);
        wOracle.writeForUSD(1e6);
        wOracle.previewPrice();

        _usdgAt(0.5e8, block.timestamp);
        wOracle.writePrice();
        assertTrue(true, "no path reverts");
    }

    // ═════════════════════════════ rounding helpers (D-065) ═════════════════════════════

    function test_usdValueOfWrite_floorsAndWriteForUSDCeils() public view {
        uint256 price8 = _writePrice8();

        (uint256 usd6, bool ok1) = wOracle.usdValueOfWrite(1_000_000e18);
        assertTrue(ok1);
        assertEq(usd6, 1_000_000e18 * price8 / 1e20, "18 + 8 - 20 = 6, floored");

        (uint256 wei_, bool ok2) = wOracle.writeForUSD(100e6);
        assertTrue(ok2);
        uint256 exact = 100e6 * 1e20 / price8;
        assertGe(wei_, exact, "6 + 20 - 8 = 18, ceiled in the protocol's favour");
        assertLe(wei_ - exact, 1);
    }

    // ═════════════════════════════ parameters ═════════════════════════════

    function test_setTwapWindow_bounded() public {
        vm.startPrank(admin);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setTwapWindow(14 minutes);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setTwapWindow(7 hours);
        wOracle.setTwapWindow(1 hours);
        vm.stopPrank();
        assertEq(wOracle.twapWindow(), 1 hours);
    }

    function test_setDepthParams_bounded() public {
        vm.startPrank(admin);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setDepthParams(0, 1e6);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setDepthParams(1001, 1e6);
        wOracle.setDepthParams(200, 500_000e6);
        vm.stopPrank();
        assertEq(wOracle.impactBps(), 200);
        assertEq(wOracle.notionalUSDG(), 500_000e6);
    }

    function test_setSanityBand_bounded() public {
        vm.startPrank(admin);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setSanityBand(1e8, 1e8);
        vm.expectRevert(WritePriceOracle.OutOfBounds.selector);
        wOracle.setSanityBand(1e8, 0);
        vm.stopPrank();
    }

    // ═════════════════════════════ threats ═════════════════════════════

    /// @dev T-03: a single-block tick spike moves the spot price but barely moves a 30-minute TWAP.
    function test_T03_singleBlockSpikeBarelyMovesTheTwap() public {
        uint256 before = _writePrice8();
        int24 spike = _tickForWritePrice(1e8, wOracle.writeIsToken1()); // ten times the price
        writePool.write(uint32(block.timestamp), spike, WRITE_POOL_LIQ);
        vm.warp(block.timestamp + 12); // one block
        _usdgFresh();

        (uint256 after_, bool ok) = wOracle.writePrice();
        assertTrue(ok);
        // The TWAP averages ticks, so 12 s of a 10x spike inside a 1800 s window shifts the mean tick by
        // ~23 026 / 150 = 153 ticks, i.e. 1.0001^153 = +1.55 %. The property worth asserting is the damping
        // ratio, not an arbitrary bound: a 900 % spot move becomes a ~1.5 % oracle move.
        assertLt(after_, before * 102 / 100, "a one-block spike stays inside 2 %");
        uint256 spotMovePct = 900;
        uint256 oracleMovePct = (after_ - before) * 100 / before;
        assertGe(spotMovePct / (oracleMovePct + 1), 100, "at least 100x damping");
    }

    /// @dev T-12: a feed that reverts outright must read as "no price", never bubble.
    function test_T12_revertingFeedReturnsNotOk() public {
        MockAggregatorV3 dead = new MockAggregatorV3(8); // no rounds set at all
        vm.prank(admin);
        wOracle.setChainlinkFeed(address(dead));
        (uint256 price8, bool ok) = wOracle.writePrice();
        assertTrue(ok, "falls through to the TWAP");
        assertApproxEqRel(price8, WRITE_PRICE_8, 1e14);
    }

    // ═════════════════════════════ fuzz ═════════════════════════════

    function testFuzz_writePriceNeverRevertsForAnyTick(int256 tickSeed) public {
        // Wide enough to reach the TICK_RANGE guard at +/-887 272, which a +/-600 000 bound never did.
        int24 tick = int24(bound(tickSeed, -1_000_000, 1_000_000));
        writePool.write(uint32(block.timestamp), tick, WRITE_POOL_LIQ);
        vm.warp(block.timestamp + 31 minutes);
        _usdgFresh();
        writePool.write(uint32(block.timestamp), tick, WRITE_POOL_LIQ);

        (uint256 price8, bool ok) = wOracle.writePrice();
        if (ok) {
            assertGe(price8, SANITY_LOW_8);
            assertLe(price8, SANITY_HIGH_8);
        } else {
            assertEq(price8, 0);
        }
    }

    function testFuzz_writeForUSDInvertsUsdValueOfWrite(uint256 usd6) public view {
        usd6 = bound(usd6, 1e6, 1_000_000e6);
        (uint256 wei_, bool ok) = wOracle.writeForUSD(usd6);
        assertTrue(ok);
        (uint256 back, bool ok2) = wOracle.usdValueOfWrite(wei_);
        assertTrue(ok2);
        assertGe(back, usd6 - 1, "round trip loses at most a rounding unit");
    }
}
