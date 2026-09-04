// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DeployConfig, VaultCfg, MockCfg} from "./Config.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {MockUniswapV3Pool} from "../src/mocks/MockUniswapV3Pool.sol";
import {OracleMath} from "../src/libraries/OracleMath.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @title MockDeployLib
/// @notice The four testnet mocks of SPEC §1.8 / D-014, deployed and seeded so the real contracts accept them.
/// @dev **A mock is deployed exactly where the config address is zero.** On 4663 every external address is
/// real, so this library does nothing; on 46630 nothing is real, so it fills in all of them. There is no
/// `isTestnet` flag anywhere: the rule is the config, which makes `config/46630.json` the standing record of
/// what was mocked once `Deploy` writes the addresses back into it.
///
/// A cast sweep of every address in `docs/SPEC.md` against 46630 confirms SPEC §1.8: USDG, the stock tokens,
/// the Chainlink feeds, the Uniswap v3 factory and Morpho have no code there. Uniswap **v4**, Permit2 and
/// Multicall3 do, but the protocol reads v3 pools, so a v3 mock is still required.
///
/// Seeding is not optional. `SettlementOracle.registerVault` probes the feed for its earliest reachable round
/// and reverts `Miswired("FEED_FIRST_ROUND")` if there is none (D-057), and it rejects a pool whose `fee()` is
/// not 500. The pool needs an observation history before any TWAP path can answer at all (SPEC §9.5).
///
/// Like `TokenDeployLib` and `VaultDeployLib` this library uses no cheatcodes, so a test can call it under a
/// prank and the script can call it inside a broadcast.
library MockDeployLib {
    uint24 internal constant POOL_FEE = 500; // SettlementOracle.POOL_FEE; nothing else is accepted
    uint8 internal constant FEED_DECIMALS = 8; // asserted by both oracle constructors
    uint256 internal constant HISTORY = 2 days; // how far back the seeded history reaches
    uint256 internal constant FEED_PERIOD = 4 hours; // matches test/SettlementBase.t.sol
    uint256 internal constant SWAP_PERIOD = 1 hours;
    uint256 internal constant USDG_PEG_8 = 1e8; // $1.00, inside the 0.98-1.02 band of SPEC §9.5

    /// @dev Testnet float minted to `treasury` so a deposit can be smoke-tested straight after the deploy.
    /// `MockUSDG.mint` is permissionless anyway, so this is convenience, not capability.
    uint256 internal constant FLOAT_USDG = 1_000_000e6;
    uint256 internal constant FLOAT_STOCK = 10_000e18;

    /// @notice Fills every zero address in `c` with a freshly deployed mock and returns a human-readable list
    /// of what was mocked. `c` is mutated in place, so everything downstream sees one uniform config whether
    /// the addresses are real or not.
    function deployMissing(DeployConfig memory c) internal returns (string[] memory mocked) {
        string[] memory buf = new string[](2 + 3 * c.vaults.length);
        uint256 n;

        if (c.ext.usdg == address(0)) {
            MockUSDG usdg = new MockUSDG();
            usdg.mint(c.gov.treasury, FLOAT_USDG);
            c.ext.usdg = address(usdg);
            buf[n++] = "USDG";
        }
        if (c.ext.usdgUsdFeed == address(0)) {
            c.ext.usdgUsdFeed = address(_feed(USDG_PEG_8));
            buf[n++] = "USDG/USD feed";
        }
        for (uint256 i; i < c.vaults.length; ++i) {
            n = _deployVaultMocks(c, i, buf, n);
        }

        mocked = new string[](n);
        for (uint256 i; i < n; ++i) {
            mocked[i] = buf[i];
        }
    }

    function _deployVaultMocks(DeployConfig memory c, uint256 i, string[] memory buf, uint256 n)
        private
        returns (uint256)
    {
        VaultCfg memory v = c.vaults[i];
        if (v.stock == address(0)) {
            // Owned by the governance EOA, not the timelock: the mocks are testnet fixtures, not protocol
            // contracts, and `mint` has to stay reachable without a 48 h delay.
            MockStockToken stock = new MockStockToken(v.mock.tokenName, v.symbol, c.gov.admin);
            c.vaults[i].stock = address(stock);
            buf[n++] = string.concat(v.symbol, " stock token");
        }
        if (v.feed == address(0)) {
            c.vaults[i].feed = address(_feed(v.mock.price8));
            buf[n++] = string.concat(v.symbol, "/USD feed");
        }
        if (v.pool == address(0)) {
            c.vaults[i].pool = address(_pool(c.vaults[i].stock, c.ext.usdg, v.mock));
            buf[n++] = string.concat(v.symbol, "/USDG 0.05% pool");
        }
        return n;
    }

    /// @notice Mints the testnet float of a mocked stock token. Separate from `deployMissing` because it is
    /// `onlyOwner` on `MockStockToken`, so only the governance EOA can call it.
    function mintStockFloat(DeployConfig memory c, address to) internal {
        for (uint256 i; i < c.vaults.length; ++i) {
            MockStockToken(c.vaults[i].stock).mint(to, FLOAT_STOCK);
        }
    }

    // ───────────────────────────── feed ─────────────────────────────

    /// @dev Phase 1, one round every 4 h across the last two days at a flat `answer8`. `registerVault` walks
    /// back to the earliest round, so the history has to exist before the timelock batch runs, not after.
    function _feed(uint256 answer8) private returns (MockAggregatorV3 feed) {
        feed = new MockAggregatorV3(FEED_DECIMALS);
        uint256 start = block.timestamp - HISTORY;
        uint64 agg = 1;
        for (uint256 t = start; t <= block.timestamp; t += FEED_PERIOD) {
            feed.setRound(feed.roundId(1, agg++), int256(answer8), t);
        }
        // The last round lands on the current timestamp whatever the period leaves over, so `latestRoundData`
        // is always fresh against the 26 h staleness rules of SPEC §9.2 and §9.5.
        feed.setRound(feed.roundId(1, agg), int256(answer8), block.timestamp);
    }

    // ───────────────────────────── pool ─────────────────────────────

    /// @dev One swap an hour across the last two days at the tick that prices the stock at `mock.price8`, so
    /// every anchored window of SPEC §9.5 is inside the buffer and the minimum-observations rule of §9.3
    /// (D-019) is satisfied.
    function _pool(address stock, address usdg, MockCfg memory m) private returns (MockUniswapV3Pool pool) {
        (address t0, address t1) = m.stockIsToken0 ? (stock, usdg) : (usdg, stock);
        int24 tick = tickForPrice(m.price8, !m.stockIsToken0);
        uint32 start = uint32(block.timestamp - HISTORY);
        pool = new MockUniswapV3Pool(t0, t1, POOL_FEE, tick, m.liquidity, start);
        for (uint256 t = start + SWAP_PERIOD; t <= block.timestamp; t += SWAP_PERIOD) {
            pool.write(uint32(t), tick, m.liquidity);
        }
        // SPEC §9.5 deploy-time action. A no-op on the mock, which keeps its own capacity, but the call is
        // made unconditionally so the real-pool and mocked-pool paths are the same code.
        pool.increaseObservationCardinalityNext(65_535);
    }

    /// @notice The tick whose production price is closest to `target8`, found by binary search over
    /// `OracleMath.quotePrice8` itself rather than a hand-computed logarithm (D-096). `quotePrice8` is
    /// monotonic in tick: decreasing when the stock is token1, increasing when it is token0.
    function tickForPrice(uint256 target8, bool stockIsToken1) internal pure returns (int24) {
        int256 lo = -600_000;
        int256 hi = 600_000;
        while (hi - lo > 1) {
            int256 mid = lo + (hi - lo) / 2;
            uint256 p = priceAtTick(int24(mid), stockIsToken1);
            bool goHigher = stockIsToken1 ? (p > target8) : (p < target8);
            if (goHigher) lo = mid;
            else hi = mid;
        }
        return int24(lo);
    }

    /// @notice The 8-decimal price the production pool math produces at `tick` for an 18/6 decimal pair.
    function priceAtTick(int24 tick, bool stockIsToken1) internal pure returns (uint256) {
        return OracleMath.quotePrice8(TickMath.getSqrtRatioAtTick(tick), stockIsToken1, 18, 6);
    }
}

