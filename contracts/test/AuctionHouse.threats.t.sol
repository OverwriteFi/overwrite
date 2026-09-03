// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AuctionBaseTest} from "./AuctionBase.t.sol";
import {AuctionHouse} from "../src/AuctionHouse.sol";
import {BondManager} from "../src/BondManager.sol";
import {CoveredCallVault} from "../src/CoveredCallVault.sol";
import {MockUSDG} from "../src/mocks/MockUSDG.sol";
import {IAuctionHouse} from "../src/interfaces/IAuctionHouse.sol";
import {IBondManager} from "../src/interfaces/IBondManager.sol";
import {SeriesKind, SeriesState, VaultState} from "../src/Types.sol";
import {ReentrantActor} from "./mocks/ReentrantActor.sol";
import {IERC1155Errors, IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Bidder contract without the ERC-1155 receiver interface (THREAT-MODEL T-07.4).
contract NonReceiverBidder {
    AuctionHouse internal ah;
    BondManager internal bm;

    constructor(AuctionHouse ah_, BondManager bm_, MockUSDG usdg) {
        ah = ah_;
        bm = bm_;
        usdg.approve(address(ah_), type(uint256).max);
        usdg.approve(address(bm_), type(uint256).max);
    }

    function post() external {
        bm.postBond(IBondManager.BondKind.MM);
    }

    function bid(uint256 id, uint256 qty, uint256 price) external {
        ah.bid(id, qty, price);
    }

    function claimOptions(uint256 id) external {
        ah.claimOptions(id, address(this));
    }

    function claimPayout(uint256 id) external returns (uint256, uint256) {
        return ah.claimPayout(id, address(this));
    }
}

/// @notice Threat-model regression tests, named `test_Txx_…` per THREAT-MODEL §6 (T-04, T-05, T-07, T-09, T-12,
/// T-13, T-16).
contract AuctionHouseThreatsTest is AuctionBaseTest {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100e18);
    }

    // ───────────────────────────── T-07 auction griefing ─────────────────────────────

    /// T-07.1: a bid that cannot fund its escrow is never stored and never locks a bond.
    function test_T07_bidWithoutEscrowReverts() public {
        address poor = _newMM("poor");
        uint256 left = usdg.balanceOf(poor); // read before pranking (view call in the args would eat the prank)
        vm.prank(poor);
        usdg.transfer(bob, left);
        uint256 id = _openDefault();
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, 2e6));
        ah.bid(id, 1e18, 2e6);
        assertEq(ah.bids(id).length, 0);
        assertEq(ah.bidCount(id, poor), 0);
        assertFalse(bm.isLocked(poor, id));
        assertEq(bm.activeLocks(poor), 0);
    }

    /// T-07.2: 64 per auction, 8 per bidder.
    function test_T07_maxBidsPerAuctionAndPerBidder() public {
        uint256 id = _openDefault();
        address[8] memory mms = [mm1, mm2, mm3, mm4, _newMM("m5"), _newMM("m6"), _newMM("m7"), _newMM("m8")];
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                _bid(mms[i], id, 1e18, 2e6);
            }
            if (i == 7) break; // the auction cap (64) is checked first, see below
            vm.prank(mms[i]);
            vm.expectRevert(abi.encodeWithSelector(AuctionHouse.TooManyBidsPerBidder.selector, 8));
            ah.bid(id, 1e18, 2e6);
        }
        assertEq(ah.bids(id).length, 64);
        vm.prank(mms[7]);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.TooManyBids.selector, 64));
        ah.bid(id, 1e18, 2e6);
        address ninth = _newMM("m9");
        vm.prank(ninth);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.TooManyBids.selector, 64));
        ah.bid(id, 1e18, 2e6);
        // the auction still clears
        (, uint256 filled,,) = _clear(id);
        assertEq(filled, 64e18);
    }

    /// T-07.3 / D-023: a bidder frozen by Paxos between bid and clear cannot block `clear`; only its own
    /// pull reverts until unfrozen.
    function test_T07_clearWithFrozenBidderDoesNotRevert() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 3e6);
        _bid(mm2, id, 50e18, 2e6); // partially refunded
        _bid(mm3, id, 50e18, 1.5e6); // fully refunded
        usdg.setFrozen(mm2, true);
        usdg.setFrozen(mm3, true);
        (uint256 cp, uint256 filled,,) = _clear(id);
        assertEq(cp, 2e6);
        assertEq(filled, 100e18);
        assertEq(uint256(vault.state()), uint256(VaultState.LIVE));
        assertEq(ah.refundable(mm3), 75e6);
        vm.prank(mm3);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, mm3));
        ah.withdrawRefund(mm3);
        usdg.setFrozen(mm3, false);
        vm.prank(mm3);
        assertEq(ah.withdrawRefund(mm3), 75e6);
    }

    /// T-07.4 / D-024: a contract bidder that cannot receive ERC-1155 cannot block `clear`; it still gets its
    /// payout through `claimPayout` (unminted allocation, D-038).
    function test_T07_clearWithNonReceiverContractBidderDoesNotRevert() public {
        NonReceiverBidder bidder = new NonReceiverBidder(ah, bm, usdg);
        usdg.mint(address(bidder), 1_000_000e6);
        bidder.post();
        uint256 id = _openDefault();
        bidder.bid(id, 50e18, 2e6);
        (, uint256 filled,,) = _clear(id);
        assertEq(filled, 50e18);
        assertEq(ah.claimableOptions(id, address(bidder)), 50e18);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(bidder)));
        bidder.claimOptions(id);
        _settle(id, 250e8);
        (uint256 qty, uint256 tokens) = bidder.claimPayout(id);
        assertEq(qty, 50e18);
        assertEq(tokens, 6.8e18);
        assertEq(stock.balanceOf(address(bidder)), 6.8e18);
    }

    /// T-07.6 / D-030: the bond lock follows participation, not token balance.
    function test_T07_bondLockedUntilSeriesSettledEvenAfterTokenTransfer() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _clear(id);
        vm.prank(mm1);
        ah.claimOptions(id, mm1);
        vm.prank(mm1);
        opt.safeTransferFrom(mm1, alice, id, 50e18, "");
        assertEq(opt.balanceOf(mm1, id), 0);
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Locked.selector, 1));
        bm.requestWithdraw(IBondManager.BondKind.MM);
        _settle(id, 210e8);
        vm.prank(mm1);
        vm.expectRevert(abi.encodeWithSelector(BondManager.Locked.selector, 1));
        bm.requestWithdraw(IBondManager.BondKind.MM);
        ah.releaseLocks(id);
        vm.prank(mm1);
        bm.requestWithdraw(IBondManager.BondKind.MM);
        assertFalse(bm.hasActiveMMBond(mm1));
    }

    /// T-07.8: 64 distinct bidders, every one with a refund and most with an allocation, under 6 M gas.
    function test_T07_clearGasUnder6M() public {
        uint256 id = _openDefault();
        for (uint256 i; i < 64; ++i) {
            address mm = i < 4 ? [mm1, mm2, mm3, mm4][i] : _newMM(string.concat("g", vm.toString(i)));
            // 2 options each at 6 distinct prices: 128 demanded, 100 offered → pro-rata group at the margin
            _bid(mm, id, 2e18, 1e6 * (1 + (i * 7) % 6));
        }
        _close(id);
        uint256 gasBefore = gasleft();
        (uint256 cp, uint256 filled,,) = ah.clear(id);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("clear gas with 64 bidders", used);
        assertLt(used, 6_000_000, "SPEC 8.2 gas bound");
        assertEq(filled, 100e18);
        assertGe(cp, 1e6);
    }

    /// T-07.8 (skip path): 64 bids refunded in one skip.
    function test_T07_skipGasUnder6M() public {
        uint256 id = _openDefault();
        for (uint256 i; i < 64; ++i) {
            address mm = i < 4 ? [mm1, mm2, mm3, mm4][i] : _newMM(string.concat("s", vm.toString(i)));
            _bid(mm, id, 2e18, 2e6);
        }
        vm.warp(vault.series(id).expiry);
        uint256 gasBefore = gasleft();
        ah.clear(id);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("skip gas with 64 bidders", used);
        assertLt(used, 6_000_000);
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
    }

    // ───────────────────────────── T-12 external token failures ─────────────────────────────

    /// T-12 / D-049: the fee never leaves the AuctionHouse inside `clear`, so a frozen FeeRouter (or a frozen
    /// treasury) cannot revert it; only `flush` is affected, and a frozen router is not even that.
    function test_T12_clearSucceedsWhenFeeRouterFrozen() public {
        usdg.setFrozen(address(fr), true);
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        (,,, uint256 fee) = _clear(id);
        assertEq(fee, 10e6);
        assertEq(fr.pending(address(vault)), 10e6);
        assertEq(usdg.balanceOf(address(ah)), 10e6, "fee parked in the AuctionHouse");
        assertEq(usdg.balanceOf(address(fr)), 0);
        fr.flush(address(vault)); // AuctionHouse → treasury, the router never holds USDG
        assertEq(usdg.balanceOf(treasury), 10e6);
        assertEq(usdg.balanceOf(address(ah)), 0);
    }

    /// A frozen treasury breaks `flush` only; `clear` books the fee and moves on (D-023).
    function test_T12_clearSucceedsWhenTreasuryFrozen() public {
        usdg.setFrozen(treasury, true);
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        (,,, uint256 fee) = _clear(id);
        assertEq(fee, 10e6);
        assertEq(fr.pending(address(vault)), 10e6);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.AccountFrozen.selector, treasury));
        fr.flush(address(vault));
        usdg.setFrozen(treasury, false);
        fr.flush(address(vault));
        assertEq(usdg.balanceOf(treasury), 10e6);
    }

    /// Residual documented in SPEC §8.2: a paused USDG blocks `clear` (fee transfer + premium pull) until unpause;
    /// the series then clears normally. Bids and clear parameters are unaffected.
    function test_T12_clearWaitsForUsdgUnpause() public {
        uint256 id = _openDefault();
        _bid(mm1, id, 50e18, 2e6);
        _close(id);
        usdg.setPaused(true);
        vm.expectRevert(MockUSDG.TokenPaused.selector);
        ah.clear(id);
        assertEq(uint256(vault.state()), uint256(VaultState.AUCTION));
        usdg.setPaused(false);
        (, uint256 filled,,) = ah.clear(id);
        assertEq(filled, 50e18);
    }

    // ───────────────────────────── T-13 / T-19 rogue keeper ─────────────────────────────

    function test_T13_openAuctionRequiresKeeperRole() public {
        uint64 exp = _fridayExpiry();
        bytes32 role = ah.KEEPER_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
        vm.prank(keeper);
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, RESERVE);
    }

    /// Nobody holds `DEFAULT_ADMIN_ROLE`: the raw AccessControl grant/revoke entry points are dead for everyone,
    /// including the owner and the keeper; only the timelocked `setKeeper` changes the role (D-028, D-049).
    function test_T13_noRoleAdminExists() public {
        bytes32 role = ah.KEEPER_ROLE();
        bytes32 adminRole = ah.DEFAULT_ADMIN_ROLE();
        address[3] memory callers = [admin, keeper, bob];
        for (uint256 i; i < callers.length; ++i) {
            address c = callers[i];
            vm.prank(c);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, c, adminRole)
            );
            ah.grantRole(role, bob);
            vm.prank(c);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, c, adminRole)
            );
            ah.revokeRole(role, keeper);
            vm.prank(c);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, c, adminRole)
            );
            ah.grantRole(adminRole, c);
        }
        assertEq(ah.getRoleAdmin(role), adminRole);
        assertFalse(ah.hasRole(adminRole, admin));
        assertTrue(ah.hasRole(role, keeper));
    }

    function test_T13_distanceBelowBoundReverts() public {
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.DistanceOutOfBounds.selector, 0, 300, 1500));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, 0, RESERVE);
    }

    function test_T13_reserveBelowCuratorFloorReverts() public {
        vm.prank(admin);
        ah.setMinReserveBpsOfSpot(address(vault), SeriesKind.WEEKDAY, 100); // 1 % of $200 = 2 USDG
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.ReserveOutOfBounds.selector, 1e6, 2e6, 200e6));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, 1e6);
        assertEq(_open(DIST, 2e6), 1);
    }

    function test_T13_reserveAboveSpotReverts() public {
        uint64 exp = _fridayExpiry();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.ReserveOutOfBounds.selector, 200e6 + 1, 200_000, 200e6));
        ah.openAuction(address(vault), SeriesKind.WEEKDAY, exp, DIST, 200e6 + 1);
    }

    /// A keeper cannot open a weekend auction on Saturday or Sunday (a 3-hour option at the 1 % floor).
    function test_T13_weekendCannotOpenOutsideFridayWindow() public {
        uint256 ws = MONDAY_1400 - (MONDAY_1400 % WEEK) + WEEK;
        uint64 sun = uint64(ws + ah.SUN_2359());
        uint256[3] memory bad = [ws + 2 days + 12 hours, ws + 3 days + 20 hours, ws + ah.FRI_1930() + 599];
        for (uint256 i; i < bad.length; ++i) {
            vm.warp(bad[i]);
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(AuctionHouse.CannotOpen.selector, bytes32("OPEN_WINDOW")));
            ah.openAuction(address(vault), SeriesKind.WEEKEND, sun, 300, RESERVE);
        }
        vm.warp(ws + ah.FRI_1930() + 600);
        vm.prank(keeper);
        ah.openAuction(address(vault), SeriesKind.WEEKEND, sun, 300, RESERVE);
    }

    // ───────────────────────────── T-04 weekend series ─────────────────────────────

    function test_T04_weekendDistanceBounds() public {
        uint256 ws = MONDAY_1400 - (MONDAY_1400 % WEEK) + WEEK;
        uint64 sun = uint64(ws + ah.SUN_2359());
        vm.warp(ws + ah.FRI_1930() + 600);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.DistanceOutOfBounds.selector, 99, 100, 1000));
        ah.openAuction(address(vault), SeriesKind.WEEKEND, sun, 99, RESERVE);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AuctionHouse.DistanceOutOfBounds.selector, 1001, 100, 1000));
        ah.openAuction(address(vault), SeriesKind.WEEKEND, sun, 1001, RESERVE);
        (uint256 lo,) = ah.reserveBounds(address(vault), SeriesKind.WEEKEND, PRICE);
        assertEq(lo, 60_000, "3 bps weekend floor");
        vm.prank(keeper);
        uint256 id = ah.openAuction(address(vault), SeriesKind.WEEKEND, sun, 100, uint128(lo));
        assertEq(ah.auctions(id).strike, ah.computeStrike(PRICE, 100));
    }

    // ───────────────────────────── T-09 rounding ─────────────────────────────

    function test_T09_gridZeroReverts() public {
        vm.expectRevert(AuctionHouse.GridZero.selector);
        ah.computeStrike(399, 800);
        assertEq(ah.computeStrike(400, 800), 432);
    }

    // ───────────────────────────── T-05 sequencer outage / retry ─────────────────────────────

    /// A skipped auction can be re-opened inside the same window (no `expiry > lastExpiry` check, D-046).
    function test_T05_retryOpenAfterSkipInSameWindow() public {
        uint256 id = _openDefault();
        _clear(id); // skipped: no bids
        assertEq(uint256(vault.state()), uint256(VaultState.IDLE));
        uint256 id2 = _openDefault();
        assertEq(id2, 2);
        assertEq(ah.currentAuction(address(vault)), 2);
    }

    // ───────────────────────────── T-16 reentrancy ─────────────────────────────

    /// The re-entering actor holds a refund, an allocation and premium-bearing shares, so each attempt from the
    /// ERC-1155 mint callback would succeed if the guards were missing; every one must revert with the
    /// ReentrancyGuard error, and the same calls succeed right after the callback (non-vacuity check).
    function test_T16_erc1155CallbackCannotReenterVaultOrAuction() public {
        ReentrantActor r = new ReentrantActor(ah, vault, bm, usdg, stock);
        usdg.mint(address(r), 1_000_000e6);
        vm.prank(admin);
        stock.mint(address(r), 20e18);
        r.post();
        r.deposit(20e18); // offered = 120, so both bids fill fully at cp = 2e6
        uint256 id = _openDefault();
        r.bid(id, 50e18, 3e6); // escrow 150, pays 100 → refund 50
        _bid(mm1, id, 60e18, 2e6);
        _clear(id);
        assertEq(ah.refundable(address(r)), 50e6);
        assertEq(ah.claimableOptions(id, address(r)), 50e18);
        assertGt(vault.premiumClaimable(address(r)), 0);

        vm.prank(mm1);
        ah.claimOptions(id, address(r)); // mint callback lands on the actor while both guards are held
        assertEq(r.attempts(), 3, "callback ran");
        assertEq(r.successes(), 0, "no re-entry succeeded");
        for (uint256 i; i < r.selectorCount(); ++i) {
            assertEq(r.selectors(i), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "guard, not a precondition");
        }
        assertEq(opt.balanceOf(address(r), id), 60e18, "mm1's tokens delivered");
        assertEq(ah.refundable(address(r)), 50e6, "state untouched");
        assertEq(ah.claimableOptions(id, address(r)), 50e18);

        // the very same calls succeed outside the callback
        r.exec(address(ah), abi.encodeCall(ah.withdrawRefund, (address(r))));
        r.exec(address(ah), abi.encodeCall(ah.claimOptions, (id, address(r))));
        r.exec(address(vault), abi.encodeCall(vault.claimPremium, (address(r))));
        assertEq(ah.refundable(address(r)), 0);
        assertEq(opt.balanceOf(address(r), id), 110e18);
        assertEq(vault.premiumClaimable(address(r)), 0);
    }
}
