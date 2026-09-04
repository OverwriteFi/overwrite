// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IWritePriceOracle} from "./interfaces/IWritePriceOracle.sol";
import {OracleMath} from "./libraries/OracleMath.sol";
import {TickMath} from "./libraries/TickMath.sol";

/// @title WritePriceOracle
/// @notice Governance-configured WRITE/USD source shared by `SafetyModule.valueUSD` (SPEC §12) and the
/// FeeRouter WRITE fee path (SPEC §11). Chainlink is used when a feed exists and is fresh; otherwise the
/// 30-minute TWAP of the Uniswap v3 WRITE/USDG pool, gated by the same harmonic-liquidity depth rule the
/// SettlementOracle uses for stock prices (D-018). At launch there is no WRITE/USD feed, so the TWAP carries
/// the whole load.
/// @dev Every view follows `IPriceSource.capPrice`'s never-reverting `(value, ok)` shape (D-064), so neither
/// consumer needs a try/catch. Rounding lives here (D-065): `usdValueOfWrite` floors (conservative for a
/// deposit cap) and `writeForUSD` ceils (the protocol's favour when a curator pays a fee), so no consumer
/// repeats the 18/8/6-decimal bridge.
/// The sanity band is a *validity* band, never a clamp (D-066), and `setPool` refuses to run without one:
/// with no Chainlink deviation anchor at launch, the ceiling is the only guard against a sustained
/// cross-window pump that would inflate every vault's deposit cap.
/// This contract links the same deployed `TickMath` as the SettlementOracle and repeats the D-058 constructor
/// assert, so an unlinked or mis-linked library fails the deployment instead of silently killing every TWAP.
/// `SettlementOracle` is deliberately not imported or called: it has under 2 KB of headroom and must not be
/// recompiled.
contract WritePriceOracle is Ownable2Step, IWritePriceOracle {
    // ───────────────────────────── constants ─────────────────────────────

    uint32 public constant MIN_TWAP_WINDOW = 15 minutes;
    uint32 public constant MAX_TWAP_WINDOW = 6 hours;
    /// @notice Mirrors SettlementOracle's `REF_MAX_STALE`.
    uint256 public constant CL_MAX_STALE = 26 hours;
    /// @notice Mirrors SettlementOracle's `CAP_MAX_STALE` for the USDG peg leg.
    uint256 public constant USDG_MAX_STALE = 80 hours;
    uint256 public constant USDG_BAND_BPS = 200;
    uint16 public constant MIN_CARDINALITY = 256;
    uint16 public constant MAX_IMPACT_BPS = 1000;
    uint32 public constant MAX_SEQUENCER_GRACE = 6 hours;
    uint8 public constant SOURCE_NONE = 0;
    uint8 public constant SOURCE_CHAINLINK = 1;
    uint8 public constant SOURCE_TWAP = 2;

    // ───────────────────────────── immutables ─────────────────────────────

    address public immutable writeToken;
    address public immutable usdg;
    AggregatorV3Interface public immutable usdgUsdFeed;
    uint8 public immutable writeDecimals;
    uint8 public immutable usdgDecimals;
    uint8 public immutable usdgFeedDecimals;

    // ───────────────────────────── state ─────────────────────────────

    /// @notice WRITE/USD feed; `address(0)` until one exists, which is the launch configuration.
    address public chainlinkFeed;
    uint8 public chainlinkDecimals;
    address public pool;
    /// @notice Cached pool orientation. Also answers "is USDG token0", which is the same boolean.
    bool public writeIsToken1;
    uint32 public twapWindow = 30 minutes; // SPEC §11, §12
    uint16 public impactBps = 100;
    uint256 public notionalUSDG = 250_000e6;
    uint256 public sanityLow8;
    uint256 public sanityHigh8;
    /// @notice L2 sequencer uptime feed; `address(0)` disables the check, as in RiskModule's OracleParams.
    address public sequencerFeed;
    uint32 public sequencerGrace = 1 hours;

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error OutOfBounds();
    error Miswired(bytes32 what);
    error PoolTokenMismatch();
    error PoolFeeNotAllowed(uint24 fee);
    error PoolCardinalityTooLow(uint16 cardinalityNext, uint16 required);
    error PoolHasNoHistory();
    error SanityBandRequired();
    error RenounceDisabled();

    // ───────────────────────────── events ─────────────────────────────

    event ChainlinkFeedSet(address indexed feed, uint8 decimals);
    event PoolSet(address indexed pool, bool writeIsToken1, uint24 fee);
    event ParameterChanged(address indexed target, bytes32 key, uint256 oldValue, uint256 newValue);

    // ───────────────────────────── constructor ─────────────────────────────

    constructor(address write_, address usdg_, address usdgUsdFeed_, address owner_) Ownable(owner_) {
        if (write_ == address(0) || usdg_ == address(0) || usdgUsdFeed_ == address(0)) revert ZeroAddress();
        // D-058: `TickMath.getSqrtRatioAtTick` is `public`, so this contract carries a link placeholder. An
        // unlinked library has no code and returns nothing; a mis-linked one returns the wrong value.
        if (TickMath.getSqrtRatioAtTick(0) != 2 ** 96) revert Miswired("TICK_MATH");

        writeToken = write_;
        usdg = usdg_;
        usdgUsdFeed = AggregatorV3Interface(usdgUsdFeed_);
        writeDecimals = IERC20Metadata(write_).decimals();
        usdgDecimals = IERC20Metadata(usdg_).decimals();
        usdgFeedDecimals = AggregatorV3Interface(usdgUsdFeed_).decimals();
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice Points at a WRITE/USD feed, or clears it with `address(0)` to fall back to the TWAP.
    function setChainlinkFeed(address feed) external onlyOwner {
        emit ParameterChanged(address(this), "chainlinkFeed", uint256(uint160(chainlinkFeed)), uint256(uint160(feed)));
        chainlinkFeed = feed;
        uint8 dec = feed == address(0) ? 0 : AggregatorV3Interface(feed).decimals();
        chainlinkDecimals = dec;
        emit ChainlinkFeedSet(feed, dec);
    }

    /// @notice Points at the WRITE/USDG pool. Asserts pair membership, an allowlisted fee tier, enough
    /// reserved observation capacity, and that the pool can already answer the configured window.
    function setPool(address pool_) external onlyOwner {
        if (pool_ == address(0)) revert ZeroAddress();
        if (sanityHigh8 == 0) revert SanityBandRequired(); // D-066

        IUniswapV3Pool p = IUniswapV3Pool(pool_);
        address t0 = p.token0();
        address t1 = p.token1();
        bool writeIsToken1_;
        if (t0 == usdg && t1 == writeToken) {
            writeIsToken1_ = true;
        } else if (t0 == writeToken && t1 == usdg) {
            writeIsToken1_ = false;
        } else {
            revert PoolTokenMismatch();
        }

        uint24 fee = p.fee();
        if (fee != 500 && fee != 3000 && fee != 10_000) revert PoolFeeNotAllowed(fee);

        (,,,, uint16 cardinalityNext,,) = p.slot0();
        if (cardinalityNext < MIN_CARDINALITY) revert PoolCardinalityTooLow(cardinalityNext, MIN_CARDINALITY);

        pool = pool_;
        writeIsToken1 = writeIsToken1_;
        _probe(pool_, twapWindow);
        emit PoolSet(pool_, writeIsToken1_, fee);
    }

    function setTwapWindow(uint32 window) external onlyOwner {
        if (window < MIN_TWAP_WINDOW || window > MAX_TWAP_WINDOW) revert OutOfBounds();
        if (pool != address(0)) _probe(pool, window);
        emit ParameterChanged(address(this), "twapWindow", twapWindow, window);
        twapWindow = window;
    }

    function setDepthParams(uint16 impactBps_, uint256 notionalUSDG_) external onlyOwner {
        if (impactBps_ == 0 || impactBps_ > MAX_IMPACT_BPS || notionalUSDG_ == 0) revert OutOfBounds();
        emit ParameterChanged(address(this), "impactBps", impactBps, impactBps_);
        emit ParameterChanged(address(this), "notionalUSDG", notionalUSDG, notionalUSDG_);
        impactBps = impactBps_;
        notionalUSDG = notionalUSDG_;
    }

    /// @notice Points at the L2 sequencer uptime feed, or clears it with `address(0)`.
    function setSequencerFeed(address feed, uint32 grace) external onlyOwner {
        if (grace > MAX_SEQUENCER_GRACE) revert OutOfBounds();
        emit ParameterChanged(address(this), "sequencerFeed", uint256(uint160(sequencerFeed)), uint256(uint160(feed)));
        emit ParameterChanged(address(this), "sequencerGrace", sequencerGrace, grace);
        sequencerFeed = feed;
        sequencerGrace = grace;
    }

    /// @notice Sets the validity band, in 8-decimal USD. A quote outside it is reported as unavailable, never
    /// clamped: a clamp would let a manipulated price keep feeding the cap at the ceiling value.
    /// @dev `low8` must be non-zero: `_inBand(0)` would otherwise be true, so a feed answer that truncates to
    /// zero in `_scaleTo8` would be reported as a usable price of zero (D-098).
    function setSanityBand(uint256 low8, uint256 high8) external onlyOwner {
        if (low8 == 0 || high8 == 0 || low8 >= high8) revert OutOfBounds();
        emit ParameterChanged(address(this), "sanityLow8", sanityLow8, low8);
        emit ParameterChanged(address(this), "sanityHigh8", sanityHigh8, high8);
        sanityLow8 = low8;
        sanityHigh8 = high8;
    }

    /// @dev Renouncing would freeze the source configuration and, with it, every deposit cap.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ═════════════════════════════ views (SPEC §11, §12) ═════════════════════════════

    /// @inheritdoc IWritePriceOracle
    function writePrice() public view returns (uint256 price8, bool ok) {
        uint8 source;
        (price8,, source) = _price();
        ok = source != SOURCE_NONE;
        if (!ok) price8 = 0;
    }

    /// @inheritdoc IWritePriceOracle
    /// @dev `writeWei` is 18-dec, `price8` is 8-dec USD, the result is 6-dec USD: 18 + 8 − 20 = 6. Floored,
    /// which understates the safety module and therefore the deposit cap — the conservative direction, and
    /// the complement of `CapController`'s ceiling-rounded `used6`.
    function usdValueOfWrite(uint256 writeWei) external view returns (uint256 usd6, bool ok) {
        uint256 price8;
        (price8, ok) = writePrice();
        if (!ok) return (0, false);
        usd6 = Math.mulDiv(writeWei, price8, 1e20);
    }

    /// @inheritdoc IWritePriceOracle
    /// @dev `usd6` is 6-dec, `price8` is 8-dec, the result is 18-dec WRITE: 6 + 20 − 8 = 18. Ceiled, so a
    /// curator paying a fee in WRITE never underpays by a rounding unit (D-088).
    function writeForUSD(uint256 usd6) external view returns (uint256 writeWei, bool ok) {
        uint256 price8;
        (price8, ok) = writePrice();
        if (!ok || price8 == 0) return (0, false);
        writeWei = Math.mulDiv(usd6, 1e20, price8, Math.Rounding.Ceil);
    }

    /// @inheritdoc IWritePriceOracle
    function previewPrice() external view returns (uint256 price8, bytes32 reason, uint8 source) {
        return _price();
    }

    // ═════════════════════════════ internal ═════════════════════════════

    function _price() internal view returns (uint256 price8, bytes32 reason, uint8 source) {
        (uint256 clPrice, bool clOk) = _chainlink();
        if (clOk) {
            if (!_inBand(clPrice)) return (clPrice, "OUT_OF_BAND", SOURCE_NONE);
            return (clPrice, "OK", SOURCE_CHAINLINK);
        }

        (uint256 twapPrice, bytes32 twapReason) = _twap();
        if (twapReason != bytes32("OK")) return (0, twapReason, SOURCE_NONE);
        if (!_inBand(twapPrice)) return (twapPrice, "OUT_OF_BAND", SOURCE_NONE);
        return (twapPrice, "OK", SOURCE_TWAP);
    }

    function _inBand(uint256 price8) internal view returns (bool) {
        return price8 >= sanityLow8 && price8 <= sanityHigh8 && sanityHigh8 != 0;
    }

    function _chainlink() internal view returns (uint256 price8, bool ok) {
        address feed = chainlinkFeed;
        if (feed == address(0)) return (0, false);
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) return (0, false);
            if (block.timestamp > updatedAt + CL_MAX_STALE) return (0, false);
            return _scaleTo8(uint256(answer), chainlinkDecimals);
        } catch {
            return (0, false);
        }
    }

    function _twap() internal view returns (uint256 price8, bytes32 reason) {
        address p = pool;
        if (p == address(0)) return (0, "POOL_UNSET");
        // T-05: `observe` interpolates across a sequencer outage and reports a pre-outage tick as fresh. That
        // stale price would size every vault's deposit cap, so the window is rejected until the sequencer has
        // been back for `sequencerGrace` (D-098; mirrors SettlementOracle's own check).
        if (!_sequencerOk()) return (0, "SEQUENCER_DOWN");
        uint32 window = twapWindow;

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(p).observe(secondsAgos) returns (int56[] memory tc, uint160[] memory spl) {
            int24 tick = OracleMath.twapTick(tc[1] - tc[0], window);
            if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) return (0, "TICK_RANGE");
            uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);

            uint160 splDelta = spl[1] - spl[0];
            if (splDelta == 0) return (0, "NO_LIQUIDITY");
            uint256 lAvg = OracleMath.harmonicLiquidity(window, splDelta);
            // `usdgIsToken0` and `writeIsToken1` are the same boolean for a two-token WRITE/USDG pool.
            if (!OracleMath.depthOk(lAvg, sqrtP, writeIsToken1, notionalUSDG, impactBps)) {
                return (0, "THIN_LIQUIDITY");
            }

            uint256 usdgPerWrite8 = OracleMath.quotePrice8(sqrtP, writeIsToken1, writeDecimals, usdgDecimals);
            if (usdgPerWrite8 == 0) return (0, "ZERO_PRICE");

            (uint256 usdg8, bool pegOk) = _usdgUsd();
            if (!pegOk) return (0, "USDG_DEPEG");
            return (Math.mulDiv(usdgPerWrite8, usdg8, 1e8), "OK");
        } catch {
            // `observe` reverts "OLD" when the window predates the oldest observation, and reverts outright
            // for a dead pool. Either way there is no price; it must never bubble to the caller.
            return (0, "TWAP_UNAVAILABLE");
        }
    }

    /// @dev Disabled while `sequencerFeed == 0`. An unreachable feed counts as down, as in SettlementOracle.
    function _sequencerOk() internal view returns (bool) {
        address feed = sequencerFeed;
        if (feed == address(0)) return true;
        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            if (answer != 0 || startedAt == 0 || startedAt > block.timestamp) return false;
            return block.timestamp - startedAt >= sequencerGrace;
        } catch {
            return false;
        }
    }

    /// @dev USDG/USD, banded to ±200 bps of par. A depegged quote asset makes the pool price meaningless.
    function _usdgUsd() internal view returns (uint256 price8, bool ok) {
        try usdgUsdFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) return (0, false);
            if (block.timestamp > updatedAt + USDG_MAX_STALE) return (0, false);
            (uint256 p, bool scaled) = _scaleTo8(uint256(answer), usdgFeedDecimals);
            if (!scaled || !OracleMath.withinBps(p, 1e8, USDG_BAND_BPS)) return (0, false);
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Normalises a feed answer to 8 decimals. Rejects an absurd magnitude rather than risking an
    /// overflow revert inside a view that is required never to revert.
    function _scaleTo8(uint256 value, uint8 dec) internal pure returns (uint256, bool) {
        if (value > type(uint128).max) return (0, false);
        if (dec == 8) return (value, true);
        if (dec < 8) return (value * (10 ** (8 - dec)), true); // dec < 8 bounds the exponent at 8
        if (dec - 8 > 30) return (0, false); // an absurd feed decimals value, not a real Chainlink aggregator
        return (value / (10 ** (dec - 8)), true);
    }

    /// @dev Asserts the pool can already answer `window`, so a freshly created pool cannot be wired in and
    /// then silently report "no price" at the first read.
    function _probe(address pool_, uint32 window) internal view {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        try IUniswapV3Pool(pool_).observe(secondsAgos) returns (int56[] memory, uint160[] memory) {
            return;
        } catch {
            revert PoolHasNoHistory();
        }
    }
}
