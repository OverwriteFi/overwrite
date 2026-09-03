// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {IAuctionHouse} from "./interfaces/IAuctionHouse.sol";
import {ICoveredCallVault} from "./interfaces/ICoveredCallVault.sol";
import {IRiskModule} from "./interfaces/IRiskModule.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {ISettlementOracle} from "./interfaces/ISettlementOracle.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {OracleMath} from "./libraries/OracleMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {OracleParams, SeriesKind, SeriesState} from "./Types.sol";

/// @title SettlementOracle
/// @notice Settlement policy of SPEC §9 (D-001): never settle on a stale price, halt instead.
///
/// Paths (`settlementPath` stored by the vault):
/// 1. WEEKDAY primary — the last Chainlink round at or before expiry, no older than `weekdayMaxStale` (26 h);
/// 2. TWAP — 30-min (weekday fallback, within `weekdayTwapBoundBps` of `refRound`) or 60-min (weekend primary,
///    within `weekendTwapBoundBps`) Uniswap v3 TWAP anchored at expiry, called within `twapGrace`, with the
///    time-weighted depth rule (D-018), the observations-in-window rule (D-019) and USDG/USD conversion (D-015);
/// 3. WEEKEND fallback — the first Chainlink round after expiry, no later than Monday 15:00 UTC;
/// 4. `resolveHalted` by the timelock inside the ±25 % resolution band (D-022);
/// 5. `resolveHaltedByOracle`, permissionless 7 days after expiry, clamped into the band (D-033).
/// Every path 1–3 price passes the jump guard against `sRef` (D-025). Keeper hints are verified on-chain and a
/// wrong hint reverts; a failed policy check falls through to the next path (D-021, D-028).
///
/// Settlement effects (SPEC §7.1, §9.7, §10.2 / D-002) are computed by the vault from the price `S` this contract
/// supplies, in USD per one raw stock token (8 decimals, feed units):
///   payoutPerOption = S > K ? (S − K) × 1e18 / S : 0      (raw stock-token units per option, rounded down)
///   payoutTotal     = filledQty × payoutPerOption / 1e18
/// The strike `K` is never adjusted for `uiMultiplier` changes: under ERC-8056 the feed prices one raw token as
/// share price × multiplier, so a correctly sequenced split or dividend leaves `S`, `K` and the payout unchanged.
/// The multiplier appears only in the jump-guard exception, which admits a feed that moved by exactly the
/// multiplier ratio (the mis-sequencing of THREAT-MODEL T-10.2). Option holders redeem through
/// `OptionToken.claim(seriesId, qty, to)`; claims never expire.
contract SettlementOracle is Ownable2Step, ReentrancyGuard, IPriceSource, ISettlementOracle {
    using SafeCast for uint256;

    // ───────────────────────────── constants (SPEC §15: not parameters) ─────────────────────────────

    uint256 public constant RESOLVE_BOUND_BPS = 2_500; // D-022
    uint64 public constant HALTED_TIMEOUT = 7 days; // D-033
    uint64 public constant WEEKEND_CL_DEADLINE = 54_060; // Sunday 23:59 → Monday 15:00 UTC (§9.3)
    uint32 public constant TWAP_WINDOW_WEEKDAY = 1_800;
    uint32 public constant TWAP_WINDOW_WEEKEND = 3_600;
    uint32 public constant CAP_TWAP_WINDOW = 1_800; // §12, §7.2
    uint256 public constant CAP_MAX_STALE = 80 hours; // §12
    uint256 public constant REF_MAX_STALE = 26 hours; // §7.2
    uint256 public constant REF_TWAP_BOUND_BPS = 1_500; // §7.2
    uint32 public constant MAX_LAST_OBS_AGE = 900; // D-019
    uint256 internal constant MAX_GARBAGE_SKIP = 8; // rounds with answer <= 0 tolerated after refRound
    uint80 public constant FIRST_ROUND = (uint80(1) << 64) | 1;
    uint24 internal constant POOL_FEE = 500;
    uint256 internal constant BPS = 1e4;

    bytes32 public constant NO_ORACLE_PATH = "NO_ORACLE_PATH";
    bytes32 public constant JUMP_GUARD = "JUMP_GUARD";

    // ───────────────────────────── immutables ─────────────────────────────

    IRiskModule public immutable riskModule;
    IAuctionHouse public immutable auctionHouse;
    AggregatorV3Interface public immutable usdgUsdFeed;

    // ───────────────────────────── storage ─────────────────────────────

    mapping(address vault => VaultConfig) internal _vaults;
    mapping(uint256 seriesId => SeriesRecord) internal _records;

    // ───────────────────────────── types ─────────────────────────────

    struct Ctx {
        address vault;
        uint256 seriesId;
        SeriesKind kind;
        SeriesState state;
        uint64 expiry;
        uint128 sRef;
        uint256 multiplierAtOpen;
        OracleParams params;
        VaultConfig cfg;
    }

    struct Round {
        uint80 id;
        uint256 answer; // 0 when the feed answer is not positive
        uint256 updatedAt;
        bool exists;
    }

    struct TwapArgs {
        uint32 window;
        uint32 secondsAgoEnd;
        uint16 obsHint;
        bool anchoredNow;
    }

    struct Eval {
        uint8 path;
        uint256 price8;
        uint80 roundId;
        uint8 pathA;
        bytes32 reasonA;
        uint256 priceA;
        uint8 pathB;
        bytes32 reasonB;
        uint256 priceB;
    }

    // ───────────────────────────── errors ─────────────────────────────

    error ZeroAddress();
    error UnknownSeries(uint256 seriesId);
    error VaultNotRegistered(address vault);
    error AlreadyRegistered(address vault);
    error Miswired(bytes32 what);
    error WrongFeedDecimals();
    error PoolTokenMismatch();
    error WrongPoolFee(uint24 fee);
    error NotSettleable(bytes32 reason);
    error BadRefRoundHint(uint80 roundId);
    error RefRoundRequired();
    error BadAfterRoundHint(uint80 roundId);
    error NoOraclePath(bytes32 first, bytes32 second);
    error CannotHalt(bytes32 reason);
    error NotHalted(uint256 seriesId);
    error OutOfResolutionBand(uint256 price8, uint256 lo, uint256 hi);
    error TooEarly(uint64 unlockAt);
    error OraclePaused();
    error InvalidRound(uint80 roundId);
    error NoReferencePrice();

    // ───────────────────────────── events ─────────────────────────────

    event VaultRegistered(address indexed vault, address indexed feed, address indexed pool, bool stockIsToken1);
    event Settled(uint256 indexed seriesId, uint8 path, uint256 price8, uint80 roundId);
    /// @dev Covers SPEC's `TwapRejected`; `reason` is one of GRACE, OBSERVE, LIQUIDITY, OBSERVATIONS, USDG_STALE,
    /// USDG_OUT_OF_BAND, BOUND (TWAP), NO_ROUND, STALE, INVALID_ANSWER, DEADLINE (Chainlink).
    event PathRejected(uint256 indexed seriesId, uint8 path, bytes32 reason);
    event JumpGuardTripped(uint256 indexed seriesId, uint8 path, uint256 price8);
    event SeriesHalted(uint256 indexed seriesId, bytes32 reason, uint256 resolveRef);
    event SeriesResolved(uint256 indexed seriesId, uint256 price8, string evidenceURI);
    event SeriesResolvedByOracle(uint256 indexed seriesId, uint256 rawAnswer, uint256 clampedPrice, uint80 roundId);

    constructor(address riskModule_, address auctionHouse_, address usdgUsdFeed_, address owner_) Ownable(owner_) {
        if (riskModule_ == address(0) || auctionHouse_ == address(0) || usdgUsdFeed_ == address(0)) {
            revert ZeroAddress();
        }
        if (AggregatorV3Interface(usdgUsdFeed_).decimals() != 8) revert WrongFeedDecimals();
        riskModule = IRiskModule(riskModule_);
        auctionHouse = IAuctionHouse(auctionHouse_);
        usdgUsdFeed = AggregatorV3Interface(usdgUsdFeed_);
    }

    // ═════════════════════════════ admin (timelock) ═════════════════════════════

    /// @notice Register a vault with its Chainlink proxy and 0.05 % stock/USDG pool. Asserts the whole wiring
    /// (D-049 pattern): vault → this, vault → RiskModule → this, AuctionHouse knows the vault, feed 8 decimals,
    /// pool tokens are exactly {stock, USDG}.
    function registerVault(address vault, address feed, address pool) external onlyOwner {
        if (vault == address(0) || feed == address(0) || pool == address(0)) revert ZeroAddress();
        if (_vaults[vault].registered) revert AlreadyRegistered(vault);
        ICoveredCallVault v = ICoveredCallVault(vault);
        if (v.settlement() != address(this)) revert Miswired("VAULT_SETTLEMENT");
        if (address(v.riskModule()) != address(riskModule)) revert Miswired("VAULT_RISK_MODULE");
        if (riskModule.settlementOracle() != address(this)) revert Miswired("RISK_MODULE_ORACLE");
        if (!auctionHouse.isVault(vault)) revert Miswired("AUCTION_HOUSE");
        if (AggregatorV3Interface(feed).decimals() != 8) revert WrongFeedDecimals();
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        if (p.fee() != POOL_FEE) revert WrongPoolFee(p.fee());
        IStockToken stock = v.stock();
        address usdg = address(v.usdg());
        bool stockIsToken1;
        if (p.token0() == usdg && p.token1() == address(stock)) stockIsToken1 = true;
        else if (p.token0() != address(stock) || p.token1() != usdg) revert PoolTokenMismatch();
        _vaults[vault] = VaultConfig({
            feed: AggregatorV3Interface(feed),
            pool: p,
            stock: stock,
            stockIsToken1: stockIsToken1,
            stockDecimals: stock.decimals(),
            usdgDecimals: IERC20Metadata(usdg).decimals(),
            registered: true
        });
        emit VaultRegistered(vault, feed, pool, stockIsToken1);
    }

    // ═════════════════════════════ settlement (permissionless) ═════════════════════════════

    /// @inheritdoc ISettlementOracle
    /// @dev Reverts `NotSettleable` before expiry, while `oraclePaused()`, while the sequencer hook fails or when the
    /// series is not LIVE; `NoOraclePath(first, second)` when both paths of the kind fail (call `halt` once
    /// `canHalt` says the paths are exhausted). Payout formula: see the contract notice.
    function settle(uint256 seriesId, Hint calldata hint) external nonReentrant {
        Ctx memory c = _load(seriesId);
        bytes32 gate = _settleGate(c);
        if (gate != 0) revert NotSettleable(gate);
        Eval memory e = _evaluate(c, hint);
        if (e.path == 0) revert NoOraclePath(e.reasonA, e.reasonB);
        if (e.reasonA != 0) _emitRejected(seriesId, e.pathA, e.reasonA, e.priceA);
        _finish(c, e.path, e.price8, e.roundId);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev SPEC §9.6: permissionless once every path is provably exhausted, or unconditionally 7 days after expiry
    /// (D-053 backstop for a feed that stays paused). Fixes `resolveRef` (D-022) and pauses new auctions.
    function halt(uint256 seriesId, Hint calldata hint) external nonReentrant {
        Ctx memory c = _load(seriesId);
        (bool ok, bytes32 reason, Round memory ref) = _haltCheck(c, hint);
        if (!ok) revert CannotHalt(reason);
        uint256 resolveRef = ref.exists && ref.answer > 0 ? ref.answer : c.sRef;
        SeriesRecord storage rec = _records[seriesId];
        rec.halted = true;
        rec.haltedAt = uint64(block.timestamp);
        rec.haltReason = reason;
        rec.resolveRef = resolveRef.toUint128();
        ICoveredCallVault(c.vault).haltSeries(seriesId, reason);
        riskModule.pauseNewAuctionsOnHalt(c.vault, seriesId, reason);
        emit SeriesHalted(seriesId, reason, resolveRef);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev Timelock only (48 h public delay). `price8` must be inside `[0.75, 1.25] × resolveRef` (D-022).
    function resolveHalted(uint256 seriesId, uint128 price8, string calldata evidenceURI)
        external
        onlyOwner
        nonReentrant
    {
        Ctx memory c = _load(seriesId);
        if (c.state != SeriesState.HALTED) revert NotHalted(seriesId);
        (uint256 lo, uint256 hi) = resolutionBand(seriesId);
        if (price8 < lo || price8 > hi) revert OutOfResolutionBand(price8, lo, hi);
        _finish(c, 4, price8, 0);
        emit SeriesResolved(seriesId, price8, evidenceURI);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev Permissionless from `expiry + HALTED_TIMEOUT` (D-033): the first Chainlink round after expiry, any
    /// lateness, clamped into the resolution band. Removes the single-key liveness dependency (I-14).
    function resolveHaltedByOracle(uint256 seriesId, uint80 roundId, uint80 prevRoundId) external nonReentrant {
        Ctx memory c = _load(seriesId);
        if (c.state != SeriesState.HALTED) revert NotHalted(seriesId);
        (uint256 lo, uint256 hi) = resolutionBand(seriesId);
        uint64 unlockAt = c.expiry + HALTED_TIMEOUT;
        if (block.timestamp < unlockAt) revert TooEarly(unlockAt);
        if (c.cfg.stock.oraclePaused()) revert OraclePaused();
        Round memory r = _round(c.cfg.feed, roundId);
        if (!_isFirstAfter(c.cfg.feed, r, prevRoundId, c.expiry)) revert BadAfterRoundHint(roundId);
        if (r.answer == 0) revert InvalidRound(roundId);
        uint256 clamped = OracleMath.clamp(r.answer, lo, hi);
        _finish(c, 5, clamped, roundId);
        emit SeriesResolvedByOracle(seriesId, r.answer, clamped, roundId);
    }

    // ═════════════════════════════ price source (SPEC §7.2, §12) ═════════════════════════════

    /// @inheritdoc IPriceSource
    /// @dev `S_cap`: Chainlink latest if younger than 80 h, else the 30-min TWAP anchored at now (all pool and USDG
    /// checks, no bound). Never reverts: the vault's ERC-4626 views depend on it (D-041).
    function capPrice(address vault) external view returns (uint256 price8, bool ok) {
        VaultConfig memory cfg = _vaults[vault];
        if (!cfg.registered) return (0, false);
        Round memory l = _latest(cfg.feed);
        if (l.exists && l.answer > 0 && l.updatedAt + CAP_MAX_STALE > block.timestamp) return (l.answer, true);
        try this.twap(vault, CAP_TWAP_WINDOW) returns (uint256, uint256 usd8, bytes32 reason) {
            if (reason == 0 && usd8 > 0) return (usd8, true);
        } catch {}
        return (0, false);
    }

    /// @inheritdoc ISettlementOracle
    /// @dev `S_ref` (SPEC §7.2): Chainlink latest if ≤ 26 h old and the token oracle is not paused; else the 30-min
    /// TWAP within 15 % of a Chainlink answer ≤ 80 h old; else `NoReferencePrice`. Not yet consumed by the
    /// AuctionHouse (OQ-005, D-054).
    function referencePrice(address vault) external view returns (uint256 price8, bytes32 source) {
        VaultConfig memory cfg = _vaults[vault];
        if (!cfg.registered) revert VaultNotRegistered(vault);
        Round memory l = _latest(cfg.feed);
        bool valid = l.exists && l.answer > 0;
        if (valid && l.updatedAt + REF_MAX_STALE >= block.timestamp && !cfg.stock.oraclePaused()) {
            return (l.answer, "CHAINLINK");
        }
        if (valid && l.updatedAt + CAP_MAX_STALE >= block.timestamp) {
            try this.twap(vault, CAP_TWAP_WINDOW) returns (uint256, uint256 usd8, bytes32 reason) {
                if (reason == 0 && OracleMath.withinBps(usd8, l.answer, REF_TWAP_BOUND_BPS)) return (usd8, "TWAP");
            } catch {}
        }
        revert NoReferencePrice();
    }

    /// @notice TWAP over the last `window` seconds with the live parameters of `vault` (pool checks, USDG
    /// conversion). `reason` is 0 on success. External so `capPrice` can wrap it in try/catch.
    function twap(address vault, uint32 window)
        external
        view
        returns (uint256 twapUSDG8, uint256 twapUSD8, bytes32 reason)
    {
        VaultConfig memory cfg = _vaults[vault];
        if (!cfg.registered) revert VaultNotRegistered(vault);
        OracleParams memory p = riskModule.currentParams(vault);
        (twapUSDG8, reason) = _poolTwap(cfg, p, TwapArgs(window, 0, 0, true));
        if (reason != 0) return (0, 0, reason);
        (twapUSD8, reason) = _usdConvert(twapUSDG8, p);
        if (reason != 0) return (twapUSDG8, 0, reason);
    }

    // ═════════════════════════════ views ═════════════════════════════

    /// @inheritdoc ISettlementOracle
    /// @dev Same evaluation as `settle` without state changes; `previewSettle == settle` is an invariant. Reverts
    /// only on wrong hints.
    function previewSettle(uint256 seriesId, Hint calldata hint)
        external
        view
        returns (bool ok, uint256 price8, uint8 path, bytes32 reason)
    {
        Ctx memory c = _load(seriesId);
        bytes32 gate = _settleGate(c);
        if (gate != 0) return (false, 0, 0, gate);
        Eval memory e = _evaluate(c, hint);
        if (e.path == 0) return (false, 0, 0, e.reasonB);
        return (true, e.price8, e.path, 0);
    }

    /// @inheritdoc ISettlementOracle
    function canHalt(uint256 seriesId, Hint calldata hint) external view returns (bool ok, bytes32 reason) {
        Ctx memory c = _load(seriesId);
        (ok, reason,) = _haltCheck(c, hint);
    }

    /// @inheritdoc ISettlementOracle
    function canResolveByOracle(uint256 seriesId) external view returns (bool ok, uint64 unlockAt) {
        Ctx memory c = _load(seriesId);
        unlockAt = c.expiry + HALTED_TIMEOUT;
        if (!_records[seriesId].halted || c.state != SeriesState.HALTED) return (false, unlockAt);
        if (block.timestamp < unlockAt || c.cfg.stock.oraclePaused()) return (false, unlockAt);
        Round memory l = _latest(c.cfg.feed);
        ok = l.exists && l.updatedAt > c.expiry;
    }

    /// @inheritdoc ISettlementOracle
    /// @dev `[0.75, 1.25] × resolveRef` (D-022); `resolveRef` is fixed at `halt`.
    function resolutionBand(uint256 seriesId) public view returns (uint256 lo, uint256 hi) {
        SeriesRecord storage rec = _records[seriesId];
        if (!rec.halted) revert NotHalted(seriesId);
        lo = Math.mulDiv(rec.resolveRef, BPS - RESOLVE_BOUND_BPS, BPS);
        hi = Math.mulDiv(rec.resolveRef, BPS + RESOLVE_BOUND_BPS, BPS);
    }

    /// @inheritdoc ISettlementOracle
    function records(uint256 seriesId) external view returns (SeriesRecord memory) {
        return _records[seriesId];
    }

    /// @inheritdoc ISettlementOracle
    function vaultConfig(address vault) external view returns (VaultConfig memory) {
        return _vaults[vault];
    }

    /// @notice Keeper helper: is `roundId` the last valid round with `updatedAt <= timestamp` (SPEC §9.1)?
    function isLastRoundAtOrBefore(address vault, uint80 roundId, uint64 timestamp) external view returns (bool) {
        AggregatorV3Interface feed = _vaults[vault].feed;
        return _isLastValidAtOrBefore(feed, _round(feed, roundId), timestamp);
    }

    /// @notice Keeper helper: is `roundId` the first round with `updatedAt > timestamp` (SPEC §9.3)?
    function isFirstRoundAfter(address vault, uint80 roundId, uint80 prevRoundId, uint64 timestamp)
        external
        view
        returns (bool)
    {
        AggregatorV3Interface feed = _vaults[vault].feed;
        return _isFirstAfter(feed, _round(feed, roundId), prevRoundId, timestamp);
    }

    /// @notice Latest Chainlink round of the vault's feed; `answer` is 0 for a non-positive or unreachable round.
    function lastChainlink(address vault) external view returns (uint80 roundId, uint256 answer, uint256 updatedAt) {
        Round memory l = _latest(_vaults[vault].feed);
        return (l.id, l.answer, l.updatedAt);
    }

    // ═════════════════════════════ internals: evaluation ═════════════════════════════

    function _load(uint256 seriesId) internal view returns (Ctx memory c) {
        IAuctionHouse.Auction memory a = auctionHouse.auctions(seriesId);
        if (a.vault == address(0)) revert UnknownSeries(seriesId);
        c.cfg = _vaults[a.vault];
        if (!c.cfg.registered) revert VaultNotRegistered(a.vault);
        ICoveredCallVault.VaultSeries memory s = ICoveredCallVault(a.vault).series(seriesId);
        c.vault = a.vault;
        c.seriesId = seriesId;
        c.kind = a.kind;
        c.state = s.state;
        c.expiry = a.expiry;
        c.sRef = a.sRef;
        c.multiplierAtOpen = s.multiplierAtOpen;
        c.params = riskModule.paramsAt(a.vault, a.auctionOpen);
    }

    function _settleGate(Ctx memory c) internal view returns (bytes32) {
        if (c.state != SeriesState.LIVE) return "NOT_LIVE";
        if (block.timestamp < c.expiry) return "NOT_EXPIRED";
        if (c.cfg.stock.oraclePaused()) return "ORACLE_PAUSED";
        if (!_sequencerOk(c.params)) return "SEQUENCER_DOWN";
        return 0;
    }

    /// @dev Path order per kind (SPEC §9.2, §9.3). Hint failures revert; policy failures record a reason.
    function _evaluate(Ctx memory c, Hint calldata h) internal view returns (Eval memory e) {
        Round memory ref = _verifyRefRound(c, h.refRoundId);
        if (c.kind == SeriesKind.WEEKDAY) {
            e.pathA = 1;
            if (!ref.exists) {
                e.reasonA = "NO_ROUND";
            } else if (c.expiry - ref.updatedAt > c.params.weekdayMaxStale) {
                e.reasonA = "STALE";
            } else if (!_jumpOk(c, ref.answer)) {
                e.reasonA = JUMP_GUARD;
                e.priceA = ref.answer;
            } else {
                (e.path, e.price8, e.roundId) = (1, ref.answer, ref.id);
                return e;
            }
            e.pathB = 2;
            (e.priceB, e.reasonB) =
                _twapForSeries(c, TWAP_WINDOW_WEEKDAY, h.obsIndex, ref.answer, c.params.weekdayTwapBoundBps);
            if (e.reasonB == 0) {
                if (_jumpOk(c, e.priceB)) (e.path, e.price8) = (2, e.priceB);
                else e.reasonB = JUMP_GUARD;
            }
        } else {
            e.pathA = 2;
            (e.priceA, e.reasonA) =
                _twapForSeries(c, TWAP_WINDOW_WEEKEND, h.obsIndex, ref.answer, c.params.weekendTwapBoundBps);
            if (e.reasonA == 0) {
                if (_jumpOk(c, e.priceA)) {
                    (e.path, e.price8) = (2, e.priceA);
                    return e;
                }
                e.reasonA = JUMP_GUARD;
            }
            e.pathB = 3;
            (e.priceB, e.reasonB, e.roundId) = _path3(c, h);
            if (e.reasonB == 0) (e.path, e.price8) = (3, e.priceB);
        }
    }

    function _path3(Ctx memory c, Hint calldata h) internal view returns (uint256 price8, bytes32 reason, uint80) {
        if (h.afterRoundId == 0) return (0, "NO_ROUND", 0);
        Round memory r = _round(c.cfg.feed, h.afterRoundId);
        if (!_isFirstAfter(c.cfg.feed, r, h.afterPrevRoundId, c.expiry)) revert BadAfterRoundHint(h.afterRoundId);
        if (r.answer == 0) return (0, "INVALID_ANSWER", 0);
        if (r.updatedAt > c.expiry + WEEKEND_CL_DEADLINE) return (0, "DEADLINE", 0);
        if (!_jumpOk(c, r.answer)) return (r.answer, JUMP_GUARD, 0);
        return (r.answer, 0, r.id);
    }

    /// @dev SPEC §9.6 exhaustion proofs (D-053). Returns the verified `refRound` so `halt` can fix `resolveRef`.
    function _haltCheck(Ctx memory c, Hint calldata h) internal view returns (bool, bytes32, Round memory ref) {
        if (c.state != SeriesState.LIVE) return (false, "NOT_LIVE", ref);
        if (block.timestamp <= c.expiry) return (false, "NOT_EXPIRED", ref);
        ref = _verifyRefRound(c, h.refRoundId);
        if (block.timestamp >= c.expiry + HALTED_TIMEOUT) return (true, NO_ORACLE_PATH, ref);
        if (c.cfg.stock.oraclePaused()) return (false, "ORACLE_PAUSED", ref);
        if (!_sequencerOk(c.params)) return (false, "SEQUENCER_DOWN", ref);
        if (c.kind == SeriesKind.WEEKDAY) {
            if (block.timestamp <= c.expiry + c.params.twapGrace) return (false, "TWAP_GRACE_OPEN", ref);
            if (!ref.exists || c.expiry - ref.updatedAt > c.params.weekdayMaxStale) return (true, NO_ORACLE_PATH, ref);
            if (!_jumpOk(c, ref.answer)) return (true, JUMP_GUARD, ref);
            return (false, "PATH_AVAILABLE", ref);
        }
        if (block.timestamp <= c.expiry + WEEKEND_CL_DEADLINE) return (false, "DEADLINE_OPEN", ref);
        Round memory latest = _latest(c.cfg.feed);
        if (!latest.exists || latest.updatedAt <= c.expiry) return (true, NO_ORACLE_PATH, ref);
        if (h.afterRoundId == 0) return (false, "AFTER_HINT_REQUIRED", ref);
        Round memory r = _round(c.cfg.feed, h.afterRoundId);
        if (!_isFirstAfter(c.cfg.feed, r, h.afterPrevRoundId, c.expiry)) revert BadAfterRoundHint(h.afterRoundId);
        if (r.answer == 0 || r.updatedAt > c.expiry + WEEKEND_CL_DEADLINE) return (true, NO_ORACLE_PATH, ref);
        if (!_jumpOk(c, r.answer)) return (true, JUMP_GUARD, ref);
        return (false, "PATH_AVAILABLE", ref);
    }

    function _finish(Ctx memory c, uint8 path, uint256 price8, uint80 roundId) internal {
        SeriesRecord storage rec = _records[c.seriesId];
        rec.path = path;
        rec.price8 = price8.toUint128();
        rec.roundId = roundId;
        ICoveredCallVault(c.vault).settleSeries(c.seriesId, price8.toUint128(), path);
        emit Settled(c.seriesId, path, price8, roundId);
    }

    function _emitRejected(uint256 seriesId, uint8 path, bytes32 reason, uint256 price8) internal {
        if (reason == JUMP_GUARD) emit JumpGuardTripped(seriesId, path, price8);
        else emit PathRejected(seriesId, path, reason);
    }

    // ═════════════════════════════ internals: guards ═════════════════════════════

    /// @dev D-025 as clarified by D-051: the plain check OR, when `uiMultiplier` changed since open, the
    /// multiplier-adjusted check (`S × multiplierAtOpen / m_now`). `oraclePaused()` is checked by the caller.
    function _jumpOk(Ctx memory c, uint256 price8) internal view returns (bool) {
        if (OracleMath.withinBps(price8, c.sRef, c.params.jumpBps)) return true;
        uint256 mNow = c.cfg.stock.uiMultiplier();
        if (mNow == 0 || mNow == c.multiplierAtOpen) return false;
        return OracleMath.withinBps(Math.mulDiv(price8, c.multiplierAtOpen, mNow), c.sRef, c.params.jumpBps);
    }

    /// @dev SPEC §9.1 / D-005: disabled while `sequencerFeed == 0`. An unreachable feed counts as down.
    function _sequencerOk(OracleParams memory p) internal view returns (bool) {
        if (p.sequencerFeed == address(0)) return true;
        try AggregatorV3Interface(p.sequencerFeed).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            return answer == 0 && startedAt != 0 && block.timestamp - startedAt >= p.sequencerGrace;
        } catch {
            return false;
        }
    }

    // ═════════════════════════════ internals: Chainlink rounds ═════════════════════════════

    function _round(AggregatorV3Interface feed, uint80 id) internal view returns (Round memory r) {
        if (id == 0) return r;
        try feed.getRoundData(id) returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (updatedAt == 0) return r;
            r.id = id;
            r.exists = true;
            r.updatedAt = updatedAt;
            if (answer > 0) r.answer = uint256(answer);
        } catch {}
    }

    function _latest(AggregatorV3Interface feed) internal view returns (Round memory r) {
        try feed.latestRoundData() returns (uint80 id, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (updatedAt == 0) return r;
            r.id = id;
            r.exists = true;
            r.updatedAt = updatedAt;
            if (answer > 0) r.answer = uint256(answer);
        } catch {}
    }

    /// @dev Phase-aware successor (SPEC §9.1): `(p, a+1)` if it exists, else `(p+1, 1)`, else none.
    function _next(AggregatorV3Interface feed, uint80 id) internal view returns (Round memory n) {
        uint80 phase = id >> 64;
        uint80 agg = id & type(uint64).max;
        if (agg < type(uint64).max) {
            n = _round(feed, (phase << 64) | (agg + 1));
            if (n.exists) return n;
        }
        n = _round(feed, ((phase + 1) << 64) | 1);
    }

    /// @dev `r` is valid, at or before `ts`, and every later round at or before `ts` is invalid (answer ≤ 0),
    /// checked over at most `MAX_GARBAGE_SKIP` successors.
    function _isLastValidAtOrBefore(AggregatorV3Interface feed, Round memory r, uint256 ts)
        internal
        view
        returns (bool)
    {
        if (!r.exists || r.answer == 0 || r.updatedAt > ts) return false;
        Round memory n = _next(feed, r.id);
        for (uint256 i; i < MAX_GARBAGE_SKIP; ++i) {
            if (!n.exists || n.updatedAt > ts) return true;
            if (n.answer > 0) return false;
            n = _next(feed, n.id);
        }
        return false;
    }

    /// @dev Position check only (`answer` is checked by the caller, D-053/A10): `r` is after `ts` and its
    /// predecessor is at or before `ts`. Across a phase boundary the predecessor comes from `prevHint`.
    function _isFirstAfter(AggregatorV3Interface feed, Round memory r, uint80 prevHint, uint256 ts)
        internal
        view
        returns (bool)
    {
        if (!r.exists || r.updatedAt <= ts) return false;
        uint80 phase = r.id >> 64;
        uint80 agg = r.id & type(uint64).max;
        if (agg > 1) {
            Round memory p = _round(feed, (phase << 64) | (agg - 1));
            return p.exists && p.updatedAt <= ts;
        }
        if (phase <= 1) return true; // the feed's very first round
        if (prevHint == 0 || (prevHint >> 64) != phase - 1) return false;
        Round memory ph = _round(feed, prevHint);
        if (!ph.exists || ph.updatedAt > ts) return false;
        return _next(feed, prevHint).id == r.id;
    }

    /// @dev D-021 / D-053: `refRoundId == 0` is accepted only when the feed's first round is after expiry or the
    /// feed is unreachable; otherwise the hint must be the last valid round at or before expiry.
    function _verifyRefRound(Ctx memory c, uint80 refRoundId) internal view returns (Round memory ref) {
        if (refRoundId == 0) {
            Round memory first = _round(c.cfg.feed, FIRST_ROUND);
            if (first.exists && first.updatedAt <= c.expiry) revert RefRoundRequired();
            return ref;
        }
        ref = _round(c.cfg.feed, refRoundId);
        if (!_isLastValidAtOrBefore(c.cfg.feed, ref, c.expiry)) revert BadRefRoundHint(refRoundId);
    }

    // ═════════════════════════════ internals: TWAP ═════════════════════════════

    /// @dev Series TWAP anchored at expiry: grace, pool checks, USDG conversion, bound vs `refRound` (SPEC §9.5).
    function _twapForSeries(Ctx memory c, uint32 window, uint16 obsHint, uint256 refAnswer, uint16 boundBps)
        internal
        view
        returns (uint256 price8, bytes32 reason)
    {
        if (block.timestamp > c.expiry + c.params.twapGrace) return (0, "GRACE");
        uint32 secondsAgoEnd = uint32(block.timestamp - c.expiry);
        (price8, reason) = _poolTwap(c.cfg, c.params, TwapArgs(window, secondsAgoEnd, obsHint, false));
        if (reason != 0) return (0, reason);
        (price8, reason) = _usdConvert(price8, c.params);
        if (reason != 0) return (0, reason);
        if (refAnswer == 0 || !OracleMath.withinBps(price8, refAnswer, boundBps)) return (0, "BOUND");
    }

    /// @dev Pool TWAP in USDG per token (8 dec) over `[now − secondsAgoEnd − window, now − secondsAgoEnd]` with the
    /// D-018 depth rule and the D-019 activity rule. `anchoredNow` skips the observation hint.
    function _poolTwap(VaultConfig memory cfg, OracleParams memory p, TwapArgs memory a)
        internal
        view
        returns (uint256 price8, bytes32 reason)
    {
        (int24 tick, uint256 lAvg, bool ok) = _observe(cfg.pool, a.window, a.secondsAgoEnd);
        if (!ok) return (0, "OBSERVE");
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        if (!OracleMath.depthOk(lAvg, sqrtP, cfg.stockIsToken1, p.swapNotionalUSDG, p.impactBps)) {
            return (0, "LIQUIDITY");
        }
        if (!_observationsOk(cfg.pool, a, p.minObservationsInWindow)) return (0, "OBSERVATIONS");
        price8 = OracleMath.quotePrice8(sqrtP, cfg.stockIsToken1, cfg.stockDecimals, cfg.usdgDecimals);
    }

    function _observe(IUniswapV3Pool pool, uint32 window, uint32 secondsAgoEnd)
        internal
        view
        returns (int24 tick, uint256 lAvg, bool ok)
    {
        uint32[] memory ago = new uint32[](2);
        ago[0] = secondsAgoEnd + window;
        ago[1] = secondsAgoEnd;
        try pool.observe(ago) returns (int56[] memory tc, uint160[] memory spl) {
            int56 dTick;
            uint160 dSpl;
            unchecked {
                dTick = tc[1] - tc[0];
                dSpl = spl[1] - spl[0];
            }
            if (dSpl == 0) return (0, 0, false);
            return (OracleMath.twapTick(dTick, window), OracleMath.harmonicLiquidity(window, dSpl), true);
        } catch {
            return (0, 0, false);
        }
    }

    /// @dev D-019 / D-053: at least `minObs` observations inside `[anchor − window, anchor]` and the newest one at
    /// or before `anchor` no older than `MAX_LAST_OBS_AGE`. The walk starts at `obsHint` (the live head when
    /// anchored at now) and reads at most `minObs + 1` entries. A hint older than the true latest observation can
    /// only under-count, never pass a quiet window, so a wrong hint fails the path instead of reverting.
    function _observationsOk(IUniswapV3Pool pool, TwapArgs memory a, uint8 minObs) internal view returns (bool) {
        (,, uint16 index, uint16 card,,,) = pool.slot0();
        if (card == 0) return false;
        uint32 anchor = uint32(block.timestamp) - a.secondsAgoEnd;
        uint16 i = a.anchoredNow ? index : a.obsHint;
        if (i >= card) return false;
        (uint32 ts,,, bool init) = pool.observations(i);
        if (!init || ts > anchor || ts + MAX_LAST_OBS_AGE < anchor) return false;
        uint32 lo = anchor > a.window ? anchor - a.window : 0;
        uint256 n;
        for (uint256 k; k < card; ++k) {
            if (k > 0) {
                (ts,,, init) = pool.observations(i);
                if (!init || ts > anchor) break;
            }
            if (ts < lo) break;
            ++n;
            if (n >= minObs) return true;
            i = i == 0 ? card - 1 : i - 1;
        }
        return false;
    }

    /// @dev D-015: `twapUSD8 = twapUSDG8 × usdgUsd / 1e8`; stale or out-of-band peg read invalidates the TWAP.
    function _usdConvert(uint256 usdg8, OracleParams memory p) internal view returns (uint256, bytes32) {
        Round memory u = _latest(usdgUsdFeed);
        if (!u.exists || u.answer == 0 || u.updatedAt + p.usdgMaxStale < block.timestamp) return (0, "USDG_STALE");
        if (u.answer < uint256(p.usdgBandLowBps) * 1e4 || u.answer > uint256(p.usdgBandHighBps) * 1e4) {
            return (0, "USDG_OUT_OF_BAND");
        }
        return (Math.mulDiv(usdg8, u.answer, 1e8), 0);
    }
}
