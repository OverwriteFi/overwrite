// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CoveredCallVault} from "../../src/CoveredCallVault.sol";
import {OptionToken} from "../../src/OptionToken.sol";
import {AuctionHouse} from "../../src/AuctionHouse.sol";
import {BondManager} from "../../src/BondManager.sol";
import {FeeRouter} from "../../src/FeeRouter.sol";
import {MockStockToken} from "../../src/mocks/MockStockToken.sol";
import {MockUSDG} from "../../src/mocks/MockUSDG.sol";
import {IAuctionHouse} from "../../src/interfaces/IAuctionHouse.sol";
import {IBondManager} from "../../src/interfaces/IBondManager.sol";
import {SeriesKind, SeriesState, VaultState} from "../../src/Types.sol";

/// @dev Stateful fuzzing handler for the auction layer. Every action is guarded so it never reverts
/// (`fail_on_revert = true`). Plays depositors, bonded market makers, the keeper, the settlement oracle, the
/// issuer (burn during AUCTION), Paxos (freeze) and the timelock (fee). The lifecycle actions are
/// self-sufficient (a bid opens an auction if none is open, `clear` and `settle` warp to their earliest valid
/// time) and `fullCycle` runs open → bids → clear → settle in one call, so every run reaches every state
/// inside the depth budget while the single-step actions still interleave freely. Ghost variables record the
/// escrow flows that the invariants check exactly (SPEC I-3, I-13).
contract AuctionHandler is Test {
    CoveredCallVault public vault;
    OptionToken public opt;
    AuctionHouse public ah;
    BondManager public bm;
    FeeRouter public fr;
    MockStockToken public stock;
    MockUSDG public usdg;
    address public admin;
    address public keeper;
    address public settlement;
    address public treasury;

    address[] public mms;
    address[] public depositors;
    uint256[] public seriesIds;

    // ghosts
    mapping(uint256 seriesId => uint256) public escrowOf;
    mapping(uint256 seriesId => mapping(address bidder => bool)) public hadFill;
    uint256 public escrowOpenTotal;
    uint256 public escrowClosed;
    uint256 public refundsCredited;
    uint256 public premiumNetTotal;
    uint256 public feeTotal;
    uint256 public refundsWithdrawn;
    uint256 public withdrawWhileLocked;
    uint256 public previewMismatches;
    uint256 public issuerBurned;
    uint256 public opens;
    uint256 public bidsPlaced;
    uint256 public clears;
    uint256 public skips;
    uint256 public settles;
    uint256 public payoutsClaimed;
    uint256 public calls;

    struct Deps {
        CoveredCallVault vault;
        OptionToken opt;
        AuctionHouse ah;
        BondManager bm;
        FeeRouter fr;
        MockStockToken stock;
        MockUSDG usdg;
        address admin;
        address keeper;
        address settlement;
        address treasury;
    }

    constructor(Deps memory d, address[] memory mms_, address[] memory depositors_) {
        vault = d.vault;
        opt = d.opt;
        ah = d.ah;
        bm = d.bm;
        fr = d.fr;
        stock = d.stock;
        usdg = d.usdg;
        admin = d.admin;
        keeper = d.keeper;
        settlement = d.settlement;
        treasury = d.treasury;
        mms = mms_;
        depositors = depositors_;
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function mmCount() external view returns (uint256) {
        return mms.length;
    }

    function seriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function _mm(uint256 s) internal view returns (address) {
        return mms[s % mms.length];
    }

    function _dep(uint256 s) internal view returns (address) {
        return depositors[s % depositors.length];
    }

    function _pick(uint256 s) internal view returns (uint256 id, bool ok) {
        if (seriesIds.length == 0) return (0, false);
        return (seriesIds[s % seriesIds.length], true);
    }

    function _openAuction() internal view returns (uint256 id, bool open) {
        id = ah.currentAuction(address(vault));
        open = id != 0 && ah.auctions(id).state == IAuctionHouse.AuctionState.OPEN;
    }

    function _sumRefundable() internal view returns (uint256 sum) {
        for (uint256 i; i < mms.length; ++i) {
            sum += ah.refundable(mms[i]);
        }
    }

    function _settled(uint256 id) internal view returns (bool) {
        SeriesState st = vault.series(id).state;
        return st == SeriesState.SETTLED || st == SeriesState.RESOLVED;
    }

    function _r(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    modifier count() {
        calls++;
        _;
    }

    // ───────────────────────────── composite ─────────────────────────────

    /// @dev One whole series in a single call: open (warping to the window), up to three bids, clear, settle.
    function fullCycle(uint256 seed) external count {
        if (!_open(seed, _r(seed, 1), _r(seed, 2))) return;
        for (uint256 i; i < 3; ++i) {
            _bid(_r(seed, 10 + i), _r(seed, 20 + i), _r(seed, 30 + i));
        }
        _clear(_r(seed, 40));
        _settle(_r(seed, 50), _r(seed, 51));
    }

    // ───────────────────────────── depositors ─────────────────────────────

    function deposit(uint256 s, uint256 amt) external count {
        _deposit(s, bound(amt, 1e17, 1_000e18));
    }

    function _deposit(uint256 s, uint256 amt) internal returns (bool) {
        if (vault.state() != VaultState.IDLE || vault.sunset()) return false;
        address d = _dep(s);
        if (vault.maxDeposit(d) < amt) return false;
        vm.prank(admin);
        stock.mint(d, amt);
        vm.prank(d);
        vault.deposit(amt, d);
        return true;
    }

    function redeemIdle(uint256 s, uint256 frac) external count {
        address d = _dep(s);
        uint256 max = vault.maxRedeem(d);
        if (max == 0) return;
        uint256 shares = bound(frac, 1, max);
        if (vault.previewRedeem(shares) == 0) return; // audit N-1: refused on purpose
        vm.prank(d);
        vault.redeem(shares, d, d);
    }

    function requestRedeem(uint256 s, uint256 frac) external count {
        if (vault.state() == VaultState.IDLE) return;
        address d = _dep(s);
        uint256 bal = vault.balanceOf(d);
        if (bal == 0) return;
        uint256 shares = bound(frac, 1, bal);
        vm.prank(d);
        vault.requestRedeem(shares, d);
    }

    function claimWithdrawal(uint256 s) external count {
        address d = _dep(s);
        if (vault.withdrawalClaimable(d) == 0) return;
        vm.prank(d);
        vault.claimWithdrawal(d);
    }

    // ───────────────────────────── keeper ─────────────────────────────

    function openAuction(uint256 kindSeed, uint256 distSeed, uint256 reserveSeed) external count {
        _open(kindSeed, distSeed, reserveSeed);
    }

    /// @dev Warps to the next valid slot of the chosen kind when the vault is IDLE but the window is closed.
    function _open(uint256 kindSeed, uint256 distSeed, uint256 reserveSeed) internal returns (bool) {
        if (vault.state() != VaultState.IDLE) return false;
        SeriesKind kind = kindSeed % 2 == 0 ? SeriesKind.WEEKDAY : SeriesKind.WEEKEND;
        uint64 nowTs = uint64(block.timestamp);
        uint64 expiry = ah.scheduledExpiry(kind, nowTs);
        (bool ok, bytes32 reason) = ah.canOpen(address(vault), kind, expiry, nowTs);
        if (!ok && (reason == "OPEN_WINDOW" || reason == "EXPIRY" || reason == "WEEKDAY_GAP")) {
            vm.warp(_nextSlot(kind == SeriesKind.WEEKDAY, block.timestamp) + kindSeed % 600);
            nowTs = uint64(block.timestamp);
            expiry = ah.scheduledExpiry(kind, nowTs);
            (ok,) = ah.canOpen(address(vault), kind, expiry, nowTs);
        }
        if (!ok) return false;
        uint256 ta = vault.totalAssets();
        uint256 pend = vault.pendingRedeemAssets();
        if (ta <= pend || ta - pend < ah.minBidQty()) {
            if (!_deposit(distSeed, 10e18)) return false;
        }
        (uint16 dist, uint128 reserve, bool paramsOk) = _openParams(kind, distSeed, reserveSeed);
        if (!paramsOk) return false;
        vm.prank(keeper);
        uint256 id = ah.openAuction(address(vault), kind, expiry, dist, reserve);
        seriesIds.push(id);
        opens++;
        return true;
    }

    function _openParams(SeriesKind kind, uint256 distSeed, uint256 reserveSeed)
        internal
        view
        returns (uint16 dist, uint128 reserve, bool ok)
    {
        (uint16 lo, uint16 hi) = ah.strikeDistanceBounds(address(vault), kind);
        dist = uint16(bound(distSeed, lo, hi));
        uint256 sRef = ah.referencePrice(address(vault));
        (uint256 rLo, uint256 rHi) = ah.reserveBounds(address(vault), kind, sRef);
        if (rLo == 0) rLo = 1;
        if (rHi < rLo) return (0, 0, false);
        reserve = uint128(bound(reserveSeed, rLo, rHi));
        ok = true;
    }

    // ───────────────────────────── market makers ─────────────────────────────

    /// @dev Opens an auction first when none is open, so bids are reachable from any IDLE state.
    function bid(uint256 s, uint256 qtySeed, uint256 priceSeed) external count {
        (, bool open) = _openAuction();
        if (!open && !_open(s, qtySeed, priceSeed)) return;
        _bid(s, qtySeed, priceSeed);
    }

    function _bid(uint256 s, uint256 qtySeed, uint256 priceSeed) internal {
        (uint256 id, bool open) = _openAuction();
        if (!open) return;
        IAuctionHouse.Auction memory a = ah.auctions(id);
        if (block.timestamp >= a.auctionClose) return;
        address mm = _mm(s);
        if (usdg.isFrozen(mm) || !bm.hasActiveMMBond(mm)) return;
        if (ah.bidCount(id, mm) >= ah.maxBidsPerBidder()) return;
        if (ah.bids(id).length >= ah.MAX_BIDS()) return;
        uint256 qty = bound(qtySeed, ah.minBidQty(), 3 * uint256(a.offeredQty));
        uint256 price = uint256(a.reservePrice) * (1 + priceSeed % 6); // 6 price levels → real ties
        uint256 escrow = qty * price / 1e18;
        if (escrow == 0) return;
        usdg.mint(mm, escrow);
        vm.prank(mm);
        ah.bid(id, qty, price);
        escrowOf[id] += escrow;
        escrowOpenTotal += escrow;
        bidsPlaced++;
    }

    /// @dev Warps to `auctionClose` when needed (plus a jitter that sometimes crosses `expiry`, D-045).
    function clear(uint256 seed) external count {
        _clear(seed);
    }

    function _clear(uint256 seed) internal {
        (uint256 id, bool open) = _openAuction();
        if (!open) return;
        IAuctionHouse.Auction memory a = ah.auctions(id);
        if (block.timestamp < a.auctionClose) {
            uint256 target = a.auctionClose + seed % 1800;
            if (seed % 13 == 0) target = a.expiry + seed % 600; // late keeper: skip path
            vm.warp(target);
        }
        (uint256 pCp, uint256 pFilled, uint256 pGross, bool pSkip) = ah.previewClear(id);
        uint256 refBefore = _sumRefundable();
        (uint256 cp, uint256 filled, uint256 gross, uint256 fee) = ah.clear(id);
        bool same = pSkip ? (cp | filled | gross | fee) == 0 : (pCp == cp && pFilled == filled && pGross == gross);
        if (!same) previewMismatches++;
        _ghostClose(id, gross, fee, refBefore, pSkip);
    }

    function _ghostClose(uint256 id, uint256 gross, uint256 fee, uint256 refBefore, bool skipped) internal {
        uint256 e = escrowOf[id];
        escrowOpenTotal -= e;
        escrowClosed += e;
        refundsCredited += _sumRefundable() - refBefore;
        feeTotal += fee;
        premiumNetTotal += gross - fee;
        if (skipped) skips++;
        else clears++;
        for (uint256 i; i < mms.length; ++i) {
            hadFill[id][mms[i]] = ah.claimableOptions(id, mms[i]) > 0;
        }
    }

    function withdrawRefund(uint256 s) external count {
        address mm = _mm(s);
        if (usdg.isFrozen(mm)) return;
        uint256 r = ah.refundable(mm);
        if (r == 0) return;
        vm.prank(mm);
        ah.withdrawRefund(mm);
        refundsWithdrawn += r;
    }

    function claimOptions(uint256 s, uint256 idSeed) external count {
        (uint256 id, bool ok) = _pick(idSeed);
        if (!ok) return;
        address mm = _mm(s);
        if (ah.claimableOptions(id, mm) == 0) return;
        vm.prank(mm);
        ah.claimOptions(id, mm);
    }

    function claimPayout(uint256 s, uint256 idSeed) external count {
        (uint256 id, bool ok) = _pick(idSeed);
        if (!ok) return;
        address mm = _mm(s);
        if (ah.claimableOptions(id, mm) == 0 || !_settled(id)) return;
        vm.prank(mm);
        ah.claimPayout(id, mm);
        payoutsClaimed++;
    }

    function optionClaim(uint256 s, uint256 idSeed, uint256 frac) external count {
        (uint256 id, bool ok) = _pick(idSeed);
        if (!ok) return;
        address mm = _mm(s);
        uint256 bal = opt.balanceOf(mm, id);
        if (bal == 0 || !_settled(id)) return;
        uint256 qty = bound(frac, 1, bal);
        vm.prank(mm);
        opt.claim(id, qty, mm);
        payoutsClaimed++;
    }

    function transferOptions(uint256 s, uint256 t, uint256 idSeed, uint256 frac) external count {
        (uint256 id, bool ok) = _pick(idSeed);
        if (!ok) return;
        address from = _mm(s);
        address to = _mm(t);
        uint256 bal = opt.balanceOf(from, id);
        if (bal == 0 || from == to) return;
        uint256 qty = bound(frac, 1, bal);
        vm.prank(from);
        opt.safeTransferFrom(from, to, id, qty, "");
    }

    function releaseLocks(uint256 idSeed) external count {
        (uint256 id, bool ok) = _pick(idSeed);
        if (!ok) return;
        if (ah.auctions(id).state != IAuctionHouse.AuctionState.CLEARED || !_settled(id)) return;
        ah.releaseLocks(id);
    }

    // ───────────────────────────── bonds ─────────────────────────────

    function bondRequestWithdraw(uint256 s) external count {
        address mm = _mm(s);
        uint256 locks = bm.activeLocks(mm);
        vm.prank(mm);
        try bm.requestWithdraw(IBondManager.BondKind.MM) {
            if (locks > 0) withdrawWhileLocked++;
        } catch {}
    }

    function bondCancelWithdraw(uint256 s) external count {
        address mm = _mm(s);
        vm.prank(mm);
        try bm.cancelWithdraw(IBondManager.BondKind.MM) {} catch {}
    }

    function bondWithdraw(uint256 s) external count {
        address mm = _mm(s);
        if (usdg.isFrozen(mm)) return;
        uint256 locks = bm.activeLocks(mm);
        vm.prank(mm);
        try bm.withdrawBond(IBondManager.BondKind.MM) {
            if (locks > 0) withdrawWhileLocked++;
        } catch {}
    }

    function bondRepost(uint256 s) external count {
        address mm = _mm(s);
        if (usdg.isFrozen(mm)) return;
        (uint256 amount,, uint64 unlockAt) = bm.status(mm, IBondManager.BondKind.MM);
        uint256 required = bm.requiredAmount(IBondManager.BondKind.MM);
        if (unlockAt != 0 || amount >= required) return;
        usdg.mint(mm, required - amount);
        vm.prank(mm);
        bm.postBond(IBondManager.BondKind.MM);
    }

    // ───────────────────────────── settlement oracle ─────────────────────────────

    /// @dev Warps to `expiry` when needed.
    function settle(uint256 priceSeed, uint256 pathSeed) external count {
        _settle(priceSeed, pathSeed);
    }

    function _settle(uint256 priceSeed, uint256 pathSeed) internal {
        VaultState st = vault.state();
        if (st != VaultState.LIVE && st != VaultState.HALTED) return;
        uint256 id = vault.currentSeriesId();
        uint64 expiry = vault.series(id).expiry;
        if (block.timestamp < expiry) vm.warp(expiry + pathSeed % 3600);
        uint256 sRef = ah.auctions(id).sRef;
        uint128 price = uint128(bound(priceSeed, sRef / 2, sRef * 2));
        uint8 path = st == VaultState.LIVE ? uint8(1 + pathSeed % 3) : uint8(4 + pathSeed % 2);
        vm.prank(settlement);
        vault.settleSeries(id, price, path);
        settles++;
    }

    function halt(uint256 s) external count {
        if (vault.state() != VaultState.LIVE || s % 4 != 0) return;
        uint256 id = vault.currentSeriesId();
        uint64 expiry = vault.series(id).expiry;
        if (block.timestamp < expiry) vm.warp(expiry);
        vm.prank(settlement);
        vault.haltSeries(id, "TEST");
    }

    // ───────────────────────────── external actors ─────────────────────────────

    function flush() external count {
        if (fr.pending(address(vault)) == 0) return;
        fr.flush(address(vault));
    }

    function freeze(uint256 s, bool on) external count {
        usdg.setFrozen(_mm(s), on);
    }

    /// @dev Issuer burn during the auction window: exercises `min(offeredQty, totalAssets())` at clear.
    function issuerBurn(uint256 frac) external count {
        if (vault.state() != VaultState.AUCTION) return;
        uint256 free = vault.freeAssets();
        if (free < 2) return;
        uint256 amt = bound(frac, 1, free / 2);
        vm.prank(admin);
        stock.burn(address(vault), amt);
        issuerBurned += amt;
    }

    function setFeeBps(uint256 s) external count {
        vm.prank(admin);
        fr.setFeeBps(address(vault), uint16(bound(s, 0, 2000)));
    }

    // ───────────────────────────── time ─────────────────────────────

    /// @dev Structured time travel: to the close of an open auction, to the expiry of a live series, or to
    /// the next open slot when IDLE.
    function advance(uint256 seed) external count {
        VaultState st = vault.state();
        if (st == VaultState.AUCTION) {
            uint64 close = ah.auctions(ah.currentAuction(address(vault))).auctionClose;
            if (block.timestamp < close) vm.warp(close + seed % 3600);
        } else if (st == VaultState.LIVE || st == VaultState.HALTED) {
            uint64 expiry = vault.series(vault.currentSeriesId()).expiry;
            if (block.timestamp < expiry) vm.warp(expiry + seed % 3600);
        } else {
            vm.warp(_nextSlot(seed % 2 == 0, block.timestamp) + seed % 1800);
        }
    }

    function jitter(uint256 seed) external count {
        vm.warp(block.timestamp + seed % 300);
    }

    function _nextSlot(bool weekday, uint256 t) internal view returns (uint256 slot) {
        uint256 week = ah.WEEK();
        uint256 ws = t - (t % week);
        if (weekday) {
            slot = ws + ah.MON_1400();
            if (slot + ah.openTolerance() <= t) slot += week;
        } else {
            slot = ws + ah.FRI_1930() + ah.WEEKEND_GAP();
            if (slot + 2 hours <= t) slot += week;
            uint256 last = ah.lastWeekdayExpiry(address(vault)) + ah.WEEKEND_GAP();
            if (last > slot && last < slot + 2 hours) slot = last;
        }
        if (slot < t) slot = t;
    }
}
