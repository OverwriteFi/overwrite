// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {AuctionBaseTest} from "./AuctionBase.t.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {IAuctionHouse} from "../src/interfaces/IAuctionHouse.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Exposes the pure clearing math (SPEC §8.2 steps 1-4) for direct fuzzing.
contract ClearingHarness is AuctionHouse {
    constructor(address u, address b, address f, address p, address o) AuctionHouse(u, b, f, p, o) {}

    function compute(uint256[] memory qty, uint256[] memory price, uint256 remaining)
        external
        pure
        returns (uint256[] memory fills, uint256 cp, uint256 filled)
    {
        uint256[] memory idx = _sortIdx(price);
        cp = _clearingPrice(qty, price, idx, remaining);
        (fills, filled) = _allocate(qty, price, idx, remaining, cp);
    }
}

/// @notice Fuzz tests: clearing math (no over-allocation, price priority, pro-rata conservation), escrow
/// accounting exact to the unit (THREAT-MODEL T-09.2/T-09.3), strike grid (T-09.4), preview == clear.
contract AuctionHouseFuzzTest is AuctionBaseTest {
    ClearingHarness internal h;
    address[] internal pool;
    bytes32 internal constant BID_FILLED = keccak256("BidFilled(uint256,address,uint256,uint256,uint256)");

    function setUp() public override {
        super.setUp();
        h = new ClearingHarness(address(usdg), address(bm), address(fr), address(priceSource), admin);
        pool = [mm1, mm2, mm3, mm4, _newMM("mm5"), _newMM("mm6"), _newMM("mm7"), _newMM("mm8")];
    }

    function _rand(uint256 seed, uint256 i, bytes1 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, tag)));
    }

    // ───────────────────────────── pure clearing math ─────────────────────────────

    /// @dev SPEC §8.2 steps 2-4: Σ fills == min(Σ qty, remaining); no bid over-filled; strict price priority;
    /// the marginal group is pro-rata floor with the dust carried to the earliest bids in order (D-048).
    function testFuzz_T07_proRataMarginalFillConservesQty(uint256 seed, uint8 nRaw, uint256 remaining) public view {
        uint256 n = 1 + nRaw % 64;
        remaining = bound(remaining, 1, 500e18);
        uint256[] memory qty = new uint256[](n);
        uint256[] memory price = new uint256[](n);
        uint256 sumQty;
        for (uint256 i; i < n; ++i) {
            qty[i] = 1e17 + _rand(seed, i, "q") % 100e18;
            price[i] = 1e6 * (1 + _rand(seed, i, "p") % 6);
            sumQty += qty[i];
        }
        (uint256[] memory fills, uint256 cp, uint256 filled) = h.compute(qty, price, remaining);

        assertEq(filled, Math.min(sumQty, remaining), "filled == min(demand, supply)");
        uint256 sumFills;
        uint256 above;
        uint256 marginal;
        bool cpIsABid;
        for (uint256 i; i < n; ++i) {
            sumFills += fills[i];
            assertLe(fills[i], qty[i], "never over-fill a bid");
            if (price[i] > cp) {
                assertEq(fills[i], qty[i], "above cp: full");
                above += qty[i];
            } else if (price[i] < cp) {
                assertEq(fills[i], 0, "below cp: nothing");
            } else {
                marginal += qty[i];
                cpIsABid = true;
            }
        }
        assertEq(sumFills, filled, "sum of fills");
        assertTrue(cpIsABid, "clearing price is a bid price");
        assertLe(above, remaining, "full fills never exceed supply");

        uint256 remM = remaining - above;
        if (marginal <= remM) {
            for (uint256 i; i < n; ++i) {
                if (price[i] == cp) assertEq(fills[i], qty[i], "marginal group fits: full");
            }
        } else {
            bool noDustSeen;
            for (uint256 i; i < n; ++i) {
                if (price[i] != cp) continue;
                uint256 floorFill = Math.mulDiv(qty[i], remM, marginal);
                assertGe(fills[i], floorFill, "at least the floor pro-rata share");
                if (fills[i] > floorFill) {
                    assertFalse(noDustSeen, "dust receivers form a prefix in bidId order");
                } else {
                    noDustSeen = true;
                }
            }
        }
    }

    /// @dev cp is the lowest price among filled bids and every filled bid is at or above it.
    function testFuzz_clearingPriceIsLowestAcceptedBid(uint256 seed, uint8 nRaw, uint256 remaining) public view {
        uint256 n = 1 + nRaw % 64;
        remaining = bound(remaining, 1, 500e18);
        uint256[] memory qty = new uint256[](n);
        uint256[] memory price = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            qty[i] = 1e17 + _rand(seed, i, "q") % 10e18;
            price[i] = 1 + _rand(seed, i, "p") % 1e9;
        }
        (uint256[] memory fills, uint256 cp,) = h.compute(qty, price, remaining);
        uint256 minFilled = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            if (fills[i] > 0 && price[i] < minFilled) minFilled = price[i];
        }
        assertEq(cp, minFilled);
    }

    // ───────────────────────────── real contract ─────────────────────────────

    struct Parsed {
        uint256[] fills;
        uint256[] refunds;
        uint256 sumFills;
        uint256 sumRefunds;
    }

    function _placeBids(uint256 id, uint256 seed, uint256 n, uint256 offered)
        internal
        returns (uint256[] memory escrows, uint256 sumEscrow)
    {
        escrows = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address mm = pool[i % pool.length];
            uint256 qty = 1e17 + _rand(seed, i, "q") % (3 * offered);
            uint256 price = uint256(RESERVE) * (1 + _rand(seed, i, "p") % 6);
            escrows[i] = _escrow(qty, price);
            sumEscrow += escrows[i];
            _bid(mm, id, qty, price);
        }
    }

    function _parse(Vm.Log[] memory logs, uint256 n) internal view returns (Parsed memory p) {
        p.fills = new uint256[](n);
        p.refunds = new uint256[](n);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(ah) || logs[i].topics[0] != BID_FILLED) continue;
            (uint256 bidId, uint256 f, uint256 r) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            p.fills[bidId] = f;
            p.refunds[bidId] = r;
            p.sumFills += f;
            p.sumRefunds += r;
        }
    }

    /// @dev I-3 and T-09.2 through the real contract: `Σ refund + premiumNet + fee == Σ escrow` to the unit,
    /// per-bid `refund == escrow − floor(fill × cp / 1e18)`, no over-allocation, locks iff filled.
    function testFuzz_T09_escrowRefundPaymentConserve(uint256 seed, uint8 nRaw, uint256 depositAmt) public {
        depositAmt = bound(depositAmt, 1e18, 500e18);
        _deposit(alice, depositAmt);
        uint256 id = _openDefault();
        uint256 offered = ah.auctions(id).offeredQty;
        uint256 n = 1 + nRaw % 64;
        (uint256[] memory escrows, uint256 sumEscrow) = _placeBids(id, seed, n, offered);
        assertEq(usdg.balanceOf(address(ah)), sumEscrow);

        _close(id);
        vm.recordLogs();
        (uint256 cp, uint256 filled, uint256 gross, uint256 fee) = ah.clear(id);
        Parsed memory p = _parse(vm.getRecordedLogs(), n);

        assertLe(filled, offered, "no over-allocation");
        assertGe(cp, RESERVE);
        _checkBids(id, escrows, p, cp, filled, gross);
        assertEq(p.sumRefunds + gross, sumEscrow, "conservation to the unit");
        assertEq(fee, Math.mulDiv(gross, 1000, 1e4));
        _checkBalances(id, filled, gross, fee, p.sumRefunds);
    }

    /// @dev Per-bid: refund == escrow − floor(fill × cp), strict price priority, cp = lowest accepted price,
    /// premiumGross = Σ payments (D-043).
    function _checkBids(
        uint256 id,
        uint256[] memory escrows,
        Parsed memory p,
        uint256 cp,
        uint256 filled,
        uint256 gross
    ) internal view {
        IAuctionHouse.Bid[] memory bs = ah.bids(id);
        assertEq(p.sumFills, filled, "BidFilled events sum to filledQty");
        uint256 sumPayments;
        uint256 minFilledPrice = type(uint256).max;
        for (uint256 i; i < bs.length; ++i) {
            uint256 payment = Math.mulDiv(p.fills[i], cp, WAD);
            assertEq(p.refunds[i], escrows[i] - payment, "refund == escrow - payment");
            assertLe(p.fills[i], bs[i].qty);
            if (bs[i].price > cp) assertEq(p.fills[i], bs[i].qty, "price priority: above cp full");
            if (bs[i].price < cp) assertEq(p.fills[i], 0, "price priority: below cp empty");
            if (p.fills[i] > 0 && bs[i].price < minFilledPrice) minFilledPrice = bs[i].price;
            sumPayments += payment;
        }
        assertEq(cp, minFilledPrice, "uniform price = lowest accepted bid");
        assertEq(gross, sumPayments, "premiumGross == sum of floored payments (D-043)");
    }

    /// @dev I-3 balances, allocation identity, locks iff filled, vault side.
    function _checkBalances(uint256 id, uint256 filled, uint256 gross, uint256 fee, uint256 sumRefunds) internal view {
        uint256 sumRefundable;
        uint256 sumClaimable;
        for (uint256 i; i < pool.length; ++i) {
            sumRefundable += ah.refundable(pool[i]);
            uint256 c = ah.claimableOptions(id, pool[i]);
            sumClaimable += c;
            assertEq(bm.isLocked(pool[i], id), c > 0, "locked iff filled");
        }
        assertEq(sumRefundable, sumRefunds);
        assertEq(usdg.balanceOf(address(ah)), sumRefundable, "I-3: balance == refundable");
        assertEq(usdg.balanceOf(address(vault)), gross - fee, "vault holds premiumNet");
        assertEq(fr.pending(address(vault)), fee);
        assertEq(usdg.balanceOf(address(fr)), fee);
        assertEq(sumClaimable, filled, "allocation identity");
        assertEq(vault.series(id).filledQty, filled);
        assertEq(uint256(vault.state()), uint256(VaultState.LIVE));
    }

    /// @dev `previewClear` is a pure mirror of `clear`.
    function testFuzz_previewMatchesClear(uint256 seed, uint8 nRaw, uint256 depositAmt) public {
        depositAmt = bound(depositAmt, 1e18, 200e18);
        _deposit(alice, depositAmt);
        uint256 id = _openDefault();
        uint256 n = nRaw % 33; // may be 0 → skip
        _placeBids(id, seed, n, ah.auctions(id).offeredQty);
        _close(id);
        (uint256 pCp, uint256 pFilled, uint256 pGross, bool pSkip) = ah.previewClear(id);
        (uint256 cp, uint256 filled, uint256 gross,) = ah.clear(id);
        assertEq(pSkip, n == 0);
        assertEq(pCp, cp);
        assertEq(pFilled, filled);
        assertEq(pGross, gross);
    }

    /// @dev Every escrow is fully accounted after the skip path too.
    function testFuzz_skipRefundsEverything(uint256 seed, uint8 nRaw) public {
        _deposit(alice, 100e18);
        uint256 id = _openDefault();
        uint256 n = 1 + nRaw % 64;
        (, uint256 sumEscrow) = _placeBids(id, seed, n, 100e18);
        vm.warp(vault.series(id).expiry); // D-045: clear after expiry skips
        ah.clear(id);
        uint256 sumRefundable;
        for (uint256 i; i < pool.length; ++i) {
            sumRefundable += ah.refundable(pool[i]);
            assertEq(bm.activeLocks(pool[i]), 0);
        }
        assertEq(sumRefundable, sumEscrow);
        assertEq(usdg.balanceOf(address(ah)), sumEscrow);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
    }

    // ───────────────────────────── strike / reserve math ─────────────────────────────

    /// @dev SPEC §7.2: K ≥ K_raw, on the grid, and at most one grid step above (T-09.4).
    function testFuzz_T09_strikeGridRoundsUpAtMostOneStep(uint256 sRef, uint16 dist) public view {
        sRef = bound(sRef, 400, 1e15);
        dist = uint16(bound(dist, 100, 1500));
        uint256 grid = sRef * 25 / 1e4;
        uint256 kRaw = sRef * (1e4 + dist) / 1e4;
        uint256 k = ah.computeStrike(sRef, dist);
        assertGe(k, kRaw);
        assertLt(k - kRaw, grid);
        assertEq(k % grid, 0);
        assertGt(k, sRef, "always OTM");
    }

    function testFuzz_T09_gridZeroReverts(uint256 sRef) public {
        sRef = bound(sRef, 1, 399);
        vm.expectRevert(AuctionHouse.GridZero.selector);
        ah.computeStrike(sRef, 800);
    }

    /// @dev Reserve floor never exceeds the spot cap for any curator floor in [1, 500] bps.
    function testFuzz_reserveBoundsOrdered(uint256 sRef, uint16 bps) public {
        sRef = bound(sRef, 100, 1e15);
        bps = uint16(bound(bps, 1, 500));
        vm.prank(admin);
        ah.setMinReserveBpsOfSpot(address(vault), SeriesKind.WEEKDAY, bps);
        (uint256 lo, uint256 hi) = ah.reserveBounds(address(vault), SeriesKind.WEEKDAY, sRef);
        assertLe(lo, hi);
        assertEq(hi, sRef / 1e2);
        assertEq(lo, Math.mulDiv(sRef, bps, 1e6));
    }

    /// @dev T-09.2: payment ≤ escrow whenever cp ≤ price and fill ≤ qty (both floored).
    function testFuzz_T09_paymentNeverExceedsEscrow(uint256 qty, uint256 price, uint256 cp, uint256 fill) public pure {
        qty = bound(qty, 1e17, 1e30);
        price = bound(price, 1, 1e12);
        cp = bound(cp, 1, price);
        fill = bound(fill, 0, qty);
        assertLe(Math.mulDiv(fill, cp, 1e18), Math.mulDiv(qty, price, 1e18));
    }
}
