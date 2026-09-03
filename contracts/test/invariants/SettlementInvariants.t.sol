// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SettlementBaseTest} from "../SettlementBase.t.sol";
import {SettlementHandler} from "./SettlementHandler.sol";
import {ICoveredCallVault} from "../../src/interfaces/ICoveredCallVault.sol";
import {OracleMath} from "../../src/libraries/OracleMath.sol";
import {OracleParams, SeriesKind, SeriesState, VaultState} from "../../src/Types.sol";

/// @dev Stateful invariants for SettlementOracle + RiskModule (SPEC §17 I-5, I-7, I-9, I-10, I-11, I-12, I-14, plus
/// "payouts ≤ encumbered collateral" and "preview == settle"). `fail_on_revert = true`.
contract SettlementInvariants is SettlementBaseTest {
    SettlementHandler internal h;

    function setUp() public override {
        super.setUp();
        address[] memory mms = new address[](4);
        mms[0] = mm1;
        mms[1] = mm2;
        mms[2] = mm3;
        mms[3] = mm4;
        address[] memory deps = new address[](2);
        deps[0] = alice;
        deps[1] = bob;
        h = new SettlementHandler(
            SettlementHandler.Deps({
                vault: vault,
                opt: opt,
                ah: ah,
                rm: rm,
                oracle: oracle,
                stock: stock,
                feed: feed,
                usdgFeed: usdgFeed,
                pool: pool,
                admin: admin,
                keeper: keeper,
                guardianHot: guardianHot,
                guardianCold: guardianCold,
                nextAgg: nextAgg
            }),
            mms,
            deps
        );
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = h.openWeekday.selector;
        sel[1] = h.openWeekend.selector;
        sel[2] = h.bid.selector;
        sel[3] = h.clear.selector;
        sel[4] = h.settle.selector;
        sel[5] = h.claim.selector;
        sel[6] = h.postRound.selector;
        sel[7] = h.swap.selector;
        sel[8] = h.usdg.selector;
        sel[9] = h.split.selector;
        sel[10] = h.guardian.selector;
        sel[11] = h.setParams.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
        bytes4[] memory w = new bytes4[](1);
        w[0] = h.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: w}));
    }

    function afterInvariant() public {
        emit log_named_uint("calls", h.calls());
        emit log_named_uint("opens", h.opens());
        emit log_named_uint("clears", h.clears());
        emit log_named_uint("settles path 1", h.settlesByPath(1));
        emit log_named_uint("settles path 2", h.settlesByPath(2));
        emit log_named_uint("settles path 3", h.settlesByPath(3));
        emit log_named_uint("resolved path 4", h.settlesByPath(4));
        emit log_named_uint("resolved path 5", h.settlesByPath(5));
        emit log_named_uint("halts", h.halts());
        emit log_named_uint("claims", h.claims());
        emit log_named_uint("guardian calls", h.guardianCalls());
        emit log_named_uint("param changes", h.paramChanges());
        emit log_named_uint("splits", h.splits());
    }

    /// @dev Deterministic proof that the handler reaches every settlement path, a halt and both resolutions.
    function test_handlerReachesEveryState() public {
        h.cycleWeekdayPath1();
        h.cycleWeekendPath2();
        h.cycleWeekendPath3();
        h.cycleHaltResolveTimelock();
        h.cycleHaltResolveOracle();
        for (uint256 i; i < 8; ++i) {
            h.claim(i * 7919);
        }
        assertEq(h.settlesByPath(1), 1, "path 1");
        assertEq(h.settlesByPath(2), 1, "path 2");
        assertEq(h.settlesByPath(3), 1, "path 3");
        assertEq(h.settlesByPath(4), 1, "path 4");
        assertEq(h.settlesByPath(5), 1, "path 5");
        assertEq(h.halts(), 2, "halts");
        assertGe(h.claims(), 1, "claims");
        assertEq(h.livenessFailures(), 0);
        assertEq(h.previewMismatches(), 0);
        assertEq(h.resolveFailures(), 0);
        _checkAll();
    }

    // ───────────────────────────── invariants ─────────────────────────────

    /// I-5: never stale. Path 1 only within `weekdayMaxStale` of expiry; weekend series never settle on a round at
    /// or before expiry; path 3 rounds are after expiry.
    function invariant_I5_neverStale() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            SettlementHandler.Ghost memory g = h.ghost(id);
            if (!g.settled || g.path == 0) continue;
            OracleParams memory p = rm.paramsAt(address(vault), g.auctionOpen);
            if (g.path == 1) {
                assertEq(uint8(g.kind), uint8(SeriesKind.WEEKDAY), "I-5: path 1 is weekday only");
                (,,, uint256 upd,) = feed.getRoundData(g.roundId);
                assertLe(upd, g.expiry, "I-5: at or before expiry");
                assertLe(g.expiry - upd, p.weekdayMaxStale, "I-5: within weekdayMaxStale");
            } else if (g.path == 3) {
                (,,, uint256 upd,) = feed.getRoundData(g.roundId);
                assertGt(upd, g.expiry, "I-5: path 3 after expiry");
                assertLe(upd, uint256(g.expiry) + 54_060, "I-5: path 3 before Monday 15:00");
            }
        }
    }

    /// I-7: guardian calls write only pause flags.
    function invariant_I7_guardianScope() public view {
        assertEq(h.guardianViolations(), 0, "I-7");
    }

    /// I-9: path 2 settlements used an in-band, fresh USDG/USD read.
    function invariant_I9_usdgBand() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            SettlementHandler.Ghost memory g = h.ghost(id);
            if (!g.settled || g.path != 2) continue;
            OracleParams memory p = rm.paramsAt(address(vault), g.auctionOpen);
            assertGe(g.usdgAnswer, uint256(p.usdgBandLowBps) * 1e4, "I-9: low band");
            assertLe(g.usdgAnswer, uint256(p.usdgBandHighBps) * 1e4, "I-9: high band");
            assertLe(g.settleTs - g.usdgUpdatedAt, p.usdgMaxStale, "I-9: fresh");
        }
    }

    /// I-10: every path 1–3 price is within `jumpBps` of `sRef`, or the multiplier-adjusted price is.
    function invariant_I10_jumpGuard() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            SettlementHandler.Ghost memory g = h.ghost(id);
            if (!g.settled || g.path == 0 || g.path > 3) continue;
            OracleParams memory p = rm.paramsAt(address(vault), g.auctionOpen);
            bool plain = OracleMath.withinBps(g.price, g.sRef, p.jumpBps);
            bool adjusted =
                g.mAtSettle != g.mAtOpen && OracleMath.withinBps(g.price * g.mAtOpen / g.mAtSettle, g.sRef, p.jumpBps);
            assertTrue(plain || adjusted, "I-10");
        }
    }

    /// I-11: resolutions stay inside ±25 % of the resolution reference.
    function invariant_I11_resolutionBand() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            SettlementHandler.Ghost memory g = h.ghost(id);
            if (!g.settled || g.path < 4) continue;
            assertGe(g.price, g.resolveRef * 75 / 100, "I-11: low");
            assertLe(g.price, g.resolveRef * 125 / 100, "I-11: high");
        }
    }

    /// I-12: the parameters governing a series never change after it opened.
    function invariant_I12_paramSnapshot() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            SettlementHandler.Ghost memory g = h.ghost(id);
            assertEq(keccak256(abi.encode(rm.paramsAt(address(vault), g.auctionOpen))), g.paramsHash, "I-12");
        }
    }

    /// I-14: every settle / halt / resolution the views approved succeeded, and a halted series past the timeout
    /// with a fresh post-expiry round is always resolvable without a key.
    function invariant_I14_liveness() public view {
        assertEq(h.livenessFailures(), 0, "I-14: approved call reverted");
        assertEq(h.resolveFailures(), 0, "I-14: resolution reverted");
        if (vault.state() == VaultState.HALTED) {
            uint256 id = vault.currentSeriesId();
            uint64 e = vault.series(id).expiry;
            (, uint256 answer, uint256 upd) = oracle.lastChainlink(address(vault));
            if (block.timestamp >= e + 7 days && upd > e && answer > 0 && !stock.oraclePaused()) {
                (bool ok,) = oracle.canResolveByOracle(id);
                assertTrue(ok, "I-14: permissionless resolution open");
            }
        }
    }

    /// Payouts are bounded by the collateral encumbered for the series and by the assets at settlement; claims never
    /// exceed the reserved total; the reserve is always backed.
    function invariant_payoutsBounded() public view {
        for (uint256 i; i < h.seriesCount(); ++i) {
            uint256 id = h.seriesIds(i);
            SettlementHandler.Ghost memory g = h.ghost(id);
            if (!g.settled) continue;
            ICoveredCallVault.VaultSeries memory s = vault.series(id);
            assertLt(s.payoutPerOption, 1e18, "ppo < 1e18");
            assertLe(g.payoutTotal, g.filledQty, "payout total <= encumbered collateral of the series");
            assertLe(g.payoutTotal, g.totalAssetsAtSettle, "payout total <= totalAssets at settlement");
            assertLe(g.claimed, g.payoutTotal, "claims <= reserved payout");
        }
        assertLe(vault.payoutOwed(), stock.balanceOf(address(vault)), "payoutOwed backed");
    }

    /// `previewSettle` and `settle` agree on the price.
    function invariant_previewMatchesSettle() public view {
        assertEq(h.previewMismatches(), 0);
    }

    /// A halted vault can never open a new auction (SPEC §9.6). `halt` pauses new auctions in the RiskModule and a
    /// guardian may lift that pause after review, but the vault's own state machine keeps it closed until resolved.
    function invariant_haltedVaultCannotOpen() public view {
        if (vault.state() != VaultState.HALTED) return;
        (bool ok, bytes32 reason) = vault.canOpenAuction(uint64(block.timestamp + 5 days));
        assertFalse(ok, "halted vault cannot open");
        assertEq(reason, bytes32("NOT_IDLE"));
    }

    function _checkAll() internal view {
        invariant_I5_neverStale();
        invariant_I7_guardianScope();
        invariant_I9_usdgBand();
        invariant_I10_jumpGuard();
        invariant_I11_resolutionBand();
        invariant_I12_paramSnapshot();
        invariant_I14_liveness();
        invariant_payoutsBounded();
        invariant_haltedVaultCannotOpen();
    }
}
