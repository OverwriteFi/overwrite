// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuctionBaseTest} from "./AuctionBase.t.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {BondManager} from "../src/BondManager.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {MockStockToken} from "../src/mocks/MockStockToken.sol";
import {IAuctionHouse} from "../src/interfaces/IAuctionHouse.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {ICoveredCallVault} from "../src/interfaces/ICoveredCallVault.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @notice Unit tests for AuctionHouse: one per external function including every revert path (SPEC §5, §7.2, §8).
contract AuctionHouseTest is AuctionBaseTest {
    uint256 internal constant DEPOSIT = 100e18; // offeredQty = 100 options

    function setUp() public override {
        super.setUp();
        _deposit(alice, DEPOSIT);
    }

    // ───────────────────────────── registerVault ─────────────────────────────

    function test_registerVault_defaults() public view {
        assertTrue(ah.isVault(address(vault)));
        assertEq(address(ah.optionToken()), address(opt));
        assertEq(address(vault.optionToken()), address(opt));
        assertEq(ah.minStrikeDistanceBps(address(vault), SeriesKind.WEEKDAY), 300);
        assertEq(ah.minStrikeDistanceBps(address(vault), SeriesKind.WEEKEND), 100);
        assertEq(ah.minReserveBpsOfSpot(address(vault), SeriesKind.WEEKDAY), 10);
        assertEq(ah.minReserveBpsOfSpot(address(vault), SeriesKind.WEEKEND), 3);
        assertEq(fr.feeBps(address(vault)), 1000);
        assertTrue(fr.initialised(address(vault)));
    }

    function test_registerVault_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.AlreadyRegistered.selector, address(vault)));
        ah.registerVault(address(vault));
        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        ah.registerVault(address(0));
        CoveredCallVault stray = new CoveredCallVault(
            CoveredCallVault.Config({
                stock: address(stock),
                usdg: address(usdg),
                optionToken: address(opt),
                auctionHouse: bob,
                settlement: settlement,
                riskModule: address(risk),
                capController: address(cap),
                owner: admin,
                name: "x",
                symbol: "x"
            })
        );
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.VaultNotWired.selector, address(stray)));
        ah.registerVault(address(stray));
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ah.registerVault(address(stray));
    }

    // ───────────────────────────── openAuction ─────────────────────────────

    function test_open_happyPath() public {
        uint64 exp = _fridayExpiry();
        vm.expectEmit(true, true, false, true);
        emit AuctionHouse.AuctionOpened(
            address(vault),
            1,
            SeriesKind.WEEKDAY,
            uint64(MONDAY_1400),
            uint64(MONDAY_1400 + 900),
            exp,
            PRICE,
            K_DEFAULT,
            DEPOSIT,
            RESERVE,
            1e18
        );
        vm.prank(keeper);
        uint256 id = ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        assertEq(id, 1);
        IAuctionHouse.Auction memory a = ah.auctions(id);
        assertEq(a.vault, address(vault));
        assertEq(uint256(a.kind), uint256(SeriesKind.WEEKDAY));
        assertEq(uint256(a.state), uint256(IAuctionHouse.AuctionState.OPEN));
        assertEq(a.auctionOpen, MONDAY_1400);
        assertEq(a.auctionClose, MONDAY_1400 + 900);
        assertEq(a.expiry, exp);
        assertEq(a.sRef, PRICE);
        assertEq(a.strike, K_DEFAULT);
        assertEq(a.offeredQty, DEPOSIT);
        assertEq(a.reservePrice, RESERVE);
        assertEq(a.clearingPrice, 0);
        assertEq(ah.currentAuction(address(vault)), 1);
        assertEq(ah.lastWeekdayExpiry(address(vault)), exp);
        assertEq(uint256(vault.state()), uint256(VaultState.AUCTION));
        assertEq(vault.series(1).strike, K_DEFAULT);
        assertEq(vault.series(1).expiry, exp);
    }

    function test_open_strikeRoundsUpToGrid() public {
        // 200 × 1.0803 = 216.06 → next 0.5 grid step = 216.50
        uint256 id = _open(803, RESERVE);
        assertEq(ah.auctions(id).strike, 216.5e8);
        assertEq(ah.computeStrike(PRICE, 803), 216.5e8);
        assertEq(ah.computeStrike(PRICE, 800), 216e8);
    }

    function test_open_nonKeeperReverts() public {
        uint64 exp = _fridayExpiry();
        bytes32 role = ah.KEEPER_ROLE(); // read before pranking: a view call inside the args would eat the prank
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        // admin (owner) is not a keeper either
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        // revoked keeper
        vm.prank(admin);
        ah.setKeeper(keeper, false);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, role));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    function test_open_weekdayWindow() public {
        uint64 exp = _fridayExpiry();
        vm.warp(MONDAY_1400 + 7201);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("OPEN_WINDOW")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        vm.warp(MONDAY_1400 - 7201);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("OPEN_WINDOW")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        vm.warp(MONDAY_1400 - 7200); // edge of the tolerance
        (bool ok,) = ah.canOpen(address(vault), SeriesKind.WEEKDAY, exp, uint64(block.timestamp));
        assertTrue(ok);
        assertEq(_openDefault(), 1);
        // a Tuesday is never valid, whatever the tolerance
        (ok,) = ah.canOpen(address(vault), SeriesKind.WEEKDAY, exp, uint64(MONDAY_1400 + 1 days));
        assertFalse(ok);
    }

    function test_open_weekdayExpiryBounds() public {
        uint64 exp = _fridayExpiry(); // Friday 20:00 UTC
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("EXPIRY")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp - 31 minutes, DIST, RESERVE);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("EXPIRY")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp + 91 minutes, DIST, RESERVE);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("EXPIRY")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp + 7 days, DIST, RESERVE);
        // 21:00 UTC (EST close) is inside the window
        vm.prank(keeper);
        uint256 id = ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp + 1 hours, DIST, RESERVE);
        assertEq(ah.auctions(id).expiry, exp + 1 hours);
    }

    function test_open_distanceBounds() public {
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.DistanceOutOfBounds.selector, 299, 300, 1500));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, 299, RESERVE);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.DistanceOutOfBounds.selector, 1501, 300, 1500));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, 1501, RESERVE);
        vm.prank(admin);
        ah.setMinStrikeDistanceBps(address(vault), SeriesKind.WEEKDAY, 500);
        (uint16 lo, uint16 hi) = ah.strikeDistanceBounds(address(vault), SeriesKind.WEEKDAY);
        assertEq(lo, 500);
        assertEq(hi, 1500);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.DistanceOutOfBounds.selector, 400, 500, 1500));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, 400, RESERVE);
        assertEq(_open(500, RESERVE), 1);
    }

    function test_open_reserveBounds() public {
        uint64 exp = _fridayExpiry();
        (uint256 lo, uint256 hi) = ah.reserveBounds(address(vault), SeriesKind.WEEKDAY, PRICE);
        assertEq(lo, 200_000, "10 bps of $200 = 0.20 USDG");
        assertEq(hi, 200e6, "spot = 200 USDG");
        uint256[3] memory bad = [uint256(0), lo - 1, hi + 1];
        for (uint256 i; i < bad.length; ++i) {
            uint128 r = uint128(bad[i]);
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(AuctionHouse.ReserveOutOfBounds.selector, r, lo, hi));
            ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, r);
        }
        uint256 id = _open(DIST, uint128(hi));
        assertEq(ah.auctions(id).reservePrice, hi);
    }

    function test_open_noReferencePrice() public {
        uint64 exp = _fridayExpiry();
        priceSource.set(address(vault), PRICE, false);
        vm.prank(keeper);
        vm.expectRevert(AuctionHouse.NoReferencePrice.selector);
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        priceSource.set(address(vault), 0, true);
        vm.prank(keeper);
        vm.expectRevert(AuctionHouse.NoReferencePrice.selector);
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    function test_open_gridZero() public {
        uint64 exp = _fridayExpiry();
        priceSource.set(address(vault), 399, true);
        vm.prank(keeper);
        vm.expectRevert(AuctionHouse.GridZero.selector);
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, 1);
    }

    function test_open_vaultReasonPassthrough() public {
        uint64 exp = _fridayExpiry();
        risk.setAuctionsPaused(address(vault), true);
        (bool ok, bytes32 reason) = ah.canOpen(address(vault), SeriesKind.WEEKDAY, exp, uint64(block.timestamp));
        assertFalse(ok);
        assertEq(reason, bytes32("AUCTIONS_PAUSED"));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("AUCTIONS_PAUSED")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    function test_open_notRegistered() public {
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("NOT_REGISTERED")));
        ah.openAuction(bob, SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    function test_open_offerTooSmall() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        _deposit(alice, 5e16);
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.OfferTooSmall.selector, 5e16, 1e17));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    function test_open_twiceReverts() public {
        _openDefault();
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("NOT_IDLE")));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    function test_open_weekendAfterWeekday() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _clear(id);
        _settle(id, 210e8); // Friday 20:00, vault IDLE
        uint64 sun = _sundayExpiry();
        (bool ok, bytes32 reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun, uint64(block.timestamp));
        assertFalse(ok);
        assertEq(reason, bytes32("WEEKDAY_GAP"));
        vm.warp(block.timestamp + 599);
        (ok, reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun, uint64(block.timestamp));
        assertEq(reason, bytes32("WEEKDAY_GAP"));
        vm.warp(block.timestamp + 1);
        uint256 id2 = _openWeekend(300, RESERVE);
        assertEq(id2, 2);
        IAuctionHouse.Auction memory a = ah.auctions(id2);
        assertEq(uint256(a.kind), uint256(SeriesKind.WEEKEND));
        assertEq(a.expiry, sun);
        assertEq(a.expiry % WEEK, ah.SUN_2359());
        assertEq(a.strike, ah.computeStrike(PRICE, 300));
        assertEq(ah.lastWeekdayExpiry(address(vault)), vault.series(id).expiry, "weekend does not touch it");
    }

    function test_open_weekendStandaloneWindow() public {
        uint256 ws = MONDAY_1400 - (MONDAY_1400 % WEEK) + WEEK; // Thursday after the first Monday
        uint256 friOpen = ws + ah.FRI_1930() + 600;
        uint64 sun = uint64(ws + ah.SUN_2359());
        vm.warp(friOpen - 1);
        (bool ok, bytes32 reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun, uint64(block.timestamp));
        assertFalse(ok);
        assertEq(reason, bytes32("OPEN_WINDOW"));
        vm.warp(ws + ah.FRI_2130() + 600 + 7200 + 1);
        (ok, reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun, uint64(block.timestamp));
        assertEq(reason, bytes32("OPEN_WINDOW"));
        vm.warp(ws + 2 days + 12 hours); // Saturday noon
        (ok, reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun, uint64(block.timestamp));
        assertEq(reason, bytes32("OPEN_WINDOW"));
        vm.warp(friOpen);
        (ok, reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun - 60, uint64(block.timestamp));
        assertEq(reason, bytes32("EXPIRY"));
        (ok, reason) = ah.canOpen(address(vault), SeriesKind.WEEKEND, sun, uint64(block.timestamp));
        assertTrue(ok);
        assertEq(_sundayExpiry(), sun);
        uint256 id = _openWeekend(100, RESERVE);
        assertEq(ah.auctions(id).expiry, sun);
    }

    /// @dev Audit F-2: a clear that arrives after `clearGrace` skips, so a bidder cannot wait for the stock to
    /// move and then take an ITM option at Monday's price.
    function test_clear_afterGraceSkips() public {
        uint256 id = _open(DIST, RESERVE);
        _bid(mm1, id, 100e18, RESERVE);
        uint64 close = ah.auctions(id).auctionClose;
        vm.warp(close + ah.clearGrace() - 1);
        (,,, bool willSkip) = ah.previewClear(id);
        assertFalse(willSkip, "inside the grace window the clear fills");
        vm.warp(close + ah.clearGrace());
        (,,, willSkip) = ah.previewClear(id);
        assertTrue(willSkip, "at the deadline the clear skips");
        (uint256 cp, uint256 filled,,) = ah.clear(id);
        assertEq(cp, 0);
        assertEq(filled, 0);
        assertEq(uint8(ah.auctions(id).state), uint8(IAuctionHouse.AuctionState.SKIPPED));
        assertEq(ah.refundable(mm1), 100e18 * RESERVE / 1e18, "escrow fully refundable");
        assertEq(uint8(vault.state()), uint8(VaultState.IDLE));
    }

    function test_setClearGrace_bounds() public {
        uint64 lo = ah.MIN_CLEAR_GRACE();
        uint64 hi = ah.MAX_CLEAR_GRACE();
        vm.startPrank(admin);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setClearGrace(lo - 1);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setClearGrace(hi + 1);
        ah.setClearGrace(2 hours);
        assertEq(ah.clearGrace(), 2 hours);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ah.setClearGrace(1 hours);
    }

    // ───────────────────────────── bid ─────────────────────────────

    function test_bid_happy() public {
        uint256 id = _openDefault();
        vm.expectEmit(true, true, false, true);
        emit AuctionHouse.BidPlaced(id, mm1, 0, 50e18, 2e6, 100e6);
        uint256 bidId = _bid(mm1, id, 50e18, 2e6);
        assertEq(bidId, 0);
        assertEq(usdg.balanceOf(address(ah)), 100e6);
        IAuctionHouse.Bid[] memory bs = ah.bids(id);
        assertEq(bs.length, 1);
        assertEq(bs[0].bidder, mm1);
        assertEq(bs[0].qty, 50e18);
        assertEq(bs[0].price, 2e6);
        assertEq(bs[0].escrow, 100e6);
        assertEq(ah.bidCount(id, mm1), 1);
        assertEq(ah.bidders(id).length, 1);
        assertTrue(bm.isLocked(mm1, id));
        assertEq(bm.activeLocks(mm1), 1);
        // second bid of the same bidder: new escrow, no second lock
        assertEq(_bid(mm1, id, 10e18, 3e6), 1);
        assertEq(ah.bidCount(id, mm1), 2);
        assertEq(ah.bidders(id).length, 1);
        assertEq(bm.activeLocks(mm1), 1);
        assertEq(usdg.balanceOf(address(ah)), 130e6);
    }

    function test_bid_reverts() public {
        uint256 id = _openDefault();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.NoActiveBond.selector, alice));
        ah.bid(id, 1e18, 2e6);
        vm.prank(mm1);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.NONE)
        );
        ah.bid(99, 1e18, 2e6);
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.BidTooSmall.selector, 1e17 - 1, 1e17));
        ah.bid(id, 1e17 - 1, 2e6);
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.BelowReserve.selector, RESERVE - 1, RESERVE));
        ah.bid(id, 1e18, RESERVE - 1);
        for (uint256 i; i < 8; ++i) {
            _bid(mm1, id, 1e18, 2e6);
        }
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.TooManyBidsPerBidder.selector, 8));
        ah.bid(id, 1e18, 2e6);
        vm.warp(block.timestamp + 900);
        vm.prank(mm2);
        vm.expectRevert(AuctionHouse.AuctionClosed.selector);
        ah.bid(id, 1e18, 2e6);
        ah.clear(id);
        vm.prank(mm2);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.CLEARED)
        );
        ah.bid(id, 1e18, 2e6);
    }

    function test_bid_onSkippedAuctionReverts() public {
        uint256 id = _openDefault();
        _clear(id); // no bids → SKIPPED
        vm.prank(mm1);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.SKIPPED)
        );
        ah.bid(id, 1e18, 2e6);
    }

    function test_bid_zeroEscrowReverts() public {
        priceSource.set(address(vault), 1000, true); // $0.00001: reserve floor rounds to 0, cap is 10 units
        uint256 id = _open(DIST, 1);
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.ZeroEscrow.selector);
        ah.bid(id, 1e17, 1);
        _bid(mm1, id, 1e18, 1); // 1e18 × 1 / 1e18 = 1 unit
    }

    function test_bid_afterWithdrawRequestReverts() public {
        uint256 id = _openDefault();
        vm.prank(mm1);
        bm.requestWithdraw(IBondManager.BondKind.MM);
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.NoActiveBond.selector, mm1));
        ah.bid(id, 1e18, 2e6);
    }

    // ───────────────────────────── clear ─────────────────────────────

    function test_clear_reverts() public {
        uint256 id = _openDefault();
        vm.expectRevert(AuctionHouse.AuctionNotClosed.selector);
        ah.clear(id);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.NONE)
        );
        ah.clear(99);
        _clear(id);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.SKIPPED)
        );
        ah.clear(id);
    }

    function test_clear_singleBid() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _close(id);
        (uint256 pCp, uint256 pFilled, uint256 pGross, bool pSkip) = ah.previewClear(id);
        vm.expectEmit(true, true, false, true);
        emit AuctionHouse.BidFilled(id, mm1, 0, 50e18, 0);
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.AuctionCleared(id, 2e6, 50e18, 100e6, 10e6);
        vm.prank(bob); // permissionless
        (uint256 cp, uint256 filled, uint256 gross, uint256 fee) = ah.clear(id);
        assertEq(cp, 2e6);
        assertEq(filled, 50e18);
        assertEq(gross, 100e6);
        assertEq(fee, 10e6);
        assertFalse(pSkip);
        assertEq(pCp, cp);
        assertEq(pFilled, filled);
        assertEq(pGross, gross);
        assertEq(ah.refundable(mm1), 0);
        assertEq(ah.claimableOptions(id, mm1), 50e18);
        assertEq(usdg.balanceOf(address(vault)), 90e6, "net premium pulled by the vault");
        assertEq(fr.pending(address(vault)), 10e6);
        assertEq(usdg.balanceOf(address(fr)), 0, "fee is pulled by flush, never pushed (D-049)");
        assertEq(usdg.balanceOf(address(ah)), 10e6);
        assertEq(uint256(vault.state()), uint256(VaultState.LIVE));
        assertEq(vault.series(id).filledQty, 50e18);
        assertEq(vault.premiumClaimable(alice), 90e6);
        IAuctionHouse.Auction memory a = ah.auctions(id);
        assertEq(uint256(a.state), uint256(IAuctionHouse.AuctionState.CLEARED));
        assertEq(a.clearingPrice, 2e6);
        assertEq(a.filledQty, 50e18);
        assertEq(a.premiumGross, 100e6);
        assertEq(a.fee, 10e6);
        assertTrue(bm.isLocked(mm1, id), "filled bidder stays locked");
        (uint256 sCp, uint256 sFilled, uint256 sGross, bool sSkip) = ah.previewClear(id);
        assertEq(sCp, 2e6);
        assertEq(sFilled, 50e18);
        assertEq(sGross, 100e6);
        assertFalse(sSkip);
    }

    function test_clear_multiplePrices() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 60e18, 3e6);
        _bid(mm2, id, 60e18, 2e6);
        _bid(mm3, id, 60e18, 1.5e6);
        assertEq(usdg.balanceOf(address(ah)), 180e6 + 120e6 + 90e6);
        (uint256 cp, uint256 filled, uint256 gross, uint256 fee) = _clear(id);
        assertEq(cp, 2e6);
        assertEq(filled, 100e18);
        assertEq(gross, 120e6 + 80e6);
        assertEq(fee, 20e6);
        assertEq(ah.claimableOptions(id, mm1), 60e18);
        assertEq(ah.claimableOptions(id, mm2), 40e18);
        assertEq(ah.claimableOptions(id, mm3), 0);
        assertEq(ah.refundable(mm1), 60e6, "paid 120 at the uniform price, escrowed 180");
        assertEq(ah.refundable(mm2), 40e6);
        assertEq(ah.refundable(mm3), 90e6);
        assertEq(usdg.balanceOf(address(ah)), 190e6 + 20e6, "I-3: balance == sum of refundable + pending fee");
        assertTrue(bm.isLocked(mm1, id));
        assertTrue(bm.isLocked(mm2, id));
        assertFalse(bm.isLocked(mm3, id), "unfilled bidder unlocked at clear");
        assertEq(bm.activeLocks(mm3), 0);
    }

    function test_clear_undersubscribed() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 30e18, 3e6);
        _bid(mm2, id, 20e18, 2e6);
        (uint256 cp, uint256 filled, uint256 gross,) = _clear(id);
        assertEq(cp, 2e6, "lowest accepted bid");
        assertEq(filled, 50e18);
        assertEq(gross, 60e6 + 40e6);
        assertEq(ah.refundable(mm1), 30e6);
        assertEq(ah.refundable(mm2), 0);
    }

    function test_clear_tieProRata() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 40e18, 3e6);
        _bid(mm2, id, 70e18, 2e6);
        _bid(mm3, id, 50e18, 2e6);
        (uint256 cp, uint256 filled,,) = _clear(id);
        assertEq(cp, 2e6);
        assertEq(filled, 100e18);
        assertEq(ah.claimableOptions(id, mm1), 40e18);
        assertEq(ah.claimableOptions(id, mm2), 35e18, "70/120 of the remaining 60");
        assertEq(ah.claimableOptions(id, mm3), 25e18, "50/120 of the remaining 60");
        assertEq(ah.refundable(mm1), 120e6 - 80e6, "pays the uniform price, not its own");
        assertEq(ah.refundable(mm2), 140e6 - 70e6);
        assertEq(ah.refundable(mm3), 100e6 - 50e6);
    }

    function test_clear_tieDustToEarliestBid() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 40e18, 3e6);
        _bid(mm3, id, 50e18, 2e6); // earlier bidId at the marginal price
        _bid(mm2, id, 70e18 + 1, 2e6);
        (, uint256 filled,,) = _clear(id);
        assertEq(filled, 100e18);
        uint256 total = 120e18 + 1;
        uint256 f3 = Math.mulDiv(50e18, 60e18, total);
        uint256 f2 = Math.mulDiv(70e18 + 1, 60e18, total);
        uint256 dust = 60e18 - f3 - f2;
        assertGt(dust, 0, "test needs a rounding dust");
        assertEq(ah.claimableOptions(id, mm3), f3 + dust, "dust to the earliest marginal bid");
        assertEq(ah.claimableOptions(id, mm2), f2);
    }

    function test_clear_skipNoBids() public {
        uint256 id = _openDefault();
        _close(id);
        (,,, bool willSkip) = ah.previewClear(id);
        assertTrue(willSkip);
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.AuctionSkipped(id);
        (uint256 cp, uint256 filled, uint256 gross, uint256 fee) = ah.clear(id);
        assertEq(cp | filled | gross | fee, 0);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        assertEq(uint256(vault.series(id).state), uint256(SeriesState.SKIPPED));
        assertEq(uint256(ah.auctions(id).state), uint256(IAuctionHouse.AuctionState.SKIPPED));
        (,,, willSkip) = ah.previewClear(id);
        assertTrue(willSkip, "skipped auctions preview as skip");
    }

    function test_clear_skipAfterExpiry() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _bid(mm2, id, 50e18, 3e6);
        vm.warp(vault.series(id).expiry);
        (,,, bool willSkip) = ah.previewClear(id);
        assertTrue(willSkip);
        vm.expectEmit(true, true, false, true);
        emit AuctionHouse.RefundCredited(id, mm1, 100e6);
        ah.clear(id);
        assertEq(ah.refundable(mm1), 100e6);
        assertEq(ah.refundable(mm2), 150e6);
        assertEq(usdg.balanceOf(address(ah)), 250e6);
        assertEq(bm.activeLocks(mm1), 0);
        assertEq(bm.activeLocks(mm2), 0);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        assertEq(uint256(ah.auctions(id).state), uint256(IAuctionHouse.AuctionState.SKIPPED));
    }

    function test_clear_skipWhenAllSharesEscrowed() public {
        uint256 id = _openDefault();
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        _bid(mm1, id, 50e18, 2e6);
        (,,, bool willSkip) = ah.previewClear(id);
        assertTrue(willSkip, "NoSharesForPremium would revert mintSeries");
        _clear(id);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        assertEq(ah.refundable(mm1), 100e6);
        assertEq(ah.claimableOptions(id, mm1), 0);
    }

    function test_clear_coverageCapAfterIssuerBurn() public {
        uint256 id = _openDefault();
        vm.prank(admin);
        stock.burn(address(vault), 60e18);
        _bid(mm1, id, 100e18, 2e6);
        (uint256 cp, uint256 filled, uint256 gross,) = _clear(id);
        assertEq(cp, 2e6);
        assertEq(filled, 40e18, "min(offered, totalAssets)");
        assertEq(gross, 80e6);
        assertEq(ah.refundable(mm1), 120e6);
        assertEq(uint256(vault.state()), uint256(VaultState.LIVE));
        assertEq(vault.encumbered(), 40e18);
    }

    function test_clear_skipWhenNothingCoverable() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 100e18, 2e6);
        vm.prank(admin);
        stock.burn(address(vault), 100e18);
        _clear(id);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        assertEq(ah.refundable(mm1), 200e6);
    }

    function test_clear_zeroFee() public {
        vm.prank(admin);
        fr.setFeeBps(address(vault), 0);
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        (,, uint256 gross, uint256 fee) = _clear(id);
        assertEq(gross, 100e6);
        assertEq(fee, 0);
        assertEq(fr.pending(address(vault)), 0);
        assertEq(usdg.balanceOf(address(vault)), 100e6);
    }

    function test_clear_maxFee() public {
        vm.prank(admin);
        fr.setFeeBps(address(vault), 2000);
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        (,,, uint256 fee) = _clear(id);
        assertEq(fee, 20e6);
        assertEq(usdg.balanceOf(address(vault)), 80e6);
    }

    // ───────────────────────────── pull: refunds, options, payout ─────────────────────────────

    function test_withdrawRefund() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 60e18, 3e6);
        _bid(mm2, id, 40e18, 2e6);
        _bid(mm3, id, 60e18, 1.5e6); // unfilled
        _clear(id);
        vm.prank(mm3);
        vm.expectRevert(AuctionHouse.InvalidRecipient.selector);
        ah.withdrawRefund(address(0));
        vm.prank(mm3);
        vm.expectRevert(AuctionHouse.InvalidRecipient.selector);
        ah.withdrawRefund(address(ah));
        vm.expectEmit(true, true, false, true);
        emit AuctionHouse.RefundWithdrawn(mm3, bob, 90e6);
        vm.prank(mm3);
        uint256 amount = ah.withdrawRefund(bob);
        assertEq(amount, 90e6);
        assertEq(usdg.balanceOf(bob), 90e6);
        assertEq(ah.refundable(mm3), 0);
        vm.prank(mm3);
        vm.expectRevert(AuctionHouse.NothingToClaim.selector);
        ah.withdrawRefund(bob);
        assertEq(usdg.balanceOf(address(ah)), 60e6 + 20e6, "mm1's refund (180 - 60 x 2) plus the pending fee");
        assertEq(ah.refundable(mm1), 60e6);
        assertEq(ah.refundable(mm2), 0);
    }

    function test_claimOptions() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 60e18, 3e6);
        _bid(mm2, id, 40e18, 2e6);
        _bid(mm3, id, 60e18, 1.5e6); // unfilled
        _clear(id);
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.InvalidRecipient.selector);
        ah.claimOptions(id, address(0));
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.InvalidRecipient.selector);
        ah.claimOptions(id, address(ah));
        vm.prank(mm3);
        vm.expectRevert(AuctionHouse.NothingToClaim.selector);
        ah.claimOptions(id, mm3);
        vm.expectEmit(true, true, true, true);
        emit AuctionHouse.OptionsClaimed(id, mm1, bob, 60e18);
        vm.prank(mm1);
        uint256 qty = ah.claimOptions(id, bob);
        assertEq(qty, 60e18);
        assertEq(opt.balanceOf(bob, id), 60e18);
        assertEq(vault.series(id).mintedQty, 60e18);
        assertEq(ah.claimableOptions(id, mm1), 0);
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.NothingToClaim.selector);
        ah.claimOptions(id, mm1);
    }

    function test_claimPayout_itm() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _clear(id);
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.NotSettled.selector, id));
        ah.claimPayout(id, mm1);
        _settle(id, 250e8); // K = 216: payoutPerOption = 34/250 = 0.136
        uint256 ppo = vault.series(id).payoutPerOption;
        assertEq(ppo, 0.136e18);
        uint256 bobBefore = stock.balanceOf(bob);
        vm.expectEmit(true, true, true, true);
        emit AuctionHouse.PayoutClaimed(id, mm1, bob, 50e18, 6.8e18);
        vm.prank(mm1);
        (uint256 qty, uint256 tokens) = ah.claimPayout(id, bob);
        assertEq(qty, 50e18);
        assertEq(tokens, 6.8e18);
        assertEq(stock.balanceOf(bob) - bobBefore, 6.8e18);
        assertEq(opt.totalSupply(id), 0, "minted to the AuctionHouse and burned in the same tx");
        assertEq(opt.balanceOf(address(ah), id), 0);
        assertEq(vault.series(id).mintedQty, 50e18);
        assertEq(vault.series(id).claimedQty, 50e18);
        assertEq(ah.claimableOptions(id, mm1), 0);
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.NothingToClaim.selector);
        ah.claimPayout(id, bob);
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.InvalidRecipient.selector);
        ah.claimPayout(id, address(0));
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.InvalidRecipient.selector);
        ah.claimPayout(id, address(ah));
    }

    function test_claimPayout_otm() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _clear(id);
        _settle(id, 100e8);
        vm.prank(mm1);
        (uint256 qty, uint256 tokens) = ah.claimPayout(id, mm1);
        assertEq(qty, 50e18);
        assertEq(tokens, 0);
        assertEq(vault.series(id).claimedQty, 50e18);
    }

    function test_releaseLocks() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _bid(mm2, id, 50e18, 2e6);
        _clear(id);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.SeriesNotSettled.selector, SeriesState.LIVE));
        ah.releaseLocks(id);
        _settle(id, 210e8);
        assertEq(bm.activeLocks(mm1), 1, "locks survive settlement until released");
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.LocksReleased(id);
        vm.prank(bob);
        ah.releaseLocks(id);
        assertEq(bm.activeLocks(mm1), 0);
        assertEq(bm.activeLocks(mm2), 0);
        ah.releaseLocks(id); // idempotent
        assertEq(bm.activeLocks(mm1), 0);
    }

    function test_releaseLocks_wrongState() public {
        uint256 id = _openDefault();
        _clear(id); // skipped
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.SKIPPED)
        );
        ah.releaseLocks(id);
        vm.expectRevert(
            abi.encodeWithSelector(AuctionHouse.WrongAuctionState.selector, IAuctionHouse.AuctionState.NONE)
        );
        ah.releaseLocks(99);
    }

    function test_onERC1155Received_rejectsStrayTokens() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _clear(id);
        vm.prank(mm1);
        ah.claimOptions(id, mm1);
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.UnexpectedTokens.selector);
        opt.safeTransferFrom(mm1, address(ah), id, 1e18, "");
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = 1e18;
        vm.prank(mm1);
        vm.expectRevert(AuctionHouse.UnexpectedTokens.selector);
        opt.safeBatchTransferFrom(mm1, address(ah), ids, amounts, "");
        assertEq(opt.balanceOf(address(ah), id), 0);
    }

    // ───────────────────────────── admin ─────────────────────────────

    function test_setters_boundsAndEvents() public {
        vm.startPrank(admin);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setOpenTolerance(4 hours + 1);
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.ParameterChanged(address(ah), "openTolerance", 7200, 3600);
        ah.setOpenTolerance(3600);
        assertEq(ah.openTolerance(), 3600);

        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMaxBidsPerBidder(0);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMaxBidsPerBidder(65);
        ah.setMaxBidsPerBidder(64);
        assertEq(ah.maxBidsPerBidder(), 64);

        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMinBidQty(0);
        ah.setMinBidQty(1e18);
        assertEq(ah.minBidQty(), 1e18);

        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.NotRegistered.selector, bob));
        ah.setMinStrikeDistanceBps(bob, SeriesKind.WEEKDAY, 400);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMinStrikeDistanceBps(address(vault), SeriesKind.WEEKDAY, 299);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMinStrikeDistanceBps(address(vault), SeriesKind.WEEKDAY, 1501);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMinStrikeDistanceBps(address(vault), SeriesKind.WEEKEND, 99);
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.ParameterChanged(address(vault), "minStrikeDistanceWeekend", 100, 1000);
        ah.setMinStrikeDistanceBps(address(vault), SeriesKind.WEEKEND, 1000);

        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.NotRegistered.selector, bob));
        ah.setMinReserveBpsOfSpot(bob, SeriesKind.WEEKDAY, 10);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMinReserveBpsOfSpot(address(vault), SeriesKind.WEEKDAY, 0);
        vm.expectRevert(AuctionHouse.OutOfBounds.selector);
        ah.setMinReserveBpsOfSpot(address(vault), SeriesKind.WEEKDAY, 501);
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.ParameterChanged(address(vault), "minReserveWeekday", 10, 500);
        ah.setMinReserveBpsOfSpot(address(vault), SeriesKind.WEEKDAY, 500);
        (uint256 lo,) = ah.reserveBounds(address(vault), SeriesKind.WEEKDAY, PRICE);
        assertEq(lo, 10e6, "5 % of $200");

        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        ah.setPriceSource(address(0));
        ah.setPriceSource(bob);
        assertEq(address(ah.priceSource()), bob);
        // audit G-1: the freeze refuses a source without code, then disables the setter for good
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.Miswired.selector, bytes32("PRICE_SOURCE")));
        ah.freezePriceSource();
        ah.setPriceSource(address(priceSource));
        vm.expectEmit(true, false, false, true);
        emit AuctionHouse.ParameterChanged(address(ah), "priceSourceFrozen", 0, 1);
        ah.freezePriceSource();
        assertTrue(ah.priceSourceFrozen());
        vm.expectRevert(AuctionHouse.PriceSourceFrozen.selector);
        ah.setPriceSource(bob);
        vm.expectRevert(AuctionHouse.PriceSourceFrozen.selector);
        ah.freezePriceSource();
        assertEq(address(ah.priceSource()), address(priceSource), "still the frozen source");

        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        ah.setKeeper(address(0), true);
        ah.setKeeper(bob, true);
        assertTrue(ah.hasRole(ah.KEEPER_ROLE(), bob));
        assertFalse(ah.hasRole(ah.DEFAULT_ADMIN_ROLE(), admin), "no admin role is ever granted");
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ah.setOpenTolerance(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ah.setKeeper(bob, false);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ah.setPriceSource(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        ah.freezePriceSource();
        vm.stopPrank();
    }

    function test_constructor_zeroAddress() public {
        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        new AuctionHouse(address(0), address(bm), address(fr), address(priceSource), address(opt), admin);
        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        new AuctionHouse(address(usdg), address(0), address(fr), address(priceSource), address(opt), admin);
        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        new AuctionHouse(address(usdg), address(bm), address(0), address(priceSource), address(opt), admin);
        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        new AuctionHouse(address(usdg), address(bm), address(fr), address(0), address(opt), admin);
        vm.expectRevert(AuctionHouse.ZeroAddress.selector);
        new AuctionHouse(address(usdg), address(bm), address(fr), address(priceSource), address(0), admin);
    }

    /// D-049: a BondManager or FeeRouter on another USDG is rejected at construction.
    function test_constructor_rejectsMiswiredUsdg() public {
        MockUSDG usdg2 = new MockUSDG();
        BondManager bm2 = new BondManager(address(usdg2), admin, treasury);
        FeeRouter fr2 = new FeeRouter(address(usdg2), admin, treasury);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.Miswired.selector, bytes32("BOND_MANAGER_USDG")));
        new AuctionHouse(address(usdg), address(bm2), address(fr), address(priceSource), address(opt), admin);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.Miswired.selector, bytes32("FEE_ROUTER_USDG")));
        new AuctionHouse(address(usdg), address(bm), address(fr2), address(priceSource), address(opt), admin);
        assertEq(usdg.allowance(address(ah), address(fr)), type(uint256).max, "standing approval for flush");
    }

    /// D-049 (review H-1): series ids come from one OptionToken counter, so a vault on another OptionToken
    /// would collide with a live auction; it is rejected at registration.
    function test_registerVault_rejectsForeignOptionToken() public {
        OptionToken opt2 = new OptionToken("", admin);
        CoveredCallVault foreign = _newVault(address(stock), address(usdg), address(opt2), address(ah));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.WrongOptionToken.selector, address(foreign), address(opt2)));
        ah.registerVault(address(foreign));
    }

    /// D-049 (review L-2): a vault on another USDG, or a BondManager / FeeRouter not wired to this AuctionHouse,
    /// is rejected at registration instead of failing at the first bid or clear.
    function test_registerVault_rejectsMiswiring() public {
        MockUSDG usdg2 = new MockUSDG();
        CoveredCallVault wrongUsdg = _newVault(address(stock), address(usdg2), address(opt), address(ah));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.Miswired.selector, bytes32("VAULT_USDG")));
        ah.registerVault(address(wrongUsdg));

        BondManager bm2 = new BondManager(address(usdg), admin, treasury); // auctionHouse never set
        FeeRouter fr2 = new FeeRouter(address(usdg), admin, treasury);
        AuctionHouse ah2 =
            new AuctionHouse(address(usdg), address(bm2), address(fr2), address(priceSource), address(opt), admin);
        CoveredCallVault v2 = _newVault(address(stock), address(usdg), address(opt), address(ah2));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.Miswired.selector, bytes32("BOND_MANAGER")));
        ah2.registerVault(address(v2));
        vm.prank(admin);
        bm2.setAuctionHouse(address(ah2));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.Miswired.selector, bytes32("FEE_ROUTER")));
        ah2.registerVault(address(v2));
        vm.prank(admin);
        fr2.setAuctionHouse(address(ah2));
        vm.prank(admin);
        ah2.registerVault(address(v2));
        assertTrue(ah2.isVault(address(v2)));
    }

    /// Two vaults on the same OptionToken get distinct series ids and clear independently.
    function test_twoVaultsOneOptionToken() public {
        MockStockToken stock2 = new MockStockToken("Mock SPY", "SPY", admin);
        CoveredCallVault v2 = _newVault(address(stock2), address(usdg), address(opt), address(ah));
        vm.startPrank(admin);
        opt.registerVault(address(stock2), address(v2));
        cap.setCapUSD(address(v2), BIG_CAP);
        ah.registerVault(address(v2));
        stock2.mint(bob, 50e18);
        vm.stopPrank();
        priceSource.set(address(v2), 500e8, true);
        vm.startPrank(bob);
        stock2.approve(address(v2), type(uint256).max);
        v2.deposit(50e18, bob);
        vm.stopPrank();

        uint256 id1 = _openDefault();
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        uint256 id2 = ah.openAuction(address(v2), SeriesKind.WEEKDAY, exp, 500, 3e6);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(ah.auctions(id2).vault, address(v2));
        assertEq(ah.auctions(id2).offeredQty, 50e18);
        assertEq(ah.auctions(id2).strike, ah.computeStrike(500e8, 500));
        _bid(mm1, id1, 100e18, 2e6);
        _bid(mm2, id2, 50e18, 4e6);
        _clear(id1);
        _clear(id2);
        assertEq(ah.claimableOptions(id1, mm1), 100e18);
        assertEq(ah.claimableOptions(id2, mm2), 50e18);
        assertEq(uint256(vault.state()), uint256(VaultState.LIVE));
        assertEq(uint256(v2.state()), uint256(VaultState.LIVE));
        assertEq(usdg.balanceOf(address(vault)), 180e6);
        assertEq(usdg.balanceOf(address(v2)), 180e6);
    }

    /// D-049: the fee rate is snapshotted at open; a later timelocked change does not touch the running auction.
    function test_clear_feeBpsSnapshottedAtOpen() public {
        uint256 id = _openDefault();
        assertEq(ah.auctions(id).feeBps, 1000);
        vm.prank(admin);
        fr.setFeeBps(address(vault), 2000);
        _bid(mm1, id, 50e18, 2e6);
        (,,, uint256 fee) = _clear(id);
        assertEq(fee, 10e6, "old rate applies");
        uint256 id2 = _reopenNextMonday();
        assertEq(ah.auctions(id2).feeBps, 2000, "new rate from the next open");
    }

    /// A HALTED series resolved by the timelock path (4) releases locks and pays allocations like a settled one.
    function test_haltedThenResolved_claimsAndLocks() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _bid(mm2, id, 50e18, 2e6);
        _clear(id);
        vm.warp(vault.series(id).expiry);
        vm.prank(settlement);
        vault.haltSeries(id, "NO_PRICE");
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.SeriesNotSettled.selector, SeriesState.HALTED));
        ah.releaseLocks(id);
        vm.prank(mm1);
        ah.claimOptions(id, mm1); // allowed while HALTED
        vm.prank(mm2);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.NotSettled.selector, id));
        ah.claimPayout(id, mm2);
        vm.prank(settlement);
        vault.settleSeries(id, 250e8, 4); // timelock resolution
        assertEq(uint256(vault.series(id).state), uint256(SeriesState.RESOLVED));
        vm.prank(mm2);
        (, uint256 tokens) = ah.claimPayout(id, mm2);
        assertEq(tokens, 50e18 * 0.136e18 / WAD);
        ah.releaseLocks(id);
        assertEq(bm.activeLocks(mm1) + bm.activeLocks(mm2), 0);
    }

    function _newVault(address stock_, address usdg_, address opt_, address ah_) internal returns (CoveredCallVault) {
        return new CoveredCallVault(
            CoveredCallVault.Config({
                stock: stock_,
                usdg: usdg_,
                optionToken: opt_,
                auctionHouse: ah_,
                settlement: settlement,
                riskModule: address(risk),
                capController: address(cap),
                owner: admin,
                name: "v",
                symbol: "v"
            })
        );
    }

    /// @dev Settles the current series OTM and opens a fresh weekday auction the following Monday.
    function _reopenNextMonday() internal returns (uint256 id) {
        _settle(vault.currentSeriesId(), 100e8);
        vm.warp(_nextMonday1400(block.timestamp));
        id = _openDefault();
    }

    function test_supportsInterface() public view {
        assertTrue(ah.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(ah.supportsInterface(type(IAccessControl).interfaceId));
        assertFalse(ah.supportsInterface(0xffffffff));
    }

    function test_scheduledExpiry() public view {
        uint64 fri = ah.scheduledExpiry(SeriesKind.WEEKDAY, uint64(MONDAY_1400));
        assertEq(fri, MONDAY_1400 + 4 days + 6 hours, "Friday 20:00 UTC");
        assertEq(fri % WEEK, ah.FRI_2000());
        uint64 sun = ah.scheduledExpiry(SeriesKind.WEEKEND, uint64(fri + 600));
        assertEq(sun, fri + 2 days + 3 hours + 59 minutes, "Sunday 23:59:00 UTC");
    }

    /// @dev Matches the other thirteen owned contracts (D-100). No account holds `DEFAULT_ADMIN_ROLE`, so an
    /// ownerless AuctionHouse could never register a vault, revoke a compromised keeper through `setKeeper`,
    /// or re-point `setPriceSource`.
    function test_renounceOwnershipDisabled() public {
        vm.prank(admin);
        vm.expectRevert(AuctionHouse.RenounceDisabled.selector);
        ah.renounceOwnership();
        // a non-owner is still rejected by `onlyOwner` first, so ownership cannot be dropped by anyone
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ah.renounceOwnership();
        assertEq(ah.owner(), admin, "the timelock still owns the auction house");
    }

    // ───────────────────────────── end to end ─────────────────────────────

    function test_e2e_weekCycle() public {
        // Monday: weekday auction
        uint256 id = _openDefault();
        _bid(mm1, id, 60e18, 3e6);
        _bid(mm2, id, 60e18, 2e6);
        _bid(mm3, id, 60e18, 1.5e6);
        (uint256 cp, uint256 filled, uint256 gross, uint256 fee) = _clear(id);
        assertEq(cp, 2e6);
        assertEq(filled, 100e18);
        assertEq(gross - fee, 180e6);
        vm.prank(mm1);
        ah.claimOptions(id, mm1); // mm1 pulls its tokens, mm2 does not
        vm.prank(mm3);
        ah.withdrawRefund(mm3);

        // Friday: ITM settlement at 250 (K = 216) → ppo = 0.136
        _settle(id, 250e8);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        vm.prank(mm2);
        (, uint256 tokens2) = ah.claimPayout(id, mm2);
        assertEq(tokens2, 40e18 * 0.136e18 / WAD);
        vm.prank(mm1);
        uint256 tokens1 = opt.claim(id, 60e18, mm1);
        assertEq(tokens1, 60e18 * 0.136e18 / WAD);
        assertEq(vault.payoutOwed(), 0);
        ah.releaseLocks(id);
        assertEq(bm.activeLocks(mm1) + bm.activeLocks(mm2) + bm.activeLocks(mm3), 0);
        vm.prank(alice);
        assertEq(vault.claimPremium(alice), 180e6);
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury), 20e6);

        // mm1 leaves: request now, withdraw after the cooldown (below)
        vm.prank(mm1);
        uint64 unlockAt = bm.requestWithdraw(IBondManager.BondKind.MM);

        // Friday 20:10: weekend auction on the remaining balance
        vm.warp(vault.series(id).expiry + 600);
        uint256 id2 = _openWeekend(300, RESERVE);
        assertEq(ah.auctions(id2).offeredQty, vault.totalAssets());
        _bid(mm2, id2, 200e18, 1e6);
        (, uint256 filled2,,) = _clear(id2);
        assertEq(filled2, ah.auctions(id2).offeredQty, "fully written");
        _settle(id2, 190e8); // OTM
        assertEq(vault.series(id2).payoutPerOption, 0);
        ah.releaseLocks(id2);

        // next Monday: again
        vm.warp(_nextMonday1400(block.timestamp));
        uint256 id3 = _openDefault();
        assertEq(id3, 3);

        // mm1's cooldown ends the following Friday
        vm.warp(unlockAt);
        vm.prank(mm1);
        assertEq(bm.withdrawBond(IBondManager.BondKind.MM), BOND);
    }
}
